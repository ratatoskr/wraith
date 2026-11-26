//! Photo mode's scene: one tree of nodes, the one selection, and what the picked node shows. Everything
//! in it, Wraith's own and plugins', is a contribution to the `photo.*` slots. Render thread.

const Scene = @This();

const std = @import("std");
const math = @import("tuft_math");
const ui = @import("wraith_ui");

const slots = @import("../host/slots.zig");

const c = ui.c;
const Entry = slots.Entry;
pub const Target = slots.Target;

/// A node, by what it is and its id among those. Owns its kind, so it outlives whoever named it.
pub const Key = struct {
    kind_buf: [64]u8 = undefined,
    kind_len: u8 = 0,
    id: u64 = 0,

    pub fn of(kind_: []const u8, id: u64) Key {
        var k: Key = .{ .id = id, .kind_len = @intCast(@min(kind_.len, 64)) };
        @memcpy(k.kind_buf[0..k.kind_len], kind_[0..k.kind_len]);
        return k;
    }

    pub fn kind(k: *const Key) []const u8 {
        return k.kind_buf[0..k.kind_len];
    }

    pub fn is(k: *const Key, kind_: []const u8, id: u64) bool {
        return k.id == id and std.mem.eql(u8, k.kind(), kind_);
    }
};

allocator: std.mem.Allocator,
/// Wraith's own contributions, removed with it
own: std.ArrayList(*Entry) = .empty,
selected: ?Key = null,
/// Narrows the rows, bones and shapes down by name
search: [64:0]u8 = @splat(0),
/// Where to point the camera, asked by a part this frame
focus_at: ?math.Vec3 = null,
/// The tree's labels and the like, freed as the next frame's drawn
frame: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator) Scene {
    return .{ .allocator = allocator, .frame = .init(allocator) };
}

pub fn deinit(self: *Scene) void {
    for (self.own.items) |e| e.remove();
    self.own.deinit(self.allocator);
    self.frame.deinit();
}

/// Puts `text` on the clipboard.
pub fn copy(self: *Scene, text: []const u8) void {
    ui.setClipboard(self.frame.allocator().dupeSentinel(u8, text, 0) catch return);
}

/// One of Wraith's own, in one of the `photo.*` slots.
pub fn add(self: *Scene, placement: slots.Placement, draw: slots.Draw) !void {
    try self.own.ensureUnusedCapacity(self.allocator, 1);
    self.own.appendAssumeCapacity(try slots.addOwn(placement, draw));
}

pub fn select(self: *Scene, kind: []const u8, id: u64) void {
    self.selected = .of(kind, id);
}

pub fn deselect(self: *Scene) void {
    self.selected = null;
}

pub fn isSelected(self: *const Scene, kind: []const u8, id: u64) bool {
    const s = &(self.selected orelse return false);
    return s.is(kind, id);
}

/// The selection's id if it's a `kind`.
pub fn selectedOf(self: *const Scene, kind: []const u8) ?u64 {
    const s = &(self.selected orelse return null);
    return if (std.mem.eql(u8, s.kind(), kind)) s.id else null;
}

pub fn searchText(self: *const Scene) []const u8 {
    return std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " \t");
}

/// Whether `name` has the search in it, or there's no search.
pub fn matches(self: *const Scene, name: []const u8) bool {
    const text = self.searchText();
    return text.len == 0 or std.ascii.findIgnoreCase(name, text) != null;
}

/// Points the camera at `point`, once the frame's parts are done.
pub fn focus(self: *Scene, point: math.Vec3) void {
    self.focus_at = point;
}

pub fn takeFocus(self: *Scene) ?math.Vec3 {
    defer self.focus_at = null;
    return self.focus_at;
}

// Drawing

const base_flags = c.ImGuiTreeNodeFlags_SpanAvailWidth | c.ImGuiTreeNodeFlags_AllowOverlap | c.ImGuiTreeNodeFlags_OpenOnArrow | c.ImGuiTreeNodeFlags_OpenOnDoubleClick;
const leaf_flags = c.ImGuiTreeNodeFlags_Leaf | c.ImGuiTreeNodeFlags_NoTreePushOnOpen;

