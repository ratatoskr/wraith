//! The game's C# classes, from Mono or IL2CPP, with their fields and methods. `Class:Method` works
//! anywhere an address does.

const Classes = @This();

const std = @import("std");

const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Managed = @import("../../../Managed.zig");
const Navigator = @import("../Navigator.zig");
const Clip = @import("wraith_ui").Clip;

const Runtime = Managed.Runtime;
const Allocator = std.mem.Allocator;

window: ui.Window = .{ .title = "Classes", .size = .{ 900, 520 }, .min_size = .{ 520, 260 } },
nav: Navigator,
allocator: Allocator,
/// Holds `all`, as of the last look.
arena: ?std.heap.ArenaAllocator = null,
all: []const Entry = &.{},
images: usize = 0,
/// What the filter lets through.
shown: std.ArrayList(*const Entry) = .empty,
search: [128:0]u8 = @splat(0),
picked: ui.Selection = .{},
split: ui.Split = .{ .direction = .down, .ratio = 0.5 },
/// Holds the members of `members_of`.
members_arena: ?std.heap.ArenaAllocator = null,
members_of: ?*Managed.Class = null,
fields: []const FieldRow = &.{},
methods: []const MethodRow = &.{},
picked_fields: ui.Selection = .{},
picked_methods: ui.Selection = .{},
/// Why the last thing it tried didn't work.
problem: ?[]const u8 = null,

const Entry = struct {
    /// Like `Game.Player/Stats`
    name: []const u8,
    image: []const u8,
    class: *Managed.Class,
};

const FieldRow = struct {
    name: []const u8,
    type: []const u8,
    offset: usize,
    is_static: bool,
    literal: bool,
    field: *Managed.Field,
};

const MethodRow = struct {
    name: []const u8,
    /// Like `(System.String, System.Int32) System.Void`
    signature: []const u8,
    is_static: bool,
    method: *Managed.Method,
};

pub fn deinit(self: *Classes) void {
    self.picked.deinit();
    self.picked_fields.deinit();
    self.picked_methods.deinit();
    self.shown.deinit(self.allocator);
    if (self.arena) |*a| a.deinit();
    if (self.members_arena) |*a| a.deinit();
}

pub fn draw(self: *Classes) void {
    if (!Managed.global.running()) {
        ui.textDisabled("No C# here yet. Unity games and others that run C# show their classes once the game's started its runtime.", .{});
        return;
    }
    if (self.arena == null) self.refresh();

    ui.setNextItemWidth(260);
    if (ui.inputTextHint("##filter", "Filter by name", &self.search)) self.refilter();
    ui.sameLine();
    ui.textDisabled("{s}, {d} of {d} classes in {d} images", .{ Managed.label(Managed.global.kind().?), self.shown.items.len, self.all.len, self.images });
    if (self.problem) |p| {
        ui.sameLine();
        ui.textColored(.{ 1, 0.4, 0.4, 1 }, "{s}", .{p});
    }

    if (self.split.first("classes")) |part| {
        defer part.end();
        self.drawClasses();
    }
    if (self.split.second("members")) |part| {
        defer part.end();
        self.drawMembers();
    }
}

/// Looks at every loaded image again.
pub fn refresh(self: *Classes) void {
    if (self.arena) |*a| a.deinit();
    self.arena = .init(self.allocator);
    self.all = &.{};
    self.images = 0;
    self.shown.clearRetainingCapacity();
    self.clearMembers();
    const result = Managed.global.call(snapshot, .{self.arena.?.allocator()}) catch return self.fail("the game's C# runtime stopped");
    const got = result catch return self.fail("out of memory");
    self.all = got.entries;
    self.images = got.images;
    self.problem = null;
    self.refilter();
}

fn fail(self: *Classes, why: []const u8) void {
    self.problem = why;
}

const Snapshot = struct { entries: []const Entry, images: usize };

