//! End-to-end tests that drive the real lantern binary through a real PTY.
//!
//! lantern is one persistent session with many tabs. A test "terminal" (PTY
//! master) hosts a UI client as its controlling terminal, exactly like a
//! user's terminal would. The session daemon is started up front as an
//! owned, foreground process (`LANTERN_FOREGROUND=1`) so the harness can put
//! it down deterministically at the end of each test; UI clients then
//! attach to it, and detaching leaves it running for the next client.

const std = @import("std");
const posix = @import("lantern-sys");
const build_options = @import("build_options");
const vt = @import("ghostty-vt");

const exe_path: []const u8 = build_options.exe_path;

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
extern "c" fn kill(pid: std.c.pid_t, sig: c_int) c_int;

const default_timeout_ms: u64 = 10_000;

/// Terminal ioctl request codes; Zig's std lacks the darwin set variants.
const Tio = switch (@import("builtin").os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos => struct {
        const IOCSWINSZ: c_ulong = 0x80087467;
        const IOCSCTTY: c_ulong = 0x20007461;
    },
    else => struct {
        const IOCSWINSZ: c_ulong = std.c.T.IOCSWINSZ;
        const IOCSCTTY: c_ulong = std.c.T.IOCSCTTY;
    },
};

const Deadline = struct {
    end: i64,

    fn init(ms: u64) Deadline {
        return .{ .end = posix.milliTimestamp() + @as(i64, @intCast(ms)) };
    }

    fn tick(self: *Deadline, comptime what: []const u8) !void {
        if (posix.milliTimestamp() > self.end) {
            std.debug.print("timeout: " ++ what ++ "\n", .{});
            return error.Timeout;
        }
        posix.sleep(25 * std.time.ns_per_ms);
    }
};

/// Per-test environment: an isolated socket directory under /tmp (kept
/// short because of sockaddr_un path limits) and the daemon it owns.
const Harness = struct {
    alloc: std.mem.Allocator,
    dir: []u8,
    daemon: ?PtyClient = null,

    fn init(alloc: std.mem.Allocator) !Harness {
        var random_bytes: [6]u8 = undefined;
        std.testing.io.random(&random_bytes);
        var suffix: [12]u8 = undefined;
        const hex = std.fmt.bufPrint(&suffix, "{x}", .{&random_bytes}) catch unreachable;
        const dir = try std.fmt.allocPrint(alloc, "/tmp/lanterntest-{s}", .{hex});
        errdefer alloc.free(dir);
        try posix.makePath(dir);
        return .{ .alloc = alloc, .dir = dir };
    }

    fn deinit(self: *Harness) void {
        if (self.daemon) |*d| d.deinit();
        // The daemon held every tab's PTY master; killing it hangs the
        // tab shells up. Give them a beat to exit before removing the
        // socket directory.
        posix.sleep(50 * std.time.ns_per_ms);
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.dir) catch {};
        self.alloc.free(self.dir);
    }

    fn socketPath(self: *Harness) ![]u8 {
        return std.fs.path.join(self.alloc, &.{ self.dir, "lantern.sock" });
    }

    /// Whether a live daemon is accepting connections on the socket.
    fn socketUp(self: *Harness) bool {
        const sock = self.socketPath() catch return false;
        defer self.alloc.free(sock);
        const fd = posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0) catch return false;
        defer posix.close(fd);
        var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
        if (sock.len >= addr.path.len) return false;
        @memset(&addr.path, 0);
        @memcpy(addr.path[0..sock.len], sock);
        posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un)) catch return false;
        return true;
    }

    /// Start the session daemon as an owned foreground process and wait
    /// for its socket to accept connections.
    fn startDaemon(self: *Harness, rows: u16, cols: u16) !void {
        self.daemon = try PtyClient.spawnProgram(self, exe_path, &.{}, rows, cols, &.{
            .{ "LANTERN_FOREGROUND", "1" },
            .{ "SHELL", "/bin/sh" },
            .{ "PS1", "" },
        });
        var deadline = Deadline.init(default_timeout_ms);
        while (!self.socketUp()) {
            try deadline.tick("daemon socket never came up");
        }
    }

    fn run(self: *Harness, argv: []const []const u8) !std.process.RunResult {
        return self.runIn(null, argv);
    }

    /// Run a CLI command with an explicit working directory; cwd null
    /// inherits the test runner's directory.
    fn runIn(
        self: *Harness,
        cwd: ?[]const u8,
        argv: []const []const u8,
    ) !std.process.RunResult {
        // exe_path is relative to the build root; resolve it so a
        // custom cwd does not break spawning.
        var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
        const exe_len = try std.Io.Dir.cwd().realPathFile(std.testing.io, exe_path, &exe_buf);
        const exe_abs = exe_buf[0..exe_len];

        var full_argv: std.ArrayList([]const u8) = .empty;
        defer full_argv.deinit(self.alloc);
        try full_argv.append(self.alloc, exe_abs);
        try full_argv.appendSlice(self.alloc, argv);

        var env = try posix.environMap(self.alloc);
        defer env.deinit();
        try env.put("LANTERN_DIR", self.dir);

        const cwd_opt: std.process.Child.Cwd = if (cwd) |c| .{ .path = c } else .inherit;
        return std.process.run(self.alloc, std.testing.io, .{
            .argv = full_argv.items,
            .cwd = cwd_opt,
            .environ_map = &env,
        });
    }

    /// Run a CLI command and require exit code 0.
    fn runOk(self: *Harness, argv: []const []const u8) !void {
        const result = try self.run(argv);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("lantern {s} failed: {s}\n", .{ argv[0], result.stderr });
            return error.CommandFailed;
        }
    }

    /// Run a CLI command and require a specific exit code.
    fn runExit(self: *Harness, argv: []const []const u8, want: u8) !void {
        const result = try self.run(argv);
        defer self.alloc.free(result.stdout);
        defer self.alloc.free(result.stderr);
        if (result.term != .exited or result.term.exited != want) {
            std.debug.print(
                "lantern {s}: wanted exit {d}, got {any}: {s}\n",
                .{ argv[0], want, result.term, result.stderr },
            );
            return error.WrongExit;
        }
    }
};

