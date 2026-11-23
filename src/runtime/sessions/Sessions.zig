//! The workbench's script sessions, in JS or Lua on Salamander. Requests come as runtime messages,
//! and each session is a script of its own that keeps its state between runs, with Wraith's areas
//! as globals like `frame` and `hooks`, and every loaded plugin's services as modules by its name,
//! like `require("unreal")`. Tweaks run in them too, each in a session of its own. Each is for a
//! project, and starts with its schemas and names, see `host.projects`.
//!
//! Each session runs on the game thread or the render thread, as its runs ask. Game thread ones are
//! looked after in a tick, render thread ones in a task the render queue runs once a frame.

const Sessions = @This();

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");
const hosts = @import("salamander_hosts");
const mem = @import("tuft_mem");
const sync = @import("tuft_sys").sync;

const host = @import("../host/root.zig");
const scripts = @import("../plugins/scripts.zig");
const repl = @import("repl.zig");
const PluginLoader = @import("../PluginLoader.zig");
const Loaded = PluginLoader.Loaded;

const protocol = api.script;
const Thread = protocol.Thread;
const tweak = api.tweak;
const sal = api.salamander;
const engine = hosts.engine;
const Language = hosts.Language;
const log = core.log.scoped(.wraith_runtime);

/// Gives compiled tweaks their `__t`.
const tweak_js = @embedFile("tweak.js");
const tweak_lua = @embedFile("tweak.lua");

/// Most text one run gives back, like a tweak's state.
const max_result = 256 * 1024;

gpa: std.mem.Allocator,
/// Whose plugins' services sessions get. Null in tests.
loader: ?*PluginLoader,
/// Where sessions keep their settings, each in a folder of its own.
config_dir: []u8,
game_config_dir: []u8,
/// Its pump's, so stopping waits for one that's running.
owner: *sal.Owner,
pump: sal.Task = .{},
ticks: ?host.frame.TickSubscription = null,
subscription: ?host.messages.RuntimeSubscription = null,
lock: sync.RwLock = .{},
queue: std.ArrayList(Request) = .empty,
/// Held by whichever thread's looking after its sessions. Neither waits for it.
work: sync.Mutex = .{},
// Under `work`
sessions: std.ArrayList(*Session) = .empty,
reported: std.ArrayList(protocol.Running) = .empty,
report_all: bool = true,

pub const Session = struct {
    owner: *Sessions,
    id: u32,
    name: []u8,
    language: Language,
    thread: Thread = .game,
    /// Null after a reset.
    live: ?*Live = null,
    /// Runs a tweak, which gets to clean up when it stops.
    tweak: bool = false,
    /// What's on of a group's file, each in a scope of its own. The shared part's first, unnamed.
    parts: std.ArrayList(Part) = .empty,
    /// The part running now, for saying where output came from.
    speaking: []const u8 = "",
    /// What the next part's tagged with.
    next_tag: u32 = 1,

    fn findPart(self: *const Session, name: []const u8) ?usize {
        for (self.parts.items, 0..) |p, i| if (std.mem.eql(u8, p.name, name)) return i;
        return null;
    }
};

pub const Part = struct {
    name: []u8,
    /// Keeps the callbacks it gave Wraith.
    scope: *engine.Scope,
    /// What it made through Wraith, which stops with it.
    tag: u32,
    /// A group's shared part, which what's under its path goes before.
    group: bool = false,

    /// In `group`'s subtree, but not `group` itself.
    fn isUnder(self: Part, group: []const u8) bool {
        return self.name.len > group.len and std.mem.startsWith(u8, self.name, group) and self.name[group.len] == '/';
    }
};

/// A session's script, and the plugin-like owner of what it makes.
const Live = struct {
    loaded: Loaded,
    script: hosts.Script = undefined,
    language: Language,
    exposed: scripts.Exposed = .{},
    /// Its project's schemas as one text, which a tweak's own `@schema` comes after.
    project_text: []u8 = &.{},
    /// Its schemas have the plugins' that offer services, so it can have their services.
    with_plugins: bool = false,

    fn languageName(l: *const Live) []const u8 {
        return @tagName(l.language);
    }
};

const Request = struct {
    op: enum { run, reset, stop },
    session: u32,
    name: []u8 = &.{},
    code: []u8 = &.{},
    language: []u8 = &.{},
    tweak: bool = false,
    values: []tweak.Value = &.{},
    /// A group's `@tweak`.
    part: []u8 = &.{},
    shared_values: []tweak.Value = &.{},
    project: []u8 = &.{},
    thread: Thread = .game,

    fn free(self: Request, gpa: std.mem.Allocator) void {
        gpa.free(self.project);
        gpa.free(self.name);
        gpa.free(self.code);
        gpa.free(self.language);
        freeValues(gpa, self.values);
        freeValues(gpa, self.shared_values);
        gpa.free(self.part);
    }
};

fn freeValues(gpa: std.mem.Allocator, values: []tweak.Value) void {
    for (values) |v| gpa.free(v.name);
    gpa.free(values);
}

/// Listens for requests from now on. The config folders are where sessions keep their settings.
pub fn create(gpa: std.mem.Allocator, config_dir: []const u8, game_config_dir: []const u8, loader: ?*PluginLoader) !*Sessions {
    const self = try gpa.create(Sessions);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .loader = loader, .config_dir = undefined, .game_config_dir = undefined, .owner = undefined };
    self.config_dir = try gpa.dupe(u8, config_dir);
    errdefer gpa.free(self.config_dir);
    self.game_config_dir = try gpa.dupe(u8, game_config_dir);
    errdefer gpa.free(self.game_config_dir);
    self.owner = try sal.host().owner("wraith.sessions");
    errdefer self.owner.drain();
    self.pump = try sal.Task.owned(self.owner, self, pumpNow);
    self.ticks = try host.frame.subscribeTicks(self, tickNow);
    errdefer self.ticks.?.unsubscribe();
    self.subscription = try host.messages.subscribeRuntime(self, onMessage);
    self.schedule();
    return self;
}

/// Stops every session, letting tweaks clean up first.
pub fn destroy(self: *Sessions) void {
    if (self.subscription) |s| s.unsubscribe();
    // Waits for a tick that's in
    if (self.ticks) |t| t.unsubscribe();
    // Its pump's done for good, so nothing else touches the sessions
    self.owner.drain();
    for (self.sessions.items) |s| {
        if (s.tweak) self.stopTweak(s);
        self.end(s);
    }
    self.sessions.deinit(self.gpa);
    for (self.queue.items) |r| r.free(self.gpa);
    self.queue.deinit(self.gpa);
    for (self.reported.items) |r| self.gpa.free(r.name);
    self.reported.deinit(self.gpa);
    self.gpa.free(self.config_dir);
    self.gpa.free(self.game_config_dir);
    self.gpa.destroy(self);
}

fn schedule(self: *Sessions) void {
    host.salamander.renderQueueOf().postTask(self.pump) catch {};
}

/// Once a frame.
fn pumpNow(self: *Sessions) void {
    defer self.schedule();
    // The render thread never waits, so with the game thread in it's next frame
    if (!self.work.tryLock()) return;
    defer self.work.unlock();
    self.pumpOn(.render);
    self.report();
}

/// Once a tick, on the game thread.
fn tickNow(self: *Sessions) void {
    // It doesn't hold up the game either, so with the render thread in it's next tick
    if (!self.work.tryLock()) return;
    defer self.work.unlock();
    self.pumpOn(.game);
}

/// Under `work`. What was asked of the sessions on `thread`, then what their scripts set going.
fn pumpOn(self: *Sessions, thread: Thread) void {
    self.handleQueued(thread);
    for (self.sessions.items) |s| {
        if (s.thread != thread) continue;
        const live = s.live orelse continue;
        // Nor does it wait on a script
        if (!live.script.tryEnter()) continue;
        defer live.script.leave();
        live.script.pump();
    }
}

// Requests

