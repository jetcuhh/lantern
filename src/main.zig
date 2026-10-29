//! lantern: a terminal multiplexer built on libghostty (ghostty-vt).
//!
//! Running `lantern` opens the full-screen UI. Quitting the UI detaches;
//! the session and its tabs keep running, and `lantern` brings them back.

const std = @import("std");
const posix = @import("sys.zig");

const client = @import("client.zig");
const daemonpkg = @import("daemon.zig");
const help = @import("help.zig");
const paths = @import("paths.zig");
const protocol = @import("protocol.zig");
const svg = @import("svg.zig");
const ui = @import("ui.zig");

pub const version = "0.1.0";

/// Exit codes, documented in `lantern help`.
const exit_runtime: u8 = 1;
const exit_usage: u8 = 2;

fn fail(code: u8, comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lantern: " ++ fmt ++ "\n", args);
    posix.exit(code);
}

/// Usage errors point at the help page.
fn usageFail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lantern: " ++ fmt ++ " (run 'lantern help')\n", args);
    posix.exit(exit_usage);
}

fn stdoutWrite(bytes: []const u8) !void {
    try protocol.writeAll(posix.STDOUT_FILENO, bytes);
}

fn stdoutPrint(alloc: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const text = try std.fmt.allocPrint(alloc, fmt, args);
    defer alloc.free(text);
    try stdoutWrite(text);
}

pub fn main(init: std.process.Init) !void {
    // Note: not DebugAllocator. The session daemon is forked from this
    // process, and DebugAllocator's stack-trace capture reads process
    // memory through a pid cached before fork(), which blows up in the
    // child once the parent exits. Unit tests still run against
    // std.testing.allocator for leak checking.
    const alloc = std.heap.c_allocator;

    // Accept SVG documents in kitty graphics transmissions (see svg.zig).
    // Before anything forks, so the daemon and the UI agree.
    svg.install();

    const raw_args = init.minimal.args.vector;
    const argv = try alloc.alloc([:0]const u8, raw_args.len);
    defer alloc.free(argv);
    for (raw_args, 0..) |arg, i| argv[i] = std.mem.span(arg);
    const args: []const [:0]const u8 = argv[1..];

    if (args.len == 0) return launch(init.io, alloc);

    const cmd = args[0];
    const rest = args[1..];
    const eql = std.mem.eql;

    if (eql(u8, cmd, "version") or eql(u8, cmd, "-V") or eql(u8, cmd, "--version")) {
        if (rest.len > 0) usageFail("version takes no arguments", .{});
        return cmdVersion(alloc);
    }
    if (eql(u8, cmd, "help") or eql(u8, cmd, "-h") or eql(u8, cmd, "--help")) {
        return cmdHelp(alloc, rest);
    }
    usageFail("unknown command '{s}'", .{cmd});
}

fn cmdVersion(alloc: std.mem.Allocator) !void {
    try stdoutPrint(alloc, "lantern {s}\n", .{version});
}

fn cmdHelp(alloc: std.mem.Allocator, args: []const [:0]const u8) !void {
    _ = alloc;
    if (args.len == 0) return stdoutWrite(help.overview);
    if (args.len > 1) usageFail("expected one help page", .{});

    const topic = args[0];
    if (std.mem.eql(u8, topic, "--all")) {
        try stdoutWrite(help.overview);
        for (&help.commands) |*entry| {
            try stdoutWrite("\n");
            try stdoutWrite(entry.body);
        }
        for (&help.topics) |*entry| {
            try stdoutWrite("\n");
            try stdoutWrite(entry.body);
        }
        return;
    }
    if (help.find(topic)) |entry| return stdoutWrite(entry.body);
    usageFail("no help for '{s}'", .{topic});
}

// -- Launch ---------------------------------------------------------------

