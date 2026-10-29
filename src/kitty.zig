//! Kitty graphics serialization, shared by the two places that must turn a
//! libghostty terminal's image state back into protocol bytes:
//!
//!  * the UI compositor (`ui.zig`), which re-emits the focused tab's images
//!    to the user's real terminal, because the UI paints the session itself
//!    and the images would otherwise never reach it; and
//!  * the daemon's repaint (`window.zig`), which must re-send the images to
//!    a view whenever it replays a tab's screen. A repaint opens with an
//!    erase-display, which deletes the view terminal's images, and the
//!    libghostty formatter does not serialize them, so without this a
//!    resize, alternate-screen switch, tab switch or reattach made every
//!    image disappear.
//!
//! Placement resolution mirrors the render path rather than the protocol
//! storage: pin, relative (`H=`/`V=`) and unicode-placeholder (`U=1`)
//! placements all resolve to an absolute cell and source rectangle, are
//! z-sorted, and skip placements that a later opaque placement completely
//! covers. Video senders stack every frame until the storage quota evicts
//! them, so sending the whole stack would flicker and waste bandwidth.
//!
//! Everything here is quiet (`q=2`): the real terminal's acknowledgements
//! would otherwise be forwarded into the focused application and echoed as
//! garbage text.

const std = @import("std");
const vt = @import("ghostty-vt");

/// Fallback cell metrics, used until the real terminal's cell size is
/// known (or when it cannot report one).
pub const default_cell_px_w: u32 = 8;
pub const default_cell_px_h: u32 = 16;

/// Cell metrics reported to applications that ask for pixel sizes
/// (XTWINOPS, kitty) and used to lay out images. They must match the real
/// terminal's cells: an application sizes an image in cells from the
/// reported metrics, and the real terminal then draws those cells at its
/// own size, so a mismatch stretches the image. The UI sets them from the
/// terminal's reported pixel size; the daemon sets them from the UI's
/// `cell_size` message. Both processes are single-threaded.
pub var cell_px_w: u32 = default_cell_px_w;
pub var cell_px_h: u32 = default_cell_px_h;

/// Derive the cell size from a terminal's reported text-area size in
/// pixels. Null when the terminal does not report pixels (all zero, as
/// many do over a plain pty) or the result is implausible.
pub fn cellSizeFromPixels(cols: u16, rows: u16, xpixel: u16, ypixel: u16) ?struct { w: u32, h: u32 } {
    if (cols == 0 or rows == 0 or xpixel == 0 or ypixel == 0) return null;
    const w: u32 = @as(u32, xpixel) / cols;
    const h: u32 = @as(u32, ypixel) / rows;
    if (!validCellSize(w, h)) return null;
    return .{ .w = w, .h = h };
}

/// Bounds that reject garbage from a peer or a terminal.
pub fn validCellSize(w: u32, h: u32) bool {
    return w >= 1 and w <= 256 and h >= 1 and h <= 512;
}

/// Adopt new cell metrics process-wide. Returns false for an invalid size.
pub fn setCellSize(w: u32, h: u32) bool {
    if (!validCellSize(w, h)) return false;
    cell_px_w = w;
    cell_px_h = h;
    return true;
}

pub const Image = vt.kitty.graphics.Image;
pub const Placement = vt.kitty.graphics.ImageStorage.Placement;
pub const PlacementKey = vt.kitty.graphics.ImageStorage.PlacementKey;

/// Which rows a placement's row is measured against.
pub const Anchor = enum {
    /// The (possibly scrolled) viewport: what the user is looking at.
    viewport,
    /// The live screen, ignoring scrollback: what a repaint replays.
    active,
};

/// One placement resolved to an absolute position and source rectangle,
/// ready to serialize. Positions are rows relative to the anchor (negative
/// when the placement begins above it) and absolute columns.
pub const Resolved = struct {
    image_id: u32,
    placement_id: u32,
    z: i32,
    row: i32,
    col: u32,
    /// Destination grid size in cells.
    cols: u32,
    rows: u32,
    /// Destination size in pixels, for occlusion decisions.
    dest_w: u32,
    dest_h: u32,
    x_offset: u32,
    y_offset: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    /// Value copy of the storage's image record. `data` is the current
    /// animation frame and points into terminal storage after collection.
    image: Image,
};

