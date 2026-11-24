//! Where Wraith's settings live, and the runtime's own. Everything else that has settings, the game,
//! the shell and plugins, registers its own in the registry too. Values are kept in
//! `runtime/values.zon` for every game and `games/<id>/values.zon` for one.

const std = @import("std");
const builtin = @import("builtin");

const core = @import("wraith_core");
const memory = @import("tuft_mem");

pub const Registry = @import("settings/Registry.zig");
const Console = @import("Console.zig");
const Names = @import("Names.zig");

/// What Wraith's own settings are listed under.
pub const group = "Wraith";

pub const FrameStats = struct {
    /// How many seconds of frames the stats cover.
    window_seconds: f32 = 5,
    /// Frames this many times the median count as hitches.
    hitch_factor: f32 = 2,
};

pub fn applyLogLevel(level: std.log.Level) void {
    var filter = core.log.filter();
    filter.levels = core.log.Filter.atLeast(level);
    core.log.setFilter(filter);
}

pub fn rootAlloc(allocator: std.mem.Allocator, locations: core.Locations) ![]u8 {
    return locations.path(allocator, "settings");
}

/// For every game.
pub fn valuesPathAlloc(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "runtime", "values.zon" });
}

pub fn gameDirAlloc(allocator: std.mem.Allocator, root: []const u8, game_id: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ root, "games", game_id });
}

/// Just for that game.
pub fn gameValuesPathAlloc(allocator: std.mem.Allocator, game_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ game_dir, "values.zon" });
}

const level_names = [_][]const u8{ "Errors", "Warnings", "Info", "Debug" };