/// Open the UI, starting the session daemon first when none is running.
fn launch(io: std.Io, alloc: std.mem.Allocator) !void {
    if (!posix.isatty(posix.STDIN_FILENO)) {
        fail(exit_runtime, "lantern requires a terminal", .{});
    }

    // A second launch attaches to the running session: the daemon keeps
    // one session per socket and any number of clients may attach at
    // once, each with its own active tab. This is true even when
    // launched from inside a lantern tab (whose shell inherits
    // LANTERN=1), where the previous build refused.
    const dir = try paths.socketDir(alloc);
    defer alloc.free(dir);
    const sock = try paths.sessionPath(alloc, dir);
    defer alloc.free(sock);

    // Decide, under a lock, whether a daemon already owns the session or
    // this process must start one. Without the lock two simultaneous
    // first launches can race: one has bound the socket but not yet
    // called listen(), so the other's liveness probe is refused, takes
    // the socket for stale, deletes it and starts a second session,
    // orphaning the first with its tabs running.
    const Action = union(enum) { attach, listen: posix.fd_t };
    const action: Action = decide: {
        const lock = acquireLaunchLock(alloc, sock);
        defer releaseLaunchLock(lock);

        // An existing daemon already owns the session: reconnect to it.
        if (client.connect(alloc, sock)) |probe| {
            posix.close(probe);
            break :decide .attach;
        } else |_| {}

        // No live daemon. bindListen removes the socket file only after its
        // own liveness probe fails, so a daemon that is slow to answer is
        // never orphaned with its tabs still running while a fresh session
        // takes its place.
        const bound = bindListen(alloc, sock) catch |err| switch (err) {
            // A daemon appeared between the probe above and the bind;
            // attach to it instead of starting a second session.
            error.SessionExists => break :decide .attach,
            else => return err,
        };
        break :decide .{ .listen = bound };
    };
    const listen_fd = switch (action) {
        .attach => return runUi(io, alloc, sock),
        .listen => |fd| fd,
    };

    if (posix.getenv("LANTERN_FOREGROUND") != null) {
        var opts: daemonpkg.Options = .{ .socket_path = sock, .listen_fd = listen_fd };
        opts.rows = 24;
        opts.cols = 80;
        try daemonpkg.Daemon.run(io, alloc, opts);
        return;
    }

    const pid = try posix.fork();
    if (pid == 0) runDaemon(io, alloc, sock, listen_fd);
    posix.close(listen_fd);

    return runUi(io, alloc, sock);
}

/// Serialize "is there a session? start one" across concurrent launches
/// with an flock on `<socket>.lock`. Best effort: when the lock file
/// cannot be opened the launch proceeds unserialized, as before. The lock
/// is released before the daemon forks, so the daemon never inherits it.
fn acquireLaunchLock(alloc: std.mem.Allocator, sock_path: []const u8) ?posix.fd_t {
    const lock_path = std.fmt.allocPrint(alloc, "{s}.lock", .{sock_path}) catch return null;
    defer alloc.free(lock_path);
    const fd = posix.open(lock_path, .{
        .ACCMODE = .RDWR,
        .CREAT = true,
        .CLOEXEC = true,
    }, 0o600) catch return null;
    posix.flock(fd, posix.LOCK.EX) catch {
        posix.close(fd);
        return null;
    };
    return fd;
}

fn releaseLaunchLock(fd: ?posix.fd_t) void {
    if (fd) |f| posix.close(f);
}

fn runUi(io: std.Io, alloc: std.mem.Allocator, sock: []const u8) !void {
    // The UI feeds session output through an in-process libghostty
    // stream whose VT logs would otherwise paint over the viewport:
    // std.log writes to stderr, which is the user's terminal here,
    // while the daemon redirects its own stderr in runDaemon. Point
    // stderr at LANTERN_LOG, or /dev/null, while the UI owns the screen,
    // then restore it so errors are visible after it exits.
    const saved_stderr = redirectStderr();
    const result = ui.run(io, alloc, sock);
    restoreStderr(saved_stderr);
    result catch |err| switch (err) {
        error.NotATty => fail(exit_runtime, "lantern requires a terminal", .{}),
        else => return err,
    };
}