/// A leaf row under a node, like an actor, with the `photo.row` buttons and `photo.menu` items for its
/// kind. True when clicked.
pub fn row(self: *Scene, kind: []const u8, id: u64, icon: []const u8, comptime fmt: []const u8, args: anytype) bool {
    const a = self.frame.allocator();
    const text = std.fmt.allocPrint(a, fmt, args) catch return false;
    const id_part = std.fmt.allocPrint(a, "###{s}.{d}", .{ kind, id }) catch return false;
    const was = self.isSelected(kind, id);
    _ = self.treeRow(.{ .kind = kind, .id = id }, id_part, icon, text, base_flags | leaf_flags);
    return !was and self.isSelected(kind, id);
}

/// A row's tree node, its name cut short to leave room for its buttons, picked by either click, with
/// its right-click menu. True if it's open.
fn treeRow(self: *Scene, target: Target, id_part: []const u8, icon: []const u8, text: []const u8, base: c.ImGuiTreeNodeFlags) bool {
    const a = self.frame.allocator();
    const right = rightEdge();
    const spacing = ui.getStyle().item_spacing[0];
    const start = ui.raw("ImGui_GetCursorPosX")() + ui.raw("ImGui_GetTreeNodeToLabelSpacing")();
    const room = right - start - buttonsWidth(target.kind) - spacing;
    const full = std.fmt.allocPrint(a, "{s}{s}{s}", .{ icon, if (icon.len > 0) "  " else "", text }) catch return false;
    const shown = fit(a, full, room);
    const label = std.fmt.allocPrintSentinel(a, "{s}{s}", .{ shown, id_part }, 0) catch return false;
    var flags = base;
    if (self.isSelected(target.kind, target.id)) flags |= c.ImGuiTreeNodeFlags_Selected;
    const open = ui.raw("ImGui_TreeNodeEx")(label, flags);
    const toggled = ui.raw("ImGui_IsItemToggledOpen")();
    if ((ui.isItemClicked(.left) and !toggled) or ui.isItemClicked(.right)) self.select(target.kind, target.id);
    if (shown.len != full.len) ui.tooltip("{s}", .{text});
    const scope = ui.id(label);
    defer scope.end();
    if (hasMenu(target.kind)) if (ui.contextMenu("##menu")) |m| {
        defer m.end();
        drawMenu(target);
    };
    self.drawRowButtons(target, right);
    return open;
}

/// As much of `text` as fits in `width` pixels, with `...` where it's cut.
fn fit(a: std.mem.Allocator, text: []const u8, width: f32) []const u8 {
    if (ui.calcTextSize(text)[0] <= width) return text;
    var end = text.len;
    while (end > 0) {
        end -= 1;
        // Whole letters only
        while (end > 0 and text[end] & 0xC0 == 0x80) end -= 1;
        const cut = std.fmt.allocPrint(a, "{s}...", .{text[0..end]}) catch return text;
        if (ui.calcTextSize(cut)[0] <= width) return cut;
    }
    return "...";
}

pub fn hasMenu(kind: []const u8) bool {
    var held = slots.take(.photo_menu);
    defer held.end();
    for (held.items()) |e| if (e.showsFor(kind)) return true;
    return false;
}

/// The `photo.menu` items for `target`'s kind, with a line between each contributor's.
pub fn drawMenu(target: Target) void {
    var held = slots.take(.photo_menu);
    defer held.end();
    var any = false;
    for (held.items()) |e| if (e.showsFor(target.kind)) {
        if (any) ui.separator();
        any = true;
        const scope = ui.id(e.label);
        defer scope.end();
        slots.draw(e, target);
    };
}

fn rightEdge() f32 {
    return ui.raw("ImGui_GetCursorPosX")() + ui.getContentRegionAvailPixels()[0];
}

/// A button on a row, flat till it's hovered, and lit while it's on.
pub fn rowIcon(label: [:0]const u8, on: bool, comptime tip: []const u8, args: anytype) bool {
    const lit: ui.StyleColors = if (on) ui.withStyleColor(.button, .button_active) else ui.withColor(.button, @as(u32, 0));
    defer lit.end();
    const flat = ui.styleVars(.{ .frame_padding = .{ 0, 0 } });
    defer flat.end();
    const clicked = ui.buttonSized(label, .{ iconWidth(), ui.getTextLineHeight() });
    ui.tooltip(tip, args);
    return clicked;
}

