//! Sessions on the runtime's own bus and render queue, for tests.

const std = @import("std");

const api = @import("wraith_api");

const host = @import("../host/root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const Sessions = @import("Sessions.zig");

const protocol = api.script;
const testing = std.testing;

/// What the sessions said.
pub const Heard = struct {
    lines: std.ArrayList(Line) = .empty,
    /// Each `TweakState` as `part: names [choices]`.
    states: std.ArrayList([]u8) = .empty,
    /// The last state's `by` field.
    by: u64 = 0,
    sessions: std.ArrayList(protocol.Running) = .empty,
    reports: u32 = 0,

    pub const Line = struct { session: u32, kind: protocol.Kind, text: []u8, part: []u8 };

    pub fn on(self: *Heard, message: *const api.Message) void {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
        const gpa = testing.allocator;
        if (std.mem.eql(u8, message.topic, protocol.topics.output)) {
            const out = std.json.parseFromSliceLeaky(protocol.Output, a, message.payload, options) catch return;
            const text = gpa.dupe(u8, out.text) catch return;
            const part = gpa.dupe(u8, out.part) catch return gpa.free(text);
            self.lines.append(gpa, .{ .session = out.session, .kind = out.kind, .text = text, .part = part }) catch {
                gpa.free(text);
                gpa.free(part);
            };
        } else if (std.mem.eql(u8, message.topic, protocol.topics.tweak)) {
            const s = std.json.parseFromSliceLeaky(protocol.TweakState, a, message.payload, options) catch return;
            var w: std.Io.Writer.Allocating = .init(gpa);
            defer w.deinit();
            w.writer.print("{s}:", .{s.part}) catch return;
            for (s.names) |n| w.writer.print(" {s}", .{n.name}) catch return;
            for (s.fields) |f| {
                if (std.mem.eql(u8, f.name, "by")) self.by = f.address;
                for (f.choices orelse &.{}) |c| w.writer.print(" [{s}]", .{c.label}) catch return;
            }
            const text = w.toOwnedSlice() catch return;
            self.states.append(gpa, text) catch gpa.free(text);
        } else if (std.mem.eql(u8, message.topic, protocol.topics.sessions)) {
            const s = std.json.parseFromSliceLeaky(protocol.Sessions, a, message.payload, options) catch return;
            self.reports += 1;
            self.sessions.clearRetainingCapacity();
            for (s.sessions) |r| {
                var kept = r;
                kept.name = "";
                self.sessions.append(gpa, kept) catch {};
            }
        }
    }

    pub fn line(self: *const Heard, i: usize) []const u8 {
        return self.lines.items[i].text;
    }

    /// What was thrown or logged as an error first.
    pub fn problem(self: *const Heard) ?Line {
        for (self.lines.items) |l| if (l.kind == .thrown or l.kind == .err) return l;
        return null;
    }

    pub fn thrown(self: *const Heard) ?[]const u8 {
        for (self.lines.items) |l| if (l.kind == .thrown) return l.text;
        return null;
    }

    pub fn deinit(self: *Heard) void {
        const gpa = testing.allocator;
        for (self.lines.items) |l| {
            gpa.free(l.text);
            gpa.free(l.part);
        }
        self.lines.deinit(gpa);
        for (self.states.items) |s| gpa.free(s);
        self.states.deinit(gpa);
        self.sessions.deinit(gpa);
    }
};

/// Sessions on the runtime's bus and render queue. Mustn't move.
pub const Rig = struct {
    sessions: *Sessions,
    heard: Heard = .{},
    subscription: host.messages.RuntimeSubscription,
    buf: [4096]u8 = undefined,

    pub fn init(r: *Rig) !void {
        try @import("tuft_hook").init(testing.allocator);
        host.messages.setFrames(true);
        host.frame.setFrames(true);
        r.heard = .{};
        r.sessions = try Sessions.create(testing.allocator, "", "", null);
        r.subscription = try host.messages.subscribeRuntime(&r.heard, Heard.on);
    }

    pub fn deinit(r: *Rig) void {
        r.sessions.destroy();
        r.subscription.unsubscribe();
        r.heard.deinit();
        host.frame.setFrames(false);
        host.messages.setFrames(false);
        @import("tuft_hook").deinit();
    }

    pub fn send(r: *Rig, topic: []const u8, value: anytype) !void {
        _ = r;
        const json = try std.json.Stringify.valueAlloc(testing.allocator, value, .{});
        defer testing.allocator.free(json);
        try host.messages.publishFromRuntime(topic, json);
    }

    /// Requests in, a tick and a frame, and what that said out.
    pub fn step(_: *Rig) void {
        host.messages.deliver();
        host.frame.tickForTests();
        host.salamander.pollRender();
        host.messages.deliver();
    }

    /// Plain code in session `id`, not a tweak.
    pub fn run(r: *Rig, id: u32, language: []const u8, code: []const u8) !void {
        try r.send(protocol.topics.run, protocol.Run{ .session = id, .language = language, .code = code });
        r.step();
    }

    pub fn runPart(r: *Rig, id: u32, name: []const u8, source: []const u8, part: []const u8) !void {
        try r.send(protocol.topics.run, protocol.Run{ .session = id, .name = name, .code = source, .tweak = true, .part = part });
        r.step();
    }

    pub fn stopPart(r: *Rig, id: u32, part: []const u8) !void {
        try r.send(protocol.topics.stop, protocol.Target{ .session = id, .part = part });
        r.step();
    }

    pub fn forget(r: *Rig) void {
        r.heard.deinit();
        r.heard = .{};
    }

    pub fn eval(r: *Rig, id: u32, code: []const u8) []const u8 {
        const live = r.sessions.find(id).?.live.?;
        live.script.enter();
        defer live.script.leave();
        return switch (live.script.eval(code, &r.buf)) {
            .value => |v| v,
            .thrown => |t| t,
        };
    }

    pub fn loadedOf(r: *Rig, id: u32) *Loaded {
        return &r.sessions.find(id).?.live.?.loaded;
    }

    /// Fails with what it threw, if it did.
    pub fn expectFine(r: *Rig) !void {
        if (r.heard.thrown()) |t| {
            std.debug.print("threw: {s}\n", .{t});
            return error.TestUnexpectedResult;
        }
    }
};
