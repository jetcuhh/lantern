//! A window: one PTY-attached child process and its libghostty terminal
//! state. All child output is parsed through ghostty-vt so the full screen
//! (including scrollback, styles, modes, and cursor) can be rehydrated at
//! any time for attach and window switching.

const std = @import("std");
const posix = @import("sys.zig");
const vt = @import("ghostty-vt");
const altscreen = @import("altscreen.zig");
const oscquery = @import("oscquery.zig");
const ptypkg = @import("pty.zig");
const protocol = @import("protocol.zig");
const kittyfmt = @import("kitty.zig");

const log = std.log.scoped(.window);

pub const Window = struct {
    alloc: std.mem.Allocator,

    /// PTY master; -1 once the child is gone.
    pty_fd: posix.fd_t,
    child_pid: posix.pid_t,
    dead: bool = false,

    /// Default title, used when the application has not set one of its
    /// own via an OSC title sequence: the basename of the directory the
    /// child started in, so a tab is named for the folder it lives in.
    default_title: []const u8,

    /// Input bound for the child that the (non-blocking) PTY master has
    /// not accepted yet. The daemon's single event loop must never block
    /// on a program that is not reading its stdin, so the unsent tail
    /// waits here and is drained on POLLOUT (`flushInput`).
    in_queue: std.ArrayList(u8) = .empty,

    /// True while this window is the active window of an attached client.
    /// Controls whether query responses (DSR, DA, ...) are answered by
    /// the daemon or left to the client's real terminal.
    passthrough: bool = false,

    /// True while feeding bytes whose passthrough copy was discarded
    /// (see `feedDiscarded`); forces daemon-side query responses even
    /// when passing through.
    feeding_discarded: bool = false,

    /// Background color of the real terminal, reported by an attached
    /// client. Lets the daemon answer OSC 11 background queries and the
    /// color-scheme DSR from inside the session, where the application
    /// can no longer reach the real terminal. Null until a client
    /// reports it.
    term_bg: ?protocol.RgbPayload = null,
    /// An OSC 11 background query arrived before any client had reported
    /// a background color. Answered as soon as one is reported, so a
    /// session that queries the theme the instant it starts still gets
    /// an answer once the attaching client probes its terminal.
    bg_query_pending: bool = false,
    /// Strips OSC 11 background queries from the child's output so the
    /// daemon answers each exactly once (see oscquery.zig).
    color_filter: oscquery.Filter = .{},

    /// Strips alternate-screen toggles from passthrough output; the
    /// daemon repaints from terminal state on screen switches instead.
    alt_filter: altscreen.Filter = .{ .discard_after_switch = true },

    term: vt.Terminal,
    stream: Stream,

    pub const Stream = vt.TerminalStream;

    /// Cap on queued-but-unwritten child input. Input beyond this is
    /// dropped rather than buffered without bound behind a stuck program.
    pub const max_input_queue: usize = 4 * 1024 * 1024;

    /// Window is heap-allocated and pinned: the stream handler keeps a
    /// pointer to `term` and effects callbacks recover the Window with
    /// @fieldParentPtr.
    pub fn create(
        io: std.Io,
        alloc: std.mem.Allocator,
        argv: []const []const u8,
        env: *std.process.Environ.Map,
        rows: u16,
        cols: u16,
        cwd: ?[]const u8,
    ) !*Window {
        const self = try alloc.create(Window);
        errdefer alloc.destroy(self);

        const spawned = try ptypkg.spawnInPty(alloc, .{
            .argv = argv,
            .env = env,
            .size = ptypkg.makeWinsize(rows, cols),
            .cwd = cwd,
        });
        errdefer posix.close(spawned.master);
        ptypkg.setNonBlocking(spawned.master);

        self.* = .{
            .alloc = alloc,
            .pty_fd = spawned.master,
            .child_pid = spawned.pid,
            .default_title = try defaultTitle(alloc, argv[0], cwd),
            .term = undefined,
            .stream = undefined,
        };
        errdefer alloc.free(self.default_title);

        self.term = try vt.Terminal.init(io, alloc, .{
            .cols = cols,
            .rows = rows,
            .max_scrollback_bytes = scrollbackBytes(),
        });
        errdefer self.term.deinit(alloc);
        self.setPixelSize(rows, cols);

        var handler: Stream.Handler = .init(&self.term);
        handler.effects = .readonly;
        handler.effects.write_pty = effectWritePty;
        handler.effects.color_scheme = effectColorScheme;
        handler.effects.device_attributes = effectDeviceAttributes;
        handler.effects.size = effectSize;
        handler.effects.xtversion = effectXtversion;
        self.stream = .init(.{ .handler = handler, .allocator = alloc });

        return self;
    }

    /// The default title for a new window: the basename of the directory
    /// its child starts in, so a fresh tab is named for the folder the
    /// user is working in. `cwd` null means the child inherits the
    /// daemon's directory. Falls back to the launched command's name
    /// when no directory name can be found.
    fn defaultTitle(alloc: std.mem.Allocator, argv0: []const u8, cwd: ?[]const u8) ![]u8 {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        var dir: ?[]const u8 = cwd;
        if (dir == null) dir = posix.getCwd(&cwd_buf) catch null;
        if (dir) |d| {
            const base = std.fs.path.basename(d);
            if (base.len > 0) return alloc.dupe(u8, base);
        }
        return alloc.dupe(u8, std.fs.path.basename(argv0));
    }

    pub fn destroy(self: *Window) void {
        self.stream.deinit();
        self.term.deinit(self.alloc);
        self.in_queue.deinit(self.alloc);
        self.alloc.free(self.default_title);
        if (self.pty_fd >= 0) posix.close(self.pty_fd);
        self.alloc.destroy(self);
    }

    fn fromHandler(handler: *Stream.Handler) *Window {
        const stream: *Stream = @alignCast(@fieldParentPtr("handler", handler));
        return @alignCast(@fieldParentPtr("stream", stream));
    }

    /// Query responses generated by the terminal (DSR, DECRQM, ...). When
    /// a view is showing this window and it is being passed through, the
    /// view's own terminal sees the query and answers it, so the daemon
    /// stays quiet to avoid double responses. Bytes the passthrough
    /// discarded never reach that terminal, so queries among them are
    /// answered here after all.
    fn effectWritePty(handler: *Stream.Handler, data: []const u8) void {
        const self = fromHandler(handler);
        if (self.passthrough and !self.feeding_discarded) return;
        if (self.pty_fd < 0) return;
        self.writeInput(data) catch |err| {
            log.warn("window: failed writing query response: {}", .{err});
        };
    }

    // The device attributes response type is not re-exported by the
    // ghostty-vt root, so derive it from the effects callback signature.
    const DeviceAttributes = EffectReturn("device_attributes");

    // The color scheme effect returns an optional ColorScheme; recover
    // the enum the same way as the device attributes type above.
    const ColorScheme = @typeInfo(EffectReturn("color_scheme")).optional.child;

    pub fn EffectReturn(comptime field_name: []const u8) type {
        const Effects = Stream.Handler.Effects;
        const field = std.meta.fieldInfo(
            Effects,
            @field(std.meta.FieldEnum(Effects), field_name),
        );
        const Fn = @typeInfo(field.type).optional.child;
        return @typeInfo(@typeInfo(Fn).pointer.child).@"fn".return_type.?;
    }

    fn effectDeviceAttributes(handler: *Stream.Handler) DeviceAttributes {
        _ = handler;
        return .{};
    }

    /// Answer the color-scheme DSR (CSI ? 996 n) from the reported
    /// background's luminance. Returns null (no reply) until a client
    /// reports a background, matching ghostty-vt's behavior for an
    /// unknown color scheme.
    fn effectColorScheme(handler: *Stream.Handler) ?ColorScheme {
        const self = fromHandler(handler);
        const bg = self.term_bg orelse return null;
        return if (bg.isDark()) .dark else .light;
    }

    fn effectSize(handler: *Stream.Handler) ?vt.size_report.Size {
        const self = fromHandler(handler);
        return .{
            .rows = self.term.rows,
            .columns = self.term.cols,
            .cell_width = 8,
            .cell_height = 16,
        };
    }

    fn effectXtversion(handler: *Stream.Handler) []const u8 {
        _ = handler;
        return "lantern " ++ @import("main.zig").version;
    }

    /// Feed child output into the terminal emulator.
    pub fn feed(self: *Window, bytes: []const u8) void {
        self.stream.nextSlice(bytes);
    }

    /// Feed child output that was dropped from the passthrough stream
    /// (everything after an alternate-screen switch until the repaint).
    /// The client's real terminal never sees these bytes, so queries in
    /// them must be answered by the daemon or the application blocks
    /// waiting for a response that nobody sends.
    pub fn feedDiscarded(self: *Window, bytes: []const u8) void {
        self.feeding_discarded = true;
        defer self.feeding_discarded = false;
        self.stream.nextSlice(bytes);
    }

    /// Send `bytes` to the child. Never blocks: whatever the PTY will not
    /// take right now is queued (up to `max_input_queue`) and written by
    /// `flushInput` when the master becomes writable again. Input that
    /// would overflow the queue is dropped.
    pub fn writeInput(self: *Window, bytes: []const u8) !void {
        if (self.pty_fd < 0) return error.WindowDead;
        var rest = bytes;
        // Keep ordering: only write directly when nothing is queued.
        if (self.in_queue.items.len == 0) rest = try self.writeSome(rest);
        if (rest.len == 0) return;
        if (self.in_queue.items.len + rest.len > max_input_queue) {
            log.warn("window: input queue full, dropping {d} bytes", .{rest.len});
            return;
        }
        try self.in_queue.appendSlice(self.alloc, rest);
    }

    /// Whether input is waiting for the PTY to become writable.
    pub fn wantsWrite(self: *const Window) bool {
        return self.in_queue.items.len > 0;
    }

    /// Write queued input as far as the PTY accepts it.
    pub fn flushInput(self: *Window) !void {
        if (self.in_queue.items.len == 0 or self.pty_fd < 0) return;
        const total = self.in_queue.items.len;
        const rest = try self.writeSome(self.in_queue.items);
        const remaining = rest.len;
        if (remaining == 0) {
            self.in_queue.clearAndFree(self.alloc);
            return;
        }
        const off = total - remaining;
        if (off > 0) {
            std.mem.copyForwards(u8, self.in_queue.items[0..remaining], self.in_queue.items[off..]);
            self.in_queue.shrinkRetainingCapacity(remaining);
        }
    }

    /// Write until done or the PTY would block; returns the unwritten
    /// tail of `bytes`.
    fn writeSome(self: *Window, bytes: []const u8) ![]const u8 {
        var off: usize = 0;
        while (off < bytes.len) {
            const n = posix.write(self.pty_fd, bytes[off..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => return err,
            };
            if (n == 0) break;
            off += n;
        }
        return bytes[off..];
    }

    /// Copy `input` to `writer` with OSC 11 background queries removed,
    /// answering each one. The query is answered with the background a
    /// client reported; until one is known the query is recorded and
    /// answered later by `setBackground`. Removing the query keeps it
    /// from also reaching an attached client's real terminal, which
    /// would answer it a second time.
    pub fn filterColorQueries(
        self: *Window,
        input: []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        const result = try self.color_filter.feed(input, writer);
        for (0..result.background_queries) |_| self.answerBackgroundQuery();
    }

    fn answerBackgroundQuery(self: *Window) void {
        const bg = self.term_bg orelse {
            self.bg_query_pending = true;
            return;
        };
        self.writeBackgroundReply(bg);
    }

    /// Record the real terminal's background color and answer any query
    /// that arrived before it was known.
    pub fn setBackground(self: *Window, bg: protocol.RgbPayload) void {
        self.term_bg = bg;
        if (self.bg_query_pending) {
            self.bg_query_pending = false;
            self.writeBackgroundReply(bg);
        }
    }

    fn writeBackgroundReply(self: *Window, bg: protocol.RgbPayload) void {
        if (self.pty_fd < 0) return;
        var buf: [40]u8 = undefined;
        const reply = std.fmt.bufPrint(
            &buf,
            "\x1b]11;rgb:{x:0>4}/{x:0>4}/{x:0>4}\x07",
            .{ bg.r, bg.g, bg.b },
        ) catch return;
        self.writeInput(reply) catch |err| {
            log.warn("window: failed writing OSC 11 reply: {}", .{err});
        };
    }

    /// Kitty graphics sizes images in cells from the terminal's pixel
    /// size; without one an image placed with no explicit size cannot be
    /// laid out. Use the same nominal metrics as the UI's view terminals.
    pub fn setPixelSize(self: *Window, rows: u16, cols: u16) void {
        self.term.width_px = @as(u32, cols) * kittyfmt.cell_px_w;
        self.term.height_px = @as(u32, rows) * kittyfmt.cell_px_h;
    }

    pub fn resize(self: *Window, rows: u16, cols: u16) !void {
        try self.term.resize(self.alloc, .{ .cols = cols, .rows = rows });
        self.setPixelSize(rows, cols);
        if (self.pty_fd >= 0) {
            try ptypkg.Pty.setSize(self.pty_fd, ptypkg.makeWinsize(rows, cols));
        }
    }

    pub fn title(self: *Window) []const u8 {
        if (self.term.getTitle()) |t| {
            if (t.len > 0) return t;
        }
        return self.default_title;
    }

    /// Whether the active screen has any kitty keyboard protocol
    /// flags enabled. While attached, the user's terminal mirrors
    /// this state, so the C-w prefix arrives CSI-u encoded.
    pub fn kittyKeysActive(self: *Window) bool {
        return self.term.screens.active.kitty_keyboard.current().int() != 0;
    }

    /// Whether the application has xterm modifyOtherKeys mode 2 set.
    /// While attached, the user's terminal mirrors this state (the
    /// repaint's keyboard extra replays CSI > 4 ; 2 m), so the C-w
    /// prefix may arrive as CSI 27;5;119~ on xterm-faithful terminals.
    pub fn modifyKeysActive(self: *Window) bool {
        return self.term.flags.modify_other_keys_2;
    }

    /// Whether the application is on the alternate screen. The
    /// passthrough strips screen toggles, so clients cannot tell
    /// from the byte stream.
    pub fn onAltScreen(self: *Window) bool {
        return self.term.screens.active_key == .alternate;
    }

    /// VT bytes that reproduce this window's visible screen on a
    /// freshly sanitized terminal: contents, styles, cursor, and modes.
    pub fn repaint(self: *Window, alloc: std.mem.Allocator) ![]u8 {
        var raw: std.Io.Writer.Allocating = .init(alloc);
        defer raw.deinit();

        var formatter: vt.formatter.TerminalFormatter = .init(&self.term, .{ .emit = .vt });
        // Repaint the visible screen only. Every canvas drops
        // scrolled-off rows (attached clients render in the user
        // terminal's alternate screen and ui views keep no
        // scrollback), and the formatter always trims trailing blank
        // rows from its dump. Including history scrolls the canvas,
        // so whenever the screen ends in blank rows the content lands
        // shifted up by the trimmed count and the cursor restore below
        // points at the wrong row; every relative redraw the
        // application makes after that corrupts the client's view.
        formatter.content = .{ .selection = self.screenSelection() };
        formatter.extra = .{
            // Keep the client's own palette: colors are emitted as
            // palette references, not redefined.
            .palette = false,
            .modes = true,
            .scrolling_region = true,
            .tabstops = true,
            .pwd = false,
            .keyboard = true,
            .screen = .all,
        };
        try raw.writer.print("{f}", .{formatter});

        // The formatter re-emits alternate-screen modes when the window
        // is on the alt screen, but the client canvas always shows the
        // active screen, so screen toggles must never reach it.
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        try out.writer.writeAll(sanitize_sequence);
        // The formatter does not emit the title, so without this the
        // client terminal's title would go stale across reattach and
        // window switches.
        try writeTitle(self.title(), &out.writer);
        // Re-register the real terminal's drop target from the current
        // tab so a view attaching or switching tabs targets the right
        // session (see writeDndRegistration).
        try self.writeDndRegistration(&out.writer);
        var filter: altscreen.Filter = .{};
        _ = try filter.feed(raw.writer.buffered(), &out.writer);

        // The erase-display above deletes the client's images and the
        // formatter does not serialize them: replay them from our state.
        {
            var gfx: std.ArrayList(u8) = .empty;
            defer gfx.deinit(alloc);
            try kittyfmt.appendReplay(alloc, &self.term, &gfx);
            try out.writer.writeAll(gfx.items);
        }

        // Tabstop and scrolling-region rehydration is emitted after the
        // screen extras and moves the cursor, so position it last.
        try self.writeCursorPos(&out.writer);

        return alloc.dupe(u8, out.writer.buffered());
    }

    /// VT bytes that reproduce this window's scrollback HISTORY (the rows
    /// above the visible screen) as a styled, scrolling stream. A fresh
    /// ui-view terminal that feeds historyReplay() and then repaint() ends
    /// up holding the same scrollback, so a wheel-up pages real history
    /// instead of an empty buffer. Returns null when there is no history.
    ///
    /// Only ui views request this. Bytes passed straight through go to
    /// the user's real terminal, where replaying history would dump the
    /// whole buffer onto their screen.
    pub fn historyReplay(self: *Window, alloc: std.mem.Allocator) !?[]u8 {
        const pages = &self.term.screens.active.pages;
        const br = pages.getBottomRight(.history) orelse return null; // no history
        const tl = pages.getTopLeft(.history);
        const sel = vt.Selection.init(tl, br, false);

        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();

        // Content only (per-cell SGR is part of content emission); no
        // cursor, modes, or other terminal state — the repaint that
        // follows re-establishes all of that.
        var formatter: vt.formatter.TerminalFormatter = .init(&self.term, .{ .emit = .vt });
        formatter.content = .{ .selection = sel };
        formatter.extra = .none;
        try out.writer.print("{f}", .{formatter});

        // The history selection reproduces as a stream that fills the
        // canvas's visible screen with its last rows; the repaint that
        // follows opens with ED (erase display), which would drop those
        // still-visible rows. Reset SGR, then scroll a full screen so
        // every history row lands in scrollback before the erase. The
        // blank rows this leaves are in the visible area, so ED discards
        // them rather than committing them to scrollback.
        try out.writer.writeAll("\x1b[0m");
        for (0..self.term.rows) |_| try out.writer.writeAll("\r\n");

        const bytes = try alloc.dupe(u8, out.writer.buffered());
        return bytes;
    }

    /// Selection spanning the visible screen of the active terminal
    /// screen, so a repaint excludes scrollback history. Null (the
    /// formatter's dump-everything default) only if the pins cannot
    /// resolve, which a sized terminal never produces.
    fn screenSelection(self: *Window) ?vt.Selection {
        const pages = &self.term.screens.active.pages;
        const tl = pages.pin(.{ .active = .{ .x = 0, .y = 0 } }) orelse return null;
        const br = pages.pin(.{ .active = .{
            .x = self.term.cols - 1,
            .y = self.term.rows - 1,
        } }) orelse return null;
        return vt.Selection.init(tl, br, false);
    }

    fn writeCursorPos(self: *Window, writer: *std.Io.Writer) !void {
        const cursor = &self.term.screens.active.cursor;
        var row: usize = cursor.y;
        var col: usize = cursor.x;
        // CUP is relative to the scrolling region in origin mode.
        if (self.term.modes.get(.origin)) {
            row -|= self.term.scrolling_region.top;
            col -|= self.term.scrolling_region.left;
        }
        try writer.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    }

    /// OSC 72 bytes that re-advertise this window to a freshly attached
    /// or newly focused view's real terminal as its drop target, or clear
    /// a stale one when the application is not accepting drops. Live
    /// registration is relayed by the view itself; this covers the state
    /// it never saw because it was established before attach or while the
    /// tab was in the background.
    fn writeDndRegistration(self: *Window, writer: *std.Io.Writer) !void {
        const dnd = self.term.kitty_dnd orelse {
            try writer.writeAll("\x1b]72;t=A\x1b\\");
            return;
        };
        try writer.writeAll("\x1b]72;t=a");
        if (dnd.drop.client_id != 0) {
            try writer.print(":i={d}", .{dnd.drop.client_id});
        }
        try writer.writeByte(';');
        try writer.writeAll(dnd.drop.registered_mimes.items);
        try writer.writeAll("\x1b\\");
    }
};

/// Default scrollback per terminal, in bytes of libghostty page memory.
const default_scrollback: usize = 512 * 1024;
/// Upper bound for `LANTERN_SCROLLBACK`. The scrollback is replayed to a
/// client on attach and the daemon drops a client whose queue passes 8
/// MiB, so the history must stay comfortably below that.
const max_scrollback: usize = 4 * 1024 * 1024;

/// Scrollback size for new terminals: `$LANTERN_SCROLLBACK` (bytes) when
/// set to a valid number, clamped to `max_scrollback`, else the default.
pub fn scrollbackBytes() usize {
    const text = posix.getenv("LANTERN_SCROLLBACK") orelse return default_scrollback;
    const n = std.fmt.parseInt(usize, text, 10) catch return default_scrollback;
    return std.math.clamp(n, 0, max_scrollback);
}

/// OSC 2: set the client terminal's window title. Control bytes are
/// dropped so the title text cannot terminate or corrupt the sequence.
fn writeTitle(title: []const u8, writer: *std.Io.Writer) !void {
    try writer.writeAll("\x1b]2;");
    for (title) |byte| {
        if (byte < 0x20 or byte == 0x7f) continue;
        try writer.writeByte(byte);
    }
    try writer.writeByte(0x07);
}

/// Resets every piece of terminal state a window's repaint or
/// passthrough may have changed, without touching the screen choice or
/// the saved cursor. DECSTR is deliberately avoided: it clears the
/// cursor position that `1049h` saved, which the client needs intact
/// for the final `1049l` restore on detach.
pub const reset_state_sequence =
    "\x0f\x1b(B" ++ // locking shift and G0 charset to ASCII
    "\x1b[0m" ++ // SGR reset
    "\x1b[0 q" ++ // default cursor style
    "\x1b[?1l\x1b[?5l\x1b[?6l\x1b[?7h" ++ // cursor keys, reverse video, origin, autowrap
    "\x1b[4l" ++ // insert mode off
    "\x1b[r\x1b[?69l" ++ // scrolling margins reset
    "\x1b[?25h" ++ // cursor visible
    "\x1b[?1000l\x1b[?1002l\x1b[?1003l\x1b[?1005l\x1b[?1006l" ++ // mouse off
    "\x1b[?2004l" ++ // bracketed paste off
    "\x1b[?1004l" ++ // focus reporting off
    "\x1b[>4;0m" ++ // modifyOtherKeys off
    "\x1b[=0;1u"; // kitty keyboard flags cleared

/// Repaint preamble: reset state, then clear the client canvas. The
/// canvas is the client terminal's own alternate screen, so no screen
/// toggles belong here.
pub const sanitize_sequence = reset_state_sequence ++ "\x1b[H\x1b[2J";

test "defaultTitle names a tab for the last path component only" {
    const alloc = std.testing.allocator;

    // The whole path is never shown: only the final folder name.
    const cases = [_]struct { cwd: []const u8, want: []const u8 }{
        .{ .cwd = "/home/dev", .want = "dev" },
        .{ .cwd = "/home/jet/dev/lantern", .want = "lantern" },
        .{ .cwd = "/home/dev/", .want = "dev" },
        .{ .cwd = "/home/dev/my-project", .want = "my-project" },
    };
    for (cases) |case| {
        const title = try Window.defaultTitle(alloc, "/bin/sh", case.cwd);
        defer alloc.free(title);
        try std.testing.expectEqualStrings(case.want, title);
    }
}

test "window state machine without a child" {
    // Exercise the terminal+stream wiring directly (no PTY): construct
    // the pieces the same way Window.create does.
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("hello \x1b[1;31mred\x1b[0m\r\nline2");

    const plain = try term.plainString(alloc);
    defer alloc.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "hello red") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "line2") != null);

    // Styled repaint contains the bold+red SGR introducer and content.
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    var formatter: vt.formatter.TerminalFormatter = .init(&term, .{ .emit = .vt });
    formatter.extra = .{
        .palette = false,
        .modes = true,
        .scrolling_region = true,
        .tabstops = false,
        .pwd = false,
        .keyboard = true,
        .screen = .all,
    };
    try out.writer.print("{f}", .{formatter});
    const repainted = out.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, repainted, "red") != null);
    try std.testing.expect(std.mem.indexOf(u8, repainted, "\x1b[") != null);
}

