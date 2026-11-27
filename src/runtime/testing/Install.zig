//! A throwaway Wraith install for tests, with a loader on it.

const Install = @This();

const std = @import("std");
const testing = std.testing;

const core = @import("wraith_core");

const PluginLoader = @import("../PluginLoader.zig");

tmp: testing.TmpDir,
root: [:0]u8,
loader: PluginLoader,
saved_filter: core.log.Filter,

pub const Contents = struct {
    plugins: []const [2][]const u8 = &.{},
    dev_plugins: []const []const u8 = &.{},
};

pub fn init(self: *Install, contents: Contents) !void {
    const io = testing.io;
    const a = testing.allocator;
    self.saved_filter = core.log.mute(&.{ .plugin, .runtime, .sdk });
    self.tmp = testing.tmpDir(.{});
    for (contents.plugins) |p| try self.addDll("plugins", p[0], p[1]);
    self.root = try self.tmp.dir.realPathFileAlloc(io, ".", a);
    const dev_file = try std.fs.path.join(a, &.{ self.root, "settings", core.dev_plugins.file_name });
    {
        var arena: std.heap.ArenaAllocator = .init(a);
        defer arena.deinit();
        const dev = try arena.allocator().alloc([]const u8, contents.dev_plugins.len);
        for (dev, contents.dev_plugins) |*s, folder| s.* = try std.fs.path.join(arena.allocator(), &.{ self.root, folder });
        if (dev.len != 0) try core.dev_plugins.save(a, io, dev_file, dev);
    }
    self.loader = PluginLoader.init(a, io, .{
        .plugins = try std.fs.path.join(a, &.{ self.root, "plugins" }),
        .dev_plugins = dev_file,
        .copies = try std.fs.path.join(a, &.{ self.root, "copies" }),
        .cache = try std.fs.path.join(a, &.{ self.root, "cache" }),
        .config = try std.fs.path.join(a, &.{ self.root, "settings" }),
        .game_config = try std.fs.path.join(a, &.{ self.root, "settings", "games", "test-game" }),
    });
}

pub fn deinit(self: *Install) void {
    self.loader.deinit();
    testing.allocator.free(self.root);
    self.tmp.cleanup();
    core.log.setFilter(self.saved_filter);
}

/// It gets an empty manifest too, which a test can write over.
pub fn addDll(self: *Install, folder: []const u8, name: []const u8, path: []const u8) !void {
    const io = testing.io;
    const a = testing.allocator;
    const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ folder, name });
    defer a.free(dir);
    try self.tmp.dir.createDirPath(io, dir);
    const file = try core.arch.native.dllNameAlloc(a, name);
    defer a.free(file);
    const dll = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, file });
    defer a.free(dll);
    try std.Io.Dir.cwd().copyFile(path, self.tmp.dir, dll, io, .{});
    try self.writeManifest(dir, name, "");
}

/// `dir/wraith.json`, `fields` being brace-less JSON like `"autoLoad": false`.
pub fn writeManifest(self: *Install, dir: []const u8, id: []const u8, fields: []const u8) !void {
    const a = testing.allocator;
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, core.manifest.file_name });
    defer a.free(path);
    const api = if (std.mem.indexOf(u8, fields, "\"apiVersion\"") == null)
        std.fmt.comptimePrint(", \"apiVersion\": {d}", .{core.manifest.api_version})
    else
        "";
    // Plugins need one, so native unless it says
    const native = std.mem.indexOf(u8, fields, "\"provider\"") == null and std.mem.indexOf(u8, fields, "\"project\"") == null;
    const text = try std.fmt.allocPrint(a, "{{ \"id\": \"{s}\"{s}{s}{s}{s} }}", .{ id, api, if (native) ", \"provider\": \"native\"" else "", if (fields.len > 0) ", " else "", fields });
    defer a.free(text);
    try self.tmp.dir.writeFile(testing.io, .{ .sub_path = path, .data = text });
}

/// A plugin's, in `plugins/<name>`.
pub fn pluginManifest(self: *Install, name: []const u8, fields: []const u8) !void {
    const dir = try std.fmt.allocPrint(testing.allocator, "plugins/{s}", .{name});
    defer testing.allocator.free(dir);
    try self.writeManifest(dir, name, fields);
}

/// A script plugin run by the `provider` kind, with an empty main file.
pub fn addScript(self: *Install, name: []const u8, provider: []const u8) !void {
    const io = testing.io;
    const a = testing.allocator;
    const dir = try std.fmt.allocPrint(a, "plugins/{s}", .{name});
    defer a.free(dir);
    try self.tmp.dir.createDirPath(io, dir);
    const fields = try std.fmt.allocPrint(a, "\"provider\": \"{s}\"", .{provider});
    defer a.free(fields);
    try self.pluginManifest(name, fields);
    const main = try std.fmt.allocPrint(a, "{s}/main.{s}", .{ dir, provider });
    defer a.free(main);
    try self.tmp.dir.writeFile(io, .{ .sub_path = main, .data = "" });
}

pub fn info(self: *Install, name: []const u8) ?PluginLoader.Info {
    var out: [16]PluginLoader.Info = undefined;
    const listed = out[0..self.loader.list(&out)];
    for (listed) |i| {
        if (std.mem.eql(u8, i.name.get(), name)) return i;
    }
    return null;
}
