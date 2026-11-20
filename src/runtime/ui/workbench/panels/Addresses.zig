//! Addresses you're watching in this game, Cheat Engine style.

const Addresses = @This();

const std = @import("std");

const devtools = @import("tuft_devtools");
const core = @import("wraith_core");
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");
const Accesses = @import("Accesses.zig");
pub const AddressKeys = @import("AddressKeys.zig");
const Names = @import("../../../Names.zig");
const SharedSchemas = @import("../../../SharedSchemas.zig");
const Project = @import("../../../Project.zig");

const AddressList = devtools.AddressList;
const salamander_schema = @import("salamander_schema");
const Schema = salamander_schema.Schema;
const Parsed = salamander_schema.Parsed;
const sal_options = @import("wraith_api").sal_options;
const sigs = @import("tuft_schema").sigs;
const Sig = @import("tuft_mem").Sig;
const Kind = @import("tuft_mem").values.Kind;
const RwLock = @import("tuft_sys").sync.RwLock;
const log = core.log.scoped(.wraith_ui);

window: ui.Window = .{ .title = "Addresses", .size = .{ 720, 560 }, .min_size = .{ 500, 360 } },
wb: *Workbench,
list: AddressList,
/// Its hotkeys, in the game's keybinds.
keys: AddressKeys,
/// Before the workbench's thread starts, the render thread keeps holds and hotkeys going. This
/// is the handover.
live_lock: RwLock = .{},
/// Its thread ticks it now. Under `live_lock`.
handed_over: bool = false,
split: ui.Split = .{ .ratio = 0.55 },
/// Where the list lives. Without one it only lasts as long as the game.
project: ?*Project = null,
/// When names were last worked out again, so listings name what moved.
refreshed_ns: u64 = 0,
/// The project's schemas, then the ones plugins and scripts share, for typed entries.
project_schemas: std.ArrayList(Parsed) = .empty,
plugin_schemas: std.ArrayList(Shared) = .empty,
/// Both, project first so its types win. Sources are "" for the project's, else the plugin.
schemas: std.ArrayList(*const Schema) = .empty,
sources: std.ArrayList([]const u8) = .empty,
/// The project version and schema text they were read from, so they're only read again when
/// that changes.
schemas_version: u32 = 0,
schemas_hash: u64 = 0,
/// `SharedSchemas` as last read.
plugins_generation: u32 = 0,

const refresh_ns = std.time.ns_per_s / 2;

pub fn useProject(self: *Addresses, project: *Project) void {
    self.project = project;
    self.schemas_hash = 0;
    self.readSchemas();
    self.reload();
}

/// The project's list as it is now, saved or not.
pub fn reload(self: *Addresses) void {
    const project = self.project orelse return;
    const gpa = self.wb.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const text = (project.read(arena.allocator(), Project.addresses_file) catch null) orelse "";
    const saved = parse(arena.allocator(), text) catch |err| {
        log.warn("Couldn't read the project's address list: {t}", .{err});
        return;
    };
    self.list.load(saved.items) catch |err| log.warn("Couldn't load the address list: {t}", .{err});
    Names.global.setUser(saved.items, self.schemas.items);
}

fn parse(arena: std.mem.Allocator, text: []const u8) !AddressList.Saved {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{};
    const source = try arena.dupeSentinel(u8, text, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(AddressList.Saved, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diagnostics, .ignore_unknown_fields = true });
}

pub fn deinit(self: *Addresses) void {
    const gpa = self.wb.allocator;
    self.keys.deinit();
    self.list.deinit();
    freeSchemas(&self.project_schemas, gpa);
    freeShared(&self.plugin_schemas, gpa);
    self.schemas.deinit(gpa);
    self.sources.deinit(gpa);
    Names.global.removeGroup(.schema, statics_group);
}

fn freeSchemas(parsed: *std.ArrayList(Parsed), gpa: std.mem.Allocator) void {
    for (parsed.items) |*p| p.deinit();
    parsed.deinit(gpa);
}

/// A schema a plugin or script shared, parsed for us.
const Shared = struct {
    parsed: Parsed,
    /// Its plugin, in the parse's arena.
    group: []const u8,
};

fn freeShared(shared: *std.ArrayList(Shared), gpa: std.mem.Allocator) void {
    for (shared.items) |*p| p.parsed.deinit();
    shared.deinit(gpa);
}

/// What the project's schema statics are named under in `Names`.
const statics_group = "schemas";

