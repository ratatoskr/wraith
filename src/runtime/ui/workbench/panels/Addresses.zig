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
const api = @import("wraith_api");
const Kind = @import("tuft_mem").values.Kind;
const RwLock = @import("tuft_sys").sync.RwLock;
const log = core.log.scoped(.wraith_ui);

wb: *Workbench,
list: AddressList,
/// Its hotkeys, in the game's keybinds.
keys: AddressKeys,
/// Hands holds and hotkeys from the render thread to the workbench's thread once it starts.
live_lock: RwLock = .{},
/// Its thread ticks it now. Under `live_lock`.
handed_over: bool = false,
split: ui.Split = .{ .ratio = 0.55 },
/// Where the list lives. Without one it only lasts as long as the game.
project: ?*Project = null,
/// When names were last worked out again, so listings name what moved.
refreshed_ns: u64 = 0,
/// The schemas the project, plugins and scripts share, for typed entries.
shared: std.ArrayList(Shared) = .empty,
/// Those, project first so its types win. Sources are "" for the project's, else the plugin.
schemas: std.ArrayList(*const Schema) = .empty,
sources: std.ArrayList([]const u8) = .empty,
/// `SharedSchemas` as last read.
plugins_generation: u32 = 0,
/// Why one of them didn't parse, last time they were read. Empty if they all did.
parse_problem: @import("tuft_text").Message(256) = .{},

const refresh_ns = std.time.ns_per_s / 2;

pub fn useProject(self: *Addresses, project: *Project) void {
    self.project = project;
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
    const saved = Names.parseList(arena.allocator(), text) catch |err| {
        log.warn("Couldn't read the project's address list: {t}", .{err});
        return;
    };
    self.list.load(saved.items) catch |err| log.warn("Couldn't load the address list: {t}", .{err});
}

pub fn deinit(self: *Addresses) void {
    const gpa = self.wb.allocator;
    self.keys.deinit();
    self.list.deinit();
    freeShared(&self.shared, gpa);
    self.schemas.deinit(gpa);
    self.sources.deinit(gpa);
}

/// A schema a plugin or script shared, parsed for us.
const Shared = struct {
    parsed: Parsed,
    /// Its plugin, in the parse's arena.
    group: []const u8,
    /// Wraith's own types come first, as plugins' are read. Ones before here are those.
    own_from: usize = 0,
    /// Wraith's own, alone.
    wraith: bool = false,

    /// The project's first, so its types win, then Wraith's, so they're named after it.
    fn rank(self: Shared) u2 {
        if (self.group.len == 0) return 0;
        return if (self.wraith) 1 else 2;
    }
};

/// What plugins' schemas are read after, so theirs can use its types, like `Vec3`.
const wraith_prefix = api.wraith_sal ++ "\n";

fn freeShared(shared: *std.ArrayList(Shared), gpa: std.mem.Allocator) void {
    for (shared.items) |*p| p.parsed.deinit();
    shared.deinit(gpa);
}

/// Reads the shared schemas again if they changed.
fn readSchemas(self: *Addresses) void {
    const gpa = self.wb.allocator;
    const shared = self.readShared() orelse return;
    std.mem.sort(Shared, shared.items, {}, struct {
        fn before(_: void, a: Shared, b: Shared) bool {
            return a.rank() < b.rank();
        }
    }.before);
    // The list lets go of the old ones before they're freed
    var schemas: std.ArrayList(*const Schema) = .empty;
    var sources: std.ArrayList([]const u8) = .empty;
    var from: std.ArrayList(usize) = .empty;
    defer from.deinit(gpa);
    for (shared.items) |*p| {
        // Every plugin's has Wraith's types already, so they aren't offered on their own
        if (p.wraith) continue;
        schemas.append(gpa, &p.parsed.schema) catch {};
        sources.append(gpa, p.group) catch {};
        from.append(gpa, p.own_from) catch {};
    }
    if (schemas.items.len != sources.items.len) sources.clearRetainingCapacity();
    self.list.setSchemasFrom(schemas.items, sources.items, if (from.items.len == schemas.items.len) from.items else &.{});
    self.schemas.deinit(gpa);
    self.sources.deinit(gpa);
    self.schemas = schemas;
    self.sources = sources;
    freeShared(&self.shared, gpa);
    self.shared = shared;
}

/// The shared schemas parsed again, or null if unchanged. Each is ours, so a plugin going just drops them.
fn readShared(self: *Addresses) ?std.ArrayList(Shared) {
    const now = SharedSchemas.global.generation();
    if (now == self.plugins_generation) return null;
    self.plugins_generation = now;
    const gpa = self.wb.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    self.parse_problem = .{};
    var parsed: std.ArrayList(Shared) = .empty;
    const entries = SharedSchemas.global.copy(arena.allocator()) catch return parsed;
    if (entries.len > 0) wraith: {
        var diag: Schema.Diagnostic = .{};
        var one = salamander_schema.parse(gpa, api.wraith_sal, sal_options, &diag) catch break :wraith;
        parsed.append(gpa, .{ .parsed = one, .group = "wraith", .wraith = true }) catch one.deinit();
    }
    for (entries) |e| {
        var diag: Schema.Diagnostic = .{};
        // With Wraith's types before it, else alone for any that clash. Its own file, so not in Wraith's namespace
        const own = if (std.mem.startsWith(u8, e.text, Schema.bundle_marker)) e.text else salamander_schema.bundle(arena.allocator(), &.{.{ .name = e.name, .text = e.text }}) catch continue;
        const with = std.mem.concat(arena.allocator(), u8, &.{ wraith_prefix, own }) catch continue;
        var own_from: usize = wraith_prefix.len;
        var one = salamander_schema.parse(gpa, with, sal_options, &diag) catch alone: {
            own_from = 0;
            break :alone salamander_schema.parse(gpa, e.text, sal_options, &diag) catch {
                log.debug("{s} from {s} doesn't parse: {s}", .{ e.name, e.group, diag.message() });
                self.parse_problem.print("{s}'s schemas don't parse: {s}", .{ e.group, diag.message() });
                continue;
            };
        };
        const group = one.arena.allocator().dupe(u8, e.group) catch "";
        parsed.append(gpa, .{ .parsed = one, .group = group, .own_from = own_from }) catch {
            one.deinit();
            break;
        };
    }
    return parsed;
}

/// Writes the list to the project, which names its ids from there, see `host.projects`.
pub fn changed(self: *Addresses) void {
    var arena: std.heap.ArenaAllocator = .init(self.wb.allocator);
    defer arena.deinit();
    const items = self.list.items(arena.allocator()) catch |err| {
        log.warn("Couldn't keep the address list: {t}", .{err});
        return;
    };
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

/// Before the workbench's thread starts, or back if it couldn't. Waits for a render thread tick in flight.
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
    self.wb.focus(.addresses, null);
}

/// Like a name from the Names panel, as the user's own.
pub fn addItem(self: *Addresses, item: AddressList.Item) void {
    self.list.addItem(item) catch |err| {
        log.warn("Couldn't add to the address list: {t}", .{err});
        return;
    };
    self.wb.focus(.addresses, null);
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