test "repaint reproduces the screen once output has scrolled" {
    // The shape every frame-based TUI leaves behind (Claude Code's
    // idle prompt is the motivating case): output has scrolled into
    // history, the application then redraws a short frame at the top
    // and erases the rest, leaving trailing blank rows below the
    // cursor. The repaint must land every row and the cursor exactly
    // where the emulator has them, or every subsequent relative
    // redraw by the application corrupts the client's view.
    const alloc = std.testing.allocator;

    var win: Window = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = -1,
        .default_title = "test",
        .term = try vt.Terminal.init(std.testing.io, alloc, .{
            .cols = 20,
            .rows = 5,
            .max_scrollback_bytes = 512 * 1024,
        }),
        .stream = undefined,
    };
    defer win.term.deinit(alloc);
    var stream = win.term.vtStream();
    defer stream.deinit();

    // Eight lines scroll three into history, then a two-row frame
    // is drawn and everything below it erased: the screen is
    // L4, "lantern>", and three blank rows, cursor after the "lantern>".
    stream.nextSlice("L1\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6\r\nL7\r\nL8");
    stream.nextSlice("\x1b[2;1Hlantern>\x1b[0J");

    const bytes = try win.repaint(alloc);
    defer alloc.free(bytes);

    // Replay on a fresh terminal of the same size, standing in for
    // an attached client's alternate-screen canvas or a ui view.
    var canvas = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer canvas.deinit(alloc);
    var canvas_stream = canvas.vtStream();
    defer canvas_stream.deinit();
    canvas_stream.nextSlice(bytes);

    const want = try win.term.plainString(alloc);
    defer alloc.free(want);
    const got = try canvas.plainString(alloc);
    defer alloc.free(got);
    try std.testing.expectEqualStrings(want, got);

    const want_cursor = win.term.screens.active.cursor;
    const got_cursor = canvas.screens.active.cursor;
    try std.testing.expectEqual(want_cursor.y, got_cursor.y);
    try std.testing.expectEqual(want_cursor.x, got_cursor.x);
}