/// Reads the project's schemas and the shared ones again if either changed.
fn readSchemas(self: *Addresses) void {
    const gpa = self.wb.allocator;
    var project = self.readProjectSchemas();
    var plugins = self.readPluginSchemas();
    if (project == null and plugins == null) return;

    // The list lets go of the old ones before they're freed
    var schemas: std.ArrayList(*const Schema) = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    const project_now = if (project) |*p| p else &self.project_schemas;
    const plugins_now = if (plugins) |*p| p else &self.plugin_schemas;
    for (project_now.items) |*p| {
        schemas.append(gpa, &p.schema) catch {};
        sources.append(gpa, "") catch {};
    }
    for (plugins_now.items) |*p| {
        schemas.append(gpa, &p.parsed.schema) catch {};
        sources.append(gpa, p.group) catch {};
    }
    if (schemas.items.len != sources.items.len) sources.clearRetainingCapacity();
    self.list.setSchemas(schemas.items, sources.items);
    self.schemas.deinit(gpa);
    self.sources.deinit(gpa);
    self.schemas = schemas;
    self.sources = sources;
    if (project) |p| {
        freeSchemas(&self.project_schemas, gpa);
        self.project_schemas = p;
        self.publishStatics();
    }
    if (plugins) |p| {
        freeShared(&self.plugin_schemas, gpa);
        self.plugin_schemas = p;
    }
    self.publish();
}

/// The project's `schemas/*.sal` parsed again, or null if they didn't change. All together like a
/// plugin's `schemas` folder, or one at a time if that doesn't parse, so one bad file doesn't hide
/// the rest.
fn readProjectSchemas(self: *Addresses) ?std.ArrayList(Parsed) {
    const version = if (self.project) |p| p.version() else 0;
    if (version == self.schemas_version and self.schemas_hash != 0) return null;
    self.schemas_version = version;
    const gpa = self.wb.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var texts: std.ArrayList(salamander_schema.File) = .empty;
    var hash = std.hash.Wyhash.init(0);
    if (self.project) |project| {
        var paths = project.list(gpa, "schemas", Project.ext.schema) catch return null;
        defer Project.freePaths(gpa, &paths);
        for (paths.items) |path| {
            const text = (project.read(a, path) catch return null) orelse continue;
            texts.append(a, .{ .name = path, .text = text }) catch return null;
            hash.update(path);
            hash.update(&.{0});
            hash.update(text);
            hash.update(&.{0});
        }
    }
    // Never 0, so the first read always counts
    const digest = hash.final() | 1;
    if (digest == self.schemas_hash) return null;
    self.schemas_hash = digest;

    var parsed: std.ArrayList(Parsed) = .empty;
    const combined = salamander_schema.bundle(a, texts.items) catch return parsed;
    if (salamander_schema.parse(gpa, combined, sal_options, null)) |one| {
        parsed.append(gpa, one) catch {
            var gone = one;
            gone.deinit();
        };
    } else |_| for (texts.items) |t| {
        var diag: Schema.Diagnostic = .{};
        var one = salamander_schema.parse(gpa, t.text, sal_options, &diag) catch {
            log.debug("{s} doesn't parse: {s}", .{ t.name, diag.message() });
            continue;
        };
        parsed.append(gpa, one) catch {
            one.deinit();
            break;
        };
    }
    return parsed;
}

/// The schemas plugins and scripts share, parsed again, or null if they didn't change. Each is
/// ours, so a plugin going just drops them next time.
fn readPluginSchemas(self: *Addresses) ?std.ArrayList(Shared) {
    const now = SharedSchemas.global.generation();
    if (now == self.plugins_generation) return null;
    self.plugins_generation = now;
    const gpa = self.wb.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var parsed: std.ArrayList(Shared) = .empty;
    const entries = SharedSchemas.global.copy(arena.allocator()) catch return parsed;
    for (entries) |e| {
        var diag: Schema.Diagnostic = .{};
        var one = salamander_schema.parse(gpa, e.text, sal_options, &diag) catch {
            log.debug("{s} from {s} doesn't parse: {s}", .{ e.name, e.group, diag.message() });
            continue;
        };
        const group = one.arena.allocator().dupe(u8, if (e.group.len > 0) e.group else e.name) catch "";
        parsed.append(gpa, .{ .parsed = one, .group = group }) catch {
            one.deinit();
            break;
        };
    }
    return parsed;
}

