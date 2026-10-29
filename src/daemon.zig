//! The session daemon: owns one session made of tabs. Every tab is a
//! Window (a PTY-attached child plus its libghostty terminal state).
//! Clients are UI views: any number may be attached at once, and each
//! view selects its own active tab and has its own size, so two clients
//! on the same session behave independently (tmux-style).
//!
//! A tab's output is broadcast to every view showing it; a tab is
//! sized to the smallest of the views showing it. Transient control
//! connections may also come and go.
//!
//! Single-threaded poll(2) loop.
//!
//! Client sockets are non-blocking and per-connection output is queued
//! and flushed on POLLOUT, so a client that reads slowly never blocks the
//! loop. A blocking write here would stall every tab until the slow
//! reader caught up (the lantern-ui freeze this design guards against).

const std = @import("std");
const posix = @import("sys.zig");

const protocol = @import("protocol.zig");
const keys = @import("keys.zig");
const altscreen = @import("altscreen.zig");
const cwd = @import("cwd.zig");
const reap = @import("reap.zig");
const windowpkg = @import("window.zig");
const kittyfmt = @import("kitty.zig");
const Window = windowpkg.Window;

const log = std.log.scoped(.daemon);

pub const Options = struct {
    socket_path: []const u8,
    listen_fd: posix.fd_t,
    /// Command for the first tab; empty runs the session shell.
    argv: []const []const u8 = &.{},
    rows: u16 = 24,
    cols: u16 = 80,
    /// Working directory for the first tab; null inherits the daemon's.
    cwd: ?[]const u8 = null,
};

/// Hard cap on a single connection's queued-but-unsent output. The
/// daemon never blocks on a client write (see `Conn.flush`), so a
/// client that stops reading would otherwise grow this without bound.
/// A client that falls this far behind is dropped instead; it
/// reconnects and gets a fresh repaint. Generous, so an ordinary burst
/// (a full-screen repaint is kilobytes) never trips it.
const max_conn_out: usize = 8 * 1024 * 1024;

/// Upper bound on how long teardown waits for queued finals to drain.
const shutdown_drain_ms: i64 = 250;

const Conn = struct {
    alloc: std.mem.Allocator,
    fd: posix.fd_t,
    decoder: protocol.Decoder,
    attached: bool = false,
    /// A UI view (vs an internal control connection): gets the
    /// active tab's scrollback history replayed on attach and switch.
    ui: bool = false,
    /// This view's active tab (0 when the session has no tabs). Each
    /// attached view selects its own tab independently.
    active_id: u32 = 0,
    /// This view's terminal size. A tab is sized to the smallest of the
    /// views currently showing it.
    rows: u16 = 0,
    cols: u16 = 0,
    /// Prefix-key (C-w) parser state for this view's input. Per view so
    /// two clients typing at once never share a half-armed prefix.
    key_parser: keys.Parser = .{},
    /// The connection is finished: its fd is dead or it was dropped.
    /// `sweep` closes the fd and frees it.
    closed: bool = false,
    /// A final frame (detach or exit) is queued: read no more input and
    /// close once `out` has drained, so the client still sees it.
    shutdown: bool = false,
    /// Frames queued for the client but not yet written to the socket.
    /// The socket is non-blocking, so a slow reader backs up here
    /// instead of blocking the loop. Drained on POLLOUT.
    out: std.ArrayList(u8) = .empty,
    /// Drop threshold for `out`; a field so tests can shrink it.
    out_cap: usize = max_conn_out,

    /// Queue a frame and write what the socket will take right now.
    /// Never blocks: the unsent remainder waits for the next POLLOUT. A
    /// client that backs up past `out_cap` is dropped rather than
    /// buffered without bound.
    fn send(self: *Conn, msg_type: protocol.MsgType, payload: []const u8) void {
        if (self.closed or self.shutdown) return;
        // A frame may not exceed the protocol's payload cap (the peer's
        // decoder treats a longer one as corruption). Terminal output is
        // a byte stream, so a long repaint is simply split; nothing else
        // is ever that large.
        if (payload.len > protocol.max_payload) {
            if (msg_type != .output) {
                self.drop();
                return;
            }
            var i: usize = 0;
            while (i < payload.len) {
                const end = @min(i + protocol.max_payload, payload.len);
                self.send(msg_type, payload[i..end]);
                i = end;
            }
            return;
        }
        protocol.appendMsg(self.alloc, &self.out, msg_type, payload) catch {
            self.drop();
            return;
        };
        if (self.out.items.len > self.out_cap) {
            self.drop();
            return;
        }
        self.flush();
    }

    /// Write as much of `out` as the socket accepts without blocking. A
    /// full send buffer (WouldBlock) just leaves the remainder for the
    /// next POLLOUT; any other error drops the connection.
    fn flush(self: *Conn) void {
        if (self.closed) return;
        var off: usize = 0;
        while (off < self.out.items.len) {
            const n = posix.write(self.fd, self.out.items[off..]) catch |err| switch (err) {
                error.WouldBlock => break,
                else => {
                    self.drop();
                    return;
                },
            };
            if (n == 0) break;
            off += n;
        }
        if (off == self.out.items.len) {
            self.out.clearRetainingCapacity();
        } else if (off > 0) {
            const remaining = self.out.items.len - off;
            std.mem.copyForwards(u8, self.out.items[0..remaining], self.out.items[off..]);
            self.out.shrinkRetainingCapacity(remaining);
        }
    }

    /// Discard queued output and mark the connection dead.
    fn drop(self: *Conn) void {
        self.closed = true;
        self.out.clearRetainingCapacity();
    }

    fn deinit(self: *Conn) void {
        self.out.deinit(self.alloc);
        self.decoder.deinit();
    }
};

