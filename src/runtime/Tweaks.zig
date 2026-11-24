//! The project's tweaks, `tweaks/*.rwt`, installed project mods' and ones plugins add. Each runs in a script session of
//! its own while it's on, workbench open or not, and its key turns it on and off or runs an
//! action. Its data fields are kept per game and go in when it starts. While it's on they're read
//! from and written to the game's memory.
//!
//! A group's file is listed once for the group, with its shared part's fields, then once for each
//! of its tweaks and nested groups, named by their path like `file/Title` or `file/Combat/Title`.
//! A group's own box turns what's in it on or off as its `@children` says.
//!
//! This is the front. What the tweaks are lives in `tweaks/definitions.zig`, what's kept in
//! `tweaks/values.zig`, running them in `tweaks/running.zig` and keys in `tweaks/bindings.zig`.

const Tweaks = @This();

const std = @import("std");

const api = @import("wraith_api");
const input = @import("wraith_platform").input;
const Registry = @import("settings/Registry.zig");
const log = @import("wraith_core").log.scoped(.wraith_runtime);
const Atomic = @import("tuft_arch").atomic.Value;
const sync = @import("tuft_sys").sync;

const Project = @import("Project.zig");
const GameSettings = @import("GameSettings.zig");
const messages = @import("host/messages.zig");
const definitions = @import("tweaks/definitions.zig");
const values = @import("tweaks/values.zig");
const running = @import("tweaks/running.zig");
const bindings = @import("tweaks/bindings.zig");
const switching = @import("host/tweaks.zig");

const format = api.tweak;
const Settings = GameSettings.Tweaks;

pub const Tweak = @import("tweaks/Tweak.zig");
pub const Field = Tweak.Field;
pub const fit = values.fit;
pub const copySettings = values.copySettings;

pub const Env = struct {
    context: ?*anyopaque = null,
    /// Can run code in `language`, like `"js"`, now. Asks for its provider if not.
    ready: *const fn (context: ?*anyopaque, language: []const u8) bool = alwaysReady,
    publish: *const fn (topic: []const u8, payload: []const u8) anyerror!void = publishRuntime,
    /// Keep the settings, which are only good during the call.
    save: *const fn (context: ?*anyopaque, settings: Settings) void = ignoreSave,
    /// Its key turned one on or off, or ran an action. For saying so. The title's only good
    /// during the call.
    keyed: *const fn (context: ?*anyopaque, title: []const u8, now: Keyed) void = ignoreKeyed,

    fn alwaysReady(_: ?*anyopaque, _: []const u8) bool {
        return true;
    }

    fn publishRuntime(topic: []const u8, payload: []const u8) anyerror!void {
        return messages.publishFromRuntime(topic, payload);
    }

    fn ignoreSave(_: ?*anyopaque, _: Settings) void {}

    fn ignoreKeyed(_: ?*anyopaque, _: []const u8, _: Keyed) void {}
};

pub const Keyed = enum { on, off, ran };

/// A copy for views.
pub const Info = struct {
    name: []const u8,
    /// Its `@tweak`, else its name.
    title: []const u8,
    path: []const u8,
    /// Its path in its group's file, like `Combat/Max HP`. Empty for a whole file.
    part: []const u8 = "",
    /// Where it's from. Only your project's have a file to edit.
    source: Tweak.Source.Kind = .project,
    /// The mod's or plugin's id, empty for your project's.
    source_id: []const u8 = "",
    source_title: []const u8 = "",
    /// A group, the file's or one nested in it, with what's in it after it.
    is_group: bool = false,
    /// The name of the group it's in.
    group: ?[]const u8 = null,
    /// A plugin's heading for it. Empty for none.
    section: []const u8 = "",
    /// An action that opens something of a plugin's, like a window.
    opens: bool = false,
    /// How many groups it's in, for indenting.
    depth: u32 = 0,
    mode: format.Mode,
    /// Its own box. A group's doesn't count what's in it.
    on: bool,
    /// A group that's off with something in it on, which keeps its shared part up.
    partial: bool = false,
    running: bool,
    key: ?input.Chord,
    /// Yours, not the project's.
    own_key: bool,
    problem: ?[]const u8,
    fields: []const FieldInfo,
};

