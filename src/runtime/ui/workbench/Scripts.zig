//! The workbench's end of script sessions, which outlive their documents.

const Scripts = @This();

const std = @import("std");

const api = @import("wraith_api");
const core = @import("wraith_core");
const sync = @import("tuft_sys").sync;
const Text = @import("tuft_text").Text;

const messages = @import("../../host/messages.zig");
const Shell = @import("../shell/Shell.zig");
const Project = @import("../../Project.zig");

const protocol = api.script;
const log = core.log.scoped(.wraith_ui);

pub const max_lines = 2000;

/// What a session runs.
pub const Language = enum {
    js,
    lua,

    pub fn title(self: Language) []const u8 {
        return switch (self) {
            .js => "JavaScript",
            .lua => "Lua",
        };
    }

    /// For its project scripts.
    pub fn ext(self: Language) []const u8 {
        return switch (self) {
            .js => Project.ext.script,
            .lua => Project.ext.script_lua,
        };
    }

    /// By a script's extension. Null if it's not a script.
    pub fn ofPath(path: []const u8) ?Language {
        inline for (comptime std.enums.values(Language)) |l| {
            if (std.mem.endsWith(u8, path, l.ext())) return l;
        }
        return null;
    }
};

allocator: std.mem.Allocator,
/// Null in tests, where scripts count as ready.
shell: ?*Shell,
subscription: ?messages.RuntimeSubscription = null,
next_session: u32 = 1,

// Render thread in, workbench thread out
inbox_lock: sync.RwLock = .{},
inbox: std.ArrayList(Line) = .empty,
inbox_report: ?[]protocol.Running = null,

// Workbench thread only
sessions: std.ArrayList(Session) = .empty,
console: std.ArrayList(Line) = .empty,
/// So the Console can follow.
console_changes: u32 = 0,
next_seq: u64 = 1,

pub const Line = struct {
    session: u32,
    kind: protocol.Kind,
    text: []u8,
    seq: u64 = 0,
};

pub const Session = struct {
    id: u32,
    name: Text(64) = .{},
    /// Its project script, like `scripts/x.rws.js`. Empty if it hasn't one.
    file: Text(128) = .{},
    language: Language = .js,
    /// Where it runs, from the next run. A change starts it afresh.
    thread: protocol.Thread = .game,
    code: []u8 = &.{},
    pending: ?[]u8 = null,
    /// Null if the runtime hasn't heard of it.
    running: ?protocol.Running = null,

    pub fn label(self: *const Session) []const u8 {
        return self.name.get();
    }

    pub fn filePath(self: *const Session) ?[]const u8 {
        const f = self.file.get();
        return if (f.len == 0) null else f;
    }
};

pub fn init(allocator: std.mem.Allocator, shell: ?*Shell) Scripts {
    return .{ .allocator = allocator, .shell = shell };
}

pub fn deinit(self: *Scripts) void {
    if (self.subscription) |s| s.unsubscribe();
    self.subscription = null;
    for (self.inbox.items) |l| self.allocator.free(l.text);
    self.inbox.deinit(self.allocator);
    if (self.inbox_report) |r| self.freeReport(r);
    for (self.console.items) |l| self.allocator.free(l.text);
    self.console.deinit(self.allocator);
    for (self.sessions.items) |*s| self.freeSession(s);
    self.sessions.deinit(self.allocator);
}

/// Nothing runs in it until `run`.
pub fn newSession(self: *Scripts, name: []const u8) !u32 {
    var s: Session = .{ .id = self.next_session };
    s.name.set(name);
    try self.sessions.append(self.allocator, s);
    self.next_session += 1;
    return s.id;
}

pub fn find(self: *Scripts, id: u32) ?*Session {
    for (self.sessions.items) |*s| if (s.id == id) return s;
    return null;
}

