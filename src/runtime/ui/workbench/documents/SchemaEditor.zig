//! A Schema document, game types as text on the left and a struct laid out on the right. Either a
//! project's `schemas/x.sal`, made on the first edit, or a file of its own, like a plugin's.

const SchemaEditor = @This();

const std = @import("std");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const salamander_schema = @import("salamander_schema");
const sal_options = @import("wraith_api").sal_options;
/// Before everything it reads, like a plugin's schemas are, so Wraith's types like `Vec3` are there.
const wraith_prefix = @import("wraith_api").wraith_sal ++ "\n";
/// Each file's read as its own, like in a plugin's bundle, so namespaces stay in their files.
const file_marker = "file \"";
/// Its own text's name in the bundle, which its problems are shown without.
const own_name = "this";
const own_marker = file_marker ++ own_name ++ "\";\n";
const tuft_window = @import("tuft_window");
const ui = @import("wraith_ui");
const Text = @import("tuft_text").Text;

const Workbench = @import("../Workbench.zig");
const PluginLoader = @import("../../../PluginLoader.zig");
const Project = @import("../../../Project.zig");

const Schema = salamander_schema.Schema;
const max_text = 256 * 1024;
const red: ui.Color = .{ 1, 0.4, 0.4, 1 };
/// Typing pauses this long before the text goes to the project.
const write_delay_ns = 400 * std.time.ns_per_ms;

pub const example =
    \\// Types to lay out on the right. Type an address over there to see one in memory, or give a
    \\// struct a [Sig] static of its own type and Ctrl+Enter finds it.
    \\// Right-click a row to define a field in a gap, change a type and more
    \\enum State : u8 { Idle, Walking, Dead }
    \\
    \\[Size(0x40)]
    \\struct Player {
    \\    [0x8] f32 health;
    \\    State state;
    \\    [0x10] utf8[16] name;
    \\    Player* target;
    \\}
    \\
;

/// Its tab's, which the Workbench's tabs keep.
window: *ui.Window = undefined,
wb: *Workbench,
view: devtools.StructView,
text: ?[:0]u8 = null,
/// Its own file. Empty if it's the project's.
path: Text(260) = .{},
/// Where it is in the project, once it's been changed.
project_path: Text(128) = .{},
/// Typed but not given to the project yet.
pending: bool = false,
last_edit_ns: u64 = 0,
/// Its name changed, so the workbench gives it a new title.
renamed: bool = false,
context: []u8 = &.{},
/// Shown while the text doesn't parse.
parsed: ?salamander_schema.Parsed = null,
problem: ?devtools.Problem = null,
/// Only ever false for one with its own file.
saved: bool = true,
split: ui.Split = .{ .ratio = 0.4 },
/// After Ctrl+Enter took it.
refocus_text: bool = false,

pub fn init(self: *SchemaEditor, text: ?[]const u8) !void {
    if (self.text == null) {
        const buf = try self.wb.allocator.allocSentinel(u8, max_text, 0);
        @memset(buf, 0);
        self.text = buf;
    }
    // Empty, with the example as a hint
    self.setText(text orelse "");
    self.reparse();
}

pub fn deinit(self: *SchemaEditor) void {
    self.flush();
    self.view.deinit();
    if (self.parsed) |*p| p.deinit();
    self.parsed = null;
    if (self.text) |t| self.wb.allocator.free(t);
    self.text = null;
    self.wb.allocator.free(self.context);
    self.context = &.{};
}

fn setText(self: *SchemaEditor, text: []const u8) void {
    const buf = self.text orelse return;
    const n = @min(text.len, max_text);
    @memcpy(buf[0..n], text[0..n]);
    @memset(buf[n..], 0);
}

pub fn source(self: *const SchemaEditor) []const u8 {
    return std.mem.sliceTo(self.text orelse return "", 0);
}

pub fn savedPath(self: *const SchemaEditor) ?[]const u8 {
    const p = self.path.get();
    return if (p.len == 0) null else p;
}

/// Saved to a file of its own, not the project.
pub fn ownFile(self: *const SchemaEditor) bool {
    return self.savedPath() != null;
}

pub fn projectPath(self: *const SchemaEditor) ?[]const u8 {
    const p = self.project_path.get();
    return if (p.len == 0) null else p;
}

/// Like `x.sal`. Null for a new one.
pub fn name(self: *const SchemaEditor) ?[]const u8 {
    return std.fs.path.basename(self.savedPath() orelse self.projectPath() orelse return null);
}

