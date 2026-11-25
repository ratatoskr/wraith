//! A struct in game memory as controls, built from its schema and read fresh each frame. Names
//! come from the fields, or `[Label("..")]`. `[Range(min, max)]` makes a number a slider,
//! `[ReadOnly]` shows it without letting it change and `[Hidden]` leaves it out. `[Flatten]` on a
//! struct or a pointer to one shows its fields in place, as if it wasn't there. Nested structs,
//! bitfields, arrays and pointers to structs fold open, `T[count]` ones as long as their count says.
//! `[Choices("Type.path.to.list", id, name)]` makes a number one of a list the game has, like its
//! items. Render thread.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("wraith_core");
const ui = @import("wraith_ui");
const Schema = @import("salamander_schema").Schema;
const Ref = @import("tuft_schema").Ref;

const TweakFields = @import("TweakFields.zig");
const StructRows = @import("tuft_devtools").StructRows;
const sigs = @import("tuft_schema").sigs;
const Sig = @import("tuft_mem").Sig;
const Memory = @import("tuft_mem").Memory;
const Names = @import("../Names.zig");

/// Unscaled.
const label_width = 170;
/// Folds this deep stay shut, in case pointers loop.
const max_depth = 8;
/// Shown of a long array.
const max_elements = 64;

/// The fields of the struct `type_name` at `address`. False if the schema doesn't have it.
pub fn draw(schema: *const Schema, type_name: []const u8, address: usize) bool {
    const t = schema.findType(type_name) orelse return false;
    const scope = ui.id(t);
    defer scope.end();
    const table = ui.table("##fields", 2, .{}) orelse return true;
    defer table.end();
    ui.tableColumnWith("Field", .{ .fixed = true, .width = label_width });
    ui.tableColumnWith("Value", .{ .stretch = true, .width = 1 });
    members(schema, t, Ref.of(schema, type_name, address), 0);
    return true;
}

/// Whether a field's name for people has `query` in it, nested ones too, for searching.
pub fn mentions(schema: *const Schema, type_name: []const u8, query: []const u8) bool {
    return mentionsIn(schema, type_name, query, 0);
}

fn mentionsIn(schema: *const Schema, type_name: []const u8, query: []const u8, depth: u8) bool {
    if (depth >= max_depth) return false;
    const t = schema.findType(type_name) orelse return false;
    const st = switch (t.kind) {
        .@"struct", .@"union" => |st| st,
        else => return false,
    };
    for (st.fields) |f| {
        if (has(f.annotations, "Hidden")) continue;
        var buf: [96]u8 = undefined;
        if (std.ascii.findIgnoreCase(labelOf(&buf, f.name, f.annotations), query) != null) return true;
        const inner = switch (f.type) {
            .named => |n| n,
            .pointer, .optional => |to| if (to.* == .named) to.named else continue,
            else => continue,
        };
        if (mentionsIn(schema, inner, query, depth + 1)) return true;
    }
    return false;
}

fn members(schema: *const Schema, t: *const Schema.Type, ref: Ref, depth: u8) void {
    switch (t.kind) {
        .@"struct", .@"union" => |st| {
            // A base's fields come first
            if (schema.baseOf(t)) |b| if (depth < max_depth) members(schema, b, ref, depth + 1);
            for (st.fields) |*f| {
                if (has(f.annotations, "Hidden")) continue;
                const scope = ui.id(f);
                defer scope.end();
                member(schema, t.name, f.name, f.annotations, ref.field(f.name), depth);
            }
        },
        .bitfield => |bf| for (bf.members) |*b| {
            const scope = ui.id(b);
            defer scope.end();
            member(schema, t.name, b.name, &.{}, ref.field(b.name), depth);
        },
        else => {},
    }
}