fn onMessage(self: *Sessions, message: *const api.Message) void {
    if (!std.mem.eql(u8, message.from, protocol.runtime)) return;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    if (std.mem.eql(u8, message.topic, protocol.topics.run)) {
        const run_ = std.json.parseFromSliceLeaky(protocol.Run, a, message.payload, options) catch return;
        self.push(self.copyRun(run_) catch return);
    } else if (std.mem.eql(u8, message.topic, protocol.topics.reset)) {
        const target = std.json.parseFromSliceLeaky(protocol.Target, a, message.payload, options) catch return;
        self.push(.{ .op = .reset, .session = target.session });
    } else if (std.mem.eql(u8, message.topic, protocol.topics.stop)) {
        const target = std.json.parseFromSliceLeaky(protocol.Target, a, message.payload, options) catch return;
        const part = self.gpa.dupe(u8, target.part) catch return;
        self.push(.{ .op = .stop, .session = target.session, .part = part });
    }
}

fn copyRun(self: *Sessions, request: protocol.Run) !Request {
    var r: Request = .{ .op = .run, .session = request.session, .tweak = request.tweak, .thread = request.thread };
    errdefer r.free(self.gpa);
    r.name = try self.gpa.dupe(u8, request.name);
    r.code = try self.gpa.dupe(u8, request.code);
    r.language = try self.gpa.dupe(u8, request.language);
    r.part = try self.gpa.dupe(u8, request.part);
    r.project = try self.gpa.dupe(u8, request.project);
    r.values = try self.copyValues(request.values);
    r.shared_values = try self.copyValues(request.shared_values);
    return r;
}

fn copyValues(self: *Sessions, values: []const tweak.Value) ![]tweak.Value {
    const out = try self.gpa.alloc(tweak.Value, values.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |v| self.gpa.free(v.name);
        self.gpa.free(out);
    }
    for (out, values) |*dst, src| {
        dst.* = .{ .name = try self.gpa.dupe(u8, src.name), .value = src.value };
        done += 1;
    }
    return out;
}

fn push(self: *Sessions, request: Request) void {
    self.lock.lock();
    defer self.lock.unlock();
    self.queue.append(self.gpa, request) catch request.free(self.gpa);
}

/// Under `work`. Takes the requests for sessions on `thread`, leaving the rest.
fn handleQueued(self: *Sessions, thread: Thread) void {
    var queue: std.ArrayList(Request) = .empty;
    defer queue.deinit(self.gpa);
    {
        self.lock.lock();
        defer self.lock.unlock();
        const all = self.queue.items;
        if (all.len == 0) return;
        const threads = self.gpa.alloc(Thread, all.len) catch return;
        defer self.gpa.free(threads);
        for (all, threads, 0..) |r, *t, i| t.* = self.threadFor(r, all[0..i]);
        var kept: usize = 0;
        for (all, threads) |r, t| {
            // Out of memory and it waits for the next go
            if (t == thread) {
                if (queue.append(self.gpa, r)) |_| continue else |_| {}
            }
            all[kept] = r;
            kept += 1;
        }
        self.queue.shrinkRetainingCapacity(kept);
    }
    for (queue.items) |r| {
        defer r.free(self.gpa);
        switch (r.op) {
            .run => if (r.tweak) self.runTweak(r) else self.run(r),
            .reset => if (self.find(r.session)) |s| self.reset(s),
            .stop => if (self.find(r.session)) |s| {
                if (r.part.len > 0) {
                    self.stopPart(s, r.part);
                    continue;
                }
                _ = self.sessions.orderedRemove(std.mem.indexOfScalar(*Session, self.sessions.items, s).?);
                if (s.tweak) self.stopTweak(s);
                self.end(s);
            },
        }
    }
}

pub fn find(self: *Sessions, id: u32) ?*Session {
    for (self.sessions.items) |s| if (s.id == id) return s;
    return null;
}

/// Under both locks. A run goes where it asks. Anything else goes where its session is, or will be
/// once a run that's ahead of it starts it.
fn threadFor(self: *Sessions, r: Request, ahead: []const Request) Thread {
    if (r.op == .run) return r.thread;
    var i = ahead.len;
    while (i > 0) {
        i -= 1;
        if (ahead[i].op == .run and ahead[i].session == r.session) return ahead[i].thread;
    }
    if (self.find(r.session)) |s| return s.thread;
    return .render;
}

// Running code

fn run(self: *Sessions, r: Request) void {
    const language = std.meta.stringToEnum(Language, r.language) orelse
        return self.send(r.session, .thrown, "There's no {s} language", .{r.language});
    const session = self.find(r.session) orelse (self.open(r.session, r.name, language, r.thread) catch |err| {
        self.send(r.session, .thrown, "Couldn't start a session: {t}", .{err});
        return;
    });
    if (session.tweak) return self.send(r.session, .thrown, "A tweak gets a session of its own", .{});
    if (r.name.len > 0 and !std.mem.eql(u8, r.name, session.name)) {
        if (self.gpa.dupe(u8, r.name)) |copy| {
            self.gpa.free(session.name);
            session.name = copy;
        } else |_| {}
    }
    // Its variables were the other language's, or what it made is the other thread's
    if (session.language != language or session.thread != r.thread) {
        self.reset(session);
        session.language = language;
        session.thread = r.thread;
    }
    const live = session.live orelse (self.makeLive(session, r.project) catch |err| {
        self.send(r.session, .thrown, "Couldn't start a script: {t}", .{err});
        return;
    });
    self.send(r.session, .code, "{s}", .{r.code});
    const buf = self.gpa.alloc(u8, max_result) catch return self.send(r.session, .thrown, "Out of memory", .{});
    defer self.gpa.free(buf);
    live.script.enter();
    defer live.script.leave();
    if (language == .js and repl.awaits(r.code)) return self.runAwaiting(live, r.session, r.code, buf);
    switch (live.script.eval(r.code, buf)) {
        .value => |v| self.send(r.session, .value, "{s}", .{v}),
        .thrown => |t| self.send(r.session, .thrown, "{s}", .{t}),
    }
}

/// JS with a top-level `await`, in an async function that prints what it gave once it's done.
fn runAwaiting(self: *Sessions, live: *Live, id: u32, code: []const u8, buf: []u8) void {
    for ([_]repl.Form{ .expression, .statements }) |form| {
        const wrapped = repl.wrap(self.gpa, code, form) catch return self.send(id, .thrown, "Out of memory", .{});
        defer self.gpa.free(wrapped);
        switch (live.script.eval(wrapped, buf)) {
            .value => return,
            .thrown => |t| {
                // Not an expression, like `const x = await f()`
                if (form == .expression and std.mem.indexOf(u8, t, "SyntaxError") != null) continue;
                return self.send(id, .thrown, "{s}", .{t});
            },
        }
    }
}

