//! Photo mode's scene: one tree of nodes, what's picked in it, and what the picked node shows. Everything
//! in it, Wraith's own and plugins', is a contribution to the `photo.*` slots. Kinds say what their
//! nodes can do, like move or reset, and the scene offers it the same way for each. Render thread.

const Scene = @This();

const std = @import("std");
const core = @import("wraith_core");
const math = @import("tuft_math");
const ui = @import("wraith_ui");

const slots = @import("../host/slots.zig");
const Keybinds = @import("tuft_input").Keybinds;
const icons = @import("../ui/icons.zig");
const View = @import("View.zig");
pub const History = @import("History.zig");
const transform = @import("transform.zig");

const c = ui.c;
const Entry = slots.Entry;
const Mat4 = math.Mat4;
const Vec3 = math.Vec3;
pub const Target = slots.Target;
pub const Local = transform.Local;

/// A node or part of one, like `Target`, owning its strings so it outlives whoever named it.
pub const Key = struct {
    kind_buf: [64]u8 = undefined,
    kind_len: u8 = 0,
    id: u64 = 0,
    parent: u64 = 0,
    name_buf: [48]u8 = undefined,
    name_len: u8 = 0,

    pub fn of(t: Target) Key {
        var k: Key = .{ .id = t.id, .parent = t.parent, .kind_len = @intCast(@min(t.kind.len, 64)), .name_len = @intCast(@min(t.name.len, 48)) };
        @memcpy(k.kind_buf[0..k.kind_len], t.kind[0..k.kind_len]);
        @memcpy(k.name_buf[0..k.name_len], t.name[0..k.name_len]);
        return k;
    }

    pub fn kind(k: *const Key) []const u8 {
        return k.kind_buf[0..k.kind_len];
    }

    pub fn name(k: *const Key) []const u8 {
        return k.name_buf[0..k.name_len];
    }

    /// Good while the key is.
    pub fn target(k: *const Key) Target {
        return .{ .kind = k.kind(), .id = k.id, .parent = k.parent, .name = k.name() };
    }

    pub fn eql(k: *const Key, t: Target) bool {
        return k.id == t.id and k.parent == t.parent and std.mem.eql(u8, k.kind(), t.kind) and
            std.mem.eql(u8, k.name(), t.name[0..@min(t.name.len, 48)]);
    }
};