fn levelOf(name: []const u8) std.log.Level {
    for (level_names, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @fromBackingInt(@intCast(i));
    return .info;
}

/// The runtime's own: what it logs and whether it watches file access. Applied as they change.
pub const Own = struct {
    registry: *Registry,
    log_level: *Registry.Setting,
    console: *Registry.Setting,
    file_io: *Registry.Setting,
    ime: *Registry.Setting,
    sounds: *Registry.Setting,
    sources: *Registry.Setting,

    /// For `wraith.address_sources`, in the order of `sources_options`.
    const sources_options = [_][]const u8{ "Live, then snapshot, then disk", "Live, then snapshot", "Live only" };
    const sources_values = [_]memory.Sources{ .all, .{ .disk = false }, .live_only };

    pub fn add(registry: *Registry) !Own {
        const level: std.log.Level = if (builtin.mode == .debug) .debug else .info;
        const default_level = level_names[@backingInt(level)];
        const log_level = try registry.add(.{
            .id = "wraith.log_level",
            .name = "Log level",
            .help = "How much goes in the log. Debug is a lot, but it's what a bug report wants.",
            .group = group,
            .section = "Advanced",
            .kind = .{ .choice = .{ .default = default_level, .options = &level_names } },
        }, .{ .changed = .{ .ctx = registry, .call = logLevelChanged } });
        errdefer registry.remove(log_level);
        const console = try registry.add(.{
            .id = "wraith.console",
            .name = "Console window",
            .help = "Shows the log in a window of its own. Turning it off takes a restart.",
            .group = group,
            .section = "Advanced",
            .kind = .{ .toggle = false },
        }, .{ .changed = .{ .ctx = registry, .call = consoleChanged } });
        errdefer registry.remove(console);
        const file_io = try registry.add(.{
            .id = "wraith.file_io",
            .name = "Watch file access",
            .help = "Watches the files the game reads and writes, for the workbench's IO page, and lets plugins serve files. Turn it off if it clashes with this game or another mod.",
            .group = group,
            .section = "Advanced",
            .scope = .game,
            .restart = true,
            .kind = .{ .toggle = true },
        }, .{});
        errdefer registry.remove(file_io);
        const ime = try registry.add(.{
            .id = "wraith.ime",
            .name = "IME in the overlay",
            .help = "Lets the overlay's text boxes use the IME for typing Japanese, Chinese or Korean, even where the game switches it off, and puts its windows by the caret. Turn it off if it clashes with this game's own IME or another mod.",
            .group = group,
            .section = "Advanced",
            .scope = .game,
            .restart = true,
            .kind = .{ .toggle = true },
        }, .{});
        errdefer registry.remove(ime);
        const sounds = try registry.add(.{
            .id = "wraith.sounds",
            .name = "Sounds",
            .help = "Lets plugins and scripts play sounds, at the system's volume.",
            .group = group,
            .section = "Look & Feel",
            .kind = .{ .toggle = true },
        }, .{ .changed = .{ .ctx = registry, .call = soundsChanged } });
        errdefer registry.remove(sounds);
        const sources = try registry.add(.{
            .id = "wraith.address_sources",
            .name = "Find hooked code",
            .help = "Where signatures are looked for when they aren't in the game's code as it is now, like when another mod hooked it first. The snapshot is the code as Wraith started, disk is the game's exe. Plugins can say for themselves.",
            .group = group,
            .section = "Advanced",
            .scope = .game,
            .kind = .{ .choice = .{ .default = sources_options[0], .options = &sources_options } },
        }, .{ .changed = .{ .ctx = registry, .call = sourcesChanged } });
        const own: Own = .{ .registry = registry, .log_level = log_level, .console = console, .file_io = file_io, .ime = ime, .sounds = sounds, .sources = sources };
        Names.setDefaultSources(own.addressSources());
        return own;
    }

    pub fn remove(self: Own) void {
        self.registry.remove(self.log_level);
        self.registry.remove(self.console);
        self.registry.remove(self.file_io);
        self.registry.remove(self.ime);
        self.registry.remove(self.sounds);
        self.registry.remove(self.sources);
    }

    pub fn addressSources(self: Own) memory.Sources {
        return sourcesOf(self.registry.get(self.sources).choice);
    }

    fn sourcesOf(choice: []const u8) memory.Sources {
        for (sources_options, sources_values) |o, v| if (std.mem.eql(u8, o, choice)) return v;
        return .all;
    }

    fn sourcesChanged(ctx: *anyopaque, s: *Registry.Setting) void {
        const registry: *Registry = @ptrCast(@alignCast(ctx));
        Names.setDefaultSources(sourcesOf(registry.get(s).choice));
    }

    pub fn logLevel(self: Own) std.log.Level {
        return levelOf(self.registry.get(self.log_level).choice);
    }

    pub fn wantsConsole(self: Own) bool {
        return self.registry.get(self.console).toggle;
    }

    pub fn watchesFiles(self: Own) bool {
        return self.registry.get(self.file_io).toggle;
    }

    pub fn usesIme(self: Own) bool {
        return self.registry.get(self.ime).toggle;
    }

    pub fn playsSounds(self: Own) bool {
        return self.registry.get(self.sounds).toggle;
    }

    fn soundsChanged(ctx: *anyopaque, s: *Registry.Setting) void {
        const registry: *Registry = @ptrCast(@alignCast(ctx));
        @import("host/sound.zig").setEnabled(registry.get(s).toggle);
    }

    fn logLevelChanged(ctx: *anyopaque, s: *Registry.Setting) void {
        const registry: *Registry = @ptrCast(@alignCast(ctx));
        applyLogLevel(levelOf(registry.get(s).choice));
    }

    fn consoleChanged(ctx: *anyopaque, s: *Registry.Setting) void {
        const registry: *Registry = @ptrCast(@alignCast(ctx));
        if (registry.get(s).toggle) Console.show();
    }
};

const tests = struct {
    const testing = std.testing;

    test "settings root" {
        const a = testing.allocator;
        const locations = try core.Locations.init(a, .{ .root_override = "C:\\Wraith" });
        defer locations.deinit(a);
        const in_root = try rootAlloc(a, locations);
        defer a.free(in_root);
        try testing.expectEqualStrings("C:\\Wraith\\settings", in_root);

        const path = try valuesPathAlloc(a, "C:\\portable");
        defer a.free(path);
        try testing.expectEqualStrings("C:\\portable\\runtime\\values.zon", path);
    }

    test "the runtime's own apply as they change" {
        const saved = core.log.filter();
        defer core.log.setFilter(saved);
        const r = try Registry.create(testing.allocator, .{});
        defer r.destroy();
        const own = try Own.add(r);
        defer own.remove();
        try testing.expect(own.watchesFiles());
        try testing.expect(own.usesIme());
        try r.set(own.log_level, .{ .choice = "Warnings" });
        try testing.expectEqual(.warn, own.logLevel());
        try testing.expect(core.log.enabled(.warn, .wraith_runtime));
        try testing.expect(!core.log.enabled(.info, .wraith_runtime));
        try r.set(own.log_level, .{ .choice = "Debug" });
        try testing.expect(core.log.enabled(.debug, .wraith_runtime));
    }
};

test {
    _ = tests;
}