/// A `.rwt` tweak, in a session of its own. A group's file shares one, where `part` is the path
/// of the `@tweak` or `@group` to turn on. Its file's shared part comes up with the first, and
/// a nested one's group has to be on already. Says where their data went, or what went wrong.
fn runTweak(self: *Sessions, r: Request) void {
    const id = r.session;
    const part = r.part;
    var arena: std.heap.ArenaAllocator = .init(self.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var problem: tweak.Problem = .{};
    const file = tweak.parseFile(a, r.code, &problem) catch |err| return switch (err) {
        error.Invalid => self.sendPart(id, part, .thrown, "line {d}: {s}", .{ problem.line, problem.message() }),
        error.OutOfMemory => self.sendPart(id, part, .thrown, "Out of memory", .{}),
    };
    const language: Language = switch (file.script) {
        .js => .js,
        .lua => .lua,
    };

    if (!file.grouped) {
        if (self.find(id) != null) return self.send(id, .thrown, "A tweak gets a session of its own", .{});
        const session = self.openTweak(id, r.name, language, r.project, r.thread) orelse return;
        return self.reportPart(a, session, "", self.runPart(session, a, r.code, file, .whole, r.values, ""));
    }
    const target = file.resolve(part) orelse return self.sendPart(id, part, .thrown, "There's no @tweak or @group \"{s}\" in it", .{part});
    const session = self.find(id) orelse blk: {
        const session = self.openTweak(id, r.name, language, r.project, r.thread) orelse return;
        const shared = self.runPart(session, a, r.code, file, .{ .group = 0 }, if (part.len == 0) r.values else r.shared_values, "");
        self.reportPart(a, session, "", shared);
        if (shared == .thrown) {
            // Nothing of the group stays up without its shared part
            _ = self.sessions.orderedRemove(std.mem.indexOfScalar(*Session, self.sessions.items, session).?);
            self.stopTweak(session);
            self.end(session);
            return;
        }
        break :blk session;
    };
    if (!session.tweak or session.live == null) return self.send(id, .thrown, "A tweak gets a session of its own", .{});
    // The file's shared part is up with its session
    if (part.len == 0) return;
    const parent = file.groups[file.parentOf(target).?].path;
    if (parent.len > 0 and session.findPart(parent) == null) return self.sendPart(id, part, .thrown, "Its group \"{s}\" isn't on", .{parent});
    // On already, so it starts again as it is now
    if (session.findPart(part) != null) self.stopPart(session, part);
    self.reportPart(a, session, part, self.runPart(session, a, r.code, file, target, r.values, part));
}

fn openTweak(self: *Sessions, id: u32, name: []const u8, language: Language, project: []const u8, thread: Thread) ?*Session {
    const session = self.open(id, name, language, thread) catch |err| {
        self.send(id, .thrown, "Couldn't start a session: {t}", .{err});
        return null;
    };
    session.tweak = true;
    _ = self.makeLive(session, project) catch |err| {
        self.send(id, .thrown, "Couldn't start a script: {t}", .{err});
        return null;
    };
    return session;
}

/// A group's parts each get a scope of their own, kept as one of the session's if it comes up.
/// One that throws is stopped there, so nothing of it stays. A lone tweak runs as the script's own.
fn runPart(self: *Sessions, session: *Session, a: std.mem.Allocator, source: []const u8, file: tweak.File, part: tweak.Part, values: []const tweak.Value, part_name: []const u8) engine.Evaluated {
    const live = session.live.?;
    live.script.enter();
    defer live.script.leave();
    const scope: ?*engine.Scope = if (part == .whole) null else live.script.openScope(part_name) catch return .{ .thrown = "Out of memory" };
    live.script.useScope(scope);
    defer live.script.useScope(null);
    session.speaking = part_name;
    defer session.speaking = "";
    const tag: u32 = if (scope == null) 0 else session.next_tag;
    if (scope != null) session.next_tag += 1;
    live.loaded.making.store(tag, .monotonic);
    defer live.loaded.making.store(0, .monotonic);

    const result = self.evalPart(session, a, source, file, part, values) catch |err|
        engine.Evaluated{ .thrown = std.fmt.allocPrint(a, "{t}", .{err}) catch "Out of memory" };
    // What it set off runs in its scope too
    live.script.pump();
    const s = scope orelse return result;
    if (result == .value) {
        if (self.gpa.dupe(u8, part_name)) |owned| {
            if (session.parts.append(self.gpa, .{ .name = owned, .scope = s, .tag = tag, .group = part == .group })) |_| {
                return result;
            } else |_| self.gpa.free(owned);
        } else |_| {}
    }
    self.runOff(session, live, part_name);
    live.script.closeScope(s);
    host.stopTagged(&live.loaded.owner, tag);
    return if (result == .thrown) result else .{ .thrown = "Out of memory" };
}

/// Entered. The tweak runtime first, for a lone tweak or a group's shared part, then the part.
fn evalPart(self: *Sessions, session: *Session, a: std.mem.Allocator, source: []const u8, file: tweak.File, part: tweak.Part, values: []const tweak.Value) !engine.Evaluated {
    _ = self;
    const live = session.live.?;
    if (part == .whole or (part == .group and part.group == 0)) {
        const runtime = switch (live.language) {
            .js => tweak_js,
            .lua => tweak_lua,
        };
        switch (try evalCopy(live, a, runtime)) {
            .thrown => |t| return .{ .thrown = t },
            .value => {},
        }
        const set_file = switch (live.language) {
            .js => try std.fmt.allocPrint(a, "__t.file = {f}", .{std.json.fmt(session.name, .{})}),
            .lua => try std.fmt.allocPrint(a, "__t.file = {f}", .{tweak.luaString(session.name)}),
        };
        switch (try evalCopy(live, a, set_file)) {
            .thrown => |t| return .{ .thrown = t },
            .value => {},
        }
        if (live.project_text.len > 0) {
            const set_project = switch (live.language) {
                .js => try std.fmt.allocPrint(a, "__t.project = {f}", .{std.json.fmt(live.project_text, .{})}),
                .lua => try std.fmt.allocPrint(a, "__t.project = {f}", .{tweak.luaString(live.project_text)}),
            };
            switch (try evalCopy(live, a, set_project)) {
                .thrown => |t| return .{ .thrown = t },
                .value => {},
            }
        }
    }
    const code = try tweak.compilePart(a, source, file, part, values);
    return evalCopy(live, a, code);
}

/// Entered. What it gave, kept in `a`.
fn evalCopy(live: *Live, a: std.mem.Allocator, code: []const u8) !engine.Evaluated {
    const buf = try a.alloc(u8, max_result);
    return live.script.eval(code, buf);
}

fn reportPart(self: *Sessions, a: std.mem.Allocator, session: *Session, part: []const u8, result: engine.Evaluated) void {
    switch (result) {
        .thrown => |t| self.sendPart(session.id, part, .thrown, "{s}", .{t}),
        .value => |json| self.sendState(a, session.id, part, json),
    }
}

fn sendState(self: *Sessions, a: std.mem.Allocator, id: u32, part: []const u8, json: []const u8) void {
    const State = struct {
        fields: []const protocol.TweakState.Field = &.{},
        names: []const protocol.TweakState.Name = &.{},
    };
    const state = std.json.parseFromSliceLeaky(State, a, json, .{ .ignore_unknown_fields = true }) catch |err|
        return self.sendPart(id, part, .thrown, "Couldn't read what the tweak made: {t}", .{err});
    publish(a, protocol.topics.tweak, protocol.TweakState{ .session = id, .part = part, .fields = state.fields, .names = state.names });
}

/// One of a group's tweaks or nested groups, with everything under it. Each runs its `off`, then
/// what it made goes, innermost first. The rest stay on.
fn stopPart(self: *Sessions, session: *Session, name: []const u8) void {
    const i = session.findPart(name) orelse return;
    const is_group = session.parts.items[i].group;
    const live = session.live orelse {
        self.gpa.free(session.parts.orderedRemove(i).name);
        return;
    };
    live.script.enter();
    defer live.script.leave();
    // Newest first, so what's in a group goes before it
    var k = session.parts.items.len;
    while (k > i) {
        k -= 1;
        const p = session.parts.items[k];
        if (k != i and !(is_group and p.isUnder(name))) continue;
        live.script.useScope(p.scope);
        self.runOff(session, live, p.name);
        live.script.useScope(null);
        live.script.closeScope(p.scope);
        host.stopTagged(&live.loaded.owner, p.tag);
        _ = session.parts.orderedRemove(k);
        self.gpa.free(p.name);
    }
}

/// Lets it clean up before it all goes, a group's tweaks before its shared part.
fn stopTweak(self: *Sessions, session: *Session) void {
    const live = session.live orelse return;
    live.script.enter();
    defer live.script.leave();
    if (session.parts.items.len == 0) return self.runOff(session, live, "");
    var i = session.parts.items.len;
    while (i > 0) {
        i -= 1;
        const p = session.parts.items[i];
        live.script.useScope(p.scope);
        defer live.script.useScope(null);
        self.runOff(session, live, p.name);
    }
}

/// Entered. Its `off()`, and what it made goes.
fn runOff(_: *Sessions, session: *Session, live: *Live, part: []const u8) void {
    var code_buf: [512]u8 = undefined;
    const code = switch (live.language) {
        .js => std.fmt.bufPrint(&code_buf, "__t.stop({f})", .{std.json.fmt(part, .{})}),
        .lua => std.fmt.bufPrint(&code_buf, "__t.stop({f})", .{tweak.luaString(part)}),
    } catch return log.warn("Tweak {s}'s part {s} has too long a name to stop", .{ session.name, part });
    const was = session.speaking;
    session.speaking = part;
    defer session.speaking = was;
    var buf: [2048]u8 = undefined;
    switch (live.script.eval(code, &buf)) {
        .thrown => |t| log.warn("Tweak {s}{s}{s} off(): {s}", .{ session.name, if (part.len > 0) "." else "", part, t }),
        .value => {},
    }
    live.script.pump();
}

// Sessions

fn open(self: *Sessions, id: u32, name: []const u8, language: Language, thread: Thread) !*Session {
    const session = try self.gpa.create(Session);
    errdefer self.gpa.destroy(session);
    const owned = try self.gpa.dupe(u8, name);
    errdefer self.gpa.free(owned);
    session.* = .{ .owner = self, .id = id, .name = owned, .language = language, .thread = thread };
    try self.sessions.append(self.gpa, session);
    return session;
}

/// Its script, owning what it makes like a plugin does, with Wraith's areas and its project's
/// schemas in scope.
fn makeLive(self: *Sessions, session: *Session, project: []const u8) !*Live {
    const gpa = self.gpa;
    const live = try gpa.create(Live);
    errdefer gpa.destroy(live);
    const name = try std.fmt.allocPrint(gpa, "script.{d}", .{session.id});
    errdefer gpa.free(name);
    const config_dir = try std.fs.path.join(gpa, &.{ self.config_dir, "scripts", name });
    errdefer gpa.free(config_dir);
    const game_config_dir = try std.fs.path.join(gpa, &.{ self.game_config_dir, "scripts", name });
    errdefer gpa.free(game_config_dir);
    live.* = .{ .loaded = undefined, .language = session.language };
    live.loaded.initBare(gpa, name, config_dir, game_config_dir);
    live.loaded.session = true;
    live.loaded.echo = .{ .ctx = session, .write = echoed };
    errdefer {
        live.loaded.owner.close();
        live.loaded.owner.release();
        live.loaded.free();
    }
    // Its plugins can't go while their schemas and services are read
    if (self.loader) |l| l.known.lock.lockShared();
    defer if (self.loader) |l| l.known.lock.unlockShared();
    try useProject(live, gpa, project, self.loader);
    errdefer freeProject(live, gpa);

    live.script = try live.exposed.create(session.language, gpa, .{ .ctx = live, .resolve = resolve, .read = read }, .{ .ctx = session, .f = thrownLater });
    errdefer live.script.deinit();
    const wraith = host.wraith.root(&live.loaded).as(@FieldType(host.wraith.Guest, "wraith"));
    if (wraith.table == null) return error.OutOfMemory;
    try live.exposed.expose(live.script, wraith, if (live.loaded.schemas) |s| s.text else api.wraith_sal, true);
    if (live.with_plugins) try exposeServices(live, gpa, self.loader.?);
    session.live = live;
    return live;
}

/// Its project's schemas as its own, like a plugin's, with those of every plugin that offers
/// services. Ones that don't check out are left out, since the project says why. Under the
/// loader's lock.
fn useProject(live: *Live, gpa: std.mem.Allocator, project: []const u8, loader: ?*PluginLoader) !void {
    live.loaded.project = try gpa.dupe(u8, project);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const own = host.projects.files(project, a);
    var files: std.ArrayList(host.schemas.File) = .empty;
    try files.appendSlice(a, own);
    if (loader) |l| for (l.known.items.items) |k| {
        const loaded = k.loaded orelse continue;
        if (loaded.services.items.len == 0) continue;
        const theirs = loaded.schemas orelse continue;
        // Their dependencies' come with them, which others may have brought already
        outer: for (theirs.files) |f| {
            for (files.items) |have| if (std.mem.eql(u8, have.name, f.name)) continue :outer;
            try files.append(a, f);
        }
    };
    if (files.items.len > own.len) {
        if (host.schemas.fromFiles(files.items)) |s| {
            live.loaded.schemas = s;
            live.with_plugins = true;
        } else |err| log.warn("Script sessions for {s} don't get plugins' services, since their schemas and the project's don't go together ({t})", .{ if (project.len == 0) "your project" else project, err });
    }
    if (own.len == 0) return;
    if (live.loaded.schemas == null) live.loaded.schemas = host.schemas.fromFiles(own) catch null;
    if (live.loaded.schemas == null) return;
    live.project_text = try gpa.dupe(u8, host.projects.bundle(project, a));
}

/// Each plugin that offers services as a module by its name, like `require("unreal")`, the way
/// plugins that depend on it get them. Under the loader's lock. What's called once its plugin's
/// gone just fails with `Gone`.
fn exposeServices(live: *Live, gpa: std.mem.Allocator, loader: *PluginLoader) !void {
    const types = live.exposed.types orelse return;
    var exports: std.ArrayList(engine.Export) = .empty;
    defer exports.deinit(gpa);
    for (loader.known.items.items) |k| {
        const loaded = k.loaded orelse continue;
        if (loaded.services.items.len == 0) continue;
        exports.clearRetainingCapacity();
        for (loaded.services.items) |s| try exports.append(gpa, .{ .name = s.trait, .schema = types, .trait = s.trait, .obj = s.obj });
        try live.script.module(loaded.name, exports.items);
    }
}

fn freeProject(live: *Live, gpa: std.mem.Allocator) void {
    if (live.loaded.project) |p| gpa.free(p);
    gpa.free(live.project_text);
}

/// Stops what it started and forgets its variables.
fn reset(self: *Sessions, session: *Session) void {
    const live = session.live orelse return;
    session.live = null;
    // Scopes go with the script
    for (session.parts.items) |p| self.gpa.free(p.name);
    session.parts.clearRetainingCapacity();
    // Like a plugin going. What it made stops, then its script, then the rest's freed
    live.loaded.owner.close();
    live.script.interrupt();
    live.script.deinit();
    live.loaded.owner.release();
    live.loaded.free();
    self.gpa.free(live.loaded.name);
    self.gpa.free(live.loaded.config_dir);
    self.gpa.free(live.loaded.game_config_dir);
    freeProject(live, self.gpa);
    self.gpa.destroy(live);
}

fn end(self: *Sessions, session: *Session) void {
    self.reset(session);
    session.parts.deinit(self.gpa);
    self.gpa.free(session.name);
    self.gpa.destroy(session);
}

// Its script's needs

/// Only shared libraries, since a session has no folder.
fn resolve(ctx: ?*anyopaque, buf: []u8, _: []const u8, name: []const u8) ?[]const u8 {
    const live: *Live = @ptrCast(@alignCast(ctx.?));
    return scripts.resolveLibrary(buf, name, live.languageName());
}

fn read(ctx: ?*anyopaque, gpa: std.mem.Allocator, name: []const u8) ?[]u8 {
    const live: *Live = @ptrCast(@alignCast(ctx.?));
    return scripts.readLibrary(gpa, name, live.languageName());
}

/// What a callback or task threw.
fn thrownLater(ctx: ?*anyopaque, message: []const u8) void {
    const session: *Session = @ptrCast(@alignCast(ctx.?));
    session.owner.sendPart(session.id, session.speaking, .err, "{s}", .{message});
}

/// What it logs, from any thread.
fn echoed(ctx: *anyopaque, level: std.log.Level, text: []const u8) void {
    const session: *Session = @ptrCast(@alignCast(ctx));
    const kind: protocol.Kind = switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
    session.owner.sendPart(session.id, session.speaking, kind, "{s}", .{text});
}

// Output

fn send(self: *Sessions, id: u32, kind: protocol.Kind, comptime fmt: []const u8, args: anytype) void {
    self.sendPart(id, "", kind, fmt, args);
}

/// From one of a group's tweaks, or its shared part if `part` is empty.
fn sendPart(self: *Sessions, id: u32, part: []const u8, kind: protocol.Kind, comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(self.gpa, fmt, args) catch return;
    defer self.gpa.free(text);
    publish(self.gpa, protocol.topics.output, protocol.Output{ .session = id, .kind = kind, .text = text, .part = part });
}

fn publish(gpa: std.mem.Allocator, topic: []const u8, value: anytype) void {
    const json = std.json.Stringify.valueAlloc(gpa, value, .{}) catch return;
    defer gpa.free(json);
    host.messages.publishFromRuntime(topic, json) catch |err| log.debug("Couldn't send {s}: {t}", .{ topic, err });
}

/// What each session has going, when that changes.
fn report(self: *Sessions) void {
    var now: std.ArrayList(protocol.Running) = .empty;
    defer now.deinit(self.gpa);
    for (self.sessions.items) |s| {
        var r: protocol.Running = .{ .session = s.id, .name = s.name };
        if (s.live) |live| {
            r.frames = host.frame.countOf(&live.loaded);
            r.keybinds = host.keybinds.countOf(&live.loaded);
            r.hooks = host.hooks.countOf(&live.loaded);
        }
        now.append(self.gpa, r) catch return;
    }
    if (!self.report_all and same(self.reported.items, now.items)) return;
    self.report_all = false;
    publish(self.gpa, protocol.topics.sessions, protocol.Sessions{ .sessions = now.items });

    for (self.reported.items) |r| self.gpa.free(r.name);
    self.reported.clearRetainingCapacity();
    for (now.items) |r| {
        var kept = r;
        kept.name = self.gpa.dupe(u8, r.name) catch "";
        self.reported.append(self.gpa, kept) catch {
            self.gpa.free(kept.name);
            self.report_all = true;
            return;
        };
    }
}

fn same(a: []const protocol.Running, b: []const protocol.Running) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        var named = y;
        named.name = x.name;
        if (!std.meta.eql(x, named) or !std.mem.eql(u8, x.name, y.name)) return false;
    }
    return true;
}