/// What a kind's nodes can do. Each is optional, and the scene offers only what's there. Each takes
/// the kind's `ctx` and locks what it needs itself.
pub const Kind = struct {
    name: []const u8,
    ctx: *anyopaque,
    /// Whose panel shows while one's picked: the node of this kind with its `parent` as id, like a bone's actor
    inspect_as: []const u8 = "",
    /// For copying and tooltips, in `buf` or its own
    label: ?*const fn (*anyopaque, Target, []u8) ?[]const u8 = null,
    /// Where it is in the world, for focusing the camera
    position: ?*const fn (*anyopaque, Target) ?Vec3 = null,
    /// Where the gizmo goes, in the world, and taking where it's dragged to
    get_transform: ?*const fn (*anyopaque, Target) ?Mat4 = null,
    set_transform: ?*const fn (*anyopaque, Target, Mat4) void = null,
    /// A drag starting on it, and every drag of its kind ending
    begin_drag: ?*const fn (*anyopaque, Target) void = null,
    end_drag: ?*const fn (*anyopaque) void = null,
    /// Whether the first follows the second, so it isn't moved twice
    is_under: ?*const fn (*anyopaque, Target, Target) bool = null,
    /// Draws its nodes over the game and says where to click on them
    handles: ?*const fn (*anyopaque, *View.Sink) void = null,
    can_reset: ?*const fn (*anyopaque, Target) bool = null,
    reset: ?*const fn (*anyopaque, Target) void = null,
    can_remove: ?*const fn (*anyopaque, Target) bool = null,
    remove: ?*const fn (*anyopaque, Target) void = null,
    /// What the Transform boxes show and set, when it's not where it is in the world, like a bone's change from its animation
    edit: ?*const fn (*anyopaque, Target) ?Local = null,
    set_edit: ?*const fn (*anyopaque, Target, Local) void = null,
    /// Under the Transform boxes, saying what they're in
    edit_note: []const u8 = "",
    /// Which of turning, moving and scaling its boxes and the gizmo offer, like a camera without scale
    parts: Parts = .{},
    /// Whether the gizmo's offered for it, or just the boxes
    gizmo: bool = true,

    pub const Options = struct { inspect_as: []const u8 = "", edit_note: []const u8 = "", parts: Parts = .{}, gizmo: bool = true };

    /// The first tool it offers, `wanted` if it does.
    pub fn toolFor(k: *const Kind, wanted: View.Tool) View.Tool {
        if (k.parts.has(wanted)) return wanted;
        inline for (.{ View.Tool.rotate, View.Tool.move, View.Tool.scale }) |t| if (k.parts.has(t)) return t;
        return wanted;
    }

    /// From `Impl`'s pub functions of the fields' names, each taking `ctx` first. Ones it leaves out it can't do.
    pub fn of(name_: []const u8, ctx: anytype, comptime Impl: type, options: Options) Kind {
        const T = @TypeOf(ctx);
        const S = struct {
            fn me(p: *anyopaque) T {
                return @ptrCast(@alignCast(p));
            }
            fn label(p: *anyopaque, t: Target, buf: []u8) ?[]const u8 {
                return Impl.label(me(p), t, buf);
            }
            fn position(p: *anyopaque, t: Target) ?Vec3 {
                return Impl.position(me(p), t);
            }
            fn get_transform(p: *anyopaque, t: Target) ?Mat4 {
                return Impl.get_transform(me(p), t);
            }
            fn set_transform(p: *anyopaque, t: Target, m: Mat4) void {
                Impl.set_transform(me(p), t, m);
            }
            fn begin_drag(p: *anyopaque, t: Target) void {
                Impl.begin_drag(me(p), t);
            }
            fn end_drag(p: *anyopaque) void {
                Impl.end_drag(me(p));
            }
            fn is_under(p: *anyopaque, a: Target, b: Target) bool {
                return Impl.is_under(me(p), a, b);
            }
            fn handles(p: *anyopaque, sink: *View.Sink) void {
                Impl.handles(me(p), sink);
            }
            fn can_reset(p: *anyopaque, t: Target) bool {
                return Impl.can_reset(me(p), t);
            }
            fn reset(p: *anyopaque, t: Target) void {
                Impl.reset(me(p), t);
            }
            fn can_remove(p: *anyopaque, t: Target) bool {
                return Impl.can_remove(me(p), t);
            }
            fn remove(p: *anyopaque, t: Target) void {
                Impl.remove(me(p), t);
            }
            fn edit(p: *anyopaque, t: Target) ?Local {
                return Impl.edit(me(p), t);
            }
            fn set_edit(p: *anyopaque, t: Target, l: Local) void {
                Impl.set_edit(me(p), t, l);
            }
        };
        var k: Kind = .{ .name = name_, .ctx = @ptrCast(@constCast(ctx)), .inspect_as = options.inspect_as, .edit_note = options.edit_note, .parts = options.parts, .gizmo = options.gizmo };
        const info = @typeInfo(Kind).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            if (comptime @typeInfo(F) == .optional and @hasDecl(Impl, name)) @field(k, name) = @field(S, name);
        }
        return k;
    }

    pub fn canMove(k: *const Kind) bool {
        return k.get_transform != null and k.set_transform != null;
    }

    /// Whether the gizmo's on it when it's picked.
    pub fn hasGizmo(k: *const Kind) bool {
        return k.gizmo and k.canMove();
    }

    /// Whether it has Transform boxes: its own values, or where it is.
    pub fn hasBoxes(k: *const Kind) bool {
        return (k.edit != null and k.set_edit != null) or k.canMove();
    }

    /// What its boxes show: its own value, or where it is.
    pub fn local(k: *const Kind, t: Target) ?Local {
        if (k.edit) |f| return f(k.ctx, t);
        const m = (k.get_transform orelse return null)(k.ctx, t) orelse return null;
        return .of(m);
    }

    pub fn setLocal(k: *const Kind, t: Target, l: Local) void {
        if (k.set_edit) |f| return f(k.ctx, t, l);
        if (k.set_transform) |f| f(k.ctx, t, l.matrix());
    }
};