test "repaint re-advertises the drop target and clears it when unregistered" {
    const alloc = std.testing.allocator;

    var win: Window = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = -1,
        .default_title = "test",
        .term = try vt.Terminal.init(std.testing.io, alloc, .{
            .cols = 20,
            .rows = 5,
            .max_scrollback_bytes = 512 * 1024,
        }),
        .stream = undefined,
    };
    defer win.term.deinit(alloc);
    var stream = win.term.vtStream();
    defer stream.deinit();

    // Nothing registered: the repaint tells the host to stop targeting
    // this tab, which clears a registration left by the tab we left.
    {
        const bytes = try win.repaint(alloc);
        defer alloc.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]72;t=A\x1b\\") != null);
    }

    // The application registers with a MIME list and a multiplexer id.
    stream.nextSlice("\x1b]72;t=a:i=3;text/plain text/uri-list\x1b\\");
    try std.testing.expect(win.term.kitty_dnd != null);
    {
        const bytes = try win.repaint(alloc);
        defer alloc.free(bytes);
        try std.testing.expect(std.mem.indexOf(
            u8,
            bytes,
            "\x1b]72;t=a:i=3;text/plain text/uri-list\x1b\\",
        ) != null);
    }

    // Unregistering clears it again.
    stream.nextSlice("\x1b]72;t=A\x1b\\");
    try std.testing.expect(win.term.kitty_dnd == null);
    {
        const bytes = try win.repaint(alloc);
        defer alloc.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\x1b]72;t=A\x1b\\") != null);
    }
}

