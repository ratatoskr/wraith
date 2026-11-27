//! Every type in the project's and plugins' schemas, by plugin and namespace, with its members,
//! users and source, or laid over memory.

const SchemasPanel = @This();

const std = @import("std");

const devtools = @import("tuft_devtools");
const Schema = @import("salamander_schema").Schema;
const sigs = @import("tuft_schema").sigs;
const mem = @import("tuft_mem");
const ui = @import("wraith_ui");
const Clip = ui.Clip;

const Names = @import("../../../Names.zig");
const Workbench = @import("../Workbench.zig");

const red: [4]f32 = .{ 1, 0.4, 0.4, 1 };
const highlight: [4]f32 = .{ 1, 0.85, 0.4, 1 };
/// So `seen` never matches before the first look.
const never = std.math.maxInt(u32);

wb: *Workbench,
allocator: std.mem.Allocator,
/// The Addresses panel's generation of parses that `types` points into.
seen: u32 = never,
types: std.ArrayList(TypeRow) = .empty,
/// Folders that are open, by key. Plugins start open, namespaces closed.
toggled: std.StringHashMapUnmanaged(void) = .empty,
/// What's shown, tree or filtered, with keys in `rows_arena`.
rows: std.ArrayList(Row) = .empty,
rows_arena: std.heap.ArenaAllocator,
rows_stale: bool = true,
search: [128:0]u8 = @splat(0),
picked: ui.Selection = .{},
split: ui.Split = .{ .direction = .down, .ratio = 0.45 },
/// The type the bottom half is about, by id, and what was worked out for it.
members_of: ?u64 = null,
used_by: std.ArrayList(usize) = .empty,
/// Where each line of its file starts, and which lines it's on.
lines: std.ArrayList(u32) = .empty,
type_lines: [2]usize = .{ 0, 0 },
scroll_source: bool = false,
picked_members: ui.Selection = .{},
tab: Tab = .members,
pick_tab: ?Tab = null,
/// Lays the picked struct over memory.
view: devtools.StructView,
/// Goes to the view once a struct's picked.
pending_address: ?usize = null,
problem: ?[]const u8 = null,

const Tab = enum { members, used_by, source, memory };

pub const TypeRow = struct {
    /// Like `Client.Game.ActionManager`.
    name: []const u8,
    /// Like `ActionManager`.
    short: []const u8,
    /// Like `Client.Game`. Empty outside one.
    namespace: []const u8,
    /// Like `ffxiv`, from its file's name.
    plugin: []const u8,
    /// Like `ffxiv/clientstructs/Client.Game.sal`.
    file: []const u8,
    schema: *const Schema,
    /// The bundle positions point into.
    source: []const u8,
    type: *const Schema.Type,
    id: u64,
};

const Row = struct {
    kind: enum { folder, type },
    depth: u8,
    label: []const u8,
    /// Folders' key in `toggled`.
    key: []const u8 = "",
    open: bool = false,
    /// Into `types`.
    type: usize = 0,
    id: u64,
};

pub fn init(wb: *Workbench, allocator: std.mem.Allocator) SchemasPanel {
    return .{
        .wb = wb,
        .allocator = allocator,
        .rows_arena = .init(allocator),
        .view = .{ .allocator = allocator, .symbols = Names.global_symbols, .memory = .local, .claims = .local, .editable = false },
    };
}

pub fn deinit(self: *SchemasPanel) void {
    const gpa = self.allocator;
    self.view.deinit();
    self.types.deinit(gpa);
    var keys = self.toggled.keyIterator();
    while (keys.next()) |k| gpa.free(k.*);
    self.toggled.deinit(gpa);
    self.rows.deinit(gpa);
    self.rows_arena.deinit();
    self.used_by.deinit(gpa);
    self.lines.deinit(gpa);
    self.picked.deinit();
    self.picked_members.deinit();
}

/// Brings it up on the Memory tab, laying whatever struct's picked over `address`.
pub fn viewAt(self: *SchemasPanel, address: usize) void {
    self.pending_address = address;
    self.pick_tab = .memory;
    self.wb.focus(.schemas, null);
}

/// Picks the type named `name`, from any plugin, opening its folders.
pub fn show(self: *SchemasPanel, name: []const u8) bool {
    self.catchUp();
    for (self.types.items) |*t| if (std.mem.eql(u8, t.name, name)) {
        self.reveal(t);
        self.picked.only(t.id);
        return true;
    };
    return false;
}

// Keeping up with the parses