/// A lantern process (the daemon or a UI client) running on a real PTY owned
/// by the test.
const PtyClient = struct {
    alloc: std.mem.Allocator,
    master: posix.fd_t,
    pid: posix.pid_t,
    output: std.ArrayList(u8) = .empty,
    exited: ?u32 = null,

    fn spawn(
        harness: *Harness,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
    ) !PtyClient {
        return spawnProgram(harness, exe_path, argv, rows, cols, &.{});
    }

    /// Like spawn, but runs an arbitrary program instead of the lantern
    /// binary, e.g. a shell wrapping an attach the way a login shell
    /// does for a user. `env_extra` overrides or adds environment
    /// variables for the child.
    fn spawnProgram(
        harness: *Harness,
        program: []const u8,
        argv: []const []const u8,
        rows: u16,
        cols: u16,
        env_extra: []const [2][]const u8,
    ) !PtyClient {
        const alloc = harness.alloc;

        // PTY pair.
        const master = posix_openpt(@bitCast(@as(u32, @bitCast(posix.O{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }))));
        if (master < 0) return error.OpenPtyFailed;
        errdefer posix.close(master);
        if (grantpt(master) != 0) return error.OpenPtyFailed;
        if (unlockpt(master) != 0) return error.OpenPtyFailed;
        var path_buf: [128]u8 = undefined;
        if (ptsname_r(master, &path_buf, path_buf.len) != 0) return error.OpenPtyFailed;
        const path_len = std.mem.indexOfScalar(u8, &path_buf, 0) orelse return error.OpenPtyFailed;
        const slave_path = path_buf[0..path_len :0];

        // Open the slave before setting the size: macOS rejects
        // TIOCSWINSZ on the master until the slave has been opened.
        const slave = posix.openZ(slave_path, .{
            .ACCMODE = .RDWR,
            .NOCTTY = true,
        }, 0) catch return error.OpenPtyFailed;
        errdefer posix.close(slave);

        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (ioctl(slave, Tio.IOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }

        // Exec args, prepared before fork.
        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const argv0 = try arena.dupeSentinel(u8, program, 0);
        const argv_z = try arena.allocSentinel(?[*:0]const u8, argv.len + 1, null);
        argv_z[0] = argv0;
        for (argv, 1..) |arg, i| argv_z[i] = try arena.dupeSentinel(u8, arg, 0);

        var env = try posix.environMap(arena);
        // A test run from inside a lantern tab would otherwise inherit LANTERN
        // and trip the nested-lantern guard; never leak the harness's own
        // session state into the child.
        _ = env.swapRemove("LANTERN");
        _ = env.swapRemove("LANTERN_FOREGROUND");
        try env.put("LANTERN_DIR", harness.dir);
        for (env_extra) |pair| try env.put(pair[0], pair[1]);
        const envp = (try env.createPosixBlock(arena, .{})).slice;

        const pid = try posix.fork();
        if (pid == 0) {
            // Child: make the inherited PTY slave the controlling
            // terminal (login_tty pattern).
            _ = posix.setsid() catch posix.exit(127);
            if (ioctl(slave, Tio.IOCSCTTY, @as(c_ulong, 0)) != 0) {
                posix.exit(127);
            }
            posix.dup2(slave, 0) catch posix.exit(127);
            posix.dup2(slave, 1) catch posix.exit(127);
            posix.dup2(slave, 2) catch posix.exit(127);
            if (slave > 2) posix.close(slave);
            posix.close(master);
            const err = posix.execveZ(argv0, argv_z, envp.ptr);
            _ = err catch {};
            posix.exit(127);
        }

        posix.close(slave);
        return .{ .alloc = alloc, .master = master, .pid = pid };
    }

    fn deinit(self: *PtyClient) void {
        if (self.exited == null) {
            _ = kill(self.pid, @intCast(@intFromEnum(posix.SIG.KILL)));
            var status: c_int = undefined;
            _ = std.c.waitpid(self.pid, &status, 0);
        }
        posix.close(self.master);
        self.output.deinit(self.alloc);
    }

    fn send(self: *PtyClient, bytes: []const u8) !void {
        var i: usize = 0;
        while (i < bytes.len) i += try posix.write(self.master, bytes[i..]);
    }

    /// Type text into the session, followed by Enter.
    fn sendLine(self: *PtyClient, text: []const u8) !void {
        try self.send(text);
        try self.send("\r");
    }

    fn setSize(self: *PtyClient, rows: u16, cols: u16) !void {
        const ws: posix.winsize = .{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
        if (ioctl(self.master, Tio.IOCSWINSZ, @intFromPtr(&ws)) != 0) {
            return error.IoctlFailed;
        }
    }

    fn pump(self: *PtyClient, timeout_ms: i32) !bool {
        var fds = [_]posix.pollfd{
            .{ .fd = self.master, .events = posix.POLL.IN, .revents = 0 },
        };
        const n = try posix.poll(&fds, timeout_ms);
        if (n == 0) return false;
        var buf: [4096]u8 = undefined;
        const got = posix.read(self.master, &buf) catch |err| switch (err) {
            error.InputOutput => return error.ClientGone,
            else => return err,
        };
        if (got == 0) return error.ClientGone;
        try self.output.appendSlice(self.alloc, buf[0..got]);
        return true;
    }

    /// Read output until `needle` appears anywhere in the accumulated
    /// stream. Fails loudly with the captured output on timeout.
    fn waitFor(self: *PtyClient, needle: []const u8) !void {
        var deadline = Deadline.init(default_timeout_ms);
        while (std.mem.indexOf(u8, self.output.items, needle) == null) {
            _ = self.pump(100) catch |err| switch (err) {
                error.ClientGone => {
                    if (std.mem.indexOf(u8, self.output.items, needle) != null) return;
                    std.debug.print(
                        "client exited; output so far:\n{s}\n",
                        .{self.output.items},
                    );
                    return err;
                },
                else => return err,
            };
            deadline.tick("waiting for output") catch |err| {
                std.debug.print(
                    "--- waiting for {s} --- captured:\n{s}\n---\n",
                    .{ needle, self.output.items },
                );
                return err;
            };
        }
    }

    /// Drop accumulated output so later waitFor calls only see new data.
    fn clearOutput(self: *PtyClient) void {
        self.output.clearRetainingCapacity();
    }

    /// Keep reading until the PTY reports the client is gone, so final
    /// output (like the terminal restore sequence) is captured. Bounded
    /// so a still-running client cannot hang the test.
    fn drain(self: *PtyClient) void {
        const end = posix.milliTimestamp() + 2000;
        while (posix.milliTimestamp() < end) {
            _ = self.pump(100) catch return;
        }
    }

    /// Read and discard output for roughly `ms`, letting the client
    /// process asynchronous events (like SIGWINCH) before the next
    /// assertion.
    fn pumpFor(self: *PtyClient, ms: u64) void {
        const end = posix.milliTimestamp() + @as(i64, @intCast(ms));
        while (posix.milliTimestamp() < end) {
            _ = self.pump(25) catch return;
        }
    }

    fn waitExit(self: *PtyClient) !u32 {
        if (self.exited) |code| return code;
        var deadline = Deadline.init(default_timeout_ms);
        while (true) {
            var status: c_int = undefined;
            const r = std.c.waitpid(self.pid, &status, std.c.W.NOHANG);
            if (r == self.pid) {
                const code: u32 = if (std.c.W.IFEXITED(@bitCast(status)))
                    std.c.W.EXITSTATUS(@bitCast(status))
                else
                    128;
                self.exited = code;
                return code;
            }
            // Keep draining the PTY so the client can't block on writes.
            _ = self.pump(0) catch {};
            try deadline.tick("waiting for client exit");
        }
    }
};

/// Render raw client output through a terminal emulator and return the
/// resulting screen text, one line per row. Raw byte matching cannot
/// tell whether content survives on screen (a later erase can remove
/// it); this can.
fn renderScreen(
    alloc: std.mem.Allocator,
    bytes: []const u8,
    rows: u16,
    cols: u16,
) ![]const u8 {
    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = cols, .rows = rows });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    return term.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
}