/// One tab: a child process and the terminal state that remembers what
/// it has drawn.
const Tab = struct {
    id: u32,
    win: *Window,
};

var sigchld_pipe: posix.fd_t = -1;

fn handleSigchld(_: posix.SIG) callconv(.c) void {
    if (sigchld_pipe >= 0) {
        _ = posix.write(sigchld_pipe, "c") catch {};
    }
}

pub const Daemon = struct {
    alloc: std.mem.Allocator,
    io: std.Io,
    opts: Options,

    tabs: std.ArrayList(Tab) = .empty,
    /// The session's last-focused tab. New views start here, and it
    /// tracks whichever tab a view selected most recently. Each view
    /// keeps its own `active_id` after that.
    active_id: u32 = 0,
    next_id: u32 = 1,

    conns: std.ArrayList(*Conn) = .empty,

    rows: u16,
    cols: u16,

    sig_read: posix.fd_t = -1,
    quitting: bool = false,

    /// The real terminal's background as last reported by any client.
    /// Kept on the daemon so tabs created after the report learn it too.
    term_bg: ?protocol.RgbPayload = null,
    /// The latest `env` payload from a client (see protocol.zig), applied
    /// to the environment of every tab created afterwards.
    client_env: ?[]u8 = null,

    pub fn run(io: std.Io, alloc: std.mem.Allocator, opts: Options) !void {
        var self: Daemon = .{
            .alloc = alloc,
            .io = io,
            .opts = opts,
            .rows = opts.rows,
            .cols = opts.cols,
        };
        defer self.deinit();

        // Reap children via the self-pipe trick.
        const pipe_fds = try posix.pipe2(.{ .CLOEXEC = true, .NONBLOCK = true });
        self.sig_read = pipe_fds[0];
        sigchld_pipe = pipe_fds[1];
        posix.sigaction(posix.SIG.CHLD, &.{
            .handler = .{ .handler = handleSigchld },
            .mask = posix.sigemptyset(),
            .flags = posix.SA.RESTART | posix.SA.NOCLDSTOP,
        }, null);

        // A dying client must never kill the session.
        posix.sigaction(posix.SIG.PIPE, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);
        posix.sigaction(posix.SIG.HUP, &.{
            .handler = .{ .handler = posix.SIG.IGN },
            .mask = posix.sigemptyset(),
            .flags = 0,
        }, null);

        const first = try self.newTab(opts.argv, opts.cwd, opts.rows, opts.cols);
        self.active_id = first;

        try self.loop();
    }

    fn deinit(self: *Daemon) void {
        // Stop advertising the session first: tearing the tabs down can
        // take seconds, and a `lantern` started meanwhile must find no
        // session and start a fresh one instead of connecting to this
        // dying daemon and reading EOF.
        self.retireListener();

        // Signal every tab's tree together so they share one grace period.
        var leaders: std.ArrayList(posix.pid_t) = .empty;
        defer leaders.deinit(self.alloc);
        for (self.tabs.items) |tab| {
            if (!tab.win.dead) leaders.append(self.alloc, tab.win.child_pid) catch {};
        }
        reap.terminateAll(self.alloc, leaders.items);
        for (self.tabs.items) |tab| self.destroyTab(tab);
        self.tabs.deinit(self.alloc);
        for (self.conns.items) |c| {
            posix.close(c.fd);
            c.deinit();
            self.alloc.destroy(c);
        }
        self.conns.deinit(self.alloc);
        if (self.client_env) |blob| self.alloc.free(blob);
        if (self.sig_read >= 0) posix.close(self.sig_read);
        if (sigchld_pipe >= 0) posix.close(sigchld_pipe);
    }

    /// Close the listening socket and remove its file so a new `lantern`
    /// resolves "no session" and starts a fresh daemon instead of
    /// connecting to a dying one and reading EOF.
    fn retireListener(self: *Daemon) void {
        if (self.opts.listen_fd < 0) return;
        posix.close(self.opts.listen_fd);
        self.opts.listen_fd = -1;
        posix.deleteFile(self.opts.socket_path) catch {};
    }

    fn loop(self: *Daemon) !void {
        var fds: std.ArrayList(posix.pollfd) = .empty;
        defer fds.deinit(self.alloc);

        // Parallel array describing what each pollfd refers to.
        const Ref = union(enum) {
            listen,
            sigchld,
            conn: *Conn,
            /// A tab, by id, not by pointer: handling a connection's
            /// message earlier in this same batch can append or remove
            /// tabs, which moves (or frees) the array entries a stored
            /// pointer would reference.
            tab: u32,
        };
        var refs: std.ArrayList(Ref) = .empty;
        defer refs.deinit(self.alloc);

        var buf: [32 * 1024]u8 = undefined;

        while (!self.quitting) {
            fds.clearRetainingCapacity();
            refs.clearRetainingCapacity();

            try fds.append(self.alloc, .{ .fd = self.opts.listen_fd, .events = posix.POLL.IN, .revents = 0 });
            try refs.append(self.alloc, .listen);
            try fds.append(self.alloc, .{ .fd = self.sig_read, .events = posix.POLL.IN, .revents = 0 });
            try refs.append(self.alloc, .sigchld);
            for (self.conns.items) |c| {
                if (c.closed) continue;
                // A connection whose final frame has drained is done;
                // close it so sweep can free it this cycle.
                if (c.shutdown and c.out.items.len == 0) {
                    c.closed = true;
                    continue;
                }
                var events: i16 = 0;
                // Read input until shutdown; a shutdown conn only
                // drains its queued tail.
                if (!c.shutdown) events |= posix.POLL.IN;
                // Watch for writability whenever output is queued.
                if (c.out.items.len > 0) events |= posix.POLL.OUT;
                try fds.append(self.alloc, .{ .fd = c.fd, .events = events, .revents = 0 });
                try refs.append(self.alloc, .{ .conn = c });
            }
            for (self.tabs.items) |*tab| {
                if (tab.win.dead or tab.win.pty_fd < 0) continue;
                // Watch for writability while input is queued for a child
                // that is not reading (see Window.writeInput).
                var events: i16 = posix.POLL.IN;
                if (tab.win.wantsWrite()) events |= posix.POLL.OUT;
                try fds.append(self.alloc, .{ .fd = tab.win.pty_fd, .events = events, .revents = 0 });
                try refs.append(self.alloc, .{ .tab = tab.id });
            }

            _ = try posix.poll(fds.items, -1);

            for (fds.items, refs.items) |pfd, ref| {
                if (pfd.revents == 0) continue;
                switch (ref) {
                    .listen => self.acceptConn(),
                    .sigchld => self.reapChildren(&buf),
                    .conn => |c| {
                        // Drain queued output first so a writable socket
                        // makes room before any new input is handled.
                        if ((pfd.revents & posix.POLL.OUT) != 0) c.flush();
                        if (!c.closed and !c.shutdown and
                            (pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0)
                        {
                            self.serviceConn(c, &buf);
                        }
                    },
                    .tab => |id| {
                        // Resolve the tab fresh, and only service it if its
                        // pty fd is still the one poll reported: an earlier
                        // message this batch may have closed it (freeing the
                        // id) and a new tab may even have reused the fd.
                        if (self.tabById(id)) |tab| {
                            if (tab.win.pty_fd == pfd.fd) {
                                if ((pfd.revents & posix.POLL.OUT) != 0) {
                                    tab.win.flushInput() catch |err| {
                                        log.warn("tab input flush failed: {}", .{err});
                                    };
                                }
                                if ((pfd.revents & (posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR)) != 0) {
                                    self.serviceTab(tab, &buf);
                                }
                            }
                        }
                    },
                }
                if (self.quitting) break;
            }

            self.sweep();
            self.sweepTabs();
            // The session outlives its last tab: while any client is still
            // attached, stay up on the landing so a new tab can be opened.
            // It ends only once there is nothing left to keep alive: no
            // tabs and no attached client.
            if (self.tabs.items.len == 0 and !self.anyAttached()) break;
        }

        // Give queued finals (detach, exit, tab state) a bounded chance
        // to reach clients before the fds close in deinit.
        self.drainOutbound();
    }

    fn acceptConn(self: *Daemon) void {
        // Non-blocking so the daemon's writes to this client never
        // block the loop; output the socket cannot take yet is queued
        // on the Conn and flushed on POLLOUT.
        const fd = posix.accept(self.opts.listen_fd, null, null, posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK) catch |err| {
            log.warn("accept failed: {}", .{err});
            return;
        };
        const conn = self.alloc.create(Conn) catch {
            posix.close(fd);
            return;
        };
        conn.* = .{ .alloc = self.alloc, .fd = fd, .decoder = .init(self.alloc) };
        self.conns.append(self.alloc, conn) catch {
            posix.close(fd);
            self.alloc.destroy(conn);
            return;
        };
    }

    fn reapChildren(self: *Daemon, buf: []u8) void {
        _ = posix.read(self.sig_read, buf) catch {};
        // Tab teardown happens via PTY EOF, which arrives after all
        // remaining output has been drained; this only reaps zombies.
        var status: c_int = undefined;
        while (std.c.waitpid(-1, &status, std.c.W.NOHANG) > 0) {}
    }

    fn serviceConn(self: *Daemon, conn: *Conn, buf: []u8) void {
        const n = posix.read(conn.fd, buf) catch |err| switch (err) {
            // A POLLOUT-only wake (or spurious readiness) has nothing
            // to read yet; that is not an EOF.
            error.WouldBlock => return,
            else => {
                conn.closed = true;
                return;
            },
        };
        if (n == 0) {
            conn.closed = true;
            return;
        }
        conn.decoder.feed(buf[0..n]) catch {
            conn.closed = true;
            return;
        };
        while (true) {
            const msg = conn.decoder.next() catch {
                conn.closed = true;
                return;
            } orelse break;
            self.handleMsg(conn, msg) catch |err| {
                log.warn("error handling message: {}", .{err});
                conn.closed = true;
                return;
            };
            if (self.quitting or conn.closed) break;
        }
    }

    fn handleMsg(self: *Daemon, conn: *Conn, msg: protocol.Msg) !void {
        switch (msg.type) {
            .ui => conn.ui = true,

            .bg_color => {
                // The client probed its real terminal's background and
                // reported it; every tab uses it to answer OSC 11
                // queries and the color-scheme DSR from the session.
                const bg = protocol.RgbPayload.decode(msg.payload) catch return;
                self.term_bg = bg;
                for (self.tabs.items) |tab| tab.win.setBackground(bg);
            },

            .cell_size => {
                // The UI measured its real terminal's cell size. Adopt
                // it so applications size images against the cells the
                // user's terminal will actually draw. With several
                // clients attached the newest report wins.
                const cs = protocol.CellSizePayload.decode(msg.payload) catch return;
                if (!kittyfmt.setCellSize(cs.w, cs.h)) return;
                for (self.tabs.items) |tab| tab.win.setPixelSize(tab.win.term.rows, tab.win.term.cols);
            },

            .env => {
                // Remember the newest client environment; tabs created
                // from now on start with it (see newTab).
                const blob = self.alloc.dupe(u8, msg.payload) catch return;
                if (self.client_env) |old| self.alloc.free(old);
                self.client_env = blob;
            },

            .redraw_req => {
                if (!conn.attached) return;
                if (self.tabById(conn.active_id)) |tab| try self.repaintTo(conn, tab.win);
            },

            .attach => {
                const size = try protocol.SizePayload.decode(msg.payload);
                // Any number of views may be attached at once; a new
                // one joins without disturbing the others. It starts on
                // the session's last-focused tab.
                conn.attached = true;
                conn.rows = size.rows;
                conn.cols = size.cols;
                conn.key_parser = .{};
                conn.active_id = if (self.tabById(self.active_id)) |tab| tab.id else self.firstTabId();
                self.active_id = conn.active_id;
                self.rows = size.rows;
                self.cols = size.cols;
                self.updatePassthrough();
                self.sendTabs();
                if (self.tabById(conn.active_id)) |tab| self.sendTab(conn, tab.id);
                self.resizeTabs();
            },

            .input => {
                if (!conn.attached) return;
                // A UI view parses its own prefix keys, so its input is
                // the application's, byte for byte. Running it through the
                // prefix parser would corrupt pasted C-w bytes (a pasted
                // C-w d detached the view) and eat the byte after them.
                if (conn.ui) {
                    if (self.tabById(conn.active_id)) |tab| tab.win.writeInput(msg.payload) catch {};
                    return;
                }
                const Handler = struct {
                    daemon: *Daemon,
                    conn: *Conn,
                    pub fn command(h: @This(), cmd: keys.Command) !void {
                        try h.daemon.handleKeyCommand(h.conn, cmd);
                    }
                };
                // When this view's active tab runs the kitty keyboard
                // protocol or modifyOtherKeys, the view's terminal
                // mirrors it and sends the prefix key encoded.
                const prot: keys.Protocols = if (self.tabById(conn.active_id)) |tab| .{
                    .kitty = tab.win.kittyKeysActive(),
                    .modify = tab.win.modifyKeysActive(),
                } else .{};
                try conn.key_parser.feed(msg.payload, prot, Handler{ .daemon = self, .conn = conn });
            },

            .resize => {
                if (!conn.attached) return;
                const size = try protocol.SizePayload.decode(msg.payload);
                conn.rows = size.rows;
                conn.cols = size.cols;
                self.rows = size.rows;
                self.cols = size.cols;
                self.resizeTabs();
            },

            .detach_req => {
                if (!conn.attached) return;
                self.detachConn(conn, "detached");
            },

            .quit => {
                // End the session for everyone: terminate every tab and
                // close the daemon. Used by the UI's kill binding.
                if (!conn.attached) return;
                self.broadcastExit("quit");
            },

            .tab_new => {
                if (!conn.attached) return;
                self.newTabFromActive(conn) catch |err| {
                    log.warn("new tab failed: {}", .{err});
                    conn.send(.err, "could not create tab");
                };
            },

            .tab_close => {
                if (!conn.attached) return;
                const id = protocol.IdPayload.decode(msg.payload) catch return;
                self.closeTab(id.id);
            },

            .tab_select => {
                if (!conn.attached) return;
                const id = protocol.IdPayload.decode(msg.payload) catch return;
                self.selectTab(conn, id.id);
            },

            else => {},
        }
    }

    fn handleKeyCommand(self: *Daemon, conn: *Conn, cmd: keys.Command) !void {
        // A detach earlier in the same input batch ended the
        // attachment. Bytes after the detach key (auto-repeats of a
        // held C-d arriving coalesced, or keys typed during the
        // detach round trip) belong to no tab; forwarding them would
        // EOF or garble the program the user just left.
        if (!conn.attached) return;
        switch (cmd) {
            .forward => |bytes| if (self.tabById(conn.active_id)) |tab| {
                tab.win.writeInput(bytes) catch {};
            },
            .detach => |byte| self.detachConn(
                conn,
                // A C-d triggered detach warns the client that the
                // user may be holding the byte that EOFs shells.
                if (byte == 0x04) "detached-eof" else "detached",
            ),
            .redraw => if (self.tabById(conn.active_id)) |tab| try self.repaintTo(conn, tab.win),
            // Unbound prefix keys are ignored rather than announced.
            .unknown => {},
        }
    }

    // -- Tabs -------------------------------------------------------------

    fn newTab(self: *Daemon, argv: []const []const u8, cwd_opt: ?[]const u8, rows: u16, cols: u16) !u32 {
        var env = try posix.environMap(self.alloc);
        defer env.deinit();
        self.applyClientEnv(&env);
        try env.put("TERM", "xterm-256color");
        try env.put("LANTERN", "1");

        var default_argv: [1][]const u8 = .{env.get("SHELL") orelse "/bin/sh"};
        const child_argv: []const []const u8 = if (argv.len > 0) argv else &default_argv;

        const win = try Window.create(self.io, self.alloc, child_argv, &env, rows, cols, cwd_opt);
        errdefer win.destroy();

        // A tab born after a client reported the terminal background must
        // still be able to answer OSC 11 queries.
        if (self.term_bg) |bg| win.setBackground(bg);

        const id = self.next_id;
        self.next_id +%= 1;
        if (self.next_id == 0) self.next_id = 1;
        try self.tabs.append(self.alloc, .{ .id = id, .win = win });
        return id;
    }

    /// Overlay the most recent client's session environment (SSH agent,
    /// display, ...) onto a new tab's environment, so tabs do not inherit
    /// the stale values the daemon captured when it first started.
    fn applyClientEnv(self: *Daemon, env: *std.process.Environ.Map) void {
        const blob = self.client_env orelse return;
        var it = std.mem.splitScalar(u8, blob, 0);
        while (it.next()) |entry| {
            if (entry.len == 0) continue;
            if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                if (eq == 0) continue;
                env.put(entry[0..eq], entry[eq + 1 ..]) catch {};
            } else {
                _ = env.swapRemove(entry);
            }
        }
    }

    /// Open a shell tab in this view's active tab's working directory
    /// and focus it for that view, so a new tab lands where the user is
    /// working.
    fn newTabFromActive(self: *Daemon, conn: *Conn) !void {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir: ?[]const u8 = if (self.tabById(conn.active_id)) |tab|
            cwd.ofPid(&cwd_buf, tab.win.child_pid)
        else
            null;
        const rows = if (conn.rows > 0) conn.rows else self.rows;
        const cols = if (conn.cols > 0) conn.cols else self.cols;
        const id = try self.newTab(&.{}, dir, rows, cols);
        conn.active_id = id;
        conn.key_parser = .{};
        self.active_id = id;
        self.updatePassthrough();
        self.sendTabs();
        self.sendTab(conn, id);
        self.resizeTabs();
    }

    fn firstTabId(self: *Daemon) u32 {
        if (self.tabs.items.len == 0) return 0;
        return self.tabs.items[0].id;
    }

    fn tabById(self: *Daemon, id: u32) ?*Tab {
        for (self.tabs.items) |*tab| {
            if (tab.id == id) return tab;
        }
        return null;
    }

    fn tabIndex(self: *Daemon, id: u32) ?usize {
        for (self.tabs.items, 0..) |tab, i| {
            if (tab.id == id) return i;
        }
        return null;
    }

    /// Focus `id` for one view. Each view keeps its own active tab; the
    /// session's `active_id` just remembers the last choice for the next
    /// view that attaches.
    fn selectTab(self: *Daemon, conn: *Conn, id: u32) void {
        if (self.tabIndex(id) == null) return;
        if (id == conn.active_id) return;
        conn.active_id = id;
        conn.key_parser = .{};
        self.active_id = id;
        self.updatePassthrough();
        self.sendTabs();
        self.sendTab(conn, id);
        self.resizeTabs();
    }

    fn closeTab(self: *Daemon, id: u32) void {
        const idx = self.tabIndex(id) orelse return;
        const tab = self.tabs.items[idx];
        // Off-thread: a program that ignores SIGHUP/SIGTERM would
        // otherwise freeze every tab and client for the grace period.
        if (!tab.win.dead) reap.terminateTreeAsync(self.alloc, tab.win.child_pid);
        self.destroyTab(tab);
        _ = self.tabs.orderedRemove(idx);
        self.afterTabsRemoved(idx);
    }

    /// Remove tabs whose child exited, then reconcile every view.
    fn sweepTabs(self: *Daemon) void {
        var removed = false;
        var last_removed_index: usize = 0;
        var i: usize = 0;
        while (i < self.tabs.items.len) {
            const tab = self.tabs.items[i];
            if (!tab.win.dead) {
                i += 1;
                continue;
            }
            self.destroyTab(tab);
            _ = self.tabs.orderedRemove(i);
            last_removed_index = i;
            removed = true;
        }
        if (!removed) return;
        self.afterTabsRemoved(last_removed_index);
    }

    /// Reconcile per-view state after tabs were removed. Any view whose
    /// active tab is gone moves to the neighbour of the removed slot and
    /// is sent the new tab's state; every view gets a fresh tab list.
    fn afterTabsRemoved(self: *Daemon, removed_index: usize) void {
        if (self.tabs.items.len == 0) {
            // The session outlives its last tab: views stay attached on
            // the landing and can open a fresh tab.
            self.active_id = 0;
            for (self.conns.items) |c| c.active_id = 0;
            self.updatePassthrough();
            self.sendTabs();
            self.resizeTabs();
            return;
        }
        if (self.tabById(self.active_id) == null) self.active_id = self.tabs.items[0].id;
        const next = self.tabs.items[@min(removed_index, self.tabs.items.len - 1)];
        for (self.conns.items) |c| {
            if (c.closed or c.shutdown or !c.attached) continue;
            if (self.tabById(c.active_id) != null) continue;
            c.active_id = next.id;
            c.key_parser = .{};
            self.sendTab(c, next.id);
        }
        self.updatePassthrough();
        self.sendTabs();
        self.resizeTabs();
    }

    fn destroyTab(_: *Daemon, tab: Tab) void {
        tab.win.destroy();
    }

    fn tabTitle(_: *Daemon, tab: *const Tab) []const u8 {
        // A tab is named for the folder it was opened in. Application
        // window titles (OSC 2) deliberately do not replace it: shells
        // such as nushell restamp the title on every prompt, which would
        // otherwise lose the folder name.
        return tab.win.default_title;
    }

    /// Send each live view its own tab list. Payload:
    /// `<active_id>\n` then `<id>\t<title>\n` per tab, where `active_id`
    /// is that view's selected tab.
    fn sendTabs(self: *Daemon) void {
        for (self.conns.items) |conn| {
            if (conn.closed or conn.shutdown) continue;
            self.sendTabsTo(conn);
        }
    }

    fn sendTabsTo(self: *Daemon, conn: *Conn) void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.alloc);
        out.print(self.alloc, "{d}\n", .{conn.active_id}) catch return;
        for (self.tabs.items) |*tab| {
            out.print(self.alloc, "{d}\t", .{tab.id}) catch return;
            for (self.tabTitle(tab)) |byte| {
                if (byte < 0x20 or byte == 0x7f) continue;
                out.append(self.alloc, byte) catch return;
            }
            out.append(self.alloc, '\n') catch return;
        }
        conn.send(.tabs, out.items);
    }

    fn sendTab(self: *Daemon, conn: *Conn, id: u32) void {
        const tab = self.tabById(id) orelse return;
        const idp: protocol.IdPayload = .{ .id = id };
        conn.send(.tab_switched, &idp.encode());
        if (conn.ui) self.historyTo(conn, tab.win) catch {};
        self.repaintTo(conn, tab.win) catch |err| {
            log.warn("repaint failed: {}", .{err});
        };
    }

    fn serviceTab(self: *Daemon, tab: *Tab, buf: []u8) void {
        const n = posix.read(tab.win.pty_fd, buf) catch |err| n: {
            // The master is non-blocking; spurious readiness is not EOF.
            if (err == error.WouldBlock) return;
            // EIO means the slave side is fully closed: tab is done.
            if (err != error.InputOutput) {
                log.warn("tab read error: {}", .{err});
            }
            break :n 0;
        };
        if (n == 0) {
            tab.win.dead = true;
            return;
        }
        const chunk = buf[0..n];

        // Strip OSC 11 background queries up front and answer them from
        // the reported terminal background. They must not also reach an
        // attached client's real terminal, which would answer them a
        // second time, so this runs before any passthrough forwarding.
        var clean_buf: [32 * 1024]u8 = undefined;
        var clean_writer = std.Io.Writer.fixed(&clean_buf);
        const cleaned = cleaned: {
            tab.win.filterColorQueries(chunk, &clean_writer) catch break :cleaned chunk;
            break :cleaned clean_writer.buffered();
        };

        // A tab's output is passed through to the real terminals of the
        // views showing it, so their terminals answer any queries. With
        // no views, the tab answers for itself.
        if (!tab.win.passthrough) {
            tab.win.feed(cleaned);
            return;
        }

        // Forward raw bytes, minus alternate-screen toggles: the client
        // canvas cannot switch screens. When the tab switches, the rest
        // of the chunk is dropped and the new active screen is repainted
        // from terminal state.
        var out_buf: [32 * 1024 + 32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&out_buf);
        const was_alt = tab.win.onAltScreen();
        const result = tab.win.alt_filter.feed(cleaned, &writer) catch
            altscreen.Filter.Result{ .switched = true, .discard_start = 0 };

        // Bytes up to the discard point reach the views' real terminals,
        // which answer any queries among them. The repaint re-renders
        // the discarded tail from terminal state, but it cannot answer
        // queries, so the tab must.
        const split = result.discard_start orelse cleaned.len;
        tab.win.feed(cleaned[0..split]);
        if (split < cleaned.len) tab.win.feedDiscarded(cleaned[split..]);

        const filtered = writer.buffered();
        if (filtered.len > 0) self.sendToViewers(tab.id, .output, filtered);
        // Repaint when the filter stripped a toggle, or when the active
        // screen changed by a path the filter cannot see (e.g. RIS), so
        // a fresh repaint and `.screen` reach every view either way.
        if (result.switched or tab.win.onAltScreen() != was_alt) {
            self.repaintToViewers(tab);
        }
    }

    /// Whether any attached view is currently showing tab `id`.
    fn tabHasViewer(self: *Daemon, id: u32) bool {
        for (self.conns.items) |c| {
            if (c.attached and !c.closed and !c.shutdown and c.active_id == id) return true;
        }
        return false;
    }

    /// Send a frame to every attached view showing tab `id`.
    fn sendToViewers(self: *Daemon, id: u32, msg_type: protocol.MsgType, payload: []const u8) void {
        for (self.conns.items) |c| {
            if (!c.attached or c.closed or c.shutdown) continue;
            if (c.active_id != id) continue;
            c.send(msg_type, payload);
        }
    }

    /// Repaint every view showing `tab` from the tab's terminal state.
    fn repaintToViewers(self: *Daemon, tab: *Tab) void {
        const bytes = tab.win.repaint(self.alloc) catch |err| {
            log.warn("repaint failed: {}", .{err});
            return;
        };
        defer self.alloc.free(bytes);
        // The repaint covers everything fed so far; resume passthrough
        // from a clean slate.
        tab.win.alt_filter.reset();
        self.sendToViewers(tab.id, .output, bytes);
        self.sendToViewers(tab.id, .screen, if (tab.win.onAltScreen()) "alt" else "primary");
    }

    /// Remove closed conns. Runs after every poll dispatch so iteration
    /// above never sees mutation.
    fn sweep(self: *Daemon) void {
        var removed = false;
        var ci: usize = 0;
        while (ci < self.conns.items.len) {
            const c = self.conns.items[ci];
            if (!c.closed) {
                ci += 1;
                continue;
            }
            posix.close(c.fd);
            c.deinit();
            self.alloc.destroy(c);
            _ = self.conns.swapRemove(ci);
            removed = true;
        }
        // A dropped or abruptly closed view leaves the tabs it was
        // showing; recompute passthrough so a tab with no views resumes
        // answering its own queries, and let the remaining views grow.
        if (removed) {
            self.updatePassthrough();
            self.resizeTabs();
        }
    }

    fn attachedConn(self: *Daemon) ?*Conn {
        for (self.conns.items) |c| {
            if (c.attached and !c.closed) return c;
        }
        return null;
    }

    /// Whether any live connection is currently attached as a view.
    fn anyAttached(self: *Daemon) bool {
        return self.attachedConn() != null;
    }

    /// Passthrough is per tab: a tab passes its output through to the
    /// real terminals of the views showing it, so they answer queries.
    fn updatePassthrough(self: *Daemon) void {
        for (self.tabs.items) |tab| {
            tab.win.passthrough = self.tabHasViewer(tab.id);
        }
    }

    /// Size every tab to the smallest of the views currently showing it.
    /// A tab with no views keeps its size.
    fn resizeTabs(self: *Daemon) void {
        for (self.tabs.items) |*tab| self.resizeTab(tab);
    }

    fn resizeTab(self: *Daemon, tab: *Tab) void {
        var rows: u16 = 0;
        var cols: u16 = 0;
        for (self.conns.items) |c| {
            if (!c.attached or c.closed or c.shutdown) continue;
            if (c.active_id != tab.id or c.rows == 0 or c.cols == 0) continue;
            if (rows == 0 or c.rows < rows) rows = c.rows;
            if (cols == 0 or c.cols < cols) cols = c.cols;
        }
        if (rows == 0 or cols == 0) return;
        if (tab.win.term.rows == rows and tab.win.term.cols == cols) return;
        tab.win.resize(rows, cols) catch |err| {
            log.warn("resize tab failed: {}", .{err});
            return;
        };
        self.repaintToViewers(tab);
    }

    /// Send a tab's scrollback history to a ui view as a stream of
    /// `output` frames, to be fed before the repaint. The replay can be
    /// larger than one frame, so it is split across messages; the client
    /// feeds them in order into its terminal, so an escape sequence
    /// split across the boundary still parses.
    fn historyTo(self: *Daemon, conn: *Conn, win: *Window) !void {
        const bytes = (try win.historyReplay(self.alloc)) orelse return;
        defer self.alloc.free(bytes);
        var i: usize = 0;
        while (i < bytes.len) {
            const end = @min(i + protocol.max_payload, bytes.len);
            conn.send(.output, bytes[i..end]);
            i = end;
        }
    }

    fn repaintTo(self: *Daemon, conn: *Conn, win: *Window) !void {
        const bytes = try win.repaint(self.alloc);
        defer self.alloc.free(bytes);
        // The repaint covers everything fed so far; resume passthrough
        // from a clean slate.
        win.alt_filter.reset();
        conn.send(.output, bytes);
        // Repaints accompany every screen identity change (attach,
        // switch, redraw, alt-screen switches), so this keeps the
        // client's picture of the application's screen current.
        conn.send(.screen, if (win.onAltScreen()) "alt" else "primary");
    }

    fn detachConn(self: *Daemon, conn: *Conn, reason: []const u8) void {
        conn.send(.detached, reason);
        conn.attached = false;
        // Close once the detach notice has drained, not before, so the
        // client still receives it.
        conn.shutdown = true;
        self.updatePassthrough();
        self.resizeTabs();
    }

    fn broadcastExit(self: *Daemon, reason: []const u8) void {
        for (self.conns.items) |c| {
            if (c.closed or c.shutdown) continue;
            c.send(.exit, reason);
            // Drain the exit notice before closing (see drainOutbound).
            c.shutdown = true;
        }
        self.quitting = true;
    }

    /// Best-effort flush of every connection's queued output before
    /// teardown, so a final frame (detach, exit, tab state) still
    /// reaches a client that is reading. Bounded by `shutdown_drain_ms`
    /// so a client that stopped reading cannot delay shutdown.
    fn drainOutbound(self: *Daemon) void {
        const deadline = posix.milliTimestamp() + shutdown_drain_ms;
        var fds: std.ArrayList(posix.pollfd) = .empty;
        defer fds.deinit(self.alloc);
        while (true) {
            fds.clearRetainingCapacity();
            for (self.conns.items) |c| {
                if (c.closed) continue;
                c.flush();
                if (!c.closed and c.out.items.len > 0) {
                    fds.append(self.alloc, .{
                        .fd = c.fd,
                        .events = posix.POLL.OUT,
                        .revents = 0,
                    }) catch {};
                }
            }
            if (fds.items.len == 0) break;
            const now = posix.milliTimestamp();
            if (now >= deadline) break;
            _ = posix.poll(fds.items, @intCast(deadline - now)) catch break;
        }
    }
};