test "historyReplay reconstructs scrollback for a ui view canvas" {
    // A switched-to ui view starts with an empty terminal; feeding
    // historyReplay() then repaint() must leave it holding the same
    // scrollback the daemon window has, so a wheel-up pages real history.
    const alloc = std.testing.allocator;

    var win: Window = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = -1,
        .default_title = "test",
        .term = try vt.Terminal.init(std.testing.io, alloc, .{
            .cols = 20,
            .rows = 5,
            .max_scrollback_bytes = 512 * 1024,
        }),
        .stream = undefined,
    };
    defer win.term.deinit(alloc);
    var stream = win.term.vtStream();
    defer stream.deinit();

    // Ten lines on a five-row screen: five scroll into history, five
    // stay visible. The first row carries color, to prove styling
    // survives the round trip.
    stream.nextSlice("\x1b[31mL1\x1b[0m\r\nL2\r\nL3\r\nL4\r\nL5\r\nL6\r\nL7\r\nL8\r\nL9\r\nL10");

    const history = (try win.historyReplay(alloc)) orelse return error.TestUnexpectedResult;
    defer alloc.free(history);
    // The colored history row keeps its SGR.
    try std.testing.expect(std.mem.indexOf(u8, history, "\x1b[") != null);

    const repaint = try win.repaint(alloc);
    defer alloc.free(repaint);

    // A fresh canvas, standing in for a ui view's terminal.
    var canvas = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 512 * 1024 });
    defer canvas.deinit(alloc);
    var canvas_stream = canvas.vtStream();
    defer canvas_stream.deinit();
    canvas_stream.nextSlice(history);
    canvas_stream.nextSlice(repaint);

    // Full dump (history + visible) matches: the canvas holds the same
    // scrollback as the window, with no blank gap.
    const want_full = try win.term.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(want_full);
    const got_full = try canvas.screens.active.dumpStringAlloc(alloc, .{ .screen = .{} });
    defer alloc.free(got_full);
    try std.testing.expectEqualStrings(want_full, got_full);

    // The viewport still sits at the live bottom.
    const want_screen = try win.term.plainString(alloc);
    defer alloc.free(want_screen);
    const got_screen = try canvas.plainString(alloc);
    defer alloc.free(got_screen);
    try std.testing.expectEqualStrings(want_screen, got_screen);
}