/// Rows point into the Addresses panel's parses, so this reruns as soon as it has new ones.
fn catchUp(self: *SchemasPanel) void {
    const now = self.wb.panels.addresses.plugins_generation;
    if (now == self.seen) return;
    self.seen = now;
    self.collect() catch {
        self.problem = "out of memory";
    };
    self.rows_stale = true;
    self.members_of = null;
    self.view.setSchema(null);
}

fn collect(self: *SchemasPanel) !void {
    const gpa = self.allocator;
    self.types.clearRetainingCapacity();
    // A plugin's bundle has what it depends on too. Each file's listed from the first bundle with it
    var claimed: std.StringHashMapUnmanaged(usize) = .empty;
    defer claimed.deinit(gpa);
    for (self.wb.panels.addresses.shared.items, 0..) |*shared, bundle| {
        const schema = &shared.parsed.schema;
        const source = shared.parsed.source;
        for (schema.types) |*t| {
            if (t.nested or t.at < shared.own_from) continue;
            const file = Schema.fileOf(source, t.at);
            const got = try claimed.getOrPut(gpa, file);
            if (!got.found_existing) got.value_ptr.* = bundle;
            if (got.value_ptr.* != bundle) continue;
            const plugin = if (std.mem.indexOfScalar(u8, file, '/')) |slash| file[0..slash] else if (shared.group.len > 0) shared.group else "project";
            const dot = Schema.namespaceEnd(t.name);
            var h = std.hash.Wyhash.init(0);
            h.update(plugin);
            h.update(&.{0});
            h.update(t.name);
            try self.types.append(gpa, .{
                .name = t.name,
                .short = if (dot) |d| t.name[d + 1 ..] else t.name,
                .namespace = if (dot) |d| t.name[0..d] else "",
                .plugin = plugin,
                .file = file,
                .schema = schema,
                .source = source,
                .type = t,
                .id = h.final(),
            });
        }
    }
    std.mem.sort(TypeRow, self.types.items, {}, struct {
        fn less(_: void, a: TypeRow, b: TypeRow) bool {
            if (!std.mem.eql(u8, a.plugin, b.plugin)) return std.ascii.lessThanIgnoreCase(a.plugin, b.plugin);
            if (!std.mem.eql(u8, a.namespace, b.namespace)) return std.ascii.lessThanIgnoreCase(a.namespace, b.namespace);
            return std.ascii.lessThanIgnoreCase(a.short, b.short);
        }
    }.less);
}

// The tree

fn isOpen(self: *const SchemasPanel, key: []const u8, plugin: bool) bool {
    // Plugins are open unless closed, namespaces and Wraith's own closed unless opened
    const starts_open = plugin and !std.mem.eql(u8, key, "wraith");
    return self.toggled.contains(key) != starts_open;
}

fn setOpen(self: *SchemasPanel, key: []const u8, plugin: bool, open: bool) void {
    if (self.isOpen(key, plugin) == open) return;
    if (self.toggled.fetchRemove(key)) |kv| {
        self.allocator.free(kv.key);
    } else {
        const owned = self.allocator.dupe(u8, key) catch return;
        self.toggled.put(self.allocator, owned, {}) catch self.allocator.free(owned);
    }
    self.rows_stale = true;
}

fn folderKey(a: std.mem.Allocator, plugin: []const u8, namespace: []const u8) []const u8 {
    if (namespace.len == 0) return plugin;
    return std.fmt.allocPrint(a, "{s}/{s}", .{ plugin, namespace }) catch plugin;
}

fn folderId(key: []const u8) u64 {
    return std.hash.Wyhash.hash(1, key);
}

/// Opens the folders it's in.
fn reveal(self: *SchemasPanel, t: *const TypeRow) void {
    self.setOpen(t.plugin, true, true);
    var it = std.mem.splitScalar(u8, t.namespace, '.');
    var end: usize = 0;
    var buf: [512]u8 = undefined;
    while (it.next()) |part| {
        if (part.len == 0) break;
        end += part.len;
        const key = std.fmt.bufPrint(&buf, "{s}/{s}", .{ t.plugin, t.namespace[0..end] }) catch return;
        self.setOpen(key, false, true);
        end += 1;
    }
}