/// Turning, moving and scaling, which a kind can each leave out.
pub const Parts = struct {
    rotate: bool = true,
    move: bool = true,
    scale: bool = true,

    pub fn has(p: Parts, tool: View.Tool) bool {
        return switch (tool) {
            .rotate => p.rotate,
            .move => p.move,
            .scale => p.scale,
        };
    }
};

/// How several picked things turn and scale with the gizmo: each round its own origin, or all round their middle.
pub const Pivot = enum { each, middle };

allocator: std.mem.Allocator,
/// Wraith's own contributions, removed with it
own: std.ArrayList(*Entry) = .empty,
kinds: std.ArrayList(Kind) = .empty,
/// What's picked, the last being the one whose panel shows and the gizmo's on
picked: std.ArrayList(Key) = .empty,
/// Counts changes to `picked`, so the gizmo comes back in front over others
picked_version: u64 = 0,
/// The handles and gizmo over the game, off for a clear look
handles_shown: bool = true,
tool: View.Tool = .rotate,
/// Along the world's axes, not the active node's
world_axes: bool = false,
pivot: Pivot = .each,
/// Undo and redo over every part's state
history: History,
/// Which keys are down, even ones a binding hides from ImGui, like the free camera's Shift and Ctrl. Null in tests
keybinds: ?*const Keybinds = null,
/// The Rotation boxes' degrees and the turn they gave, kept while it's still the turn so they don't jump
shown_degrees: Vec3 = .zero,
shown_turn: math.Quat = .identity,
/// Narrows the rows, bones and shapes down by name
search: [64:0]u8 = @splat(0),
/// Where to point the camera, asked by a part this frame
focus_at: ?math.Vec3 = null,
/// The tree's labels and the like, freed as the next frame's drawn
frame: std.heap.ArenaAllocator,

pub fn init(allocator: std.mem.Allocator) Scene {
    return .{ .allocator = allocator, .frame = .init(core.heap.named("photo frame", core.heap.main)), .history = .init(allocator) };
}

pub fn deinit(self: *Scene) void {
    for (self.own.items) |e| e.remove();
    self.own.deinit(self.allocator);
    self.kinds.deinit(self.allocator);
    self.picked.deinit(self.allocator);
    self.history.deinit();
    self.frame.deinit();
}

/// A part's state, so undo and redo cover it. For as long as the scene's around.
pub fn addState(self: *Scene, state: History.State) !void {
    try self.history.add(state);
}

/// What `kind.name`'s nodes can do, for as long as the scene's around.
pub fn addKind(self: *Scene, kind: Kind) !void {
    try self.kinds.append(self.allocator, kind);
}