/// Append an APC kitty-graphics command with no payload data.
pub fn appendControl(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    control: []const u8,
) !void {
    try out.appendSlice(alloc, "\x1b_G");
    try out.appendSlice(alloc, control);
    try out.appendSlice(alloc, ",q=2");
    try out.appendSlice(alloc, "\x1b\\");
}

/// Resolve every placement of the terminal's active screen into absolute
/// geometry, z-sorted and with fully covered placements removed. Only
/// placements that intersect the anchor's rows are returned. The slice is
/// owned by the caller.
pub fn collect(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    anchor: Anchor,
) ![]Resolved {
    const storage = &term.screens.active.kitty_images;
    var items: std.ArrayList(Resolved) = .empty;
    errdefer items.deinit(alloc);

    const pages = &term.screens.active.pages;
    const top = switch (anchor) {
        .viewport => pages.getTopLeft(.viewport),
        .active => pages.getTopLeft(.active),
    };
    const top_pt = pages.pointFromPin(.screen, top) orelse return items.toOwnedSlice(alloc);

    var pending_relative: std.ArrayList(PendingRelative) = .empty;
    defer pending_relative.deinit(alloc);

    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        var image = storage.imageById(entry.key_ptr.image_id) orelse continue;
        image.data = image.renderData();
        image.animation = null;
        if (image.data.bytes() == null) continue;

        const placement = entry.value_ptr.*;
        switch (placement.location) {
            .pin => |pin| {
                const pt = pages.pointFromPin(.screen, pin.*) orelse continue;
                try appendPinPlacement(
                    alloc,
                    term,
                    &items,
                    entry.key_ptr.*,
                    &placement,
                    &image,
                    @as(i32, @intCast(pt.screen.y)) - @as(i32, @intCast(top_pt.screen.y)),
                    pt.screen.x,
                );
            },
            .relative => |relative| {
                const chain = storage.resolveChain(relative) orelse continue;
                switch (chain.root.location) {
                    .pin => |pin| {
                        const pt = pages.pointFromPin(.screen, pin.*) orelse continue;
                        try appendPinPlacement(
                            alloc,
                            term,
                            &items,
                            entry.key_ptr.*,
                            &placement,
                            &image,
                            @as(i32, @intCast(pt.screen.y)) -
                                @as(i32, @intCast(top_pt.screen.y)) +
                                chain.vertical_offset,
                            @intCast(@max(
                                0,
                                @as(i64, pt.screen.x) + chain.horizontal_offset,
                            )),
                        );
                    },
                    .virtual => try pending_relative.append(alloc, .{
                        .key = entry.key_ptr.*,
                        .image = image,
                        .placement = placement,
                        .root_key = chain.root_key,
                        .horizontal_offset = chain.horizontal_offset,
                        .vertical_offset = chain.vertical_offset,
                    }),
                    .relative => unreachable,
                }
            },
            .virtual => {},
        }
    }

    try collectVirtual(alloc, term, top, &items, pending_relative.items);

    std.mem.sortUnstable(Resolved, items.items, {}, lessThan);
    items.items.len = cullOccluded(items.items);
    return items.toOwnedSlice(alloc);
}

const PendingRelative = struct {
    key: PlacementKey,
    image: Image,
    placement: Placement,
    root_key: PlacementKey,
    horizontal_offset: i32,
    vertical_offset: i32,
};

fn appendPinPlacement(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    out: *std.ArrayList(Resolved),
    key: PlacementKey,
    placement: *const Placement,
    image: *const Image,
    row: i32,
    col: u32,
) !void {
    const geom = geometry(term, placement, image.*) orelse return;
    if (col >= @as(u32, term.cols)) return;
    if (row >= @as(i32, @intCast(term.rows))) return;
    if (row + @as(i32, @intCast(geom.rows)) <= 0) return;

    try out.append(alloc, .{
        .image_id = key.image_id,
        .placement_id = key.placement_id.id,
        .z = placement.z,
        .row = row,
        .col = col,
        .cols = geom.cols,
        .rows = geom.rows,
        .dest_w = geom.dest_w,
        .dest_h = geom.dest_h,
        .x_offset = placement.x_offset,
        .y_offset = placement.y_offset,
        .source_x = geom.source_x,
        .source_y = geom.source_y,
        .source_width = geom.source_width,
        .source_height = geom.source_height,
        .image = image.*,
    });
}

