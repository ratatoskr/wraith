//! Settings saved to disk as ZON.
//! File I/O runs on `Io` workers since std's Windows file calls need ~200 KB of stack.

const std = @import("std");

const files = @import("files.zig");
const log = @import("log.zig").scoped(.wraith_config);

pub fn Config(comptime T: type) type {
    validate(T);

    return struct {
        const Self = @This();

        /// Saved by `save` and on unload.
        value: T = .{},
        allocator: std.mem.Allocator,
        io: std.Io,
        arena: std.heap.ArenaAllocator,
        path: []u8,
        saver: files.Saver,

        fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Self {
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);
            self.* = .{
                .allocator = allocator,
                .io = io,
                .arena = .init(allocator),
                .path = try allocator.dupe(u8, path),
                .saver = .{ .allocator = allocator, .io = io, .options = .{ .replace = true }, .failed = logFailure },
            };
            errdefer allocator.free(self.path);

            var loading = try io.concurrent(loadInBackground, .{self});
            self.value = try loading.await(io);
            return self;
        }

        fn loadInBackground(self: *Self) !T {
            if (std.fs.path.dirname(self.path)) |dir| try std.Io.Dir.cwd().createDirPath(self.io, dir);
            return self.load();
        }

        /// On a read or parse error nothing changes, and we log and return it.
        pub fn reload(self: *Self) !void {
            self.finishPending();

            var fresh: std.heap.ArenaAllocator = .init(self.allocator);
            errdefer fresh.deinit();
            var reading = try self.io.concurrent(readInBackground, .{ self, fresh.allocator() });
            const value = reading.await(self.io) catch |err| switch (err) {
                error.FileNotFound => T{},
                else => return err,
            };

            self.arena.deinit();
            self.arena = fresh;
            self.value = value;
        }

        pub fn flush(self: *Self) !void {
            return self.saver.wait();
        }

        fn readInBackground(self: *Self, arena: std.mem.Allocator) !T {
            return self.read(arena);
        }

        /// Only errors if the write can't start. Use `flush` to see how it went.
        pub fn save(self: *Self) !void {
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            defer out.deinit();
            // Checking a big settings struct for recursion takes a lot of comptime branches
            @setEvalBranchQuota(10_000);
            std.zon.stringify.serialize(self.value, .{}, &out.writer) catch return error.OutOfMemory;
            out.writer.writeByte('\n') catch return error.OutOfMemory;
            try self.saver.save(self.path, out.written());
        }

        fn close(self: *Self) void {
            self.save() catch |err| log.err("Couldn't save settings to {s}: {t}", .{ self.path, err });
            self.discard();
        }

        fn discard(self: *Self) void {
            self.finishPending();
            const allocator = self.allocator;
            self.arena.deinit();
            allocator.free(self.path);
            allocator.destroy(self);
        }

        fn finishPending(self: *Self) void {
            self.flush() catch {};
        }

        fn logFailure(path: []const u8, err: anyerror) void {
            log.err("Couldn't save settings to {s}: {t}", .{ path, err });
        }

        /// A file that won't parse gets moved aside so the next save doesn't wipe the user's edits.
        fn load(self: *Self) T {
            return self.read(self.arena.allocator()) catch |err| switch (err) {
                error.FileNotFound => .{},
                error.ParseZon => {
                    self.moveAside();
                    return .{};
                },
                else => {
                    log.warn("Couldn't read {s} ({t}); using default settings", .{ self.path, err });
                    return .{};
                },
            };
        }

        fn read(self: *Self, arena: std.mem.Allocator) !T {
            const source = try std.Io.Dir.cwd().readFileAllocOptions(self.io, self.path, self.allocator, .limited(16 << 20), .of(u8), 0);
            defer self.allocator.free(source);

            var diagnostics: std.zon.parse.Diagnostics = undefined;
            // Same as `save`, checking a big settings struct takes a lot of comptime branches
            @setEvalBranchQuota(10_000);
            return std.zon.parse.fromSlice(T, .{
                .gpa = self.allocator,
                .arena = arena,
                .source = source,
                .diagnostics = &diagnostics,
                .ignore_unknown_fields = true,
            }) catch |err| {
                // Just a warning, the caller decides what to do
                if (err == error.ParseZon) log.warn("{f}", .{diagnostics.fmt(self.path)});
                return err;
            };
        }

        fn moveAside(self: *Self) void {
            const bad = std.mem.concat(self.allocator, u8, &.{ self.path, ".bad" }) catch return;
            defer self.allocator.free(bad);
            std.Io.Dir.renameAbsolute(self.path, bad, self.io) catch |err| {
                log.warn("Couldn't move unreadable settings aside: {t}", .{err});
                return;
            };
            log.warn("Using default settings; the unreadable file was moved to {s}", .{bad});
        }
    };
}

