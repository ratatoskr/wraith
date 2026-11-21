//! Settings service. Each is a setting in the registry, its id the plugin's name then its own,
//! listed under the plugin in Wraith's Settings.

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const Registry = @import("../settings/Registry.zig");

const log = core.log.scoped(.wraith_plugin);
const allocator = std.heap.page_allocator;

/// Null before the runtime's up.
var registry: ?*Registry = null;

pub fn setRegistry(r: ?*Registry) void {
    registry = r;
}

const sal = api.salamander;
const W = api.wraith;
const Definition = W.SettingDefinition;
const Value = W.SettingValue;
/// What `Settings.add` takes to call after a change, from `settings.sal`.
pub const Changed = ?W.SettingChanged;

pub const Record = struct {
    loaded: *Loaded,
    changed: Changed,
    /// Its `Setting` table, for passing itself to `changed`.
    table: *const anyopaque,
    setting: ?*Registry.Setting = null,
    /// What `get` gave as text last.
    text: []u8 = &.{},

    fn onChange(ctx: *anyopaque, _: *Registry.Setting) void {
        const self: *Record = @ptrCast(@alignCast(ctx));
        if (self.changed) |f| f.invoke(.{.{ .data = @intFromPtr(self), .table = self.table }});
    }

    /// Its saved value stays.
    pub fn stop(self: *Record) void {
        const setting = self.setting orelse return;
        if (registry) |r| r.remove(setting);
        self.setting = null;
        // Won't be called again
        if (self.changed) |f| {
            f.release();
            self.changed = null;
        }
    }

    pub fn free(self: *Record) void {
        self.stop();
        allocator.free(self.text);
        allocator.destroy(self);
    }
};

var records: host.Owned(Record) = .{};

const Common = struct {
    id: []const u8,
    name: []const u8,
    help: []const u8,
    section: []const u8,
    scope: api.Scope,
    restart: bool,
};

fn register(r: *Registry, loaded: *Loaded, changed: Changed, table: *const anyopaque, def: Common, kind: Registry.Kind) api.SettingError!*Record {
    if (!validId(def.id)) return error.InvalidId;
    var id_buf: [160]u8 = undefined;
    const id = std.fmt.bufPrint(&id_buf, "{s}.{s}", .{ loaded.name, def.id }) catch return error.InvalidId;
    const record = try allocator.create(Record);
    record.* = .{ .loaded = loaded, .changed = changed, .table = table };
    record.setting = r.add(.{
        .id = id,
        .name = if (def.name.len > 0) def.name else def.id,
        .help = def.help,
        .group = loaded.displayName(),
        .section = def.section,
        .scope = switch (def.scope) {
            .global => .global,
            .game => .game,
        },
        .restart = def.restart,
        .kind = kind,
    }, .{ .changed = .{ .ctx = record, .call = Record.onChange } }) catch |err| {
        allocator.destroy(record);
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.AlreadyAdded => error.AlreadyAdded,
        };
    };
    records.add(record) catch |err| {
        // Not `free`, since the callback's still the caller's
        if (record.setting) |st| r.remove(st);
        allocator.destroy(record);
        return if (err == error.OutOfMemory) error.OutOfMemory else error.SettingFailed;
    };
    return record;
}

pub const TypedError = error{ Unavailable, InvalidDefinition, InvalidId, AlreadyAdded, InvalidValue, Failed };

fn typedError(err: api.SettingError) TypedError {
    return switch (err) {
        error.SettingsUnavailable => error.Unavailable,
        error.InvalidDefinition => error.InvalidDefinition,
        error.InvalidId => error.InvalidId,
        error.AlreadyAdded => error.AlreadyAdded,
        error.InvalidValue => error.InvalidValue,
        error.OutOfMemory, error.SettingFailed => error.Failed,
    };
}

pub fn add(loaded: *Loaded, def: Definition, changed: Changed, table: *const anyopaque) TypedError!*Record {
    const r = registry orelse return error.Unavailable;
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const kind = kindOfTyped(arena.allocator(), def) catch return error.Failed;
    return register(r, loaded, changed, table, .{
        .id = def.id,
        .name = def.name,
        .help = def.help,
        .section = def.section,
        .scope = switch (def.scope) {
            .game => .game,
            else => .global,
        },
        .restart = def.restart,
    }, kind orelse return error.InvalidDefinition) catch |err| typedError(err);
}