const Geometry = struct {
    cols: u32,
    rows: u32,
    dest_w: u32,
    dest_h: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};

fn geometry(
    term: *vt.Terminal,
    placement: *const Placement,
    image: Image,
) ?Geometry {
    const grid = placement.gridSize(image, term);
    if (grid.cols == 0 or grid.rows == 0) return null;
    const pixel = placement.pixelSize(image, term);

    const source_x = @min(image.width, placement.source_x);
    const source_y = @min(image.height, placement.source_y);
    const source_width = if (placement.source_width > 0)
        @min(image.width - source_x, placement.source_width)
    else
        image.width - source_x;
    const source_height = if (placement.source_height > 0)
        @min(image.height - source_y, placement.source_height)
    else
        image.height - source_y;
    if (source_width == 0 or source_height == 0) return null;

    return .{
        .cols = grid.cols,
        .rows = grid.rows,
        .dest_w = pixel.width,
        .dest_h = pixel.height,
        .source_x = source_x,
        .source_y = source_y,
        .source_width = source_width,
        .source_height = source_height,
    };
}

/// Scan the anchor's rows for unicode placeholder runs (`U=1`, U+10EEEE)
/// and resolve them to absolute geometry. Runs are always one row tall, and
/// a run's ORIGIN is the top-left of all cells targeting the same
/// placement; relative placements rooted at a virtual placement are
/// positioned from that origin. This is the same scan the render pipeline
/// performs, rebuilt on the public pin/cell APIs.
fn collectVirtual(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    top: vt.Pin,
    out: *std.ArrayList(Resolved),
    pending: []const PendingRelative,
) !void {
    const storage = &term.screens.active.kitty_images;
    const bottom = term.screens.active.pages.getBottomRight(.viewport) orelse return;
    const limit = bottom.down(1) orelse bottom;

    var origins: std.AutoHashMapUnmanaged(PlacementKey, struct { x: u32, y: u32 }) = .empty;
    defer origins.deinit(alloc);

    var it = VirtualPlacementIterator.init(top, limit);
    while (it.next()) |virtual_placement| {
        const target = storage.placeholderTarget(
            virtual_placement.image_id,
            virtual_placement.placement_id,
        ) orelse continue;

        if (pending.len > 0) {
            if (term.screens.active.pages.pointFromPin(.viewport, virtual_placement.pin)) |pt| {
                const gop = try origins.getOrPut(alloc, target.key);
                if (gop.found_existing) {
                    gop.value_ptr.x = @min(gop.value_ptr.x, pt.viewport.x);
                    gop.value_ptr.y = @min(gop.value_ptr.y, pt.viewport.y);
                } else {
                    gop.value_ptr.* = .{ .x = pt.viewport.x, .y = pt.viewport.y };
                }
            }
        }

        var image = storage.imageById(virtual_placement.image_id) orelse continue;
        image.data = image.renderData();
        image.animation = null;
        if (image.data.bytes() == null) continue;

        const render = virtual_placement.renderPlacement(
            &target.placement,
            &image,
            cell_px_w,
            cell_px_h,
        ) catch continue;
        const pt = term.screens.active.pages.pointFromPin(.viewport, render.top_left) orelse continue;
        if (render.dest_width == 0 or render.dest_height == 0) continue;

        const cols = divCeilSum(render.dest_width, render.offset_x, cell_px_w);
        const rows = divCeilSum(render.dest_height, render.offset_y, cell_px_h);
        if (cols == 0 or rows == 0) continue;
        const row: i32 = @intCast(pt.viewport.y);
        if (row >= @as(i32, @intCast(term.rows))) continue;

        try out.append(alloc, .{
            .image_id = virtual_placement.image_id,
            .placement_id = virtual_placement.placement_id,
            .z = -1,
            .row = row,
            .col = pt.viewport.x,
            .cols = cols,
            .rows = rows,
            .dest_w = render.dest_width,
            .dest_h = render.dest_height,
            .x_offset = render.offset_x,
            .y_offset = render.offset_y,
            .source_x = render.source_x,
            .source_y = render.source_y,
            .source_width = render.source_width,
            .source_height = render.source_height,
            .image = image,
        });
    }

    for (pending) |rel| {
        const origin = origins.get(rel.root_key) orelse continue;
        const col = @max(0, @as(i64, origin.x) + rel.horizontal_offset);
        const row = @as(i64, origin.y) + rel.vertical_offset;
        if (row > std.math.maxInt(i32) or row < std.math.minInt(i32)) continue;
        try appendPinPlacement(
            alloc,
            term,
            out,
            rel.key,
            &rel.placement,
            &rel.image,
            @intCast(row),
            @intCast(col),
        );
    }
}

