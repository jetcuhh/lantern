//! Relay of application OSC 72 Kitty drag-and-drop to the real terminal.
//!
//! Native drops belong to the real terminal, so a session's OSC 72
//! commands (registering as a drop target, requesting dropped data) must
//! reach it. The view's own libghostty terminal would instead answer them
//! as the terminal itself — refusing a data request it has no data for —
//! so the commands are forwarded verbatim and kept out of that terminal.
//! The real terminal's answers and drop events travel the other way as
//! ordinary input, which the key parser forwards to the focused session
//! unchanged.
//!
//! This scanner watches the same passthrough bytes the view canvas
//! consumes. It hands each complete OSC 72 sequence to a sink and passes
//! everything else through unchanged. Sequences split across feeds are
//! carried over, so a command is recognized even when the session's
//! output chunks split it.

const std = @import("std");

/// `ESC ] 7 2 ;`: the exact prefix of an OSC 72 sequence. Requiring the
/// trailing `;` keeps neighbours such as OSC 720 from matching.
const prefix = "\x1b]72;";

/// Cap on a single buffered sequence. A registration's MIME list is at
/// most 1 MiB upstream and a data request is tiny; anything larger is
/// abandoned rather than buffered without bound. The abandoned tail is
/// ordinary bytes, so it rejoins the passthrough.
const max_seq = 2 * 1024 * 1024;

/// Incremental scanner over a session's output. It never drops bytes: a
/// complete OSC 72 sequence goes to `sink.sequence`, everything else to
/// `sink.plain`, in order.
pub const Filter = struct {
    /// An in-progress candidate, starting at ESC. Empty in the ground
    /// state.
    buf: std.ArrayList(u8) = .empty,
    /// The previous body byte was an ESC that may begin an ST
    /// terminator (`ESC \`).
    esc_pending: bool = false,

    pub fn deinit(self: *Filter, alloc: std.mem.Allocator) void {
        self.buf.deinit(alloc);
    }

    /// Scan `input`. Each complete OSC 72 sequence, terminator included,
    /// goes to `sink.sequence(seq)`; the surrounding bytes go to
    /// `sink.plain(bytes)` unchanged. The sink must consume every slice
    /// immediately: it aliases `input` or this filter's buffer.
    pub fn feed(
        self: *Filter,
        alloc: std.mem.Allocator,
        input: []const u8,
        sink: anytype,
    ) std.mem.Allocator.Error!void {
        var i: usize = 0;
        while (i < input.len) {
            const byte = input[i];
            var advance = true;

            if (self.buf.items.len == 0) {
                // Ground: only ESC can begin a candidate. Skip the run
                // of ordinary bytes in one pass.
                if (byte != 0x1b) {
                    const rel = std.mem.indexOfScalar(u8, input[i..], 0x1b) orelse
                        input.len - i;
                    sink.plain(input[i..][0..rel]);
                    i += rel;
                    continue;
                }
                try self.buf.append(alloc, byte);
            } else if (self.buf.items.len < prefix.len) {
                // Matching the fixed prefix one byte at a time.
                if (byte == prefix[self.buf.items.len]) {
                    try self.buf.append(alloc, byte);
                } else {
                    // Not OSC 72 after all. The candidate is ordinary
                    // output; hand it on and reconsider this byte from
                    // the ground state so a fresh ESC is not lost.
                    sink.plain(self.buf.items);
                    self.reset();
                    advance = false;
                }
            } else if (self.esc_pending) {
                self.esc_pending = false;
                if (byte == '\\') {
                    // ST terminator (`ESC \`) completes the sequence.
                    try self.buf.append(alloc, byte);
                    sink.sequence(self.buf.items);
                    self.reset();
                } else {
                    // The ESC was body content, not ST: ordinary output.
                    sink.plain(self.buf.items);
                    self.reset();
                    advance = false;
                }
            } else if (byte == 0x07) {
                // BEL terminator completes the sequence.
                try self.buf.append(alloc, byte);
                sink.sequence(self.buf.items);
                self.reset();
            } else {
                // Body. Neither terminator byte can appear in a well
                // formed command's fields, so accumulate the run in one
                // copy instead of byte by byte.
                const rest = input[i..];
                const run = std.mem.indexOfAny(u8, rest, &[_]u8{ 0x07, 0x1b }) orelse
                    rest.len;
                if (run == 0) {
                    // The byte is ESC (BEL is handled above); it may
                    // open ST.
                    try self.buf.append(alloc, byte);
                    self.esc_pending = true;
                } else if (self.buf.items.len + run > max_seq) {
                    // Oversized: abandon it to the passthrough.
                    sink.plain(self.buf.items);
                    self.reset();
                    sink.plain(rest[0..run]);
                    i += run;
                    continue;
                } else {
                    try self.buf.appendSlice(alloc, rest[0..run]);
                    i += run;
                    continue;
                }
            }

            if (advance) i += 1;
        }
    }

    fn reset(self: *Filter) void {
        self.buf.clearRetainingCapacity();
        self.esc_pending = false;
    }
};