fn member(schema: *const Schema, owner: []const u8, name: []const u8, notes: []const Schema.Annotation, r: Ref, depth: u8) void {
    var label_buf: [96]u8 = undefined;
    const label = labelOf(&label_buf, name, notes);
    const read_only = has(notes, "ReadOnly");
    const flat = has(notes, "Flatten");
    if (r.bits == null) switch (r.type) {
        .named => |n| if (schema.findType(n)) |t| switch (t.kind) {
            .@"struct", .@"union", .bitfield => return if (flat) inline_(schema, t, r, depth) else fold(schema, label, r, t, depth),
            else => {},
        },
        .array => |a| {
            if (StructRows.isTextUnit(a.child.*)) return textRow(label, r);
            return elements(schema, owner, label, notes, r, a.len, depth);
        },
        .pointer, .optional => {
            const to = r.deref();
            if (to.named()) |t| if (t.kind == .@"struct" or t.kind == .@"union") {
                if (to.address.state == .err) return emptyRow(label, "None");
                return if (flat) inline_(schema, t, to, depth) else fold(schema, label, to, t, depth);
            };
            if (r.type == .pointer and r.type.pointer.* == .prim and StructRows.isTextUnit(r.type.pointer.*)) return textRow(label, r);
        },
        .prim => |p| if (p == .cstring) return textRow(label, r),
        .slice, .result, .func => return,
    };
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.alignTextToFramePadding();
    ui.text("{s}", .{label});
    _ = ui.tableNextColumn();
    value(schema, owner, r, notes, read_only);
}

/// Its fields among its parent's, for `[Flatten]`.
fn inline_(schema: *const Schema, t: *const Schema.Type, r: Ref, depth: u8) void {
    if (depth >= max_depth) return;
    members(schema, t, r, depth + 1);
}

/// A struct or bitfield inside, folded shut to start.
fn fold(schema: *const Schema, label: []const u8, r: Ref, t: *const Schema.Type, depth: u8) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    var buf: [104]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{s}##fold", .{label}, 0) catch return;
    if (depth >= max_depth) {
        ui.textDisabled("{s}", .{label});
        return;
    }
    // Tests see inside everything
    if (builtin.is_test) ui.setNextItemOpen(true, .always);
    const node = ui.treeNode(text) orelse return;
    defer node.end();
    members(schema, t, r, depth + 1);
}

fn elements(schema: *const Schema, owner: []const u8, label: []const u8, notes: []const Schema.Annotation, r: Ref, len: usize, depth: u8) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    var buf: [112]u8 = undefined;
    const text = std.fmt.bufPrintSentinel(&buf, "{s} ({d})##fold", .{ label, len }, 0) catch return;
    if (depth >= max_depth) return ui.textDisabled("{s}", .{label});
    if (builtin.is_test) ui.setNextItemOpen(true, .always);
    const node = ui.treeNode(text) orelse return;
    defer node.end();
    for (0..@min(len, max_elements)) |i| {
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        var name_buf: [24]u8 = undefined;
        // Each element keeps the array's [Range] and [ReadOnly], not its [Label]
        member(schema, owner, std.fmt.bufPrint(&name_buf, "#{d}", .{i + 1}) catch "?", withoutLabel(notes), r.index(i), depth + 1);
    }
    if (len > max_elements) {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.textDisabled("and {d} more", .{len - max_elements});
    }
}

fn textRow(label: []const u8, r: Ref) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.alignTextToFramePadding();
    ui.text("{s}", .{label});
    _ = ui.tableNextColumn();
    var buf: [256]u8 = undefined;
    const text = r.text(&buf) catch return ui.textDisabled("Can't read it", .{});
    ui.alignTextToFramePadding();
    ui.text("{s}", .{text});
}

fn emptyRow(label: []const u8, what: []const u8) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.alignTextToFramePadding();
    ui.text("{s}", .{label});
    _ = ui.tableNextColumn();
    ui.alignTextToFramePadding();
    ui.textDisabled("{s}", .{what});
}

