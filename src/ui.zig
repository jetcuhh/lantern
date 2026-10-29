//! lantern: one session, many tabs. The UI paints the active tab's terminal
//! full-screen with a tab bar along the top row.
//!
//! The session daemon owns the tabs (each a PTY-attached child with its
//! own libghostty terminal state) and passes through only the active
//! tab's output. This client is a compositor: that output feeds a local
//! libghostty terminal sized to the viewport, and the UI repaints
//! changed rows from that terminal state, exactly the way a plain attach
//! rehydrates from the daemon. Switching tabs resets the local terminal
//! and replays the new tab's state from the daemon.
//!
//! The local terminal also stands in for a real terminal in both
//! directions: it answers terminal queries (DSR, DA, ...) by sending the
//! reply back to the session as input, and its mode state decides
//! whether mouse, focus, and bracketed-paste events are forwarded to the
//! application.
//!
//! Kitty graphics follow the same split: the local terminal parses the
//! images an application transmits, and the compositor re-emits them to
//! the real terminal (`KittyState`), caching pixels by image identity so
//! only placements are rebuilt as the viewport scrolls.

const std = @import("std");
const posix = @import("sys.zig");
const vt = @import("ghostty-vt");

const client = @import("client.zig");
const keys = @import("keys.zig");
const kittygfx = @import("kitty.zig");
const osc52 = @import("osc52.zig");
const osc72 = @import("osc72.zig");
const protocol = @import("protocol.zig");
const ptypkg = @import("pty.zig");
const windowpkg = @import("window.zig");

const log = std.log.scoped(.ui);

/// Render coalescing: at most one repaint per interval while output
/// is streaming.
const render_interval_ms: i64 = 15;
/// While a freshly switched tab is being seeded, the previous frame is
/// held on screen until the new tab's repaint arrives (its `.screen`
/// marker), so the viewport never flashes blank in between. This bounds
/// the wait, measured from the last byte of the seeding stream: if the
/// repaint stalls, or its marker is lost, the hold releases rather than
/// freezing the UI.
const awaiting_repaint_timeout_ms: i64 = 500;
/// A lone ESC held by the input parser is delivered as session input
/// after this long without a follow-up byte. Escape sequences arrive
/// as one chunk, so only a human pressing the ESC key waits this long.
const esc_flush_ms: i64 = 50;
/// Rows per mouse wheel tick, both for paging local scrollback and for
/// the arrow keys sent to alternate-screen applications.
const wheel_lines = 3;
/// Kitty keyboard flags lantern forces on the real terminal while the C-w
/// prefix is engaged: "disambiguate" (1), "report event types" (2), and
/// "report all keys as escape codes" (8). With these the command key and
/// its auto-repeats and release arrive as distinguishable CSI-u events,
/// so a held command key is swallowed deterministically instead of
/// leaking into the focused tab. Terminals without the kitty protocol
/// ignore the request.
const report_events_flags: u5 = 0b01011;

// -- Layout -----------------------------------------------------------------

/// Screen geometry: the top row is the tab bar and the terminal viewport
/// fills every row below it. A status overlay (the quit prompt or the
/// armed-prefix keybind list) borrows the tab bar row while it has
/// something to show; the tab bar repaints when it clears.
pub const Layout = struct {
    rows: u16,
    cols: u16,

    /// Rows reserved for the tab bar, pinned to the top.
    pub const tabbar_h: u16 = 1;

    pub fn init(rows: u16, cols: u16) Layout {
        return .{ .rows = rows, .cols = cols };
    }

    pub fn viewportRows(self: Layout) u16 {
        return self.rows -| tabbar_h;
    }

    pub fn viewportCols(self: Layout) u16 {
        return self.cols;
    }

    /// First viewport screen row, 0-based: the tab bar takes the top row.
    pub fn viewportTop(_: Layout) u16 {
        return tabbar_h;
    }

    /// First viewport column, 0-based. The viewport spans the full
    /// width; the tab bar is a separate row.
    pub fn viewportX(_: Layout) u16 {
        return 0;
    }

    /// Whether screen row `y` is the tab bar.
    pub fn isTabBar(_: Layout, y: u16) bool {
        return y < tabbar_h;
    }

    pub const Hit = union(enum) {
        viewport: struct { x: u16, y: u16 },
        tabbar: struct { x: u16 },
        none,
    };

    /// Map a 0-based screen coordinate to a UI region. A viewport cell
    /// carries its row within the viewport (0 is the first row below the
    /// tab bar).
    pub fn hit(self: Layout, x: u16, y: u16) Hit {
        if (y >= self.rows or x >= self.cols) return .none;
        if (self.isTabBar(y)) return .{ .tabbar = .{ .x = x } };
        return .{ .viewport = .{ .x = x, .y = y - tabbar_h } };
    }
};

// -- Input parsing ----------------------------------------------------------

/// A mouse report from the terminal (SGR 1006 encoding).
pub const Mouse = struct {
    /// Raw SGR button code: low bits select the button, bit 2..4 are
    /// modifiers, bit 5 marks motion, bit 6 marks wheel buttons.
    code: u16,
    /// 1-based terminal column.
    x: u16,
    /// 1-based terminal row.
    y: u16,
    release: bool,

    pub fn isWheel(self: Mouse) bool {
        return self.code & 64 != 0;
    }

    pub fn isMotion(self: Mouse) bool {
        return self.code & 32 != 0;
    }
};

pub const InputEvent = union(enum) {
    /// Bytes destined for the focused session.
    forward: []const u8,
    /// Ctrl+C. With a live selection the UI copies it; otherwise the
    /// bytes are forwarded as the interrupt. Carries the original
    /// encoding so an unconsumed interrupt reaches the session exactly
    /// as the terminal sent it.
    copy: []const u8,
    /// Ctrl+Shift+C: copy the retained selection, exactly like C-w y.
    /// Unlike Ctrl+C there is no interrupt to fall back to, so an
    /// empty selection reports it rather than forwarding anything.
    copy_selection,
    /// Command key following the C-w prefix.
    prefix: u8,
    /// Plain arrow key (ESC [ A/B/C/D).
    arrow: Arrow,
    mouse: Mouse,
    /// Bracketed paste begin (true) / end (false).
    paste: bool,
    /// Focus in (true) / out (false).
    focus: bool,
    /// The Esc key: a lone 0x1b delivered after the flush timeout, or
    /// its kitty CSI-u encoding. Carries the original bytes so an
    /// unconsumed Esc forwards to the session exactly as typed.
    esc: []const u8,

    pub const Arrow = struct {
        dir: Dir,
        /// The original bytes, forwarded verbatim, so a modified arrow
        /// or the report-events encoding the terminal used reaches the
        /// application intact. Empty for arrows constructed without a
        /// source sequence; `bytes()` then falls back to the legacy
        /// form.
        seq: []const u8 = &.{},

        pub const Dir = enum { up, down, left, right };

        /// Bytes to forward to the application: the original sequence
        /// when present, else the legacy encoding of the direction.
        pub fn bytes(self: Arrow) []const u8 {
            if (self.seq.len > 0) return self.seq;
            return switch (self.dir) {
                .up => "\x1b[A",
                .down => "\x1b[B",
                .right => "\x1b[C",
                .left => "\x1b[D",
            };
        }
    };
};

/// Synthetic command key following the C-w prefix: Shift-Tab has no
/// single-byte encoding (it arrives as `ESC [ Z`, or a kitty CSI-u Tab
/// with the shift modifier), so the parser reports it with this code.
const prefix_prev_tab: u8 = 0xff;

/// Splits raw terminal input into session bytes and UI events: the
/// C-w prefix, SGR mouse reports, focus reports, and bracketed paste
/// markers. Everything else passes through untouched. While a paste
/// is open the prefix byte is NOT special, so pasted 0x17 bytes reach
/// the application (unlike a plain attach).
///
/// When the focused application runs the kitty keyboard protocol or
/// xterm modifyOtherKeys the real terminal mirrors that state, so the
/// parser also recognizes the encodings of the prefix key, of the
/// command key that follows it, and (kitty only) of the Esc key;
/// every other encoded key passes through to the session unchanged.
pub const InputParser = struct {
    /// A C-w was seen; the next byte is a command key.
    pending_prefix: bool = false,
    /// Held bytes of a possible CSI sequence that may need to be
    /// intercepted (arrows, mouse/focus/paste reports, and
    /// parameterized keys such as kitty CSI-u). Replayed verbatim the
    /// moment the sequence diverges.
    held: [hold_max]u8 = undefined,
    held_len: u8 = 0,
    /// The held sequence followed an armed prefix: an arrow binds to
    /// it (C-w Up/Down) and an encoded key decodes to the command
    /// key; anything else cancels the prefix as before.
    prefix_held: bool = false,
    in_paste: bool = false,
    /// Which encoded-key decodes are active: the real terminal
    /// mirrors the focused application's kitty flags and
    /// modifyOtherKeys state. The hold grammar itself is always on,
    /// so a sequence in flight while the mirror flips replays whole
    /// instead of splitting.
    prot: keys.Protocols = .{},
    /// Codepoint of the command key that ran the most recent prefix
    /// command while its auto-repeats and release are still expected.
    /// The UI forces kitty report-events for the duration, so the held
    /// key's repeat (event 2) and release (event 3) arrive as CSI-u
    /// events and are dropped here instead of leaking into the
    /// now-focused session. Null when no command key is being released.
    swallow_cp: ?u32 = null,
    /// Inside a kitty-graphics reply (`ESC _ G ... ST`). The real
    /// terminal sends these in answer to lantern's own image re-emit; they
    /// belong to lantern, not the application, so they are swallowed whole
    /// rather than forwarded as input and echoed as text.
    in_apc: bool = false,
    /// Saw the ESC of an ST (`ESC \`) while inside an APC.
    apc_esc: bool = false,
    /// APC bytes consumed so far, bounding a malformed, unterminated one.
    apc_len: u32 = 0,
    /// Inside a late OSC 11 background reply (`ESC ] 11 ; rgb:... BEL`).
    /// The startup probe waits only a moment for the terminal's answer;
    /// over a slow link the reply arrives afterwards and, unrecognized,
    /// would be typed into the focused tab as `]11;rgb:...` garbage.
    in_osc: bool = false,
    /// Saw the ESC of an ST (`ESC \`) while inside that reply.
    osc_esc: bool = false,
    /// Reply bytes consumed so far, bounding an unterminated one.
    osc_len: u32 = 0,

    const hold_max = 40;
    /// The fixed start of an OSC 11 color reply.
    const osc11_reply_prefix = "\x1b]11;rgb:";
    const osc_max = 96;
    /// Longest kitty reply swallowed. Replies are short; the bound keeps
    /// a stray or unterminated APC from eating the rest of the stream.
    const apc_max = 4096;

    /// Process a chunk of input. Calls handler.event for every parsed
    /// event, including .forward runs of passthrough bytes. The
    /// handler must consume event payloads immediately (they alias
    /// `input` or the parser's internal hold buffer).
    ///
    /// `prot` enables decoding of kitty-keyboard CSI-u and
    /// modifyOtherKeys encodings; pass what the real terminal
    /// currently mirrors. The raw prefix byte is always recognized.
    pub fn feed(self: *InputParser, input: []const u8, prot: keys.Protocols, handler: anytype) !void {
        self.prot = prot;
        // Without the kitty protocol there are no release events to end
        // a command-key swallow, so never let a stale one linger.
        if (!prot.kitty) self.swallow_cp = null;
        var start: usize = 0;
        var i: usize = 0;
        while (i < input.len) {
            const byte = input[i];

            if (self.in_apc) {
                self.apc_len += 1;
                if (self.apc_esc) {
                    self.apc_esc = false;
                    if (byte == '\\') {
                        self.in_apc = false;
                        self.apc_len = 0;
                    }
                } else if (byte == 0x1b) {
                    self.apc_esc = true;
                }
                i += 1;
                start = i;
                if (self.in_apc and self.apc_len >= apc_max) {
                    // Unterminated reply: stop swallowing so real input
                    // is not lost to a malformed stream.
                    self.in_apc = false;
                    self.apc_len = 0;
                }
                continue;
            }

            if (self.in_osc) {
                self.osc_len += 1;
                if (self.osc_esc) {
                    self.osc_esc = false;
                    if (byte == '\\') {
                        self.in_osc = false;
                        self.osc_len = 0;
                    }
                } else if (byte == 0x07) {
                    self.in_osc = false;
                    self.osc_len = 0;
                } else if (byte == 0x1b) {
                    self.osc_esc = true;
                }
                i += 1;
                start = i;
                if (self.in_osc and self.osc_len >= osc_max) {
                    // Unterminated: stop swallowing so real input is not
                    // lost to a malformed stream.
                    self.in_osc = false;
                    self.osc_len = 0;
                }
                continue;
            }

            if (self.held_len > 0) {
                if (self.held_len == 1 and byte == ']' and !self.in_paste and !self.pending_prefix) {
                    // `ESC ]`: maybe a late OSC 11 reply. Hold it and
                    // match the fixed reply prefix byte by byte; anything
                    // else replays verbatim (Alt+] stays Alt+]).
                    self.held[1] = byte;
                    self.held_len = 2;
                    i += 1;
                    start = i;
                    continue;
                }
                if (self.held_len >= 2 and self.held[1] == ']') {
                    if (byte == osc11_reply_prefix[self.held_len]) {
                        self.held[self.held_len] = byte;
                        self.held_len += 1;
                        i += 1;
                        start = i;
                        if (self.held_len == osc11_reply_prefix.len) {
                            // A complete prefix: swallow the rest.
                            self.held_len = 0;
                            self.prefix_held = false;
                            self.in_osc = true;
                            self.osc_esc = false;
                            self.osc_len = osc11_reply_prefix.len;
                        }
                        continue;
                    }
                    try self.flushHeld(handler);
                    continue;
                }
                if (self.held_len == 1 and byte == '_' and !self.in_paste) {
                    // `ESC _`: maybe a kitty-graphics reply. Hold the
                    // introducer and decide on the next byte. The held
                    // buffer is otherwise only for `ESC [` sequences,
                    // so this is not something the CSI decoder handles.
                    self.held[1] = byte;
                    self.held_len = 2;
                    i += 1;
                    start = i;
                    continue;
                }
                if (self.held_len == 2 and self.held[1] == '_') {
                    if (byte == 'G') {
                        // `ESC _ G`: a kitty-graphics reply. It answers
                        // lantern's own image re-emit, so swallow it whole
                        // rather than forward it into the application,
                        // which would echo it as text.
                        self.held_len = 0;
                        self.prefix_held = false;
                        self.in_apc = true;
                        self.apc_esc = false;
                        self.apc_len = 3;
                        i += 1;
                        start = i;
                        continue;
                    }
                    // Not a kitty reply: replay `ESC _` verbatim and
                    // reprocess this byte.
                    try self.flushHeld(handler);
                    continue;
                }
                if (self.heldAccepts(byte)) {
                    self.held[self.held_len] = byte;
                    self.held_len += 1;
                    i += 1;
                    start = i;
                    if (isCsiFinal(byte)) try self.finishCsi(handler);
                    if (self.held_len == hold_max) try self.flushHeld(handler);
                } else {
                    try self.flushHeld(handler);
                }
                continue;
            }

            if (self.pending_prefix) {
                self.pending_prefix = false;
                if (byte == 0x1b) {
                    // Esc backs out of the armed prefix. A lone Esc
                    // is the cancel key and is consumed; when more
                    // bytes follow immediately it starts a key or
                    // mouse sequence, which must be reprocessed so
                    // its tail is not typed into the application. An
                    // arrow sequence binds back to the prefix
                    // (C-w Up/Down) via prefix_held. Under a mirrored
                    // keyboard protocol the command key itself
                    // arrives ESC-encoded, so a bare ESC ending the
                    // read is a split sequence and is held instead.
                    if (!self.prot.any() and i + 1 == input.len) {
                        i += 1;
                    } else {
                        self.prefix_held = true;
                    }
                    start = i;
                    continue;
                }
                i += 1;
                start = i;
                // The command key may still be held; begin swallowing
                // its repeats and release. A control byte (C-d) maps to
                // its letter keycode so a kitty release of the same
                // physical key matches. Inert without report-events.
                self.swallow_cp = if (byte < 0x20) @as(u32, byte) | 0x60 else byte;
                try handler.event(.{ .prefix = byte });
                continue;
            }

            if (byte == 0x1b) {
                if (i > start) try handler.event(.{ .forward = input[start..i] });
                self.held[0] = byte;
                self.held_len = 1;
                i += 1;
                start = i;
                continue;
            }

            if (byte == keys.escape_byte and !self.in_paste) {
                if (i > start) try handler.event(.{ .forward = input[start..i] });
                self.pending_prefix = true;
                i += 1;
                start = i;
                continue;
            }

            // Ctrl+C: singled out so the UI can copy a live selection
            // instead of interrupting. Without a selection it forwards
            // the byte, so the session still gets the interrupt.
            if (byte == 0x03 and !self.in_paste) {
                if (i > start) try handler.event(.{ .forward = input[start..i] });
                try handler.event(.{ .copy = input[i .. i + 1] });
                i += 1;
                start = i;
                continue;
            }

            i += 1;
        }

        if (i > start) try handler.event(.{ .forward = input[start..i] });
    }

    /// Whether `byte` keeps the held bytes a candidate for a sequence
    /// this parser handles as a unit: plain and functional arrows
    /// (ESC [ A/B/C/D and ESC [ 1 ; mods [: event] A/B/C/D), CSI
    /// mouse (ESC [ < ... M/m), focus (ESC [ I, ESC [ O), and
    /// parameterized keys (ESC [ <digits...> [;:] ... ~/u): paste
    /// markers, kitty CSI-u keys, modifyOtherKeys, and legacy keys
    /// that share the grammar (F5 is ESC [ 15 ~). Holding never
    /// depends on the protocol state; finishCsi decodes encoded keys
    /// only while the matching protocol is active and replays them
    /// verbatim otherwise.
    fn heldAccepts(self: *const InputParser, byte: u8) bool {
        const len = self.held_len;
        if (len == 1) return byte == '[';
        if (len == 2) return switch (byte) {
            '<', 'I', 'O', '0'...'9', 'A', 'B', 'C', 'D' => true,
            'Z' => true, // ESC [ Z: Back-Tab (Shift-Tab)
            else => false,
        };
        return switch (self.held[2]) {
            '<' => switch (byte) {
                '0'...'9', ';', 'M', 'm' => true,
                else => false,
            },
            '0'...'9' => switch (byte) {
                // A/B/C/D close the functional cursor-key form
                // (ESC [ 1 ; mods [: event] A); ~/u close paste,
                // kitty, and modifyOtherKeys keys.
                '0'...'9', ';', ':', '~', 'u', 'A', 'B', 'C', 'D' => true,
                else => false,
            },
            else => false,
        };
    }

    fn isCsiFinal(byte: u8) bool {
        return switch (byte) {
            'M', 'm', '~', 'I', 'O', 'A', 'B', 'C', 'D', 'Z', 'u' => true,
            else => false,
        };
    }

    fn finishCsi(self: *InputParser, handler: anytype) !void {
        const seq = self.held[0..self.held_len];
        const body = seq[2 .. seq.len - 1];
        const final = seq[seq.len - 1];
        const prefixed = self.prefix_held;
        self.prefix_held = false;

        // Shift-Tab, `ESC [ Z`: after the prefix it walks to the previous
        // tab; otherwise it is the application's input, replayed intact.
        if (final == 'Z') {
            if (body.len != 0 or !prefixed) return self.flushHeld(handler);
            self.held_len = 0;
            return handler.event(.{ .prefix = prefix_prev_tab });
        }

        // Arrows. A bare ESC [ A/B/C/D directly after the bracket is
        // an unmodified cursor key; the functional form
        // ESC [ 1 ; mods [: event] A/B/C/D carries modifiers and, when
        // the terminal reports event types, even an unmodified press.
        // An unmodified press or repeat becomes an arrow event carrying
        // the original bytes; modified arrows (Ctrl+Left word motion)
        // and release events are the application's input and replay
        // verbatim.
        switch (final) {
            'A', 'B', 'C', 'D' => {
                if (body.len == 0 or arrowNavigates(body)) {
                    self.held_len = 0;
                    return handler.event(.{ .arrow = .{
                        .dir = switch (final) {
                            'A' => .up,
                            'B' => .down,
                            'C' => .right,
                            else => .left,
                        },
                        .seq = seq,
                    } });
                }
                return self.flushHeld(handler);
            },
            else => {},
        }

        // Kitty CSI-u keys. Pasted content is the application's
        // verbatim, like the raw prefix byte.
        if (final == 'u') {
            if (!self.prot.kitty or self.in_paste) return self.flushHeld(handler);
            return self.finishCsiU(prefixed, handler);
        }

        // Focus reports arrive as a bare final byte.
        if (final == 'I' or final == 'O') {
            if (body.len != 0) return self.flushHeld(handler);
            self.held_len = 0;
            return handler.event(.{ .focus = final == 'I' });
        }

        if (final == '~') {
            if (std.mem.eql(u8, body, "200")) {
                self.held_len = 0;
                self.in_paste = true;
                return handler.event(.{ .paste = true });
            }
            if (std.mem.eql(u8, body, "201")) {
                self.held_len = 0;
                self.in_paste = false;
                return handler.event(.{ .paste = false });
            }
            // xterm modifyOtherKeys keys, under the same mirror-and-
            // paste rules as CSI-u.
            if (self.prot.modify and !self.in_paste) {
                return self.finishModify(prefixed, handler);
            }
            return self.flushHeld(handler);
        }

        // SGR mouse: ESC [ < code ; x ; y (M|m).
        if (body.len == 0 or body[0] != '<') return self.flushHeld(handler);
        var it = std.mem.splitScalar(u8, body[1..], ';');
        const code = parseField(it.next()) orelse return self.flushHeld(handler);
        const x = parseField(it.next()) orelse return self.flushHeld(handler);
        const y = parseField(it.next()) orelse return self.flushHeld(handler);
        if (it.next() != null) return self.flushHeld(handler);
        self.held_len = 0;
        return handler.event(.{ .mouse = .{
            .code = code,
            .x = x,
            .y = y,
            .release = final == 'm',
        } });
    }

    /// A complete `ESC [ ... u` sequence is in the hold buffer: a
    /// kitty CSI-u key. Intercepts the prefix key, the command key
    /// that follows an armed prefix, and the Esc key, mirroring
    /// keys.Parser (including base-layout-key matching for non-Latin
    /// layouts); every other key is the application's input.
    fn finishCsiU(self: *InputParser, prefixed: bool, handler: anytype) !void {
        const seq = self.held[0..self.held_len];
        const key = keys.parseKitty(seq[2 .. seq.len - 1]) orelse
            return self.flushHeld(handler);

        // Modifier bitmask with the lock bits ignored: caps lock or
        // num lock must not hide the prefix.
        const mods = (key.mods -| 1) & 0x3f;
        const ctrl_only = mods == 0x4;
        const ctrl_shift = mods == 0x5;
        const plain = mods == 0;
        const release = key.event == 3;
        const cp = keys.effectiveCp(key);

        if (prefixed) {
            self.held_len = 0;
            // A release while the command key is awaited is the
            // prefix key itself being let go; stay armed.
            if (release) {
                self.pending_prefix = true;
                return;
            }
            // The prefix key repeating while still held is not a
            // command key; stay armed. A discrete second press is
            // the C-w C-w binding (focus last), exactly like a
            // second raw 0x17, and dispatches below.
            if (cp == keys.prefix_cp and ctrl_only and key.event == 2) {
                self.pending_prefix = true;
                return;
            }
            // Modifier and lock keys are reported as keys of their
            // own under the kitty "report all keys" flag; holding or
            // tapping one while armed must not eat the command key.
            if (keys.isModifierKey(key.cp)) {
                self.pending_prefix = true;
                return;
            }
            // Esc backs out of the armed prefix, like the raw byte.
            if (key.cp == 27 and plain) return;
            // The command key may still be held: begin swallowing its
            // auto-repeats and release so they do not leak into the
            // session once the command runs.
            self.swallow_cp = key.cp;
            // Tab walks forward; Shift-Tab walks back. Under the kitty
            // protocol both encode the same keycode with different
            // modifiers.
            if (cp == '\t' and mods <= 0x1) {
                return handler.event(.{
                    .prefix = if (mods == 0x1) prefix_prev_tab else '\t',
                });
            }
            if (ctrl_only and cp >= 'a' and cp <= 'z') {
                return handler.event(.{ .prefix = @intCast(cp & 0x1f) });
            }
            if (plain and cp >= 0x20 and cp <= 0x7f) {
                return handler.event(.{ .prefix = @intCast(cp) });
            }
            return handler.event(.{
                .prefix = if (cp <= 0x7f) @as(u8, @intCast(cp)) else '?',
            });
        }

        // The command key that ran a prefix command may still be held:
        // under the forced report-events flags its own auto-repeats
        // (event 2) and release (event 3) arrive as CSI-u events.
        // Swallow them, plus any modifier-key noise from the C-w chord,
        // until the key is released, so none of it reaches the
        // now-focused session.
        if (self.swallow_cp) |held_cp| {
            if (key.cp == held_cp) {
                self.held_len = 0;
                if (release) self.swallow_cp = null;
                return;
            }
            if (keys.isModifierKey(key.cp)) {
                self.held_len = 0;
                return;
            }
            // Any other real key means the command key's hold is over.
            self.swallow_cp = null;
        }

        if (cp == keys.prefix_cp and ctrl_only) {
            self.held_len = 0;
            // Releases are swallowed: the session never saw the press.
            if (!release) self.pending_prefix = true;
            return;
        }

        // Ctrl+C: the UI copies a live selection, else forwards the
        // interrupt exactly as the terminal encoded it.
        if (cp == 'c' and ctrl_only) {
            self.held_len = 0;
            return handler.event(.{ .copy = seq });
        }

        // Ctrl+Shift+C: a pure copy binding, the same as C-w y. The
        // shifted codepoint may be reported as 'C' or as 'c' with the
        // shift subfield, so match either case.
        if (ctrl_shift and (cp | 0x20) == 'c') {
            self.held_len = 0;
            return handler.event(.{ .copy_selection = {} });
        }

        if (key.cp == 27 and plain and !release) {
            // The Esc key, unambiguously encoded: deliver it as the
            // cancel key, with the original bytes for forwarding.
            self.held_len = 0;
            return handler.event(.{ .esc = seq });
        }

        // Some other key (Shift+Enter, ...): the session's input,
        // exactly as the terminal encoded it. This includes
        // the release of a key whose press the UI consumed (Esc
        // after cancelling a prompt): kitty applications must
        // tolerate unmatched releases, e.g. after a focus change, so
        // no swallow state is kept.
        try self.flushHeld(handler);
    }

    /// A complete `ESC [ ... ~` non-paste sequence is in the hold
    /// buffer while modifyOtherKeys is mirrored: possibly an xterm
    /// `CSI 27;mods;cp~` key. Intercepts the prefix key and the
    /// command key after an armed prefix, mirroring keys.Parser. The
    /// protocol has no event types and never encodes an unmodified
    /// Esc, so there is no release or cancel handling; a repeat of
    /// the held prefix key is indistinguishable from a second press
    /// and dispatches C-w C-w, exactly like repeated raw 0x17 bytes.
    fn finishModify(self: *InputParser, prefixed: bool, handler: anytype) !void {
        const seq = self.held[0..self.held_len];
        const key = keys.parseModify(seq[2 .. seq.len - 1]) orelse
            return self.flushHeld(handler);

        const mods = (key.mods -| 1) & 0x3f;
        const ctrl_only = mods == 0x4;
        const ctrl_shift = mods == 0x5;
        const plain = mods == 0;

        if (prefixed) {
            self.held_len = 0;
            if (ctrl_only and key.cp >= 'a' and key.cp <= 'z') {
                return handler.event(.{ .prefix = @intCast(key.cp & 0x1f) });
            }
            if (plain and key.cp >= 0x20 and key.cp <= 0x7f) {
                return handler.event(.{ .prefix = @intCast(key.cp) });
            }
            return handler.event(.{
                .prefix = if (key.cp <= 0x7f) @as(u8, @intCast(key.cp)) else '?',
            });
        }

        if (key.cp == keys.prefix_cp and ctrl_only) {
            self.held_len = 0;
            self.pending_prefix = true;
            return;
        }

        // Ctrl+C: the UI copies a live selection, else forwards the
        // interrupt exactly as the terminal encoded it.
        if (key.cp == 'c' and ctrl_only) {
            const enc = self.held[0..self.held_len];
            self.held_len = 0;
            return handler.event(.{ .copy = enc });
        }

        // Ctrl+Shift+C: a pure copy binding, the same as C-w y.
        if (ctrl_shift and (key.cp | 0x20) == 'c') {
            self.held_len = 0;
            return handler.event(.{ .copy_selection = {} });
        }

        // Some other key (Ctrl+Shift+H, ...): the session's input,
        // exactly as the terminal encoded it.
        try self.flushHeld(handler);
    }

    fn parseField(field: ?[]const u8) ?u16 {
        const text = field orelse return null;
        return std.fmt.parseInt(u16, text, 10) catch null;
    }

    /// Whether the body of a functional cursor key
    /// (ESC [ 1 ; mods [: event] A/B/C/D) is an unmodified press or
    /// repeat, so it becomes an arrow event rather than replaying
    /// verbatim. A modified arrow (mods other than none, ignoring lock
    /// bits) or a release event belongs to the application and replays
    /// verbatim. The leading parameter is always `1` for these keys.
    fn arrowNavigates(body: []const u8) bool {
        var sections = std.mem.splitScalar(u8, body, ';');
        const first = sections.next() orelse return false;
        if (!std.mem.eql(u8, first, "1")) return false;
        const mods_section = sections.next() orelse return false;
        if (sections.next() != null) return false;
        var fields = std.mem.splitScalar(u8, mods_section, ':');
        const mods_text = fields.next() orelse return false;
        const mods = std.fmt.parseInt(u32, mods_text, 10) catch return false;
        // Lock bits (caps/num) do not count as a real modifier.
        if ((mods -| 1) & 0x3f != 0) return false;
        if (fields.next()) |event_text| {
            const event = std.fmt.parseInt(u32, event_text, 10) catch return false;
            // 1 press, 2 repeat navigate; 3 release does not.
            if (event != 1 and event != 2) return false;
        }
        if (fields.next() != null) return false;
        return true;
    }

    /// Replay held bytes as session input: the sequence is some other
    /// key encoding (function keys, modified arrows, ...) that belongs
    /// to the application.
    fn flushHeld(self: *InputParser, handler: anytype) !void {
        const held = self.held[0..self.held_len];
        self.held_len = 0;
        self.prefix_held = false;
        if (held.len > 0) try handler.event(.{ .forward = held });
    }

    /// Deliver a held lone ESC as the Esc key: the flush timeout
    /// passed without follow-up bytes, so the user pressed the key
    /// itself. After an armed prefix it is the cancel key and is
    /// consumed. Any other hold replays as plain input.
    pub fn flushEsc(self: *InputParser, handler: anytype) !void {
        if (self.held_len != 1 or self.held[0] != 0x1b) {
            return self.flushHeld(handler);
        }
        self.held_len = 0;
        if (self.prefix_held) {
            self.prefix_held = false;
            return;
        }
        try handler.event(.{ .esc = &.{0x1b} });
    }
};