const Collector = struct {
    alloc: std.mem.Allocator,
    plain: std.ArrayList(u8) = .empty,
    seqs: std.ArrayList([]u8) = .empty,

    fn sink(self: *Collector) Sink {
        return .{ .c = self };
    }

    const Sink = struct {
        c: *Collector,

        pub fn plain(self: Sink, bytes: []const u8) void {
            self.c.plain.appendSlice(self.c.alloc, bytes) catch {};
        }

        pub fn sequence(self: Sink, seq: []const u8) void {
            const dup = self.c.alloc.dupe(u8, seq) catch return;
            self.c.seqs.append(self.c.alloc, dup) catch self.c.alloc.free(dup);
        }
    };

    fn deinit(self: *Collector) void {
        self.plain.deinit(self.alloc);
        for (self.seqs.items) |s| self.alloc.free(s);
        self.seqs.deinit(self.alloc);
    }
};

fn expectScan(input: []const u8, want_plain: []const u8, want_seqs: []const []const u8) !void {
    const alloc = std.testing.allocator;
    var f: Filter = .{};
    defer f.deinit(alloc);
    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();
    try f.feed(alloc, input, c.sink());
    try std.testing.expectEqualStrings(want_plain, c.plain.items);
    try std.testing.expectEqual(want_seqs.len, c.seqs.items.len);
    for (want_seqs, c.seqs.items) |want, got| {
        try std.testing.expectEqualStrings(want, got);
    }
}

test "OSC 72 is forwarded with surrounding output passing through" {
    try expectScan(
        "before\x1b]72;t=a;text/plain\x07after",
        "beforeafter",
        &.{"\x1b]72;t=a;text/plain\x07"},
    );
}

test "an ST-terminated OSC 72 is forwarded" {
    try expectScan(
        "\x1b]72;t=a;text/plain text/uri-list\x1b\\",
        "",
        &.{"\x1b]72;t=a;text/plain text/uri-list\x1b\\"},
    );
}

test "an OSC 72 split across feeds is recognized" {
    const alloc = std.testing.allocator;
    var f: Filter = .{};
    defer f.deinit(alloc);
    var c: Collector = .{ .alloc = alloc };
    defer c.deinit();

    try f.feed(alloc, "x\x1b]72;t=", c.sink());
    try std.testing.expectEqual(@as(usize, 0), c.seqs.items.len);
    try std.testing.expectEqualStrings("x", c.plain.items);

    try f.feed(alloc, "r:x=1\x1b\\y", c.sink());
    try std.testing.expectEqual(@as(usize, 1), c.seqs.items.len);
    try std.testing.expectEqualStrings("\x1b]72;t=r:x=1\x1b\\", c.seqs.items[0]);
    try std.testing.expectEqualStrings("xy", c.plain.items);
}

test "an OSC 720 and other neighbours are not matched" {
    try expectScan("\x1b]720;t=a\x07", "\x1b]720;t=a\x07", &.{});
    try expectScan("\x1b]2;title\x07", "\x1b]2;title\x07", &.{});
    try expectScan("\x1b]11;rgb:1234/5678/9abc\x07", "\x1b]11;rgb:1234/5678/9abc\x07", &.{});
}

test "a near-miss prefix rejoins the output and a later command still matches" {
    // ESC ] 7 then ordinary text aborts the candidate; its bytes must
    // still reach the terminal, and the following real command matches.
    try expectScan(
        "\x1b]7x\x1b]72;t=A\x1b\\",
        "\x1b]7x",
        &.{"\x1b]72;t=A\x1b\\"},
    );
}

test "plain text and CSI sequences pass through untouched" {
    try expectScan("hello \x1b[2J\x1b[1;5Hworld", "hello \x1b[2J\x1b[1;5Hworld", &.{});
}

test "back-to-back commands are both forwarded" {
    try expectScan(
        "\x1b]72;t=a\x07\x1b]72;t=r:x=1\x1b\\",
        "",
        &.{ "\x1b]72;t=a\x07", "\x1b]72;t=r:x=1\x1b\\" },
    );
}

test "a lone ESC before ordinary output is not swallowed" {
    // The trailing ESC is held as a possible candidate; two ESC bytes
    // in a row then abort it back into the output.
    try expectScan("\x1b\x1bX", "\x1b\x1bX", &.{});
}