fn snapshot(rt: *const Runtime, a: Allocator) Allocator.Error!Snapshot {
    const gpa = std.heap.smp_allocator;
    const list = try rt.assemblies(gpa);
    defer gpa.free(list);
    var out: std.ArrayList(Entry) = .empty;
    var images: usize = 0;
    for (list) |assembly| {
        const image = rt.assemblyImage(assembly) orelse continue;
        images += 1;
        const image_name = try a.dupe(u8, rt.imageName(image));
        const n = rt.classCount(image);
        try out.ensureUnusedCapacity(a, n);
        for (0..n) |i| {
            const c = rt.classAt(image, i) orelse continue;
            const name = try Managed.fullName(rt, a, c);
            // Every image has one of these, and it's never anything
            if (std.mem.eql(u8, name, "<Module>")) continue;
            out.appendAssumeCapacity(.{ .name = name, .image = image_name, .class = c });
        }
    }
    std.mem.sort(Entry, out.items, {}, struct {
        fn less(_: void, x: Entry, y: Entry) bool {
            return std.ascii.lessThanIgnoreCase(x.name, y.name);
        }
    }.less);
    return .{ .entries = out.items, .images = images };
}

fn refilter(self: *Classes) void {
    self.shown.clearRetainingCapacity();
    const text = std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " \t");
    for (self.all) |*e| {
        if (text.len > 0 and std.ascii.findIgnoreCase(e.name, text) == null) continue;
        self.shown.append(self.allocator, e) catch return;
    }
}

/// Filters to `name` and picks it, if it's there.
pub fn show(self: *Classes, name: []const u8) void {
    if (!Managed.global.running()) return;
    if (self.arena == null) self.refresh();
    const n = @min(name.len, self.search.len);
    @memset(&self.search, 0);
    @memcpy(self.search[0..n], name[0..n]);
    self.refilter();
    for (self.shown.items) |e| if (std.mem.eql(u8, e.name, name)) {
        self.picked.only(entryId(e));
        return;
    };
}

fn drawClasses(self: *Classes) void {
    const table = ui.table("classes", 2, .{
        .borders = true,
        .row_background = true,
        .resizable = true,
        .sizing = .stretch_prop,
        .scroll_y = true,
    }) orelse return;
    ui.tableColumnWith("Class", .{ .stretch = true, .width = 3 });
    ui.tableColumnWith("Image", .{ .stretch = true, .width = 1 });
    ui.tableHeaders();
    const rows = self.shown.items;
    var picking = self.picked.begin(rows.len, ui.Selection.Rows(*const Entry, shownId){ .rows = rows }, .{});
    var clipper = ui.clip(rows.len);
    clipper.include(picking.keep());
    while (clipper.next()) |i| {
        const e = rows[i];
        const scope = ui.id(@as(i32, @truncate(@as(i64, @bitCast(entryId(e))))));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}", .{e.name}));
        _ = ui.tableNextColumn();
        ui.textDisabled("{s}", .{e.image});
    }
    picking.end();
    table.end();
    self.classCommands();
}

fn classCommands(self: *Classes) void {
    const keys = &devtools.keys;
    var menu = ui.commands("classes", .{ .activated = self.picked.activated });
    defer menu.end();
    const any = self.picked.count() > 0;
    if (menu.item(.{ .label = "Copy", .chord = keys.copy, .enabled = any, .tooltip = "Each class's full name, one a line" })) {
        var clip: Clip = .{};
        for (self.shown.items) |e| if (self.picked.contains(entryId(e))) clip.line("{s}", .{e.name});
        clip.copy();
    }
    menu.separator();
    if (menu.item(.{ .label = "Refresh", .tooltip = "Looks at every loaded image again, for ones loaded since" })) self.refresh();
}

fn entryId(e: *const Entry) u64 {
    return @intFromPtr(e.class);
}

fn shownId(e: *const *const Entry) u64 {
    return entryId(e.*);
}

fn focusedEntry(self: *const Classes) ?*const Entry {
    const id = self.picked.focused() orelse return null;
    for (self.shown.items) |e| if (entryId(e) == id) return e;
    return null;
}

fn clearMembers(self: *Classes) void {
    if (self.members_arena) |*a| a.deinit();
    self.members_arena = null;
    self.members_of = null;
    self.fields = &.{};
    self.methods = &.{};
    self.picked_fields.clear();
    self.picked_methods.clear();
}

const Members = struct { fields: []const FieldRow, methods: []const MethodRow };

