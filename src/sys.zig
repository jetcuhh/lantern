//! POSIX syscalls, over libc.
//!
//! Zig 0.17 moved the filesystem and process APIs onto the `std.Io`
//! interface and removed most of the raw syscall wrappers from `std.posix`.
//! lantern is a single-threaded poll loop over non-blocking descriptors: it
//! wants the plain syscalls, and it needs `EAGAIN` to surface as
//! `error.WouldBlock` immediately rather than parking a fiber. This module
//! keeps that surface in one place.

const std = @import("std");
const builtin = @import("builtin");
const c = std.c;

// -- Types and constants re-exported from std.posix -----------------------

pub const fd_t = std.posix.fd_t;
pub const pid_t = std.posix.pid_t;
pub const uid_t = std.posix.uid_t;
pub const mode_t = std.posix.mode_t;
pub const socklen_t = std.posix.socklen_t;
pub const sockaddr = std.posix.sockaddr;
pub const pollfd = std.posix.pollfd;
pub const winsize = std.posix.winsize;
pub const termios = std.posix.termios;
pub const Sigaction = std.posix.Sigaction;
pub const sigset_t = std.posix.sigset_t;

pub const O = std.posix.O;
pub const F = std.posix.F;
pub const S = std.posix.S;
pub const AT = std.posix.AT;
pub const SIG = std.posix.SIG;
pub const SA = std.posix.SA;
pub const AF = std.posix.AF;
pub const SOCK = std.posix.SOCK;
pub const POLL = std.posix.POLL;
pub const LOCK = std.posix.LOCK;
pub const V = std.posix.V;

pub const FD_CLOEXEC = std.posix.FD_CLOEXEC;
pub const STDIN_FILENO = std.posix.STDIN_FILENO;
pub const STDOUT_FILENO = std.posix.STDOUT_FILENO;
pub const STDERR_FILENO = std.posix.STDERR_FILENO;

/// Still provided by std.posix; re-exported so callers have one import.
pub const poll = std.posix.poll;
pub const read = std.posix.read;
pub const sigaction = std.posix.sigaction;
pub const sigemptyset = std.posix.sigemptyset;
pub const tcgetattr = std.posix.tcgetattr;
pub const tcsetattr = std.posix.tcsetattr;
pub const kill = std.posix.kill;

pub const Unexpected = std.posix.UnexpectedError;

const unexpectedErrno = std.posix.unexpectedErrno;

/// The metadata lantern needs: enough to refuse an insecure socket
/// directory, and nothing more. Zig 0.17 dropped a portable `Stat`.
pub const Stat = struct {
    mode: u32,
    uid: uid_t,

    pub fn isDir(self: Stat) bool {
        return (self.mode & S.IFMT) == S.IFDIR;
    }
};

// -- Helpers --------------------------------------------------------------

/// Copy `path` into `buf` and NUL-terminate it. Every syscall below takes a
/// C string; the conversion lives here so callers keep slices.
fn toZ(path: []const u8, buf: []u8) error{NameTooLong}![*:0]const u8 {
    if (path.len >= buf.len) return error.NameTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0].ptr;
}

// -- File descriptors -----------------------------------------------------

/// Write, retrying on EINTR. `EAGAIN` is `error.WouldBlock`: the daemon
/// treats it as "try again when the fd is writable", never as a failure.
pub fn write(fd: fd_t, bytes: []const u8) !usize {
    while (true) {
        const rc = c.write(fd, bytes.ptr, bytes.len);
        switch (c.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            .AGAIN => return error.WouldBlock,
            .BADF => return error.BadFileDescriptor,
            .FAULT => unreachable, // our own buffer
            .INVAL => return error.InvalidArgument,
            .IO => return error.InputOutput,
            .NOSPC => return error.NoSpaceLeft,
            .PIPE => return error.BrokenPipe,
            .CONNRESET => return error.ConnectionResetByPeer,
            .ACCES => return error.AccessDenied,
            else => |err| return unexpectedErrno(err),
        }
    }
}

pub fn close(fd: fd_t) void {
    // A close failure cannot be acted on: the descriptor is gone either way.
    _ = c.close(fd);
}