/// The project's schema statics as names, like `GameStateManager.instance`. Plugins' are named
/// by the plugin, with its name in front.
fn publishStatics(self: *Addresses) void {
    Names.global.removeGroup(.schema, statics_group);
    for (self.project_schemas.items) |*p| {
        const s = &p.schema;
        for (s.statics) |st| nameStatic(s, st, "");
        for (s.types) |t| switch (t.kind) {
            .@"struct" => |st| for (st.statics) |one| nameStatic(s, one, t.name),
            else => {},
        };
    }
}

fn nameStatic(s: *const Schema, st: Schema.Static, owner: []const u8) void {
    var id_buf: [192]u8 = undefined;
    const id = (if (owner.len > 0) std.fmt.bufPrint(&id_buf, "{s}.{s}", .{ owner, st.name }) else st.name) catch return;
    var steps: [sigs.max_steps]Sig.Step = undefined;
    const sig = (sigs.of(st.annotations, "wraith", "Sig", &steps) catch return) orelse return;
    var text_buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&text_buf, "{f}", .{sig}) catch return;
    var type_buf: [256]u8 = undefined;
    Names.global.put(.{
        .source = .schema,
        .group = statics_group,
        .name = id,
        .where = .{ .text = .{ .text = text } },
        .type = std.fmt.bufPrint(&type_buf, "{f}", .{st.type}) catch return,
        .size = s.sizeOf(st.type) orelse 0,
    }) catch |err| log.debug("Couldn't name {s}: {t}", .{ id, err });
}

/// Gives `Names` the list as it is, like when sizes change with the schemas.
fn publish(self: *Addresses) void {
    var arena: std.heap.ArenaAllocator = .init(self.wb.allocator);
    defer arena.deinit();
    const items = self.list.items(arena.allocator()) catch return;
    Names.global.setUser(items, self.schemas.items);
}

/// Writes the list to the project and `Names`.
pub fn changed(self: *Addresses) void {
    var arena: std.heap.ArenaAllocator = .init(self.wb.allocator);
    defer arena.deinit();
    const items = self.list.items(arena.allocator()) catch |err| {
        log.warn("Couldn't keep the address list: {t}", .{err});
        return;
    };
    Names.global.setUser(items, self.schemas.items);
    const project = self.project orelse return;
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    std.zon.stringify.serialize(AddressList.Saved{ .items = items }, .{}, &out.writer) catch return;
    out.writer.writeByte('\n') catch return;
    project.write(Project.addresses_file, out.written()) catch |err| log.warn("Couldn't keep the address list: {t}", .{err});
}

/// Every workbench tick, open or not.
pub fn tick(self: *Addresses) void {
    self.readSchemas();
    self.tickLive();
    const now_ns = core.timing.now();
    if (now_ns -| self.refreshed_ns >= refresh_ns) {
        self.refreshed_ns = now_ns;
        Names.global.refresh();
    }
}

/// Holds and hotkeys, which players count on with the workbench never opened.
fn tickLive(self: *Addresses) void {
    self.keys.tick(&self.list);
    self.list.enforce();
}

/// From the render thread till the workbench's own thread takes over. No files here.
pub fn tickUnopened(self: *Addresses) void {
    self.live_lock.lock();
    defer self.live_lock.unlock();
    if (!self.handed_over) self.tickLive();
}

/// Before the workbench's thread starts, or back if it couldn't. Waits for a render thread tick
/// in flight.
pub fn handOver(self: *Addresses, on: bool) void {
    self.live_lock.lock();
    defer self.live_lock.unlock();
    self.handed_over = on;
}

pub fn add(self: *Addresses, address: usize, kind: Kind, len: usize) void {
    self.list.addAddress(address, kind, len) catch |err| {
        log.warn("Couldn't add to the address list: {t}", .{err});
        return;
    };
    self.window.focus();
}

/// Like a name from the Names panel, as the user's own.
pub fn addItem(self: *Addresses, item: AddressList.Item) void {
    self.list.addItem(item) catch |err| {
        log.warn("Couldn't add to the address list: {t}", .{err});
        return;
    };
    self.window.focus();
}

pub fn watch(self: *Addresses, address: usize, kind: Kind, len: usize, mode: Accesses.Mode) void {
    self.add(address, kind, len);
    const target = self.list.selectedTarget() orelse return;
    self.wb.panels.accesses.start(target.address, target.len, mode, target.name);
}