fn value(schema: *const Schema, owner: []const u8, r: Ref, notes: []const Schema.Annotation, read_only: bool) void {
    const v = r.load() catch {
        ui.alignTextToFramePadding();
        return ui.textDisabled("Can't read it", .{});
    };
    const off = ui.disabled(read_only);
    defer off.end();
    ui.setNextItemWidth(ui.fill);
    if (Schema.findAnnotation(notes, "wraith", "Choices")) |a| switch (v) {
        .int, .uint, .@"enum" => {
            const current: i64 = switch (v) {
                .int => |i| i,
                .uint => |u| std.math.lossyCast(i64, u),
                .@"enum" => |e| e.value,
                else => unreachable,
            };
            if (TweakFields.choose("##v", choicesOf(schema, owner, a), @floatFromInt(current), false)) |n| write(r, .{ .int = std.math.lossyCast(i64, n) });
            return;
        },
        else => {},
    };
    const limits = limitsOf(notes);
    switch (v) {
        .bool => |b| {
            var on = b;
            if (ui.checkbox("##v", &on)) write(r, .{ .bool = on });
        },
        .int => |i| if (TweakFields.intInput(i64, "##v", i, limits)) |n| write(r, .{ .int = n }),
        .uint => |u| if (TweakFields.intInput(u64, "##v", u, limits)) |n| write(r, .{ .uint = n }),
        .float => |f| if (TweakFields.floatInput("##v", f, limits)) |n| write(r, .{ .float = n }),
        .@"enum" => |e| if (TweakFields.choose("##v", enumChoices(r), @floatFromInt(e.value), false)) |n| write(r, .{ .int = std.math.lossyCast(i64, n) }),
        .pointer => |p| {
            ui.alignTextToFramePadding();
            ui.textDisabled("0x{X}", .{p});
        },
    }
}

/// A bad value, like one too big for its type, just doesn't go in, and the next frame shows what's there.
fn write(r: Ref, v: Ref.Value) void {
    r.store(v) catch {};
}

/// An enum's names, as choices.
fn enumChoices(r: Ref) []const TweakFields.Choice {
    const t = r.named() orelse return &.{};
    const values = switch (t.kind) {
        .@"enum" => |e| e.values,
        else => return &.{},
    };
    const n = @min(values.len, enum_buf.len);
    for (values[0..n], enum_buf[0..n]) |item, *ch| ch.* = .{ .value = @floatFromInt(item.value), .label = item.name };
    return enum_buf[0..n];
}

var enum_buf: [256]TweakFields.Choice = undefined;

/// Where the game has `type_name` now, through its `[Instance]`. Null till the game makes it.
/// The scan goes through `Names`, which keeps what it found and waits a bit before trying a miss again.
pub fn instanceOf(schema: *const Schema, type_name: []const u8) ?usize {
    const t = schema.findType(type_name) orelse return null;
    const found = schema.staticOf(t, "instance") orelse return null;
    var steps: [sigs.max_steps]Sig.Step = undefined;
    const sig = (sigs.of(found.static.annotations, "wraith", "Sig", &steps) catch return null) orelse return null;
    var buf: [128]u8 = undefined;
    const label = std.fmt.bufPrint(&buf, "{s}.instance", .{t.name}) catch return null;
    const at = Names.global.symbols().scan(sig, label).unwrap() catch return null;
    var ptr: usize = 0;
    Memory.local.read(at, std.mem.asBytes(&ptr)) catch return null;
    return if (ptr == 0) null else ptr;
}

/// A list the game has, read again every so often, since it's slow for big ones.
const Choices = struct {
    key: u64 = 0,
    read_ns: u64 = 0,
    arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
    list: []const TweakFields.Choice = &.{},
};

var lists: [8]Choices = @splat(.{});
var next_list: usize = 0;
const reread_ns = 2 * std.time.ns_per_s;

/// What `[Choices(path)]` lists now, by its items' `id` and `name`, or the fields named after the
/// path. Empty till the game has it.
pub fn choicesOf(schema: *const Schema, owner: []const u8, a: *const Schema.Annotation) []const TweakFields.Choice {
    const path = if (a.args.len > 0 and a.args[0] == .string) a.args[0].string else return &.{};
    const key = std.hash.Wyhash.hash(@intFromPtr(schema) +% std.hash.Wyhash.hash(0, owner), path);
    const now = core.timing.now();
    const l = for (&lists) |*l| {
        if (l.key == key) break l;
    } else blk: {
        const l = &lists[next_list];
        next_list = (next_list + 1) % lists.len;
        l.arena.deinit();
        l.* = .{ .key = key };
        break :blk l;
    };
    if (l.read_ns != 0 and now -| l.read_ns < reread_ns) return l.list;
    l.read_ns = now;
    _ = l.arena.reset(.retain_capacity);
    l.list = readChoices(schema, owner, a, path, l.arena.allocator()) catch &.{};
    return l.list;
}