/// Null if the default doesn't fit the kind. Options point into `a`, which the registry copies.
fn kindOfTyped(a: std.mem.Allocator, def: Definition) error{OutOfMemory}!?Registry.Kind {
    const d = def.default_value;
    return switch (def.kind) {
        .toggle => .{ .toggle = def.has_default and d.toggle },
        .number => blk: {
            if (!(def.min <= def.max)) break :blk null;
            const v = if (def.has_default) d.number else def.min;
            break :blk .{ .number = .{ .default = std.math.clamp(v, def.min, def.max), .min = def.min, .max = def.max, .step = def.step } };
        },
        .choice => blk: {
            const options = try a.alloc([]const u8, def.options.len);
            for (def.options, options) |o, *to| to.* = o;
            if (options.len == 0) break :blk null;
            const chosen = if (def.has_default) d.text else options[0];
            for (options) |o| {
                if (std.mem.eql(u8, o, chosen)) break;
            } else break :blk null;
            break :blk .{ .choice = .{ .default = chosen, .options = options } };
        },
        .text => .{ .text = if (def.has_default) d.text else "" },
        .colour => .{ .colour = if (def.has_default) .{ d.colour.r, d.colour.g, d.colour.b, d.colour.a } else .{ 1, 1, 1, 1 } },
        .path => .{ .path = .{
            .default = if (def.has_default) d.text else "",
            .file = def.file,
            .extension = def.extension,
            .placeholder = def.placeholder,
        } },
        else => null,
    };
}

pub fn get(record: *Record) TypedError!Value {
    const r = registry orelse return error.Unavailable;
    const setting = record.setting orelse return error.Failed;
    var out: Value = std.mem.zeroes(Value);
    switch (r.get(setting)) {
        .toggle => |b| out.toggle = b,
        .number => |n| out.number = n,
        .choice, .text, .path => |t| {
            const copy = allocator.dupe(u8, t) catch return error.Failed;
            allocator.free(record.text);
            record.text = copy;
            out.text = copy;
        },
        .colour => |c| out.colour = .{ .r = c[0], .g = c[1], .b = c[2], .a = c[3] },
        .key => return error.Failed,
    }
    return out;
}

pub fn set(record: *Record, value: Value) TypedError!void {
    const r = registry orelse return error.Unavailable;
    const setting = record.setting orelse return error.Failed;
    const v: Registry.Value = switch (setting.def.kind) {
        .toggle => .{ .toggle = value.toggle },
        .number => .{ .number = value.number },
        .choice => .{ .choice = value.text },
        .text => .{ .text = value.text },
        .path => .{ .path = value.text },
        .colour => .{ .colour = .{ value.colour.r, value.colour.g, value.colour.b, value.colour.a } },
        .key => return error.InvalidValue,
    };
    r.set(setting, v) catch |err| return switch (err) {
        error.WrongKind, error.NotAnOption, error.InvalidChord => error.InvalidValue,
        else => error.Failed,
    };
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    return true;
}

const tests = struct {
    const testing = std.testing;

    test "a plugin's setting, through settings.sal" {
        const sdk = @import("wraith_sdk");
        const r = try Registry.create(testing.allocator, .{});
        defer r.destroy();
        setRegistry(r);
        defer setRegistry(null);
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        loaded.manifest.value.title = "Kai";
        sdk.Owner.attach(loaded.root());

        const Seen = struct {
            changes: u32 = 0,
            fn changed(self: *@This(), _: W.Setting) void {
                self.changes += 1;
            }
        };
        var seen: Seen = .{};
        const list = sdk.wraith.root().?.settings();
        const fov = try list.add(.{ .id = "fov", .name = "Field of view", .kind = .number, .min = 60, .max = 120, .has_default = true, .default_value = .{ .number = 90 }, .scope = .game }, W.SettingChanged.init(&seen, Seen.changed));
        const mode = try list.add(.{ .id = "mode", .kind = .choice, .options = &.{ "fast", "slow" } }, null);
        try testing.expectError(error.AlreadyAdded, list.add(.{ .id = "fov", .kind = .toggle }, null));
        try testing.expectError(error.InvalidId, list.add(.{ .id = "no spaces", .kind = .toggle }, null));

        // Listed under the plugin's title, for just this game
        const listed = r.find("kai.fov").?;
        try testing.expectEqualStrings("Kai", listed.def.group);
        try testing.expectEqual(.game, listed.def.scope);
        try testing.expectEqual(90, (try fov.get()).number);

        try fov.set(.{ .number = 200 });
        try testing.expectEqual(120, (try fov.get()).number);
        try testing.expectEqual(1, seen.changes);
        // From Wraith's Settings too
        try r.set(listed, .{ .number = 75 });
        try testing.expectEqual(2, seen.changes);
        try testing.expectEqual(75, (try fov.get()).number);

        try testing.expectEqualStrings("fast", (try mode.get()).text);
        try mode.set(.{ .text = "slow" });
        try testing.expectEqualStrings("slow", (try mode.get()).text);
        try testing.expectError(error.InvalidValue, mode.set(.{ .text = "medium" }));

        // A folder, empty till it's picked
        const folder = try list.add(.{ .id = "folder", .kind = .path, .placeholder = "Pictures" }, null);
        try testing.expectEqualStrings("", (try folder.get()).text);
        try testing.expectEqualStrings("Pictures", r.find("kai.folder").?.def.kind.path.placeholder);
        try folder.set(.{ .text = "C:\\shots" });
        try testing.expectEqualStrings("C:\\shots", (try folder.get()).text);

        // Gone with the plugin, its value kept
        loaded.deinitForTest();
        sdk.Owner.detach();
        try testing.expectEqual(null, r.find("kai.fov"));
        try testing.expectEqual(75, r.stores[1].values.get("kai.fov").?.number);
    }
};

test {
    _ = tests;
}