/// Where a `rowIcon` would go, for one that doesn't apply.
pub fn skipIcon() void {
    ui.dummy(.{ iconWidth(), ui.getTextLineHeight() });
}

fn iconWidth() f32 {
    return ui.getTextLineHeight() + ui.scaled(4);
}

/// How wide `kind`'s row buttons drew last frame.
fn buttonsWidth(kind: []const u8) f32 {
    var held = slots.take(.photo_row);
    defer held.end();
    var width: f32 = 0;
    for (held.items()) |e| if (e.showsFor(kind)) {
        width += e.width + ui.scaled(2);
    };
    return width;
}

/// The `photo.row` contributions for `target`'s kind, ending at `right`. Each's width is last frame's.
fn drawRowButtons(self: *Scene, target: Target, right: f32) void {
    _ = self;
    var held = slots.take(.photo_row);
    defer held.end();
    const taken = held.items();
    const spacing = ui.scaled(2);
    var width: f32 = 0;
    var any = false;
    for (taken) |e| if (e.showsFor(target.kind)) {
        width += e.width + spacing;
        any = true;
    };
    if (!any) return;
    ui.sameLineWith(@max(0, right - width), spacing);
    var first = true;
    for (taken) |e| if (e.showsFor(target.kind)) {
        if (!first) ui.sameLineWith(0, spacing);
        first = false;
        const scope = ui.id(e.label);
        defer scope.end();
        ui.raw("ImGui_BeginGroup")();
        slots.draw(e, target);
        ui.raw("ImGui_EndGroup")();
        e.width = ui.getItemRectMax()[0] - ui.getItemRectMin()[0];
    };
}

/// The toolbar's contributions on one line, a gap between each.
pub fn drawToolbar(self: *Scene) void {
    _ = self;
    _ = drawRow(.photo_toolbar, .{}, false);
}

/// The `photo.tools` contributions for `target`'s kind, along the top of its panel. With `after`, on
/// the line before. True if any drew.
pub fn drawTools(target: Target, after: bool) bool {
    return drawRow(.photo_tools, target, after);
}

/// A slot's contributions for `target` on one line, a gap between each, as tight as the toolbar's.
fn drawRow(slot: slots.Slot, target: Target, after: bool) bool {
    var held = slots.take(slot);
    defer held.end();
    const tight = ui.styleVars(.{ .frame_padding = .{ ui.scaled(4), ui.scaled(2) }, .item_spacing = .{ ui.scaled(2), ui.scaled(4) } });
    defer tight.end();
    var any = after;
    for (held.items()) |e| if (e.showsFor(target.kind)) {
        if (any) ui.sameLineWith(0, ui.scaled(8));
        any = true;
        const scope = ui.id(e.label);
        defer scope.end();
        ui.raw("ImGui_BeginGroup")();
        slots.draw(e, target);
        ui.raw("ImGui_EndGroup")();
    };
    return any;
}

/// Unscaled.
const tree_indent = 10;

/// A `photo.scene` node, with where it sits in the tree.
const Node = struct {
    e: *Entry,
    parent: ?usize = null,
    /// Like "world/actors", worked out once
    path: ?[]const u8 = null,
    resolving: bool = false,
};

/// The search box over every node in one tree.
pub fn drawTree(self: *Scene) void {
    _ = self.frame.reset(.retain_capacity);
    ui.setNextItemWidth(ui.fill);
    _ = ui.inputTextHint("##search", "Search", &self.search);
    // Tighter than ImGui's, so deep rows keep room for their names
    ui.raw("ImGui_PushStyleVar")(c.ImGuiStyleVar_IndentSpacing, ui.scaled(tree_indent));
    defer ui.raw("ImGui_PopStyleVar")();
    var held = slots.take(.photo_scene);
    defer held.end();
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const nodes = arena.allocator().alloc(Node, held.items().len) catch return;
    for (held.items(), nodes) |e, *n| n.* = .{ .e = e };
    for (0..nodes.len) |i| _ = pathOf(nodes, i, arena.allocator());
    for (nodes, 0..) |n, i| if (n.parent == null) self.drawNode(nodes, i);
}