fn rebuildRows(self: *SchemasPanel) void {
    self.rows_stale = false;
    self.rows.clearRetainingCapacity();
    _ = self.rows_arena.reset(.retain_capacity);
    const a = self.rows_arena.allocator();
    const gpa = self.allocator;
    const text = std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " \t");
    if (text.len > 0) {
        for (self.types.items, 0..) |*t, i| {
            if (std.ascii.findIgnoreCase(t.name, text) == null) continue;
            self.rows.append(gpa, .{ .kind = .type, .depth = 0, .label = t.name, .type = i, .id = t.id }) catch return;
        }
        return;
    }
    var plugin: ?[]const u8 = null;
    var plugin_open = false;
    // The last type's namespace, and whether each of its folders is open
    var prev: ?[]const u8 = null;
    var opens: [max_namespaces]bool = @splat(true);
    for (self.types.items, 0..) |*t, i| {
        if (plugin == null or !std.mem.eql(u8, plugin.?, t.plugin)) {
            plugin = t.plugin;
            plugin_open = self.isOpen(t.plugin, true);
            self.rows.append(gpa, .{ .kind = .folder, .depth = 0, .label = t.plugin, .key = t.plugin, .open = plugin_open, .id = folderId(t.plugin) }) catch return;
            prev = null;
        }
        const ns = t.namespace;
        var ends: [max_namespaces]usize = undefined;
        var n: usize = 0;
        if (ns.len > 0) {
            var from: usize = 0;
            while (n < ends.len) {
                const dot = std.mem.indexOfScalarPos(u8, ns, from, '.') orelse ns.len;
                ends[n] = dot;
                n += 1;
                if (dot == ns.len) break;
                from = dot + 1;
            }
        }
        // Folders it shares with the last one are there already
        var common: usize = 0;
        if (prev) |p| while (common < n) : (common += 1) {
            const end = ends[common];
            if (end > p.len or !std.mem.eql(u8, ns[0..end], p[0..end]) or (end < p.len and p[end] != '.')) break;
        };
        for (common..n) |j| {
            const shown = plugin_open and allOpen(opens[0..j]);
            const key = folderKey(a, t.plugin, ns[0..ends[j]]);
            opens[j] = self.isOpen(key, false);
            if (!shown) continue;
            const start = if (j == 0) 0 else ends[j - 1] + 1;
            self.rows.append(gpa, .{ .kind = .folder, .depth = @intCast(j + 1), .label = ns[start..ends[j]], .key = key, .open = opens[j], .id = folderId(key) }) catch return;
        }
        prev = ns;
        if (plugin_open and allOpen(opens[0..n])) {
            self.rows.append(gpa, .{ .kind = .type, .depth = @intCast(n + 1), .label = t.short, .type = i, .id = t.id }) catch return;
        }
    }
}

/// Folders deeper than this hold the rest of the namespace as one.
const max_namespaces = 16;

fn allOpen(opens: []const bool) bool {
    for (opens) |o| if (!o) return false;
    return true;
}

fn rowId(r: *const Row) u64 {
    return r.id;
}

// Drawing

pub fn draw(self: *SchemasPanel) void {
    self.catchUp();
    if (self.rows_stale) self.rebuildRows();

    ui.setNextItemWidth(260);
    if (ui.inputTextHint("##filter", "Filter by name", &self.search)) self.rows_stale = true;
    ui.sameLine();
    ui.textDisabled("{d} types", .{self.types.items.len});
    if (self.problem) |p| {
        ui.sameLine();
        ui.textColored(red, "{s}", .{p});
    }
    const parse_problem = self.wb.panels.addresses.parse_problem.message();
    if (parse_problem.len > 0) ui.textColored(red, "{s}", .{parse_problem});
    if (self.types.items.len == 0) {
        ui.textDisabled("No schemas loaded. The project's schemas and plugins' show here once they're loaded.", .{});
        return;
    }

    if (self.split.first("types")) |part| {
        defer part.end();
        self.drawTypes();
    }
    if (self.split.second("members")) |part| {
        defer part.end();
        self.drawPicked();
    }
}