/// The rendered screen's first row, which holds the tab bar (and the
/// status overlay when one is active).
fn firstRow(alloc: std.mem.Allocator, ui: *PtyClient, rows: u16, cols: u16) ![]u8 {
    const screen = try renderScreen(alloc, ui.output.items, rows, cols);
    defer alloc.free(screen);
    var lines = std.mem.splitScalar(u8, screen, '\n');
    return alloc.dupe(u8, lines.next() orelse "");
}

/// A cell position on the rendered screen.
const ScreenPos = struct { row: u16, col: u16 };

/// The 0-based screen cell of the last occurrence of `needle` in the
/// rendered screen. Used to aim a mouse press at real viewport text.
fn findText(
    alloc: std.mem.Allocator,
    ui: *PtyClient,
    rows: u16,
    cols: u16,
    needle: []const u8,
) !ScreenPos {
    const screen = try renderScreen(alloc, ui.output.items, rows, cols);
    defer alloc.free(screen);
    var lines = std.mem.splitScalar(u8, screen, '\n');
    var best: ?ScreenPos = null;
    var i: u16 = 0;
    while (lines.next()) |line| : (i += 1) {
        if (std.mem.lastIndexOf(u8, line, needle)) |col| {
            best = .{ .row = i, .col = @intCast(col) };
        }
    }
    return best orelse error.NeedleMissing;
}

/// Drag a left-button selection across `len` cells starting at the last
/// occurrence of `needle`, then release. SGR coordinates are 1-based;
/// the viewport starts at row 1, column 1.
fn dragSelectText(
    alloc: std.mem.Allocator,
    ui: *PtyClient,
    rows: u16,
    cols: u16,
    needle: []const u8,
    len: u16,
) !void {
    const at = try findText(alloc, ui, rows, cols, needle);
    const y = at.row + 1;
    const x0 = at.col + 1;
    const x1 = at.col + len;
    var buf: [32]u8 = undefined;
    try ui.send(try std.fmt.bufPrint(&buf, "\x1b[<0;{d};{d}M", .{ x0, y }));
    try ui.send(try std.fmt.bufPrint(&buf, "\x1b[<32;{d};{d}M", .{ x1, y }));
    try ui.send(try std.fmt.bufPrint(&buf, "\x1b[<0;{d};{d}m", .{ x1, y }));
}