// -- Focused session view ----------------------------------------------------

/// Sink for `osc52.Filter`: writes a forwarded clipboard sequence to
/// the real terminal (fd 1), the same destination as the ui's own
/// selection copy.
const ClipboardSink = struct {
    pub fn clipboard(_: ClipboardSink, seq: []const u8) void {
        protocol.writeAll(1, seq) catch {};
    }
};

/// Sink for `osc72.Filter`: a complete OSC 72 command goes verbatim to
/// the real terminal (fd 1), where native drops live; every other byte
/// stays in the view canvas's terminal stream.
const DndSink = struct {
    view: *View,

    pub fn plain(self: DndSink, bytes: []const u8) void {
        self.view.stream.nextSlice(bytes);
    }

    pub fn sequence(_: DndSink, seq: []const u8) void {
        protocol.writeAll(1, seq) catch {};
    }
};

/// The attach connection and local terminal state of the focused
/// session. Heap-allocated and pinned: the stream handler keeps a
/// pointer to `term`, and effects callbacks recover the View with
/// @fieldParentPtr (the same shape as window.Window).
pub const View = struct {
    alloc: std.mem.Allocator,
    sock: posix.fd_t,
    decoder: protocol.Decoder,
    term: vt.Terminal,
    stream: Stream,
    state: State = .live,
    /// The application rang the bell; the UI forwards it.
    bell: bool = false,
    /// The application is on the alternate screen, per the daemon's
    /// `.screen` messages. Decides whether a wheel over the viewport
    /// pages local scrollback or sends arrow keys.
    app_alt: bool = false,
    /// Recovers application clipboard writes (OSC 52) from the output
    /// stream so a copy inside the session reaches the real terminal
    /// (see osc52.zig and feedOutput).
    clip: osc52.Filter = .{},
    /// Forward application OSC 52 clipboard writes to the real terminal.
    /// Off when `LANTERN_OSC52` is 0/off/false.
    clip_enabled: bool = true,
    /// Recovers application OSC 72 drag-and-drop commands from the output
    /// stream so the real terminal, which owns native drops, can answer
    /// them (see osc72.zig and feedOutput).
    dnd: osc72.Filter = .{},
    /// The real terminal's background, for answering the color-scheme DSR
    /// (CSI ? 996 n) from this view's terminal: while a view shows a tab
    /// the daemon leaves queries to the view, so nobody else would.
    bg: ?protocol.RgbPayload = null,

    pub const State = enum { live, ended, lost };
    pub const Stream = vt.TerminalStream;

    pub fn create(
        io: std.Io,
        alloc: std.mem.Allocator,
        socket_path: []const u8,
        rows: u16,
        cols: u16,
        bg: ?protocol.RgbPayload,
    ) !*View {
        const self = try alloc.create(View);
        errdefer alloc.destroy(self);

        const sock = try client.connect(alloc, socket_path);
        errdefer posix.close(sock);

        self.* = .{
            .alloc = alloc,
            .sock = sock,
            .decoder = .init(alloc),
            .term = undefined,
            .stream = undefined,
            .clip_enabled = osc52Enabled(),
            .bg = bg,
        };
        errdefer self.decoder.deinit();

        self.term = try vt.Terminal.init(io, alloc, .{
            .cols = @max(cols, 1),
            .rows = @max(rows, 1),
            // Output that scrolls off while attached accumulates
            // here; the wheel pages through it for primary-screen
            // applications.
            .max_scrollback_bytes = windowpkg.scrollbackBytes(),
        });
        errdefer self.term.deinit(alloc);

        // Kitty graphics place relative to the cell grid in pixels; the
        // nominal metrics match what the daemon reports to applications.
        self.term.width_px = @as(u32, self.term.cols) * kittygfx.cell_px_w;
        self.term.height_px = @as(u32, self.term.rows) * kittygfx.cell_px_h;

        var handler: Stream.Handler = .init(&self.term);
        handler.effects = .readonly;
        handler.effects.write_pty = effectWritePty;
        handler.effects.bell = effectBell;
        handler.effects.color_scheme = effectColorScheme;
        handler.effects.device_attributes = effectDeviceAttributes;
        handler.effects.size = effectSize;
        handler.effects.xtversion = effectXtversion;
        // Applications' notifications and progress reports have no
        // window of their own here: relay them to the real terminal,
        // which owns the notification daemon and the taskbar entry.
        handler.effects.desktop_notification = effectDesktopNotification;
        handler.effects.progress_report = effectProgressReport;
        self.stream = .init(.{ .handler = handler, .allocator = alloc });
        errdefer self.stream.deinit();

        // Mark this connection as a ui view before attaching, so the
        // daemon replays scrollback history on attach. A ui view renders
        // from terminal state, so it can take the replay and page it on
        // a wheel-up. An older daemon ignores the unknown `.ui` message
        // and just attaches with no history.
        try protocol.writeMsg(sock, .ui, "");
        // Report the real terminal's cell size before attaching so the
        // tab's applications size images against it. Best effort: an
        // older daemon ignores it and keeps its nominal cells.
        const cell_size: protocol.CellSizePayload = .{
            .w = @intCast(kittygfx.cell_px_w),
            .h = @intCast(kittygfx.cell_px_h),
        };
        protocol.writeMsg(sock, .cell_size, &cell_size.encode()) catch {};
        // Refresh the environment new tabs start with (best effort).
        sendSessionEnv(alloc, sock);
        try protocol.writeMsg(sock, .attach, &(protocol.SizePayload{
            .rows = @max(rows, 1),
            .cols = @max(cols, 1),
        }).encode());
        // Tell the daemon the real terminal's background so the session
        // can detect the theme via OSC 11 (see window.zig). Best effort:
        // a session simply keeps its prior behavior without it.
        if (bg) |color| protocol.writeMsg(sock, .bg_color, &color.encode()) catch {};

        return self;
    }

    pub fn destroy(self: *View) void {
        // Ask for an orderly detach; the daemon also detaches on EOF
        // if the request is lost.
        if (self.state == .live) {
            protocol.writeMsg(self.sock, .detach_req, "") catch {};
        }
        posix.close(self.sock);
        self.stream.deinit();
        self.term.deinit(self.alloc);
        self.decoder.deinit();
        self.clip.deinit(self.alloc);
        self.dnd.deinit(self.alloc);
        self.alloc.destroy(self);
    }

    fn fromHandler(handler: *Stream.Handler) *View {
        const stream: *Stream = @alignCast(@fieldParentPtr("handler", handler));
        return @alignCast(@fieldParentPtr("stream", stream));
    }

    /// Query replies (DSR, DA, OSC color queries, ...) generated by
    /// the local terminal go back to the session as input, exactly as
    /// a real terminal would answer them.
    fn effectWritePty(handler: *Stream.Handler, data: []const u8) void {
        const self = fromHandler(handler);
        self.sendInput(data) catch |err| {
            log.warn("query reply failed: {}", .{err});
        };
    }

    fn effectBell(handler: *Stream.Handler) void {
        fromHandler(handler).bell = true;
    }

    fn effectDesktopNotification(
        handler: *Stream.Handler,
        note: EffectParam("desktop_notification"),
    ) void {
        const self = fromHandler(handler);
        var aw: std.Io.Writer.Allocating = .init(self.alloc);
        defer aw.deinit();
        formatNotification(&aw.writer, note.title, note.body) catch return;
        protocol.writeAll(1, aw.writer.buffered()) catch {};
    }

    fn effectProgressReport(
        handler: *Stream.Handler,
        report: ProgressReport,
    ) void {
        _ = handler;
        var buf: [24]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        formatProgress(&writer, report.state, report.progress) catch return;
        protocol.writeAll(1, writer.buffered()) catch {};
    }

    const DeviceAttributes = windowpkg.Window.EffectReturn("device_attributes");
    const ColorScheme = @typeInfo(windowpkg.Window.EffectReturn("color_scheme")).optional.child;

    fn effectColorScheme(handler: *Stream.Handler) ?ColorScheme {
        const self = fromHandler(handler);
        const bg = self.bg orelse return null;
        return if (bg.isDark()) .dark else .light;
    }

    fn effectDeviceAttributes(handler: *Stream.Handler) DeviceAttributes {
        _ = handler;
        return .{};
    }

    fn effectSize(handler: *Stream.Handler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{
            .rows = self.term.rows,
            .columns = self.term.cols,
            .cell_width = kittygfx.cell_px_w,
            .cell_height = kittygfx.cell_px_h,
        };
    }

    fn effectXtversion(handler: *Stream.Handler) []const u8 {
        _ = handler;
        return "lantern " ++ @import("main.zig").version;
    }

    pub fn feedOutput(self: *View, bytes: []const u8) void {
        // The view-canvas stream below parses OSC 52 but has no
        // clipboard effect, so an application's own clipboard write
        // would be dropped. Forward it to the real terminal first, the
        // same path the ui's selection copy uses, so a copy inside a
        // session reaches the user's clipboard over SSH.
        if (self.clip_enabled) self.clip.feed(self.alloc, bytes, ClipboardSink{}) catch {};
        // OSC 72 drag-and-drop is answered by the real terminal, which
        // owns native drops. Relay it there and keep it out of the view
        // terminal, which would otherwise answer a data request it has
        // no data for and reply into the session.
        self.dnd.feed(self.alloc, bytes, DndSink{ .view = self }) catch {};
    }

    pub fn sendInput(self: *View, bytes: []const u8) !void {
        if (self.state != .live) return;
        try protocol.writeMsg(self.sock, .input, bytes);
    }

    pub fn resize(self: *View, rows: u16, cols: u16) !void {
        try self.term.resize(self.alloc, .{ .cols = @max(cols, 1), .rows = @max(rows, 1) });
        self.term.width_px = @as(u32, self.term.cols) * kittygfx.cell_px_w;
        self.term.height_px = @as(u32, self.term.rows) * kittygfx.cell_px_h;
        if (self.state != .live) return;
        try protocol.writeMsg(self.sock, .resize, &(protocol.SizePayload{
            .rows = @max(rows, 1),
            .cols = @max(cols, 1),
        }).encode());
    }
};

