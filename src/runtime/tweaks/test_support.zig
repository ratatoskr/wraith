//! Shared by the tweaks' tests: a fake provider and a project in a temp folder.

const std = @import("std");
const testing = std.testing;

const api = @import("wraith_api");

const Tweaks = @import("../Tweaks.zig");
const Project = @import("../Project.zig");
const GameSettings = @import("../GameSettings.zig");
const running = @import("running.zig");

const protocol = api.script;
const Settings = GameSettings.Tweaks;

pub const Fake = struct {
    runs: u32 = 0,
    stops: u32 = 0,
    last_code: [256]u8 = undefined,
    last_len: usize = 0,
    last_session: u32 = 0,
    last_language: [8]u8 = undefined,
    last_language_len: usize = 0,
    last_value: ?f64 = null,
    /// The last run's and stop's `part`, for a group's.
    last_part: [32]u8 = undefined,
    last_part_len: usize = 0,
    stop_part: [32]u8 = undefined,
    stop_part_len: usize = 0,
    saved_on: usize = 0,
    saved_values: usize = 0,
    saves: u32 = 0,
    ready: bool = false,
    /// Each run and stop's part, like `run Combat;stop ;`, since `forget`.
    history_buf: [1024]u8 = undefined,
    history_len: usize = 0,
    /// Each `TweakSwitched`, like `kai/One on;`.
    switched_buf: [512]u8 = undefined,
    switched_len: usize = 0,

    var current: *Fake = undefined;

    fn note(self: *Fake, what: []const u8, of: []const u8) void {
        const text = std.fmt.bufPrint(self.history_buf[self.history_len..], "{s} {s};", .{ what, of }) catch return;
        self.history_len += text.len;
    }

    pub fn history(self: *const Fake) []const u8 {
        return self.history_buf[0..self.history_len];
    }

    pub fn switched(self: *const Fake) []const u8 {
        return self.switched_buf[0..self.switched_len];
    }

    pub fn forget(self: *Fake) void {
        self.history_len = 0;
    }

    fn readyFn(context: ?*anyopaque, _: []const u8) bool {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        return self.ready;
    }

    fn publish(topic: []const u8, payload: []const u8) anyerror!void {
        if (std.mem.eql(u8, topic, protocol.topics.run)) {
            current.runs += 1;
            const run = try std.json.parseFromSlice(protocol.Run, testing.allocator, payload, .{});
            defer run.deinit();
            try testing.expect(run.value.tweak);
            current.last_session = run.value.session;
            current.last_language_len = @min(run.value.language.len, current.last_language.len);
            @memcpy(current.last_language[0..current.last_language_len], run.value.language[0..current.last_language_len]);
            current.last_len = @min(run.value.code.len, current.last_code.len);
            @memcpy(current.last_code[0..current.last_len], run.value.code[0..current.last_len]);
            current.last_value = if (run.value.values.len > 0) run.value.values[0].value else null;
            current.last_part_len = copy(&current.last_part, run.value.part);
            current.note("run", run.value.part);
        } else if (std.mem.eql(u8, topic, protocol.topics.stop)) {
            current.stops += 1;
            const target = try std.json.parseFromSlice(protocol.Target, testing.allocator, payload, .{});
            defer target.deinit();
            current.stop_part_len = copy(&current.stop_part, target.value.part);
            current.note("stop", target.value.part);
        } else if (std.mem.eql(u8, topic, protocol.topics.switched)) {
            const s = try std.json.parseFromSlice(api.TweakSwitched, testing.allocator, payload, .{});
            defer s.deinit();
            const text = std.fmt.bufPrint(current.switched_buf[current.switched_len..], "{s} {s};", .{ s.value.name, if (s.value.on) "on" else "off" }) catch return;
            current.switched_len += text.len;
        }
    }

    fn copy(to: []u8, from: []const u8) usize {
        const n = @min(to.len, from.len);
        @memcpy(to[0..n], from[0..n]);
        return n;
    }

    pub fn part(self: *const Fake) []const u8 {
        return self.last_part[0..self.last_part_len];
    }

    pub fn stopPart(self: *const Fake) []const u8 {
        return self.stop_part[0..self.stop_part_len];
    }

    fn save(context: ?*anyopaque, settings: Settings) void {
        const self: *Fake = @ptrCast(@alignCast(context.?));
        self.saves += 1;
        self.saved_on = settings.on.len;
        self.saved_values = settings.values.len;
    }

    pub fn env(self: *Fake) Tweaks.Env {
        current = self;
        return .{ .context = self, .ready = readyFn, .publish = publish, .save = save };
    }

    pub fn code(self: *const Fake) []const u8 {
        return self.last_code[0..self.last_len];
    }

    pub fn language(self: *const Fake) []const u8 {
        return self.last_language[0..self.last_language_len];
    }
};

pub const Setup = struct {
    tmp: testing.TmpDir,
    project: *Project,

    pub fn init(files: []const [2][]const u8) !Setup {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];
        const project = try Project.create(testing.allocator, testing.io, dir);
        for (files) |f| try project.write(f[0], f[1]);
        return .{ .tmp = tmp, .project = project };
    }

    pub fn deinit(self: *Setup) void {
        self.project.destroy();
        self.tmp.cleanup();
    }
};

/// As if the provider sent it.
pub fn hear(tweaks: *Tweaks, topic: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(testing.allocator, value, .{});
    defer testing.allocator.free(json);
    running.onMessage(tweaks, &.{ .topic = topic, .payload = json, .from = "js" });
}
