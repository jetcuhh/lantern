//! All user-facing help text: the overview, per-command help, and
//! topic pages. Kept in one place so the CLI surface reads as a whole
//! and stays consistent.

pub const Entry = struct {
    /// Primary command or topic name.
    name: []const u8,
    /// Optional short alias for the command.
    alias: ?[]const u8 = null,
    /// Full help text printed by `lantern help <name>`.
    body: []const u8,
};

pub const overview =
    \\lantern
    \\
    \\A terminal multiplexer built on libghostty. One persistent
    \\session holds many tabs, each a shell (or any command) in its own
    \\pseudo-terminal. Run lantern with no arguments to open the UI; quitting
    \\the UI leaves every tab running, and running lantern again
    \\brings them all back exactly as you left them.
    \\
    \\usage:
    \\  lantern             open the UI (starts the session if needed)
    \\  lantern <command>   run a command
    \\
    \\commands:
    \\  version             print the version
    \\  help [page]         this overview, or a detailed page
    \\
    \\tabs:
    \\  The active tab fills the screen and a tab bar along the top
    \\  lists every tab. New tabs start a shell in the active tab's
    \\  working directory.
    \\
    \\  C-w r      new tab
    \\  C-w Tab    next tab (Shift-Tab: previous)
    \\  C-w 1..9   select a tab by its number
    \\  C-w w      close the active tab
    \\  C-w y      copy the current selection
    \\  C-w q      leave: quit the UI, tabs keep running
    \\  C-w d      quit: end the session and close every tab (asks y/N)
    \\  C-w l      redraw the active tab
    \\  C-w C-w    switch to the previously active tab
    \\  C-w a      send a literal C-w to the tab
    \\  C-w Esc    cancel the armed prefix
    \\
    \\Run 'lantern help keys' for the full key list.
    \\
    \\environment:
    \\  LANTERN_DIR         socket directory
    \\                      (default: $XDG_RUNTIME_DIR/lantern, else /tmp/lantern-<uid>)
    \\  LANTERN_LOG         append daemon and UI logs to this file (debugging)
    \\  LANTERN_FOREGROUND  run the session daemon in the foreground
    \\  LANTERN_SCROLLBACK  scrollback per tab, in bytes (default 524288, max 4194304)
    \\  LANTERN_OSC52       0/off/false: do not forward applications' clipboard
    \\                      writes (OSC 52) to your terminal
    \\
;

pub const commands = [_]Entry{
    .{
        .name = "version",
        .body =
        \\usage: lantern version
        \\
        \\Print the lantern version. Also available as -V or --version.
        \\
        ,
    },
    .{
        .name = "help",
        .body =
        \\usage: lantern help [page] [--all]
        \\
        \\Show the overview or a detailed page. There is a page for
        \\every command, plus 'keys' (the C-w bindings in the UI).
        \\--all prints every page in one pass, which is handy for
        \\piping into a pager or for tools that want to learn the
        \\whole CLI in one call.
        \\
        ,
    },
};

pub const topics = [_]Entry{
    .{
        .name = "keys",
        .body =
        \\Key bindings (prefix C-w)
        \\
        \\Everything you type is sent to the active tab, except the
        \\prefix C-w and the key that follows it. Control variants
        \\match GNU screen: C-w C-q leaves, C-w C-d ends the
        \\session, C-w C-l redraws.
        \\
        \\tabs:
        \\  C-w r        new tab; starts a shell in the active tab's
        \\               working directory
        \\  C-w Tab      next tab
        \\  C-w S-Tab    previous tab (Shift-Tab)
        \\  C-w 1..9     select the tab with that number
        \\  C-w C-w      switch back to the previously active tab
        \\  C-w a        send a literal C-w to the tab (readline word
        \\               delete, vim window commands, ...)
        \\  C-w w        close the active tab
        \\
        \\session:
        \\  C-w q        leave: quit the UI; every tab keeps running
        \\  C-w d        quit: end the session and close every tab;
        \\               asks for confirmation, answer y to quit or
        \\               n (or Esc) to cancel
        \\  C-w l        redraw the active tab
        \\  C-w y        copy the mouse selection to the clipboard
        \\  Ctrl+Shift+C copy the mouse selection (same as C-w y)
        \\  Ctrl+C       copy the mouse selection, else interrupt
        \\  C-w Esc      cancel the armed prefix
        \\
        \\mouse:
        \\  click a tab     focus it
        \\  wheel           page the active tab's scrollback; wheel back
        \\                  down or press esc to return to live output
        \\                  (full-screen applications receive arrow keys)
        \\  in the viewport forwarded to the application when it asked
        \\                  for mouse reporting; otherwise dragging
        \\                  selects text and keeps it highlighted;
        \\                  Ctrl+C (or C-w y) copies it (OSC 52)
        \\
        \\Pressing C-w alone lists the bindings in the top bar.
        \\Pasted text may contain C-w bytes safely (bracketed paste).
        \\Leaving keeps every tab running; run lantern again to return.
        \\
        ,
    },
};

pub fn find(name: []const u8) ?*const Entry {
    const eql = @import("std").mem.eql;
    for (&commands) |*entry| {
        if (eql(u8, entry.name, name)) return entry;
        if (entry.alias) |alias| {
            if (eql(u8, alias, name)) return entry;
        }
    }
    for (&topics) |*entry| {
        if (eql(u8, entry.name, name)) return entry;
    }
    return null;
}
