//! Length-prefixed message framing for the client/daemon Unix socket.
//!
//! Wire format, little endian:
//!
//!   | type: u8 | payload_len: u32 | payload: [payload_len]u8 |
//!
//! Payloads are opaque bytes; structured payloads (sizes, command argv)
//! are encoded by the helpers below.

const std = @import("std");
const posix = @import("sys.zig");

/// Maximum payload size. Anything larger is a protocol error; this bounds
/// memory used by a malicious or corrupt peer.
pub const max_payload = 1 << 20;

pub const header_len = 5;

pub const MsgType = enum(u8) {
    // Client to daemon.
    attach = 1,
    input = 2,
    resize = 3,
    detach_req = 4,
    /// Marks this connection as a UI view. Sent right before the
    /// attach so the daemon replays scrollback history on attach. A
    /// daemon from before this message existed ignores the unknown type
    /// and simply attaches the view with no history, so a new ui client
    /// stays compatible with an already-running older daemon.
    ui = 6,
    /// Tab management. The single session owns a list of tabs; every
    /// client is a UI view of the active tab.
    ///
    /// `tab_new` carries no payload: the daemon starts the session shell
    /// in the active tab's working directory.
    tab_new = 8,
    /// `tab_close` and `tab_select` carry a little-endian u32 tab id.
    tab_close = 9,
    tab_select = 10,
    /// End the whole session: terminate every tab and shut the daemon
    /// down. The UI sends this for the kill binding; detaching instead
    /// leaves the tabs running.
    quit = 12,
    /// The background color of the client's real terminal, as a
    /// `RgbPayload`. The client probes its terminal once at startup and
    /// reports the answer so the daemon can satisfy OSC 11 background
    /// queries (and the color-scheme DSR) from inside the session, where
    /// the application can no longer reach the real terminal. An older
    /// daemon ignores the unknown type, so theme detection simply stays
    /// as it was before this message existed.
    bg_color = 7,
    /// Repaint this view's active tab from the daemon's terminal state.
    /// Replaces the old trick of sending the prefix bytes `C-w l` as
    /// input, which made the daemon parse the view's input stream. An
    /// older daemon ignores it (the redraw then does nothing).
    redraw_req = 13,
    /// The client's environment, for tabs created from now on. Payload:
    /// NUL-separated entries, `NAME=value` for a variable the client has
    /// and a bare `NAME` for a variable it does not (so a stale value
    /// the daemon inherited at startup, such as SSH_AUTH_SOCK, is
    /// removed). Only a fixed allowlist of session variables is sent.
    env = 14,
    /// The real terminal's cell size in pixels, as a `CellSizePayload`.
    /// The daemon reports it to applications (XTWINOPS, kitty) and uses
    /// it to lay out images, so an image sized in cells by the
    /// application lands at the right pixel size on the real terminal.
    /// An older daemon ignores it and keeps its nominal 8x16 cells.
    cell_size = 15,

    // Daemon to client.
    output = 64,
    detached = 65,
    exit = 66,
    err = 68,
    /// Which screen the application is on ("alt" or "primary"),
    /// sent alongside every repaint. The passthrough strips screen
    /// toggles, so clients cannot tell on their own; the ui uses it
    /// to decide what a wheel over the viewport should do.
    screen = 69,
    /// The full tab list, sent on attach and whenever tabs change:
    /// `<active_id>\n` followed by one `<id>\t<title>\n` line per tab.
    /// Titles are sanitized so they cannot contain tabs or newlines.
    tabs = 70,
    /// The daemon switched the active tab to this little-endian u32 id.
    /// Sent before the new tab's history and repaint; the client resets
    /// its local terminal so the two tab states never mix.
    tab_switched = 71,
    _,
};

pub const Msg = struct {
    type: MsgType,
    payload: []const u8,
};

/// 2x u16 little endian: rows, cols. Used by attach and resize.
pub const SizePayload = struct {
    rows: u16,
    cols: u16,

    pub fn encode(self: SizePayload) [4]u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], self.rows, .little);
        std.mem.writeInt(u16, buf[2..4], self.cols, .little);
        return buf;
    }

    pub fn decode(payload: []const u8) error{InvalidPayload}!SizePayload {
        if (payload.len != 4) return error.InvalidPayload;
        return .{
            .rows = std.mem.readInt(u16, payload[0..2], .little),
            .cols = std.mem.readInt(u16, payload[2..4], .little),
        };
    }
};