pub const FieldInfo = struct {
    name: []const u8,
    label: []const u8,
    type: format.Type,
    toggle: bool,
    hex: bool,
    min: ?f64,
    max: ?f64,
    key: ?input.Chord,
    value: f64,
    /// In the game's memory now, not only kept for next time.
    live: bool,
    choices: []const format.Choice,
};

allocator: std.mem.Allocator,
project: *Project,
/// Where their keys are. Null in tests, where they have none.
registry: ?*Registry,
env: Env,
/// Over everything below. Key callbacks don't take it.
lock: sync.RwLock = .{},
list: std.ArrayList(*Tweak) = .empty,
seen_version: u32 = 0,
/// The plugin tweaks' version last seen.
plugins_seen: u32 = 0,
/// Installed project mods for this game, read already, in `mods_arena`. Under `lock`.
mods: []const ModProject = &.{},
mods_arena: ?std.heap.ArenaAllocator = null,
/// Bumped by `setMods`, from any thread.
mods_version: Atomic(u32) = .init(0),
mods_seen: u32 = 0,
kept: values.Kept,
next_session: u32 = running.first_session,
subscription: ?messages.RuntimeSubscription = null,
/// For plugins, made outside the lock since they can add and remove from inside.
calls: std.ArrayList(running.PluginCall) = .empty,
/// Bumped when the list or a tweak changes, so views can catch up.
generation: Atomic(u32) = .init(1),
/// Every box as of the last tick, for scripts' `tweaks.isOn` and `setOn`.
switches: switching.Switches = .{},
/// The generation `switches` last caught up with.
switches_seen: u32 = 0,

/// An installed project mod. Its tweak files are named `id:file`, like a plugin's `plugin:id`, so
/// what's kept for them outlasts updates.
pub const ModProject = struct {
    id: []const u8,
    title: []const u8,
    /// Its `tweaks/*.rwt`, by path like `tweaks/speed.rwt`.
    files: []const ModFile,
    /// Its `schemas/*.sal`, named like `schemas/game.sal`.
    schemas: []const @import("host/projects.zig").File = &.{},
    /// Its address list as saved.
    addresses: ?[]const u8 = null,
};

pub const ModFile = struct {
    path: []const u8,
    text: []const u8,
};

/// What's installed now, copied. Any thread. Their tweaks show up on the next tick. One updated
/// turns off what was on in it, reads it again and turns that back on.
pub fn setMods(self: *Tweaks, mods: []const ModProject) !void {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const copy = try a.alloc(ModProject, mods.len);
    for (mods, copy) |m, *c| c.* = .{
        .id = try a.dupe(u8, m.id),
        .title = try a.dupe(u8, m.title),
        .files = try copyFiles(a, m.files),
        .schemas = try copySchemas(a, m.schemas),
        .addresses = if (m.addresses) |text| try a.dupe(u8, text) else null,
    };
    self.lock.lock();
    defer self.lock.unlock();
    if (self.mods_arena) |*old| old.deinit();
    self.mods_arena = arena;
    self.mods = copy;
    _ = self.mods_version.fetchAdd(1, .release);
}

fn copyFiles(a: std.mem.Allocator, from: []const ModFile) ![]const ModFile {
    const out = try a.alloc(ModFile, from.len);
    for (from, out) |f, *to| to.* = .{ .path = try a.dupe(u8, f.path), .text = try a.dupe(u8, f.text) };
    return out;
}

fn copySchemas(a: std.mem.Allocator, from: []const @import("host/projects.zig").File) ![]const @import("host/projects.zig").File {
    const out = try a.alloc(@import("host/projects.zig").File, from.len);
    for (from, out) |f, *to| to.* = .{ .name = try a.dupe(u8, f.name), .text = try a.dupe(u8, f.text) };
    return out;
}