// -- Daemon plumbing ------------------------------------------------------

/// Open the destination for std.log and std.debug output: $LANTERN_LOG
/// (created, appended) when set, otherwise /dev/null. Both the session
/// daemon and the UI run with a terminal on stderr, where libghostty's
/// in-process VT logging would paint over the display, so they route
/// stderr here. Returns null when the target cannot be opened.
fn openLogSink() ?posix.fd_t {
    if (posix.getenv("LANTERN_LOG")) |log_path| {
        return posix.open(log_path, .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .APPEND = true,
        }, 0o600) catch null;
    }
    return posix.open("/dev/null", .{ .ACCMODE = .WRONLY }, 0) catch null;
}

/// Redirect stderr to the log sink for the lifetime of a foreground
/// command that owns the terminal (the UI). Returns a saved dup of the
/// original stderr for restoreStderr, or -1 when stderr was left
/// untouched.
fn redirectStderr() posix.fd_t {
    const sink = openLogSink() orelse return -1;
    defer posix.close(sink);
    // Mark the saved terminal stderr close-on-exec so it is not
    // inherited by any child processes a tab spawns.
    const saved = posix.dup(posix.STDERR_FILENO) catch return -1;
    _ = posix.fcntl(saved, posix.F.SETFD, posix.FD_CLOEXEC) catch {};
    posix.dup2(sink, posix.STDERR_FILENO) catch {
        posix.close(saved);
        return -1;
    };
    return saved;
}

/// Restore stderr from a redirectStderr handle. A no-op for -1.
fn restoreStderr(saved: posix.fd_t) void {
    if (saved < 0) return;
    posix.dup2(saved, posix.STDERR_FILENO) catch {};
    posix.close(saved);
}

fn runDaemon(io: std.Io, alloc: std.mem.Allocator, sock: []const u8, listen_fd: posix.fd_t) noreturn {
    _ = posix.setsid() catch {};

    // Detach stdio: stdin and stdout go to /dev/null, stderr to the log
    // sink (LANTERN_LOG when set, else /dev/null) so std.log output is
    // preserved for debugging.
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch posix.exit(1);
    posix.dup2(devnull, 0) catch {};
    posix.dup2(devnull, 1) catch {};
    if (openLogSink()) |sink| {
        posix.dup2(sink, 2) catch {};
        posix.close(sink);
    } else {
        posix.dup2(devnull, 2) catch {};
    }
    if (devnull > 2) posix.close(devnull);

    var opts: daemonpkg.Options = .{
        .socket_path = sock,
        .listen_fd = listen_fd,
    };
    opts.rows = 24;
    opts.cols = 80;
    daemonpkg.Daemon.run(io, alloc, opts) catch |err| {
        std.log.err("daemon failed: {}", .{err});
        posix.exit(1);
    };
    posix.exit(0);
}

fn bindListen(alloc: std.mem.Allocator, sock_path: []const u8) !posix.fd_t {
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);

    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (sock_path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..sock_path.len], sock_path);

    posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch |err| switch (err) {
        error.AddressInUse => {
            // Either a live session or a stale socket file.
            if (client.connect(alloc, sock_path)) |probe| {
                posix.close(probe);
                return error.SessionExists;
            } else |_| {
                try posix.deleteFile(sock_path);
                try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
            }
        },
        else => return err,
    };

    try posix.listen(fd, 8);
    return fd;
}

// -- Tests ----------------------------------------------------------------

test {
    _ = @import("protocol.zig");
    _ = @import("paths.zig");
    _ = @import("cwd.zig");
    _ = @import("keys.zig");
    _ = @import("pty.zig");
    _ = @import("reap.zig");
    _ = @import("altscreen.zig");
    _ = @import("oscquery.zig");
    _ = @import("osc52.zig");
    _ = @import("kitty.zig");
    _ = @import("window.zig");
    _ = @import("daemon.zig");
    _ = @import("client.zig");
    _ = @import("help.zig");
    _ = @import("ui.zig");
}