fn drawTypes(self: *SchemasPanel) void {
    const table = ui.table("types", 3, .{
        .borders = true,
        .row_background = true,
        .resizable = true,
        .sizing = .stretch_prop,
        .scroll_y = true,
    }) orelse return;
    ui.tableColumnWith("Name", .{ .stretch = true, .width = 4 });
    ui.tableColumnWith("Kind", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Size", .{ .stretch = true, .width = 1 });
    ui.tableHeaders();
    const rows = self.rows.items;
    var toggle: ?usize = null;
    var picking = self.picked.begin(rows.len, ui.Selection.Rows(Row, rowId){ .rows = rows }, .{});
    var clipper = ui.clip(rows.len);
    clipper.include(picking.keep());
    while (clipper.next()) |i| {
        const r = &rows[i];
        const scope = ui.id(@as(i32, @truncate(@as(i64, @bitCast(r.id)))));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, "##row");
        ui.sameLine();
        const indent = ui.scaled(14) * @as(f32, @floatFromInt(r.depth));
        if (r.depth > 0) ui.indent(indent);
        switch (r.kind) {
            .folder => {
                if (ui.Outline.arrow(r.open)) toggle = i;
                ui.text("{s}", .{r.label});
            },
            .type => {
                ui.Outline.noArrow();
                ui.text("{s}", .{r.label});
                if (r.depth == 0) {
                    ui.sameLine();
                    ui.textDisabled("{s}", .{self.types.items[r.type].plugin});
                }
            },
        }
        if (r.depth > 0) ui.unindent(indent);
        _ = ui.tableNextColumn();
        if (r.kind == .type) {
            const t = self.types.items[r.type].type;
            ui.textDisabled("{s}", .{kindName(t)});
            _ = ui.tableNextColumn();
            if (t.size != Schema.Type.auto) ui.textDisabled("0x{x}", .{t.size});
        }
    }
    picking.end();
    table.end();
    if (self.picked.activated) if (self.focusedRow()) |i| if (rows[i].kind == .folder) {
        toggle = i;
    };
    if (toggle) |i| {
        const r = self.rows.items[i];
        self.setOpen(r.key, r.depth == 0, !r.open);
    }
    self.typeCommands();
}

fn kindName(t: *const Schema.Type) []const u8 {
    return switch (t.kind) {
        .@"struct" => "struct",
        .@"union" => "union",
        .@"enum" => "enum",
        .bitfield => "bitfield",
        .@"error" => "error",
        .@"opaque" => "opaque",
        .func => "fn",
    };
}

fn focusedRow(self: *const SchemasPanel) ?usize {
    const id = self.picked.focused() orelse return null;
    for (self.rows.items, 0..) |*r, i| if (r.id == id) return i;
    return null;
}

/// The type picked, if one is.
fn pickedType(self: *const SchemasPanel) ?*const TypeRow {
    const id = self.picked.focused() orelse return null;
    for (self.types.items) |*t| if (t.id == id) return t;
    return null;
}

fn isLaidOut(t: *const Schema.Type) bool {
    return t.kind == .@"struct" or t.kind == .@"union";
}

fn typeCommands(self: *SchemasPanel) void {
    const keys = &devtools.keys;
    var menu = ui.commands("schema_types", .{ .activated = self.picked.activated });
    defer menu.end();
    const row: ?Row = if (self.focusedRow()) |i| self.rows.items[i] else null;
    const t = self.pickedType();
    const folder = if (row) |r| r.kind == .folder else false;
    if (menu.item(.{ .label = "Open", .chord = keys.expand, .enabled = folder and !row.?.open, .default = folder })) self.setOpen(row.?.key, row.?.depth == 0, true);
    if (menu.item(.{ .label = "Close", .chord = keys.collapse, .enabled = folder and row.?.open })) self.setOpen(row.?.key, row.?.depth == 0, false);
    if (menu.item(.{ .label = "View at address", .chord = keys.go_to, .enabled = t != null and isLaidOut(t.?.type), .tooltip = "Lays it over memory, on the Memory tab. Type where it is there" })) {
        self.pick_tab = .memory;
        self.view.bar.focus();
    }
    if (menu.item(.{ .label = "Show source", .enabled = t != null, .tooltip = "Its .sal, on the Source tab" })) {
        self.pick_tab = .source;
        self.scroll_source = true;
    }
    if (menu.item(.{ .label = "Used by", .enabled = t != null, .tooltip = "Types with a field, base or static of this type, on the Used by tab" })) self.pick_tab = .used_by;
    menu.separator();
    if (menu.item(.{ .label = "Copy name", .chord = keys.copy, .enabled = t != null, .tooltip = "Its full name, namespace and all" })) {
        var clip: Clip = .{};
        clip.line("{s}", .{t.?.name});
        clip.copy();
    }
    if (menu.item(.{ .label = "Close all", .tooltip = "Every folder but the plugins" })) {
        var it = self.toggled.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.toggled.clearRetainingCapacity();
        self.rows_stale = true;
    }
}

// The picked type

