const std = @import("std");
const builtin = @import("builtin");
const posix = @import("sys.zig");

const Kind = enum { wayland, x11, mac };

const Tool = struct {
    kind: Kind,
    argv: [*:null]const ?[*:0]const u8,
};

const tools = [_]Tool{
    .{ .kind = .wayland, .argv = &[_:null]?[*:0]const u8{"wl-copy"} },
    .{ .kind = .x11, .argv = &[_:null]?[*:0]const u8{ "xclip", "-selection", "clipboard", "-in" } },
    .{ .kind = .x11, .argv = &[_:null]?[*:0]const u8{ "xsel", "--clipboard", "--input" } },
    .{ .kind = .mac, .argv = &[_:null]?[*:0]const u8{"pbcopy"} },
};

fn isSet(name: []const u8) bool {
    const v = posix.getenv(name) orelse return false;
    return v.len > 0;
}

pub fn copy(text: []const u8) void {
    if (text.len == 0) return;
    if (isSet("SSH_CONNECTION") or isSet("SSH_TTY")) return;

    const wayland = isSet("WAYLAND_DISPLAY");
    const x11 = isSet("DISPLAY");
    const mac = builtin.os.tag == .macos;
    if (!wayland and !x11 and !mac) return;

    const first = posix.fork() catch return;
    if (first != 0) {
        var status: c_int = undefined;
        _ = std.c.waitpid(first, &status, 0);
        return;
    }

    const second = posix.fork() catch std.c._exit(1);
    if (second != 0) std.c._exit(0);

    detach();
    for (tools) |tool| {
        const enabled = switch (tool.kind) {
            .wayland => wayland,
            .x11 => x11,
            .mac => mac,
        };
        if (!enabled) continue;
        if (feed(tool.argv, text)) break;
    }
    std.c._exit(0);
}

fn detach() void {
    _ = posix.setsid() catch {};
    const devnull = posix.open("/dev/null", .{ .ACCMODE = .RDWR }, 0) catch std.c._exit(1);
    posix.dup2(devnull, 0) catch {};
    posix.dup2(devnull, 1) catch {};
    posix.dup2(devnull, 2) catch {};
    var fd: posix.fd_t = 3;
    while (fd < 256) : (fd += 1) posix.close(fd);
}

fn feed(argv: [*:null]const ?[*:0]const u8, text: []const u8) bool {
    const fds = posix.pipe2(.{ .CLOEXEC = true }) catch return false;
    const pid = posix.fork() catch {
        posix.close(fds[0]);
        posix.close(fds[1]);
        return false;
    };

    if (pid == 0) {
        posix.dup2(fds[0], 0) catch std.c._exit(127);
        const envp: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
        const err = posix.execvpeZ(argv[0].?, argv, envp);
        _ = err catch {};
        std.c._exit(127);
    }

    posix.close(fds[0]);
    var written: usize = 0;
    var ok = true;
    while (written < text.len) {
        const n = posix.write(fds[1], text[written..]) catch {
            ok = false;
            break;
        };
        written += n;
    }
    posix.close(fds[1]);

    var status: c_int = undefined;
    _ = std.c.waitpid(pid, &status, 0);
    return ok and status == 0;
}