fn divCeilSum(a: u32, b: u32, divisor: u32) u32 {
    const sum = @as(u64, a) + @as(u64, b);
    const n = (sum + divisor - 1) / divisor;
    return std.math.cast(u32, n) orelse std.math.maxInt(u32);
}

/// The unicode-placeholder scan over the anchor's rows. A run is confined
/// to one row; `row.x` advances to the next unprocessed cell so a completed
/// run can resume after a gap.
const VirtualPlacementIterator = struct {
    row_it: vt.PageList.RowIterator,
    row: ?vt.Pin,

    fn init(pin: vt.Pin, limit: ?vt.Pin) VirtualPlacementIterator {
        var row_it = pin.rowIterator(.right_down, limit);
        const row = row_it.next();
        return .{ .row_it = row_it, .row = row };
    }

    fn next(self: *VirtualPlacementIterator) ?vt.kitty.graphics.unicode.Placement {
        while (self.row) |*row| {
            // Only rows flagged as virtual-placeholder rows carry runs.
            if (!row.rowAndCell().row.kitty_virtual_placeholder) {
                self.row = self.row_it.next();
                continue;
            }

            var run: ?vt.kitty.graphics.unicode.IncompletePlacement = null;
            var run_pin: vt.Pin = undefined;

            const cells = row.cells(.right);
            for (cells, row.x..) |*cell, x| {
                row.x = @intCast(x);

                if (cell.codepoint() != vt.kitty.graphics.unicode.placeholder) {
                    if (run) |prev| return completeRun(run_pin, prev);
                    continue;
                }

                const style = row.style(cell);
                const cps: []const u21 = row.grapheme(cell) orelse &.{};
                const curr = vt.kitty.graphics.unicode.IncompletePlacement.init(&style, cps);
                if (run) |*prev| {
                    if (!prev.append(&curr)) return completeRun(run_pin, prev.*);
                } else {
                    run = curr.start();
                    run_pin = row.*;
                }
            }

            self.row = self.row_it.next();
            if (run) |prev| return completeRun(run_pin, prev);
        }

        return null;
    }
};

fn completeRun(
    pin: vt.Pin,
    run: vt.kitty.graphics.unicode.IncompletePlacement,
) vt.kitty.graphics.unicode.Placement {
    return .{
        .pin = pin,
        .image_id = run.imageId(),
        .placement_id = run.placement_id orelse 0,
        .col = run.col orelse 0,
        .row = run.row orelse 0,
        .width = run.width,
        .height = 1,
    };
}

fn lessThan(_: void, lhs: Resolved, rhs: Resolved) bool {
    if (lhs.z != rhs.z) return lhs.z < rhs.z;
    if (lhs.image_id != rhs.image_id) return lhs.image_id < rhs.image_id;
    return lhs.placement_id < rhs.placement_id;
}

/// True when the image's pixels are fully opaque, so a later placement that
/// covers it hides it completely.
fn isOpaque(image: Image) bool {
    return switch (image.format) {
        .rgb, .gray => true,
        .rgba, .gray_alpha, .png => false,
    };
}