fn drawPicked(self: *SchemasPanel) void {
    const t = self.pickedType() orelse {
        ui.textDisabled("Pick a type to see what's in it.", .{});
        return;
    };
    if (self.members_of != t.id) self.pick(t);
    self.drawHeader(t);

    const bar = ui.tabBar("picked") orelse return;
    defer bar.end();
    const want = self.pick_tab;
    self.pick_tab = null;
    if (ui.tabItem(membersLabel(t.type), .{ .select = want == .members })) |tab| {
        defer tab.end();
        self.tab = .members;
        self.drawMembers(t);
    }
    if (ui.tabItem(ui.format("Used by ({d})###used_by", .{self.used_by.items.len}), .{ .select = want == .used_by })) |tab| {
        defer tab.end();
        self.tab = .used_by;
        self.drawUsedBy();
    }
    if (ui.tabItem("Source", .{ .select = want == .source })) |tab| {
        defer tab.end();
        self.tab = .source;
        self.drawSource(t);
    }
    if (isLaidOut(t.type)) if (ui.tabItem("Memory", .{ .select = want == .memory })) |tab| {
        defer tab.end();
        self.tab = .memory;
        self.drawMemory(t);
    };
}

fn membersLabel(t: *const Schema.Type) [:0]const u8 {
    return switch (t.kind) {
        .@"struct", .@"union" => "Members###members",
        .@"enum", .bitfield, .@"error" => "Values###members",
        .func, .@"opaque" => "About###members",
    };
}

fn pick(self: *SchemasPanel, t: *const TypeRow) void {
    self.members_of = t.id;
    self.picked_members.clear();
    self.findUsers(t);
    self.findLines(t);
    if (isLaidOut(t.type)) {
        if (self.view.schema != t.schema) self.view.setSchema(t.schema);
        _ = self.view.show(t.name);
    }
}

fn drawHeader(self: *SchemasPanel, t: *const TypeRow) void {
    ui.text("{s} {s}", .{ kindName(t.type), t.name });
    ui.sameLine();
    if (t.type.size != Schema.Type.auto) {
        ui.textDisabled("0x{x} bytes", .{t.type.size});
        ui.sameLine();
    }
    switch (t.type.kind) {
        .@"struct" => |s| if (s.base) |base| {
            ui.textDisabled(": ", .{});
            ui.sameLine();
            if (ui.textLink(ui.format("{s}", .{base}))) _ = self.show(base);
            ui.sameLine();
        },
        .func => |sig| {
            ui.textDisabled("{f}", .{sig});
            ui.sameLine();
        },
        else => {},
    }
    ui.textDisabled("{s}:{d}", .{ t.file, self.type_lines[0] + 1 });
}

// Members

const Member = union(enum) {
    field: *const Schema.Field,
    method: *const Schema.Method,
    static: *const Schema.Static,
};

fn drawMembers(self: *SchemasPanel, t: *const TypeRow) void {
    switch (t.type.kind) {
        .@"struct", .@"union" => |s| self.drawStruct(t, s),
        .@"enum" => |e| {
            const table = ui.table("values", 2, .{ .borders = true, .row_background = true, .resizable = true, .scroll_y = true }) orelse return;
            defer table.end();
            ui.tableColumnWith("Name", .{ .stretch = true, .width = 2 });
            ui.tableColumnWith("Value", .{ .stretch = true, .width = 1 });
            ui.tableHeaders();
            for (e.values) |v| {
                ui.tableNextRow();
                _ = ui.tableNextColumn();
                ui.text("{s}", .{v.name});
                _ = ui.tableNextColumn();
                ui.text("{d}", .{v.value});
                if (v.value > 9) {
                    ui.sameLine();
                    ui.textDisabled("0x{x}", .{v.value});
                }
            }
        },
        .bitfield => |b| {
            const table = ui.table("bits", 3, .{ .borders = true, .row_background = true, .resizable = true, .scroll_y = true }) orelse return;
            defer table.end();
            ui.tableColumnWith("Name", .{ .stretch = true, .width = 2 });
            ui.tableColumnWith("Bits", .{ .stretch = true, .width = 1 });
            ui.tableColumnWith("Type", .{ .stretch = true, .width = 1 });
            ui.tableHeaders();
            for (b.members) |m| {
                ui.tableNextRow();
                _ = ui.tableNextColumn();
                ui.text("{s}", .{m.name});
                _ = ui.tableNextColumn();
                if (m.bits == 1) ui.text("{d}", .{m.bit}) else ui.text("{d}..{d}", .{ m.bit, m.bit + m.bits - 1 });
                _ = ui.tableNextColumn();
                switch (m.type) {
                    .uint => ui.textDisabled("uint", .{}),
                    .bool => ui.textDisabled("bool", .{}),
                    .@"enum" => |name| if (ui.textLink(ui.format("{s}", .{name}))) {
                        _ = self.show(name);
                    },
                }
            }
        },
        .@"error" => |e| {
            for (e.errors) |err| ui.text("{s} = {d}", .{ err.name, err.code });
        },
        .func => |sig| ui.text("fn{f}", .{sig}),
        .@"opaque" => ui.textDisabled("Opaque, only ever behind a pointer. Nothing's known about what's in it.", .{}),
    }
}