/// Whether application OSC 52 clipboard writes are forwarded to the real
/// terminal. On by default; `LANTERN_OSC52=0` (or off/false) disables it,
/// so untrusted output cannot overwrite the user's clipboard.
fn osc52Enabled() bool {
    const v = posix.getenv("LANTERN_OSC52") orelse return true;
    return !(std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "off") or std.mem.eql(u8, v, "false"));
}

/// Session variables a long-lived daemon would otherwise leave stale in
/// every new tab (the daemon keeps the environment of whichever shell
/// started it): SSH agent and connection, display servers, and terminal
/// identity.
const session_env_names = [_][]const u8{
    "SSH_AUTH_SOCK",
    "SSH_CONNECTION",
    "SSH_CLIENT",
    "SSH_TTY",
    "DISPLAY",
    "WAYLAND_DISPLAY",
    "DBUS_SESSION_BUS_ADDRESS",
    "XDG_SESSION_ID",
    "COLORTERM",
    "TERM_PROGRAM",
    "TERM_PROGRAM_VERSION",
};

/// Tell the daemon this client's session environment (see protocol.zig
/// `env`). Best effort: an older daemon ignores the message.
fn sendSessionEnv(alloc: std.mem.Allocator, sock: posix.fd_t) void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    for (session_env_names) |name| {
        buf.appendSlice(alloc, name) catch return;
        if (posix.getenv(name)) |value| {
            buf.append(alloc, '=') catch return;
            buf.appendSlice(alloc, value) catch return;
        }
        buf.append(alloc, 0) catch return;
    }
    if (buf.items.len > protocol.max_payload) return;
    protocol.writeMsg(sock, .env, buf.items) catch {};
}

/// A kitty-graphics image already transmitted to the real terminal.
const KittyImage = struct {
    id: u32,
    transmission: u64,
};

/// Re-emits the kitty graphics held by a view's terminal to the user's
/// real terminal. The UI paints the session itself, so the images an
/// application transmits are parsed by libghostty and would otherwise
/// never reach the real terminal. Pixel data is sent once per image
/// (cached by id and transmit time); placements follow the viewport as
/// output scrolls, so they are rebuilt whenever the visible scene changes
/// (and only then: re-placing every frame made images flicker).
const KittyState = struct {
    images: std.ArrayList(KittyImage) = .empty,
    /// Whether placements from an earlier frame may still be showing.
    placed: bool = false,
    /// The placement commands last sent. A frame whose scene is identical
    /// (a cursor move, typing elsewhere) sends nothing.
    scene: std.ArrayList(u8) = .empty,

    fn deinit(self: *KittyState, alloc: std.mem.Allocator) void {
        self.images.deinit(alloc);
        self.scene.deinit(alloc);
    }

    /// Forget everything: delete every placement and image on the real
    /// terminal and drop the cache.
    fn reset(self: *KittyState, alloc: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
        if (self.placed or self.images.items.len > 0) {
            try kittygfx.appendControl(alloc, out, "a=d,d=A");
        }
        self.placed = false;
        self.images.clearRetainingCapacity();
        self.scene.clearRetainingCapacity();
    }

    /// Bring the real terminal's images in step with the view's terminal.
    /// `row_offset` is the number of screen rows above the viewport (the
    /// tab bar). `force` re-places everything even when the scene looks
    /// unchanged (after a resize, redraw, or tab switch the real terminal
    /// may have moved or dropped the placements).
    fn compose(
        self: *KittyState,
        alloc: std.mem.Allocator,
        term: *vt.Terminal,
        out: *std.ArrayList(u8),
        row_offset: u16,
        force: bool,
    ) !void {
        const storage = &term.screens.active.kitty_images;

        // Keep the cache in step with the terminal: an image the session
        // deleted is deleted on the real terminal too, and one that was
        // replaced is simply re-sent the next time it is visible.
        var ci: usize = 0;
        while (ci < self.images.items.len) {
            const entry = self.images.items[ci];
            const current = storage.imageById(entry.id);
            const keep = if (current) |img|
                img.transmission == entry.transmission
            else
                false;
            if (keep) {
                ci += 1;
                continue;
            }
            if (current == null) {
                try out.print(alloc, "\x1b_Ga=d,d=I,i={d},q=2\x1b\\", .{entry.id});
            }
            _ = self.images.swapRemove(ci);
        }

        // Build this frame's scene: pixels not yet on the real terminal
        // (`tx`) and the placement commands (`place`).
        var tx: std.ArrayList(u8) = .empty;
        defer tx.deinit(alloc);
        var place: std.ArrayList(u8) = .empty;
        defer place.deinit(alloc);

        const items = try kittygfx.collect(alloc, term, .viewport);
        defer alloc.free(items);

        var uid: u32 = 1;
        for (items) |*item| {
            const mark = place.items.len;
            if (!try kittygfx.appendPlacement(alloc, &place, item, uid, term.rows, row_offset)) continue;
            if (try self.transmit(alloc, &item.image, &tx)) {
                uid += 1;
            } else {
                // Cannot be sent in a supported form: leave it out.
                place.shrinkRetainingCapacity(mark);
            }
        }

        if (!force and tx.items.len == 0 and std.mem.eql(u8, place.items, self.scene.items)) return;

        // Drop last frame's placements and re-place from scratch.
        if (self.placed) try kittygfx.appendControl(alloc, out, "a=d,d=a");
        try out.appendSlice(alloc, tx.items);
        try out.appendSlice(alloc, place.items);
        self.placed = uid > 1;
        self.scene.clearRetainingCapacity();
        try self.scene.appendSlice(alloc, place.items);
    }

    /// Send an image's pixels if they are not already on the real
    /// terminal. The cache is keyed by id and transmit time, the same
    /// identity the renderer uses to notice a replaced image.
    fn transmit(
        self: *KittyState,
        alloc: std.mem.Allocator,
        image: *const vt.kitty.graphics.Image,
        out: *std.ArrayList(u8),
    ) !bool {
        for (self.images.items) |entry| {
            if (entry.id == image.id and
                entry.transmission == image.transmission)
            {
                return true;
            }
        }

        if (!try kittygfx.appendTransmit(alloc, image, out)) return false;

        // Record the transmission, replacing a stale entry for this id.
        for (self.images.items) |*entry| {
            if (entry.id == image.id) {
                entry.transmission = image.transmission;
                return true;
            }
        }
        try self.images.append(alloc, .{
            .id = image.id,
            .transmission = image.transmission,
        });
        return true;
    }
};

/// Display width in terminal columns of one codepoint: 0 for
/// combining and other zero-width marks, 2 for East Asian wide and
/// fullwidth characters, 1 otherwise. A compact wcwidth-style
/// approximation of the width table ghostty applies to session
/// content; that table lives in ghostty's src/unicode, is generated
/// at build time, and is not exported through the ghostty-vt
/// module, so chrome text approximates it locally. Only tab bar and
/// status chrome is measured here, session content renders through
/// libghostty's formatter and never passes through this table.
fn codepointWidth(cp: u21) u2 {
    return switch (cp) {
        // Zero width: combining marks, joiners, and variation
        // selectors attach to the preceding glyph.
        0x0300...0x036F,
        0x1AB0...0x1AFF,
        0x1DC0...0x1DFF,
        0x200B...0x200F,
        0x2060,
        0x20D0...0x20FF,
        0xFE00...0xFE0F,
        0xFE20...0xFE2F,
        0xFEFF,
        => 0,
        // Wide and fullwidth East Asian blocks, plus the emoji
        // blocks terminals render wide. 0x303F (ideographic half
        // fill space) inside the CJK range stays narrow.
        0x1100...0x115F,
        0x2329...0x232A,
        0x2E80...0x303E,
        0x3040...0xA4CF,
        0xA960...0xA97F,
        0xAC00...0xD7A3,
        0xF900...0xFAFF,
        0xFE10...0xFE19,
        0xFE30...0xFE6F,
        0xFF00...0xFF60,
        0xFFE0...0xFFE6,
        0x1F300...0x1F64F,
        0x1F680...0x1F6FF,
        0x1F900...0x1FAFF,
        0x20000...0x2FFFD,
        0x30000...0x3FFFD,
        => 2,
        else => 1,
    };
}

/// Iterator yielding `text` as terminal display units: each valid
/// printable UTF-8 sequence intact with its column width, and each
/// control or invalid byte as a one-column '?' so damaged input
/// stays visible without corrupting the layout.
const DisplayUnits = struct {
    text: []const u8,
    i: usize = 0,

    const Unit = struct {
        bytes: []const u8,
        width: u2,
    };

    const replaced: Unit = .{ .bytes = "?", .width = 1 };

    fn next(self: *DisplayUnits) ?Unit {
        if (self.i >= self.text.len) return null;
        const rest = self.text[self.i..];
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch {
            self.i += 1;
            return replaced;
        };
        if (len > rest.len) {
            self.i += 1;
            return replaced;
        }
        const cp = std.unicode.utf8Decode(rest[0..len]) catch {
            // Advance one byte, not the whole sequence: a valid
            // sequence may start at the next byte.
            self.i += 1;
            return replaced;
        };
        // C0, DEL, and C1 controls never reach the writer raw; they
        // could corrupt the row the tab bar is composing.
        if (cp < 0x20 or cp == 0x7f or (cp >= 0x80 and cp <= 0x9f)) {
            self.i += len;
            return replaced;
        }
        self.i += len;
        return .{ .bytes = rest[0..len], .width = codepointWidth(cp) };
    }
};

/// Append `text` clipped to `width` display columns, then pad with
/// spaces to exactly `width`. Valid UTF-8 passes through intact so
/// non-ASCII titles render; control bytes and invalid sequences
/// become '?'. A wide character that would straddle the clip
/// boundary is dropped and its columns are padded instead.
fn appendClipped(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
) !void {
    var used: usize = 0;
    var units: DisplayUnits = .{ .text = text };
    while (units.next()) |unit| {
        if (used + unit.width > width) break;
        try out.appendSlice(alloc, unit.bytes);
        used += unit.width;
    }
    while (used < width) : (used += 1) try out.append(alloc, ' ');
}

/// Append `text` centered in `width` display columns, padding both
/// sides with spaces to exactly `width`. Too-wide text clips from the
/// left edge like appendClipped.
fn appendCentered(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    width: usize,
) !void {
    const tw = displayWidth(text);
    if (tw >= width) return appendClipped(alloc, out, text, width);
    const left = (width - tw) / 2;
    var i: usize = 0;
    while (i < left) : (i += 1) try out.append(alloc, ' ');
    try appendClipped(alloc, out, text, width - left);
}

/// Append `text` to `out`, eliding its middle to `...` when it is wider
/// than `max` display columns. Short titles pass through untouched; long
/// ones read as `folderInitial...folderLast`, keeping both ends visible.
fn appendTruncatedMiddle(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    max: usize,
) !void {
    if (displayWidth(text) <= max) {
        try out.appendSlice(alloc, text);
        return;
    }
    if (max <= 3) {
        for (0..max) |_| try out.append(alloc, '.');
        return;
    }

    // Slice the text into display units once, then take whole units from
    // the front and the back until the elision budget is spent.
    const Piece = struct { bytes: []const u8, width: usize };
    var pieces: std.ArrayList(Piece) = .empty;
    defer pieces.deinit(alloc);
    var units: DisplayUnits = .{ .text = text };
    while (units.next()) |u| try pieces.append(alloc, .{ .bytes = u.bytes, .width = u.width });

    const keep = max - 3;
    const head_cols = keep - keep / 2;
    const tail_cols = keep / 2;

    var head: usize = 0;
    var used: usize = 0;
    while (head < pieces.items.len and used + pieces.items[head].width <= head_cols) : (head += 1) {
        used += pieces.items[head].width;
    }
    var tail_start: usize = pieces.items.len;
    used = 0;
    while (tail_start > head and used + pieces.items[tail_start - 1].width <= tail_cols) {
        tail_start -= 1;
        used += pieces.items[tail_start].width;
    }

    for (pieces.items[0..head]) |p| try out.appendSlice(alloc, p.bytes);
    try out.appendSlice(alloc, "...");
    for (pieces.items[tail_start..]) |p| try out.appendSlice(alloc, p.bytes);
}

// -- Rendering helpers -------------------------------------------------------

const sgr_reset = "\x1b[0m";
/// Reverse video, used to highlight an in-progress mouse text selection.
const style_selected = "\x1b[7m";
const style_dim = "\x1b[2m";
/// The armed-prefix keys: bolder than the dim chrome (and their dim
/// labels) so the bindings stand out across the row.
const style_keybind = "\x1b[1m";
/// The focused tab, styled like fut's current tab: blue foreground plus
/// reverse video, which renders as a solid blue block with the label in
/// the terminal's own background color, whatever the theme.
const style_tab_active = "\x1b[34;7m";
/// Inactive tabs: dim.
const style_tab_inactive = "\x1b[2m";

/// Longest a tab title renders before its middle is elided. Keeps a bar
/// of several tabs readable: a long directory name reads as
/// "folderInitial...folderLast".
const tab_title_max = 20;

/// Display width in terminal columns of `text`, using the same local
/// approximation appendClipped measures with. Only UI chrome (tab bar,
/// status) is measured here; session content renders through
/// libghostty's formatter and never passes through this table.
fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var units: DisplayUnits = .{ .text = text };
    while (units.next()) |unit| width += unit.width;
    return width;
}

// -- Tabs --------------------------------------------------------------------

/// One tab as the UI knows it: the daemon-assigned id and the title to
/// show. Titles are owned by the list.
const Tab = struct {
    id: u32,
    title: []u8,
};

fn freeTabs(alloc: std.mem.Allocator, tabs: *std.ArrayList(Tab)) void {
    for (tabs.items) |tab| alloc.free(tab.title);
    tabs.deinit(alloc);
}

/// A clickable span on the tab bar, in screen columns [x0, x1).
const TabHit = struct {
    id: u32,
    x0: u16,
    x1: u16,
};

/// Cached serialization of one viewport (terminal) row, keyed on the
/// libghostty row identity so a row that scrolls to a new position is
/// re-serialized even when its own contents did not change.
const ViewportRow = struct {
    /// The bytes appendTermRow produced for this row last time.
    bytes: std.ArrayList(u8) = .empty,
    /// The page node the cached row lived in, compared by pointer
    /// identity. Null until first serialized.
    node: ?*const anyopaque = null,
    /// The row offset within `node`.
    offset: u16 = 0,
    /// Whether `bytes`/`node`/`offset` hold a serialized row.
    valid: bool = false,

    fn deinit(self: *ViewportRow, alloc: std.mem.Allocator) void {
        self.bytes.deinit(alloc);
    }
};

/// Whether `entry` may be reused for the row currently at `pin` instead
/// of re-serializing it. Reuse is safe only when a full repaint is not
/// forced, the entry holds a serialized row, the libghostty row identity
/// (page node and offset within it) is unchanged, and the row is not
/// dirty. Scrolling the active screen relocates a visual row onto a
/// different identity even while its own bytes stay clean, so the
/// identity comparison is required and the dirty bit alone is not
/// enough.
fn viewportRowReusable(entry: *const ViewportRow, pin: vt.Pin, full_render: bool) bool {
    if (full_render or !entry.valid) return false;
    if (entry.node != @as(*const anyopaque, @ptrCast(pin.node))) return false;
    if (entry.offset != pin.y) return false;
    return !pin.isDirty();
}

// -- The UI ------------------------------------------------------------------

var signal_pipe: posix.fd_t = -1;

/// `SIGWINCH` as the byte the handler writes to the self-pipe.
const winch_sig: u8 = @intCast(@intFromEnum(posix.SIG.WINCH));

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    if (signal_pipe >= 0) {
        const byte: [1]u8 = .{@intCast(@intFromEnum(sig) & 0xff)};
        _ = posix.write(signal_pipe, &byte) catch {};
    }
}

const enter_sequence =
    "\x1b[?1049h" ++ // alternate screen, saving the cursor
    "\x1b]22;text\x07" ++ // mouse pointer: text I-beam over the terminal
    "\x1b[?1002h\x1b[?1006h" ++ // mouse: button events, SGR encoding
    "\x1b[?1004h" ++ // focus reporting
    "\x1b[?2004h" ++ // bracketed paste
    "\x1b[=0;1u\x1b[>4;0m" ++ // keyboard protocols off until the view sets them
    "\x1b]2;lantern\x07"; // window title

/// reset_state_sequence turns every mode above back off.
const restore_sequence = windowpkg.reset_state_sequence ++
    "\x1b]22;default\x07" ++ // hand the pointer shape back to the terminal
    "\x1b]72;t=A\x1b\\" ++ // hand the drop target back to the terminal
    "\x1b[?1049l";

/// The pointer shape type libghostty stores on a terminal. The enum's
/// tags are exactly the W3C CSS cursor names with `_` in place of `-`.
const MouseShape = @FieldType(vt.Terminal, "mouse_shape");
const ProgressReport = EffectParam("progress_report");

/// The payload type of a terminal-stream effects callback, e.g. the
/// notification struct passed to `desktop_notification`.
fn EffectParam(comptime field_name: []const u8) type {
    const Effects = vt.TerminalStream.Handler.Effects;
    const field = std.meta.fieldInfo(
        Effects,
        @field(std.meta.FieldEnum(Effects), field_name),
    );
    const Fn = @typeInfo(field.type).optional.child;
    const params = @typeInfo(@typeInfo(Fn).pointer.child).@"fn".param_types;
    return params[1].?;
}

/// OSC 22: set the real terminal's pointer to `shape`. W3C names spell
/// the enum tags with hyphens.
fn formatMouseShape(writer: *std.Io.Writer, shape: MouseShape) !void {
    var name_buf: [24]u8 = undefined;
    const tag = @tagName(shape);
    const name: []const u8 = blk: {
        if (tag.len > name_buf.len) break :blk "default";
        for (tag, 0..) |ch, i| name_buf[i] = if (ch == '_') '-' else ch;
        break :blk name_buf[0..tag.len];
    };
    try writer.writeAll("\x1b]22;");
    try writer.writeAll(name);
    try writer.writeByte(0x07);
}

/// OSC 777 (`OSC 9` when there is no title): show a desktop
/// notification on the real terminal. Bytes that could terminate the
/// sequence are dropped, and `;` in the title becomes `:` so it cannot
/// split the fields.
fn formatNotification(
    writer: *std.Io.Writer,
    title: []const u8,
    body: []const u8,
) !void {
    if (title.len > 0) {
        try writer.writeAll("\x1b]777;notify;");
        for (title) |ch| {
            if (ch < 0x20 or ch == 0x7f) continue;
            try writer.writeByte(if (ch == ';') ':' else ch);
        }
        try writer.writeByte(';');
    } else {
        try writer.writeAll("\x1b]9;");
    }
    for (body) |ch| {
        if (ch < 0x20 or ch == 0x7f) continue;
        try writer.writeByte(ch);
    }
    try writer.writeByte(0x07);
}