/// Ties session `id` to a project script, named after it and running its language. Empty unties it.
pub fn bindFile(self: *Scripts, id: u32, path_in: []const u8) void {
    const s = self.find(id) orelse return;
    // It can be the session's own, which setting would wipe
    const copy: @TypeOf(s.file) = .init(path_in);
    s.file = copy;
    const path = s.file.get();
    if (path.len == 0) return;
    const base = std.fs.path.basename(path);
    s.name.set(base[0 .. std.mem.indexOfScalar(u8, base, '.') orelse base.len]);
    if (Language.ofPath(path)) |l| self.setLanguage(id, l);
}

/// From the next run, which starts it afresh.
pub fn setLanguage(self: *Scripts, id: u32, language: Language) void {
    const s = self.find(id) orelse return;
    if (s.language == language) return;
    if (s.code.len > 0 or s.running != null) self.send(protocol.topics.reset, protocol.Target{ .session = id });
    s.language = language;
    s.running = null;
}

/// From the next run, which starts it afresh on that thread.
pub fn setThread(self: *Scripts, id: u32, thread: protocol.Thread) void {
    const s = self.find(id) orelse return;
    if (s.thread == thread) return;
    if (s.code.len > 0 or s.running != null) self.send(protocol.topics.reset, protocol.Target{ .session = id });
    s.thread = thread;
    s.running = null;
}

/// The session for a project script, if one's open.
pub fn findFile(self: *Scripts, path: []const u8) ?*Session {
    for (self.sessions.items) |*s| if (s.filePath()) |f| if (std.mem.eql(u8, f, path)) return s;
    return null;
}

/// Once scripts are ready.
pub fn run(self: *Scripts, id: u32, code: []const u8) void {
    const s = self.find(id) orelse return;
    const copy = self.allocator.dupe(u8, code) catch return;
    self.allocator.free(s.code);
    s.code = copy;
    if (s.pending) |p| self.allocator.free(p);
    s.pending = self.allocator.dupe(u8, code) catch null;
    self.listen();
    self.sendPending();
}

/// Like typed at the Console. It runs in the session, but its document still opens with what it
/// ran before. Once scripts are ready.
pub fn eval(self: *Scripts, id: u32, code: []const u8) void {
    const s = self.find(id) orelse return;
    if (s.pending) |p| self.allocator.free(p);
    s.pending = self.allocator.dupe(u8, code) catch null;
    self.listen();
    self.sendPending();
}

/// Stops what it started and forgets its variables. It stays listed.
pub fn reset(self: *Scripts, id: u32) void {
    self.send(protocol.topics.reset, protocol.Target{ .session = id });
}

pub fn stop(self: *Scripts, id: u32) void {
    self.send(protocol.topics.stop, protocol.Target{ .session = id });
    for (self.sessions.items, 0..) |*s, i| if (s.id == id) {
        self.freeSession(s);
        _ = self.sessions.orderedRemove(i);
        return;
    };
}

pub fn clearConsole(self: *Scripts) void {
    for (self.console.items) |l| self.allocator.free(l.text);
    self.console.clearRetainingCapacity();
}

/// Whether the runtime's sessions are up, which they are once plugins are.
pub fn ready(self: *Scripts) bool {
    const shell = self.shell orelse return true;
    return shell.scriptsReady();
}

/// Workbench thread, each frame.
pub fn pump(self: *Scripts) void {
    var lines: std.ArrayList(Line) = .empty;
    defer lines.deinit(self.allocator);
    var report: ?[]protocol.Running = null;
    {
        self.inbox_lock.lock();
        defer self.inbox_lock.unlock();
        std.mem.swap(std.ArrayList(Line), &lines, &self.inbox);
        report = self.inbox_report;
        self.inbox_report = null;
    }
    for (lines.items) |l| self.addLine(l);
    if (report) |r| {
        defer self.freeReport(r);
        self.applyReport(r);
    }
    // The sessions went, so what they had did too
    if (!self.ready()) for (self.sessions.items) |*s| {
        s.running = null;
    };
    self.sendPending();
}