/// Its file, or its spot in the project.
fn edited(self: *SchemaEditor) void {
    if (self.ownFile()) {
        self.saved = false;
        return;
    }
    self.pending = true;
    self.last_edit_ns = core.timing.now();
}

/// Gives what's typed to the project. The first time picks a free name.
pub fn flush(self: *SchemaEditor) void {
    if (!self.pending) return;
    self.pending = false;
    const project = self.wb.project orelse return;
    if (self.projectPath() == null) {
        const free = project.freeName("schemas/schema" ++ Project.ext.schema) catch return;
        defer project.allocator.free(free);
        if (free.len > self.project_path.buf.len) return;
        self.project_path.set(free);
        self.renamed = true;
    }
    project.write(self.projectPath().?, self.source()) catch |err| {
        self.problem = .init("Couldn't keep it in the project: {t}", .{err});
    };
}

/// One of the project's, with the others before it like a plugin's schemas are read.
pub fn openInProject(self: *SchemaEditor, project: *Project, path: []const u8) !void {
    const gpa = self.wb.allocator;
    const text = (try project.read(gpa, path)) orelse return error.FileNotFound;
    defer gpa.free(text);
    if (text.len >= max_text) return error.FileTooBig;
    var context: std.ArrayList(u8) = .empty;
    errdefer context.deinit(gpa);
    var others = try project.list(gpa, "schemas", Project.ext.schema);
    defer Project.freePaths(gpa, &others);
    for (others.items) |other| {
        if (std.mem.eql(u8, other, path)) continue;
        const t = (try project.read(gpa, other)) orelse continue;
        defer gpa.free(t);
        try appendFile(gpa, &context, std.fs.path.basename(other), t);
    }
    if (self.text == null) try self.init("");
    if (path.len > self.project_path.buf.len) return error.NameTooLong;
    self.project_path.set(path);
    gpa.free(self.context);
    self.context = try context.toOwnedSlice(gpa);
    self.setText(text);
    self.reparse();
}

/// Wraith's, then the others next to it, then its own, each a file of the bundle. The caller frees it.
fn combined(self: *const SchemaEditor) ![:0]u8 {
    return std.mem.concatWithSentinel(self.wb.allocator, u8, &.{ wraith_prefix, self.context, own_marker, self.source() }, 0);
}

/// Another file before its own, with its marker.
fn appendFile(gpa: std.mem.Allocator, context: *std.ArrayList(u8), file_name: []const u8, text: []const u8) !void {
    try context.print(gpa, file_marker ++ "{s}\";\n", .{file_name});
    try context.appendSlice(gpa, text);
    if (text.len > 0 and text[text.len - 1] != '\n') try context.append(gpa, '\n');
}

/// While it doesn't parse, the last one that did stays up.
fn reparse(self: *SchemaEditor) void {
    const gpa = self.wb.allocator;
    const text = self.combined() catch |err| {
        self.problem = .init("Couldn't read it: {t}", .{err});
        return;
    };
    defer gpa.free(text);
    var diag: Schema.Diagnostic = .{};
    const parsed = salamander_schema.parse(gpa, text, sal_options, &diag) catch |err| {
        self.problem = if (err == error.InvalidSchema) located(diag.message()) else .init("Couldn't read it: {t}", .{err});
        return;
    };
    const old = self.parsed;
    self.parsed = parsed;
    self.view.setSchema(&self.parsed.?.schema);
    self.hideWraiths();
    if (old) |o| {
        var gone = o;
        gone.deinit();
    }
    self.problem = null;
}

/// Wraith's types are there to use, not to show, so only the ones after its schemas are listed.
fn hideWraiths(self: *SchemaEditor) void {
    const schema = &self.parsed.?.schema;
    const view = &self.view;
    const kept: ?[]const u8 = if (view.shownName()) |n| view.allocator.dupe(u8, n) catch null else null;
    defer if (kept) |k| view.allocator.free(k);
    var i: usize = 0;
    while (i < view.type_names.items.len) {
        const type_name = view.type_names.items[i];
        const wraiths = for (schema.types) |t| {
            if (!t.nested and std.mem.eql(u8, t.name, type_name)) break t.at < wraith_prefix.len;
        } else false;
        if (!wraiths) {
            i += 1;
            continue;
        }
        view.allocator.free(type_name);
        _ = view.type_names.orderedRemove(i);
    }
    view.shown = 0;
    if (kept) |k| _ = view.show(k);
}

/// Problems come as `file:line:column: what`. Its own are shown without the file.
fn located(message: []const u8) devtools.Problem {
    if (std.mem.startsWith(u8, message, own_name ++ ":")) return .init("{s}", .{message[own_name.len + 1 ..]});
    return .init("In another file, {s}", .{message});
}