const tests = struct {
    const testing = std.testing;

    const Rig = @import("testing.zig").Rig;

    test "sessions run, reset and stop, in JS and Lua" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();

        try rig.send(protocol.topics.run, protocol.Run{ .session = 1, .name = "one", .code = "var x = 40; x + 2" });
        try rig.send(protocol.topics.run, protocol.Run{ .session = 2, .code = "frame.onFrame(() => {}); typeof memory" });
        rig.step();
        try testing.expectEqualStrings("var x = 40; x + 2", rig.heard.line(0));
        try testing.expectEqualStrings("42", rig.heard.line(1));
        try testing.expectEqual(2, rig.heard.lines.items[3].session);
        try testing.expectEqualStrings("object", rig.heard.line(3));
        try testing.expectEqual(1, rig.heard.reports);
        try testing.expectEqual(2, rig.heard.sessions.items.len);
        try testing.expectEqual(1, rig.heard.sessions.items[1].frames);

        // Only changes are reported
        rig.step();
        try testing.expectEqual(1, rig.heard.reports);

        try rig.send(protocol.topics.reset, protocol.Target{ .session = 2 });
        try rig.send(protocol.topics.stop, protocol.Target{ .session = 1 });
        try rig.send(protocol.topics.run, protocol.Run{ .session = 2, .code = "typeof x" });
        rig.step();
        try testing.expectEqualStrings("undefined", rig.heard.line(5));
        try testing.expectEqual(2, rig.heard.reports);
        try testing.expectEqual(1, rig.heard.sessions.items.len);
        try testing.expectEqual(0, rig.heard.sessions.items[0].total());

        // What it logs comes back, then what it threw
        try rig.send(protocol.topics.run, protocol.Run{ .session = 2, .code = "log.info('hi'); throw new Error('nope')" });
        rig.step();
        try testing.expectEqual(.info, rig.heard.lines.items[7].kind);
        try testing.expectEqualStrings("hi", rig.heard.line(7));
        try testing.expectEqual(.thrown, rig.heard.lines.items[8].kind);
        try testing.expect(std.mem.indexOf(u8, rig.heard.line(8), "nope") != null);

        // Lua, and a session that changes language starts afresh
        try rig.send(protocol.topics.run, protocol.Run{ .session = 3, .language = "lua", .code = "x = 40; return x + 2" });
        try rig.send(protocol.topics.run, protocol.Run{ .session = 2, .language = "lua", .code = "return type(memory.readU32)" });
        rig.step();
        try testing.expectEqualStrings("42", rig.heard.line(10));
        try testing.expectEqualStrings("function", rig.heard.line(12));
    }

    test "JS can await at the top, like in the Console" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        const Lines = struct {
            fn has(r: *Rig, kind: protocol.Kind, text: []const u8) bool {
                for (r.heard.lines.items, 0..) |l, i| {
                    if (l.kind == kind and std.mem.indexOf(u8, r.heard.line(i), text) != null) return true;
                }
                return false;
            }
        };
        // What it gave shows once it's done
        try rig.run(5, "js", "await Promise.resolve(41 + 1)");
        try testing.expect(Lines.has(&rig, .info, "42"));
        // A name it makes outlasts it, like at the top
        try rig.run(5, "js", "const hp = await Promise.resolve(7)");
        try testing.expectEqualStrings("7", rig.eval(5, "hp"));
        // Its error's logged too, which is expected here
        const saved = core.log.mute(&.{.plugin});
        defer core.log.setFilter(saved);
        try rig.run(5, "js", "await Promise.reject(new Error('nope'))");
        try testing.expect(Lines.has(&rig, .err, "nope"));
    }

    test "a tweak starts with its project's schemas and names" {
        const Names = @import("../Names.zig");
        const SharedSchemas = @import("../SharedSchemas.zig");
        Names.global = .init(testing.allocator);
        defer Names.global.deinit();
        SharedSchemas.global = .init(testing.allocator);
        defer SharedSchemas.global.deinit();
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();

        var gold: u32 = 70;
        var buf: [128]u8 = undefined;
        const list = try std.fmt.bufPrint(&buf, ".{{ .items = .{{ .{{ .id = \"gold\", .address = \"0x{x}\" }} }} }}", .{@intFromPtr(&gold)});
        _ = host.projects.set(.{ .key = "kai_tables", .title = "Kai Tables", .schemas = &.{.{ .name = "schemas/game.sal", .text = "struct Bank { u32 mira; u32 gold; }\n" }}, .addresses = list });
        defer host.projects.keep(&.{});
        try testing.expect(Names.global.has(.plugin, "kai_tables.gold"));

        // Its project's types under its own, and its names without the mod's in front
        try rig.send(protocol.topics.run, protocol.Run{
            .session = 4,
            .name = "t",
            .code = "@schema\nstruct Wallet { Bank bank; }\n@js\nglobalThis.both = String(!!types.Wallet && !!types.Bank); globalThis.at = String(addresses.resolve(\"gold\", []));",
            .tweak = true,
            .project = "kai_tables",
        });
        rig.step();
        try rig.expectFine();
        try testing.expectEqualStrings("true", rig.eval(4, "both"));
        const at = try std.fmt.bufPrint(&buf, "{d}", .{@intFromPtr(&gold)});
        try testing.expectEqualStrings(at, rig.eval(4, "at"));
        // A script session has them as its `schema` module
        try rig.send(protocol.topics.run, protocol.Run{ .session = 6, .language = "lua", .code = "return tostring(require('schema').Bank ~= nil)", .project = "kai_tables" });
        rig.step();
        try rig.expectFine();
        try testing.expectEqualStrings("true", rig.heard.lines.items[rig.heard.lines.items.len - 1].text);
    }

    noinline fn tweaked(x: u32) callconv(.c) u32 {
        var y = x;
        asm volatile (""
            : [y] "+r" (y),
        );
        return y + 1;
    }

    test "tweaks report their data and stopping undoes them" {
        // A sig that finds nothing warns, which tests treat as noise
        const saved_level = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved_level;
        const a = testing.allocator;
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();

        // Through a pointer, like a CE [address]
        const Pointer = struct {
            var to: usize = 0;
        };
        Pointer.to = @intFromPtr(&tweaked);
        // The first argument's in ECX on x64, on the stack on x86
        const first_arg = if (@import("builtin").cpu.arch == .x86_64) "ecx" else "[esp+4]";
        const source = try std.fmt.allocPrint(a,
            \\@tweak Add more
            \\@data
            \\  [Label("By")] u32 by = 5
            \\  [Choices(picks)] u32 pick
            \\@sym at = [0x{x}] + 1 - 1
            \\@inject at
            \\  mov eax, {s} // the first argument
            \\  add eax, [by]
            \\  ret
            \\@js
            \\function picks() {{ return [[1, "One"], {{ value: 2, label: "Two" }}, "3:Three"]; }}
            \\function off() {{}}
        , .{ @intFromPtr(&Pointer.to), first_arg });
        defer a.free(source);
        try rig.send(protocol.topics.run, protocol.Run{ .session = 5, .name = "add", .code = source, .tweak = true, .values = &.{.{ .name = "by", .value = 7 }} });
        rig.step();
        try rig.expectFine();
        try testing.expectEqual(8, tweaked(1));
        try testing.expectEqualStrings(": by pick at [One] [Two] [Three]", rig.heard.states.items[0]);
        const by: *u32 = @ptrFromInt(@as(usize, @intCast(rig.heard.by)));
        by.* = 10;
        try testing.expectEqual(11, tweaked(1));

        try rig.send(protocol.topics.stop, protocol.Target{ .session = 5 });
        rig.step();
        try testing.expectEqual(2, tweaked(1));
        try testing.expectEqual(null, rig.sessions.find(5));

        // Problems say the tweak's line, and nothing's left on
        const cases = [_]struct { []const u8, []const u8 }{
            .{ "@js\n\nnull.x", ":3" },
            .{ "@data\n  u8 x\n@patch x + nope\n  nop", "line 3: there's no nope" },
            .{ "@data\n  u8 x\n@inject x\n  nop\n  bogus", "line 5: " },
            .{ "@bytes 0x10\n  90 9", "line 2: 9 isn't a byte" },
            .{ "@schema\nstruct A { u32 a; }\nstruct B { nope b; }", "line 3: " },
            .{ "@data\n  [Choices(none)] u8 x", "line 2: there's no function none" },
            .{ "@sym", "line 1: it's @sym name = where" },
            .{ "@sym p = [0] + 4EFF", "line 1: can't read [0x0]" },
        };
        for (cases, 10..) |case, id| {
            rig.forget();
            try rig.send(protocol.topics.run, protocol.Run{ .session = @intCast(id), .name = "bad", .code = case[0], .tweak = true });
            rig.step();
            const t = rig.heard.thrown() orelse return error.TestExpectedError;
            if (std.mem.indexOf(u8, t, case[1]) == null or std.mem.indexOf(u8, t, "tweak.js") != null) {
                std.debug.print("{s}\n  wanted: {s}\n  got: {s}\n", .{ case[0], case[1], t });
                return error.TestUnexpectedResult;
            }
        }
    }

    test "a group's shared part comes with its first tweak and goes with its last" {
        const a = testing.allocator;
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();

        const Pointer = struct {
            var to: usize = 0;
            var shared_off: u32 = 0;
        };
        Pointer.to = @intFromPtr(&tweaked);
        Pointer.shared_off = 0;
        const first_arg = if (@import("builtin").cpu.arch == .x86_64) "ecx" else "[esp+4]";
        const source = try std.fmt.allocPrint(a,
            \\@group "Combat"
            \\@data
            \\  u32 base = 5
            \\@sym at = [0x{x}]
            \\@js
            \\function itemName(id) {{ return "item" + id; }}
            \\function off() {{ memory.writeU32(0x{x}, 1); }}
            \\@tweak "One"
            \\@data
            \\  [Choices(items)] u32 pick
            \\@inject at
            \\  mov eax, {s}
            \\  add eax, 5
            \\  ret
            \\@js
            \\var mine = "one";
            \\function items() {{ return [[1, itemName(1)]]; }}
            \\frame.onFrame(() => {{}});
            \\@tweak "Two"
            \\@js
            \\var mine = "two";
            \\frame.onFrame(() => {{}});
            \\function off() {{ globalThis.twoOff = data.base; }}
            \\@tweak "Three"
            \\@data
            \\  [Choices(items)] u32 pick
            \\@js
        , .{ @intFromPtr(&Pointer.to), @intFromPtr(&Pointer.shared_off), first_arg });
        defer a.free(source);
        for ([_][]const u8{ "One", "Two", "Three" }) |part| try rig.send(protocol.topics.run, protocol.Run{ .session = 7, .name = "combat", .code = source, .tweak = true, .part = part });
        rig.step();

        // The shared part first, then each tweak with its own names, calling the shared part
        try testing.expectEqual(3, rig.heard.states.items.len);
        try testing.expectEqualStrings(": base at", rig.heard.states.items[0]);
        try testing.expectEqualStrings("One: pick [item1]", rig.heard.states.items[1]);
        try testing.expectEqualStrings("Two:", rig.heard.states.items[2]);
        try testing.expectEqual(6, tweaked(1));
        // Three can't see One's items, and only it failed
        const t = rig.heard.thrown() orelse return error.TestExpectedError;
        try testing.expect(std.mem.indexOf(u8, t, "there's no function items") != null);
        try testing.expectEqualStrings("Three", rig.heard.lines.items[rig.heard.lines.items.len - 1].part);

        // Each tweak's top level is its own
        try testing.expectEqualStrings("undefined", rig.eval(7, "typeof mine"));
        try testing.expectEqualStrings("function", rig.eval(7, "typeof itemName"));
        const loaded = rig.loadedOf(7);
        try testing.expectEqual(2, host.frame.countOf(loaded));

        // One goes on its own, and only what it made goes
        try rig.send(protocol.topics.stop, protocol.Target{ .session = 7, .part = "One" });
        rig.step();
        try testing.expectEqual(2, tweaked(1));
        try testing.expectEqual(1, host.frame.countOf(loaded));
        // Two's off, not the shared part's
        try rig.send(protocol.topics.stop, protocol.Target{ .session = 7, .part = "Two" });
        rig.step();
        try testing.expectEqualStrings("5", rig.eval(7, "globalThis.twoOff"));
        try testing.expectEqual(0, Pointer.shared_off);
        try testing.expectEqual(0, host.frame.countOf(loaded));

        try rig.send(protocol.topics.stop, protocol.Target{ .session = 7 });
        rig.step();
        try testing.expectEqual(null, rig.sessions.find(7));
        try testing.expectEqual(1, Pointer.shared_off);

        // A shared part that throws takes the group down
        rig.forget();
        try rig.send(protocol.topics.run, protocol.Run{ .session = 8, .name = "g", .code = "@group G\n@js\nthrow new Error('shared broke')\n@tweak A\n@js", .tweak = true, .part = "A" });
        rig.step();
        const broke = rig.heard.thrown() orelse return error.TestExpectedError;
        try testing.expect(std.mem.indexOf(u8, broke, "shared broke") != null);
        try testing.expectEqualStrings("", rig.heard.lines.items[0].part);
        try testing.expectEqual(null, rig.sessions.find(8));
    }

    // a + b + 103, as 2, 2, 3, 3, 3 and 3 byte instructions
    comptime {
        if (@import("builtin").cpu.arch == .x86_64) asm (
            \\.text
            \\.globl wraith_session_tweak_target
            \\wraith_session_tweak_target:
            \\  movl %ecx, %eax
            \\  addl %edx, %eax
            \\  addl $100, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  retq
        );
    }
    extern fn wraith_session_tweak_target(a: u32, b: u32) callconv(.c) u32;

    test "a patch replaces code and an inject goes before it" {
        if (@import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;
        // The one that throws warns
        const saved_level = testing.log_level;
        testing.log_level = .err;
        defer testing.log_level = saved_level;
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        const at = @intFromPtr(&wraith_session_tweak_target);
        try testing.expectEqual(113, wraith_session_tweak_target(1, 9));

        const Case = struct { source: []const u8, result: ?u32, err: []const u8 = "" };
        const cases = [_]Case{
            // Like the XP multiplier. It's longer than what it replaces, so it goes in a cave
            .{ .source = "@data\n  u32 times = 3\n@patch 0x{x} expect \"89 C8\"\n  mov eax, ecx\n  imul eax, [times]", .result = 3 + 9 + 103 },
            // Fits in place
            .{ .source = "@patch 0x{x}\n  mov eax, edx", .result = 9 + 9 + 103 },
            // Two instructions by size, and `original` runs them as they were
            .{ .source = "@patch 0x{x} (4)\n  cmp ecx, 2\n  je original\n  xor eax, eax", .result = 103 },
            .{ .source = "@inject 0x{x}\n  add ecx, 5", .result = 6 + 9 + 103 },
            .{ .source = "@patch 0x{x} (3)\n  nop", .result = null, .err = "line 1: 3 bytes ends inside an instruction. The instructions there end at 2, 4, 7" },
            // The same in JS, as a mid hook
            .{ .source = "@data\n  u32 times = 3\n@patch 0x{x} expect \"89 C8\"\n  @js\n  cpu.rax = Number(cpu.rcx) * data.times", .result = 3 + 9 + 103 },
            .{ .source = "@patch 0x{x} (4)\n  @js\n  if (Number(cpu.rcx) == 2) original(); else cpu.rax = 0", .result = 103 },
            .{ .source = "@patch 0x{x} (4)\n  @js\n  if (Number(cpu.rcx) == 1) original(); else cpu.rax = 0", .result = 113 },
            .{ .source = "@inject 0x{x}\n  @js\n  cpu.rcx = Number(cpu.rcx) + 5", .result = 6 + 9 + 103 },
            // Skipping the mov eax, ecx it goes before
            .{ .source = "@inject 0x{x}\n  @js\n  cpu.rax = 50\n  resume()", .result = 50 + 9 + 103 },
            .{ .source = "@patch 0x{x}\n  @asm\n  mov eax, edx", .result = 9 + 9 + 103 },
            // A throw runs the code it replaces, and the tweak stays on
            .{ .source = "@patch 0x{x} (4)\n  @js\n  cpu.rax = 0\n  throw new Error('nope')", .result = 113 },
            .{ .source = "@hook 0x{x} as u32 (u32 a, u32 b)\n  return original(a, b + 1) * 2", .result = (1 + 10 + 103) * 2 },
            .{ .source = "@patch 0x{x} (3)\n  @js\n  cpu.rax = 0", .result = null, .err = "line 1: " },
            .{ .source = "@patch 0x{x} expect \"90 90\"\n  @js\n  cpu.rax = 0", .result = null, .err = "line 1: " },
            // expect as asm covers both instructions
            .{ .source = "@patch 0x{x} expect \"mov eax, ecx; add eax, edx\"\n  xor eax, eax", .result = 103 },
            .{ .source = "@patch 0x{x} expect \"mov eax, ecx; add eax, edx\"\n  @js\n  cpu.rax = 0", .result = 103 },
            .{ .source = "@patch 0x{x} expect \"mov eax, ecx; sub eax, edx\"\n  nop", .result = null, .err = "line 1: expected `sub eax, edx` but found `add eax, edx`" },
            .{ .source = "@patch 0x{x} expect \"mov eax, ecx; sub eax, edx\"\n  @js\n  cpu.rax = 0", .result = null, .err = "line 1: " },
        };
        inline for (cases, 100..) |case, id| {
            rig.forget();
            var buf: [256]u8 = undefined;
            const source = try std.fmt.bufPrint(&buf, case.source, .{at});
            try rig.send(protocol.topics.run, protocol.Run{ .session = @intCast(id), .name = "t", .code = source, .tweak = true });
            rig.step();
            if (case.result) |expected| {
                if (rig.heard.thrown()) |t| {
                    std.debug.print("{s}\n  threw: {s}\n", .{ source, t });
                    return error.TestUnexpectedResult;
                }
                const got = wraith_session_tweak_target(1, 9);
                if (got != expected) {
                    std.debug.print("{s}\n  wanted {d}, got {d}\n", .{ source, expected, got });
                    return error.TestUnexpectedResult;
                }
                try rig.send(protocol.topics.stop, protocol.Target{ .session = @intCast(id) });
                rig.step();
                try testing.expectEqual(113, wraith_session_tweak_target(1, 9));
            } else {
                const t = rig.heard.thrown() orelse return error.TestExpectedError;
                if (std.mem.indexOf(u8, t, case.err) == null) {
                    std.debug.print("{s}\n  wanted: {s}\n  got: {s}\n", .{ source, case.err, t });
                    return error.TestUnexpectedResult;
                }
                try testing.expectEqual(113, wraith_session_tweak_target(1, 9));
            }
        }
    }

    test "nested groups see their groups' functions and stop inside out" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        const source =
            \\@group "Kai"
            \\@js
            \\globalThis.order = [];
            \\function kaiName(id) { return "kai" + id; }
            \\@group "Combat"
            \\@data
            \\  u32 hits = 3
            \\@js
            \\function combatHelper() { return kaiName(2) + "!"; }
            \\var mine = "combat";
            \\function off() { order.push("Combat"); }
            \\@tweak "Max bravery"
            \\@data
            \\  [Choices(items)] u32 pick
            \\@js
            \\function items() { return [[1, combatHelper()], [2, kaiName(1)]]; }
            \\globalThis.seen = combatHelper() + data.hits;
            \\function off() { order.push("Max bravery"); }
            \\@group "Party"
            \\@js
            \\var count = 0;
            \\function off() { order.push("Party"); }
            \\@tweak "Max HP"
            \\@js
            \\count += 1;
            \\globalThis.hp = combatHelper() + count + mine;
            \\frame.onFrame(() => {});
            \\function off() { order.push("Max HP"); }
            \\@end
            \\@end
            \\@group "Other"
            \\@js
            \\var mine = "other";
            \\@tweak "Peek"
            \\@js
            \\globalThis.peek = typeof combatHelper + ":" + mine;
            \\@end
            \\@group "Broken"
            \\@js
            \\throw new Error("broke");
            \\@tweak "Inside"
            \\@js
            \\@end
        ;
        for ([_][]const u8{ "Combat", "Combat/Max bravery", "Combat/Party", "Combat/Party/Max HP", "Other", "Other/Peek", "Broken", "Broken/Inside" }) |part|
            try rig.send(protocol.topics.run, protocol.Run{ .session = 9, .name = "kai", .code = source, .tweak = true, .part = part });
        rig.step();

        const want = [_][]const u8{ ":", "Combat: hits", "Combat/Max bravery: pick [kai2!] [kai1]", "Combat/Party:", "Combat/Party/Max HP:", "Other:", "Other/Peek:" };
        try testing.expectEqual(want.len, rig.heard.states.items.len);
        for (want, rig.heard.states.items) |w, got| try testing.expectEqualStrings(w, got);
        // The broken group says so, and what's in it can't come up
        var thrown_parts: [2][]const u8 = undefined;
        var n: usize = 0;
        for (rig.heard.lines.items) |l| if (l.kind == .thrown and n < 2) {
            thrown_parts[n] = l.part;
            n += 1;
        };
        try testing.expectEqual(2, n);
        try testing.expectEqualStrings("Broken", thrown_parts[0]);
        try testing.expectEqualStrings("Broken/Inside", thrown_parts[1]);

        try testing.expectEqualStrings("kai2!3", rig.eval(9, "globalThis.seen"));
        try testing.expectEqualStrings("kai2!1combat", rig.eval(9, "globalThis.hp"));
        // Sibling groups keep their own
        try testing.expectEqualStrings("undefined:other", rig.eval(9, "globalThis.peek"));
        try testing.expectEqualStrings("undefined", rig.eval(9, "typeof combatHelper"));
        const loaded = rig.loadedOf(9);
        try testing.expectEqual(1, host.frame.countOf(loaded));

        // Combat goes with everything in it, innermost first, and Other stays
        try rig.send(protocol.topics.stop, protocol.Target{ .session = 9, .part = "Combat" });
        rig.step();
        try testing.expectEqualStrings("Max HP,Party,Max bravery,Combat", rig.eval(9, "order.join()"));
        try testing.expectEqual(0, host.frame.countOf(loaded));
        const left = rig.sessions.find(9).?.parts.items;
        try testing.expectEqual(3, left.len);
        try testing.expectEqualStrings("Other/Peek", left[2].name);
    }

    test "@globals shared takes plain writes, vars and functions, and off and tick stay each tweak's" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        const source =
            \\@group "Kai"
            \\@globals shared
            \\@js
            \\globalThis.order = [];
            \\@tweak "One"
            \\@data
            \\  [Choices(items)] u32 pick
            \\@js
            \\var sharedX = 40;
            \\sharedX += 1;
            \\function helper() { return sharedX + 1; }
            \\function items() { return [[1, "one"]]; }
            \\function tick() { globalThis.ticksOne = (globalThis.ticksOne || 0) + 1; }
            \\function off() { order.push("One"); }
            \\@tweak "Two"
            \\@data
            \\  [Choices(items)] u32 pick
            \\@js
            \\globalThis.twoSaw = helper();
            \\function items() { return [[2, "two"]]; }
            \\function tick() { globalThis.ticksTwo = (globalThis.ticksTwo || 0) + 10; }
            \\function off() { order.push("Two"); }
            \\@tweak "Late"
            \\@js
            \\globalThis.lateSaw = sharedX + ":" + deepWrote;
            \\@group "Inner"
            \\@js
            \\@tweak "Deep"
            \\@js
            \\globalThis.deepSaw = helper();
            \\deepWrote = "deep";
            \\@end
            \\@group "Own"
            \\@globals shared
            \\@js
            \\@tweak "Writer"
            \\@js
            \\var ownX = "own";
            \\plainOwn = 1;
            \\@tweak "Reader"
            \\@js
            \\globalThis.readerSaw = typeof ownX + ":" + typeof plainOwn + ":" + sharedX;
            \\@end
        ;
        for ([_][]const u8{ "One", "Two", "Inner", "Inner/Deep", "Own", "Own/Writer", "Own/Reader" }) |part| try rig.runPart(3, "kai", source, part);
        try rig.expectFine();
        // A sibling and a tweak in a nested group both see One's var and function
        try testing.expectEqualStrings("42", rig.eval(3, "globalThis.twoSaw"));
        try testing.expectEqualStrings("42", rig.eval(3, "globalThis.deepSaw"));
        // A nested group's own sharing takes its writes, and it still sees the file's
        try testing.expectEqualStrings("string:number:41", rig.eval(3, "globalThis.readerSaw"));
        try testing.expectEqualStrings("undefined undefined", rig.eval(3, "typeof ownX + ' ' + typeof plainOwn"));
        // Choices, tick and off are each tweak's own
        try testing.expectEqualStrings("One: pick [one]", rig.heard.states.items[1]);
        try testing.expectEqualStrings("Two: pick [two]", rig.heard.states.items[2]);
        _ = rig.eval(3, "globalThis.ticksOne = 0; globalThis.ticksTwo = 0");
        host.frame.run();
        host.frame.run();
        try testing.expectEqualStrings("2 20", rig.eval(3, "ticksOne + ' ' + ticksTwo"));
        try rig.stopPart(3, "Two");
        try rig.stopPart(3, "One");
        try testing.expectEqualStrings("Two,One", rig.eval(3, "order.join()"));

        // What One and Deep wrote outlives them
        try rig.stopPart(3, "Inner");
        try rig.runPart(3, "kai", source, "Late");
        try testing.expectEqualStrings("41:deep", rig.eval(3, "globalThis.lateSaw"));
        // and goes when its group stops
        try rig.stopPart(3, "Own");
        try rig.runPart(3, "kai", source, "Own");
        try rig.runPart(3, "kai", source, "Own/Reader");
        try testing.expectEqualStrings("undefined:undefined:41", rig.eval(3, "globalThis.readerSaw"));
        try testing.expectEqual(null, rig.heard.thrown());

        // Without it each tweak's top level is its own
        const plain =
            \\@group "Plain"
            \\@js
            \\@tweak "A"
            \\@js
            \\var x = 1;
            \\function f() {}
            \\@tweak "B"
            \\@js
            \\globalThis.bSaw = typeof x + ":" + typeof f;
        ;
        for ([_][]const u8{ "A", "B" }) |part| try rig.runPart(4, "plain", plain, part);
        try testing.expectEqualStrings("undefined:undefined", rig.eval(4, "globalThis.bSaw"));
    }

    test "@use installs a library before the group's code, and its handle stops with it" {
        const Libraries = @import("../Libraries.zig");
        const Owner = @import("tuft_event").Owner;
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        var owner: Owner = .init("libs");
        defer Libraries.global.removeOwner(&owner);
        const Stopped = struct {
            var js: u32 = 0;
            var lua: u32 = 0;
        };
        Stopped.js = 0;
        Stopped.lua = 0;
        var js_buf: [256]u8 = undefined;
        try Libraries.global.add(.{ .owner = &owner, .name = "kit", .language = "js", .source = try std.fmt.bufPrint(&js_buf,
            \\exports.install = (env, options) => {{
            \\  env.installed = options.name;
            \\  return {{ stop() {{ memory.writeU32(0x{x}, 1); }} }};
            \\}};
        , .{@intFromPtr(&Stopped.js)}) });
        try Libraries.global.add(.{ .owner = &owner, .name = "util", .language = "js", .source = "exports.twice = (x) => x * 2;" });
        var lua_buf: [256]u8 = undefined;
        try Libraries.global.add(.{ .owner = &owner, .name = "kit", .language = "lua", .source = try std.fmt.bufPrint(&lua_buf,
            \\local M = {{}}
            \\function M.install(env, options)
            \\  env.installed = options.name
            \\  return {{ stop = function() memory:writeU32(0x{x}, 1) end }}
            \\end
            \\return M
        , .{@intFromPtr(&Stopped.lua)}) });
        try Libraries.global.add(.{ .owner = &owner, .name = "util", .language = "lua", .source = "return { twice = function(x) return x * 2 end }" });

        try rig.runPart(3, "kai", "@group \"Kai\"\n@use kit\n@use util\n@js\nglobalThis.seen = installed + ':' + util.twice(2);\n@tweak \"One\"\n@js\n", "One");
        try rig.runPart(4, "kai", "@group \"Kai\"\n@use kit\n@use util\n@lua\n_G.seen = installed .. ':' .. util.twice(2)\n@tweak \"One\"\n@lua\n", "One");
        try rig.expectFine();
        try testing.expectEqualStrings("Kai:4", rig.eval(3, "globalThis.seen"));
        try testing.expectEqualStrings("Kai:4", rig.eval(4, "seen"));

        try rig.send(protocol.topics.stop, protocol.Target{ .session = 3 });
        try rig.send(protocol.topics.stop, protocol.Target{ .session = 4 });
        rig.step();
        try testing.expectEqual(1, Stopped.js);
        try testing.expectEqual(1, Stopped.lua);

        // One that can't load fails on its line
        try rig.runPart(5, "bad", "@tweak \"X\"\n@use nope\n@js\n", "");
        const t = rig.heard.thrown() orelse return error.TestExpectedError;
        try testing.expect(std.mem.indexOf(u8, t, "line 2: @use nope: ") != null);
    }

    test "Lua tweaks run in Lua sessions" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();

        const Seen = struct {
            var off: u32 = 0;
        };
        Seen.off = 0;
        var buf: [512]u8 = undefined;
        const source = try std.fmt.bufPrint(&buf,
            \\@group "Kai"
            \\@data
            \\  u32 base = 5
            \\@lua
            \\function off() memory:writeU32(0x{x}, 1) end
            \\@tweak "One"
            \\@lua
            \\mine = "one"
            \\frame:onFrame(function() end)
        , .{@intFromPtr(&Seen.off)});
        try rig.send(protocol.topics.run, protocol.Run{ .session = 9, .name = "kai", .code = source, .tweak = true, .part = "One" });
        rig.step();
        try rig.expectFine();
        try testing.expectEqual(2, rig.heard.states.items.len);
        try testing.expectEqualStrings(": base", rig.heard.states.items[0]);
        try testing.expectEqual(1, host.frame.countOf(rig.loadedOf(9)));

        try rig.send(protocol.topics.stop, protocol.Target{ .session = 9 });
        rig.step();
        try testing.expectEqual(null, rig.sessions.find(9));
        try testing.expectEqual(1, Seen.off);
    }
};

test {
    _ = tests;
    _ = repl;
}