/// OSC 9;4: report progress to the real terminal (taskbar progress).
/// Only set/error/pause carry a value; remove/indeterminate do not.
fn formatProgress(
    writer: *std.Io.Writer,
    state: @FieldType(ProgressReport, "state"),
    progress: ?u8,
) !void {
    const code: u8 = switch (state) {
        .remove => 0,
        .set => 1,
        .@"error" => 2,
        .indeterminate => 3,
        .pause => 4,
    };
    if (code == 1 or code == 2 or code == 4) {
        try writer.print("\x1b]9;4;{d};{d}\x07", .{
            code,
            @min(progress orelse 0, 100),
        });
    } else {
        try writer.print("\x1b]9;4;{d}\x07", .{code});
    }
}

pub fn run(io: std.Io, alloc: std.mem.Allocator, sock_path: []const u8) !void {
    const tty: posix.fd_t = 0;
    if (!posix.isatty(tty)) return error.NotATty;

    var ui: Ui = .{ .alloc = alloc, .tty = tty };
    defer ui.deinit();

    // Signal plumbing: WINCH relayouts, TERM/HUP quit cleanly.
    const pipe_fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
    defer posix.close(pipe_fds[0]);
    defer posix.close(pipe_fds[1]);
    signal_pipe = pipe_fds[1];
    defer signal_pipe = -1;
    const sigact: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = posix.SA.RESTART,
    };
    posix.sigaction(posix.SIG.WINCH, &sigact, null);
    posix.sigaction(posix.SIG.TERM, &sigact, null);
    posix.sigaction(posix.SIG.HUP, &sigact, null);
    posix.sigaction(posix.SIG.PIPE, &.{
        .handler = .{ .handler = posix.SIG.IGN },
        .mask = posix.sigemptyset(),
        .flags = 0,
    }, null);

    const saved = try posix.tcgetattr(tty);
    var raw = saved;
    client.rawMode(&raw);
    try posix.tcsetattr(tty, .FLUSH, raw);
    // Shared restore with a plain attach: screen restore (which also
    // resets the mirrored keyboard protocols), input drain, then the
    // mode switch. A C-d quit gets the longer EOF guard.
    defer client.restoreTty(tty, saved, restore_sequence, ui.eof_guard, ui.parser.swallow_cp orelse 0);
    try protocol.writeAll(1, enter_sequence);

    // Probe the real terminal's background color so the session can
    // detect the theme via OSC 11 (see window.zig). Input typed during
    // the probe is fed through the parser before the loop so it is not
    // lost.
    var probe_scratch: [256]u8 = undefined;
    var probe_leftover: usize = 0;
    ui.term_bg = client.probeBackground(tty, pipe_fds[0], &probe_scratch, &probe_leftover);

    const ws = ptypkg.getSize(tty) catch ptypkg.makeWinsize(24, 80);
    ui.layout = .init(ws.row, ws.col);
    // Use the real terminal's cell size, so images that applications
    // size in cells are drawn at the proportions they intended. Must be
    // set before the view terminal is created.
    _ = adoptCellSize(ws);

    ui.view = View.create(
        io,
        alloc,
        sock_path,
        ui.layout.viewportRows(),
        ui.layout.viewportCols(),
        ui.term_bg,
    ) catch |err| {
        log.err("attach failed: {}", .{err});
        return err;
    };
    // The daemon streams the active tab's state (history, then a repaint
    // ending in a `.screen` message); hold the previous frame until then
    // so a large history replay never flashes before the live screen.
    ui.awaiting_repaint = true;
    ui.awaiting_since_ms = posix.milliTimestamp();

    if (probe_leftover > 0) ui.feedStartupInput(probe_scratch[0..probe_leftover]);

    try ui.loop(pipe_fds[0]);
}

/// Adopt the real terminal's cell size from its reported pixel size.
/// Returns true when the metrics changed. A terminal that reports no
/// pixel size leaves the current (fallback) metrics in place.
fn adoptCellSize(ws: ptypkg.Winsize) bool {
    const cell = kittygfx.cellSizeFromPixels(ws.col, ws.row, ws.xpixel, ws.ypixel) orelse return false;
    if (cell.w == kittygfx.cell_px_w and cell.h == kittygfx.cell_px_h) return false;
    return kittygfx.setCellSize(cell.w, cell.h);
}