test "Conn.send queues output without blocking and flushes in order" {
    const alloc = std.testing.allocator;

    // A non-blocking pipe stands in for the client socket: writing to a
    // full pipe yields WouldBlock just as a full socket send buffer
    // does, so this exercises the queue/flush path without a client.
    const fds = try posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(fds[0]);

    var conn: Conn = .{ .alloc = alloc, .fd = fds[1], .decoder = .init(alloc) };
    defer {
        posix.close(fds[1]);
        conn.deinit();
    }

    const payload: [1024]u8 = @splat('x');
    const frame_count: usize = 1000;

    // Nothing reads during this loop, so the pipe fills and the surplus
    // must land in conn.out rather than block the caller. (A blocking
    // write here would hang the test, which is the regression.)
    for (0..frame_count) |_| conn.send(.output, &payload);
    try std.testing.expect(!conn.closed);
    try std.testing.expect(conn.out.items.len > 0);

    // Drain: flush what the pipe will take, read it back, repeat. Every
    // frame must arrive intact and in order.
    var decoder: protocol.Decoder = .init(alloc);
    defer decoder.deinit();
    var rbuf: [8192]u8 = undefined;
    var got: usize = 0;
    var guard: usize = 0;
    while (got < frame_count) {
        conn.flush();
        const n = posix.read(fds[0], &rbuf) catch |err| switch (err) {
            error.WouldBlock => {
                guard += 1;
                try std.testing.expect(guard < 1_000_000);
                continue;
            },
            else => return err,
        };
        try std.testing.expect(n != 0);
        try decoder.feed(rbuf[0..n]);
        while (try decoder.next()) |msg| {
            try std.testing.expectEqual(protocol.MsgType.output, msg.type);
            try std.testing.expectEqualStrings(&payload, msg.payload);
            got += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), conn.out.items.len);
}