pub fn kindOf(self: *const Scene, name: []const u8) ?*const Kind {
    for (self.kinds.items) |*k| if (std.mem.eql(u8, k.name, name)) return k;
    return null;
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

// What's picked

/// Just the node `kind` `id`.
pub fn select(self: *Scene, kind: []const u8, id: u64) void {
    self.selectTarget(.{ .kind = kind, .id = id });
}

/// Just `t`.
pub fn selectTarget(self: *Scene, t: Target) void {
    self.picked.clearRetainingCapacity();
    self.addPick(t);
}

/// `t` as well, and the active one.
pub fn addPick(self: *Scene, t: Target) void {
    if (self.find(t)) |i| _ = self.picked.orderedRemove(i);
    self.picked.append(self.allocator, .of(t)) catch return;
    self.picked_version +%= 1;
}

/// `t` let go if it's picked, else added.
pub fn toggle(self: *Scene, t: Target) void {
    if (self.find(t)) |i| {
        _ = self.picked.orderedRemove(i);
        self.picked_version +%= 1;
    } else self.addPick(t);
}

/// As a click asks: Ctrl toggles, Shift adds, else just `t`.
pub fn pick(self: *Scene, t: Target) void {
    const m = self.mods();
    if (m.ctrl) self.toggle(t) else if (m.shift) self.addPick(t) else self.selectTarget(t);
}

/// Whether Ctrl and Shift are down. From the keybinds, since a binding that takes one, like the free
/// camera's, hides it from ImGui.
pub fn mods(self: *const Scene) struct { ctrl: bool, shift: bool } {
    const k = self.keybinds orelse {
        const m = ui.mods();
        return .{ .ctrl = m.ctrl, .shift = m.shift };
    };
    return .{ .ctrl = k.isDown(.left_ctrl) or k.isDown(.right_ctrl), .shift = k.isDown(.left_shift) or k.isDown(.right_shift) };
}

pub fn deselect(self: *Scene) void {
    self.picked.clearRetainingCapacity();
    self.picked_version +%= 1;
}

fn find(self: *const Scene, t: Target) ?usize {
    for (self.picked.items, 0..) |*k, i| if (k.eql(t)) return i;
    return null;
}

pub fn isPicked(self: *const Scene, t: Target) bool {
    return self.find(t) != null;
}

pub fn isSelected(self: *const Scene, kind: []const u8, id: u64) bool {
    return self.isPicked(.{ .kind = kind, .id = id });
}

/// The one whose panel shows. Good till the picks change.
pub fn active(self: *const Scene) ?Target {
    if (self.picked.items.len == 0) return null;
    return self.picked.items[self.picked.items.len - 1].target();
}

/// The active one's id if it's a `kind`.
pub fn selectedOf(self: *const Scene, kind: []const u8) ?u64 {
    const t = self.active() orelse return null;
    return if (std.mem.eql(u8, t.kind, kind)) t.id else null;
}

/// The node whose panel shows `t`: its own, or its parent's for a part.
pub fn panelOf(self: *const Scene, t: Target) Target {
    const k = self.kindOf(t.kind) orelse return t;
    if (k.inspect_as.len == 0) return t;
    return .{ .kind = k.inspect_as, .id = t.parent };
}

/// Whether `kind` `id`'s panel is the one showing.
fn isShowing(self: *const Scene, kind: []const u8, id: u64) bool {
    const p = self.panelOf(self.active() orelse return false);
    return p.id == id and std.mem.eql(u8, p.kind, kind);
}

/// `t` and the rest of its kind picked with it, if it's picked, else just `t`. Good this frame.
fn actedOn(self: *Scene, t: Target) []const Target {
    const a = self.frame.allocator();
    if (!self.isPicked(t)) return a.dupe(Target, &.{dupeTarget(a, t) catch return &.{}}) catch &.{};
    var list: std.ArrayList(Target) = .empty;
    // Copied, since acting on one may change what's picked
    for (self.picked.items) |*k| if (std.mem.eql(u8, k.kind(), t.kind)) {
        list.append(a, dupeTarget(a, k.target()) catch break) catch break;
    };
    return list.items;
}

fn dupeTarget(a: std.mem.Allocator, t: Target) !Target {
    return .{ .kind = try a.dupe(u8, t.kind), .id = t.id, .parent = t.parent, .name = try a.dupe(u8, t.name) };
}

/// Whether `t` follows something else picked of its kind, so changing that moves it already.
pub fn followsPicked(self: *const Scene, t: Target) bool {
    const k = self.kindOf(t.kind) orelse return false;
    const under = k.is_under orelse return false;
    for (self.picked.items) |*o| {
        const other = o.target();
        if (o.eql(t) or !std.mem.eql(u8, other.kind, t.kind)) continue;
        if (under(k.ctx, t, other)) return true;
    }
    return false;
}

/// How `t`'s value changed, from `before` to `after`, put on everything else picked of its kind: the
/// same turn in each's own axes and the same scale, and the same move for those nothing picked carries.
/// The Transform boxes and the gizmo both, so they agree.
pub fn changePicked(self: *Scene, t: Target, before: Local, after: Local) void {
    const k = self.kindOf(t.kind) orelse return;
    const change: transform.Change = .between(before, after);
    for (self.actedOn(t)) |other| {
        if (std.mem.eql(u8, other.kind, t.kind) and other.id == t.id and other.parent == t.parent and std.mem.eql(u8, other.name, t.name)) continue;
        var l = k.local(other) orelse continue;
        change.apply(&l, self.followsPicked(other));
        k.setLocal(other, l);
    }
}

/// `t`'s name from its kind, if it has one.
pub fn labelOf(self: *const Scene, t: Target, buf: []u8) ?[]const u8 {
    const k = self.kindOf(t.kind) orelse return null;
    const f = k.label orelse return null;
    return f(k.ctx, t, buf);
}

/// Points the camera at the active one, if its kind knows where it is.
pub fn focusActive(self: *Scene) void {
    const t = self.active() orelse return;
    const k = self.kindOf(t.kind) orelse return;
    const f = k.position orelse return;
    if (f(k.ctx, t)) |p| self.focus(p);
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
    const version = self.picked_version;
    _ = self.treeRow(.{ .kind = kind, .id = id }, id_part, icon, text, base_flags | leaf_flags);
    return version != self.picked_version and self.isSelected(kind, id);
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
    if (self.isPicked(target) or self.isShowing(target.kind, target.id)) flags |= c.ImGuiTreeNodeFlags_Selected;
    const open = ui.raw("ImGui_TreeNodeEx")(label, flags);
    const toggled = ui.raw("ImGui_IsItemToggledOpen")();
    if (ui.isItemClicked(.left) and !toggled) self.pick(target);
    // Right-clicking one already picked keeps the rest, so its menu acts on them all
    if (ui.isItemClicked(.right) and !self.isPicked(target)) self.selectTarget(target);
    if (shown.len != full.len) ui.tooltip("{s}", .{text});
    const scope = ui.id(label);
    defer scope.end();
    if (self.hasMenu(target.kind)) if (ui.contextMenu("##menu")) |m| {
        defer m.end();
        self.drawMenu(target);
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

pub fn hasMenu(self: *const Scene, kind: []const u8) bool {
    if (self.kindOf(kind)) |k| {
        if (k.position != null or k.reset != null or k.label != null or k.remove != null) return true;
    }
    var held = slots.take(.photo_menu);
    defer held.end();
    for (held.items()) |e| if (e.showsFor(kind)) return true;
    return false;
}

/// What its kind can do, then the `photo.menu` items for it, with a line between each contributor's.
pub fn drawMenu(self: *Scene, target: Target) void {
    var any = self.drawKindMenu(target);
    var held = slots.take(.photo_menu);
    defer held.end();
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

/// What `target`'s kind can do, then its `photo.tools` contributions, along the top of its panel. With
/// `after`, on the line before. True if any drew.
pub fn drawTools(self: *Scene, target: Target, after: bool) bool {
    const kind_scope = ui.id(target.kind);
    defer kind_scope.end();
    const id_scope = ui.id(@as(i32, @truncate(@as(i64, @bitCast(target.id ^ target.parent)))));
    defer id_scope.end();
    const any = self.drawKindTools(target, after);
    return drawRow(.photo_tools, target, any);
}

/// The gizmo's tools, focusing and resetting, for kinds that can.
fn drawKindTools(self: *Scene, target: Target, after: bool) bool {
    const k = self.kindOf(target.kind) orelse return after;
    const tight = toolStyle();
    defer tight.end();
    var any = after;
    if (k.hasGizmo()) {
        if (any) ui.sameLineWith(0, ui.scaled(8));
        any = true;
        self.drawGizmoTools(k.parts);
    }
    var buf: [64]u8 = undefined;
    const name = self.labelOf(target, &buf) orelse "it";
    if (k.position) |f| {
        if (any) ui.sameLineWith(0, ui.scaled(8));
        any = true;
        if (toolButton(icons.crosshair ++ "##scene_focus", false, "Orbit the camera round {s}", .{name})) {
            if (f(k.ctx, target)) |p| self.focus(p);
        }
    }
    if (k.reset) |run| {
        if (any) ui.sameLine();
        any = true;
        const targets = self.actedOn(target);
        const can = self.canAny(k, targets, k.can_reset);
        const off = ui.disabled(!can);
        defer off.end();
        const clicked = if (targets.len > 1)
            toolButton(icons.rotate_ccw ++ "##scene_reset", false, "Put the {d} picked back", .{targets.len})
        else
            toolButton(icons.rotate_ccw ++ "##scene_reset", false, "Put {s} back", .{name});
        if (clicked) for (targets) |t| run(k.ctx, t);
    }
    return any;
}

/// Rotate, move or scale, which axes, and how several move.
fn drawGizmoTools(self: *Scene, parts: Parts) void {
    const hidden = ui.disabled(!self.handles_shown);
    defer hidden.end();
    inline for (.{ .{ View.Tool.rotate, icons.rotate_3d, "Rotate" }, .{ View.Tool.move, icons.move_3d, "Move" }, .{ View.Tool.scale, icons.scale_3d, "Scale" } }) |t| if (parts.has(t[0])) {
        if (toolButton(t[1] ++ "##scene_" ++ t[2], self.tool == t[0], t[2] ++ " with the gizmo", .{})) self.tool = t[0];
        ui.sameLine();
    };
    if (toolButton(icons.globe ++ "##scene_world", self.world_axes, "Line the gizmo up with the world, not what's picked", .{})) self.world_axes = !self.world_axes;
    ui.sameLine();
    const middle = self.pivot == .middle;
    if (toolButton(icons.boxes ++ "##scene_pivot", middle, "{s}", .{if (middle) "Everything picked turns and scales round its middle" else "Each picked turns and scales round itself"})) {
        self.pivot = if (middle) .each else .middle;
    }
}

fn canAny(self: *const Scene, k: *const Kind, targets: []const Target, can: ?*const fn (*anyopaque, Target) bool) bool {
    _ = self;
    const f = can orelse return true;
    for (targets) |t| if (f(k.ctx, t)) return true;
    return false;
}

/// Focusing, resetting, copying and removing, for kinds that can. True if any drew.
fn drawKindMenu(self: *Scene, target: Target) bool {
    const k = self.kindOf(target.kind) orelse return false;
    var any = false;
    if (k.position) |f| {
        any = true;
        if (ui.menuItem("Focus the camera here", .{})) if (f(k.ctx, target)) |p| self.focus(p);
    }
    const targets = self.actedOn(target);
    if (k.reset) |run| {
        any = true;
        var buf: [32:0]u8 = undefined;
        const label = if (targets.len > 1) std.fmt.bufPrintSentinel(&buf, "Reset the {d} picked", .{targets.len}, 0) catch "Reset" else "Reset";
        if (ui.menuItem(label, .{ .enabled = self.canAny(k, targets, k.can_reset) })) for (targets) |t| run(k.ctx, t);
    }
    var buf: [64]u8 = undefined;
    if (self.labelOf(target, &buf)) |name| {
        any = true;
        if (ui.menuItem("Copy its name", .{})) self.copy(name);
    }
    if (k.remove) |run| if (self.canAny(k, targets, k.can_remove)) {
        any = true;
        if (ui.menuItem(if (targets.len > 1) "Remove the picked" else "Remove", .{})) for (targets) |t| {
            if (k.can_remove == null or k.can_remove.?(k.ctx, t)) run(k.ctx, t);
        };
    };
    return any;
}

/// An icon button in a tool row, flat till it's hovered, and lit while it's on.
pub fn toolButton(label: [:0]const u8, on: bool, comptime tip: []const u8, args: anytype) bool {
    const lit: ui.StyleColors = if (on) ui.withStyleColor(.button, .button_active) else ui.withColor(.button, @as(u32, 0));
    defer lit.end();
    const clicked = ui.iconButton(label, "");
    ui.tooltip(tip, args);
    return clicked;
}

fn toolStyle() ui.StyleScope {
    return ui.styleVars(.{ .frame_padding = .{ ui.scaled(4), ui.scaled(2) }, .item_spacing = .{ ui.scaled(2), ui.scaled(4) } });
}

/// The toolbar's button that shows or hides the handles and gizmo over the game.
pub fn drawHandlesTool(self: *Scene) void {
    const shown = self.handles_shown;
    if (toolButton(if (shown) icons.eye ++ "##scene_handles" else icons.eye_off ++ "##scene_handles", shown, "{s} the skeletons and gizmo", .{if (shown) "Hide" else "Show"})) self.handles_shown = !shown;
}

/// A slot's contributions for `target` on one line, a gap between each, as tight as the toolbar's.
fn drawRow(slot: slots.Slot, target: Target, after: bool) bool {
    var held = slots.take(slot);
    defer held.end();
    const tight = toolStyle();
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
    // The frame's, emptied above, so the tree doesn't allocate once it's drawn a few times
    const a = self.frame.allocator();
    const nodes = a.alloc(Node, held.items().len) catch return;
    for (held.items(), nodes) |e, *n| n.* = .{ .e = e };
    for (0..nodes.len) |i| _ = pathOf(nodes, i, a);
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
    const picked = self.active() orelse {
        ui.textDisabled("Pick something from the list, or click on a bone in the game.", .{});
        return;
    };
    // Copied, since drawing may change what's picked
    const key: Key = .of(self.panelOf(picked));
    const target = key.target();
    const part: Key = .of(picked);
    // What every kind shares: tools, then the picked part's beside them, then its boxes
    const any = self.drawTools(target, false);
    if (!part.eql(target)) _ = self.drawTools(part.target(), any);
    self.drawTransform(part.target());
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
    for (held.items()) |e| if (e.showsFor(target.kind) and !replaced(held.items(), e, target.kind)) {
        const scope = ui.id(e.label);
        defer scope.end();
        if (e.presentation == .foldout) {
            if (e.focus_wanted.swap(false, .acq_rel)) ui.setNextItemOpen(true, .always);
            if (!ui.collapsingHeader(e.label, e.open)) continue;
        }
        slots.draw(e, target);
    };
}

/// Rotation, position and scale for anything with boxes, the same change going on everything picked of its kind.
fn drawTransform(self: *Scene, t: Target) void {
    const k = self.kindOf(t.kind) orelse return;
    if (!k.hasBoxes()) return;
    var current = k.local(t) orelse return;
    const before = current;
    var others: usize = 0;
    for (self.picked.items) |*p| others += @intFromBool(std.mem.eql(u8, p.kind(), t.kind));
    others -|= 1;
    var buf: [64]u8 = undefined;
    const name = self.labelOf(t, &buf) orelse "Transform";
    ui.separatorText(if (others > 0) ui.format("{s} and {d} more", .{ name, others }) else ui.format("{s}", .{name}));

    // Another's degrees still do if it has the same turn
    if (@abs(self.shown_turn.dot(current.rotation)) < 1 - 1e-6) {
        self.shown_degrees = transform.eulerOf(current.rotation);
        self.shown_turn = current.rotation;
    }
    var changed = false;
    if (k.parts.rotate and ui.drag("Rotation", &self.shown_degrees, 0.25)) {
        current.rotation = transform.euler(self.shown_degrees);
        self.shown_turn = current.rotation;
        changed = true;
    }
    if (k.parts.move) changed = ui.drag("Position", &current.position, 0.002) or changed;
    if (k.parts.scale) changed = ui.drag("Scale", &current.scale, 0.002) or changed;
    ui.textDisabled("{s} Double-click a box to type.", .{if (k.edit_note.len > 0) k.edit_note else "Where it is in the world."});
    if (!changed) return;
    k.setLocal(t, current);
    self.changePicked(t, before, current);
}

/// A stand-in of Wraith's that something else in its slot has taken the place of, by its id.
fn replaced(all: []const *Entry, e: *const Entry, kind: []const u8) bool {
    if (!e.fallback) return false;
    for (all) |o| if (!o.fallback and o.showsFor(kind) and std.mem.eql(u8, o.id, e.id)) return true;
    return false;
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

test "several picked, the last added being active, and toggling lets one go" {
    var scene: Scene = .init(std.testing.allocator);
    defer scene.deinit();
    const head: Target = .{ .kind = "bone", .id = 1, .parent = 7, .name = "head" };
    const hand: Target = .{ .kind = "bone", .id = 2, .parent = 7, .name = "hand" };
    // Another actor's bone of the same name is another thing
    const other_head: Target = .{ .kind = "bone", .id = 1, .parent = 8, .name = "head" };
    scene.selectTarget(head);
    scene.addPick(hand);
    scene.addPick(other_head);
    try std.testing.expectEqual(3, scene.picked.items.len);
    try std.testing.expectEqual(8, scene.active().?.parent);
    // Added again, it's active again, and still once
    scene.addPick(head);
    try std.testing.expectEqual(3, scene.picked.items.len);
    try std.testing.expectEqualStrings("head", scene.active().?.name);
    try std.testing.expectEqual(7, scene.active().?.parent);
    scene.toggle(hand);
    try std.testing.expect(!scene.isPicked(hand));
    try std.testing.expect(scene.isPicked(other_head));
    scene.toggle(hand);
    try std.testing.expect(scene.isPicked(hand));
    scene.selectTarget(hand);
    try std.testing.expectEqual(1, scene.picked.items.len);
}

test "a part's panel is its node's, and the node shows as picked" {
    const Impl = struct {};
    var n: u32 = 0;
    var scene: Scene = .init(std.testing.allocator);
    defer scene.deinit();
    try scene.addKind(.of("bone", &n, Impl, .{ .inspect_as = "actor" }));
    scene.selectTarget(.{ .kind = "bone", .id = 1, .parent = 7, .name = "head" });
    const p = scene.panelOf(scene.active().?);
    try std.testing.expectEqualStrings("actor", p.kind);
    try std.testing.expectEqual(7, p.id);
    try std.testing.expect(scene.isShowing("actor", 7));
    try std.testing.expect(!scene.isSelected("actor", 7));
    // Something of a kind no one's said anything about is its own panel
    scene.select("camera", 3);
    try std.testing.expectEqualStrings("camera", scene.panelOf(scene.active().?).kind);
}

test "a kind without a part offers another tool for the gizmo" {
    const Impl = struct {};
    var n: u32 = 0;
    const camera: Kind = .of("camera", &n, Impl, .{ .parts = .{ .scale = false } });
    try std.testing.expectEqual(View.Tool.move, camera.toolFor(.move));
    try std.testing.expectEqual(View.Tool.rotate, camera.toolFor(.scale));
    const fixed: Kind = .of("fixed", &n, Impl, .{ .parts = .{ .rotate = false, .scale = false } });
    try std.testing.expectEqual(View.Tool.move, fixed.toolFor(.rotate));
}

test "a kind can do what its functions say, and nothing else" {
    const Impl = struct {
        pub fn label(_: *u32, t: Target, _: []u8) ?[]const u8 {
            return t.name;
        }
        pub fn reset(n: *u32, _: Target) void {
            n.* += 1;
        }
    };
    var n: u32 = 0;
    const k: Kind = .of("prop", &n, Impl, .{});
    try std.testing.expect(k.position == null and !k.canMove() and k.remove == null);
    var buf: [8]u8 = undefined;
    try std.testing.expectEqualStrings("lamp", k.label.?(k.ctx, .{ .name = "lamp" }, &buf).?);
    k.reset.?(k.ctx, .{});
    try std.testing.expectEqual(1, n);
}

test "acting on one picked acts on every picked of its kind, and on one not picked alone" {
    var scene: Scene = .init(std.testing.allocator);
    defer scene.deinit();
    scene.selectTarget(.{ .kind = "bone", .id = 1, .parent = 7, .name = "head" });
    scene.addPick(.{ .kind = "bone", .id = 2, .parent = 7, .name = "hand" });
    scene.addPick(.{ .kind = "camera", .id = 3 });
    try std.testing.expectEqual(2, scene.actedOn(.{ .kind = "bone", .id = 2, .parent = 7, .name = "hand" }).len);
    try std.testing.expectEqual(1, scene.actedOn(.{ .kind = "bone", .id = 5, .parent = 7, .name = "foot" }).len);
}

test "a stand-in of Wraith's gives way to another with its id, for the same kind" {
    const Own = struct {
        fn draw(_: *u32, _: Target) void {}
    };
    var n: u32 = 0;
    const stand_in = try slots.addOwn(.{ .slot = .photo_inspector, .id = "look", .kind = "camera", .fallback = true }, .{ .native = .of(&n, Own.draw) });
    defer stand_in.remove();
    const other = try slots.addOwn(.{ .slot = .photo_inspector, .id = "lens", .kind = "camera" }, .{ .native = .of(&n, Own.draw) });
    defer other.remove();
    try std.testing.expect(!replaced(&.{ stand_in, other }, stand_in, "camera"));
    const look = try slots.addOwn(.{ .slot = .photo_inspector, .id = "look", .kind = "camera" }, .{ .native = .of(&n, Own.draw) });
    defer look.remove();
    try std.testing.expect(replaced(&.{ stand_in, other, look }, stand_in, "camera"));
    // Only stand-ins give way
    try std.testing.expect(!replaced(&.{ stand_in, look }, look, "camera"));
}

test "search matches names regardless of case" {
    var scene: Scene = .init(std.testing.allocator);
    defer scene.deinit();
    try std.testing.expect(scene.matches("Rean"));
    @memcpy(scene.search[0..3], "rea");
    try std.testing.expect(scene.matches("Rean"));
    try std.testing.expect(!scene.matches("Alisa"));
}