/// Only for whoever owns it, like the runtime or the SDK.
pub fn Lifecycle(comptime T: type) type {
    return struct {
        pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !*Config(T) {
            return Config(T).open(allocator, io, path);
        }

        pub fn close(cfg: *Config(T)) void {
            cfg.close();
        }

        pub fn discard(cfg: *Config(T)) void {
            cfg.discard();
        }
    };
}

fn validate(comptime T: type) void {
    const info = @typeInfo(T);
    if (info != .@"struct") @compileError("Settings must be a struct, found " ++ @typeName(T));
    for (info.@"struct".field_names, info.@"struct".field_attrs) |name, attrs| {
        if (attrs.default_value_ptr == null) {
            @compileError("Settings field `" ++ name ++ "` needs a default value (used on first run, and when a saved file predates the field)");
        }
    }
}

const tests = struct {
    const Mode = enum { off, low, high };

    const Settings = struct {
        enabled: bool = true,
        volume: f32 = 0.5,
        mode: Mode = .low,
        label: []const u8 = "default",
        window: struct { x: i32 = 10, y: i32 = 20 } = .{},
        hotkey: ?u8 = null,
    };

    const testing = std.testing;
    const io = testing.io;

    const Temp = struct {
        tmp: testing.TmpDir,
        root: [:0]u8,
        path: []u8,

        fn init() !Temp {
            var tmp = testing.tmpDir(.{});
            errdefer tmp.cleanup();
            const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
            errdefer testing.allocator.free(root);
            return .{ .tmp = tmp, .root = root, .path = try std.fs.path.join(testing.allocator, &.{ root, "plugin", "config.zon" }) };
        }

        fn deinit(self: *Temp) void {
            testing.allocator.free(self.root);
            testing.allocator.free(self.path);
            self.tmp.cleanup();
        }

        fn write(self: Temp, text: []const u8) !void {
            try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(self.path).?);
            try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = self.path, .data = text });
        }
    };

    const log_mod = @import("log.zig");

    test "save and reopen" {
        var temp = try Temp.init();
        defer temp.deinit();

        const first = try Lifecycle(Settings).open(testing.allocator, io, temp.path);
        try testing.expectEqualDeep(Settings{}, first.value);
        first.value.enabled = false;
        first.value.volume = 0.25;
        first.value.mode = .high;
        first.value.label = "custom";
        first.value.window.y = 99;
        first.value.hotkey = 0x2D;
        Lifecycle(Settings).close(first); // saves

        const second = try Lifecycle(Settings).open(testing.allocator, io, temp.path);
        defer Lifecycle(Settings).close(second);
        try testing.expectEqualDeep(Settings{
            .enabled = false,
            .volume = 0.25,
            .mode = .high,
            .label = "custom",
            .window = .{ .x = 10, .y = 99 },
            .hotkey = 0x2D,
        }, second.value);
    }

    test "save on small stack" {
        var temp = try Temp.init();
        defer temp.deinit();

        const cfg = try Lifecycle(Settings).open(testing.allocator, io, temp.path);
        cfg.value.volume = 0.75;
        const saver = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, struct {
            fn run(c: *Config(Settings)) void {
                c.save() catch unreachable;
            }
        }.run, .{cfg});
        saver.join();
        Lifecycle(Settings).close(cfg);

        const reopened = try Lifecycle(Settings).open(testing.allocator, io, temp.path);
        defer Lifecycle(Settings).close(reopened);
        try testing.expectEqual(0.75, reopened.value.volume);
    }

    test "open on small stack" {
        var temp = try Temp.init();
        defer temp.deinit();
        try temp.write(".{ .volume = 0.125 }\n");

        var volume: f32 = 0;
        const opener = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, struct {
            fn run(path: []const u8, out: *f32) void {
                const c = Lifecycle(Settings).open(testing.allocator, io, path) catch unreachable;
                out.* = c.value.volume;
                Lifecycle(Settings).discard(c);
            }
        }.run, .{ temp.path, &volume });
        opener.join();
        try testing.expectEqual(0.125, volume);
    }

    test "missing and unknown fields" {
        var temp = try Temp.init();
        defer temp.deinit();
        try temp.write(".{ .enabled = false, .removed_in_this_version = 3 }\n");

        const cfg = try Lifecycle(Settings).open(testing.allocator, io, temp.path);
        defer Lifecycle(Settings).close(cfg);
        try testing.expectEqual(false, cfg.value.enabled);
        try testing.expectEqual(Mode.low, cfg.value.mode);
        try testing.expectEqualStrings("default", cfg.value.label);
    }

    test "flush reports failure" {
        const saved = log_mod.mute(&.{.config});
        defer log_mod.setFilter(saved);
        var temp = try Temp.init();
        defer temp.deinit();

        const cfg = try Lifecycle(Settings).open(testing.allocator, io, temp.path);
        defer Lifecycle(Settings).discard(cfg);
        try cfg.flush(); // nothing pending

        cfg.value.volume = 0.875;
        try cfg.save();
        try cfg.flush();
        const text = try std.Io.Dir.cwd().readFileAlloc(io, temp.path, testing.allocator, .limited(1024));
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "0.875") != null);

        // Delete the folder so the save fails
        try std.Io.Dir.cwd().deleteTree(io, std.fs.path.dirname(temp.path).?);
        try cfg.save();
        try testing.expectError(error.FileNotFound, cfg.flush());
    }

    test "reload" {
        const saved = log_mod.mute(&.{.config});
        defer log_mod.setFilter(saved);
        var temp = try Temp.init();
        defer temp.deinit();

        const cfg = try Lifecycle(Settings).open(testing.allocator, io, temp.path);
        defer Lifecycle(Settings).discard(cfg);

        try temp.write(".{ .volume = 0.9, .label = \"edited\" }\n");
        try cfg.reload();
        try testing.expectEqual(0.9, cfg.value.volume);
        try testing.expectEqualStrings("edited", cfg.value.label);

        // Half-edited file. Nothing changes and it doesn't get moved aside
        try temp.write(".{ .volume = ");
        try testing.expectError(error.ParseZon, cfg.reload());
        try testing.expectEqual(0.9, cfg.value.volume);
        try testing.expectEqualStrings("edited", cfg.value.label);
        try std.Io.Dir.accessAbsolute(io, temp.path, .{});

        try std.Io.Dir.deleteFileAbsolute(io, temp.path);
        try cfg.reload();
        try testing.expectEqualDeep(Settings{}, cfg.value);
    }

    test "reload during save" {
        var temp = try Temp.init();
        defer temp.deinit();

        const cfg = try Lifecycle(Settings).open(testing.allocator, io, temp.path);
        defer Lifecycle(Settings).discard(cfg);
        cfg.value.mode = .high;
        try cfg.save();
        cfg.value.mode = .off; // not saved, reload should undo this

        const reloader = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, struct {
            fn run(c: *Config(Settings)) void {
                c.reload() catch unreachable;
            }
        }.run, .{cfg});
        reloader.join();
        try testing.expectEqual(Mode.high, cfg.value.mode);
    }

    test "bad file moved aside" {
        const saved = log_mod.mute(&.{.config});
        defer log_mod.setFilter(saved);
        var temp = try Temp.init();
        defer temp.deinit();
        try temp.write(".{ .enabled = maybe ");

        const cfg = try Lifecycle(Settings).open(testing.allocator, io, temp.path);
        try testing.expectEqualDeep(Settings{}, cfg.value);
        Lifecycle(Settings).close(cfg);

        const bad = try std.mem.concat(testing.allocator, u8, &.{ temp.path, ".bad" });
        defer testing.allocator.free(bad);
        const kept = try std.Io.Dir.cwd().readFileAlloc(io, bad, testing.allocator, .limited(1024));
        defer testing.allocator.free(kept);
        try testing.expectEqualStrings(".{ .enabled = maybe ", kept);
    }
};

test {
    _ = tests;
}