fn drawStruct(self: *SchemasPanel, t: *const TypeRow, s: Schema.Struct) void {
    const table = ui.table("members", 5, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true }) orelse return;
    ui.tableColumnWith("Offset", .{ .stretch = true, .width = 0.7 });
    ui.tableColumnWith("Name", .{ .stretch = true, .width = 2 });
    ui.tableColumnWith("Type", .{ .stretch = true, .width = 3 });
    ui.tableColumnWith("Where", .{ .stretch = true, .width = 2.5 });
    ui.tableColumnWith("Now", .{ .stretch = true, .width = 1.2 });
    ui.tableHeaders();
    const total = s.fields.len + s.methods.len + s.statics.len;
    var picking = self.picked_members.begin(total, ui.Selection.Indices{}, .{});
    var clipper = ui.clip(total);
    clipper.include(picking.keep());
    var link: ?[]const u8 = null;
    while (clipper.next()) |i| {
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, "##member");
        ui.sameLine();
        switch (memberAt(s, i)) {
            .field => |f| {
                if (f.offset != Schema.Type.auto) ui.text("{X:0>4}", .{f.offset});
                _ = ui.tableNextColumn();
                ui.text("{s}", .{f.name});
                _ = ui.tableNextColumn();
                if (typeLink(t.schema, f.type)) |name| link = name;
                _ = ui.tableNextColumn();
                if (t.schema.sizeOf(f.type)) |size| ui.textDisabled("{d} bytes", .{size});
            },
            .method => |m| {
                ui.textDisabled("fn", .{});
                _ = ui.tableNextColumn();
                ui.text("{s}", .{m.name});
                _ = ui.tableNextColumn();
                ui.text("{s}fn{f}", .{ if (m.static) "static " else "", m.signature });
                _ = ui.tableNextColumn();
                if (m.virtual) |slot| {
                    ui.textDisabled("vtable slot {d}", .{slot});
                } else self.drawWhere(t, m.name, m.annotations);
            },
            .static => |st| {
                ui.textDisabled("static", .{});
                _ = ui.tableNextColumn();
                ui.text("{s}", .{st.name});
                _ = ui.tableNextColumn();
                if (typeLink(t.schema, st.type)) |name| link = name;
                _ = ui.tableNextColumn();
                self.drawWhere(t, st.name, st.annotations);
            },
        }
    }
    picking.end();
    table.end();
    if (link) |name| _ = self.show(name);
    self.memberCommands(t, s);
}

fn memberAt(s: Schema.Struct, i: usize) Member {
    if (i < s.fields.len) return .{ .field = &s.fields[i] };
    if (i < s.fields.len + s.methods.len) return .{ .method = &s.methods[i - s.fields.len] };
    return .{ .static = &s.statics[i - s.fields.len - s.methods.len] };
}

/// A type, with what it names as a link when that's a type here. The name if it was clicked.
fn typeLink(schema: *const Schema, r: Schema.Ref) ?[]const u8 {
    const named = namedIn(r) orelse {
        ui.text("{f}", .{r});
        return null;
    };
    if (schema.findType(named) == null) {
        ui.text("{f}", .{r});
        return null;
    }
    const clicked = ui.textLink(ui.format("{f}", .{r}));
    return if (clicked) named else null;
}

/// The type a ref is of, through pointers, arrays and the like.
fn namedIn(r: Schema.Ref) ?[]const u8 {
    return switch (r) {
        .named => |n| n,
        .pointer, .slice, .optional => |c| namedIn(c.*),
        .array => |a| namedIn(a.child.*),
        .result => |res| namedIn(res.ok.*),
        .prim, .func => null,
    };
}