/// Under the lock. A file's text, the project's or a mod's. The caller frees it.
pub fn readFile(self: *Tweaks, mod: ?[]const u8, path: []const u8) ?[]u8 {
    const id = mod orelse return self.project.read(self.allocator, path) catch null;
    for (self.mods) |m| {
        if (!std.mem.eql(u8, m.id, id)) continue;
        for (m.files) |f| if (std.mem.eql(u8, f.path, path)) return self.allocator.dupe(u8, f.text) catch null;
    }
    return null;
}

/// Under the lock. Where it's from, for headings.
pub fn sourceTitle(self: *const Tweaks, t: *const Tweak) []const u8 {
    return switch (t.source.kind) {
        .project => "Your project",
        .mod => self.modTitle(t.source.id) orelse t.source.id,
        .plugin => t.source.title,
    };
}

/// Under the lock. A mod's title, by id.
pub fn modTitle(self: *const Tweaks, id: []const u8) ?[]const u8 {
    for (self.mods) |m| if (std.mem.eql(u8, m.id, id)) return m.title;
    return null;
}

pub fn create(allocator: std.mem.Allocator, project: *Project, registry: ?*Registry, settings: Settings, env: Env) !*Tweaks {
    const self = try allocator.create(Tweaks);
    self.* = .{ .allocator = allocator, .project = project, .registry = registry, .env = env, .kept = undefined };
    self.kept.init(allocator, settings);
    self.subscription = messages.subscribeRuntime(self, running.onMessage) catch null;
    definitions.refresh(self);
    self.publishSwitches();
    switching.useSwitches(&self.switches, null);
    return self;
}

/// Stops them all.
pub fn destroy(self: *Tweaks) void {
    switching.useSwitches(null, &self.switches);
    if (self.subscription) |s| s.unsubscribe();
    if (self.kept.changed_ns != null) self.persist();
    running.stopAll(self);
    // What's in a group's file points into the file's arena, so it goes first
    var i: usize = 0;
    while (i < self.list.items.len) {
        const t = self.list.items[i];
        if (t.file == null) {
            i += 1;
            continue;
        }
        _ = self.list.swapRemove(i);
        definitions.freeTweak(self, t);
    }
    for (self.list.items) |t| definitions.freeTweak(self, t);
    self.list.deinit(self.allocator);
    self.calls.deinit(self.allocator);
    if (self.mods_arena) |*a| a.deinit();
    @import("host/projects.zig").keep(&.{});
    self.switches.deinit();
    self.kept.deinit();
    self.allocator.destroy(self);
}

/// Render thread, each frame.
pub fn tick(self: *Tweaks) void {
    if (definitions.stale(self)) definitions.refresh(self);
    const settled = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        break :blk self.kept.settled();
    };
    if (settled) self.persist();
    bindings.handlePresses(self);
    // What scripts asked for, like clicks, so they never run inside a script's callback
    var asked = self.switches.take();
    defer switching.Switches.freeAll(&asked);
    for (asked.items) |s| self.setOn(s.name, s.on);
    running.tick(self);
    self.publishSwitches();
}

/// Catches `switches` up and tells everyone which boxes changed.
fn publishSwitches(self: *Tweaks) void {
    const now_generation = self.version();
    if (now_generation == self.switches_seen) return;
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var switched: std.ArrayList(switching.Switches.Switch) = .empty;
    {
        self.lock.lock();
        defer self.lock.unlock();
        const now = a.alloc(switching.Switches.Switch, self.list.items.len) catch return;
        for (self.list.items, now) |t, *s| s.* = .{ .name = t.name, .on = t.isOn() };
        self.switches.update(now, a, &switched) catch return;
    }
    self.switches_seen = now_generation;
    for (switched.items) |s| {
        const json = std.json.Stringify.valueAlloc(a, api.TweakSwitched{ .name = s.name, .on = s.on }, .{}) catch continue;
        self.env.publish(api.script.topics.switched, json) catch {};
        switching.announce(s.name, s.on);
    }
}

pub fn version(self: *const Tweaks) u32 {
    return self.generation.load(.acquire);
}