test "historyReplay returns null without scrollback" {
    const alloc = std.testing.allocator;
    var win: Window = .{
        .alloc = alloc,
        .pty_fd = -1,
        .child_pid = -1,
        .default_title = "test",
        .term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5, .max_scrollback_bytes = 512 * 1024 }),
        .stream = undefined,
    };
    defer win.term.deinit(alloc);
    var stream = win.term.vtStream();
    defer stream.deinit();
    // Two lines, nothing scrolled off: no history.
    stream.nextSlice("hello\r\nworld");
    try std.testing.expect((try win.historyReplay(alloc)) == null);
}

test "title set via OSC is tracked and emitted sanitized" {
    const alloc = std.testing.allocator;

    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 });
    defer term.deinit(alloc);
    var stream = term.vtStream();
    defer stream.deinit();

    stream.nextSlice("\x1b]2;my title\x07");
    try std.testing.expectEqualStrings("my title", term.getTitle().?);

    var buf: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buf);
    try writeTitle(term.getTitle().?, &writer);
    try std.testing.expectEqualStrings("\x1b]2;my title\x07", writer.buffered());

    // Control bytes in a title cannot break out of the sequence.
    writer = std.Io.Writer.fixed(&buf);
    try writeTitle("a\x1b\x07b\x7f!", &writer);
    try std.testing.expectEqualStrings("\x1b]2;ab!\x07", writer.buffered());
}