/// Its `[Sig]`, and where that is if it's been found.
fn drawWhere(self: *SchemasPanel, t: *const TypeRow, member: []const u8, annotations: []const Schema.Annotation) void {
    var steps: [sigs.max_steps]mem.Sig.Step = undefined;
    const sig = (sigs.of(annotations, "wraith", "Sig", &steps) catch {
        ui.textColored(red, "bad [Sig]", .{});
        return;
    }) orelse {
        ui.textDisabled("-", .{});
        return;
    };
    ui.text("{f}", .{sig});
    if (ui.isItemHovered()) ui.tooltip("{f}", .{sig});
    _ = ui.tableNextColumn();
    if (self.peek(t, member)) |at| ui.text("{X}", .{at}) else ui.textDisabled("not found yet", .{});
}

/// Names are like `ffxiv.Client.Game.ActionManager.instance`, or without the plugin for the project's.
fn memberName(t: *const TypeRow, member: []const u8, with_plugin: bool, buf: []u8) []const u8 {
    if (with_plugin) return std.fmt.bufPrint(buf, "{s}.{s}.{s}", .{ t.plugin, t.name, member }) catch "";
    return std.fmt.bufPrint(buf, "{s}.{s}", .{ t.name, member }) catch "";
}

fn peek(_: *SchemasPanel, t: *const TypeRow, member: []const u8) ?usize {
    var buf: [512]u8 = undefined;
    return Names.global.peek(memberName(t, member, true, &buf)) orelse Names.global.peek(memberName(t, member, false, &buf));
}

/// Looks for it, scanning if it has to.
fn locate(self: *SchemasPanel, t: *const TypeRow, member: []const u8) ?usize {
    var buf: [512]u8 = undefined;
    if (Names.global.get(memberName(t, member, true, &buf))) |at| return at else |_| {}
    if (Names.global.get(memberName(t, member, false, &buf))) |at| return at else |_| {}
    self.problem = "it wasn't found. Its Names row says why";
    return null;
}

fn memberCommands(self: *SchemasPanel, t: *const TypeRow, s: Schema.Struct) void {
    const keys = &devtools.keys;
    var menu = ui.commands("schema_members", .{ .activated = self.picked_members.activated });
    defer menu.end();
    const focused: ?Member = if (self.picked_members.focused()) |i| if (i < s.fields.len + s.methods.len + s.statics.len) memberAt(s, @intCast(i)) else null else null;
    const code = if (focused) |m| m == .method and m.method.virtual == null else false;
    const static = if (focused) |m| m == .static else false;
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = code, .default = code, .tooltip = "Finds its [Sig] first if nothing has" })) {
        if (self.locate(t, focused.?.method.name)) |at| self.wb.openCode(at);
    }
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = static, .default = static, .tooltip = "Finds its [Sig] first if nothing has" })) {
        if (self.locate(t, focused.?.static.name)) |at| self.wb.openMemory(at, t.schema.sizeOf(focused.?.static.type) orelse @sizeOf(usize), null);
    }
    if (menu.item(.{ .label = "Copy name", .chord = keys.copy, .enabled = focused != null, .tooltip = "As Type.member" })) {
        var clip: Clip = .{};
        const name = switch (focused.?) {
            inline else => |m| m.name,
        };
        clip.line("{s}.{s}", .{ t.name, name });
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy offset", .chord = keys.copy_address, .enabled = if (focused) |m| m == .field else false })) {
        var clip: Clip = .{};
        clip.line("0x{x}", .{focused.?.field.offset});
        clip.copy();
    }
}

// Used by

/// Types with a field, base or static of `t`'s type.
fn findUsers(self: *SchemasPanel, t: *const TypeRow) void {
    self.used_by.clearRetainingCapacity();
    for (self.types.items, 0..) |*other, i| {
        if (other.id == t.id) continue;
        const s = switch (other.type.kind) {
            .@"struct", .@"union" => |s| s,
            else => continue,
        };
        const uses = blk: {
            if (s.base) |b| if (std.mem.eql(u8, b, t.name)) break :blk true;
            for (s.fields) |f| if (mentions(f.type, t.name)) break :blk true;
            for (s.statics) |st| if (mentions(st.type, t.name)) break :blk true;
            break :blk false;
        };
        if (uses) self.used_by.append(self.allocator, i) catch return;
    }
}

fn mentions(r: Schema.Ref, name: []const u8) bool {
    const n = namedIn(r) orelse return false;
    return std.mem.eql(u8, n, name);
}