fn destRect(r: Resolved) struct { x0: i64, y0: i64, x1: i64, y1: i64 } {
    const x0 = @as(i64, r.col) * cell_px_w + @as(i64, r.x_offset);
    const y0 = @as(i64, r.row) * cell_px_h + @as(i64, r.y_offset);
    return .{
        .x0 = x0,
        .y0 = y0,
        .x1 = x0 + @as(i64, r.dest_w),
        .y1 = y0 + @as(i64, r.dest_h),
    };
}

/// Drop placements that a later-drawn opaque placement fully covers. The
/// slice must be in draw order. Compacts in place and returns the new
/// length.
fn cullOccluded(items: []Resolved) usize {
    if (items.len < 2) return items.len;

    // Video senders retain every prior full-frame placement until the
    // storage quota evicts it. If the final item in draw order is opaque
    // and covers every other item, the sorted result is that item alone;
    // detect it in linear time and skip the quadratic cull.
    if (keepOnlyFinalCover(items)) return 1;

    var kept: usize = 0;
    outer: for (items, 0..) |item, i| {
        const rect = destRect(item);
        for (items[i + 1 ..]) |later| {
            if (!isOpaque(later.image)) continue;
            const cover = destRect(later);
            if (cover.x0 <= rect.x0 and cover.y0 <= rect.y0 and
                cover.x1 >= rect.x1 and cover.y1 >= rect.y1)
            {
                continue :outer;
            }
        }
        items[kept] = item;
        kept += 1;
    }
    return kept;
}

fn keepOnlyFinalCover(items: []Resolved) bool {
    var final_index: usize = 0;
    var final_unique = true;
    for (items[1..], 1..) |item, i| {
        if (lessThan({}, items[final_index], item)) {
            final_index = i;
            final_unique = true;
        } else if (!lessThan({}, item, items[final_index])) {
            // Equal sort keys can occur for separate virtual fragments;
            // their unstable-sort order is undefined, so decline.
            final_unique = false;
        }
    }
    if (!final_unique) return false;

    const final = items[final_index];
    if (!isOpaque(final.image)) return false;

    const cover = destRect(final);
    for (items, 0..) |item, i| {
        if (i == final_index) continue;
        const rect = destRect(item);
        if (cover.x0 > rect.x0 or cover.y0 > rect.y0 or
            cover.x1 < rect.x1 or cover.y1 < rect.y1)
        {
            return false;
        }
    }

    items[0] = final;
    return true;
}

/// Append the cursor move and placement command for one resolved graphic,
/// clipped to the visible rows. `row_offset` is the number of screen rows
/// above row 0 of the anchor (the UI's tab bar). Returns false, writing
/// nothing, when the graphic lies entirely outside the visible rows.
pub fn appendPlacement(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    r: *const Resolved,
    uid: u32,
    term_rows: u16,
    row_offset: u16,
) !bool {
    var src_y = r.source_y;
    var src_h = r.source_height;
    var rows = r.rows;
    var y_offset = r.y_offset;
    var row = r.row;

    if (row < 0) {
        // Clip the rows that scrolled off the top. Trimming the same
        // fraction of the source keeps the remaining pixels at their
        // original scale when the destination rows shrink in step.
        const clip: u32 = @intCast(-row);
        if (clip >= rows) return false;
        const trimmed: u32 = @intCast(
            (@as(u64, src_h) * clip) / rows,
        );
        src_y += trimmed;
        src_h -= trimmed;
        rows -= clip;
        y_offset = 0;
        row = 0;
    }
    if (row >= @as(i32, @intCast(term_rows))) return false;

    try out.print(alloc, "\x1b[{d};{d}H", .{
        @as(u32, @intCast(row)) + @as(u32, row_offset) + 1,
        r.col + 1,
    });
    try out.print(
        alloc,
        "\x1b_Ga=p,i={d},p={d},x={d},y={d},w={d},h={d},c={d},r={d},X={d},Y={d},z={d},C=1,q=2",
        .{
            r.image_id,
            uid,
            r.source_x,
            src_y,
            r.source_width,
            src_h,
            r.cols,
            rows,
            r.x_offset,
            y_offset,
            r.z,
        },
    );
    try out.appendSlice(alloc, "\x1b\\");
    return true;
}