const Ui = struct {
    alloc: std.mem.Allocator,
    tty: posix.fd_t,
    /// Real terminal background, probed once at startup and forwarded to
    /// the daemon so tabs can detect the light/dark theme.
    term_bg: ?protocol.RgbPayload = null,

    layout: Layout = .{ .rows = 24, .cols = 80 },
    /// The session's tabs, as last reported by the daemon.
    tabs: std.ArrayList(Tab) = .empty,
    /// The daemon's active tab id.
    active_id: u32 = 0,
    /// Previously focused tab id, for C-w C-w.
    last_id: ?u32 = null,
    view: ?*View = null,

    parser: InputParser = .{},
    /// When nonzero, the parser holds a lone ESC that is flushed as
    /// input once this deadline passes without follow-up bytes.
    esc_deadline: i64 = 0,
    /// Kitty keyboard flags currently applied to the user's real
    /// terminal, mirroring the active tab.
    kitty_flags: u5 = 0,
    /// modifyOtherKeys=2 state currently applied to the real terminal.
    modify_keys: bool = false,
    /// Pointer shape currently applied to the real terminal, mirroring
    /// the active application's OSC 22. `enter_sequence` starts at the
    /// text I-beam.
    host_mouse_shape: MouseShape = .text,

    /// Per-screen-row cache of the last emitted bytes; rows that did not
    /// change are not re-sent.
    row_cache: std.ArrayList(std.ArrayList(u8)) = .empty,
    /// Per-screen-row cache of the serialized viewport row bytes.
    viewport_cache: std.ArrayList(ViewportRow) = .empty,
    /// Kitty graphics already sent to the real terminal.
    kitty: KittyState = .{},
    /// Clickable tab spans recorded by the last tab-bar render.
    tab_hits: std.ArrayList(TabHit) = .empty,

    need_render: bool = true,
    /// Force every row out on the next render (resize, tab switch, redraw).
    full_render: bool = true,
    /// A newly switched view is seeded by the daemon with a scrollback
    /// history replay followed by a repaint that ends in a `.screen`
    /// message. Until that marker arrives the viewport stays blank
    /// rather than from the half-applied stream.
    awaiting_repaint: bool = false,
    /// When the current wait for that marker last saw progress, so the
    /// hold in `renderIfNeeded` stays bounded. Only meaningful while
    /// `awaiting_repaint`.
    awaiting_since_ms: i64 = 0,
    last_render_ms: i64 = 0,

    /// Mouse forwarding state for the active application.
    mouse_pressed: bool = false,
    mouse_last_cell: ?vt.Coordinate = null,
    /// Viewport text selection in viewport cell coordinates. Anchor is
    /// where the drag started; head follows the pointer. Both inclusive.
    select_anchor: ?CellPos = null,
    select_head: CellPos = .{ .x = 0, .y = 0 },

    quitting: bool = false,
    /// A destructive quit (C-w d) is waiting for a y/N answer on the
    /// status row. While set, all other input is swallowed.
    confirm_quit: bool = false,
    /// The quit command key was C-d; the deferred terminal restore uses
    /// the longer EOF drain guard.
    eof_guard: bool = false,

    const CellPos = struct { x: u16, y: u16 };

    fn deinit(self: *Ui) void {
        if (self.view) |v| v.destroy();
        freeTabs(self.alloc, &self.tabs);
        for (self.row_cache.items) |*row| row.deinit(self.alloc);
        self.row_cache.deinit(self.alloc);
        for (self.viewport_cache.items) |*row| row.deinit(self.alloc);
        self.viewport_cache.deinit(self.alloc);
        self.kitty.deinit(self.alloc);
        self.tab_hits.deinit(self.alloc);
    }

    // -- Main loop ---------------------------------------------------------

    fn loop(self: *Ui, sig_read: posix.fd_t) !void {
        var buf: [32 * 1024]u8 = undefined;

        while (!self.quitting) {
            try self.renderIfNeeded();

            var fds = [_]posix.pollfd{
                .{ .fd = self.tty, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = sig_read, .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = -1, .events = posix.POLL.IN, .revents = 0 },
            };
            // Only a live view's socket is polled: a dead one stays
            // readable (EOF) forever and would spin the loop.
            if (self.liveView()) |v| fds[2].fd = v.sock;

            _ = try posix.poll(&fds, self.pollTimeout());

            if (fds[1].revents != 0) self.drainSignals(sig_read, &buf);
            if (self.quitting) break;

            if (fds[0].revents != 0) try self.readTty(&buf);
            if (self.quitting) break;
            try self.flushPendingEsc();
            // Input may have opened or closed a prompt; re-sync the
            // keyboard mirror before the terminal encodes more keys.
            self.syncKeyboard();

            if (fds[2].revents != 0) try self.readView(&buf);

            if (self.view) |v| {
                if (v.bell) {
                    v.bell = false;
                    protocol.writeAll(1, "\x07") catch {};
                }
            }
            self.syncKeyboard();
            self.syncMouseShape();
        }
    }

    fn pollTimeout(self: *Ui) i32 {
        const now = posix.milliTimestamp();
        var deadline = now + 1000;
        if (self.need_render) deadline = @min(deadline, self.last_render_ms + render_interval_ms);
        if (self.esc_deadline != 0) deadline = @min(deadline, self.esc_deadline);
        return @intCast(std.math.clamp(deadline - now, 0, 1000));
    }

    fn drainSignals(self: *Ui, sig_read: posix.fd_t, buf: []u8) void {
        while (true) {
            const n = posix.read(sig_read, buf) catch 0;
            if (n == 0) break;
            for (buf[0..n]) |sig| switch (sig) {
                winch_sig => self.relayout(),
                else => self.quitting = true,
            };
            if (n < buf.len) break;
        }
    }

    fn relayout(self: *Ui) void {
        const ws = ptypkg.getSize(self.tty) catch return;
        self.layout = .init(ws.row, ws.col);
        // A font zoom changes the cell size without changing the grid.
        if (adoptCellSize(ws)) {
            if (self.view) |v| {
                const cs: protocol.CellSizePayload = .{
                    .w = @intCast(kittygfx.cell_px_w),
                    .h = @intCast(kittygfx.cell_px_h),
                };
                protocol.writeMsg(v.sock, .cell_size, &cs.encode()) catch {};
            }
        }
        self.viewportChanged();
    }

    /// The viewport geometry changed: resize the view (and the session
    /// pty behind it) and repaint every row.
    fn viewportChanged(self: *Ui) void {
        self.need_render = true;
        if (self.view) |v| {
            v.resize(self.layout.viewportRows(), self.layout.viewportCols()) catch |err| {
                log.warn("viewport resize failed: {}", .{err});
            };
        }
        self.select_anchor = null;
        self.full_render = true;
    }

    // -- Terminal input ----------------------------------------------------

    /// Feed input captured during the startup background probe through
    /// the parser before the main loop, so a keystroke that raced startup
    /// still reaches the ui.
    fn feedStartupInput(self: *Ui, bytes: []const u8) void {
        const Handler = struct {
            ui: *Ui,
            pub fn event(h: @This(), ev: InputEvent) !void {
                try h.ui.handleEvent(ev);
            }
        };
        self.parser.feed(bytes, .{}, Handler{ .ui = self }) catch {};
    }

    fn readTty(self: *Ui, buf: []u8) !void {
        const n = posix.read(self.tty, buf) catch 0;
        if (n == 0) {
            self.quitting = true;
            return;
        }
        const Handler = struct {
            ui: *Ui,
            pub fn event(h: @This(), ev: InputEvent) !void {
                try h.ui.handleEvent(ev);
            }
        };
        // The tab bar shows the keybind list while the prefix is armed,
        // so arming and disarming both need a repaint.
        const was_pending = self.parser.pending_prefix;
        try self.parser.feed(buf[0..n], .{
            .kitty = self.kitty_flags != 0,
            .modify = self.modify_keys,
        }, Handler{ .ui = self });
        if (self.parser.pending_prefix != was_pending) self.need_render = true;
        // A read that ends in a bare ESC is ambiguous: the ESC key, or a
        // split escape sequence. Deliver it on a short timeout instead of
        // waiting for the next keypress.
        self.esc_deadline = if (self.parser.held_len == 1 or
            (self.parser.held_len >= 2 and self.parser.held[1] == ']'))
            posix.milliTimestamp() + esc_flush_ms
        else
            0;
    }

    /// Deliver a lone held ESC once the flush deadline passes.
    fn flushPendingEsc(self: *Ui) !void {
        if (self.esc_deadline == 0) return;
        if (posix.milliTimestamp() < self.esc_deadline) return;
        self.esc_deadline = 0;
        const Handler = struct {
            ui: *Ui,
            pub fn event(h: @This(), ev: InputEvent) !void {
                try h.ui.handleEvent(ev);
            }
        };
        try self.parser.flushEsc(Handler{ .ui = self });
    }

    /// Whether the C-w prefix is mid-interaction: armed and awaiting the
    /// command key, or still swallowing that key's auto-repeats and
    /// release.
    fn prefixEngaged(self: *Ui) bool {
        return self.parser.pending_prefix or self.parser.swallow_cp != null;
    }

    /// Mirror the active application's keyboard protocol state onto the
    /// real terminal, the same state a plain attach's repaint replays.
    fn syncKeyboard(self: *Ui) void {
        var kitty: u5 = 0;
        var modify = false;
        if (self.liveView()) |v| {
            kitty = v.term.screens.active.kitty_keyboard.current().int();
            modify = v.term.flags.modify_other_keys_2;
        }
        // While the C-w prefix is engaged, force report-events so a
        // held command key's repeats and release are distinguishable
        // CSI-u events the parser can swallow.
        if (self.prefixEngaged()) kitty |= report_events_flags;
        if (kitty != self.kitty_flags) {
            self.kitty_flags = kitty;
            var buf: [12]u8 = undefined;
            const seq = std.fmt.bufPrint(&buf, "\x1b[={d};1u", .{kitty}) catch unreachable;
            protocol.writeAll(1, seq) catch {};
        }
        if (modify != self.modify_keys) {
            self.modify_keys = modify;
            const seq: []const u8 = if (modify) "\x1b[>4;2m" else "\x1b[>4;0m";
            protocol.writeAll(1, seq) catch {};
        }
    }

    /// Mirror the active application's OSC 22 pointer shape onto the
    /// real terminal. Without a live view the terminal keeps lantern's
    /// text I-beam, so a dead application's hand or resize cursor does
    /// not linger.
    fn syncMouseShape(self: *Ui) void {
        const desired: MouseShape = if (self.liveView()) |v|
            v.term.mouse_shape
        else
            .text;
        if (self.host_mouse_shape == desired) return;
        self.host_mouse_shape = desired;
        var buf: [40]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        formatMouseShape(&writer, desired) catch return;
        protocol.writeAll(1, writer.buffered()) catch {};
    }

    fn handleEvent(self: *Ui, ev: InputEvent) !void {
        // A destructive confirmation is modal: only y/N (plus Esc and
        // Ctrl+C to cancel) get through. Everything else is swallowed so
        // a stray key cannot reach the session under the prompt.
        if (self.confirm_quit) return self.handleConfirm(ev);

        // Any keystroke or paste headed for the application dismisses
        // the selection highlight. C-w y is a prefix command, not one of
        // these, so it can still copy the retained selection.
        switch (ev) {
            .forward, .arrow, .esc, .paste => self.clearSelection(),
            else => {},
        }

        switch (ev) {
            .forward => |bytes| {
                if (self.scrollConsumes(bytes)) return;
                const v = self.liveView() orelse return;
                self.snapViewBottom();
                v.sendInput(bytes) catch self.markViewLost();
            },
            .copy => |bytes| {
                // Ctrl+C with a live selection copies it and drops the
                // highlight, so a second Ctrl+C interrupts; without a
                // selection it is the ordinary interrupt.
                if (self.select_anchor != null) {
                    self.copyActiveSelection();
                    self.clearSelection();
                    return;
                }
                if (self.scrollConsumes(bytes)) return;
                const v = self.liveView() orelse return;
                self.snapViewBottom();
                v.sendInput(bytes) catch self.markViewLost();
            },
            // Ctrl+Shift+C is a pure copy binding, the same as C-w y.
            .copy_selection => self.copyActiveSelection(),
            .prefix => |byte| try self.handlePrefix(byte),
            .arrow => |a| {
                const v = self.liveView() orelse return;
                v.sendInput(a.bytes()) catch self.markViewLost();
            },
            .mouse => |m| try self.handleMouse(m),
            .paste => |begin| {
                const v = self.liveView() orelse return;
                if (!v.term.modes.get(.bracketed_paste)) return;
                self.snapViewBottom();
                const marker: []const u8 = if (begin) "\x1b[200~" else "\x1b[201~";
                v.sendInput(marker) catch self.markViewLost();
            },
            .focus => |in| {
                const v = self.liveView() orelse return;
                if (!v.term.modes.get(.focus_event)) return;
                const marker: []const u8 = if (in) "\x1b[I" else "\x1b[O";
                v.sendInput(marker) catch self.markViewLost();
            },
            .esc => |bytes| {
                // A lone Esc while the view is scrolled returns it to
                // the bottom; otherwise it belongs to the application in
                // whatever encoding the terminal used.
                if (self.viewScrolled()) {
                    self.snapViewBottom();
                    return;
                }
                const v = self.liveView() orelse return;
                v.sendInput(bytes) catch self.markViewLost();
            },
        }
    }

    /// Command keys after the C-w prefix.
    fn handlePrefix(self: *Ui, byte: u8) !void {
        switch (byte) {
            'r', 0x12 => self.newTab(),
            // Tab walks forward; Shift-Tab, which the parser reports as
            // `prefix_prev_tab`, walks back.
            '\t' => self.selectOffset(1),
            prefix_prev_tab => self.selectOffset(-1),
            'w' => self.closeActive(),
            // Copy the retained mouse selection to the clipboard.
            'y', 0x19 => self.copyActiveSelection(),
            // C-d ends the whole session; C-q detaches and leaves the
            // tabs running. The plain letters are aliases.
            'd', 0x04 => self.requestKillSession(),
            'q', 0x11 => self.detachUi(),
            keys.escape_byte => self.focusLast(),
            // Send a literal C-w to the application (like screen's
            // C-a a), since the prefix itself is never forwarded.
            'a', 0x01 => self.sendLiteralPrefix(),
            'l', 0x0c => self.redraw(),
            '1'...'9' => self.selectIndex(byte - '1'),
            else => {},
        }
    }

    /// Forward one C-w byte to the application: readline's word delete,
    /// vim's window commands, and so on.
    fn sendLiteralPrefix(self: *Ui) void {
        const v = self.liveView() orelse return;
        self.snapViewBottom();
        v.sendInput(&.{keys.escape_byte}) catch self.markViewLost();
    }

    /// Detach: close the UI and leave every tab running for the next
    /// client.
    fn detachUi(self: *Ui) void {
        self.quitting = true;
    }

    /// Ask before ending the whole session: C-w d is destructive, so it
    /// opens a y/N prompt instead of killing every tab outright.
    fn requestKillSession(self: *Ui) void {
        self.confirm_quit = true;
        self.need_render = true;
    }

    /// Answer the y/N quit prompt. y ends the session; anything else
    /// cancels and leaves every tab running.
    fn handleConfirm(self: *Ui, ev: InputEvent) !void {
        switch (ev) {
            .forward => |bytes| {
                for (bytes) |b| switch (b) {
                    'y', 'Y' => {
                        self.confirmKill();
                        return;
                    },
                    'n', 'N' => {
                        self.cancelConfirm();
                        return;
                    },
                    else => {},
                };
            },
            // Esc and Ctrl+C both mean "no".
            .esc, .copy => self.cancelConfirm(),
            else => {},
        }
    }

    fn confirmKill(self: *Ui) void {
        self.confirm_quit = false;
        self.killSession();
    }

    fn cancelConfirm(self: *Ui) void {
        if (!self.confirm_quit) return;
        self.confirm_quit = false;
        self.need_render = true;
    }

    /// Kill: end the session (terminating every tab) and close the UI.
    fn killSession(self: *Ui) void {
        self.sendMsg(.quit, "");
        self.quitting = true;
    }

    /// Re-seed from daemon state and repaint everything.
    fn redraw(self: *Ui) void {
        self.sendMsg(.redraw_req, "");
        self.full_render = true;
        self.need_render = true;
    }

    // -- Tabs --------------------------------------------------------------

    fn sendMsg(self: *Ui, msg_type: protocol.MsgType, payload: []const u8) void {
        const v = self.liveView() orelse return;
        protocol.writeMsg(v.sock, msg_type, payload) catch {};
    }

    fn hasTab(self: *Ui, id: u32) bool {
        for (self.tabs.items) |tab| {
            if (tab.id == id) return true;
        }
        return false;
    }

    fn activeIndex(self: *Ui) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.id == self.active_id) return i;
        }
        return null;
    }

    fn newTab(self: *Ui) void {
        if (self.liveView() == null) return;
        self.sendMsg(.tab_new, "");
    }

    fn closeTab(self: *Ui, id: u32) void {
        const idp: protocol.IdPayload = .{ .id = id };
        self.sendMsg(.tab_close, &idp.encode());
    }

    fn requestSelect(self: *Ui, id: u32) void {
        if (id == self.active_id) return;
        if (!self.hasTab(id)) return;
        self.last_id = self.active_id;
        const idp: protocol.IdPayload = .{ .id = id };
        self.sendMsg(.tab_select, &idp.encode());
    }

    fn selectOffset(self: *Ui, dir: i2) void {
        const len = self.tabs.items.len;
        if (len == 0) return;
        const cur = self.activeIndex() orelse 0;
        const idx = if (dir > 0)
            (cur + 1) % len
        else
            (cur + len - 1) % len;
        self.requestSelect(self.tabs.items[idx].id);
    }

    fn selectIndex(self: *Ui, idx: usize) void {
        if (idx >= self.tabs.items.len) return;
        self.requestSelect(self.tabs.items[idx].id);
    }

    fn focusLast(self: *Ui) void {
        const want = self.last_id orelse return;
        if (!self.hasTab(want)) return;
        self.requestSelect(want);
    }

    /// Close the active tab outright. The daemon ends the session when
    /// that was its last tab.
    fn closeActive(self: *Ui) void {
        if (!self.hasTab(self.active_id)) return;
        self.closeTab(self.active_id);
    }

    // -- Mouse -------------------------------------------------------------

    fn handleMouse(self: *Ui, m: Mouse) !void {
        if (m.x == 0 or m.y == 0) return;
        const x: u16 = m.x - 1;
        const y: u16 = m.y - 1;

        // An in-progress viewport selection captures the drag and the
        // release wherever the pointer wanders. Selection rows are
        // viewport-relative, so drop the tab bar's offset.
        if (self.select_anchor != null and !m.isWheel() and (m.isMotion() or m.release)) {
            return self.dragSelection(m, x, y -| Layout.tabbar_h);
        }

        if (m.isWheel() and !m.release) {
            switch (self.layout.hit(x, y)) {
                .viewport => return self.wheelViewport(m),
                else => return,
            }
        }

        switch (self.layout.hit(x, y)) {
            .viewport => |cell| {
                // Applications that asked for mouse reporting get the
                // events; otherwise a left press starts a selection.
                const v = self.liveView() orelse return;
                if (v.term.flags.mouse_event != .none) return self.forwardMouse(m);
                if (m.release or m.isMotion() or m.code & 3 != 0) return;
                self.select_anchor = .{
                    .x = @min(cell.x, v.term.cols -| 1),
                    .y = @min(cell.y, v.term.rows -| 1),
                };
                self.select_head = self.select_anchor.?;
                self.need_render = true;
            },
            .tabbar => |t| {
                if (m.release or m.isMotion()) return;
                self.clickTabBar(t.x);
            },
            .none => {},
        }
    }

    /// A left press on the tab bar: focus the tab under the cursor.
    fn clickTabBar(self: *Ui, x: u16) void {
        for (self.tab_hits.items) |hit| {
            if (x >= hit.x0 and x < hit.x1) {
                self.requestSelect(hit.id);
                return;
            }
        }
    }

    /// Wheel over the viewport. Applications that asked for mouse
    /// reporting get the event. Alternate-screen applications get arrow
    /// keys per tick, like terminals' alternate-scroll mode, so pagers
    /// scroll without mouse support. Otherwise the wheel pages the
    /// view's local scrollback.
    fn wheelViewport(self: *Ui, m: Mouse) !void {
        const v = self.liveView() orelse return;
        if (v.term.flags.mouse_event != .none) return self.forwardMouse(m);
        const down = m.code & 1 != 0;
        if (v.app_alt) {
            const seq: []const u8 = if (v.term.modes.get(.cursor_keys))
                (if (down) "\x1bOB" else "\x1bOA")
            else
                (if (down) "\x1b[B" else "\x1b[A");
            for (0..wheel_lines) |_| {
                v.sendInput(seq) catch return self.markViewLost();
            }
            return;
        }
        self.scrollView(if (down) wheel_lines else -@as(isize, wheel_lines));
    }

    /// Page the focused view's scrollback by delta rows (up is negative).
    fn scrollView(self: *Ui, delta: isize) void {
        const v = self.liveView() orelse return;
        v.term.scrollViewport(.{ .delta = delta });
        self.full_render = true;
        self.need_render = true;
    }

    /// Whether the focused view's viewport is scrolled into history.
    fn viewScrolled(self: *Ui) bool {
        const v = self.view orelse return false;
        if (v.state != .live) return false;
        return !v.term.screens.active.viewportIsBottom();
    }

    /// Return the viewport to the live bottom, so input lands where the
    /// user can see it.
    fn snapViewBottom(self: *Ui) void {
        if (!self.viewScrolled()) return;
        if (self.view) |v| v.term.scrollViewport(.{ .bottom = {} });
        self.full_render = true;
        self.need_render = true;
    }

    /// A lone Esc while the view is scrolled returns it to the bottom
    /// instead of reaching the application.
    fn scrollConsumes(self: *Ui, bytes: []const u8) bool {
        if (!self.viewScrolled()) return false;
        if (bytes.len == 1 and bytes[0] == 0x1b) {
            self.snapViewBottom();
            return true;
        }
        return false;
    }

    /// Track press state and forward the event to the application when it
    /// asked for mouse reporting, with coordinates translated into
    /// viewport space.
    fn forwardMouse(self: *Ui, m: Mouse) !void {
        const v = self.liveView() orelse return;

        if (!m.isWheel() and !m.isMotion()) {
            self.mouse_pressed = !m.release;
        }

        if (v.term.flags.mouse_event == .none) return;

        const cell_x: u16 = (m.x - 1) -| self.layout.viewportX();
        const cell_y: u16 = (m.y - 1) -| Layout.tabbar_h;

        const SizeType = @FieldType(vt.input.MouseEncodeOptions, "size");
        const size: SizeType = .{
            .screen = .{
                .width = @as(u32, v.term.cols) * kittygfx.cell_px_w,
                .height = @as(u32, v.term.rows) * kittygfx.cell_px_h,
            },
            .cell = .{ .width = kittygfx.cell_px_w, .height = kittygfx.cell_px_h },
            .padding = .{},
        };
        var opts: vt.input.MouseEncodeOptions = .fromTerminal(&v.term, size);
        opts.any_button_pressed = self.mouse_pressed;
        opts.last_cell = &self.mouse_last_cell;

        const event: vt.input.MouseEncodeEvent = .{
            .action = if (m.release)
                .release
            else if (m.isMotion())
                .motion
            else
                .press,
            .button = sgrButton(m),
            .mods = .{
                .shift = m.code & 4 != 0,
                .alt = m.code & 8 != 0,
                .ctrl = m.code & 16 != 0,
            },
            .pos = .{
                .x = (@as(f32, @floatFromInt(cell_x)) + 0.5) * @as(f32, @floatFromInt(kittygfx.cell_px_w)),
                .y = (@as(f32, @floatFromInt(cell_y)) + 0.5) * @as(f32, @floatFromInt(kittygfx.cell_px_h)),
            },
        };

        var enc_buf: [64]u8 = undefined;
        var writer = std.Io.Writer.fixed(&enc_buf);
        vt.input.encodeMouse(&writer, event, opts) catch return;
        const encoded = writer.buffered();
        if (encoded.len > 0) v.sendInput(encoded) catch self.markViewLost();
    }

    /// Update an in-progress selection from a drag or release. The
    /// selection is not copied on release: it stays highlighted until
    /// the next click, a keypress, a tab switch, or C-w y.
    fn dragSelection(self: *Ui, m: Mouse, x: u16, y: u16) void {
        const v = self.liveView() orelse {
            self.select_anchor = null;
            return;
        };
        const head: CellPos = .{
            .x = @min(x, v.term.cols -| 1),
            .y = @min(y, v.term.rows -| 1),
        };
        if (head.x != self.select_head.x or head.y != self.select_head.y) {
            self.select_head = head;
            self.need_render = true;
        }
        if (!m.release) return;

        // A release with the head still on the anchor means the button
        // went down and up on one cell: a plain click, not a drag. Drop
        // any highlight rather than leaving a one-cell selection.
        const anchor = self.select_anchor.?;
        if (anchor.x == self.select_head.x and anchor.y == self.select_head.y) {
            self.select_anchor = null;
            self.need_render = true;
        }
    }

    /// Drop the selection highlight, if any.
    fn clearSelection(self: *Ui) void {
        if (self.select_anchor == null) return;
        self.select_anchor = null;
        self.need_render = true;
    }

    /// Copy the retained selection to the clipboard (C-w y, or Ctrl+C
    /// with a selection). The selection stays highlighted so it can be
    /// copied again.
    fn copyActiveSelection(self: *Ui) void {
        if (self.select_anchor == null) return;
        const v = self.liveView() orelse return;
        self.copySelection(v);
    }

    /// The selection's inclusive span on viewport row `y`, or null when
    /// the row is outside the selection.
    fn selectionSpan(self: *Ui, y: u16, cols: u16) ?struct { x0: u16, x1: u16 } {
        const anchor = self.select_anchor orelse return null;
        if (cols == 0) return null;
        var s = anchor;
        var e = self.select_head;
        if (e.y < s.y or (e.y == s.y and e.x < s.x)) std.mem.swap(CellPos, &s, &e);
        if (y < s.y or y > e.y) return null;
        const x0: u16 = if (y == s.y) @min(s.x, cols - 1) else 0;
        const x1: u16 = if (y == e.y) @min(e.x, cols - 1) else cols - 1;
        if (x0 > x1) return null;
        return .{ .x0 = x0, .x1 = x1 };
    }

    /// Copy the selected viewport text to the clipboard via OSC 52, which
    /// works over SSH and through nested multiplexers.
    fn copySelection(self: *Ui, v: *View) void {
        const alloc = self.alloc;

        var s = self.select_anchor.?;
        var e = self.select_head;
        if (e.y < s.y or (e.y == s.y and e.x < s.x)) std.mem.swap(CellPos, &s, &e);

        const screen = v.term.screens.active;
        const start = screen.pages.pin(.{ .viewport = .{ .x = s.x, .y = s.y } }) orelse return;
        const end = screen.pages.pin(.{ .viewport = .{ .x = e.x, .y = e.y } }) orelse return;

        var formatter: vt.formatter.ScreenFormatter = .init(screen, .plain);
        formatter.content = .{ .selection = vt.Selection.init(start, end, false) };

        var aw: std.Io.Writer.Allocating = .init(alloc);
        defer aw.deinit();
        aw.writer.print("{f}", .{formatter}) catch return;
        const text = aw.writer.buffered();
        if (text.len == 0) return;

        const encoder = std.base64.standard.Encoder;
        var seq: std.ArrayList(u8) = .empty;
        defer seq.deinit(alloc);
        seq.appendSlice(alloc, "\x1b]52;c;") catch return;
        const b64 = seq.addManyAsSlice(alloc, encoder.calcSize(text.len)) catch return;
        _ = encoder.encode(b64, text);
        seq.appendSlice(alloc, "\x07") catch return;
        protocol.writeAll(1, seq.items) catch {};
    }

    fn sgrButton(m: Mouse) ?vt.input.MouseButton {
        if (m.isWheel()) {
            return if (m.code & 1 != 0) .five else .four;
        }
        return switch (m.code & 3) {
            0 => .left,
            1 => .middle,
            2 => .right,
            else => null,
        };
    }

    // -- Daemon output -----------------------------------------------------

    fn readView(self: *Ui, buf: []u8) !void {
        const v = self.view orelse return;
        if (v.state != .live) return;
        const n = posix.read(v.sock, buf) catch 0;
        if (n == 0) {
            self.markViewLost();
            return;
        }
        v.decoder.feed(buf[0..n]) catch {
            self.markViewLost();
            return;
        };
        while (true) {
            const msg = v.decoder.next() catch {
                self.markViewLost();
                return;
            } orelse break;
            switch (msg.type) {
                .tabs => self.applyTabs(msg.payload),
                .tab_switched => {
                    const id = protocol.IdPayload.decode(msg.payload) catch continue;
                    self.active_id = id.id;
                    // Reset the local terminal so the two tabs' states
                    // never mix, and hold the previous frame until the
                    // repaint's `.screen` marks the new state complete.
                    v.term.fullReset();
                    self.select_anchor = null;
                    for (self.viewport_cache.items) |*row| row.valid = false;
                    self.awaiting_repaint = true;
                    self.awaiting_since_ms = posix.milliTimestamp();
                    self.full_render = true;
                    self.need_render = true;
                },
                .output => {
                    v.feedOutput(msg.payload);
                    // Still while seeding: the replay is making progress,
                    // so extend the hold rather than cut it off mid-stream.
                    if (self.awaiting_repaint) {
                        self.awaiting_since_ms = posix.milliTimestamp();
                    }
                    self.need_render = true;
                },
                .screen => {
                    v.app_alt = std.mem.eql(u8, msg.payload, "alt");
                    if (self.awaiting_repaint) {
                        self.awaiting_repaint = false;
                        for (self.viewport_cache.items) |*row| row.valid = false;
                        self.need_render = true;
                    }
                },
                .detached => {
                    // A detach is only ever a reply to this client's own
                    // leave/close request, so this client is on its way
                    // out; end it and restore the terminal.
                    v.state = .ended;
                    self.quitting = true;
                    self.need_render = true;
                },
                .exit => {
                    // The session ended (another client quit, or this one
                    // did): the daemon and every tab are gone, so there is
                    // nothing to reattach to. Close the UI and restore the
                    // terminal instead of stranding a landing screen on a
                    // dead socket.
                    v.state = .ended;
                    self.quitting = true;
                    self.need_render = true;
                },
                .err => {},
                else => {},
            }
            if (v.state != .live) break;
        }
    }

    fn liveView(self: *Ui) ?*View {
        const v = self.view orelse return null;
        if (v.state != .live) return null;
        return v;
    }

    fn markViewLost(self: *Ui) void {
        if (self.view) |v| {
            if (v.state == .live) {
                v.state = .lost;
                // The connection to the session is gone and there is no
                // reconnect path, so an idle landing would be a dead end.
                // Close the UI and restore the terminal.
                self.quitting = true;
            }
        }
        self.need_render = true;
    }

    /// Replace the tab list from a `.tabs` payload:
    /// `<active_id>\n` then `<id>\t<title>\n` per tab.
    fn applyTabs(self: *Ui, payload: []const u8) void {
        var lines = std.mem.splitScalar(u8, payload, '\n');
        const first = lines.next() orelse return;
        const active = std.fmt.parseInt(u32, std.mem.trim(u8, first, " \r"), 10) catch return;

        var fresh: std.ArrayList(Tab) = .empty;
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const sep = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const id = std.fmt.parseInt(u32, line[0..sep], 10) catch continue;
            const title = self.alloc.dupe(u8, line[sep + 1 ..]) catch break;
            fresh.append(self.alloc, .{ .id = id, .title = title }) catch {
                self.alloc.free(title);
                break;
            };
        }

        // Remember the tab being left behind for C-w C-w, when it still
        // existed.
        const had_old = self.hasTab(self.active_id);
        if (had_old and active != self.active_id) self.last_id = self.active_id;

        freeTabs(self.alloc, &self.tabs);
        self.tabs = fresh;
        self.active_id = active;
        if (!self.hasTab(self.active_id)) {
            if (self.tabs.items.len > 0) self.active_id = self.tabs.items[0].id;
        }
        self.need_render = true;
    }

    // -- Rendering ---------------------------------------------------------

    fn renderIfNeeded(self: *Ui) !void {
        if (!self.need_render) return;
        const now = posix.milliTimestamp();

        // A tab switch reset the local terminal and is replaying the new
        // tab's history + repaint. Hold the previous frame on screen
        // rather than paint the half-applied stream (or a blank viewport),
        // so switching is a single visible transition. The repaint's
        // `.screen` marker releases the hold; the timeout, refreshed as
        // the replay streams in, guarantees a lost marker can never freeze
        // the UI. A view that is no longer live sets `quitting`, so the
        // loop exits before another frame is composed.
        if (self.awaiting_repaint and self.liveView() != null and
            now - self.awaiting_since_ms < awaiting_repaint_timeout_ms)
        {
            // Advance the render clock so the main loop keeps sleeping
            // between checks instead of spinning on a past deadline.
            self.last_render_ms = now;
            return;
        }

        if (now - self.last_render_ms < render_interval_ms) return;
        self.last_render_ms = now;
        self.need_render = false;

        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(self.alloc);
        try self.composeFrame(&frame);
        self.full_render = false;
        if (frame.items.len > 0) try protocol.writeAll(1, frame.items);
    }

    /// Build the bytes for one repaint: changed rows only, wrapped in a
    /// synchronized update so terminals that support it repaint
    /// atomically.
    fn composeFrame(self: *Ui, frame: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        const l = self.layout;

        while (self.row_cache.items.len < l.rows) {
            try self.row_cache.append(alloc, .empty);
        }
        while (self.row_cache.items.len > l.rows) {
            var row = self.row_cache.pop() orelse break;
            row.deinit(alloc);
        }
        while (self.viewport_cache.items.len < l.rows) {
            try self.viewport_cache.append(alloc, .{});
        }
        while (self.viewport_cache.items.len > l.rows) {
            var row = self.viewport_cache.pop() orelse break;
            row.deinit(alloc);
        }

        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(alloc);
        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(alloc);
        var kitty: std.ArrayList(u8) = .empty;
        defer kitty.deinit(alloc);

        for (0..l.rows) |y| {
            scratch.clearRetainingCapacity();
            try self.composeRow(@intCast(y), &scratch);
            const cache = &self.row_cache.items[y];
            if (!self.full_render and std.mem.eql(u8, cache.items, scratch.items)) {
                continue;
            }
            cache.clearRetainingCapacity();
            try cache.appendSlice(alloc, scratch.items);
            try body.print(alloc, "\x1b[{d};1H", .{y + 1});
            try body.appendSlice(alloc, scratch.items);
        }

        try self.composeKittyGraphics(&kitty);

        const cursor = self.cursorSequence();

        // The frame consumed this round's dirty bits; clear them so the
        // next frame's viewport cache reuse reflects only new changes.
        if (self.liveView()) |v| v.term.screens.active.pages.clearDirty();

        if (body.items.len == 0 and kitty.items.len == 0 and !self.full_render) {
            try frame.appendSlice(alloc, "\x1b[?25l");
            try frame.appendSlice(alloc, cursor.pos[0..cursor.pos_len]);
            try frame.appendSlice(alloc, if (cursor.visible) "\x1b[?25h" else "\x1b[?25l");
            return;
        }

        try frame.appendSlice(alloc, "\x1b[?2026h\x1b[?25l");
        try frame.appendSlice(alloc, body.items);
        try frame.appendSlice(alloc, kitty.items);
        try frame.appendSlice(alloc, cursor.pos[0..cursor.pos_len]);
        try frame.appendSlice(alloc, if (cursor.visible) "\x1b[?25h" else "\x1b[?25l");
        try frame.appendSlice(alloc, "\x1b[?2026l");
    }

    /// Forward the focused view's kitty graphics to the real terminal. With
    /// no live view nothing should remain on screen.
    fn composeKittyGraphics(self: *Ui, out: *std.ArrayList(u8)) !void {
        const v = self.liveView() orelse {
            try self.kitty.reset(self.alloc, out);
            return;
        };
        try self.kitty.compose(self.alloc, &v.term, out, Layout.tabbar_h, self.full_render);
    }

    const CursorState = struct {
        pos: [32]u8 = undefined,
        pos_len: usize = 0,
        visible: bool = false,
    };

    fn cursorSequence(self: *Ui) CursorState {
        var state: CursorState = .{};
        const v = self.liveView() orelse return state;
        // The landing has no cursor.
        if (self.tabs.items.len == 0) return state;
        // The viewport is blank while the view is being seeded; keep the
        // cursor hidden until the repaint releases it.
        if (self.awaiting_repaint) return state;
        if (self.viewScrolled()) return state;
        const cursor = &v.term.screens.active.cursor;
        const row: usize = @min(cursor.y, self.layout.viewportRows() -| 1);
        const col: usize = @min(@as(usize, cursor.x), self.layout.cols -| 1);
        const text = std.fmt.bufPrint(&state.pos, "\x1b[{d};{d}H", .{
            row + Layout.tabbar_h + 1,
            col + 1,
        }) catch return state;
        state.pos_len = text.len;
        state.visible = v.term.modes.get(.cursor_visible);
        return state;
    }

    /// Whether the tab-bar row has status content to show: a quit
    /// confirmation or an armed prefix.
    fn statusActive(self: *Ui) bool {
        return self.confirm_quit or self.parser.pending_prefix;
    }

    /// One full screen row: the top tab bar, or a viewport row.
    fn composeRow(self: *Ui, y: u16, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        try out.appendSlice(alloc, sgr_reset);
        if (self.layout.isTabBar(y)) {
            try self.composeTabBarRow(out);
            return;
        }
        try self.composeViewportCell(y - Layout.tabbar_h, out);
    }

    /// The armed-prefix hints, most useful first: when the row is too
    /// narrow for all of them the tail is dropped, never half a hint.
    const KeyHint = struct { key: []const u8, label: []const u8 };
    const keybind_hints = [_]KeyHint{
        .{ .key = "r", .label = "new" },
        .{ .key = "Tab/S-Tab", .label = "cycle" },
        .{ .key = "1-9", .label = "jump" },
        .{ .key = "w", .label = "close" },
        .{ .key = "y", .label = "copy" },
        .{ .key = "q", .label = "detach" },
        .{ .key = "d", .label = "end" },
        .{ .key = "l", .label = "redraw" },
        .{ .key = "a", .label = "send C-w" },
    };
    const hint_gap = 3;

    /// How many leading hints fit in `width` columns, and their width.
    fn fitHints(width: usize) struct { count: usize, width: usize } {
        var used: usize = 0;
        var count: usize = 0;
        for (keybind_hints) |h| {
            const hw = h.key.len + 1 + h.label.len;
            const need = if (count == 0) hw else hint_gap + hw;
            if (used + need > width) break;
            used += need;
            count += 1;
        }
        return .{ .count = count, .width = used };
    }

    /// The top row: the tab bar, or the status overlay while
    /// the quit prompt or the keybind list is active.
    fn composeTabBarRow(self: *Ui, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        const w = self.layout.cols;
        self.tab_hits.clearRetainingCapacity();

        if (self.statusActive()) {
            try self.composeStatusRow(out);
            return;
        }

        var x: usize = 0;
        var label: std.ArrayList(u8) = .empty;
        defer label.deinit(alloc);

        for (self.tabs.items) |tab| {
            label.clearRetainingCapacity();
            label.append(alloc, ' ') catch break;
            appendTruncatedMiddle(alloc, &label, tab.title, tab_title_max) catch break;
            label.append(alloc, ' ') catch break;
            const lw: usize = displayWidth(label.items);
            if (x + lw > w) break;
            self.tab_hits.append(alloc, .{
                .id = tab.id,
                .x0 = @intCast(x),
                .x1 = @intCast(x + lw),
            }) catch {};
            const active = tab.id == self.active_id;
            try out.appendSlice(alloc, if (active) style_tab_active else style_tab_inactive);
            try appendClipped(alloc, out, label.items, lw);
            try out.appendSlice(alloc, sgr_reset);
            x += lw;
        }

        // Blank the rest of the row.
        try out.appendSlice(alloc, style_dim);
        var pad: usize = w - x;
        while (pad > 0) : (pad -= 1) try out.append(alloc, ' ');
        try out.appendSlice(alloc, sgr_reset);
    }

    /// Status content overlaid on the tab-bar row while present: the quit
    /// confirmation, or the keybind list while the prefix is armed.
    fn composeStatusRow(self: *Ui, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        const w = self.layout.cols;
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(alloc);

        // Everything shown here sits centered across the row.
        if (self.confirm_quit) {
            try out.appendSlice(alloc, style_dim);
            try text.appendSlice(alloc, "quit? y/N");
            try appendCentered(alloc, out, text.items, w);
            // Blank the rest of the row so no tab-bar cells linger.
            const tw = displayWidth(text.items);
            const shown_left = if (tw >= w) 0 else (w - tw) / 2;
            for (0..(w -| (shown_left + @min(tw, w)))) |_| try out.append(alloc, ' ');
            try out.appendSlice(alloc, sgr_reset);
            return;
        }

        // Keys stand out in bold against dim labels.
        const fit = fitHints(w);
        const left = (w - fit.width) / 2;
        try out.appendSlice(alloc, style_dim);
        for (0..left) |_| try out.append(alloc, ' ');
        for (keybind_hints[0..fit.count], 0..) |h, i| {
            if (i > 0) {
                try out.appendSlice(alloc, style_dim);
                for (0..hint_gap) |_| try out.append(alloc, ' ');
            }
            try out.appendSlice(alloc, sgr_reset);
            try out.appendSlice(alloc, style_keybind);
            try out.appendSlice(alloc, h.key);
            try out.appendSlice(alloc, sgr_reset);
            try out.appendSlice(alloc, style_dim);
            try out.append(alloc, ' ');
            try out.appendSlice(alloc, h.label);
        }
        try out.appendSlice(alloc, sgr_reset);
        for (0..(w - left - fit.width)) |_| try out.append(alloc, ' ');
    }

    fn composeViewportCell(self: *Ui, y: u16, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;

        // Erase before drawing. Erasing afterwards would eat the last
        // cell of a row that touches the terminal's right edge.
        try out.appendSlice(alloc, "\x1b[K");

        const v = self.view orelse {
            try self.composeLanding(y, "create new tab to start", out);
            return;
        };

        switch (v.state) {
            .live => {},
            .ended, .lost => {
                try self.composeLanding(y, "create new tab to start again", out);
                return;
            },
        }

        // The session has no tabs: the landing invites a fresh one.
        if (self.tabs.items.len == 0) {
            try self.composeLanding(y, "create new tab to start", out);
            return;
        }

        // While the view is still being seeded (history replay and
        // repaint in flight) the viewport stays blank; the repaint's
        // `.screen` releases it.
        if (!self.awaiting_repaint and y < v.term.rows) {
            try self.appendViewportRow(v, y, out);
        }
        try out.appendSlice(alloc, sgr_reset);

        // An in-progress mouse selection is highlighted by repainting the
        // selected cells in reverse video over the row content.
        if (self.selectionSpan(y, v.term.cols)) |span| {
            const col = self.layout.viewportX() + span.x0 + 1;
            try out.print(alloc, "\x1b[{d};{d}H", .{ y + Layout.tabbar_h + 1, col });
            try out.appendSlice(alloc, style_selected);
            // Fill the whole span with reverse-video spaces first, so
            // blank cells highlight too, then overpaint the glyphs.
            try out.appendNTimes(alloc, ' ', span.x1 - span.x0 + 1);
            try out.print(alloc, "\x1b[{d};{d}H", .{ y + Layout.tabbar_h + 1, col });
            try appendPlainSpan(alloc, &v.term, y, span.x0, span.x1, out);
            try out.appendSlice(alloc, sgr_reset);
        }
    }

    /// A small lantern, shown on the empty landing.
    const lantern_art = [_][]const u8{
        "   ~",
        "  .-.",
        " (   )",
        "  |o|",
        "  '-'",
    };

    /// The empty landing: the lantern and a one-line prompt, centered in
    /// the viewport. Shown whenever there is no session screen to paint:
    /// the session has no tabs, or it ended or was lost.
    fn composeLanding(self: *Ui, y: u16, comptime prompt: []const u8, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        const l = self.layout;
        const vw = l.viewportCols();

        const art_h: u16 = lantern_art.len;
        const total: u16 = art_h + 2;
        const top = (l.viewportRows() -| total) / 2;
        if (y < top) return;
        const line = y - top;

        if (line < art_h) {
            var art_w: usize = 0;
            for (lantern_art) |a| art_w = @max(art_w, a.len);
            if (art_w >= vw) return;
            const pad = (vw - art_w) / 2;
            for (0..pad) |_| try out.append(alloc, ' ');
            try out.appendSlice(alloc, lantern_art[line]);
            return;
        }

        const text: []const u8 = switch (line) {
            art_h + 1 => prompt,
            else => return,
        };
        if (text.len >= vw) return;
        const pad = (vw - text.len) / 2;
        try out.appendSlice(alloc, style_dim);
        for (0..pad) |_| try out.append(alloc, ' ');
        try out.appendSlice(alloc, text);
        try out.appendSlice(alloc, sgr_reset);
    }

    /// Append the serialized bytes for viewport row `y`, reusing the
    /// cached serialization when libghostty reports the row unchanged.
    fn appendViewportRow(self: *Ui, v: *View, y: u16, out: *std.ArrayList(u8)) !void {
        const alloc = self.alloc;
        const screen = v.term.screens.active;
        const pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = y } }) orelse {
            if (y < self.viewport_cache.items.len) {
                self.viewport_cache.items[y].valid = false;
            }
            return;
        };
        const entry = &self.viewport_cache.items[y];
        const node: *const anyopaque = @ptrCast(pin.node);

        if (viewportRowReusable(entry, pin, self.full_render)) {
            try out.appendSlice(alloc, entry.bytes.items);
            return;
        }

        entry.bytes.clearRetainingCapacity();
        try appendTermRow(alloc, &v.term, y, &entry.bytes);
        entry.node = node;
        entry.offset = pin.y;
        entry.valid = true;
        try out.appendSlice(alloc, entry.bytes.items);
    }
};