test "Conn.send drops a client that exceeds its output cap" {
    const alloc = std.testing.allocator;

    const fds = try posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(fds[0]);

    var conn: Conn = .{
        .alloc = alloc,
        .fd = fds[1],
        .decoder = .init(alloc),
        .out_cap = 64 * 1024,
    };
    defer {
        posix.close(fds[1]);
        conn.deinit();
    }

    // Nothing reads, so once the pipe is full the queue grows until it
    // trips out_cap and the connection is dropped instead of buffering
    // without bound. The bound on the loop keeps a regression from
    // hanging the test.
    const payload: [4096]u8 = @splat('y');
    var i: usize = 0;
    while (!conn.closed and i < 10_000) : (i += 1) conn.send(.output, &payload);

    try std.testing.expect(conn.closed);
    try std.testing.expectEqual(@as(usize, 0), conn.out.items.len);
}

test "Conn.send splits an oversized output frame instead of sending a corrupt one" {
    const alloc = std.testing.allocator;

    const fds = try posix.pipe2(.{ .NONBLOCK = true });
    defer posix.close(fds[0]);

    var conn: Conn = .{
        .alloc = alloc,
        .fd = fds[1],
        .decoder = .init(alloc),
        .out_cap = 16 * 1024 * 1024,
    };
    defer {
        posix.close(fds[1]);
        conn.deinit();
    }

    // A repaint larger than one frame may carry. The peer's decoder
    // rejects any frame over max_payload as corruption, so it must
    // arrive as several in-order frames.
    const total = protocol.max_payload * 2 + 123;
    const big = try alloc.alloc(u8, total);
    defer alloc.free(big);
    @memset(big, 'z');
    conn.send(.output, big);
    try std.testing.expect(!conn.closed);

    var decoder: protocol.Decoder = .init(alloc);
    defer decoder.deinit();
    var rbuf: [64 * 1024]u8 = undefined;
    var got: usize = 0;
    var frames: usize = 0;
    var guard: usize = 0;
    while (got < total) {
        conn.flush();
        const n = posix.read(fds[0], &rbuf) catch |err| switch (err) {
            error.WouldBlock => {
                guard += 1;
                try std.testing.expect(guard < 1_000_000);
                continue;
            },
            else => return err,
        };
        try decoder.feed(rbuf[0..n]);
        while (try decoder.next()) |msg| {
            try std.testing.expectEqual(protocol.MsgType.output, msg.type);
            try std.testing.expect(msg.payload.len <= protocol.max_payload);
            got += msg.payload.len;
            frames += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), frames);
}