/// Pump the client until the rendered screen's first row contains
/// every needle (or, for `absent`, none of them).
fn waitFirstRow(
    alloc: std.mem.Allocator,
    ui: *PtyClient,
    rows: u16,
    cols: u16,
    present: []const []const u8,
    absent: []const []const u8,
) !void {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const screen = try renderScreen(alloc, ui.output.items, rows, cols);
        defer alloc.free(screen);
        var lines = std.mem.splitScalar(u8, screen, '\n');
        const first: []const u8 = lines.next() orelse "";

        var ok = true;
        for (present) |needle| {
            if (std.mem.indexOf(u8, first, needle) == null) ok = false;
        }
        for (absent) |needle| {
            if (std.mem.indexOf(u8, first, needle) != null) ok = false;
        }
        if (ok) return;

        _ = try ui.pump(100);
        deadline.tick("waiting for the top row") catch |err| {
            std.debug.print("--- top row --- {s}\n", .{first});
            return err;
        };
    }
}

/// Pump for a short window and assert no OSC 52 clipboard write carrying
/// `text` reached the client's output.
fn expectNoCopy(ui: *PtyClient, text: []const u8) !void {
    ui.pumpFor(300);
    var b64_buf: [64]u8 = undefined;
    const expected = std.base64.standard.Encoder.encode(&b64_buf, text);
    try std.testing.expect(std.mem.indexOf(u8, ui.output.items, expected) == null);
}

/// Pump output until the rendered screen contains every `present`
/// needle and none of the `absent` ones.
fn waitScreen(
    alloc: std.mem.Allocator,
    ui: *PtyClient,
    rows: u16,
    cols: u16,
    present: []const []const u8,
    absent: []const []const u8,
) !void {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        const screen = try renderScreen(alloc, ui.output.items, rows, cols);
        defer alloc.free(screen);

        var ok = true;
        for (present) |needle| {
            if (std.mem.indexOf(u8, screen, needle) == null) ok = false;
        }
        for (absent) |needle| {
            if (std.mem.indexOf(u8, screen, needle) != null) ok = false;
        }
        if (ok) return;

        _ = try ui.pump(100);
        deadline.tick("waiting for the screen") catch |err| {
            std.debug.print("--- screen ---\n{s}\n", .{screen});
            return err;
        };
    }
}

/// Left-press on the `index`-th (0-based) tab in the bar, regardless of
/// its title. Titles are rendered as " <title> ", so tabs are the labels
/// separated by the two spaces where one label's trailing space meets
/// the next one's leading space.
fn clickTabBarIndex(
    alloc: std.mem.Allocator,
    ui: *PtyClient,
    rows: u16,
    cols: u16,
    index: usize,
) !void {
    const row = try firstRow(alloc, ui, rows, cols);
    defer alloc.free(row);
    var start: usize = 1; // first label's text, after its leading space
    var i: usize = 0;
    while (i < index) : (i += 1) {
        const sep = std.mem.indexOf(u8, row[start..], "  ") orelse {
            std.debug.print("--- tab bar --- {s}\n", .{row});
            return error.NeedleMissing;
        };
        start += sep + 2;
    }
    if (start >= row.len) return error.NeedleMissing;
    var buf: [32]u8 = undefined;
    // The tab bar is the top row, so the click lands on row 1.
    const seq = try std.fmt.bufPrint(&buf, "\x1b[<0;{d};1M", .{start + 1});
    try ui.send(seq);
}

/// How many tabs the rendered top row shows. Labels look like
/// " title " and are concatenated, so tabs are separated by two spaces.
fn tabCount(alloc: std.mem.Allocator, ui: *PtyClient, rows: u16, cols: u16) !usize {
    const row = try firstRow(alloc, ui, rows, cols);
    defer alloc.free(row);
    const body = std.mem.trim(u8, row, " ");
    if (body.len == 0) return 0;
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, body, "  ");
    while (it.next()) |part| {
        if (std.mem.trim(u8, part, " ").len > 0) count += 1;
    }
    return count;
}

/// Pump the client until the bar shows exactly `want` tabs.
fn waitTabCount(
    alloc: std.mem.Allocator,
    ui: *PtyClient,
    rows: u16,
    cols: u16,
    want: usize,
) !void {
    var deadline = Deadline.init(default_timeout_ms);
    while (true) {
        if (try tabCount(alloc, ui, rows, cols) == want) return;
        _ = try ui.pump(100);
        deadline.tick("waiting for tab count") catch |err| {
            const row = try firstRow(alloc, ui, rows, cols);
            defer alloc.free(row);
            std.debug.print("--- tab bar --- {s}\n", .{row});
            return err;
        };
    }
}

/// Spawn a UI client against the harness's session.
fn spawnUi(harness: *Harness, rows: u16, cols: u16) !PtyClient {
    return PtyClient.spawnProgram(harness, exe_path, &.{}, rows, cols, &.{
        .{ "SHELL", "/bin/sh" },
        .{ "PS1", "" },
    });
}