/// Append one row of the terminal's active screen as styled VT bytes.
/// Rendered through libghostty's own formatter, so styles, wide
/// characters, and blank runs come out exactly as the daemon would
/// replay them, just one row at a time.
pub fn appendTermRow(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    y: u16,
    out: *std.ArrayList(u8),
) !void {
    const screen = term.screens.active;
    if (term.cols == 0) return;
    // Viewport pins follow scrollback paging; at the bottom the
    // viewport and the active screen are the same rows.
    const start = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = y } }) orelse return;
    const end = screen.pages.pin(.{ .viewport = .{ .x = term.cols - 1, .y = y } }) orelse return;

    var formatter: vt.formatter.ScreenFormatter = .init(screen, .vt);
    formatter.content = .{ .selection = vt.Selection.init(start, end, true) };

    // Format straight into `out`, reusing its capacity, so a repaint
    // does not allocate a fresh writer for every row.
    const begin = out.items.len;
    {
        var aw: std.Io.Writer.Allocating = .fromArrayList(alloc, out);
        defer out.* = aw.toArrayList();
        aw.writer.print("{f}", .{formatter}) catch return error.OutOfMemory;
    }
    // A row that opened a hyperlink must not leak it into the next
    // row or the tab bar.
    if (std.mem.indexOf(u8, out.items[begin..], "\x1b]8;") != null) {
        try out.appendSlice(alloc, "\x1b]8;;\x1b\\");
    }
}

/// Append one row's cells in [x0, x1] inclusive as plain text, with
/// trailing blanks trimmed. Used to repaint the selection highlight
/// over already-rendered row content.
fn appendPlainSpan(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    y: u16,
    x0: u16,
    x1: u16,
    out: *std.ArrayList(u8),
) !void {
    const screen = term.screens.active;
    const start = screen.pages.pin(.{ .viewport = .{ .x = x0, .y = y } }) orelse return;
    const end = screen.pages.pin(.{ .viewport = .{ .x = x1, .y = y } }) orelse return;

    var formatter: vt.formatter.ScreenFormatter = .init(screen, .plain);
    formatter.content = .{ .selection = vt.Selection.init(start, end, false) };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    aw.writer.print("{f}", .{formatter}) catch return error.OutOfMemory;
    try out.appendSlice(alloc, aw.writer.buffered());
}

const TestHandler = struct {
    alloc: std.mem.Allocator,
    events: std.ArrayList(InputEvent) = .empty,
    forwarded: std.ArrayList(u8) = .empty,
    /// Number of discrete .forward events; prompts read byte-wise,
    /// so chunk boundaries are observable behavior.
    forward_chunks: usize = 0,
    /// Esc-event payload bytes, copied out (they alias the parser's
    /// hold buffer).
    escs: std.ArrayList(u8) = .empty,
    /// Bytes of the most recent arrow event, copied out (they alias
    /// the parser's hold buffer).
    last_arrow_seq: std.ArrayList(u8) = .empty,
    /// Ctrl+C (`.copy`) payload bytes, copied out (they alias the
    /// parser's hold buffer or the input).
    copies: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestHandler) void {
        self.events.deinit(self.alloc);
        self.forwarded.deinit(self.alloc);
        self.escs.deinit(self.alloc);
        self.last_arrow_seq.deinit(self.alloc);
        self.copies.deinit(self.alloc);
    }

    fn event(self: *TestHandler, ev: InputEvent) !void {
        switch (ev) {
            .forward => |bytes| {
                self.forward_chunks += 1;
                try self.forwarded.appendSlice(self.alloc, bytes);
            },
            .esc => |bytes| try self.escs.appendSlice(self.alloc, bytes),
            .copy => |bytes| {
                try self.copies.appendSlice(self.alloc, bytes);
                try self.events.append(self.alloc, .{ .copy = &.{} });
            },
            .arrow => |a| {
                // Copy the seq before storing; the slice aliases the
                // hold buffer and is only valid during this call.
                self.last_arrow_seq.clearRetainingCapacity();
                try self.last_arrow_seq.appendSlice(self.alloc, a.seq);
                var rec = a;
                rec.seq = &.{};
                try self.events.append(self.alloc, .{ .arrow = rec });
            },
            else => try self.events.append(self.alloc, ev),
        }
    }
};

test "parser: plain bytes pass through" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("hello", .{}, &h);
    try std.testing.expectEqualStrings("hello", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: Ctrl+C becomes a copy event, splitting the run" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("ab\x03cd", .{}, &h);
    try std.testing.expectEqualStrings("abcd", h.forwarded.items);
    try std.testing.expectEqualStrings("\x03", h.copies.items);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .copy = &.{} }, h.events.items[0]);
}

test "parser: kitty Ctrl+C is a copy event" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[99;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[99;5u", h.copies.items);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: modifyOtherKeys Ctrl+C is a copy event" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[27;5;99~", .{ .modify = true }, &h);
    try std.testing.expectEqualStrings("\x1b[27;5;99~", h.copies.items);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: Ctrl+Shift+C is a copy-selection event" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Kitty CSI-u: some terminals report the unshifted 'c' plus the
    // shift bit (mods 6), others the shifted 'C'.
    try p.feed("\x1b[99;6u", .{ .kitty = true }, &h);
    try p.feed("\x1b[67;6u", .{ .kitty = true }, &h);
    // modifyOtherKeys: CSI 27;6;99~.
    try p.feed("\x1b[27;6;99~", .{ .modify = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.copies.items.len);
    try std.testing.expectEqual(@as(usize, 3), h.events.items.len);
    for (h.events.items) |ev| {
        try std.testing.expectEqual(InputEvent{ .copy_selection = {} }, ev);
    }
}

test "parser: Ctrl+C inside a paste is forwarded verbatim" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[200~a\x03b\x1b[201~", .{}, &h);
    try std.testing.expectEqualStrings("a\x03b", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.copies.items.len);
}

test "parser: kitty graphics replies are swallowed" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // A placement acknowledgement like the ones the real terminal used
    // to send: it belongs to lantern, so it must not reach the application
    // (where it would echo as `p=1;OK` garbage).
    try p.feed("\x1b_Gi=7,p=1;OK\x1b\\hi", .{}, &h);
    try std.testing.expectEqualStrings("hi", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: a kitty reply split across reads is swallowed" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b_Gi=7", .{}, &h);
    try p.feed(",p=1;OK\x1b", .{}, &h);
    try p.feed("\\x", .{}, &h);
    try std.testing.expectEqualStrings("x", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: Alt+_ is not mistaken for a kitty reply" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b_x", .{}, &h);
    try std.testing.expectEqualStrings("\x1b_x", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: prefix commands" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("ab\x17cde", .{}, &h);
    try std.testing.expectEqualStrings("abde", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 'c' }, h.events.items[0]);
}

test "parser: prefix split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x17", .{}, &h);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try p.feed("k", .{}, &h);
    try std.testing.expectEqual(InputEvent{ .prefix = 'k' }, h.events.items[0]);
}

test "parser: esc backs out of an armed prefix" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x17\x1b", .{}, &h);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try std.testing.expect(!p.pending_prefix);
    // The prefix is disarmed: the next byte is plain input again.
    try p.feed("x", .{}, &h);
    try std.testing.expectEqualStrings("x", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: a mouse click while the prefix is armed cancels it cleanly" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Esc with trailing bytes is the start of a sequence, not a lone
    // cancel: the sequence must parse instead of leaking into the pty.
    try p.feed("\x17\x1b[<0;5;7M", .{}, &h);
    try std.testing.expect(!p.pending_prefix);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    const m = h.events.items[0].mouse;
    try std.testing.expectEqual(@as(u16, 0), m.code);
    try std.testing.expectEqual(@as(u16, 5), m.x);
    try std.testing.expectEqual(@as(u16, 7), m.y);
    try std.testing.expect(!m.release);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: sgr mouse press and release" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[<0;5;7M\x1b[<0;5;7m", .{}, &h);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    const press = h.events.items[0].mouse;
    try std.testing.expectEqual(@as(u16, 0), press.code);
    try std.testing.expectEqual(@as(u16, 5), press.x);
    try std.testing.expectEqual(@as(u16, 7), press.y);
    try std.testing.expect(!press.release);
    try std.testing.expect(h.events.items[1].mouse.release);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: mouse sequence split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[<6", .{}, &h);
    try p.feed("5;10;2M", .{}, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    const m = h.events.items[0].mouse;
    try std.testing.expectEqual(@as(u16, 65), m.code);
    try std.testing.expect(m.isWheel());
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: non-intercepted CSI passes through" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[1;5A\x1b[1;5C", .{}, &h);
    try std.testing.expectEqualStrings("\x1b[1;5A\x1b[1;5C", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: plain arrows become arrow events" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[A\x1b[B", .{}, &h);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .up } },
        h.events.items[0],
    );
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .down } },
        h.events.items[1],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: side arrows become arrow events" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[D\x1b[C", .{}, &h);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .left } },
        h.events.items[0],
    );
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .right } },
        h.events.items[1],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // The prefix is consumed, then a side arrow is parsed normally.
    try p.feed("\x17\x1b[C", .{}, &h);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .right } },
        h.events.items[2],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: the prefix is consumed before an arrow" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x17\x1b[B", .{}, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .down } },
        h.events.items[0],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // The prefix was consumed: the next bytes are plain input, and a
    // later arrow is parsed normally.
    try p.feed("x\x1b[A", .{}, &h);
    try std.testing.expectEqualStrings("x", h.forwarded.items);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .up } },
        h.events.items[1],
    );
}

test "parser: arrow split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[", .{}, &h);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try p.feed("A", .{}, &h);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .up } },
        h.events.items[0],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: report-events functional arrows become arrow events" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // A report-events terminal encodes even an unmodified arrow press
    // as ESC [ 1;1:1 A. After the kitty-encoded prefix it must still be
    // an arrow event, the way the legacy ESC [ A is.
    try p.feed("\x1b[119;5u\x1b[1;1:1A", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .up } },
        h.events.items[0],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // The forms without an event subfield (ESC [ 1;1 A) and the
    // repeat event are arrow events too.
    try p.feed("\x1b[1;1B\x1b[1;1:2C", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 3), h.events.items.len);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .down } },
        h.events.items[1],
    );
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .right } },
        h.events.items[2],
    );
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: functional arrows forward the original bytes" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // A functional arrow is an arrow event carrying its original bytes,
    // so the focused application receives the exact report-events
    // encoding rather than a downgraded legacy arrow.
    try p.feed("\x1b[1;1:1A", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqualStrings("\x1b[1;1:1A", h.last_arrow_seq.items);
}