/// Its parent's path and its id. A parent's found by path, or by id among its owner's nodes.
fn pathOf(nodes: []Node, i: usize, a: std.mem.Allocator) []const u8 {
    const n = &nodes[i];
    if (n.path) |p| return p;
    // A loop of parents puts it at the top
    if (n.resolving) return n.e.id;
    n.resolving = true;
    defer n.resolving = false;
    const parent = findParent(nodes, i, a);
    n.parent = parent;
    const p = if (parent) |at| std.fmt.allocPrint(a, "{s}/{s}", .{ pathOf(nodes, at, a), n.e.id }) catch n.e.id else n.e.id;
    n.path = p;
    return p;
}

fn findParent(nodes: []Node, i: usize, a: std.mem.Allocator) ?usize {
    const e = nodes[i].e;
    if (e.parent.len == 0) return null;
    for (nodes, 0..) |o, j| if (j != i and o.e.own == e.own and (e.own or o.e.loaded == e.loaded) and std.mem.eql(u8, o.e.id, e.parent)) return j;
    for (nodes, 0..) |_, j| if (j != i and !nodes[j].resolving and std.mem.eql(u8, pathOf(nodes, j, a), e.parent)) return j;
    // Under nothing it knows, so at the top rather than lost
    return null;
}

fn drawNode(self: *Scene, nodes: []const Node, i: usize) void {
    const e = nodes[i].e;
    const kind = e.nodeKind();
    if (e.focus_wanted.swap(false, .acq_rel)) self.select(kind, e.node);
    var children = e.children != null;
    for (nodes) |o| if (o.parent == i) {
        children = true;
    };
    var flags: c.ImGuiTreeNodeFlags = base_flags;
    if (!children) flags |= leaf_flags;
    if (e.open) flags |= c.ImGuiTreeNodeFlags_DefaultOpen;
    const id_part = e.label[(std.mem.indexOf(u8, e.label, "###") orelse 0)..];
    const open = self.treeRow(.{ .kind = kind, .id = e.node }, id_part, e.icon, e.title, flags);
    if (!children or !open) return;
    defer ui.raw("ImGui_TreePop")();
    if (e.children) |f| f.func(f.ctx, .{ .kind = kind, .id = e.node });
    for (nodes, 0..) |o, j| if (o.parent == i) self.drawNode(nodes, j);
}

/// The picked node's own draw, then each `photo.inspector` contribution for its kind.
pub fn drawInspector(self: *Scene) void {
    const key = &(self.selected orelse {
        ui.textDisabled("Pick something from the list, or click on a bone in the game.", .{});
        return;
    });
    const target: Target = .{ .kind = key.kind(), .id = key.id };
    {
        var held = slots.take(.photo_scene);
        defer held.end();
        for (held.items()) |e| if (e.node == key.id and std.mem.eql(u8, e.nodeKind(), target.kind)) {
            e.drawn = true;
            const scope = ui.id(e.label);
            defer scope.end();
            slots.draw(e, target);
        };
    }
    var held = slots.take(.photo_inspector);
    defer held.end();
    for (held.items()) |e| if (e.showsFor(target.kind)) {
        const scope = ui.id(e.label);
        defer scope.end();
        if (e.presentation == .foldout) {
            if (e.focus_wanted.swap(false, .acq_rel)) ui.setNextItemOpen(true, .always);
            if (!ui.collapsingHeader(e.label, e.open)) continue;
        }
        slots.draw(e, target);
    };
}

test "one selection, by kind and id" {
    var scene: Scene = .init(std.testing.allocator);
    defer scene.deinit();
    try std.testing.expectEqual(null, scene.selectedOf("actor"));
    scene.select("actor", 7);
    try std.testing.expectEqual(7, scene.selectedOf("actor"));
    try std.testing.expect(scene.isSelected("actor", 7));
    try std.testing.expect(!scene.isSelected("camera", 7));
    scene.select("world", 0);
    try std.testing.expectEqual(null, scene.selectedOf("actor"));
}

test "search matches names regardless of case" {
    var scene: Scene = .init(std.testing.allocator);
    defer scene.deinit();
    try std.testing.expect(scene.matches("Rean"));
    @memcpy(scene.search[0..3], "rea");
    try std.testing.expect(scene.matches("Rean"));
    try std.testing.expect(!scene.matches("Alisa"));
}