/// Start the daemon and open a UI on it, waiting for the first tab bar.
fn boot(harness: *Harness, rows: u16, cols: u16) !PtyClient {
    try harness.startDaemon(rows, cols);
    var ui = try spawnUi(harness, rows, cols);
    errdefer ui.deinit();
    try waitTabCount(harness.alloc, &ui, rows, cols, 1);
    return ui;
}

// -- CLI -------------------------------------------------------------------

test "version prints the version" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const result = try h.run(&.{"version"});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "lantern 0.") != null);
}

test "help overview and topic pages" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const overview = try h.run(&.{"help"});
    defer alloc.free(overview.stdout);
    defer alloc.free(overview.stderr);
    try std.testing.expect(overview.term == .exited and overview.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "one session, many tabs") != null);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "C-w r") != null);
    // The removed multi-session commands must not be advertised.
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "lantern attach") == null);
    try std.testing.expect(std.mem.indexOf(u8, overview.stdout, "lantern ls") == null);

    const keys = try h.run(&.{ "help", "keys" });
    defer alloc.free(keys.stdout);
    defer alloc.free(keys.stderr);
    try std.testing.expect(keys.term == .exited and keys.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, keys.stdout, "C-w w") != null);

    const version = try h.run(&.{ "help", "version" });
    defer alloc.free(version.stdout);
    defer alloc.free(version.stderr);
    try std.testing.expect(version.term == .exited and version.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, version.stdout, "lantern version") != null);
}

test "help --all prints every page" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    const all = try h.run(&.{ "help", "--all" });
    defer alloc.free(all.stdout);
    defer alloc.free(all.stderr);
    try std.testing.expect(all.term == .exited and all.term.exited == 0);
    try std.testing.expect(std.mem.indexOf(u8, all.stdout, "one session, many tabs") != null);
    try std.testing.expect(std.mem.indexOf(u8, all.stdout, "lantern version") != null);
    try std.testing.expect(std.mem.indexOf(u8, all.stdout, "Key bindings") != null);
}

test "unknown command exits with a usage error" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();
    try h.runExit(&.{"frobnicate"}, 2);
}

test "launch without a terminal fails cleanly" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    // Child.run gives the process a pipe on stdin, not a TTY.
    const result = try h.run(&.{});
    defer alloc.free(result.stdout);
    defer alloc.free(result.stderr);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stderr, "requires a terminal") != null);
}

test "a second launch attaches alongside the first, sharing the session" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var first = try boot(&h, 24, 80);
    defer first.deinit();

    // Even with the marker a tab's shell inherits, a second launch must
    // attach to the existing session instead of refusing.
    var second = try PtyClient.spawnProgram(&h, exe_path, &.{}, 24, 80, &.{
        .{ "LANTERN", "1" },
        .{ "SHELL", "/bin/sh" },
        .{ "PS1", "" },
    });
    defer second.deinit();

    // Both clients are attached to the same session: the second sees the
    // existing tab, and the first is neither stolen nor detached.
    try waitTabCount(alloc, &second, 24, 80, 1);
    try waitTabCount(alloc, &first, 24, 80, 1);

    // Input from either client reaches the shared shell, and its output
    // is broadcast to both.
    try first.sendLine("echo SHARED-1");
    try waitScreen(alloc, &first, 24, 80, &.{"SHARED-1"}, &.{});
    try waitScreen(alloc, &second, 24, 80, &.{"SHARED-1"}, &.{});
    try second.sendLine("echo SHARED-2");
    try waitScreen(alloc, &second, 24, 80, &.{"SHARED-2"}, &.{});
    try waitScreen(alloc, &first, 24, 80, &.{"SHARED-2"}, &.{});
}

test "two clients keep independent active tabs" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var first = try boot(&h, 24, 80);
    defer first.deinit();

    // Tag tab 1, then open tab 2 (which becomes this client's active tab)
    // and tag it too.
    try first.sendLine("echo ONE");
    try waitScreen(alloc, &first, 24, 80, &.{"ONE"}, &.{});
    try first.send("\x17r");
    try waitTabCount(alloc, &first, 24, 80, 2);
    try first.sendLine("echo TWO");
    try waitScreen(alloc, &first, 24, 80, &.{"TWO"}, &.{});

    // A second client attaches. It starts on the session's last-focused
    // tab (tab 2), where TWO lives.
    var second = try spawnUi(&h, 24, 80);
    defer second.deinit();
    try waitTabCount(alloc, &second, 24, 80, 2);
    try waitScreen(alloc, &second, 24, 80, &.{"TWO"}, &.{});

    // The first client switches to tab 1. The second is not affected:
    // it keeps showing its own tab 2, so each client has an independent
    // active tab (tmux-style).
    try first.send("\x171");
    try waitScreen(alloc, &first, 24, 80, &.{"ONE"}, &.{});
    try waitScreen(alloc, &second, 24, 80, &.{"TWO"}, &.{});
}

test "one client quitting ends the session for every client" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var first = try boot(&h, 24, 80);
    defer first.deinit();

    var second = try spawnUi(&h, 24, 80);
    defer second.deinit();
    try waitTabCount(alloc, &second, 24, 80, 1);

    // The second client ends the whole session (C-w d, answered y).
    try second.send("\x17\x04");
    try waitFirstRow(alloc, &second, 24, 80, &.{"quit? y/N"}, &.{});
    try second.send("y");

    // Every client exits: the session is gone, so the first must not be
    // left stranded on a landing screen with a dead socket.
    try std.testing.expectEqual(@as(u32, 0), try second.waitExit());
    try std.testing.expectEqual(@as(u32, 0), try first.waitExit());
    try std.testing.expectEqual(@as(u32, 0), try h.daemon.?.waitExit());
}