pub fn apply(self: *SchemaEditor, changes: []const salamander_schema.edit.Change) void {
    const gpa = self.wb.allocator;
    const text = self.combined() catch return;
    defer gpa.free(text);
    var diag: Schema.Diagnostic = .{};
    const out = salamander_schema.edit.apply(gpa, text, changes, .{ .parse = sal_options, .diagnostic = &diag }) catch |err| {
        const problem: devtools.Problem = switch (err) {
            error.InvalidSchema => located(diag.message()),
            error.NotInSource => .init("That isn't written where it can be changed, like a field's own bits", .{}),
            else => .init("Couldn't change it: {t}", .{err}),
        };
        self.view.problem = problem;
        return;
    };
    defer gpa.free(out);
    if (!std.mem.startsWith(u8, out, wraith_prefix)) {
        self.view.fail("That's one of Wraith's, which can't be changed here", .{});
        return;
    }
    const rest = out[wraith_prefix.len..];
    if (!std.mem.startsWith(u8, rest, self.context) or !std.mem.startsWith(u8, rest[self.context.len..], own_marker)) {
        self.view.fail("That's in another file next to this one. Open that to change it", .{});
        return;
    }
    const mine = rest[self.context.len + own_marker.len ..];
    if (mine.len >= max_text) {
        self.view.fail("That makes it too long", .{});
        return;
    }
    self.setText(mine);
    self.edited();
    self.reparse();
}

pub fn draw(self: *SchemaEditor) void {
    const text = self.text orelse return;
    if (self.problem) |*p| ui.textColored(red, "{s}", .{p.message()}) else self.drawStatus();

    if (self.split.first("text")) |part| {
        defer part.end();
        const mono = ui.monospace();
        defer mono.end();
        if (self.refocus_text) {
            self.refocus_text = false;
            ui.focusNext();
        }
        if (ui.inputTextMultilineHint("##text", text, .{ ui.fill, ui.fill }, .{}, example)) {
            self.edited();
            self.reparse();
        }
        self.typingKeys();
    }
    if (self.split.second("struct")) |part| {
        defer part.end();
        self.view.draw();
        self.commands();
    }
    if (self.pending and (core.timing.now() -| self.last_edit_ns > write_delay_ns or !ui.isAnyItemActive())) self.flush();
}

/// Ctrl+Enter makes ImGui let go of the text, so it's caught as that happens.
fn typingKeys(self: *SchemaEditor) void {
    const typing = ui.isItemActive();
    if (!typing and !ui.isItemDeactivated()) return;
    const keys = &devtools.keys;
    if (pressed(keys.run)) {
        self.view.findSignatures();
        if (!typing) self.refocus_text = true;
    }
    // The project's are saved by the workbench
    if (typing and self.ownFile() and pressed(keys.save)) self.save();
}

fn pressed(chord: ?ui.Chord) bool {
    const ch = chord orelse return false;
    return ch.pressed();
}

fn drawStatus(self: *SchemaEditor) void {
    const schema = if (self.parsed) |*p| &p.schema else {
        ui.textDisabled("Nothing yet", .{});
        return;
    };
    const where = self.savedPath() orelse self.projectPath() orelse "Not in the project till it's changed";
    const unsaved = if (self.saved) "" else ", not saved";
    ui.textDisabled("{s}. {d} types{s}", .{ where, schema.types.len, unsaved });
}