/// Build a childless window whose PTY master is the write end of a pipe,
/// so a test can read back whatever the window writes to the child.
fn testWindowWithPipe(alloc: std.mem.Allocator, read_fd: *posix.fd_t) !Window {
    const fds = try posix.pipe();
    read_fd.* = fds[0];
    return .{
        .alloc = alloc,
        .pty_fd = fds[1],
        .child_pid = -1,
        .default_title = "test",
        .term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 }),
        .stream = undefined,
    };
}

test "OSC 11 background query is answered from the reported background" {
    const alloc = std.testing.allocator;
    var read_fd: posix.fd_t = undefined;
    var win = try testWindowWithPipe(alloc, &read_fd);
    defer posix.close(read_fd);
    defer posix.close(win.pty_fd);
    defer win.term.deinit(alloc);

    // A query before any background is known is deferred, not dropped.
    var sink: [16]u8 = undefined;
    var w = std.Io.Writer.fixed(&sink);
    try win.filterColorQueries("\x1b]11;?\x07", &w);
    try std.testing.expectEqualStrings("", w.buffered()); // query stripped
    try std.testing.expect(win.bg_query_pending);

    // Learning the background answers the pending query.
    win.setBackground(.{ .r = 0xffff, .g = 0xffff, .b = 0xffff });
    try std.testing.expect(!win.bg_query_pending);
    var buf: [64]u8 = undefined;
    const n = try posix.read(read_fd, &buf);
    try std.testing.expectEqualStrings("\x1b]11;rgb:ffff/ffff/ffff\x07", buf[0..n]);

    // A later query is answered immediately, now that the color is known.
    w = std.Io.Writer.fixed(&sink);
    try win.filterColorQueries("\x1b]11;?\x07", &w);
    const n2 = try posix.read(read_fd, &buf);
    try std.testing.expectEqualStrings("\x1b]11;rgb:ffff/ffff/ffff\x07", buf[0..n2]);
}