test "a UI exits when the daemon dies unexpectedly" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    // Kill the daemon out from under the client, with no `.exit` notice.
    const pid = h.daemon.?.pid;
    posix.kill(pid, posix.SIG.KILL) catch {};

    // The client notices the dead session and exits rather than sitting
    // on a landing screen whose socket can never carry another message.
    _ = try ui.waitExit();
    try std.testing.expect(!h.socketUp());
}

// -- The UI: first launch ----------------------------------------------

test "first launch starts one shell tab with a bar" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    // The UI renders on the alternate screen, like a real attached view.
    try std.testing.expect(std.mem.indexOf(u8, ui.output.items, "\x1b[?1049h") != null);

    // The tab bar lists tab 1; input reaches the shell in that tab.
    try ui.sendLine("echo READY");
    try waitScreen(alloc, &ui, 24, 80, &.{"READY"}, &.{});
}

test "a new tab is named for its working directory" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    // Move the active shell into a distinctively named folder, then open
    // a tab there: its label is the folder's name.
    const folder = try std.fs.path.join(alloc, &.{ h.dir, "workfolder" });
    defer alloc.free(folder);
    try posix.makePath(folder);

    const cmd = try std.fmt.allocPrint(alloc, "cd {s} && echo CHDIR-OK", .{folder});
    defer alloc.free(cmd);
    try ui.sendLine(cmd);
    try waitScreen(alloc, &ui, 24, 80, &.{"CHDIR-OK"}, &.{});

    try ui.send("\x17r");
    try waitFirstRow(alloc, &ui, 24, 80, &.{" workfolder "}, &.{});
    try waitTabCount(alloc, &ui, 24, 80, 2);
}

test "an application title does not replace the tab name" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    // Open a tab in a distinctively named folder.
    const folder = try std.fs.path.join(alloc, &.{ h.dir, "workfolder" });
    defer alloc.free(folder);
    try posix.makePath(folder);
    const cmd = try std.fmt.allocPrint(alloc, "cd {s} && echo CHDIR-OK", .{folder});
    defer alloc.free(cmd);
    try ui.sendLine(cmd);
    try waitScreen(alloc, &ui, 24, 80, &.{"CHDIR-OK"}, &.{});
    try ui.send("\x17r");
    try waitFirstRow(alloc, &ui, 24, 80, &.{" workfolder "}, &.{});

    // An OSC 2 window title (nushell restamps one on every prompt) must
    // not replace the folder name in the bar. Follow it with visible
    // output so we know the sequence was parsed before checking.
    try ui.sendLine("printf '\\033]2;HIJACKED\\007'");
    try ui.sendLine("echo AFTER-OSC");
    try waitScreen(alloc, &ui, 24, 80, &.{"AFTER-OSC"}, &.{});
    try waitFirstRow(alloc, &ui, 24, 80, &.{" workfolder "}, &.{"HIJACKED"});
}

test "C-w r opens a tab and focus follows it" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.send("\x17r");
    try waitTabCount(alloc, &ui, 24, 80, 2);

    // The new tab is active: typed input lands there.
    try ui.sendLine("echo SECOND");
    try waitScreen(alloc, &ui, 24, 80, &.{"SECOND"}, &.{});

    // Switching back to tab 1 shows a screen without tab 2's output.
    try ui.send("\x17\x1b[Z");
    try waitScreen(alloc, &ui, 24, 80, &.{}, &.{"SECOND"});
}

test "C-w Tab and C-w Shift-Tab cycle through tabs" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    // Three tabs: 1 (untouched), 2, 3 with a marker on 3.
    try ui.send("\x17r");
    try ui.send("\x17r");
    try waitTabCount(alloc, &ui, 24, 80, 3);
    try ui.sendLine("echo THREE");
    try waitScreen(alloc, &ui, 24, 80, &.{"THREE"}, &.{});

    // C-w Shift-Tab: 3 -> 2 (a fresh shell, no marker).
    try ui.send("\x17\x1b[Z");
    try waitScreen(alloc, &ui, 24, 80, &.{}, &.{"THREE"});
    // C-w Shift-Tab: 2 -> 1.
    try ui.send("\x17\x1b[Z");
    try ui.sendLine("echo ONE");
    try waitScreen(alloc, &ui, 24, 80, &.{"ONE"}, &.{});
    // C-w Tab: 1 -> 2 (still empty, not 3).
    try ui.send("\x17\t");
    try waitScreen(alloc, &ui, 24, 80, &.{}, &.{ "ONE", "THREE" });
    // C-w Tab: 2 -> 3.
    try ui.send("\x17\t");
    try waitScreen(alloc, &ui, 24, 80, &.{"THREE"}, &.{"ONE"});
}

test "C-w 1..9 selects a tab by number" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.send("\x17r");
    try ui.send("\x17r");
    try ui.sendLine("echo THIRD");
    try waitScreen(alloc, &ui, 24, 80, &.{"THIRD"}, &.{});

    try ui.send("\x171");
    try waitScreen(alloc, &ui, 24, 80, &.{}, &.{"THIRD"});
    try ui.send("\x173");
    try waitScreen(alloc, &ui, 24, 80, &.{"THIRD"}, &.{});
}