fn commands(self: *SchemaEditor) void {
    const keys = &devtools.keys;
    var menu = ui.commands("schema", .{ .activated = self.view.activated() });
    defer menu.end();
    self.view.commands(&menu);
    const changes = self.view.takeChanges();
    if (changes.len > 0) self.apply(changes);

    menu.separator();
    const selected = self.view.selected();
    const one = selected != null;
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one, .tooltip = "Where it points, for pointers and vtable slots" })) {
        self.wb.openCode(selected.?.target orelse selected.?.address);
    }
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = one })) self.wb.openMemory(selected.?.address, selected.?.size, null);
    if (menu.item(.{ .label = "Show where it points", .enabled = one and selected.?.target != null and selected.?.target.? != 0, .tooltip = "In memory" })) {
        self.wb.openMemory(selected.?.target.?, 1, null);
    }
    if (menu.item(.{ .label = "Add to address list", .chord = keys.add_to_list, .enabled = one, .tooltip = "Watch it in the Addresses window" })) {
        self.wb.panels.addresses.add(selected.?.address, selected.?.kind, selected.?.size);
    }
    if (menu.item(.{ .label = "Find what writes this", .chord = keys.what_writes, .enabled = one, .tooltip = "Adds it to the address list, where every instruction that writes it shows" })) {
        self.wb.panels.addresses.watch(selected.?.address, selected.?.kind, selected.?.size, .writes);
    }
    if (menu.item(.{ .label = "Find what reads this", .chord = keys.what_reads, .enabled = one, .tooltip = "Adds it to the address list, where every instruction that reads it shows" })) {
        self.wb.panels.addresses.watch(selected.?.address, selected.?.kind, selected.?.size, .reads);
    }
    if (menu.item(.{ .label = "Go to address", .chord = keys.go_to, .tooltip = "Type where the struct is" })) self.view.bar.focus();
    menu.separator();
    if (self.ownFile()) {
        if (menu.item(.{ .label = "Save", .chord = keys.save, .enabled = !self.saved, .tooltip = "Back to its file" })) self.save();
        if (menu.item(.{ .label = "Save as...", .chord = keys.save_as })) self.saveAsPicked();
        if (menu.item(.{ .label = "Reload", .tooltip = "Read its file again, dropping what's not saved" })) {
            var buf: [260]u8 = undefined;
            const path = buf[0..self.savedPath().?.len];
            @memcpy(path, self.savedPath().?);
            self.open(path) catch |err| {
                self.problem = .init("Couldn't reload it: {t}", .{err});
            };
        }
        if (menu.item(.{ .label = "Copy into the project", .tooltip = "A copy that's saved with the project. This file stays as it is" })) self.copyIntoProject();
    } else if (self.projectPath()) |path| {
        if (menu.item(.{ .label = "Remove from the project", .tooltip = "Gone when the project's saved" })) {
            if (self.wb.project) |project| project.delete(path);
            self.pending = false;
            self.window.open = false;
        }
    }
    if (menu.item(.{ .label = "Open file...", .enabled = self.wb.io != null, .tooltip = "A .sal of its own, like a plugin's" })) {
        const picked = self.pick(.open) orelse return;
        defer self.wb.allocator.free(picked);
        self.wb.openSchema(picked);
    }
    const files = self.wb.io != null;
    if (menu.item(.{ .label = "Export...", .chord = keys.export_file, .enabled = files, .tooltip = "A copy, to a .sal file of its own" })) {
        self.wb.exportText(Workbench.FileType.schema, self.name() orelse ("schema" ++ Project.ext.schema), self.source());
    }
    if (menu.item(.{ .label = "Import...", .chord = keys.import_file, .enabled = files and self.wb.project != null, .tooltip = "A .sal file, into the project" })) {
        if (self.wb.importFile(Workbench.FileType.schema, "schemas")) |path| {
            defer self.wb.project.?.allocator.free(path);
            self.wb.openProjectSchema(path);
        }
    }
}

/// Null if cancelled.
fn pick(self: *SchemaEditor, mode: tuft_window.FileDialog.Mode) ?[]u8 {
    const current = self.savedPath() orelse "";
    return tuft_window.pickFile(self.wb.allocator, .{
        .mode = mode,
        .owner = self.wb.dialogOwner(),
        .alive = self.wb.dialogAlive(),
        .title = if (mode == .save) "Save schema" else "Open schema",
        .folder = std.fs.path.dirname(current) orelse "",
        .file_name = if (mode == .save) self.name() orelse ("schema" ++ Project.ext.schema) else "",
        .kind = "Schema",
        .extension = Project.ext.schema,
    }) catch |err| {
        self.problem = .init("Couldn't show the file dialog: {t}", .{err});
        return null;
    };
}

fn saveAsPicked(self: *SchemaEditor) void {
    const path = self.pick(.save) orelse return;
    defer self.wb.allocator.free(path);
    self.saveAs(path) catch |err| {
        self.problem = .init("Couldn't save it: {t}", .{err});
    };
}

fn copyIntoProject(self: *SchemaEditor) void {
    const project = self.wb.project orelse return;
    const base = self.name() orelse ("schema" ++ Project.ext.schema);
    var buf: [128]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "schemas/{s}", .{base}) catch return;
    const free = project.freeName(want) catch return;
    defer project.allocator.free(free);
    project.write(free, self.source()) catch |err| {
        self.problem = .init("Couldn't copy it: {t}", .{err});
        return;
    };
    self.wb.openProjectSchema(free);
}

pub fn save(self: *SchemaEditor) void {
    const path = self.savedPath() orelse return self.saveAsPicked();
    self.write(path) catch |err| {
        self.problem = .init("Couldn't save it: {t}", .{err});
    };
}