/// 4-byte little-endian tab id, used by tab_close/tab_select and
/// tab_switched.
pub const IdPayload = struct {
    id: u32,

    pub fn encode(self: IdPayload) [4]u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &buf, self.id, .little);
        return buf;
    }

    pub fn decode(payload: []const u8) error{InvalidPayload}!IdPayload {
        if (payload.len != 4) return error.InvalidPayload;
        return .{ .id = std.mem.readInt(u32, payload[0..4], .little) };
    }
};

/// A terminal color as three 16-bit channels, matching the precision a
/// terminal reports for an OSC 10/11/12 query (`rgb:RRRR/GGGG/BBBB`).
pub const CellSizePayload = struct {
    w: u16,
    h: u16,

    pub fn encode(self: CellSizePayload) [4]u8 {
        var buf: [4]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], self.w, .little);
        std.mem.writeInt(u16, buf[2..4], self.h, .little);
        return buf;
    }

    pub fn decode(payload: []const u8) error{InvalidPayload}!CellSizePayload {
        if (payload.len != 4) return error.InvalidPayload;
        return .{
            .w = std.mem.readInt(u16, payload[0..2], .little),
            .h = std.mem.readInt(u16, payload[2..4], .little),
        };
    }
};

pub const RgbPayload = struct {
    r: u16,
    g: u16,
    b: u16,

    pub fn encode(self: RgbPayload) [6]u8 {
        var buf: [6]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], self.r, .little);
        std.mem.writeInt(u16, buf[2..4], self.g, .little);
        std.mem.writeInt(u16, buf[4..6], self.b, .little);
        return buf;
    }

    pub fn decode(payload: []const u8) error{InvalidPayload}!RgbPayload {
        if (payload.len != 6) return error.InvalidPayload;
        return .{
            .r = std.mem.readInt(u16, payload[0..2], .little),
            .g = std.mem.readInt(u16, payload[2..4], .little),
            .b = std.mem.readInt(u16, payload[4..6], .little),
        };
    }

    /// Perceived luminance on a 0..255 scale (Rec. 601 weights), computed
    /// from the high byte of each channel. Used to classify the
    /// background as light or dark for the color-scheme DSR.
    pub fn luminance(self: RgbPayload) u8 {
        const r: u32 = self.r >> 8;
        const g: u32 = self.g >> 8;
        const b: u32 = self.b >> 8;
        return @intCast((r * 299 + g * 587 + b * 114) / 1000);
    }

    pub fn isDark(self: RgbPayload) bool {
        return self.luminance() < 128;
    }
};

/// Write a full frame to a fd. Handles short writes.
pub fn writeMsg(fd: posix.fd_t, msg_type: MsgType, payload: []const u8) !void {
    std.debug.assert(payload.len <= max_payload);
    var header: [header_len]u8 = undefined;
    header[0] = @intFromEnum(msg_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    try writeAll(fd, &header);
    try writeAll(fd, payload);
}

/// Append a full frame (header + payload) to a growable buffer, for
/// callers that queue output to flush later instead of writing it to a
/// fd right away (e.g. a non-blocking socket with backpressure).
pub fn appendMsg(
    alloc: std.mem.Allocator,
    list: *std.ArrayList(u8),
    msg_type: MsgType,
    payload: []const u8,
) !void {
    std.debug.assert(payload.len <= max_payload);
    var header: [header_len]u8 = undefined;
    header[0] = @intFromEnum(msg_type);
    std.mem.writeInt(u32, header[1..5], @intCast(payload.len), .little);
    try list.appendSlice(alloc, &header);
    try list.appendSlice(alloc, payload);
}

pub fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var i: usize = 0;
    while (i < bytes.len) i += try posix.write(fd, bytes[i..]);
}