test "parser: modified arrows and releases are application input" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Ctrl+Left (word motion) and an arrow release are the
    // application's: forwarded verbatim, never an arrow event, even
    // right after the prefix.
    try p.feed("\x1b[1;5D", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[1;5D", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[1;1:3A", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[1;1:3A", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: bracketed paste protects the prefix byte" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[200~a\x17b\x1b[201~", .{}, &h);
    try std.testing.expectEqualStrings("a\x17b", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .paste = true }, h.events.items[0]);
    try std.testing.expectEqual(InputEvent{ .paste = false }, h.events.items[1]);
}

test "parser: focus reports" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[I\x1b[O", .{}, &h);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .focus = true }, h.events.items[0]);
    try std.testing.expectEqual(InputEvent{ .focus = false }, h.events.items[1]);
}

test "parser: host OSC 72 drop events pass through to the session" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // A drop notification and a data response from the real terminal
    // must reach the focused session unchanged, both BEL- and
    // ST-terminated.
    try p.feed("\x1b]72;t=M:i=0;text/plain text/uri-list\x1b\\", .{}, &h);
    try p.feed("\x1b]72;t=r:x=1;i=0;SGVsbG8=\x07", .{}, &h);
    try std.testing.expectEqualStrings(
        "\x1b]72;t=M:i=0;text/plain text/uri-list\x1b\\" ++
            "\x1b]72;t=r:x=1;i=0;SGVsbG8=\x07",
        h.forwarded.items,
    );
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: host OSC 72 split across feeds is forwarded whole" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b]72;t=M;text/pl", .{}, &h);
    try p.feed("ain\x1b\\", .{}, &h);
    try std.testing.expectEqualStrings("\x1b]72;t=M;text/plain\x1b\\", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: a held lone esc flushes as the esc key" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b", .{}, &h);
    try std.testing.expectEqual(@as(usize, 0), h.escs.items.len);
    try p.flushEsc(&h);
    try std.testing.expectEqualStrings("\x1b", h.escs.items);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: kitty Ctrl+W arms the prefix, plain command key follows" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[119;5ud", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 'd' }, h.events.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: kitty Ctrl+W then encoded command key" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Encoded Ctrl+D, then (after re-arming) report-all-keys plain g.
    try p.feed("\x1b[119;5u\x1b[100;5u", .{ .kitty = true }, &h);
    try p.feed("\x1b[119;5u\x1b[103u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 0x04 }, h.events.items[0]);
    try std.testing.expectEqual(InputEvent{ .prefix = 'g' }, h.events.items[1]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: kitty Ctrl+W split across feeds" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[119;5", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try p.feed("uk", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 'k' }, h.events.items[0]);
}

test "parser: kitty prefix release and repeat stay armed" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Press, repeat, release of Ctrl+W, then the command key: one
    // command, nothing typed into the session.
    try p.feed("\x1b[119;5u\x1b[119;5:2u\x1b[119;5:3ud", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 'd' }, h.events.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // A stray prefix release outside a pending sequence is swallowed.
    try p.feed("\x1b[119;5:3u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: kitty double Ctrl+W press is the focus-last command" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Two discrete presses (not a held-key repeat): the C-w C-w
    // focus-last binding, exactly like two raw 0x17 bytes.
    try p.feed("\x1b[119;5u\x1b[119;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 0x17 }, h.events.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: kitty modifier key events while armed do not eat the command" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // A reported left-ctrl press between the prefix and the command
    // (kitty report-all-keys flag) is not the command key.
    try p.feed("\x1b[119;5u\x1b[57442;5u\x1b[100;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 0x04 }, h.events.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: kitty esc cancels an armed prefix" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[119;5u\x1b[27u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.escs.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // The prefix is disarmed: the next byte is plain input again.
    try p.feed("x", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("x", h.forwarded.items);
}

test "parser: a bare esc after an armed kitty prefix disarms on flush" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // A read ending in a bare ESC while armed could be a split CSI-u
    // Esc, so it is held; the flush timeout resolves it as the
    // cancel key, consumed silently.
    try p.feed("\x1b[119;5u\x1b", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try p.flushEsc(&h);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.escs.items.len);
    // The prefix is disarmed: the next byte is plain input again.
    try p.feed("x", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("x", h.forwarded.items);
}

test "parser: kitty esc press becomes the esc key, release passes through" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[27u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[27u", h.escs.items);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    h.escs.clearRetainingCapacity();
    // The press-event form is the esc key as well.
    try p.feed("\x1b[27;1:1u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[27;1:1u", h.escs.items);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    h.escs.clearRetainingCapacity();
    // Releases and modified Esc belong to the application.
    try p.feed("\x1b[27;1:3u\x1b[27;2u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.escs.items.len);
    try std.testing.expectEqualStrings("\x1b[27;1:3u\x1b[27;2u", h.forwarded.items);
}

test "parser: kitty other CSI-u keys pass through verbatim" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Shift+Enter, Ctrl+B, and a bare 97 with no ctrl: session input.
    try p.feed("\x1b[13;2u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[13;2u", h.forwarded.items);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[98;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[98;5u", h.forwarded.items);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[119u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[119u", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.escs.items.len);
}

test "parser: kitty CSI-u encodings pass through when kitty mode is off" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[119;5ud\x1b[27u", .{}, &h);
    try std.testing.expectEqualStrings("\x1b[119;5ud\x1b[27u", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.escs.items.len);
}

test "parser: kitty turning off mid-hold replays the sequence whole" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // The mirror dropped (say, a prompt opened) while a CSI-u key
    // was split across reads: the bytes replay verbatim instead of
    // decoding or splitting.
    try p.feed("\x1b[119", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try p.feed(";5ud", .{}, &h);
    try std.testing.expectEqualStrings("\x1b[119;5ud", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: kitty mode keeps mouse, paste, and arrow interception" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[<0;5;7M\x1b[200~a\x1b[201~\x1b[A", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 4), h.events.items.len);
    try std.testing.expectEqual(@as(u16, 5), h.events.items[0].mouse.x);
    try std.testing.expectEqual(InputEvent{ .paste = true }, h.events.items[1]);
    try std.testing.expectEqual(InputEvent{ .paste = false }, h.events.items[2]);
    try std.testing.expectEqual(
        InputEvent{ .arrow = .{ .dir = .up } },
        h.events.items[3],
    );
    try std.testing.expectEqualStrings("a", h.forwarded.items);
}

test "parser: kitty CSI-u inside a paste is application input" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[200~\x1b[27u\x1b[201~", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 0), h.escs.items.len);
    try std.testing.expectEqualStrings("\x1b[27u", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
}

test "parser: legacy escape sequences pass through in kitty mode" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // A modified arrow and an F-key: the digits stay hold candidates
    // but the sequences replay verbatim.
    try p.feed("\x1b[1;5A\x1b[15;5~", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[1;5A\x1b[15;5~", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: legacy function keys replay as one chunk" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // F5 with kitty off: held to its final and replayed whole, so a
    // prompt's byte-wise reader sees one escape sequence instead of
    // "\x1b[" plus literal "15~" typed as text.
    try p.feed("\x1b[15~", .{}, &h);
    try std.testing.expectEqualStrings("\x1b[15~", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 1), h.forward_chunks);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: non-latin layout kitty prefix and command match the base key" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Russian layout: Ctrl+(A position) reports cyrillic ef (1092)
    // with base 'a'; the command key at the D position reports
    // cyrillic de (1076) with base 'd'.
    try p.feed("\x1b[1094:1062:119;5u\x1b[1076::100;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 0x04 }, h.events.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    // An ASCII primary wins over its base (AZERTY Ctrl+Q): session
    // input, not the prefix.
    try p.feed("\x1b[122:90:119;5u", .{ .kitty = true }, &h);
    try std.testing.expectEqualStrings("\x1b[122:90:119;5u", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
}

test "parser: modify Ctrl+W arms the prefix, plain command key follows" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[27;5;119~d", .{ .modify = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 'd' }, h.events.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: modify Ctrl+W then encoded command key" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[27;5;119~\x1b[27;5;100~", .{ .modify = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 0x04 }, h.events.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: modify double Ctrl+W is the focus-last command" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // No event types exist in this protocol, so a second sequence is
    // a second press (or a repeat of a held key): the C-w C-w
    // binding, like two raw 0x17 bytes.
    try p.feed("\x1b[27;5;119~\x1b[27;5;119~", .{ .modify = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 0x17 }, h.events.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
}

test "parser: modify other encoded keys pass through verbatim" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // Ctrl+Shift+H, and the same sequence with the mode off: session
    // input either way.
    try p.feed("\x1b[27;6;72~", .{ .modify = true }, &h);
    try std.testing.expectEqualStrings("\x1b[27;6;72~", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 1), h.forward_chunks);
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b[27;5;119~", .{}, &h);
    try std.testing.expectEqualStrings("\x1b[27;5;119~", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);
}

test "parser: modify keys inside a paste are application input" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[200~\x1b[27;5;119~\x1b[201~", .{ .modify = true }, &h);
    try std.testing.expectEqualStrings("\x1b[27;5;119~", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .paste = true }, h.events.items[0]);
    try std.testing.expectEqual(InputEvent{ .paste = false }, h.events.items[1]);
}

test "parser: paste markers still decode while modify is mirrored" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x1b[200~a\x17b\x1b[201~", .{ .modify = true }, &h);
    try std.testing.expectEqualStrings("a\x17b", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .paste = true }, h.events.items[0]);
    try std.testing.expectEqual(InputEvent{ .paste = false }, h.events.items[1]);
}

test "parser: a held command key's repeats and release are swallowed" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // C-w then c, the way a report-events terminal sends them: the
    // command key as a CSI-u press, then its auto-repeat and release.
    // The repeats and release must not reach the now-focused session.
    try p.feed("\x1b[119;5u\x1b[99;1:1u", .{ .kitty = true }, &h);
    try p.feed("\x1b[99;1:2u\x1b[99;1:3u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(InputEvent{ .prefix = 'c' }, h.events.items[0]);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try std.testing.expectEqual(@as(?u32, null), p.swallow_cp);
}

test "parser: a raw-byte command key still swallows its CSI-u repeats" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // The prefix and command key arrive as raw bytes (the common case
    // before the forced flags take effect on the terminal); once
    // report-events turns on, the held key's repeats and release arrive
    // as CSI-u events keyed on the same codepoint and must be dropped.
    try p.feed("\x17c", .{ .kitty = true }, &h);
    try std.testing.expectEqual(InputEvent{ .prefix = 'c' }, h.events.items[0]);
    try p.feed("\x1b[99;1:2u\x1b[99;1:3u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try std.testing.expectEqual(@as(?u32, null), p.swallow_cp);
}

test "parser: a real key after the command ends the swallow" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x17c", .{ .kitty = true }, &h);
    // A genuinely different key is the user's input for the focused
    // session, not part of the command key's hold: it ends the swallow
    // and reaches the application.
    try p.feed("\x1b[120;1:1u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqualStrings("\x1b[120;1:1u", h.forwarded.items);
    try std.testing.expectEqual(@as(?u32, null), p.swallow_cp);
}

test "parser: modifier noise during the swallow is dropped" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    try p.feed("\x17c", .{ .kitty = true }, &h);
    // A left-ctrl release from the C-w chord (reported under report-all)
    // is keyboard noise: dropped, not forwarded, and it does not end
    // the swallow. The command key's own release then ends it.
    try p.feed("\x1b[57442;5:3u\x1b[99;1:3u", .{ .kitty = true }, &h);
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(@as(usize, 0), h.forwarded.items.len);
    try std.testing.expectEqual(@as(?u32, null), p.swallow_cp);
}

test "parser: without kitty the swallow latch self-heals" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // A command key dispatched without the kitty protocol arms the
    // latch, but there are no release events to end it, so the next
    // feed clears it and later input is never wrongly swallowed.
    try p.feed("\x17c", .{}, &h);
    try std.testing.expectEqual(InputEvent{ .prefix = 'c' }, h.events.items[0]);
    try p.feed("z", .{}, &h);
    try std.testing.expectEqualStrings("z", h.forwarded.items);
    try std.testing.expectEqual(@as(?u32, null), p.swallow_cp);
}

test "appendClipped passes UTF-8 through and clips by display columns" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // Two wide characters: four columns, padded to six.
    try appendClipped(alloc, &out, "你好", 6);
    try std.testing.expectEqualStrings("你好  ", out.items);

    // A wide character that would straddle the clip boundary is
    // dropped and its columns padded, keeping the row exact.
    out.clearRetainingCapacity();
    try appendClipped(alloc, &out, "你好", 3);
    try std.testing.expectEqualStrings("你 ", out.items);

    // A combining mark is zero width: it rides along with its base
    // character and does not consume a column.
    out.clearRetainingCapacity();
    try appendClipped(alloc, &out, "e\u{301}x", 2);
    try std.testing.expectEqualStrings("e\u{301}x", out.items);

    // Control bytes and invalid UTF-8 still surface as '?'.
    out.clearRetainingCapacity();
    try appendClipped(alloc, &out, "a\x17b\xffc", 8);
    try std.testing.expectEqualStrings("a?b?c   ", out.items);
}

test "appendCentered pads both sides to the exact width" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // Odd remainder: the extra column goes on the right.
    try appendCentered(alloc, &out, "abc", 8);
    try std.testing.expectEqualStrings("  abc   ", out.items);

    out.clearRetainingCapacity();
    try appendCentered(alloc, &out, "abcd", 8);
    try std.testing.expectEqualStrings("  abcd  ", out.items);

    // Text as wide as (or wider than) the row clips from the left
    // edge, exactly like appendClipped.
    out.clearRetainingCapacity();
    try appendCentered(alloc, &out, "abcdef", 6);
    try std.testing.expectEqualStrings("abcdef", out.items);
    out.clearRetainingCapacity();
    try appendCentered(alloc, &out, "abcdef", 4);
    try std.testing.expectEqualStrings("abcd", out.items);
}

test "appendTermRow preserves multi-byte UTF-8 session content" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 4 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("你好, world");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendTermRow(alloc, &term, 0, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "你好") != null);
}

test "appendTermRow renders styled content for one row only" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("first\r\n  \x1b[1;31mred\x1b[0m end");

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendTermRow(alloc, &term, 0, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "first") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "red") == null);

    out.clearRetainingCapacity();
    try appendTermRow(alloc, &term, 1, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "first") == null);
    // Leading blanks are preserved so columns line up.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "  ") != null);
    // The row carries SGR styling for the red word.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[") != null);

    // Blank rows render as nothing (the caller clears with EL).
    out.clearRetainingCapacity();
    try appendTermRow(alloc, &term, 3, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "kitty graphics re-emit to the real terminal" {
    const alloc = std.testing.allocator;

    const pixels = [_]u8{
        1,  2,  3,  4,
        5,  6,  7,  8,
        9,  10, 11, 12,
        13, 14, 15, 16,
    };

    // A source terminal that has parsed an application's transmission
    // and placement at row 2, column 3 (0-based).
    var src = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer src.deinit(alloc);
    src.width_px = 20 * kittygfx.cell_px_w;
    src.height_px = 6 * kittygfx.cell_px_h;
    var src_stream = src.vtStream();
    defer src_stream.deinit();

    var b64: [64]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, &pixels);
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(alloc);
    try seq.appendSlice(alloc, "\x1b[3;4H");
    try seq.print(alloc, "\x1b_Ga=t,f=32,s=2,v=2,i=7,q=2;{s}\x1b\\", .{encoded});
    try seq.appendSlice(alloc, "\x1b_Ga=p,i=7,c=3,r=2,C=1\x1b\\");
    src_stream.nextSlice(seq.items);

    const src_storage = &src.screens.active.kitty_images;
    try std.testing.expect(src_storage.imageById(7) != null);
    try std.testing.expectEqual(@as(usize, 1), src_storage.placements.count());

    var kitty: KittyState = .{};
    defer kitty.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try kitty.compose(alloc, &src, &out, 0, true);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=t") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=p") != null);
    // Every command lantern sends is quiet (`q=2`), so the real terminal
    // never replies with an acknowledgement that could leak as text.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "C=1,q=2") != null);

    // The emitted stream recreates the same image and placement in a
    // fresh terminal: the round trip the real terminal performs.
    var dst = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer dst.deinit(alloc);
    dst.width_px = 20 * kittygfx.cell_px_w;
    dst.height_px = 6 * kittygfx.cell_px_h;
    var dst_stream = dst.vtStream();
    defer dst_stream.deinit();
    dst_stream.nextSlice(out.items);

    const dst_storage = &dst.screens.active.kitty_images;
    const image = dst_storage.imageById(7) orelse return error.MissingImage;
    try std.testing.expectEqual(@as(u32, 2), image.width);
    try std.testing.expectEqual(@as(u32, 2), image.height);
    try std.testing.expectEqualSlices(u8, &pixels, image.data.bytes().?);
    try std.testing.expectEqual(@as(usize, 1), dst_storage.placements.count());

    var it = dst_storage.placements.iterator();
    const entry = it.next().?;
    const placed_image = dst_storage.imageById(entry.key_ptr.image_id).?;
    const rect = entry.value_ptr.rect(placed_image, &dst).?;
    const pt = dst.screens.active.pages.pointFromPin(.screen, rect.top_left).?;
    try std.testing.expectEqual(@as(u16, 3), pt.screen.x);
    try std.testing.expectEqual(@as(u32, 2), pt.screen.y);

    // A second pass reuses the cached image: placements are rebuilt but
    // the pixels are not sent again.
    out.clearRetainingCapacity();
    try kitty.compose(alloc, &src, &out, 0, true);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=d,d=a") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=t") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=p") != null);
}

test "kitty graphics clip a placement that scrolled above the viewport" {
    const alloc = std.testing.allocator;
    const pixels: [2 * 2 * 4]u8 = @splat(0);

    var src = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 10, .rows = 4 });
    defer src.deinit(alloc);
    src.width_px = 10 * kittygfx.cell_px_w;
    src.height_px = 4 * kittygfx.cell_px_h;
    var src_stream = src.vtStream();
    defer src_stream.deinit();

    var b64: [64]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, &pixels);
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(alloc);
    // Place a two-row image at row 1 (0-based), then scroll past it so
    // its first row sits above the top of the viewport.
    try seq.print(
        alloc,
        "\x1b[2;1H\x1b_Ga=t,f=32,s=2,v=2,i=5,q=2;{s}\x1b\\\x1b_Ga=p,i=5,c=1,r=2,C=1\x1b\\",
        .{encoded},
    );
    try seq.appendSlice(alloc, "\r\n\r\n\r\n\r\n");
    src_stream.nextSlice(seq.items);

    var kitty: KittyState = .{};
    defer kitty.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    var dst = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 10, .rows = 4 });
    defer dst.deinit(alloc);
    dst.width_px = 10 * kittygfx.cell_px_w;
    dst.height_px = 4 * kittygfx.cell_px_h;
    var dst_stream = dst.vtStream();
    defer dst_stream.deinit();

    try kitty.compose(alloc, &src, &out, 0, true);
    dst_stream.nextSlice(out.items);

    const dst_storage = &dst.screens.active.kitty_images;
    try std.testing.expectEqual(@as(usize, 1), dst_storage.placements.count());
    var it = dst_storage.placements.iterator();
    const entry = it.next().?;
    const image = dst_storage.imageById(entry.key_ptr.image_id).?;
    // The visible remainder is one row, re-anchored at the top.
    try std.testing.expectEqual(@as(u32, 1), entry.value_ptr.rows);
    const rect = entry.value_ptr.rect(image, &dst).?;
    const pt = dst.screens.active.pages.pointFromPin(.screen, rect.top_left).?;
    try std.testing.expectEqual(@as(u32, 0), pt.screen.y);
}

test "kitty graphics chunk a large image and reassemble it" {
    const alloc = std.testing.allocator;
    const w: u32 = 32;
    const h: u32 = 32;
    var pixels: [w * h * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @truncate(i *% 7 +% 3);

    var src = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 10 });
    defer src.deinit(alloc);
    src.width_px = 40 * kittygfx.cell_px_w;
    src.height_px = 10 * kittygfx.cell_px_h;
    var src_stream = src.vtStream();
    defer src_stream.deinit();

    const b64 = try alloc.alloc(u8, std.base64.standard.Encoder.calcSize(pixels.len));
    defer alloc.free(b64);
    const encoded = std.base64.standard.Encoder.encode(b64, &pixels);

    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(alloc);
    try seq.print(alloc, "\x1b_Ga=t,f=32,s={d},v={d},i=11,q=2;{s}\x1b\\", .{ w, h, encoded });
    try seq.appendSlice(alloc, "\x1b_Ga=p,i=11,c=4,r=4,C=1\x1b\\");
    src_stream.nextSlice(seq.items);

    var kitty: KittyState = .{};
    defer kitty.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try kitty.compose(alloc, &src, &out, 0, true);

    // 4096 bytes of pixels need a continuation chunk.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "m=1;") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b_Gm=0;") != null);

    var dst = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 40, .rows = 10 });
    defer dst.deinit(alloc);
    dst.width_px = 40 * kittygfx.cell_px_w;
    dst.height_px = 10 * kittygfx.cell_px_h;
    var dst_stream = dst.vtStream();
    defer dst_stream.deinit();
    dst_stream.nextSlice(out.items);

    const image = dst.screens.active.kitty_images.imageById(11) orelse return error.MissingImage;
    try std.testing.expectEqualSlices(u8, &pixels, image.data.bytes().?);
}

