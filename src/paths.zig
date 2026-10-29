//! Socket directory and session socket path resolution.

const std = @import("std");
const posix = @import("sys.zig");

/// Resolve the runtime directory that holds the session socket:
/// $LANTERN_DIR, else $XDG_RUNTIME_DIR/lantern, else /tmp/lantern-<uid>.
/// The directory is created with mode 0700.
pub fn socketDir(alloc: std.mem.Allocator) ![]u8 {
    return socketDirFrom(
        alloc,
        posix.getenv("LANTERN_DIR"),
        posix.getenv("XDG_RUNTIME_DIR"),
    );
}

/// The XDG runtime directory is created by the login session, never by
/// applications. When $XDG_RUNTIME_DIR names a directory that does not
/// exist (common on macOS, where dotfiles shared with Linux export a
/// /run/user/<uid> path), creating it would mean writing to system
/// directories: mkdir /run on the sealed macOS system volume fails with
/// error.ReadOnlyFileSystem. Honor the variable only when the directory
/// exists and the lantern subdirectory is creatable inside it; otherwise
/// fall back to /tmp/lantern-<uid>. $LANTERN_DIR is an explicit override, so
/// errors there stay fatal rather than being silently redirected.
fn socketDirFrom(
    alloc: std.mem.Allocator,
    lantern_dir: ?[]const u8,
    runtime_dir: ?[]const u8,
) ![]u8 {
    if (lantern_dir) |d| {
        if (d.len > 0) {
            const dir = try alloc.dupe(u8, d);
            errdefer alloc.free(dir);
            try ensureDir(dir);
            return dir;
        }
    }
    if (runtime_dir) |d| usable: {
        if (d.len == 0) break :usable;
        const parent = posix.Dir.open(d) catch break :usable;
        parent.close();
        const dir = try std.fs.path.join(alloc, &.{ d, "lantern" });
        ensureDir(dir) catch {
            alloc.free(dir);
            break :usable;
        };
        return dir;
    }
    const dir = try std.fmt.allocPrint(alloc, "/tmp/lantern-{d}", .{std.c.getuid()});
    errdefer alloc.free(dir);
    try ensureDir(dir);
    return dir;
}

fn ensureDir(dir: []const u8) !void {
    try posix.makePath(dir);
    // Sockets must not be reachable by other users.
    posix.fchmodat(posix.AT.FDCWD, dir, 0o700, 0) catch {};
    try verifyPrivateDir(dir);
}

/// The fallback directory has a predictable name in a world-writable
/// parent (/tmp/lantern-<uid>), so another user could create it first
/// and, owning it, swap in their own socket to capture this user's
/// keystrokes. Accept the directory only when it is a real directory
/// (not a symlink) owned by the current user and closed to everyone else.
fn verifyPrivateDir(dir: []const u8) !void {
    const st = try posix.lstat(dir);
    if (!st.isDir()) return error.InsecureSocketDir;
    if (st.uid != std.c.getuid()) return error.InsecureSocketDir;
    if ((st.mode & 0o077) != 0) return error.InsecureSocketDir;
}

/// The single session's socket path: <dir>/lantern.sock. lantern runs one
/// session per user runtime directory, so the name is fixed.
pub fn sessionPath(alloc: std.mem.Allocator, dir: []const u8) ![]u8 {
    return std.fs.path.join(alloc, &.{ dir, "lantern.sock" });
}

test "sessionPath uses the fixed session socket name" {
    const alloc = std.testing.allocator;
    const p = try sessionPath(alloc, "/run/gs");
    defer alloc.free(p);
    try std.testing.expectEqualStrings("/run/gs/lantern.sock", p);
}

/// Resolve a test temp directory to an absolute path (0.17 has no
/// `realpathAlloc`).
fn tmpRealPath(alloc: std.mem.Allocator, dir: std.Io.Dir) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &buf);
    return alloc.dupe(u8, buf[0..n]);
}

/// Assert that `path` opens as a directory.
fn expectDir(path: []const u8) !void {
    var d = try std.Io.Dir.cwd().openDir(std.testing.io, path, .{});
    d.close(std.testing.io);
}

test "socketDirFrom prefers LANTERN_DIR and creates it" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpRealPath(alloc, tmp.dir);
    defer alloc.free(base);

    const want = try std.fs.path.join(alloc, &.{ base, "override", "lantern" });
    defer alloc.free(want);

    const dir = try socketDirFrom(alloc, want, null);
    defer alloc.free(dir);
    try std.testing.expectEqualStrings(want, dir);
    try expectDir(dir);
}

test "socketDirFrom uses an existing runtime dir" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const runtime = try tmpRealPath(alloc, tmp.dir);
    defer alloc.free(runtime);

    const dir = try socketDirFrom(alloc, null, runtime);
    defer alloc.free(dir);

    const want = try std.fs.path.join(alloc, &.{ runtime, "lantern" });
    defer alloc.free(want);
    try std.testing.expectEqualStrings(want, dir);
    try expectDir(dir);
}

test "socketDirFrom falls back when the runtime dir is unusable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpRealPath(alloc, tmp.dir);
    defer alloc.free(base);

    const fallback = try std.fmt.allocPrint(alloc, "/tmp/lantern-{d}", .{std.c.getuid()});
    defer alloc.free(fallback);

    // Missing directory, like /run/user/<uid> on macOS. The fallback
    // must not attempt to create the runtime dir or its parents.
    const missing = try std.fs.path.join(alloc, &.{ base, "run", "user", "501" });
    defer alloc.free(missing);
    {
        const dir = try socketDirFrom(alloc, null, missing);
        defer alloc.free(dir);
        try std.testing.expectEqualStrings(fallback, dir);
        try std.testing.expectError(
            error.FileNotFound,
            std.Io.Dir.cwd().access(std.testing.io, missing, .{}),
        );
    }

    // A runtime dir that is not a directory at all.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "not-a-dir", .data = "" });
    const file_path = try std.fs.path.join(alloc, &.{ base, "not-a-dir" });
    defer alloc.free(file_path);
    {
        const dir = try socketDirFrom(alloc, null, file_path);
        defer alloc.free(dir);
        try std.testing.expectEqualStrings(fallback, dir);
    }
}

test "ensureDir tightens a loose directory we own and rejects a symlink" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmpRealPath(alloc, tmp.dir);
    defer alloc.free(base);

    // A directory we own with loose permissions is closed to others.
    const loose = try std.fs.path.join(alloc, &.{ base, "loose" });
    defer alloc.free(loose);
    try tmp.dir.createDirPath(std.testing.io, "loose");
    try posix.fchmodat(posix.AT.FDCWD, loose, 0o777, 0);
    try ensureDir(loose);
    const st = try posix.lstat(loose);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, st.mode) & 0o077);

    // A symlink standing in for the directory is refused.
    try tmp.dir.symLink(std.testing.io, "loose", "link", .{ .is_directory = true });
    const link = try std.fs.path.join(alloc, &.{ base, "link" });
    defer alloc.free(link);
    try std.testing.expectError(error.InsecureSocketDir, ensureDir(link));
}