/// Incremental frame decoder. Feed bytes as they arrive from the socket,
/// pop complete messages out with next(). Payloads returned by next() are
/// valid until the following call to feed() or next().
pub const Decoder = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    consumed: usize = 0,

    pub fn init(alloc: std.mem.Allocator) Decoder {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Decoder) void {
        self.buf.deinit(self.alloc);
    }

    pub fn feed(self: *Decoder, bytes: []const u8) !void {
        self.compact();
        try self.buf.appendSlice(self.alloc, bytes);
    }

    /// Returns the next complete message, or null if more bytes are needed.
    pub fn next(self: *Decoder) error{PayloadTooLarge}!?Msg {
        self.compact();
        const items = self.buf.items;
        if (items.len < header_len) return null;

        const len = std.mem.readInt(u32, items[1..5], .little);
        if (len > max_payload) return error.PayloadTooLarge;
        const total = header_len + @as(usize, len);
        if (items.len < total) return null;

        self.consumed = total;
        return .{
            .type = @enumFromInt(items[0]),
            .payload = items[header_len..total],
        };
    }

    fn compact(self: *Decoder) void {
        if (self.consumed == 0) return;
        self.buf.replaceRangeAssumeCapacity(0, self.consumed, &.{});
        self.consumed = 0;
    }
};

test "size payload roundtrip" {
    const size: SizePayload = .{ .rows = 51, .cols = 213 };
    const enc = size.encode();
    const dec = try SizePayload.decode(&enc);
    try std.testing.expectEqual(size, dec);
    try std.testing.expectError(error.InvalidPayload, SizePayload.decode("abc"));
}

test "rgb payload roundtrip and luminance" {
    const white: RgbPayload = .{ .r = 0xffff, .g = 0xffff, .b = 0xffff };
    const enc = white.encode();
    try std.testing.expectEqual(white, try RgbPayload.decode(&enc));
    try std.testing.expectError(error.InvalidPayload, RgbPayload.decode("abc"));

    // White is light, black is dark.
    try std.testing.expect(!white.isDark());
    try std.testing.expect((RgbPayload{ .r = 0, .g = 0, .b = 0 }).isDark());
    // A typical dark editor background.
    try std.testing.expect((RgbPayload{ .r = 0x2828, .g = 0x2c2c, .b = 0x3434 }).isDark());
}

test "decoder handles fragmented and coalesced frames" {
    const alloc = std.testing.allocator;
    var dec: Decoder = .init(alloc);
    defer dec.deinit();

    // Build two frames back to back.
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(alloc);
    const payload1 = "hello";
    const payload2 = "";
    try frame.append(alloc, @intFromEnum(MsgType.output));
    try frame.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, payload1.len)));
    try frame.appendSlice(alloc, payload1);
    try frame.append(alloc, @intFromEnum(MsgType.detach_req));
    try frame.appendSlice(alloc, &std.mem.toBytes(std.mem.nativeToLittle(u32, payload2.len)));

    // Feed a single byte at a time; messages appear exactly when complete.
    var seen: usize = 0;
    for (frame.items) |byte| {
        try dec.feed(&.{byte});
        while (try dec.next()) |msg| {
            switch (seen) {
                0 => {
                    try std.testing.expectEqual(MsgType.output, msg.type);
                    try std.testing.expectEqualStrings(payload1, msg.payload);
                },
                1 => {
                    try std.testing.expectEqual(MsgType.detach_req, msg.type);
                    try std.testing.expectEqual(@as(usize, 0), msg.payload.len);
                },
                else => return error.TestUnexpectedResult,
            }
            seen += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), seen);
}

test "decoder rejects oversized payloads" {
    const alloc = std.testing.allocator;
    var dec: Decoder = .init(alloc);
    defer dec.deinit();

    var header: [header_len]u8 = undefined;
    header[0] = @intFromEnum(MsgType.input);
    std.mem.writeInt(u32, header[1..5], max_payload + 1, .little);
    try dec.feed(&header);
    try std.testing.expectError(error.PayloadTooLarge, dec.next());
}

test "CellSizePayload round trips" {
    const p: CellSizePayload = .{ .w = 10, .h = 24 };
    const back = try CellSizePayload.decode(&p.encode());
    try std.testing.expectEqual(@as(u16, 10), back.w);
    try std.testing.expectEqual(@as(u16, 24), back.h);
    try std.testing.expectError(error.InvalidPayload, CellSizePayload.decode("abc"));
}
