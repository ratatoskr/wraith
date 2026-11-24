//! The handles over the game for moving, turning and scaling something, like posing's bone or what's
//! picked in a Scene panel. Whoever makes one calls it from any thread, which only stores what's
//! asked. The render thread draws the one shown last, once a frame, and keeps where it's dragged to
//! for its owner to take. So only one shows at a time, and nobody else has to be on the render
//! thread for it.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const math = @import("tuft_math");
const sync = @import("tuft_sys").sync;

const ui = @import("wraith_ui");

const Mat4 = math.Mat4;

pub const Tool = enum(u8) { move, rotate, scale };

pub const Gizmo = struct {
    // Under `lock`
    /// Asked to show, and when, so the newest shown wins
    shown_at: ?u64 = null,
    placed: ?Mat4 = null,
    tool: Tool = .move,
    world_axes: bool = false,
    /// Dragged there and not taken yet
    moved: ?Mat4 = null,
    removed: bool = false,
    // Written by the render thread, read anywhere
    dragging: Atomic(bool) = .init(false),
    hovered: Atomic(bool) = .init(false),
    // Render thread
    /// Where it's being dragged to. Ours till the drag ends, since its owner catches up later
    matrix: Mat4 = .identity,

    /// In front of the others, from now on. Any thread.
    pub fn show(self: *Gizmo) void {
        lock.lock();
        defer lock.unlock();
        if (self.removed) return;
        shows += 1;
        self.shown_at = shows;
    }

    /// Any thread.
    pub fn hide(self: *Gizmo) void {
        lock.lock();
        defer lock.unlock();
        self.shown_at = null;
        self.placed = null;
    }

    /// Where it is in the world. It stays where it's dragged to while it's dragged. Any thread.
    pub fn place(self: *Gizmo, world: Mat4) void {
        lock.lock();
        defer lock.unlock();
        self.placed = world;
    }

    pub fn setTool(self: *Gizmo, tool: Tool) void {
        lock.lock();
        defer lock.unlock();
        self.tool = tool;
    }

    pub fn setWorldAxes(self: *Gizmo, on: bool) void {
        lock.lock();
        defer lock.unlock();
        self.world_axes = on;
    }

    /// Where it's been dragged to since the last time, or null. Any thread.
    pub fn takeMoved(self: *Gizmo) ?Mat4 {
        lock.lock();
        defer lock.unlock();
        const m = self.moved;
        self.moved = null;
        return m;
    }

    pub fn isDragging(self: *const Gizmo) bool {
        return self.dragging.load(.acquire);
    }

    /// The mouse was on it last frame, so a click there is for it.
    pub fn isHovered(self: *const Gizmo) bool {
        return self.hovered.load(.acquire);
    }

    /// Never drawn again. Waits for a draw under way, so it's fine to free after. Fine to call twice.
    pub fn remove(self: *Gizmo) void {
        lock.lock();
        defer lock.unlock();
        if (self.removed) return;
        self.removed = true;
        if (std.mem.indexOfScalar(*Gizmo, list.items, self)) |at| _ = list.swapRemove(at);
    }
};

/// Guards every gizmo's state and the list. Held while one's drawn, which is quick.
var lock: sync.Mutex = .{};
var list: std.ArrayList(*Gizmo) = .empty;
var shows: u64 = 0;
const gpa = std.heap.page_allocator;

/// Free it with `destroy`, which removes it too.
pub fn create() !*Gizmo {
    const g = try gpa.create(Gizmo);
    g.* = .{};
    lock.lock();
    defer lock.unlock();
    list.append(gpa, g) catch |err| {
        gpa.destroy(g);
        return err;
    };
    return g;
}

pub fn destroy(g: *Gizmo) void {
    g.remove();
    gpa.destroy(g);
}

/// The one to draw: shown last, and placed.
fn front() ?*Gizmo {
    var best: ?*Gizmo = null;
    for (list.items) |g| {
        const at = g.shown_at orelse continue;
        if (g.placed == null) continue;
        if (best == null or at > best.?.shown_at.?) best = g;
    }
    return best;
}

/// Render thread, once a frame after everyone's placed theirs. `view` is the game's camera, or null
/// when it's not known, and `draggable` whether the overlay has the mouse, so clicks go to the game
/// otherwise.
pub fn draw(view: ?struct { view: Mat4, projection: Mat4 }, draggable: bool) void {
    lock.lock();
    defer lock.unlock();
    const shown = front();
    for (list.items) |g| if (g != shown) {
        g.dragging.store(false, .release);
        g.hovered.store(false, .release);
    };
    const g = shown orelse return;
    const v = view orelse {
        g.dragging.store(false, .release);
        g.hovered.store(false, .release);
        return;
    };
    const gizmo = ui.gizmo;
    gizmo.beginFrame();
    // Its own, so a drag never carries over to another
    const id = gizmo.id(g);
    defer id.end();
    const vp = ui.mainViewport();
    gizmo.setDrawList(ui.getBackgroundDrawList());
    gizmo.setRect(vp.pos, vp.size);
    gizmo.setOrthographic(false);
    gizmo.enable(draggable);
    defer gizmo.enable(true);
    if (!g.dragging.load(.acquire)) g.matrix = g.placed.?;
    const operation: gizmo.Operation = switch (g.tool) {
        .move => .translate,
        .rotate => .rotate,
        .scale => .scale,
    };
    _ = gizmo.manipulate(&v.view, &v.projection, operation, if (g.world_axes) .world else .local, &g.matrix, .{});
    const using = gizmo.isUsing();
    g.hovered.store(using or gizmo.isOver(), .release);
    g.dragging.store(using, .release);
    if (using) g.moved = g.matrix;
}

const tests = struct {
    const testing = std.testing;

    test "the one shown last is in front, and hiding it goes back to the one before" {
        const a = try create();
        defer destroy(a);
        const b = try create();
        defer destroy(b);
        try testing.expectEqual(null, front());
        a.show();
        a.place(.identity);
        b.show();
        // Not placed yet, so not drawn
        try testing.expectEqual(a, front());
        b.place(.identity);
        try testing.expectEqual(b, front());
        b.hide();
        try testing.expectEqual(a, front());
        a.show();
        b.show();
        b.place(.identity);
        try testing.expectEqual(b, front());
        b.remove();
        try testing.expectEqual(a, front());
    }

    test "a drag's taken once" {
        const g = try create();
        defer destroy(g);
        g.moved = .identity;
        try testing.expect(g.takeMoved() != null);
        try testing.expectEqual(null, g.takeMoved());
    }
};

test {
    _ = tests;
}