test "a UI view's input reaches the child verbatim, C-w bytes included" {
    const alloc = std.testing.allocator;
    const vt = @import("ghostty-vt");

    // The write end of a pipe stands in for the tab's PTY master.
    const fds = try posix.pipe();
    defer posix.close(fds[0]);
    defer posix.close(fds[1]);

    const win = try alloc.create(Window);
    defer alloc.destroy(win);
    win.* = .{
        .alloc = alloc,
        .pty_fd = fds[1],
        .child_pid = -1,
        .default_title = "t",
        .term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = 20, .rows = 5 }),
        .stream = undefined,
    };
    defer win.term.deinit(alloc);

    var d: Daemon = .{
        .alloc = alloc,
        .io = std.testing.io,
        .opts = .{ .socket_path = "", .listen_fd = -1 },
        .rows = 24,
        .cols = 80,
    };
    defer d.tabs.deinit(alloc);
    try d.tabs.append(alloc, .{ .id = 1, .win = win });

    var conn: Conn = .{
        .alloc = alloc,
        .fd = -1,
        .decoder = .init(alloc),
        .attached = true,
        .ui = true,
        .active_id = 1,
    };
    defer conn.deinit();

    // Pasted text containing the prefix byte: a C-w d used to detach the
    // view and C-w <x> used to eat <x>. The UI already handles prefix
    // keys itself, so the daemon must pass everything through.
    const pasted = "a\x17db\x17lc\x17";
    try d.handleMsg(&conn, .{ .type = .input, .payload = pasted });
    try std.testing.expect(conn.attached);
    try std.testing.expect(!conn.shutdown);

    var buf: [64]u8 = undefined;
    const n = try posix.read(fds[0], &buf);
    try std.testing.expectEqualStrings(pasted, buf[0..n]);
}