test "C-w C-w returns to the previously active tab" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.send("\x17r");
    try ui.sendLine("echo TWO");
    try waitScreen(alloc, &ui, 24, 80, &.{"TWO"}, &.{});

    // Switch to tab 1 (records tab 2 as the previous tab), then jump
    // back with C-w C-w.
    try ui.send("\x17\x1b[Z");
    try waitScreen(alloc, &ui, 24, 80, &.{}, &.{"TWO"});
    try ui.send("\x17\x17");
    try waitScreen(alloc, &ui, 24, 80, &.{"TWO"}, &.{});
}

test "C-w l redraws without losing the tab bar" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.sendLine("echo KEEP");
    try waitScreen(alloc, &ui, 24, 80, &.{"KEEP"}, &.{});
    try ui.send("\x17l");
    try waitScreen(alloc, &ui, 24, 80, &.{"KEEP"}, &.{});
    try waitTabCount(alloc, &ui, 24, 80, 1);
}

// -- Closing tabs ----------------------------------------------------------

test "C-w w closes the active tab" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.send("\x17r");
    try waitTabCount(alloc, &ui, 24, 80, 2);

    try ui.send("\x17w");
    try waitTabCount(alloc, &ui, 24, 80, 1);
}

test "closing the last tab keeps the session on the landing" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.send("\x17w");

    // The session outlives its last tab: the UI stays up on the landing
    // and the daemon keeps the socket, ready for a fresh tab.
    try waitScreen(alloc, &ui, 24, 80, &.{"create new tab to start"}, &.{});
    try waitTabCount(alloc, &ui, 24, 80, 0);
    try std.testing.expect(h.socketUp());

    // The hint works: Ctrl+W r opens a new tab on the live session.
    try ui.send("\x17r");
    try waitTabCount(alloc, &ui, 24, 80, 1);
    try waitScreen(alloc, &ui, 24, 80, &.{}, &.{"create new tab to start"});
}

test "C-w C-d asks, then y ends the session and closes the UI" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    // Ctrl-D after the prefix asks first; nothing has ended yet.
    try ui.send("\x17\x04");
    try waitFirstRow(alloc, &ui, 24, 80, &.{"quit? y/N"}, &.{});
    try std.testing.expect(h.socketUp());

    // 'n' cancels and leaves the session running: the prompt clears.
    try ui.send("n");
    try waitFirstRow(alloc, &ui, 24, 80, &.{}, &.{"quit? y/N"});
    try std.testing.expect(h.socketUp());

    // Asking again and answering y kills the whole session: the UI and
    // the daemon both exit and the socket goes away.
    try ui.send("\x17\x04");
    try waitFirstRow(alloc, &ui, 24, 80, &.{"quit? y/N"}, &.{});
    try ui.send("y");
    const code = try ui.waitExit();
    try std.testing.expectEqual(@as(u32, 0), code);
    const daemon_code = try h.daemon.?.waitExit();
    try std.testing.expectEqual(@as(u32, 0), daemon_code);
    try std.testing.expect(!h.socketUp());
}

test "a tab's shell exiting removes it from the bar" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.send("\x17r");
    try ui.sendLine("echo GONE");
    try waitScreen(alloc, &ui, 24, 80, &.{"GONE"}, &.{});
    try ui.sendLine("exit");
    try waitTabCount(alloc, &ui, 24, 80, 1);
}

// -- Persistence -----------------------------------------------------------

test "detach leaves tabs running and reattach restores them" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    // Tab 2 (active) and tab 1 each get a shell variable.
    try ui.send("\x17r");
    try waitTabCount(alloc, &ui, 24, 80, 2);
    try ui.sendLine("M2=two");
    try ui.sendLine("echo PRE=$M2");
    try waitScreen(alloc, &ui, 24, 80, &.{"PRE=two"}, &.{});
    try ui.send("\x17\x1b[Z");
    try ui.sendLine("M1=one");
    try ui.sendLine("echo PRE=$M1");
    try waitScreen(alloc, &ui, 24, 80, &.{"PRE=one"}, &.{"PRE=two"});

    // Detach: the UI exits, the daemon keeps running.
    try ui.send("\x17\x11");
    const code = try ui.waitExit();
    try std.testing.expectEqual(@as(u32, 0), code);
    try std.testing.expect(h.socketUp());

    // Reattach: both tabs are back with their shell state.
    var ui2 = try spawnUi(&h, 24, 80);
    defer ui2.deinit();
    try waitTabCount(alloc, &ui2, 24, 80, 2);

    // Tab 1 was focused last.
    try ui2.sendLine("echo A=$M1");
    try waitScreen(alloc, &ui2, 24, 80, &.{"A=one"}, &.{});
    try ui2.send("\x17\t");
    try ui2.sendLine("echo B=$M2");
    try waitScreen(alloc, &ui2, 24, 80, &.{"B=two"}, &.{});
}

// -- Selection -------------------------------------------------------------

test "dragging selects text and C-w y copies it" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.sendLine("printf 'COPYME\\n'");
    try waitScreen(alloc, &ui, 24, 80, &.{"COPYME"}, &.{});

    try dragSelectText(alloc, &ui, 24, 80, "COPYME", 6);

    // The selection survives the release: C-w y copies it (rather than
    // doing nothing, as it would if the release had already cleared or
    // consumed the selection).
    try ui.send("\x17y");

    // The copy leaves the viewport as an OSC 52 clipboard write.
    var b64_buf: [16]u8 = undefined;
    const expected = std.base64.standard.Encoder.encode(&b64_buf, "COPYME");
    var deadline = Deadline.init(default_timeout_ms);
    while (std.mem.indexOf(u8, ui.output.items, expected) == null) {
        _ = try ui.pump(100);
        try deadline.tick("waiting for the OSC 52 copy");
    }
}