fn drawUsedBy(self: *SchemasPanel) void {
    if (self.used_by.items.len == 0) {
        ui.textDisabled("Nothing has a field, base or static of this type.", .{});
        return;
    }
    var go: ?[]const u8 = null;
    var clipper = ui.clip(self.used_by.items.len);
    while (clipper.next()) |i| {
        const other = &self.types.items[self.used_by.items[i]];
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        if (ui.textLink(ui.format("{s}", .{other.name}))) go = other.name;
        ui.sameLine();
        ui.textDisabled("{s}", .{other.plugin});
    }
    if (go) |name| _ = self.show(name);
}

// Source

fn findLines(self: *SchemasPanel, t: *const TypeRow) void {
    self.lines.clearRetainingCapacity();
    self.scroll_source = true;
    const text = Schema.fileText(t.source, t.type.at);
    const base = @intFromPtr(text.ptr) - @intFromPtr(t.source.ptr);
    const at = t.type.at -| base;
    self.lines.append(self.allocator, 0) catch return;
    var first: usize = 0;
    for (text, 0..) |ch, i| if (ch == '\n') {
        if (i < at) first = self.lines.items.len;
        self.lines.append(self.allocator, @intCast(i + 1)) catch return;
    };
    // Back over its annotations and doc comments, then on to where it ends
    var start = first;
    while (start > 0) {
        const line = std.mem.trim(u8, lineOf(text, self.lines.items, start - 1), " \t\r");
        if (!std.mem.startsWith(u8, line, "[") and !std.mem.startsWith(u8, line, "//")) break;
        start -= 1;
    }
    var depth: isize = 0;
    var last = first;
    var opened = false;
    find_end: for (first..self.lines.items.len) |n| {
        for (lineOf(text, self.lines.items, n)) |ch| switch (ch) {
            '{' => {
                depth += 1;
                opened = true;
            },
            '}' => depth -= 1,
            ';' => if (!opened) {
                last = n;
                break :find_end;
            },
            else => {},
        };
        last = n;
        if (opened and depth <= 0) break;
    }
    self.type_lines = .{ start, last };
}

fn lineOf(text: []const u8, lines: []const u32, n: usize) []const u8 {
    const start = lines[n];
    const end = if (n + 1 < lines.len) lines[n + 1] else text.len;
    return std.mem.trimEnd(u8, text[start..end], "\r\n");
}

fn drawSource(self: *SchemasPanel, t: *const TypeRow) void {
    const text = Schema.fileText(t.source, t.type.at);
    const child = ui.child("source", .{ 0, 0 }, .{}) orelse return;
    defer child.end();
    const mono = ui.monospace();
    defer mono.end();
    const lines = self.lines.items;
    var clipper = ui.clip(lines.len);
    if (self.scroll_source) clipper.include(self.type_lines[0]);
    while (clipper.next()) |n| {
        const line = lineOf(text, lines, n);
        const inside = n >= self.type_lines[0] and n <= self.type_lines[1];
        ui.textDisabled("{d: >5} ", .{n + 1});
        ui.sameLine();
        if (inside) ui.textColored(highlight, "{s}", .{line}) else ui.textUnformatted(line);
        if (self.scroll_source and n == self.type_lines[0]) {
            ui.setScrollHereY(0.2);
            self.scroll_source = false;
        }
    }
}

// Memory

fn drawMemory(self: *SchemasPanel, t: *const TypeRow) void {
    if (self.pending_address) |a| {
        self.view.goTo(a);
        self.pending_address = null;
    }
    // The view's own picker could show another, so it's kept on the one picked here
    if (self.view.shownName()) |shown| if (!std.mem.eql(u8, shown, t.name)) {
        _ = self.view.show(t.name);
    };
    self.view.draw();
    var menu = ui.commands("schema_memory", .{ .activated = self.view.activated() });
    defer menu.end();
    self.view.commands(&menu);
    _ = self.view.takeChanges();
    menu.separator();
    const keys = &devtools.keys;
    const selected = self.view.selected();
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = selected != null, .tooltip = "Where it points, for pointers and vtable slots" })) {
        self.wb.openCode(selected.?.target orelse selected.?.address);
    }
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = selected != null })) self.wb.openMemory(selected.?.address, selected.?.size, null);
    if (menu.item(.{ .label = "Add to address list", .chord = keys.add_to_list, .enabled = selected != null })) {
        self.wb.panels.addresses.add(selected.?.address, selected.?.kind, selected.?.size);
    }
    if (menu.item(.{ .label = "Go to address", .tooltip = "Type where the struct is" })) self.view.bar.focus();
}