test "color-scheme DSR answered from background luminance" {
    const alloc = std.testing.allocator;
    var read_fd: posix.fd_t = undefined;
    var win = try testWindowWithPipe(alloc, &read_fd);
    defer posix.close(read_fd);
    defer posix.close(win.pty_fd);
    defer win.term.deinit(alloc);

    // Wire the real handler so CSI ? 996 n routes through effectColorScheme.
    var handler: Window.Stream.Handler = .init(&win.term);
    handler.effects = .readonly;
    handler.effects.write_pty = Window.effectWritePty;
    handler.effects.color_scheme = Window.effectColorScheme;
    win.stream = .init(.{ .handler = handler, .allocator = alloc });
    defer win.stream.deinit();

    // A light background reports color scheme 2 (light).
    win.setBackground(.{ .r = 0xffff, .g = 0xffff, .b = 0xffff });
    win.feed("\x1b[?996n");
    var buf: [32]u8 = undefined;
    const n = try posix.read(read_fd, &buf);
    try std.testing.expectEqualStrings("\x1b[?997;2n", buf[0..n]);

    // A dark background reports color scheme 1 (dark).
    win.setBackground(.{ .r = 0x1e1e, .g = 0x1e1e, .b = 0x2222 });
    win.feed("\x1b[?996n");
    const n2 = try posix.read(read_fd, &buf);
    try std.testing.expectEqualStrings("\x1b[?997;1n", buf[0..n2]);
}