pub fn saveAs(self: *SchemaEditor, path: []const u8) !void {
    if (path.len == 0) return error.NoPath;
    if (path.len > self.path.buf.len) return error.NameTooLong;
    try self.write(path);
    // `path` might be our own field
    const copy: @TypeOf(self.path) = .init(path);
    self.path = copy;
    self.renamed = true;
}

fn write(self: *SchemaEditor, path: []const u8) !void {
    const io = self.wb.io orelse return error.NoFiles;
    try core.files.write(io, path, self.source(), .{ .make_dir = true });
    self.saved = true;
    self.problem = null;
}

pub fn open(self: *SchemaEditor, path: []const u8) !void {
    if (path.len == 0) return error.NoPath;
    if (path.len > self.path.buf.len) return error.NameTooLong;
    const io = self.wb.io orelse return error.NoFiles;
    const gpa = self.wb.allocator;
    var reading = try io.concurrent(load, .{ io, gpa, path });
    const loaded = try reading.await(io);
    defer gpa.free(loaded.text);
    errdefer gpa.free(loaded.context);
    if (loaded.text.len >= max_text) return error.FileTooBig;
    if (self.text == null) try self.init("");

    // `path` might be our own field
    const copy: @TypeOf(self.path) = .init(path);
    self.path = copy;
    gpa.free(self.context);
    self.context = loaded.context;
    self.setText(loaded.text);
    self.saved = true;
    self.reparse();
}

const Loaded = struct {
    text: []u8,
    context: []u8,
};

/// With the other `.sal` files next to it before it, since they're read together.
fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Loaded {
    const cwd = std.Io.Dir.cwd();
    const text = try cwd.readFileAlloc(io, path, gpa, .limited(max_text));
    errdefer gpa.free(text);
    var context: std.ArrayList(u8) = .empty;
    errdefer context.deinit(gpa);
    context: {
        const dir_path = std.fs.path.dirname(path) orelse ".";
        var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch break :context;
        defer dir.close(io);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |n| gpa.free(n);
            names.deinit(gpa);
        }
        var it = dir.iterate();
        while (it.next(io) catch break :context) |entry| {
            if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, Project.ext.schema)) continue;
            if (std.ascii.eqlIgnoreCase(entry.name, std.fs.path.basename(path))) continue;
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
        // In name order, like a plugin's schemas are read
        std.mem.sort([]u8, names.items, {}, struct {
            fn before(_: void, a: []u8, b: []u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.before);
        for (names.items) |file_name| {
            const other = dir.readFileAlloc(io, file_name, gpa, .limited(max_text)) catch continue;
            defer gpa.free(other);
            try appendFile(gpa, &context, file_name, other);
        }
    }
    return .{ .text = text, .context = try context.toOwnedSlice(gpa) };
}

pub const Found = struct {
    /// Like `kai/kai.sal`.
    label: [:0]u8,
    path: []u8,
};

/// Frees what was in `out`.
pub fn findPluginSchemas(wb: *Workbench, out: *std.ArrayList(Found)) void {
    const gpa = wb.allocator;
    freeFound(gpa, out);
    const io = wb.io orelse return;
    const shell = wb.shell orelse return;
    var infos: std.ArrayList(PluginLoader.Info) = .empty;
    defer infos.deinit(gpa);
    {
        const loader = shell.acquireLoader() orelse return;
        defer shell.releaseLoader();
        loader.listInto(gpa, &infos);
    }
    for (infos.items) |*info| {
        if (info.source_dir.get().len == 0) continue;
        var listing = io.concurrent(listSchemas, .{ io, gpa, info.name.get(), info.source_dir.get(), out }) catch continue;
        listing.await(io) catch continue;
    }
}

pub fn freeFound(gpa: std.mem.Allocator, list: *std.ArrayList(Found)) void {
    for (list.items) |f| {
        gpa.free(f.label);
        gpa.free(f.path);
    }
    list.clearRetainingCapacity();
}

fn listSchemas(io: std.Io, gpa: std.mem.Allocator, plugin: []const u8, source_dir: []const u8, out: *std.ArrayList(Found)) !void {
    const dir_path = try std.fs.path.join(gpa, &.{ source_dir, "schemas" });
    defer gpa.free(dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, Project.ext.schema)) continue;
        const label = try std.fmt.allocPrintSentinel(gpa, "{s}/{s}", .{ plugin, entry.name }, 0);
        errdefer gpa.free(label);
        const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        errdefer gpa.free(path);
        try out.append(gpa, .{ .label = label, .path = path });
    }
}