fn readChoices(schema: *const Schema, owner: []const u8, a: *const Schema.Annotation, written: []const u8, arena: std.mem.Allocator) ![]const TweakFields.Choice {
    const id_field = if (a.args.len > 1) a.args[1].name() orelse return error.BadChoices else "id";
    const name_field = if (a.args.len > 2) a.args[2].name() orelse return error.BadChoices else "name";
    var buf: [512]u8 = undefined;
    const found = @import("../host/schemas.zig").choicesPath(schema.*, &buf, owner, written) orelse return error.BadChoices;
    const path = found.path;
    const dot = found.dot;
    const type_name = path[0..dot];
    const ptr = instanceOf(schema, type_name) orelse return error.NotThere;
    return readList(Ref.of(schema, type_name, ptr), path[dot + 1 ..], id_field, name_field, arena);
}

/// The list at `rest` from `root`, like `items.table.data.items`, as choices.
pub fn readList(root: Ref, rest: []const u8, id_field: []const u8, name_field: []const u8, arena: std.mem.Allocator) ![]const TweakFields.Choice {
    // The struct the list's in, then the list
    const last = std.mem.lastIndexOfScalar(u8, rest, '.');
    var in = root;
    if (last) |l| in = in.path(rest[0..l]);
    if (in.type == .pointer) in = in.deref();
    const list_name = if (last) |l| rest[l + 1 ..] else rest;
    // As long as its count says, for a `T[count]` one
    const list = in.field(list_name);
    const len = switch (list.type) {
        .array => |arr| arr.len,
        else => return error.BadChoices,
    };
    var out: std.ArrayList(TweakFields.Choice) = try .initCapacity(arena, len);
    for (0..len) |i| {
        const item = list.index(i);
        const id: i64 = switch (item.field(id_field).load() catch continue) {
            .int => |n| n,
            .uint => |n| std.math.cast(i64, n) orelse continue,
            .@"enum" => |e| e.value,
            else => continue,
        };
        var buf: [256]u8 = undefined;
        const name = item.field(name_field).text(&buf) catch "";
        out.appendAssumeCapacity(.{ .value = @floatFromInt(id), .label = try arena.dupe(u8, name) });
    }
    return out.items;
}

fn has(notes: []const Schema.Annotation, name: []const u8) bool {
    return Schema.findAnnotation(notes, "wraith", name) != null;
}

/// `[Range(min, max)]`'s.
fn limitsOf(notes: []const Schema.Annotation) TweakFields.Limits {
    const a = Schema.findAnnotation(notes, "wraith", "Range") orelse return .{};
    if (a.args.len != 2) return .{};
    var out: [2]f64 = undefined;
    for (a.args, &out) |arg, *o| o.* = switch (arg) {
        .int => |i| @floatFromInt(i),
        .float => |f| f,
        else => return .{},
    };
    return .{ .min = out[0], .max = out[1] };
}

/// Elements share the array's notes, but not its name.
fn withoutLabel(notes: []const Schema.Annotation) []const Schema.Annotation {
    return if (Schema.findAnnotation(notes, "wraith", "Label") != null) &.{} else notes;
}

/// `[Label]`'s, else the name for people, so `gourmet_points` and `gourmetPoints` are both
/// "Gourmet points".
pub fn labelOf(buf: []u8, name: []const u8, notes: []const Schema.Annotation) []const u8 {
    if (Schema.findAnnotation(notes, "wraith", "Label")) |a| if (a.args.len == 1 and a.args[0] == .string) return a.args[0].string;
    return ui.humanName(buf, name);
}