test "writeInput queues what a full PTY refuses and flushInput drains it in order" {
    const alloc = std.testing.allocator;
    // A non-blocking pipe stands in for the PTY master: a full pipe
    // refuses writes (WouldBlock) just as a PTY whose program is not
    // reading does. A blocking write here would hang the test, which is
    // the regression (it froze the whole daemon).
    const fds = try posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    var win: Window = .{
        .alloc = alloc,
        .pty_fd = fds[1],
        .child_pid = -1,
        .default_title = "test",
        .term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 }),
        .stream = undefined,
    };
    defer win.term.deinit(alloc);
    defer win.in_queue.deinit(alloc);

    const chunk_rep: [64][16]u8 = @splat("0123456789abcdef".*);
    const chunk = std.mem.sliceAsBytes(&chunk_rep); // 1 KiB
    const chunks = 512; // 512 KiB: far more than a pipe holds
    for (0..chunks) |_| try win.writeInput(chunk);
    try std.testing.expect(win.wantsWrite());

    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(alloc);
    var buf: [4096]u8 = undefined;
    var guard: usize = 0;
    while (got.items.len < chunk.len * chunks) {
        try win.flushInput();
        const n = posix.read(fds[0], &buf) catch |err| switch (err) {
            error.WouldBlock => {
                guard += 1;
                try std.testing.expect(guard < 1_000_000);
                continue;
            },
            else => return err,
        };
        try got.appendSlice(alloc, buf[0..n]);
    }
    try std.testing.expect(!win.wantsWrite());
    for (got.items, 0..) |b, k| try std.testing.expectEqual(chunk[k % chunk.len], b);
}