fn addLine(self: *Scripts, line: Line) void {
    if (self.console.items.len == max_lines) self.allocator.free(self.console.orderedRemove(0).text);
    var numbered = line;
    numbered.seq = self.next_seq;
    self.console.append(self.allocator, numbered) catch {
        self.allocator.free(line.text);
        return;
    };
    self.next_seq += 1;
    self.console_changes +%= 1;
}

fn applyReport(self: *Scripts, report: []const protocol.Running) void {
    for (self.sessions.items) |*s| {
        s.running = null;
        for (report) |r| if (r.session == s.id) {
            s.running = r;
            s.running.?.name = "";
        };
    }
}

fn sendPending(self: *Scripts) void {
    for (self.sessions.items) |*s| {
        const code = s.pending orelse continue;
        if (!self.ready()) continue;
        s.pending = null;
        defer self.allocator.free(code);
        self.send(protocol.topics.run, protocol.Run{ .session = s.id, .name = s.label(), .code = code, .language = @tagName(s.language), .thread = s.thread });
    }
}

fn send(self: *Scripts, topic: []const u8, value: anytype) void {
    self.listen();
    const json = std.json.Stringify.valueAlloc(self.allocator, value, .{}) catch return;
    defer self.allocator.free(json);
    messages.publishFromRuntime(topic, json) catch |err| log.warn("Couldn't send to script sessions: {t}", .{err});
}

fn listen(self: *Scripts) void {
    if (self.subscription != null) return;
    self.subscription = messages.subscribeRuntime(self, onMessage) catch |err| {
        log.warn("Can't hear script output: {t}", .{err});
        return;
    };
}

/// Render thread.
fn onMessage(self: *Scripts, message: *const api.Message) void {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    if (std.mem.eql(u8, message.topic, protocol.topics.output)) {
        const out = std.json.parseFromSliceLeaky(protocol.Output, arena.allocator(), message.payload, options) catch return;
        const text = self.allocator.dupe(u8, out.text) catch return;
        self.inbox_lock.lock();
        defer self.inbox_lock.unlock();
        // Too far behind, like with the workbench closed
        if (self.inbox.items.len >= max_lines) self.allocator.free(self.inbox.orderedRemove(0).text);
        self.inbox.append(self.allocator, .{ .session = out.session, .kind = out.kind, .text = text }) catch self.allocator.free(text);
    } else if (std.mem.eql(u8, message.topic, protocol.topics.sessions)) {
        const report = std.json.parseFromSliceLeaky(protocol.Sessions, arena.allocator(), message.payload, options) catch return;
        // Names are ours already, so they're not kept
        const copy = self.allocator.dupe(protocol.Running, report.sessions) catch return;
        for (copy) |*r| r.name = "";
        self.inbox_lock.lock();
        defer self.inbox_lock.unlock();
        if (self.inbox_report) |old| self.freeReport(old);
        self.inbox_report = copy;
    }
}

fn freeReport(self: *Scripts, report: []protocol.Running) void {
    self.allocator.free(report);
}

fn freeSession(self: *Scripts, s: *Session) void {
    self.allocator.free(s.code);
    if (s.pending) |p| self.allocator.free(p);
}

test "binding a session to the path it already has" {
    var scripts: Scripts = .init(std.testing.allocator, null);
    defer scripts.deinit();
    const id = try scripts.newSession("Script");
    scripts.bindFile(id, "scripts/heal.rws.js");
    // Its own path, which used to get wiped before it was copied
    scripts.bindFile(id, scripts.find(id).?.filePath().?);
    try std.testing.expectEqualStrings("scripts/heal.rws.js", scripts.find(id).?.filePath().?);
    try std.testing.expectEqualStrings("heal", scripts.find(id).?.name.get());
    try std.testing.expectEqual(.js, scripts.find(id).?.language);
    scripts.bindFile(id, "scripts/heal.rws.lua");
    try std.testing.expectEqual(.lua, scripts.find(id).?.language);
}