fn loadMembers(rt: *const Runtime, a: Allocator, class: *Managed.Class) Allocator.Error!Members {
    var fields: std.ArrayList(FieldRow) = .empty;
    var it = rt.fields(class);
    while (it.next()) |f| {
        try fields.append(a, .{
            .name = rt.fieldName(f),
            .type = if (rt.fieldType(f)) |t| try rt.typeName(a, t) else "",
            .offset = rt.fieldOffset(f),
            .is_static = rt.isStatic(f),
            .literal = rt.isLiteral(f),
            .field = f,
        });
    }
    var methods: std.ArrayList(MethodRow) = .empty;
    var ms = rt.methods(class);
    while (ms.next()) |m| {
        var sig: std.ArrayList(u8) = .empty;
        try sig.append(a, '(');
        for (0..rt.paramCount(m)) |i| {
            if (i > 0) try sig.appendSlice(a, ", ");
            if (rt.paramType(m, @intCast(i))) |t| try sig.appendSlice(a, try rt.typeName(a, t));
        }
        try sig.appendSlice(a, ") ");
        if (rt.returnType(m)) |t| try sig.appendSlice(a, try rt.typeName(a, t));
        try methods.append(a, .{ .name = rt.methodName(m), .signature = sig.items, .is_static = rt.isStaticMethod(m), .method = m });
    }
    return .{ .fields = fields.items, .methods = methods.items };
}

fn drawMembers(self: *Classes) void {
    const entry = self.focusedEntry() orelse {
        ui.textDisabled("Pick a class to see its fields and methods.", .{});
        return;
    };
    if (self.members_of != entry.class) {
        self.clearMembers();
        self.members_arena = .init(self.allocator);
        const result = Managed.global.call(loadMembers, .{ self.members_arena.?.allocator(), entry.class }) catch return self.fail("the game's C# runtime stopped");
        const got = result catch return self.fail("out of memory");
        self.members_of = entry.class;
        self.fields = got.fields;
        self.methods = got.methods;
    }
    const bar = ui.tabBar("members") orelse return;
    defer bar.end();
    if (ui.tabItem(ui.format("Fields ({d})###fields", .{self.fields.len}), .{})) |tab| {
        defer tab.end();
        self.drawFields(entry);
    }
    if (ui.tabItem(ui.format("Methods ({d})###methods", .{self.methods.len}), .{})) |tab| {
        defer tab.end();
        self.drawMethods(entry);
    }
}

fn drawFields(self: *Classes, entry: *const Entry) void {
    const table = ui.table("fields", 4, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true }) orelse return;
    ui.tableColumnWith("Name", .{ .stretch = true, .width = 2 });
    ui.tableColumnWith("Type", .{ .stretch = true, .width = 3 });
    ui.tableColumnWith("Offset", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Kind", .{ .stretch = true, .width = 1 });
    ui.tableHeaders();
    const rows = self.fields;
    var picking = self.picked_fields.begin(rows.len, ui.Selection.Rows(FieldRow, fieldId){ .rows = rows }, .{});
    for (rows, 0..) |*f, i| {
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}", .{f.name}));
        _ = ui.tableNextColumn();
        ui.text("{s}", .{f.type});
        _ = ui.tableNextColumn();
        if (f.literal) ui.textDisabled("-", .{}) else ui.text("0x{x}", .{f.offset});
        _ = ui.tableNextColumn();
        if (f.literal) ui.textDisabled("const", .{}) else if (f.is_static) ui.textDisabled("static", .{});
    }
    picking.end();
    table.end();
    self.fieldCommands(entry);
}

fn fieldCommands(self: *Classes, entry: *const Entry) void {
    const keys = &devtools.keys;
    var menu = ui.commands("fields", .{ .activated = self.picked_fields.activated });
    defer menu.end();
    const one = self.focusedField();
    const any = self.picked_fields.count() > 0;
    const static_one = if (one) |f| f.is_static and !f.literal else false;
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = static_one, .default = true, .tooltip = "Where the static field is now" })) {
        const f = one.?;
        if (self.staticAddress(f.field)) |at| self.nav.openMemory(at, @sizeOf(usize), null) else |err| self.fail(switch (err) {
            error.ThreadStatic => "each thread has its own, so there's no one address",
            error.Unsupported => "this runtime doesn't say where statics are",
            error.NotStatic, error.NotRunning => "the game's C# runtime stopped",
        });
    }
    menu.separator();
    if (menu.item(.{ .label = "Copy", .chord = keys.copy, .enabled = any, .tooltip = "Name, type and offset, one field a line" })) {
        var clip: Clip = .{};
        for (self.fields) |*f| if (self.picked_fields.contains(fieldId(f))) clip.line("{s}\t{s}\t0x{x}", .{ f.name, f.type, f.offset });
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy offset", .chord = keys.copy_address, .enabled = one != null })) {
        var clip: Clip = .{};
        clip.line("0x{x}", .{one.?.offset});
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy name", .enabled = one != null, .tooltip = "As Class.field" })) {
        var clip: Clip = .{};
        clip.line("{s}.{s}", .{ entry.name, one.?.name });
        clip.copy();
    }
}