/// Allocated in `arena`.
pub fn snapshot(self: *Tweaks, arena: std.mem.Allocator) ![]Info {
    self.lock.lock();
    defer self.lock.unlock();
    const out = try arena.alloc(Info, self.list.items.len);
    for (self.list.items, out) |t, *info| {
        const fields = try arena.alloc(FieldInfo, t.fields.len);
        for (t.fields, fields) |*f, *fi| {
            const d = f.def;
            const now = running.readLive(t, d.*);
            const choices = if (t.liveField(d.name)) |l| l.choices orelse d.choices else d.choices;
            fi.* = .{
                .name = try arena.dupe(u8, d.name),
                .label = try arena.dupe(u8, d.label),
                .type = d.type,
                .toggle = d.toggle,
                .hex = d.hex,
                .min = d.min,
                .max = d.max,
                .key = f.key,
                .value = now orelse self.kept.stored(t.name, d.*),
                .live = now != null,
                .choices = try definitions.copyChoices(arena, choices),
            };
        }
        info.* = .{
            .name = try arena.dupe(u8, t.name),
            .title = try arena.dupe(u8, t.title()),
            .path = try arena.dupe(u8, t.path),
            .part = try arena.dupe(u8, t.part),
            .source = t.source.kind,
            .source_id = try arena.dupe(u8, t.source.id),
            .source_title = try arena.dupe(u8, self.sourceTitle(t)),
            .is_group = t.is_group,
            .group = if (t.group) |g| try arena.dupe(u8, g.name) else null,
            .section = try arena.dupe(u8, t.section),
            .opens = t.opens,
            .depth = t.depth(),
            .mode = t.def.mode,
            .on = t.isOn(),
            .partial = t.is_group and !t.own and running.anyInside(self, t),
            .running = t.state.started(),
            .key = bindings.keyOf(self, t.setting),
            .own_key = if (t.setting) |s| if (self.registry) |r| !r.isDefault(s) else false else false,
            .problem = if (t.problem) |p| try arena.dupe(u8, p) else if (t.invalid) |p| try arena.dupe(u8, p) else null,
            .fields = fields,
        };
    }
    return out;
}

pub fn projectKeys(self: *Tweaks) bool {
    self.lock.lock();
    defer self.lock.unlock();
    return self.kept.settings.project_keys;
}

/// An action runs once for `true`. A group's box does what its `@children` says to what's in it.
pub fn setOn(self: *Tweaks, name: []const u8, on: bool) void {
    const save = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        var t = definitions.find(self, name) orelse {
            // Not listed yet, like just renamed. It comes on once it is
            if (on) self.kept.remember(name);
            return;
        };
        if (t.isOn() == on) return;
        if (on) {
            // As it is now, so the next refresh doesn't take it for an edit and turn it off
            _ = definitions.reparse(self, t, .keep);
            t = definitions.find(self, name) orelse return;
        }
        break :blk running.setOn(self, t, on);
    };
    if (save) self.persist();
}

/// Off with everything in it, whatever a group's `@children` says. For a whole file.
pub fn turnOff(self: *Tweaks, name: []const u8) void {
    {
        self.lock.lock();
        defer self.lock.unlock();
        const t = definitions.find(self, name) orelse return;
        running.turnOff(self, t);
        running.clearProblem(self, t);
        self.changed();
    }
    self.persist();
}

/// What its key does: on and off, or run an action.
pub fn toggle(self: *Tweaks, name: []const u8) void {
    const on = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        const t = definitions.find(self, name) orelse return;
        break :blk (!t.is_group and t.def.mode == .action) or !t.isOn();
    };
    self.setOn(name, on);
}

/// Runs it again as it is now, saved or not, if it's on. For after editing it. A group runs its
/// shared part and everything that's on in it again.
pub fn rerun(self: *Tweaks, name: []const u8) void {
    self.lock.lock();
    defer self.lock.unlock();
    var t = definitions.find(self, name) orelse return;
    if (!running.active(self, t)) return;
    _ = definitions.reparse(self, t, .keep);
    t = definitions.find(self, name) orelse return;
    if (t.is_group or t.state.wanted()) running.restart(self, t);
}