test "viewportRowReusable re-serializes a clean row that scrolled away" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 4 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b[HAAA\r\nBBB\r\nCCC\r\nDDD");
    const screen = term.screens.active;

    // Mimic a settled frame: one cache entry per viewport row, tagged
    // with that row's libghostty identity, then clear the dirty bits.
    var entries: [4]ViewportRow = .{ .{}, .{}, .{}, .{} };
    defer for (&entries) |*e| e.deinit(alloc);
    for (0..4) |y| {
        const pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }).?;
        try appendTermRow(alloc, &term, @intCast(y), &entries[y].bytes);
        entries[y].node = @ptrCast(pin.node);
        entries[y].offset = pin.y;
        entries[y].valid = true;
    }
    screen.pages.clearDirty();

    // Nothing changed: every settled row is reusable.
    for (0..4) |y| {
        const pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }).?;
        try std.testing.expect(viewportRowReusable(&entries[y], pin, false));
    }

    // Scroll one line. The rows that moved up are not marked dirty, but
    // they now show different content, so their stale cache entries must
    // not be reused: clean-but-moved is exactly what the dirty bit
    // misses and the identity check catches.
    stream.nextSlice("\r\nEEE");
    var clean_moved: usize = 0;
    for (0..4) |y| {
        const pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = @intCast(y) } }).?;
        if (!pin.isDirty()) {
            clean_moved += 1;
            try std.testing.expect(!viewportRowReusable(&entries[y], pin, false));
        }
    }
    // The scroll must have produced a clean-but-moved row, or this test
    // would not exercise the identity check at all.
    try std.testing.expect(clean_moved > 0);

    // A forced full repaint never reuses, even an unchanged row.
    const pin0 = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = 0 } }).?;
    try std.testing.expect(!viewportRowReusable(&entries[0], pin0, true));
}

// -- UI tests ----------------------------------------------------------------

test "layout: the viewport excludes the top tab bar" {
    const l = Layout.init(24, 80);
    try std.testing.expectEqual(@as(u16, 23), l.viewportRows());
    try std.testing.expectEqual(@as(u16, 80), l.viewportCols());
    try std.testing.expectEqual(@as(u16, 0), l.viewportX());
    try std.testing.expectEqual(@as(u16, 1), l.viewportTop());
    try std.testing.expect(l.isTabBar(0));
    try std.testing.expect(!l.isTabBar(1));
    try std.testing.expect(!l.isTabBar(22));
    try std.testing.expect(!l.isTabBar(23));
}

test "layout: hit maps coordinates onto regions" {
    const l = Layout.init(24, 80);

    // The top row is the tab bar; the first viewport row is screen row 1.
    switch (l.hit(5, 0)) {
        .tabbar => |t| try std.testing.expectEqual(@as(u16, 5), t.x),
        else => return error.TestUnexpectedResult,
    }
    switch (l.hit(5, 1)) {
        .viewport => |cell| {
            try std.testing.expectEqual(@as(u16, 5), cell.x);
            try std.testing.expectEqual(@as(u16, 0), cell.y);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (l.hit(5, 22)) {
        .viewport => |cell| {
            try std.testing.expectEqual(@as(u16, 5), cell.x);
            try std.testing.expectEqual(@as(u16, 21), cell.y);
        },
        else => return error.TestUnexpectedResult,
    }
    // Out of bounds on either axis.
    switch (l.hit(80, 23)) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
    switch (l.hit(5, 24)) {
        .none => {},
        else => return error.TestUnexpectedResult,
    }
}

test "layout: a one-row terminal is all tab bar" {
    const l = Layout.init(1, 10);
    try std.testing.expectEqual(@as(u16, 0), l.viewportRows());
    try std.testing.expect(l.isTabBar(0));
    switch (l.hit(0, 0)) {
        .tabbar => |t| try std.testing.expectEqual(@as(u16, 0), t.x),
        else => return error.TestUnexpectedResult,
    }
}

/// A UI in the test shape: no view, no tty, ready for tab bookkeeping and
/// chrome rendering.
fn testUi(alloc: std.mem.Allocator) Ui {
    return .{ .alloc = alloc, .tty = -1 };
}

test "tab bar: renders titles and records clickable spans" {
    const alloc = std.testing.allocator;
    var ui = testUi(alloc);
    defer ui.deinit();
    ui.layout = Layout.init(10, 40);
    ui.active_id = 2;
    try ui.tabs.append(alloc, .{ .id = 1, .title = try alloc.dupe(u8, "build") });
    try ui.tabs.append(alloc, .{ .id = 2, .title = try alloc.dupe(u8, "edit") });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try ui.composeTabBarRow(&out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, " build ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, " edit ") != null);
    // Titles are not prefixed with their tab number.
    try std.testing.expect(std.mem.indexOf(u8, out.items, "1 build") == null);

    try std.testing.expectEqual(@as(usize, 2), ui.tab_hits.items.len);
    // " build " is 7 columns (0..7), " edit " is 6 (7..13).
    try std.testing.expectEqual(@as(u32, 1), ui.tab_hits.items[0].id);
    try std.testing.expectEqual(@as(u16, 0), ui.tab_hits.items[0].x0);
    try std.testing.expectEqual(@as(u16, 7), ui.tab_hits.items[0].x1);
    try std.testing.expectEqual(@as(u32, 2), ui.tab_hits.items[1].id);
    try std.testing.expectEqual(@as(u16, 7), ui.tab_hits.items[1].x0);
    try std.testing.expectEqual(@as(u16, 13), ui.tab_hits.items[1].x1);
}

test "tab bar: a click selects the tab under the cursor" {
    const alloc = std.testing.allocator;
    var ui = testUi(alloc);
    defer ui.deinit();
    ui.layout = Layout.init(10, 40);
    ui.active_id = 2;
    try ui.tabs.append(alloc, .{ .id = 1, .title = try alloc.dupe(u8, "build") });
    try ui.tabs.append(alloc, .{ .id = 2, .title = try alloc.dupe(u8, "edit") });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try ui.composeTabBarRow(&out);

    // A click inside the first tab's span targets it; with no live view
    // the request is recorded locally as the previous tab.
    ui.clickTabBar(3);
    try std.testing.expectEqual(@as(?u32, 2), ui.last_id);

    // A click past the last tab's span does nothing.
    ui.last_id = null;
    ui.clickTabBar(25);
    try std.testing.expectEqual(@as(?u32, null), ui.last_id);
}

test "tab bar: the status overlay borrows the row while the prefix is armed" {
    const alloc = std.testing.allocator;
    var ui = testUi(alloc);
    defer ui.deinit();
    ui.layout = Layout.init(10, 40);
    ui.active_id = 2;
    try ui.tabs.append(alloc, .{ .id = 2, .title = try alloc.dupe(u8, "edit") });

    ui.parser.pending_prefix = true;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try ui.composeTabBarRow(&out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "new") != null);
    try std.testing.expectEqual(@as(usize, 0), ui.tab_hits.items.len);
}

test "keybind hints drop whole items when the row is narrow" {
    const all = Ui.fitHints(200);
    try std.testing.expectEqual(Ui.keybind_hints.len, all.count);
    const narrow = Ui.fitHints(30);
    try std.testing.expect(narrow.count > 0 and narrow.count < Ui.keybind_hints.len);
    try std.testing.expect(narrow.width <= 30);
    try std.testing.expectEqual(@as(usize, 0), Ui.fitHints(2).count);
}

test "tab navigation wraps and tracks the previous tab" {
    const alloc = std.testing.allocator;
    var ui = testUi(alloc);
    defer ui.deinit();
    try ui.tabs.append(alloc, .{ .id = 1, .title = try alloc.dupe(u8, "a") });
    try ui.tabs.append(alloc, .{ .id = 2, .title = try alloc.dupe(u8, "b") });
    ui.active_id = 2;

    // From the last tab, next wraps to the first.
    ui.selectOffset(1);
    try std.testing.expectEqual(@as(?u32, 2), ui.last_id);
    // With no live view the active id does not change, so prev wraps
    // back to the last tab's neighbour.
    ui.selectOffset(-1);
    try std.testing.expectEqual(@as(?u32, 2), ui.last_id);
}

test "applyTabs replaces the tab list, active id, and previous tab" {
    const alloc = std.testing.allocator;
    var ui = testUi(alloc);
    defer ui.deinit();

    ui.applyTabs("2\n1\tbuild\n2\tedit\n");
    try std.testing.expectEqual(@as(u32, 2), ui.active_id);
    try std.testing.expectEqual(@as(usize, 2), ui.tabs.items.len);
    try std.testing.expectEqualStrings("build", ui.tabs.items[0].title);
    try std.testing.expectEqualStrings("edit", ui.tabs.items[1].title);
    try std.testing.expectEqual(@as(?u32, null), ui.last_id);

    // Switching to a different active tab remembers the one left behind.
    ui.applyTabs("1\n1\tbuild\n2\tedit\n");
    try std.testing.expectEqual(@as(u32, 1), ui.active_id);
    try std.testing.expectEqual(@as(?u32, 2), ui.last_id);

    // An active id that no longer exists falls back to the first tab.
    ui.applyTabs("9\n1\tbuild\n2\tedit\n");
    try std.testing.expectEqual(@as(u32, 1), ui.active_id);

    // An empty list clears everything.
    ui.applyTabs("0\n");
    try std.testing.expectEqual(@as(usize, 0), ui.tabs.items.len);
    try std.testing.expectEqual(@as(u32, 0), ui.active_id);
}

test "applyTabs ignores a malformed active id" {
    const alloc = std.testing.allocator;
    var ui = testUi(alloc);
    defer ui.deinit();
    try ui.tabs.append(alloc, .{ .id = 5, .title = try alloc.dupe(u8, "keep") });
    ui.active_id = 5;

    ui.applyTabs("nonsense\n");
    try std.testing.expectEqual(@as(u32, 5), ui.active_id);
    try std.testing.expectEqual(@as(usize, 1), ui.tabs.items.len);
    try std.testing.expectEqualStrings("keep", ui.tabs.items[0].title);
}

test "truncateMiddle keeps both ends of a long title" {
    const alloc = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // A short title is untouched.
    try appendTruncatedMiddle(alloc, &out, "short", tab_title_max);
    try std.testing.expectEqualStrings("short", out.items);

    // A long one keeps a head and a tail around "...", exactly max wide.
    out.clearRetainingCapacity();
    try appendTruncatedMiddle(alloc, &out, "my-super-long-project-folder", tab_title_max);
    try std.testing.expectEqualStrings("my-super-...t-folder", out.items);
    try std.testing.expectEqual(tab_title_max, displayWidth(out.items));

    // A title exactly at the limit is not elided.
    out.clearRetainingCapacity();
    try appendTruncatedMiddle(alloc, &out, "01234567890123456789", tab_title_max);
    try std.testing.expectEqualStrings("01234567890123456789", out.items);

    // Too narrow for both ends: the elision itself is clipped.
    out.clearRetainingCapacity();
    try appendTruncatedMiddle(alloc, &out, "abcdef", 2);
    try std.testing.expectEqualStrings("..", out.items);
}

test "the active tab renders in fut's blue-reversed style" {
    const alloc = std.testing.allocator;
    var ui = testUi(alloc);
    defer ui.deinit();
    ui.layout = Layout.init(10, 40);
    ui.active_id = 1;
    try ui.tabs.append(alloc, .{ .id = 1, .title = try alloc.dupe(u8, "lantern") });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try ui.composeTabBarRow(&out);

    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[34;7m lantern ") != null);
}

test "parser: a late OSC 11 reply is swallowed, Alt+] is not" {
    var h: TestHandler = .{ .alloc = std.testing.allocator };
    defer h.deinit();
    var p: InputParser = .{};
    // The terminal's answer to the startup probe arriving after the
    // probe gave up: it must not be typed into the focused tab.
    try p.feed("x\x1b]11;rgb:1e1e/1e1e/2e2e\x07y", .{}, &h);
    try std.testing.expectEqualStrings("xy", h.forwarded.items);

    // Split across reads and ST-terminated.
    try p.feed("\x1b]11;rgb:ff", .{}, &h);
    try p.feed("/00/00\x1b\\z", .{}, &h);
    try std.testing.expectEqualStrings("xyz", h.forwarded.items);
    try std.testing.expectEqual(@as(usize, 0), h.events.items.len);

    // Alt+] followed by something else is ordinary input.
    h.forwarded.clearRetainingCapacity();
    try p.feed("\x1b]q", .{}, &h);
    try std.testing.expectEqualStrings("\x1b]q", h.forwarded.items);
}

test "kitty placements: unchanged scene sends nothing, row offset applied" {
    const alloc = std.testing.allocator;
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };

    var src = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 6 });
    defer src.deinit(alloc);
    src.width_px = 20 * kittygfx.cell_px_w;
    src.height_px = 6 * kittygfx.cell_px_h;
    var src_stream = src.vtStream();
    defer src_stream.deinit();
    var b64: [64]u8 = undefined;
    const encoded = std.base64.standard.Encoder.encode(&b64, &pixels);
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(alloc);
    try seq.appendSlice(alloc, "\x1b[3;4H");
    try seq.print(alloc, "\x1b_Ga=t,f=32,s=2,v=2,i=7,q=2;{s}\x1b\\", .{encoded});
    try seq.appendSlice(alloc, "\x1b_Ga=p,i=7,c=3,r=2,C=1\x1b\\");
    src_stream.nextSlice(seq.items);

    var kitty: KittyState = .{};
    defer kitty.deinit(alloc);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    // Image at 0-based row 2 with a one-row tab bar: screen row 4 (1-based).
    try kitty.compose(alloc, &src, &out, 1, false);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[4;4H") != null);

    // Nothing changed: no commands, so no flicker.
    out.clearRetainingCapacity();
    try kitty.compose(alloc, &src, &out, 1, false);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);

    // Forced (resize, redraw, tab switch): placed again, pixels not re-sent.
    try kitty.compose(alloc, &src, &out, 1, true);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=p") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "a=t") == null);
}

test "enter asks for the text pointer, restore hands it back" {
    try std.testing.expect(std.mem.indexOf(u8, enter_sequence, "\x1b]22;text\x07") != null);
    const pointer = std.mem.indexOf(u8, restore_sequence, "\x1b]22;default\x07") orelse
        return error.TestExpectedPointerReset;
    const screen = std.mem.indexOf(u8, restore_sequence, "\x1b[?1049l") orelse
        return error.TestExpectedScreenRestore;
    // The pointer shape is handed back before the saved screen is, so the
    // client never sees a stale I-beam outside lantern.
    try std.testing.expect(pointer < screen);
}

test "restore hands the drop target back to the terminal" {
    // Leaving the alternate screen while the host still targets a
    // session for drops would route a drop to a dead view.
    const unregister = std.mem.indexOf(u8, restore_sequence, "\x1b]72;t=A\x1b\\") orelse
        return error.TestExpectedDropTargetReset;
    const screen = std.mem.indexOf(u8, restore_sequence, "\x1b[?1049l") orelse
        return error.TestExpectedScreenRestore;
    try std.testing.expect(unregister < screen);
    // A repaint must not clear it, or the target would be lost on every
    // attach and tab switch.
    try std.testing.expect(std.mem.indexOf(u8, windowpkg.sanitize_sequence, "\x1b]72") == null);
}

test "canvas replay leaves the pointer shape alone" {
    // sanitize_sequence replays on every attach and tab switch. A pointer
    // reset there would clobber the shape the terminal was given at enter
    // time on each repaint.
    try std.testing.expect(std.mem.indexOf(u8, windowpkg.sanitize_sequence, "\x1b]22") == null);
}

test "formatMouseShape emits W3C names and round-trips" {
    const alloc = std.testing.allocator;
    const info = @typeInfo(MouseShape).@"enum";
    inline for (info.field_names, info.field_values) |field_name, field_value| {
        const shape: MouseShape = @enumFromInt(field_value);

        var buf: [40]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buf);
        try formatMouseShape(&writer, shape);

        // OSC 22 carries the CSS cursor name (underscores become hyphens)
        // terminated by BEL.
        var want: [40]u8 = undefined;
        var name: [field_name.len]u8 = undefined;
        for (field_name, 0..) |ch, i| name[i] = if (ch == '_') '-' else ch;
        const seq = try std.fmt.bufPrint(&want, "\x1b]22;{s}\x07", .{name});
        try std.testing.expectEqualStrings(seq, writer.buffered());

        // The terminal parses our own sequence back into the same shape.
        var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 6 });
        defer term.deinit(alloc);
        var stream = term.vtStream();
        defer stream.deinit();
        stream.nextSlice(writer.buffered());
        try std.testing.expectEqual(shape, term.mouse_shape);
    }
}

test "formatNotification: OSC 777 with title, OSC 9 without" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    try formatNotification(&writer, "build", "done");
    try std.testing.expectEqualStrings("\x1b]777;notify;build;done\x07", writer.buffered());

    writer = std.Io.Writer.fixed(&buf);
    try formatNotification(&writer, "", "hi");
    try std.testing.expectEqualStrings("\x1b]9;hi\x07", writer.buffered());
}

test "formatNotification: title split and control bytes are sanitized" {
    var buf: [128]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);

    // A `;` in the title would split the OSC fields, so it is rewritten.
    try formatNotification(&writer, "a;b", "c");
    try std.testing.expectEqualStrings("\x1b]777;notify;a:b;c\x07", writer.buffered());

    // Control bytes, including a stray BEL or ESC, never reach the wire.
    writer = std.Io.Writer.fixed(&buf);
    try formatNotification(&writer, "a\x07\x1bb", "c\nd\x7f");
    try std.testing.expectEqualStrings("\x1b]777;notify;ab;cd\x07", writer.buffered());
}

test "formatProgress: every state and its value rules" {
    var buf: [32]u8 = undefined;

    const Case = struct { state: @FieldType(ProgressReport, "state"), progress: ?u8, want: []const u8 };
    const cases = [_]Case{
        .{ .state = .remove, .progress = null, .want = "\x1b]9;4;0\x07" },
        .{ .state = .set, .progress = 50, .want = "\x1b]9;4;1;50\x07" },
        .{ .state = .set, .progress = null, .want = "\x1b]9;4;1;0\x07" },
        .{ .state = .set, .progress = 200, .want = "\x1b]9;4;1;100\x07" },
        .{ .state = .@"error", .progress = 7, .want = "\x1b]9;4;2;7\x07" },
        .{ .state = .indeterminate, .progress = 60, .want = "\x1b]9;4;3\x07" },
        .{ .state = .pause, .progress = 3, .want = "\x1b]9;4;4;3\x07" },
    };
    for (cases) |case| {
        var writer = std.Io.Writer.fixed(&buf);
        try formatProgress(&writer, case.state, case.progress);
        try std.testing.expectEqualStrings(case.want, writer.buffered());
    }
}