pub fn exit(code: u8) noreturn {
    c.exit(code);
}

pub fn dup(fd: fd_t) !fd_t {
    const rc = c.dup(fd);
    if (rc < 0) return unexpectedErrno(c.errno(rc));
    return rc;
}

pub fn dup2(old: fd_t, new: fd_t) !void {
    const rc = c.dup2(old, new);
    if (rc < 0) return unexpectedErrno(c.errno(rc));
}

pub fn pipe() ![2]fd_t {
    var fds: [2]fd_t = undefined;
    const rc = c.pipe(&fds);
    if (rc < 0) return unexpectedErrno(c.errno(rc));
    return fds;
}

pub fn pipe2(flags: O) ![2]fd_t {
    var fds: [2]fd_t = undefined;
    const rc = c.pipe2(&fds, @bitCast(flags));
    if (rc < 0) return unexpectedErrno(c.errno(rc));
    return fds;
}

pub fn openZ(path: [*:0]const u8, flags: O, mode: mode_t) !fd_t {
    const rc = c.open(path, flags, mode);
    if (rc >= 0) return rc;
    switch (c.errno(rc)) {
        .ACCES, .PERM => return error.AccessDenied,
        .AGAIN => return error.WouldBlock,
        .BUSY => return error.DeviceBusy,
        .INTR => return error.Interrupted,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOENT => return error.FileNotFound,
        .NOMEM => return error.SystemResources,
        .NOSPC => return error.NoSpaceLeft,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .TXTBSY => return error.FileBusy,
        .XDEV => return error.DeviceBusy,
        .INVAL => return error.InvalidArgument,
        .NAMETOOLONG => return error.NameTooLong,
        .BADF, .FAULT => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn open(path: []const u8, flags: O, mode: mode_t) !fd_t {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    return openZ(try toZ(path, &buf), flags, mode);
}

pub fn fcntl(fd: fd_t, cmd: i32, arg: usize) !usize {
    const rc = c.fcntl(fd, cmd, arg);
    if (rc < 0) return unexpectedErrno(c.errno(rc));
    return @intCast(rc);
}

pub fn isatty(fd: fd_t) bool {
    return c.isatty(fd) == 1;
}

pub fn flock(fd: fd_t, operation: i32) !void {
    const rc = c.flock(fd, operation);
    if (rc >= 0) return;
    switch (c.errno(rc)) {
        .AGAIN => return error.WouldBlock,
        .INTR => return error.Interrupted,
        .BADF => unreachable,
        .NOLCK => return error.SystemResources,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn fchmodat(dir_fd: fd_t, path: []const u8, mode: mode_t, flags: u32) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = c.fchmodat(dir_fd, try toZ(path, &buf), mode, flags);
    if (rc >= 0) return;
    switch (c.errno(rc)) {
        .ACCES, .PERM => return error.AccessDenied,
        .INTR => return error.Interrupted,
        .IO => return error.InputOutput,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .BADF, .FAULT => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn readlink(path: []const u8, out: []u8) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = c.readlink(try toZ(path, &buf), out.ptr, out.len);
    if (rc >= 0) return out[0..@intCast(rc)];
    switch (c.errno(rc)) {
        .ACCES, .PERM => return error.AccessDenied,
        .FAULT => unreachable,
        .INVAL => return error.InvalidArgument,
        .IO => return error.InputOutput,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn getenv(name: []const u8) ?[:0]const u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = toZ(name, &buf) catch return null;
    const value = c.getenv(z) orelse return null;
    return std.mem.sliceTo(value, 0);
}

/// A fresh copy of this process's environment, the 0.17 replacement for
/// the removed `std.process.getEnvMap`.
pub fn environMap(alloc: std.mem.Allocator) !std.process.Environ.Map {
    const raw: [*:null]const ?[*:0]const u8 = @ptrCast(c.environ);
    const slice: [:null]const ?[*:0]const u8 = std.mem.span(raw);
    return std.process.Environ.createMap(.{ .block = .{ .slice = slice } }, alloc);
}

pub fn getCwd(buf: []u8) ![]u8 {
    const rc = c.getcwd(buf.ptr, buf.len) orelse return error.NameTooLong;
    return std.mem.sliceTo(rc, 0);
}

/// Metadata for `path` without following a final symlink.
pub fn lstat(path: []const u8) !Stat {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = try toZ(path, &buf);
    switch (builtin.os.tag) {
        // Linux libc no longer declares fstatat/lstat in Zig's bindings;
        // statx reports the same fields and does not follow symlinks.
        .linux => {
            var stx: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
            const rc = c.statx(
                AT.FDCWD,
                z,
                AT.SYMLINK_NOFOLLOW,
                .{ .TYPE = true, .MODE = true, .UID = true },
                &stx,
            );
            if (rc >= 0) return .{ .mode = stx.mode, .uid = stx.uid };
            switch (c.errno(rc)) {
                .ACCES, .PERM => return error.AccessDenied,
                .FAULT => unreachable,
                .LOOP => return error.SymLinkLoop,
                .NAMETOOLONG => return error.NameTooLong,
                .NOENT => return error.FileNotFound,
                .NOTDIR => return error.NotDir,
                else => |err| return unexpectedErrno(err),
            }
        },
        else => {
            var st: c.Stat = undefined;
            const rc = c.lstat(z, &st);
            if (rc < 0) return unexpectedErrno(c.errno(rc));
            return .{ .mode = @intCast(st.mode), .uid = st.uid };
        },
    }
}

// -- Directories ----------------------------------------------------------

/// Directory iteration, for the /proc scan. Entry names are valid until the
/// next call to `next`.
pub const Dir = struct {
    handle: *c.DIR,

    pub fn open(path: []const u8) !Dir {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const handle = c.opendir(try toZ(path, &buf)) orelse return error.OpenDirFailed;
        return .{ .handle = handle };
    }

    pub fn close(self: Dir) void {
        _ = c.closedir(self.handle);
    }

    pub fn next(self: *Dir) ?[]const u8 {
        while (c.readdir(self.handle)) |entry| {
            const name = std.mem.sliceTo(&entry.name, 0);
            if (name.len == 0) continue;
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return name;
        }
        return null;
    }
};

/// `mkdir -p`: create `path` and any missing parents.
pub fn makePath(path: []const u8) !void {
    if (path.len == 0) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/' or i == 0) continue;
        try mkdirOne(try toZ(path[0..i], &buf));
    }
    try mkdirOne(try toZ(path, &buf));
}

fn mkdirOne(z: [*:0]const u8) !void {
    const rc = c.mkdir(z, 0o777);
    if (rc >= 0) return;
    switch (c.errno(rc)) {
        .EXIST => {},
        .ACCES, .PERM => return error.AccessDenied,
        .FAULT => unreachable,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOSPC => return error.NoSpaceLeft,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn deleteFile(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = c.unlink(try toZ(path, &buf));
    if (rc >= 0) return;
    switch (c.errno(rc)) {
        .ACCES, .PERM => return error.AccessDenied,
        .BUSY => return error.FileBusy,
        .INTR => return error.Interrupted,
        .ISDIR => return error.IsDir,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .FAULT => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

// -- Processes ------------------------------------------------------------

pub fn fork() !pid_t {
    const rc = c.fork();
    if (rc < 0) return unexpectedErrno(c.errno(rc));
    return rc;
}

pub fn setsid() !pid_t {
    const rc = c.setsid();
    if (rc < 0) return unexpectedErrno(c.errno(rc));
    return rc;
}

pub fn chdirZ(path: [*:0]const u8) !void {
    const rc = c.chdir(path);
    if (rc < 0) return unexpectedErrno(c.errno(rc));
}

pub fn execveZ(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecError!noreturn {
    const rc = c.execve(path, argv, envp);
    return unexpectedErrno(c.errno(rc));
}

pub const ExecError = error{
    AccessDenied,
    FileNotFound,
    NotDir,
    NameTooLong,
    NoMem,
    TooManyOpenFiles,
    InputOutput,
    InvalidArgument,
    TextBusy,
} || Unexpected;

/// execvp(3): search `PATH` when `file` has no slash.
pub fn execvpeZ(
    file: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) ExecError!noreturn {
    const name = std.mem.span(file);
    if (std.mem.indexOfScalar(u8, name, '/') != null) return execveZ(file, argv, envp);

    const path_env = getenv("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var last: ExecError = error.FileNotFound;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const candidate = std.mem.printSentinel(&buf, "{s}/{s}", .{ dir, name }, 0) catch |err| switch (err) {
            error.NoSpaceLeft => return error.NameTooLong,
        };
        execveZ(candidate.ptr, argv, envp) catch |err| {
            last = err;
            continue;
        };
    }
    return last;
}

// -- Sockets --------------------------------------------------------------

pub fn socket(domain: u32, socket_type: u32, protocol: u32) !fd_t {
    const rc = c.socket(domain, socket_type, protocol);
    if (rc < 0) return unexpectedErrno(c.errno(rc));
    return rc;
}

pub fn bind(sock: fd_t, addr: *const sockaddr, len: socklen_t) !void {
    const rc = c.bind(sock, addr, len);
    switch (c.errno(rc)) {
        .SUCCESS => return,
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRINUSE => return error.AddressInUse,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .FAULT => unreachable,
        .INTR => return error.Interrupted,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .ROFS => return error.ReadOnlyFileSystem,
        .BADF, .NOTSOCK => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

pub fn listen(sock: fd_t, backlog: u31) !void {
    const rc = c.listen(sock, backlog);
    if (rc < 0) return unexpectedErrno(c.errno(rc));
}

pub fn accept(
    sock: fd_t,
    addr: ?*sockaddr,
    addr_size: ?*socklen_t,
    flags: u32,
) !fd_t {
    const rc = c.accept4(sock, addr, addr_size, flags);
    if (rc >= 0) return rc;
    return switch (c.errno(rc)) {
        .AGAIN => error.WouldBlock,
        .INTR => error.Interrupted,
        .CONNABORTED => error.ConnectionAborted,
        else => |err| unexpectedErrno(err),
    };
}

pub fn connect(sock: fd_t, addr: *const sockaddr, len: socklen_t) !void {
    const rc = c.connect(sock, addr, len);
    if (rc >= 0) return;
    switch (c.errno(rc)) {
        .ACCES, .PERM => return error.AccessDenied,
        .ADDRNOTAVAIL => return error.AddressNotAvailable,
        .AFNOSUPPORT => return error.AddressFamilyNotSupported,
        .AGAIN => return error.WouldBlock,
        .ALREADY => return error.ConnectionPending,
        .CONNREFUSED => return error.ConnectionRefused,
        .CONNRESET => return error.ConnectionResetByPeer,
        .HOSTUNREACH => return error.NoRouteToHost,
        .INTR => return error.Interrupted,
        .MFILE => return error.ProcessFdQuotaExceeded,
        .NETUNREACH => return error.NetworkUnreachable,
        .NFILE => return error.SystemFdQuotaExceeded,
        .NOENT => return error.FileNotFound,
        .TIMEDOUT => return error.ConnectionTimedOut,
        .BADF, .FAULT, .ISCONN, .NOTSOCK, .PROTOTYPE => unreachable,
        else => |err| return unexpectedErrno(err),
    }
}

// -- Time -----------------------------------------------------------------

/// Wall-clock milliseconds since the epoch, matching the old
/// `std.time.milliTimestamp` that the poll loops build deadlines from.
pub fn milliTimestamp() i64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.REALTIME, &ts);
    return @as(i64, @intCast(ts.sec)) * std.time.ms_per_s +
        @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn monotonicNs() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.nsec));
}

pub fn sleep(ns: u64) void {
    var req: c.timespec = .{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    while (c.nanosleep(&req, &req) != 0) {
        if (c.errno(-1) != .INTR) return;
    }
}

/// Monotonic stopwatch, for the render benchmark.
pub const Timer = struct {
    start_ns: u64,

    pub fn start() Timer {
        return .{ .start_ns = monotonicNs() };
    }

    pub fn read(self: *const Timer) u64 {
        return monotonicNs() - self.start_ns;
    }
};