/// Kept for next time, and written to the game now if it's on. Fitted to the field first. Saved
/// once values stop changing.
pub fn setValue(self: *Tweaks, name: []const u8, field: []const u8, value: f64) void {
    self.lock.lock();
    defer self.lock.unlock();
    const t = definitions.find(self, name) orelse return;
    const d = t.def.field(field) orelse return;
    const v = fit(d.*, value);
    self.kept.keep(t.name, d.name, v) catch return;
    running.push(self, t, d.*, v);
    self.kept.touch();
    self.changed();
}

/// Back to the tweak's own value, which then follows the tweak if it changes.
pub fn resetValue(self: *Tweaks, name: []const u8, field: []const u8) void {
    self.lock.lock();
    defer self.lock.unlock();
    const t = definitions.find(self, name) orelse return;
    const d = t.def.field(field) orelse return;
    self.kept.forget(name, field);
    running.push(self, t, d.*, d.value);
    self.kept.touch();
    self.changed();
}

/// Your own key for it, over the project's, saved in the registry for this game. Null means no
/// key. Any more picked in Settings stay.
pub fn setKey(self: *Tweaks, name: []const u8, key: ?input.Chord) void {
    self.lock.lock();
    defer self.lock.unlock();
    const t = definitions.find(self, name) orelse return;
    const s = t.setting orelse return;
    const r = self.registry orelse return;
    const now = r.get(s).key;
    const keys: ?input.Keys = if (key) |k| (if (now) |n| n.replaced(0, k) else .one(k)) else null;
    r.set(s, .{ .key = keys }) catch |err| log.warn("Couldn't set the key for {s}: {t}", .{ name, err });
}

/// Back to the project's key.
pub fn clearKey(self: *Tweaks, name: []const u8) void {
    self.lock.lock();
    defer self.lock.unlock();
    const t = definitions.find(self, name) orelse return;
    const s = t.setting orelse return;
    const r = self.registry orelse return;
    r.reset(s) catch |err| log.warn("Couldn't reset the key for {s}: {t}", .{ name, err });
}

pub fn setProjectKeys(self: *Tweaks, on: bool) void {
    {
        self.lock.lock();
        defer self.lock.unlock();
        self.kept.settings.project_keys = on;
        bindings.apply(self);
    }
    self.persist();
}

/// For the parts in `tweaks/`. Views catch up on the next version.
pub fn changed(self: *Tweaks) void {
    _ = self.generation.fetchAdd(1, .release);
}

fn persist(self: *Tweaks) void {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const settings = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        break :blk self.kept.forSave(arena.allocator(), self.list.items) catch return;
    };
    self.env.save(self.env.context, settings);
}