/// Append the commands that transmit an image's pixels (store only, no
/// placement). Returns false, writing nothing, for an image that cannot be
/// re-sent in a directly supported form.
pub fn appendTransmit(
    alloc: std.mem.Allocator,
    image: *const Image,
    out: *std.ArrayList(u8),
) !bool {
    // The protocol only carries raw rgb/rgba directly; PNG was already
    // decoded by libghostty, and the gray formats are expanded so
    // everything goes out in a directly supported form.
    const format = image.format;
    const bpp: usize = switch (format) {
        .rgb => 3,
        .rgba => 4,
        .gray => 1,
        .gray_alpha => 2,
        .png => return false,
    };
    const data = image.data.bytes() orelse return false;
    if (data.len != @as(usize, image.width) * image.height * bpp) return false;

    var expanded: std.ArrayList(u8) = .empty;
    defer expanded.deinit(alloc);
    const payload: []const u8 = switch (format) {
        .rgb, .rgba => data,
        .gray => blk: {
            try expanded.ensureTotalCapacity(alloc, data.len * 3);
            for (data) |g| {
                try expanded.appendSlice(alloc, &.{ g, g, g });
            }
            break :blk expanded.items;
        },
        .gray_alpha => blk: {
            try expanded.ensureTotalCapacity(alloc, data.len * 2);
            var i: usize = 0;
            while (i + 1 < data.len) : (i += 2) {
                const g = data[i];
                try expanded.appendSlice(alloc, &.{ g, g, g, data[i + 1] });
            }
            break :blk expanded.items;
        },
        .png => return false,
    };

    const f: u8 = if (format == .rgba or format == .gray_alpha) 32 else 24;
    // Chunk at a multiple of three raw bytes so every base64 group is
    // self-contained (libghostty decodes each chunk on its own) and
    // each APC stays within the protocol's 4096-byte payload cap.
    const raw_chunk = 3 * 1024;
    var b64: [4096]u8 = undefined;
    var off: usize = 0;
    var first = true;
    while (true) {
        const end = @min(off + raw_chunk, payload.len);
        const more = end < payload.len;
        const encoded = std.base64.standard.Encoder.encode(&b64, payload[off..end]);

        try out.appendSlice(alloc, "\x1b_G");
        if (first) {
            try out.print(
                alloc,
                "a=t,f={d},s={d},v={d},i={d},q=2",
                .{ f, image.width, image.height, image.id },
            );
            try out.appendSlice(alloc, if (more) ",m=1;" else ",m=0;");
            first = false;
        } else {
            try out.appendSlice(alloc, if (more) "m=1;" else "m=0;");
        }
        try out.appendSlice(alloc, encoded);
        try out.appendSlice(alloc, "\x1b\\");

        off = end;
        if (!more) break;
    }
    return true;
}

/// Upper bound on the image bytes one repaint replays. A repaint is
/// queued for the client in one go and the daemon drops a client whose
/// queue passes 8 MiB, so a screen full of large images must not be able
/// to push the view over that line. Images past the budget are skipped
/// (they reappear the next time the application draws them).
pub const max_replay_bytes: usize = 2 * 1024 * 1024;

/// Append commands that recreate every visible image and placement of the
/// terminal's active screen, for a view that has just erased its display.
/// Placements are positioned relative to the live screen. The commands move
/// the cursor, so the caller restores the cursor afterwards.
pub fn appendReplay(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    out: *std.ArrayList(u8),
) !void {
    const items = try collect(alloc, term, .active);
    defer alloc.free(items);
    if (items.len == 0) return;

    var tx: std.ArrayList(u8) = .empty;
    defer tx.deinit(alloc);
    var place: std.ArrayList(u8) = .empty;
    defer place.deinit(alloc);
    var sent: std.ArrayList(u32) = .empty;
    defer sent.deinit(alloc);

    var uid: u32 = 1;
    for (items) |*item| {
        const place_mark = place.items.len;
        if (!try appendPlacement(alloc, &place, item, uid, term.rows, 0)) continue;

        // Send each image's pixels once, however many placements use it.
        var already = false;
        for (sent.items) |id| {
            if (id == item.image_id) already = true;
        }
        if (!already) {
            const tx_mark = tx.items.len;
            const ok = try appendTransmit(alloc, &item.image, &tx);
            if (!ok or tx.items.len > max_replay_bytes) {
                tx.shrinkRetainingCapacity(tx_mark);
                place.shrinkRetainingCapacity(place_mark);
                continue;
            }
            try sent.append(alloc, item.image_id);
        }
        uid += 1;
    }

    try out.appendSlice(alloc, tx.items);
    try out.appendSlice(alloc, place.items);
}