fn staticAddress(_: *Classes, field: *Managed.Field) (Runtime.StaticError || Managed.Error)!usize {
    return Managed.global.call(struct {
        fn f(rt: *const Runtime, fld: *Managed.Field) Runtime.StaticError!usize {
            return rt.staticAddress(fld);
        }
    }.f, .{field}) catch |err| return err;
}

fn fieldId(f: *const FieldRow) u64 {
    return @intFromPtr(f.field);
}

fn focusedField(self: *const Classes) ?*const FieldRow {
    const id = self.picked_fields.focused() orelse return null;
    for (self.fields) |*f| if (fieldId(f) == id) return f;
    return null;
}

fn drawMethods(self: *Classes, entry: *const Entry) void {
    const table = ui.table("methods", 3, .{ .borders = true, .row_background = true, .resizable = true, .sizing = .stretch_prop, .scroll_y = true }) orelse return;
    ui.tableColumnWith("Name", .{ .stretch = true, .width = 2 });
    ui.tableColumnWith("Signature", .{ .stretch = true, .width = 4 });
    ui.tableColumnWith("Kind", .{ .stretch = true, .width = 1 });
    ui.tableHeaders();
    const rows = self.methods;
    var picking = self.picked_methods.begin(rows.len, ui.Selection.Rows(MethodRow, methodId){ .rows = rows }, .{});
    for (rows, 0..) |*m, i| {
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        _ = picking.row(i, ui.format("{s}", .{m.name}));
        _ = ui.tableNextColumn();
        ui.text("{s}", .{m.signature});
        _ = ui.tableNextColumn();
        if (m.is_static) ui.textDisabled("static", .{});
    }
    picking.end();
    table.end();
    self.methodCommands(entry);
}

fn methodCommands(self: *Classes, entry: *const Entry) void {
    const keys = &devtools.keys;
    var menu = ui.commands("methods", .{ .activated = self.picked_methods.activated });
    defer menu.end();
    const one = self.focusedMethod();
    const any = self.picked_methods.count() > 0;
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one != null, .default = true, .tooltip = "Compiles it first under Mono if nothing's run it yet" })) {
        if (self.codeOf(one.?.method)) |at| self.nav.openCode(at) else self.fail("that method has no code, like an abstract one");
    }
    menu.separator();
    if (menu.item(.{ .label = "Copy", .chord = keys.copy, .enabled = any, .tooltip = "Name and signature, one method a line" })) {
        var clip: Clip = .{};
        for (self.methods) |*m| if (self.picked_methods.contains(methodId(m))) clip.line("{s}{s}", .{ m.name, m.signature });
        clip.copy();
    }
    if (menu.item(.{ .label = "Copy address", .chord = keys.copy_address, .enabled = one != null })) {
        if (self.codeOf(one.?.method)) |at| {
            var clip: Clip = .{};
            clip.line("0x{x}", .{at});
            clip.copy();
        } else self.fail("that method has no code, like an abstract one");
    }
    if (menu.item(.{ .label = "Copy name", .enabled = one != null, .tooltip = "As Class:Method, which works anywhere an address does" })) {
        var clip: Clip = .{};
        const name = ui.format("{s}:{s}", .{ entry.name, one.?.name });
        // Nested and generic names need quotes in address text
        if (bare(name)) clip.line("{s}", .{name}) else clip.line("\"{s}\"", .{name});
        clip.copy();
    }
}

/// Fine in address text without quotes.
fn bare(name: []const u8) bool {
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != ':') return false;
    return true;
}

pub fn codeOf(_: *Classes, method: *Managed.Method) ?usize {
    return Managed.global.call(struct {
        fn f(rt: *const Runtime, m: *Managed.Method) ?usize {
            return rt.methodPointer(m);
        }
    }.f, .{method}) catch null;
}

fn methodId(m: *const MethodRow) u64 {
    return @intFromPtr(m.method);
}

fn focusedMethod(self: *const Classes) ?*const MethodRow {
    const id = self.picked_methods.focused() orelse return null;
    for (self.methods) |*m| if (methodId(m) == id) return m;
    return null;
}