const tests = struct {
    const testing = std.testing;
    const support = @import("tweaks/test_support.zig");

    test "on, off, edits and what's kept" {
        var s: support.Setup = try .init(&.{ .{ "tweaks/health.rwt", "@js\none" }, .{ "tweaks/speed.rwt", "@js\ntwo" } });
        defer s.deinit();

        var fake: support.Fake = .{};
        const tweaks = try create(testing.allocator, s.project, null, .{ .on = &.{"speed"} }, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        // On from the settings, run once the provider's there
        tweaks.tick();
        try testing.expectEqual(0, fake.runs);
        fake.ready = true;
        tweaks.tick();
        try testing.expectEqual(1, fake.runs);
        try testing.expectEqualStrings("@js\ntwo", fake.code());

        tweaks.setOn("health", true);
        try testing.expectEqual(2, fake.saved_on);
        tweaks.tick();
        try testing.expectEqual(2, fake.runs);

        // Edited, not saved, and run again as it is now, like the editor's Run again
        try s.project.write("tweaks/health.rwt", "@js\nchanged");
        tweaks.rerun("health");
        tweaks.tick();
        try testing.expectEqualStrings("@js\nchanged", fake.code());
        try testing.expect((try tweaks.snapshot(arena.allocator()))[0].on);

        tweaks.setOn("speed", false);
        try testing.expectEqual(1, fake.saved_on);
        s.project.delete("tweaks/health.rwt");
        tweaks.tick();
        const shown = try tweaks.snapshot(arena.allocator());
        try testing.expectEqual(1, shown.len);
        try testing.expectEqualStrings("speed", shown[0].name);
    }

    test "[Tweak] structs in tweak files' schemas list with them" {
        const struct_tweaks = @import("host/struct_tweaks.zig");
        var s: support.Setup = try .init(&.{
            .{ "tweaks/money.rwt", "@tweak \"Money\"\n@schema\n[Instance(\"90 90\"), Tweak(\"Bank\")] struct Bank { u32 mira; }\n@js\n" },
            // A group's shared part is in each of its tweaks', and shows once
            .{ "tweaks/kai.rwt", "@group \"Kai\"\n@schema\n[Instance(\"90 90\"), Tweak(\"Party\")] struct Party { u32 size; }\n@tweak \"One\"\n@schema\n[Instance(\"90 90\"), Tweak(\"Items\")] struct Items { u32 count; }\n@js\n@tweak \"Two\"\n@js\n" },
            .{ "tweaks/plain.rwt", "@schema\nstruct Nothing { u32 x; }\n@js\n" },
        });
        defer s.deinit();
        var fake: support.Fake = .{};
        {
            const tweaks = try create(testing.allocator, s.project, null, .{}, fake.env());
            defer tweaks.destroy();
            tweaks.tick();
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            const listed = struct_tweaks.snapshot(arena.allocator(), "");
            try testing.expectEqual(3, listed.len);
            for (listed) |e| {
                try testing.expectEqualStrings("", e.source);
                try testing.expectEqualStrings("Your project", e.source_title);
            }
        }
        try testing.expectEqual(0, struct_tweaks.count());
    }

    test "a project's schemas publish like a plugin's, the open one's and mods'" {
        const struct_tweaks = @import("host/struct_tweaks.zig");
        const Names = @import("Names.zig");
        const SharedSchemas = @import("SharedSchemas.zig");
        Names.global = .init(testing.allocator);
        defer Names.global.deinit();
        SharedSchemas.global = .init(testing.allocator);
        defer SharedSchemas.global.deinit();
        var s: support.Setup = try .init(&.{
            .{ "schemas/game.sal", "[Instance(\"90 90\"), Tweak(\"Bank\")] struct Bank { u32 mira; }\n[Sig(\"90 90 90\")] static u32 ticks;\n" },
            // Its own structs can use the project's types
            .{ "tweaks/money.rwt", "@schema\n[Instance(\"90 90\"), Tweak(\"Wallet\")] struct Wallet { Bank* bank; }\n@js\n" },
            .{ "addresses.rwa.zon", ".{ .items = .{ .{ .id = \"cash\", .address = \"0x20\" } } }" },
        });
        defer s.deinit();
        var fake: support.Fake = .{};
        const tweaks = try create(testing.allocator, s.project, null, .{}, fake.env());
        defer tweaks.destroy();
        tweaks.tick();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const listed = struct_tweaks.snapshot(arena.allocator(), "");
        try testing.expectEqual(2, listed.len);
        for (listed) |e| try testing.expectEqualStrings("", e.source);
        try testing.expect(Names.global.has(.schema, "ticks"));
        // Its address list's ids are yours, as you edit them
        try testing.expectEqual(0x20, try Names.global.get("cash"));
        try s.project.write("addresses.rwa.zon", ".{ .items = .{ .{ .id = \"cash\", .address = \"0x30\" } } }");
        tweaks.tick();
        try testing.expectEqual(0x30, try Names.global.get("cash"));
        try testing.expect(Names.global.has(.user, "cash"));

        // A mod's are named after it
        try tweaks.setMods(&.{.{ .id = "kai_tables", .title = "Kai Tables", .files = &.{}, .schemas = &.{
            .{ .name = "schemas/kai.sal", .text = "[Sig(\"90 90 90\")] static u32 level;\n" },
        }, .addresses = ".{ .items = .{ .{ .id = \"base\", .address = \"0x10\" } } }" }});
        tweaks.tick();
        try testing.expect(Names.global.has(.schema, "kai_tables.level"));
        try testing.expectEqual(0x10, try Names.global.get("kai_tables.base"));

        // And go when it does
        try tweaks.setMods(&.{});
        tweaks.tick();
        try testing.expect(!Names.global.has(.schema, "kai_tables.level"));
        try testing.expect(Names.global.has(.schema, "ticks"));
    }

    test "installed projects' tweaks, read-only, and kept on through an update" {
        var s: support.Setup = try .init(&.{.{ "tweaks/health.rwt", "@js\nmine" }});
        defer s.deinit();
        var fake: support.Fake = .{ .ready = true };
        const tweaks = try create(testing.allocator, s.project, null, .{}, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        try tweaks.setMods(&.{.{ .id = "kai_tables", .title = "Kai Tables", .files = &.{
            .{ .path = "tweaks/speed.rwt", .text = "@tweak \"Speed\"\n@js\nv1" },
            .{ .path = "notes.txt", .text = "not a tweak" },
        } }});
        tweaks.tick();
        const shown = try tweaks.snapshot(arena.allocator());
        try testing.expectEqual(2, shown.len);
        // The project's first, then the mod's, named after it
        try testing.expectEqualStrings("health", shown[0].name);
        try testing.expectEqual(.project, shown[0].source);
        try testing.expectEqualStrings("kai_tables:speed", shown[1].name);
        try testing.expectEqualStrings("kai_tables", shown[1].source_id);
        try testing.expectEqualStrings("Kai Tables", shown[1].source_title);
        try testing.expectEqualStrings("Speed", shown[1].title);

        tweaks.setOn("kai_tables:speed", true);
        tweaks.tick();
        try testing.expectEqualStrings("@tweak \"Speed\"\n@js\nv1", fake.code());

        // Updated: off, read again, and back on with the new code
        const stops = fake.stops;
        try tweaks.setMods(&.{.{ .id = "kai_tables", .title = "Kai Tables", .files = &.{
            .{ .path = "tweaks/speed.rwt", .text = "@tweak \"Speed\"\n@js\nv2" },
        } }});
        tweaks.tick();
        tweaks.tick();
        try testing.expect(fake.stops > stops);
        try testing.expectEqualStrings("@tweak \"Speed\"\n@js\nv2", fake.code());
        try testing.expect((try tweaks.snapshot(arena.allocator()))[1].on);

        // Uninstalled
        try tweaks.setMods(&.{});
        tweaks.tick();
        try testing.expectEqual(1, (try tweaks.snapshot(arena.allocator())).len);
    }

    test "scripts switch tweaks by name on the next tick, and hear about it" {
        var s: support.Setup = try .init(&.{.{ "tweaks/kai.rwt", "@group Kai\n@js\n@group Combat\n@children on\n@js\n@tweak One\n@js\n@tweak Two\n@js\n@end\n@tweak Three\n@js\n" }});
        defer s.deinit();
        var fake: support.Fake = .{ .ready = true };
        const tweaks = try create(testing.allocator, s.project, null, .{}, fake.env());
        defer tweaks.destroy();

        try testing.expect(!try switching.isOnNamed("kai/Combat"));
        try testing.expectError(error.NotFound, switching.setOnNamed("kai/Nope", true));
        // Asked for counts right away, but nothing happens until the tick
        try switching.setOnNamed("kai/Combat", true);
        try testing.expect(try switching.isOnNamed("kai/Combat"));
        try testing.expectEqual(0, fake.runs);
        tweaks.tick();
        // Its @children cascade, like a click
        try testing.expect(try switching.isOnNamed("kai/Combat/One"));
        try testing.expect(try switching.isOnNamed("kai/Combat/Two"));
        try testing.expect(!try switching.isOnNamed("kai/Three"));
        try testing.expectEqualStrings("kai/Combat on;kai/Combat/One on;kai/Combat/Two on;", fake.switched());

        // `on` only, so off leaves them, and a click is heard the same
        tweaks.setOn("kai/Combat", false);
        tweaks.tick();
        try testing.expect(try switching.isOnNamed("kai/Combat/One"));
        try testing.expect(std.mem.endsWith(u8, fake.switched(), "kai/Combat off;"));
    }
};

test {
    _ = tests;
    _ = @import("ModProjects.zig");
    _ = @import("ProjectManifest.zig");
    _ = definitions;
    _ = values;
    _ = running;
    _ = bindings;
}