fn testTerminal(alloc: std.mem.Allocator, cols: u16, rows: u16) !vt.Terminal {
    var term = try vt.Terminal.init(std.testing.io, alloc, .{ .cols = cols, .rows = rows });
    term.width_px = @as(u32, cols) * cell_px_w;
    term.height_px = @as(u32, rows) * cell_px_h;
    return term;
}

fn testImage(
    alloc: std.mem.Allocator,
    term: *vt.Terminal,
    id: u32,
    width: u32,
    height: u32,
    format: @FieldType(Image, "format"),
) !void {
    const screen = term.screens.active;
    const bpp: usize = switch (format) {
        .rgb => 3,
        .rgba => 4,
        .gray => 1,
        .gray_alpha => 2,
        .png => unreachable,
    };
    const pixels = try alloc.alloc(u8, width * height * bpp);
    @memset(pixels, 0x40);
    try screen.kitty_images.addImage(std.testing.io, alloc, screen, .{
        .id = id,
        .width = width,
        .height = height,
        .format = format,
        .data = .{ .complete = pixels },
    });
}

fn testPin(term: *vt.Terminal, x: u16, y: u16) !*vt.PageList.Pin {
    return term.screens.active.pages.trackPin(
        term.screens.active.pages.pin(.{ .active = .{ .x = x, .y = y } }).?,
    );
}

test "replay recreates images in a fresh terminal" {
    const alloc = std.testing.allocator;
    var src = try testTerminal(alloc, 20, 6);
    defer src.deinit(alloc);
    var s = src.vtStream();
    defer s.deinit();
    const pixels = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    var b64: [64]u8 = undefined;
    const enc = std.base64.standard.Encoder.encode(&b64, &pixels);
    var seq: std.ArrayList(u8) = .empty;
    defer seq.deinit(alloc);
    try seq.appendSlice(alloc, "\x1b[3;4H");
    try seq.print(alloc, "\x1b_Ga=t,f=32,s=2,v=2,i=7,q=2;{s}\x1b\\", .{enc});
    try seq.appendSlice(alloc, "\x1b_Ga=p,i=7,c=3,r=2,C=1\x1b\\");
    s.nextSlice(seq.items);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try appendReplay(alloc, &src, &out);
    try std.testing.expect(out.items.len > 0);

    var dst = try testTerminal(alloc, 20, 6);
    defer dst.deinit(alloc);
    var ds = dst.vtStream();
    defer ds.deinit();
    ds.nextSlice(out.items);
    const st = &dst.screens.active.kitty_images;
    try std.testing.expect(st.imageById(7) != null);
    try std.testing.expectEqual(@as(usize, 1), st.placements.count());
}

test "collect keeps only the final opaque full-frame placement" {
    const alloc = std.testing.allocator;
    var term = try testTerminal(alloc, 10, 10);
    defer term.deinit(alloc);
    const storage = &term.screens.active.kitty_images;

    var i: u32 = 0;
    while (i < 3) : (i += 1) {
        try testImage(alloc, &term, i + 1, 100, 100, .rgb);
        const pin = try testPin(&term, 0, 0);
        try storage.addPlacement(std.testing.io, alloc, term.screens.active, i + 1, 1, .{
            .location = .{ .pin = pin },
            .columns = 10,
            .rows = 10,
            .z = @intCast(i),
        });
    }

    const items = try collect(alloc, &term, .viewport);
    defer alloc.free(items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(u32, 3), items[0].image_id);
}

