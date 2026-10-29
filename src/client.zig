//! Client-side terminal plumbing shared with the UI: the daemon socket
//! connection, the startup OSC 11 background probe, raw-mode setup, and
//! the held-key drain that runs when the terminal is handed back.

const std = @import("std");
const posix = @import("sys.zig");

const protocol = @import("protocol.zig");
const keys = @import("keys.zig");

/// How long to wait for the terminal to answer the startup OSC 11
/// background probe. Terminals that support it answer within a few
/// milliseconds; the probe returns as soon as the reply arrives, so this
/// bound only delays the probe on a terminal that never answers.
const probe_timeout_ms = 150;

pub fn connect(alloc: std.mem.Allocator, socket_path: []const u8) !posix.fd_t {
    _ = alloc;
    const fd = try posix.socket(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0);
    errdefer posix.close(fd);
    var addr: posix.sockaddr.un = .{ .family = posix.AF.UNIX, .path = undefined };
    if (socket_path.len >= addr.path.len) return error.NameTooLong;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..socket_path.len], socket_path);
    try posix.connect(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.un));
    return fd;
}

/// Probe the real terminal for its background color via an OSC 11 query
/// and parse the reply. Returns null if the terminal does not answer
/// within `probe_timeout_ms` or a pending signal (resize/quit) on
/// `signal_fd` cuts the probe short so the caller can service it. Bytes
/// read while waiting that are not the reply (e.g. a keystroke typed
/// during startup) are left in `scratch[0..leftover_len.*]` for the
/// caller to forward as input. Pass -1 for `signal_fd` to skip the
/// signal check.
pub fn probeBackground(
    tty: posix.fd_t,
    signal_fd: posix.fd_t,
    scratch: []u8,
    leftover_len: *usize,
) ?protocol.RgbPayload {
    leftover_len.* = 0;
    // The query goes to the terminal on stdout; the reply arrives on the
    // input fd. For the UI, stdout and stdin are the same tty.
    protocol.writeAll(posix.STDOUT_FILENO, "\x1b]11;?\x07") catch return null;

    const deadline = posix.milliTimestamp() + probe_timeout_ms;
    var len: usize = 0;
    while (len < scratch.len) {
        const now = posix.milliTimestamp();
        if (now >= deadline) break;
        var fds = [_]posix.pollfd{
            .{ .fd = tty, .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = signal_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, @intCast(deadline - now)) catch break;
        if (ready == 0) break;
        // A pending signal (resize or quit) must reach the caller's loop
        // without delay; stop probing and leave it queued.
        if (fds[1].revents != 0) break;
        if (fds[0].revents == 0) continue;
        const n = posix.read(tty, scratch[len..]) catch break;
        if (n == 0) break;
        len += n;
        if (findOsc11Reply(scratch[0..len])) |span| {
            const color = parseOsc11Reply(scratch[span.start..span.end]);
            // Drop the reply from the buffer; keep anything else (typed
            // input) as leftover for the caller to forward.
            const removed = span.end - span.start;
            std.mem.copyForwards(u8, scratch[span.start..], scratch[span.end..len]);
            leftover_len.* = len - removed;
            return color;
        }
    }
    leftover_len.* = len;
    return null;
}

const Osc11Span = struct { start: usize, end: usize };

/// Locate a complete OSC 11 reply (`ESC ] 11 ; ... BEL|ST`) in `data`,
/// returning the byte span it occupies, terminator included.
fn findOsc11Reply(data: []const u8) ?Osc11Span {
    const marker = "\x1b]11;";
    const start = std.mem.indexOf(u8, data, marker) orelse return null;
    const body = data[start + marker.len ..];
    if (std.mem.indexOfScalar(u8, body, 0x07)) |bel| {
        return .{ .start = start, .end = start + marker.len + bel + 1 };
    }
    if (std.mem.indexOf(u8, body, "\x1b\\")) |st| {
        return .{ .start = start, .end = start + marker.len + st + 2 };
    }
    return null;
}

/// Parse an OSC 11 reply (`ESC ] 11 ; rgb:R/G/B` with a BEL or ST
/// terminator) into a 16-bit RGB. Each channel may be 1-4 hex digits and
/// is scaled to 16-bit. Returns null for anything it does not recognize.
pub fn parseOsc11Reply(data: []const u8) ?protocol.RgbPayload {
    const marker = "\x1b]11;";
    const start = std.mem.indexOf(u8, data, marker) orelse return null;
    var body = data[start + marker.len ..];
    if (std.mem.indexOfScalar(u8, body, 0x07)) |bel| {
        body = body[0..bel];
    } else if (std.mem.indexOf(u8, body, "\x1b\\")) |st| {
        body = body[0..st];
    }
    const rgb_prefix = "rgb:";
    if (!std.mem.startsWith(u8, body, rgb_prefix)) return null;
    var it = std.mem.splitScalar(u8, body[rgb_prefix.len..], '/');
    const r = parseChannel(it.next() orelse return null) orelse return null;
    const g = parseChannel(it.next() orelse return null) orelse return null;
    const b = parseChannel(it.next() orelse return null) orelse return null;
    if (it.next() != null) return null;
    return .{ .r = r, .g = g, .b = b };
}

fn parseChannel(s: []const u8) ?u16 {
    if (s.len == 0 or s.len > 4) return null;
    const v = std.fmt.parseInt(u16, s, 16) catch return null;
    const wide: u32 = v;
    return switch (s.len) {
        1 => @intCast(wide * 0x1111), // 0xF  -> 0xFFFF
        2 => @intCast(wide * 0x101), // 0xFF -> 0xFFFF
        3 => @intCast((wide * 0xffff) / 0xfff), // 0xFFF -> 0xFFFF
        else => @intCast(wide), // already 16-bit
    };
}

/// Configure a termios for raw byte-at-a-time input. Shared with the
/// UI client, which manages its own terminal lifecycle.
pub fn rawMode(t: *posix.termios) void {
    t.iflag.IGNBRK = false;
    t.iflag.BRKINT = false;
    t.iflag.PARMRK = false;
    t.iflag.ISTRIP = false;
    t.iflag.INLCR = false;
    t.iflag.IGNCR = false;
    t.iflag.ICRNL = false;
    t.iflag.IXON = false;
    t.oflag.OPOST = false;
    t.lflag.ECHO = false;
    t.lflag.ECHONL = false;
    t.lflag.ICANON = false;
    t.lflag.ISIG = false;
    t.lflag.IEXTEN = false;
    t.cflag.CSIZE = .CS8;
    t.cflag.PARENB = false;
    t.cc[@intFromEnum(posix.V.MIN)] = 1;
    t.cc[@intFromEnum(posix.V.TIME)] = 0;
}

/// Read and discard terminal input until it goes quiet.
///
/// When a detach is triggered by a key the user is still holding, the
/// terminal keeps producing input after the daemon has already decided
/// to detach: auto-repeats of the command key, kitty release reports,
/// impatient re-presses, and (on a remote connection) anything in
/// flight during the round trip. The final TCSAFLUSH only discards
/// what has reached the tty queue at that instant, so without this
/// wait the tail is delivered to the shell that regains the terminal:
/// a stray `d` typed at the prompt, or worse, a leaked C-d that EOFs
/// the login shell and ends the SSH session.
///
/// Runs while the terminal is still in raw mode, so the discarded
/// bytes are never echoed. Two timers bound the wait: `guard_ms`
/// covers the silence between the triggering press and the first
/// auto-repeat (keyboard repeat delays reach ~660ms on common
/// configurations, so EOF-dangerous detaches use the long guard),
/// then each absorbed chunk extends the wait by a short tail until
/// the input stays quiet, all capped at drain_cap_ms. On terminals
/// that report key releases (the kitty protocol, which restoreTty
/// enables for the drain), the triggering key's release ends the wait
/// at once, so the timers are only a fallback.
fn drainInput(tty: posix.fd_t, guard_ms: i64, trigger_cp: u32) void {
    const start = posix.milliTimestamp();
    const cap = start + drain_cap_ms;
    var deadline = start + guard_ms;
    var buf: [256]u8 = undefined;
    var scan: ReleaseScan = .{ .want_cp = trigger_cp };
    while (true) {
        const now = posix.milliTimestamp();
        const until = @min(deadline, cap);
        if (now >= until) return;
        var fds = [_]posix.pollfd{
            .{ .fd = tty, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, @intCast(until - now)) catch return;
        if (ready == 0) return;
        const n = posix.read(tty, &buf) catch return;
        if (n == 0) return;
        // The triggering key's kitty release means the user let go: no
        // more auto-repeats can follow, so stop draining immediately.
        if (scan.feed(buf[0..n])) return;
        deadline = @max(deadline, posix.milliTimestamp() + drain_tail_ms);
    }
}

/// Scans drained input for a kitty key-release event of the key that
/// triggered the detach. Carries CSI-parse state between calls so a
/// sequence split across reads is still recognized.
const ReleaseScan = struct {
    /// CSI parse state: 0 idle, 1 after ESC, 2 inside the CSI body.
    state: u8 = 0,
    body: [40]u8 = undefined,
    body_len: usize = 0,
    /// Effective codepoint whose release ends the drain; 0 matches any
    /// key release.
    want_cp: u32,

    fn feed(self: *ReleaseScan, bytes: []const u8) bool {
        for (bytes) |b| {
            switch (self.state) {
                1 => {
                    if (b == '[') {
                        self.state = 2;
                        self.body_len = 0;
                    } else self.state = if (b == 0x1b) 1 else 0;
                },
                2 => {
                    if (b == 'u') {
                        if (self.isRelease()) return true;
                        self.state = 0;
                    } else if ((b >= '0' and b <= '9') or b == ';' or b == ':') {
                        if (self.body_len < self.body.len) {
                            self.body[self.body_len] = b;
                            self.body_len += 1;
                        } else self.state = 0;
                    } else self.state = if (b == 0x1b) 1 else 0;
                },
                else => if (b == 0x1b) {
                    self.state = 1;
                },
            }
        }
        return false;
    }

    fn isRelease(self: *const ReleaseScan) bool {
        const key = keys.parseKitty(self.body[0..self.body_len]) orelse return false;
        if (key.event != 3) return false;
        return self.want_cp == 0 or keys.effectiveCp(key) == self.want_cp;
    }
};

/// Guard for detaches with no reason to expect a held key.
const drain_guard_short_ms = 300;
/// Guard for flows where the user plausibly holds C-d, the byte that
/// EOFs a cooked-mode shell: a C-w C-d detach and a session that ends
/// while attached (often a C-d typed at the session's own shell).
const drain_guard_eof_ms = 800;
const drain_tail_ms = 100;
const drain_cap_ms = 1500;
/// Kitty keyboard flags forced during the drain so a still-held key
/// reports its release: disambiguate (1) + event types (2) + report
/// all keys (8). Cleared again before the shell regains the terminal.
const drain_kbd_enable = "\x1b[=11;1u";
const drain_kbd_disable = "\x1b[=0;1u";

/// Restore a raw client terminal: screen restore, input drain, then
/// the mode switch. Shared with the UI, whose quit has the same held
/// command key and kitty release tail to absorb.
pub fn restoreTty(
    tty: posix.fd_t,
    saved: posix.termios,
    restore: []const u8,
    eof_guard: bool,
    trigger_cp: u32,
) void {
    // Screen restore first: the user sees the detach immediately, and
    // a kitty-mode terminal stops CSI-u key reporting as soon as the
    // reset reaches it, so a still-held key repeats in legacy bytes
    // that the drain below absorbs. Only then hand the tty back, after
    // a final non-blocking input discard catches anything that slipped
    // in between the last drained read and the mode switch.
    protocol.writeAll(1, restore) catch {};
    // Re-enable kitty report-events so a still-held command key reports
    // its release, ending the drain the instant the user lets go rather
    // than waiting out the timed guard. Terminals without the kitty
    // protocol ignore this and the guard still applies.
    protocol.writeAll(1, drain_kbd_enable) catch {};
    drainInput(tty, if (eof_guard) drain_guard_eof_ms else drain_guard_short_ms, trigger_cp);
    // Clear keyboard reporting again before the shell regains the tty.
    protocol.writeAll(1, drain_kbd_disable) catch {};
    // Switch the mode back without TCSAFLUSH: on Darwin its output-drain
    // half blocks until the PTY master has consumed the writes above, so
    // a peer that briefly stopped reading (a detach test between reads, a
    // stalled remote link) wedges the restore, and the input-flush half
    // then discards whatever was typed in the meantime. Drain straggler
    // input non-blockingly instead, then apply the saved mode at once.
    flushPendingInput(tty);
    posix.tcsetattr(tty, .NOW, saved) catch {};
}

/// The input-flush half of TCSAFLUSH on its own: poll with a zero
/// timeout and read until the queue is empty, while the tty is still
/// raw so canonical buffering cannot hide a partial line. Skipping the
/// output-drain half is deliberate (see restoreTty): it would block on
/// Darwin until the PTY master consumes our output.
fn flushPendingInput(tty: posix.fd_t) void {
    var buf: [256]u8 = undefined;
    while (true) {
        var fds = [_]posix.pollfd{
            .{ .fd = tty, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = posix.poll(&fds, 0) catch return;
        if (ready == 0) return;
        const n = posix.read(tty, &buf) catch return;
        if (n == 0) return;
    }
}

test "ReleaseScan: the triggering key's release ends the drain" {
    var scan: ReleaseScan = .{ .want_cp = 'd' };
    // Press and auto-repeat are not a release.
    try std.testing.expect(!scan.feed("\x1b[100;1:1u"));
    try std.testing.expect(!scan.feed("\x1b[100;1:2u"));
    // The release of the 'd' key ends the drain.
    try std.testing.expect(scan.feed("\x1b[100;1:3u"));
}

test "ReleaseScan: other keys' releases are ignored" {
    var scan: ReleaseScan = .{ .want_cp = 'd' };
    // A left-ctrl release from the C-w C-d chord is not the trigger.
    try std.testing.expect(!scan.feed("\x1b[57442;5:3u"));
    // C-d is the same physical 'd' key with ctrl held: its release ends
    // the drain, matched through the effective codepoint.
    try std.testing.expect(scan.feed("\x1b[100;5:3u"));
}

test "ReleaseScan: a sequence split across reads is still recognized" {
    var scan: ReleaseScan = .{ .want_cp = 'd' };
    try std.testing.expect(!scan.feed("\x1b[100;1"));
    try std.testing.expect(scan.feed(":3u"));
}

test "ReleaseScan: want_cp 0 matches any key release" {
    var scan: ReleaseScan = .{ .want_cp = 0 };
    try std.testing.expect(scan.feed("\x1b[119;1:3u"));
}

test "ReleaseScan: non-release CSI and plain bytes never trigger" {
    var scan: ReleaseScan = .{ .want_cp = 'd' };
    // Auto-repeats, an arrow key, and plain held bytes are not a
    // release of the trigger key.
    try std.testing.expect(!scan.feed("dddd"));
    try std.testing.expect(!scan.feed("\x1b[A\x1b[100;1:2u"));
}

test "parseOsc11Reply: BEL and ST terminators, various channel widths" {
    // 16-bit channels, BEL-terminated (ghostty's format).
    try std.testing.expectEqual(
        protocol.RgbPayload{ .r = 0x1234, .g = 0x5678, .b = 0x9abc },
        parseOsc11Reply("\x1b]11;rgb:1234/5678/9abc\x07").?,
    );
    // ST-terminated, 2-digit channels scaled to 16-bit.
    try std.testing.expectEqual(
        protocol.RgbPayload{ .r = 0xffff, .g = 0x0000, .b = 0x8080 },
        parseOsc11Reply("\x1b]11;rgb:ff/00/80\x1b\\").?,
    );
    // A reply embedded among other bytes still parses.
    try std.testing.expect(parseOsc11Reply("x\x1b]11;rgb:0000/0000/0000\x07y") != null);
    // A query is not a reply, and junk is rejected.
    try std.testing.expect(parseOsc11Reply("\x1b]11;?\x07") == null);
    try std.testing.expect(parseOsc11Reply("garbage") == null);
    try std.testing.expect(parseOsc11Reply("\x1b]11;rgb:00/00\x07") == null); // too few channels
}

test "findOsc11Reply: only a fully terminated reply is located" {
    // Incomplete (no terminator yet): not found.
    try std.testing.expect(findOsc11Reply("\x1b]11;rgb:1111/2222/3333") == null);
    // BEL-terminated reply: span covers the terminator (exclusive end).
    const span = findOsc11Reply("ab\x1b]11;rgb:1111/2222/3333\x07cd").?;
    try std.testing.expectEqual(@as(usize, 2), span.start);
    try std.testing.expectEqual(@as(usize, 26), span.end);
}