test "Ctrl+C copies a live selection instead of interrupting" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.sendLine("printf 'CTRLCME\\n'");
    try waitScreen(alloc, &ui, 24, 80, &.{"CTRLCME"}, &.{});

    try dragSelectText(alloc, &ui, 24, 80, "CTRLCME", 7);

    // Ctrl+C with the selection live copies it (OSC 52), the way a GUI
    // app would, rather than interrupting the shell.
    try ui.send("\x03");

    var b64_buf: [16]u8 = undefined;
    const expected = std.base64.standard.Encoder.encode(&b64_buf, "CTRLCME");
    var deadline = Deadline.init(default_timeout_ms);
    while (std.mem.indexOf(u8, ui.output.items, expected) == null) {
        _ = try ui.pump(100);
        try deadline.tick("waiting for the Ctrl+C OSC 52 copy");
    }
}

test "typing clears the selection" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.sendLine("printf 'CLEARME\\n'");
    try waitScreen(alloc, &ui, 24, 80, &.{"CLEARME"}, &.{});

    try dragSelectText(alloc, &ui, 24, 80, "CLEARME", 7);

    // A keystroke headed for the shell dismisses the highlight, so the
    // copy binding finds nothing to copy.
    try ui.send("x");
    try ui.send("\x17y");
    try expectNoCopy(&ui, "CLEARME");
}

test "a plain click does not leave a selection" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.sendLine("printf 'CLICKME\\n'");
    try waitScreen(alloc, &ui, 24, 80, &.{"CLICKME"}, &.{});
    const at = try findText(alloc, &ui, 24, 80, "CLICKME");

    // Press and release on one cell: no drag, so nothing is selected.
    var buf: [32]u8 = undefined;
    const y = at.row + 1;
    const x = at.col + 1;
    try ui.send(try std.fmt.bufPrint(&buf, "\x1b[<0;{d};{d}M", .{ x, y }));
    try ui.send(try std.fmt.bufPrint(&buf, "\x1b[<0;{d};{d}m", .{ x, y }));

    try ui.send("\x17y");
    try expectNoCopy(&ui, "CLICKME");
}

// -- Kitty graphics --------------------------------------------------------

test "kitty graphics from the session reach the real terminal" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    // Transmit a 1x1 RGBA image and place it at the cursor. q=2 keeps a
    // successful transmission quiet, matching what image viewers send.
    try ui.sendLine(
        "printf '\\033_Ga=t,f=32,s=1,v=1,i=9,q=2;AAAAAA==\\033\\\\\\033_Ga=p,i=9,c=1,r=1,C=1\\033\\\\'",
    );

    // The UI paints the session itself, so the image reaches the real
    // terminal only through the re-emitter. The echoed command in the
    // viewport spells the escapes literally, so an ESC-led match in the
    // client's output can only be the re-emitted APC.
    var deadline = Deadline.init(default_timeout_ms);
    while (std.mem.indexOf(u8, ui.output.items, "\x1b_Ga=t") == null or
        std.mem.indexOf(u8, ui.output.items, "\x1b_Ga=p") == null)
    {
        _ = try ui.pump(100);
        try deadline.tick("waiting for re-emitted kitty graphics");
    }
}

// -- Mouse -----------------------------------------------------------------

test "clicking a tab in the bar focuses it" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.send("\x17r");
    try ui.sendLine("echo TWO");
    try waitScreen(alloc, &ui, 24, 80, &.{"TWO"}, &.{});

    // Click tab 1; the screen switches to tab 1 (no TWO).
    try clickTabBarIndex(alloc, &ui, 24, 80, 0);
    try waitScreen(alloc, &ui, 24, 80, &.{}, &.{"TWO"});

    // Click tab 2; its output returns.
    try clickTabBarIndex(alloc, &ui, 24, 80, 1);
    try waitScreen(alloc, &ui, 24, 80, &.{"TWO"}, &.{});
}

// -- Sizing and teardown ---------------------------------------------------

test "resizing the terminal resizes the tabs" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    // The viewport is the terminal minus the one-row tab bar.
    try ui.sendLine("stty size");
    try waitScreen(alloc, &ui, 24, 80, &.{"23 80"}, &.{});

    try ui.setSize(30, 100);
    // Let the UI process the resize and push it to the daemon before
    // the shell reports its new size.
    ui.pumpFor(500);
    try ui.sendLine("stty size");
    try waitScreen(alloc, &ui, 30, 100, &.{"29 100"}, &.{});
}

test "detaching restores the terminal's alternate screen" {
    const alloc = std.testing.allocator;
    var h = try Harness.init(alloc);
    defer h.deinit();

    var ui = try boot(&h, 24, 80);
    defer ui.deinit();

    try ui.send("\x17q");
    const code = try ui.waitExit();
    try std.testing.expectEqual(@as(u32, 0), code);
    // Wait for the PTY to reach EOF so trailing restore bytes are read.
    ui.drain();
    try std.testing.expect(std.mem.indexOf(u8, ui.output.items, "\x1b[?1049l") != null);
}