test "collect z-sorts overlapping placements" {
    const alloc = std.testing.allocator;
    var term = try testTerminal(alloc, 10, 10);
    defer term.deinit(alloc);
    const storage = &term.screens.active.kitty_images;

    try testImage(alloc, &term, 1, 10, 10, .rgb);
    var pin = try testPin(&term, 0, 0);
    try storage.addPlacement(std.testing.io, alloc, term.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
        .z = 5,
    });

    try testImage(alloc, &term, 2, 10, 10, .rgb);
    pin = try testPin(&term, 2, 0);
    try storage.addPlacement(std.testing.io, alloc, term.screens.active, 2, 1, .{
        .location = .{ .pin = pin },
        .columns = 2,
        .rows = 1,
        .z = 1,
    });

    const items = try collect(alloc, &term, .viewport);
    defer alloc.free(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(u32, 2), items[0].image_id);
    try std.testing.expectEqual(@as(u32, 1), items[1].image_id);
}

test "collect resolves relative placements rooted at a pin" {
    const alloc = std.testing.allocator;
    var term = try testTerminal(alloc, 10, 10);
    defer term.deinit(alloc);
    const storage = &term.screens.active.kitty_images;

    try testImage(alloc, &term, 1, 1, 1, .rgb);
    const pin = try testPin(&term, 2, 1);
    try storage.addPlacement(std.testing.io, alloc, term.screens.active, 1, 1, .{
        .location = .{ .pin = pin },
        .columns = 1,
        .rows = 1,
    });
    try storage.addPlacement(std.testing.io, alloc, term.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 3,
            .vertical_offset = 2,
        } },
        .columns = 1,
        .rows = 1,
        .z = 1,
    });

    const items = try collect(alloc, &term, .viewport);
    defer alloc.free(items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqual(@as(i32, 1), items[0].row);
    try std.testing.expectEqual(@as(u32, 2), items[0].col);
    try std.testing.expectEqual(@as(i32, 3), items[1].row);
    try std.testing.expectEqual(@as(u32, 5), items[1].col);
}

test "collect resolves unicode placeholder placements" {
    const alloc = std.testing.allocator;
    var term = try testTerminal(alloc, 5, 5);
    defer term.deinit(alloc);
    term.modes.set(.grapheme_cluster, true);

    try testImage(alloc, &term, 1, 10, 10, .rgb);
    try term.screens.active.kitty_images.addPlacement(
        std.testing.io,
        alloc,
        term.screens.active,
        1,
        1,
        .{ .location = .virtual },
    );

    try term.setAttribute(.{ .@"256_fg" = 1 });
    try term.setAttribute(.{ .@"256_underline_color" = 1 });
    term.screens.active.cursorAbsolute(0, 0);
    try term.printString("\u{10EEEE}\u{10EEEE}");

    const items = try collect(alloc, &term, .viewport);
    defer alloc.free(items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(i32, 0), items[0].row);
    try std.testing.expectEqual(@as(u32, 0), items[0].col);
    try std.testing.expectEqual(@as(u32, 2), items[0].cols);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);
    try std.testing.expect(try appendPlacement(alloc, &out, &items[0], 1, 5, 1));
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\x1b[2;1H") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "c=2") != null);
}
test "cellSizeFromPixels derives cell metrics" {
    const c = cellSizeFromPixels(100, 40, 1000, 960).?;
    try std.testing.expectEqual(@as(u32, 10), c.w);
    try std.testing.expectEqual(@as(u32, 24), c.h);
    try std.testing.expect(cellSizeFromPixels(100, 40, 0, 0) == null);
    try std.testing.expect(cellSizeFromPixels(0, 40, 1000, 960) == null);
}

test "setCellSize rejects invalid sizes" {
    defer _ = setCellSize(default_cell_px_w, default_cell_px_h);
    try std.testing.expect(!setCellSize(0, 16));
    try std.testing.expect(!setCellSize(8, 100000));
    try std.testing.expect(setCellSize(10, 24));
    try std.testing.expectEqual(@as(u32, 10), cell_px_w);
}