pub fn draw(self: *Addresses) void {
    if (self.split.first("list")) |part| {
        defer part.end();
        self.list.drawList();
        self.commands();
    }
    if (self.split.second("entry")) |part| {
        defer part.end();
        if (self.list.drawEntry()) {
            if (self.list.selectedTarget()) |target| {
                ui.separatorText("What writes or reads it");
                self.wb.panels.accesses.drawFor(target.address, target.name);
            }
        } else {
            ui.textDisabled("Pick an entry to see it here", .{});
        }
        var menu = ui.commands("address_entry", .{});
        defer menu.end();
        self.list.entryCommands(&menu);
    }
    if (self.list.takeDirty()) self.changed();
}

fn commands(self: *Addresses) void {
    const keys = &devtools.keys;
    var menu = ui.commands("addresses", .{ .activated = self.list.activated() });
    defer menu.end();
    self.list.commands(&menu);
    menu.separator();
    const target = self.list.selectedTarget();
    const one = target != null;
    const accesses = &self.wb.panels.accesses;
    if (menu.item(.{ .label = "Find what writes this", .chord = keys.what_writes, .enabled = one, .tooltip = "Lists every instruction that writes it, next to the entry" })) {
        accesses.start(target.?.address, target.?.len, .writes, target.?.name);
    }
    if (menu.item(.{ .label = "Find what reads this", .chord = keys.what_reads, .enabled = one, .tooltip = "Lists every instruction that reads it, next to the entry" })) {
        accesses.start(target.?.address, target.?.len, .reads, target.?.name);
    }
    if (menu.item(.{ .label = "Stop all watches", .enabled = accesses.running() > 0, .tooltip = "Frees the CPU's four debug registers. What they found stays" })) accesses.stopAll();
    if (menu.item(.{ .label = "Show in memory", .chord = keys.show_memory, .enabled = one })) {
        self.wb.openMemory(target.?.address, target.?.len, .{ .start = target.?.address, .len = target.?.len });
    }
    if (menu.item(.{ .label = "Show as code", .chord = keys.show_code, .enabled = one })) self.wb.openCode(target.?.address);
    menu.separator();
    const files = self.wb.io != null;
    if (menu.item(.{ .label = "Export...", .chord = keys.export_file, .enabled = files, .tooltip = "What's picked, or all of it, to a .rwa.zon file" })) self.exportPicked();
    if (menu.item(.{ .label = "Import...", .chord = keys.import_file, .enabled = files, .tooltip = "Adds what's in a .rwa.zon file to the end" })) self.importPicked();
}

fn exportPicked(self: *Addresses) void {
    const path = self.wb.pickFile(.save, Workbench.FileType.addresses, "addresses" ++ Project.ext.addresses) orelse return;
    defer self.wb.allocator.free(path);
    _ = self.exportTo(path) catch |err| {
        self.wb.fail("Couldn't export them: {t}", .{err});
    };
}

fn importPicked(self: *Addresses) void {
    const path = self.wb.pickFile(.open, Workbench.FileType.addresses, "") orelse return;
    defer self.wb.allocator.free(path);
    _ = self.importFrom(path) catch |err| {
        self.wb.fail("Couldn't import them: {t}", .{err});
    };
}

/// What's picked, or all of it. Returns how many.
pub fn exportTo(self: *Addresses, path: []const u8) !usize {
    if (path.len == 0) return error.NoPath;
    const io = self.wb.io orelse return error.NoFiles;
    const allocator = self.wb.allocator;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const items = try self.list.pickedItems(arena.allocator());

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    std.zon.stringify.serialize(AddressList.Saved{ .items = items }, .{}, &out.writer) catch return error.OutOfMemory;
    out.writer.writeByte('\n') catch return error.OutOfMemory;
    const text = try out.toOwnedSlice();
    defer allocator.free(text);

    try core.files.write(io, path, text, .{ .make_dir = true });
    return items.len;
}

pub fn importFrom(self: *Addresses, path: []const u8) !usize {
    if (path.len == 0) return error.NoPath;
    const io = self.wb.io orelse return error.NoFiles;
    var arena: std.heap.ArenaAllocator = .init(self.wb.allocator);
    defer arena.deinit();

    var reading = try io.concurrent(readFile, .{ io, arena.allocator(), path });
    const source = try reading.await(io);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const saved = std.zon.parse.fromSlice(AddressList.Saved, .{
        .gpa = self.wb.allocator,
        .arena = arena.allocator(),
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| {
        if (err == error.ParseZon) log.warn("{f}", .{diagnostics.fmt(path)});
        return err;
    };
    try self.list.append(saved.items);
    return saved.items.len;
}

fn readFile(io: std.Io, arena: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, arena, .limited(16 << 20), .of(u8), 0);
}
