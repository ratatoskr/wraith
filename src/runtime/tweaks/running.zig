//! Running tweaks: a file's in a script session of its language's provider, a plugin's through its
//! callback. Everything in a group's file shares the file's session. A group's shared part is up
//! while its own box is on or anything in it is. It comes up before what's in it, outermost
//! first, and once the last reason goes it stops with everything in it, innermost first.
//! Every change of a tweak's `state` goes through the few functions at the top. While it runs its
//! fields are read from and written to the game's memory and its names are published.

const std = @import("std");

const api = @import("wraith_api");
const core = @import("wraith_core");
const mem = @import("tuft_mem");

const Tweaks = @import("../Tweaks.zig");
const Tweak = @import("Tweak.zig");
const Names = @import("../Names.zig");
const plugin_tweaks = @import("../host/tweaks.zig");
const definitions = @import("definitions.zig");
const values = @import("values.zig");

const protocol = api.script;
const format = api.tweak;
const log = core.log.scoped(.wraith_runtime);

/// Sessions start here so they don't meet the workbench's.
pub const first_session = 1 << 24;

/// Under the lock. Wanted, so it starts on a tick. A group's own box goes on, and its shared part
/// comes up on a tick if it isn't already.
pub fn request(t: *Tweak) void {
    if (t.is_group) {
        t.own = true;
        if (!t.state.started()) t.state = .waiting;
        return;
    }
    t.state = .waiting;
}

/// Under the lock. A group's shared part has to be up, since it's on or something in it is.
pub fn needsUp(tw: *Tweaks, g: *const Tweak) bool {
    return g.own or anyInside(tw, g);
}

/// Under the lock. Something in group `g` is on, at any depth.
pub fn anyInside(tw: *Tweaks, g: *const Tweak) bool {
    for (tw.list.items) |c| if (c.group == g) {
        if (if (c.is_group) needsUp(tw, c) else c.state.wanted()) return true;
    };
    return false;
}

/// Under the lock. On or up, or for a group anything in it is.
pub fn active(tw: *Tweaks, t: *const Tweak) bool {
    if (t.state.started()) return true;
    return if (t.is_group) needsUp(tw, t) else t.state.wanted();
}

/// Under the lock. Its box. A group's turns its direct children on or off as its `@children`
/// says, and groups among them do the same with theirs. True if what's kept on changed.
pub fn setOn(tw: *Tweaks, t: *Tweak, on: bool) bool {
    defer tw.changed();
    if (t.file == null and !t.is_group) {
        if (t.state.wanted() == on) return false;
        if (on) request(t) else {
            turnOff(tw, t);
            clearProblem(tw, t);
        }
        return t.def.mode != .action;
    }
    const changed = cascade(tw, t, on);
    settle(tw, t.fileOf());
    return changed;
}

/// Under the lock. Like `setOn`, but what's going off is only told to its session by `settle`.
fn cascade(tw: *Tweaks, t: *Tweak, on: bool) bool {
    if (!t.is_group) {
        if (t.state.wanted() == on) return false;
        if (on) request(t) else {
            offOne(t);
            clearProblem(tw, t);
        }
        return t.def.mode != .action;
    }
    // Already so, its `@children` still says what happens to what's in it
    var changed = t.own != on;
    if (on) request(t) else t.own = false;
    clearProblem(tw, t);
    if (if (on) t.children.on else t.children.off) {
        for (tw.list.items) |c| if (c.group == t and (c.is_group or c.def.mode == .toggle)) {
            changed = cascade(tw, c, on) or changed;
        };
    }
    return changed;
}

/// Under the lock. Off, with its session told once `settle` knows whether its group goes too.
fn offOne(t: *Tweak) void {
    if (t.is_group) {
        t.own = false;
        return;
    }
    if (t.state.started()) t.stop_pending = true;
    t.state = .off;
}

/// Under the lock. Stopped if it's started and waits to start again, to run it as it is now. A
/// group goes with everything in it, and what was on in it starts again too.
pub fn restart(tw: *Tweaks, t: *Tweak) void {
    if (t.file == null and !t.is_group) {
        stopSession(tw, t);
        t.state = .waiting;
        return;
    }
    if (!t.is_group) {
        if (t.state.started()) {
            send(tw, protocol.topics.stop, protocol.Target{ .session = t.sessionOf(), .part = t.part });
            clearLive(t);
        }
        t.stop_pending = false;
        t.state = .waiting;
        return;
    }
    if (!t.state.started()) return;
    stopGroup(tw, t);
    for (tw.list.items) |c| if (c == t or c.isUnder(t)) {
        if (c.is_group) {
            if (c.own) c.state = .waiting;
        } else if (c.state.wanted()) c.state = .waiting;
    };
}

/// Under the lock. Stopped if it's started. Any problem stays for the caller to clear. A group
/// turns off everything in it.
pub fn turnOff(tw: *Tweaks, t: *Tweak) void {
    if (t.file == null and !t.is_group) {
        stopSession(tw, t);
        t.state = .off;
        return;
    }
    if (t.is_group) for (tw.list.items) |c| if (c.isUnder(t)) offOne(c);
    offOne(t);
    settle(tw, t.fileOf());
}

/// Under the lock. Tells a group's file's session what's off now. A group that's not needed
/// anymore goes with everything in it at once, from the outside in.
pub fn settle(tw: *Tweaks, file: *Tweak) void {
    if (file.is_group) settleIn(tw, file);
}

fn settleIn(tw: *Tweaks, t: *Tweak) void {
    if (!t.is_group) {
        if (!t.stop_pending) return;
        t.stop_pending = false;
        send(tw, protocol.topics.stop, protocol.Target{ .session = t.sessionOf(), .part = t.part });
        clearLive(t);
        return;
    }
    if (needsUp(tw, t)) {
        for (tw.list.items) |c| if (c.group == t) settleIn(tw, c);
        return;
    }
    if (t.state.started()) return stopGroup(tw, t);
    // Nothing in it can be started without it
    for (tw.list.items) |c| if (c == t or c.isUnder(t)) {
        c.stop_pending = false;
        if (c.is_group and c.state == .waiting) c.state = .off;
    };
}

/// Under the lock. Tells its session a group's going with everything in it, and takes their data
/// and names. The file's own takes the whole session.
fn stopGroup(tw: *Tweaks, g: *Tweak) void {
    if (g.file == null) {
        send(tw, protocol.topics.stop, protocol.Target{ .session = g.session });
        dropSession(tw, g);
    } else send(tw, protocol.topics.stop, protocol.Target{ .session = g.sessionOf(), .part = g.part });
    for (tw.list.items) |c| if (c == g or c.isUnder(g)) {
        c.stop_pending = false;
        clearLive(c);
        if (c.is_group) c.state = .off;
    };
}

/// Under the lock. Sends it to its session or plugin. What's in a group's file brings up the
/// groups it's in first, outermost first. The file's own comes up with what's first in its
/// session, so it only gets a run of its own when it's on by itself.
fn start(tw: *Tweaks, t: *Tweak) void {
    if (t.plugin != null) {
        clearProblem(tw, t);
        for (t.def.fields) |d| queueCall(tw, t, .changed, d.name, tw.kept.stored(t.name, d));
        t.state = .starting;
        queueCall(tw, t, .on, "", 0);
        tw.changed();
        return;
    }
    const file = t.fileOf();
    const code = tw.readFile(file.mod, file.path) orelse {
        log.warn("Tweak {s}: couldn't read {s}", .{ t.name, file.path });
        return fail(tw, t, "Couldn't read its file");
    };
    defer tw.allocator.free(code);
    var arena: std.heap.ArenaAllocator = .init(tw.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const shared: []const format.Value = if (file.is_group) fittedValues(tw, a, file) catch return fail(tw, t, "Out of memory") else &.{};
    var chain: [64]*Tweak = undefined;
    var n: usize = 0;
    var at = t.group;
    while (at) |g| : (at = g.group) {
        if (n == chain.len) return fail(tw, t, "It's in too many groups");
        chain[n] = g;
        n += 1;
    }
    std.mem.reverse(*Tweak, chain[0..n]);
    for (chain[0..n]) |g| {
        if (g.state.started()) continue;
        clearProblem(tw, g);
        g.state = .starting;
        if (g.file != null) sendRun(tw, a, code, g, shared) catch return fail(tw, t, "Out of memory");
    }
    clearProblem(tw, t);
    t.state = .starting;
    sendRun(tw, a, code, t, shared) catch return fail(tw, t, "Out of memory");
    tw.changed();
}

fn sendRun(tw: *Tweaks, a: std.mem.Allocator, code: []const u8, t: *Tweak, shared: []const format.Value) !void {
    const file = t.fileOf();
    send(tw, protocol.topics.run, protocol.Run{
        .session = file.session,
        .name = file.name,
        .code = code,
        .language = @tagName(t.def.script),
        .tweak = true,
        .values = try fittedValues(tw, a, t),
        .part = t.part,
        .shared_values = shared,
    });
}

/// Its kept values, fitted like the UI shows them, in case the tweak's range or type changed since.
fn fittedValues(tw: *Tweaks, a: std.mem.Allocator, t: *const Tweak) ![]format.Value {
    var fitted: std.ArrayList(format.Value) = .empty;
    for (tw.kept.values.items) |v| if (std.mem.eql(u8, v.tweak, t.name)) {
        const d = t.def.field(v.field) orelse continue;
        try fitted.append(a, .{ .name = v.field, .value = values.fit(d.*, v.value) });
    };
    return fitted.items;
}

/// Under the lock. Its session or plugin says it's up. An action's done by then.
fn confirm(tw: *Tweaks, t: *Tweak) void {
    if (!t.is_group and t.def.mode == .action) {
        if (t.file != null) {
            t.stop_pending = true;
            t.state = .off;
            return settle(tw, t.fileOf());
        }
        // A plugin's has nothing left to stop
        if (t.plugin == null) stopSession(tw, t);
        t.state = .off;
        return;
    }
    if (t.state == .starting) t.state = .running;
}

/// Under the lock. It threw or refused while starting, so nothing of it is on. The box goes off,
/// the problem stays. A group's shared part failing takes everything that's on in it with it.
fn fail(tw: *Tweaks, t: *Tweak, problem: []const u8) void {
    if (t.is_group) {
        for (tw.list.items) |c| if (c.isUnder(t)) {
            if (c.is_group) {
                if (c.own) setProblem(tw, c, problem);
                c.own = false;
            } else if (c.state.wanted()) {
                clearLive(c);
                setProblem(tw, c, problem);
                c.state = .failed;
            }
        };
        t.own = false;
        setProblem(tw, t, problem);
        if (t.state.started()) stopGroup(tw, t) else t.state = .off;
        return settle(tw, t.fileOf());
    }
    if (t.file != null) {
        clearLive(t);
        if (t.state.started()) t.stop_pending = true;
        setProblem(tw, t, problem);
        t.state = .failed;
        return settle(tw, t.fileOf());
    }
    // A plugin that refused has nothing to stop
    if (t.plugin == null) stopSession(tw, t);
    setProblem(tw, t, problem);
    t.state = .failed;
}

/// Under the lock. The provider went, and its session's memory with it. What was on runs again
/// once the provider's back, but an action is just dropped. A group's file goes all at once.
fn lose(tw: *Tweaks, t: *Tweak) void {
    dropSession(tw, t);
    if (!t.is_group) {
        t.state = if (t.def.mode == .action) .off else .waiting;
        return;
    }
    for (tw.list.items) |c| if (c == t or c.file == t) {
        c.stop_pending = false;
        if (!c.state.started()) continue;
        c.state = if (c.is_group)
            (if (c.own) .waiting else .off)
        else if (c.def.mode == .action) .off else .waiting;
    };
}

/// Under the lock. For a lone tweak or a plugin's. Tells its session or plugin, if it has it.
/// Gets a fresh session, so its output can't land on the next run.
fn stopSession(tw: *Tweaks, t: *Tweak) void {
    if (!t.state.started()) return;
    if (t.plugin != null) return queueCall(tw, t, .off, "", 0);
    send(tw, protocol.topics.stop, protocol.Target{ .session = t.session });
    dropSession(tw, t);
}

/// Under the lock. Forgets its session without telling the provider. A group's file's takes
/// everything in it.
fn dropSession(tw: *Tweaks, t: *Tweak) void {
    t.session = newSession(tw);
    clearLive(t);
    if (t.is_group) for (tw.list.items) |c| if (c.file == t) clearLive(c);
}

/// Under the lock. Its data isn't in the game anymore.
fn clearLive(t: *Tweak) void {
    t.live = &.{};
    _ = t.live_arena.reset(.retain_capacity);
    Names.global.removeGroup(.tweak, t.name);
}

pub fn newSession(tw: *Tweaks) u32 {
    defer tw.next_session += 1;
    return tw.next_session;
}

pub fn clearProblem(tw: *Tweaks, t: *Tweak) void {
    if (t.problem) |p| tw.allocator.free(p);
    t.problem = null;
}

fn setProblem(tw: *Tweaks, t: *Tweak, problem: []const u8) void {
    clearProblem(tw, t);
    t.problem = tw.allocator.dupe(u8, problem) catch null;
}

/// Not under the lock. Starts what's waiting, plugins' right away and files' once their
/// language's provider is there.
pub fn tick(tw: *Tweaks) void {
    {
        tw.lock.lock();
        defer tw.lock.unlock();
        for (tw.list.items) |t| if (t.plugin != null and t.state == .waiting) start(tw, t);
    }
    runPluginCalls(tw);

    tw.lock.lock();
    defer tw.lock.unlock();
    var wanted: std.EnumSet(format.Script) = .empty;
    for (tw.list.items) |t| if (t.plugin == null and (t.state == .waiting or t.state.started())) wanted.insert(t.def.script);
    var ready: std.EnumSet(format.Script) = .empty;
    var it = wanted.iterator();
    while (it.next()) |language| if (tw.env.ready(tw.env.context, @tagName(language))) ready.insert(language);
    var lost = false;
    for (tw.list.items) |t| if (t.plugin == null and t.file == null and !ready.contains(t.def.script) and startedIn(tw, t)) {
        lose(tw, t);
        lost = true;
    };
    if (lost) tw.changed();
    // What's in groups brings them up, then groups that are on by themselves
    for (tw.list.items) |t| if (!t.is_group and t.state == .waiting and (t.plugin != null or ready.contains(t.def.script))) start(tw, t);
    for (tw.list.items) |t| if (t.is_group and t.state == .waiting and ready.contains(t.def.script)) start(tw, t);
}

/// Under the lock. It or anything in its file has its session.
fn startedIn(tw: *Tweaks, t: *const Tweak) bool {
    if (t.state.started()) return true;
    if (!t.is_group) return false;
    for (tw.list.items) |c| if (c.file == t and c.state.started()) return true;
    return false;
}

/// Stops them all, for shutting down.
pub fn stopAll(tw: *Tweaks) void {
    {
        tw.lock.lock();
        defer tw.lock.unlock();
        for (tw.list.items) |t| if (t.file == null) turnOff(tw, t);
    }
    runPluginCalls(tw);
}

fn send(tw: *Tweaks, topic: []const u8, value: anytype) void {
    const json = std.json.Stringify.valueAlloc(tw.allocator, value, .{}) catch return;
    defer tw.allocator.free(json);
    tw.env.publish(topic, json) catch |err| log.warn("Couldn't send to the script provider: {t}", .{err});
}

fn findSession(tw: *Tweaks, session: u32) ?*Tweak {
    for (tw.list.items) |t| if (t.file == null and t.session == session) return t;
    return null;
}

/// Render thread.
pub fn onMessage(tw: *Tweaks, message: *const api.Message) void {
    var arena: std.heap.ArenaAllocator = .init(tw.allocator);
    defer arena.deinit();
    const options: std.json.ParseOptions = .{ .ignore_unknown_fields = true };
    if (std.mem.eql(u8, message.topic, protocol.topics.tweak)) {
        const state = std.json.parseFromSliceLeaky(protocol.TweakState, arena.allocator(), message.payload, options) catch return;
        tw.lock.lock();
        defer tw.lock.unlock();
        const t = partOf(tw, state.session, state.part) orelse return;
        onStarted(tw, t, state.fields, state.names);
        return;
    }
    if (!std.mem.eql(u8, message.topic, protocol.topics.output)) return;
    const out = std.json.parseFromSliceLeaky(protocol.Output, arena.allocator(), message.payload, options) catch return;
    if (out.session < first_session) return;
    // What a tweak's script says goes in the log too, like CE's print
    if (out.kind == .info or out.kind == .warn) {
        tw.lock.lock();
        defer tw.lock.unlock();
        const t = partOf(tw, out.session, out.part) orelse return;
        if (out.kind == .warn) log.warn("Tweak {s}: {s}", .{ t.name, out.text }) else log.info("Tweak {s}: {s}", .{ t.name, out.text });
        return;
    }
    if (out.kind != .thrown and out.kind != .err) return;
    tw.lock.lock();
    defer tw.lock.unlock();
    const t = partOf(tw, out.session, out.part) orelse return;
    log.warn("Tweak {s}: {s}", .{ t.name, out.text });
    if (out.kind == .thrown) fail(tw, t, out.text) else setProblem(tw, t, out.text);
    tw.changed();
}

/// Under the lock. Who a session's message is about: what's at `part` in a group's file, else
/// the file's group or lone tweak. Null if it's not started, since it's late from a run that's gone.
fn partOf(tw: *Tweaks, session: u32, part: []const u8) ?*Tweak {
    const t = findSession(tw, session) orelse return null;
    const which = if (t.is_group and part.len > 0) definitions.findPart(tw, t, part) orelse return null else t;
    return if (which.state.started()) which else null;
}

/// Under the lock. Its data is at `fields`.
fn onStarted(tw: *Tweaks, t: *Tweak, fields: []const protocol.TweakState.Field, names: []const protocol.TweakState.Name) void {
    _ = t.live_arena.reset(.retain_capacity);
    const a = t.live_arena.allocator();
    const live = a.alloc(protocol.TweakState.Field, fields.len) catch return;
    for (live, fields) |*dst, src| dst.* = .{
        .name = a.dupe(u8, src.name) catch return,
        .address = src.address,
        .choices = if (src.choices) |c| definitions.copyChoices(a, c) catch return else null,
    };
    t.live = live;
    publishNames(t, names);
    confirm(tw, t);
    tw.changed();
}

/// As `<tweak>.<name>`, until its session goes. In a group's file it's the titles down to it,
/// like `<group>.<name>`, `<group>.<tweak>.<name>` or `<group>.<nested>.<tweak>.<name>`.
fn publishNames(t: *const Tweak, names: []const protocol.TweakState.Name) void {
    Names.global.removeGroup(.tweak, t.name);
    for (names) |n| {
        var buf: [256]u8 = undefined;
        const full = fullName(&buf, t, n.name) orelse continue;
        const size = if (std.meta.stringToEnum(format.Type, n.type)) |ty| ty.size() else 0;
        Names.global.put(.{ .source = .tweak, .group = t.name, .name = full, .where = .{ .at = @intCast(n.address) }, .type = n.type, .size = size }) catch |err| {
            log.warn("Couldn't name {s}: {t}", .{ full, err });
        };
    }
}

/// `name` with the titles of `t` and the groups it's in before it.
pub fn fullName(buf: []u8, t: *const Tweak, name: []const u8) ?[]const u8 {
    var w: std.Io.Writer = .fixed(buf);
    if (t.file == null and !t.is_group) {
        w.print("{s}.{s}", .{ t.name, name }) catch return null;
        return w.buffered();
    }
    var chain: [64]*const Tweak = undefined;
    var n: usize = 0;
    var at: ?*const Tweak = t;
    while (at) |p| : (at = p.group) {
        if (n == chain.len) return null;
        chain[n] = p;
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        w.print("{s}.", .{chain[n].title()}) catch return null;
    }
    w.writeAll(name) catch return null;
    return w.buffered();
}

/// Under the lock. What's in the game now, if its session put it there.
pub fn readLive(t: *const Tweak, d: format.Field) ?f64 {
    const l = t.liveField(d.name) orelse return null;
    return readValue(@intCast(l.address), d.type);
}

/// Under the lock. Into the game if it's live there, and to its plugin if it has it.
pub fn push(tw: *Tweaks, t: *Tweak, d: format.Field, value: f64) void {
    if (t.liveField(d.name)) |l| writeValue(@intCast(l.address), d.type, value);
    tellPlugin(tw, t, d.name, value);
}

fn readValue(address: usize, t: format.Type) ?f64 {
    switch (t) {
        inline else => |k| {
            const v = mem.Memory.local.load(values.TypeOf(k), address) catch return null;
            return if (comptime k.isFloat()) @floatCast(v) else @floatFromInt(v);
        },
    }
}

fn writeValue(address: usize, t: format.Type, value: f64) void {
    switch (t) {
        inline else => |k| {
            const T = values.TypeOf(k);
            const v: T = if (comptime k.isFloat()) @floatCast(value) else std.math.lossyCast(T, value);
            mem.Memory.local.store(T, address, v) catch |err| log.warn("Couldn't write a tweak's value at 0x{x}: {t}", .{ address, err });
        },
    }
}

/// For plugins, made outside the lock since they can add and remove from inside.
pub const PluginCall = struct {
    /// The tweak's, then the field's.
    names: []u8,
    name_len: usize,
    kind: api.TweakEventKind,
    value: f64 = 0,

    fn tweak(self: PluginCall) []const u8 {
        return self.names[0..self.name_len];
    }

    fn field(self: PluginCall) []const u8 {
        return self.names[self.name_len..];
    }
};

/// Under the lock. A field changed, which a plugin's started tweak hears about.
fn tellPlugin(tw: *Tweaks, t: *Tweak, field: []const u8, value: f64) void {
    if (t.plugin == null or !t.state.started()) return;
    // A drag changes it every frame, so only the newest waiting change is kept
    for (tw.calls.items) |*c| if (c.kind == .changed and std.mem.eql(u8, c.tweak(), t.name) and std.mem.eql(u8, c.field(), field)) {
        c.value = value;
        return;
    };
    queueCall(tw, t, .changed, field, value);
}

/// Under the lock.
fn queueCall(tw: *Tweaks, t: *Tweak, kind: api.TweakEventKind, field: []const u8, value: f64) void {
    const names = std.mem.concat(tw.allocator, u8, &.{ t.name, field }) catch return;
    tw.calls.append(tw.allocator, .{ .names = names, .name_len = t.name.len, .kind = kind, .value = value }) catch tw.allocator.free(names);
}

/// Not under the lock. A plugin can add and remove tweaks from inside its callback.
fn runPluginCalls(tw: *Tweaks) void {
    var calls = blk: {
        tw.lock.lock();
        defer tw.lock.unlock();
        const taken = tw.calls;
        tw.calls = .empty;
        break :blk taken;
    };
    defer {
        for (calls.items) |c| tw.allocator.free(c.names);
        calls.deinit(tw.allocator);
    }
    for (calls.items) |c| {
        var problem: api.TweakProblem = .{};
        const result = plugin_tweaks.call(c.tweak(), .{ .kind = c.kind, .field = c.field(), .value = c.value }, &problem);
        if (c.kind != .on or result == .gone) continue;
        tw.lock.lock();
        defer tw.lock.unlock();
        const t = definitions.find(tw, c.tweak()) orelse continue;
        if (result == .failed) {
            log.warn("Tweak {s}: {s}", .{ t.name, problem.message() });
            fail(tw, t, if (problem.len > 0) problem.message() else "It couldn't be turned on");
            tw.kept.persist_needed = true;
        } else confirm(tw, t);
        tw.changed();
    }
}

const tests = struct {
    const testing = std.testing;
    const support = @import("test_support.zig");

    fn stateOf(tweaks: *Tweaks, name: []const u8) Tweak.State {
        tweaks.lock.lock();
        defer tweaks.lock.unlock();
        return definitions.find(tweaks, name).?.state;
    }

    test "a tweak waits, starts, runs, fails and goes off, and an action goes off once done" {
        // Failing on purpose warns, which tests treat as noise
        const saved = core.log.mute(&.{.runtime});
        defer core.log.setFilter(saved);
        var s: support.Setup = try .init(&.{ .{ "tweaks/god.rwt", "@js\none" }, .{ "tweaks/heal.rwt", "@mode action\n@js\n" } });
        defer s.deinit();

        var fake: support.Fake = .{};
        const tweaks = try Tweaks.create(testing.allocator, s.project, null, .{}, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        tweaks.setOn("god", true);
        tweaks.tick();
        try testing.expectEqual(.waiting, stateOf(tweaks, "god"));
        fake.ready = true;
        tweaks.tick();
        try testing.expectEqual(.starting, stateOf(tweaks, "god"));
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = fake.last_session });
        try testing.expectEqual(.running, stateOf(tweaks, "god"));

        // Logged errors don't stop it, a throw does
        try support.hear(tweaks, protocol.topics.output, protocol.Output{ .session = fake.last_session, .kind = .err, .text = "meh" });
        try testing.expectEqual(.running, stateOf(tweaks, "god"));
        try support.hear(tweaks, protocol.topics.output, protocol.Output{ .session = fake.last_session, .kind = .thrown, .text = "nope" });
        try testing.expectEqual(.failed, stateOf(tweaks, "god"));
        try testing.expectEqual(1, fake.stops);
        var info = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expect(!info.on and !info.running);
        try testing.expectEqualStrings("nope", info.problem.?);

        // Already not wanted, so turning it off keeps the problem
        tweaks.setOn("god", false);
        try testing.expectEqual(.failed, stateOf(tweaks, "god"));
        tweaks.setOn("god", true);
        tweaks.tick();
        try testing.expectEqual(.starting, stateOf(tweaks, "god"));
        info = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expect(info.on and info.running and info.problem == null);
        tweaks.setOn("god", false);
        try testing.expectEqual(.off, stateOf(tweaks, "god"));
        try testing.expectEqual(2, fake.stops);

        tweaks.toggle("heal");
        try testing.expectEqual(.waiting, stateOf(tweaks, "heal"));
        tweaks.tick();
        try testing.expectEqual(.starting, stateOf(tweaks, "heal"));
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = fake.last_session });
        try testing.expectEqual(.off, stateOf(tweaks, "heal"));
        try testing.expectEqual(3, fake.stops);
    }

    test "a tweak goes to its language's provider" {
        var s: support.Setup = try .init(&.{ .{ "tweaks/fly.rwt", "@lua\nfunction tick() end" }, .{ "tweaks/walk.rwt", "@patch 0x10\n  nop" } });
        defer s.deinit();
        var fake: support.Fake = .{ .ready = true };
        const tweaks = try Tweaks.create(testing.allocator, s.project, null, .{}, fake.env());
        defer tweaks.destroy();
        tweaks.setOn("fly", true);
        tweaks.tick();
        try testing.expectEqualStrings("lua", fake.language());
        tweaks.setOn("walk", true);
        tweaks.tick();
        try testing.expectEqualStrings("js", fake.language());
    }

    const PluginSide = struct {
        ons: u32 = 0,
        offs: u32 = 0,
        changes: u32 = 0,
        last: f64 = 0,
        fail: bool = false,

        fn handle(self: *PluginSide, event: api.wraith.TweakEvent) error{ InvalidId, InvalidDefinition, NotFound, Failed }!void {
            switch (event.kind) {
                .on => self.ons += 1,
                .off => self.offs += 1,
                .changed => {
                    self.changes += 1;
                    self.last = event.value;
                },
                else => {},
            }
            if (self.fail and event.kind == .on) return api.salamander.host().explain(error.Failed, "too fast", .{});
        }

        fn handler(self: *PluginSide) api.wraith.TweakHandler {
            return .init(self, handle);
        }
    };

    test "plugins' tweaks call back, with no provider needed" {
        const saved = core.log.mute(&.{.runtime});
        defer core.log.setFilter(saved);
        const Loaded = @import("../PluginLoader.zig").Loaded;
        var s: support.Setup = try .init(&.{});
        defer s.deinit();
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");
        defer loaded.deinitForTest();
        const sdk = @import("wraith_sdk");
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();
        var side: PluginSide = .{};
        const list = sdk.wraith.root().?.tweaks();
        const def: api.wraith.TweakDefinition = .{ .id = "speed", .title = "Fast", .fields = &.{.{ .name = "speed", .type = .f32, .value = 2, .has_min = true, .min = 1, .has_max = true, .max = 10 }} };
        try list.add(def, side.handler());
        try testing.expectError(error.InvalidId, list.add(.{ .id = "a:b" }, side.handler()));
        try testing.expectError(error.InvalidDefinition, list.add(.{ .id = "a", .key = "Hyper+F8" }, side.handler()));

        var fake: support.Fake = .{};
        const tweaks = try Tweaks.create(testing.allocator, s.project, null, .{ .on = &.{"kai:speed"} }, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        // Its values come first
        tweaks.tick();
        try testing.expectEqual(1, side.ons);
        try testing.expectEqual(1, side.changes);
        try testing.expectEqual(2, side.last);
        try testing.expectEqual(0, fake.runs);
        const info = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expectEqualStrings("kai", info.plugin.?);
        try testing.expectEqualStrings("Fast", info.title);
        try testing.expect(info.on and info.running);
        try testing.expectEqual(.running, stateOf(tweaks, "kai:speed"));

        // A drag's changes pile into one, fitted
        tweaks.setValue("kai:speed", "speed", 5);
        tweaks.setValue("kai:speed", "speed", 50);
        tweaks.tick();
        try testing.expectEqual(2, side.changes);
        try testing.expectEqual(10, side.last);

        tweaks.setOn("kai:speed", false);
        tweaks.tick();
        try testing.expectEqual(1, side.offs);

        side.fail = true;
        tweaks.setOn("kai:speed", true);
        tweaks.tick();
        const failed = (try tweaks.snapshot(arena.allocator()))[0];
        try testing.expect(!failed.on and !failed.running);
        try testing.expectEqualStrings("too fast", failed.problem.?);
        try testing.expectEqual(.failed, stateOf(tweaks, "kai:speed"));
        try testing.expectEqual(1, side.offs);

        list.remove("speed");
        tweaks.tick();
        try testing.expectEqual(0, (try tweaks.snapshot(arena.allocator())).len);

        // Gone with the plugin
        try list.add(def, side.handler());
        tweaks.tick();
        try testing.expectEqual(1, (try tweaks.snapshot(arena.allocator())).len);
        loaded.deinitForTest();
        tweaks.tick();
        try testing.expectEqual(0, (try tweaks.snapshot(arena.allocator())).len);
    }

    test "a group's tweaks share its session, which comes and goes with them" {
        // Failing on purpose warns, which tests treat as noise
        const saved = core.log.mute(&.{.runtime});
        defer core.log.setFilter(saved);
        var s: support.Setup = try .init(&.{.{ "tweaks/combat.rwt", "@group Combat\n@data\n  u32 base = 1\n@js\n@tweak One\n@data\n  u32 x = 2\n@js\n@tweak Two\n@js\n" }});
        defer s.deinit();
        var fake: support.Fake = .{ .ready = true };
        const tweaks = try Tweaks.create(testing.allocator, s.project, null, .{}, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        const list = try tweaks.snapshot(arena.allocator());
        try testing.expectEqual(3, list.len);
        try testing.expect(list[0].is_group);
        try testing.expectEqualStrings("Combat", list[0].title);
        try testing.expectEqualStrings("base", list[0].fields[0].name);
        try testing.expectEqualStrings("combat/One", list[1].name);
        try testing.expectEqualStrings("combat", list[1].group.?);
        try testing.expectEqualStrings("One", list[1].title);

        // The first brings up the shared part, in the group's session
        tweaks.setOn("combat/One", true);
        tweaks.tick();
        try testing.expectEqualStrings("One", fake.part());
        const session = fake.last_session;
        var base: u32 = 0;
        var x: u32 = 0;
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = session, .names = &.{.{ .name = "base", .address = @intFromPtr(&base), .type = "u32" }} });
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = session, .part = "One", .names = &.{.{ .name = "x", .address = @intFromPtr(&x), .type = "u32" }} });
        try testing.expectEqual(.running, stateOf(tweaks, "combat/One"));
        try testing.expectEqual(@intFromPtr(&base), try Names.global.get("Combat.base"));
        try testing.expectEqual(@intFromPtr(&x), try Names.global.get("Combat.One.x"));

        tweaks.setOn("combat/Two", true);
        tweaks.tick();
        try testing.expectEqual(session, fake.last_session);
        try testing.expectEqualStrings("Two", fake.part());

        // One goes on its own, then the last takes the session
        tweaks.setOn("combat/One", false);
        try testing.expectEqual(1, fake.stops);
        try testing.expectEqualStrings("One", fake.stopPart());
        try testing.expectError(error.NotFound, Names.global.get("Combat.One.x"));
        try testing.expectEqual(@intFromPtr(&base), try Names.global.get("Combat.base"));
        tweaks.setOn("combat/Two", false);
        try testing.expectEqual(2, fake.stops);
        try testing.expectEqualStrings("", fake.stopPart());
        try testing.expectError(error.NotFound, Names.global.get("Combat.base"));
        try testing.expect(!(try tweaks.snapshot(arena.allocator()))[0].on);

        // The group's box does them all, in a new session
        tweaks.setOn("combat", true);
        tweaks.tick();
        try testing.expectEqual(4, fake.runs);
        const next = fake.last_session;
        try testing.expect(next != session);
        try testing.expect((try tweaks.snapshot(arena.allocator()))[0].on);

        // One of them failing is just that one
        try support.hear(tweaks, protocol.topics.output, protocol.Output{ .session = next, .part = "One", .kind = .thrown, .text = "nope" });
        try testing.expectEqual(.failed, stateOf(tweaks, "combat/One"));
        try testing.expectEqual(.starting, stateOf(tweaks, "combat/Two"));
        try testing.expectEqualStrings("One", fake.stopPart());
        // The shared part failing takes every one that's on
        try support.hear(tweaks, protocol.topics.output, protocol.Output{ .session = next, .kind = .thrown, .text = "shared nope" });
        try testing.expectEqual(.failed, stateOf(tweaks, "combat/Two"));
        const after = try tweaks.snapshot(arena.allocator());
        try testing.expectEqualStrings("shared nope", after[2].problem.?);
        try testing.expectEqualStrings("nope", after[1].problem.?);
        try testing.expect(!after[0].on and !after[0].running);
        try testing.expectEqualStrings("", fake.stopPart());

        // Kept on by its tweaks' names, never the group's
        tweaks.setOn("combat/Two", true);
        try testing.expectEqual(1, fake.saved_on);
    }

    const kai_source =
        \\@group "Kai"
        \\@data
        \\  u32 base = 1
        \\@js
        \\@group "Combat"
        \\@data
        \\  u32 hits = 2
        \\@js
        \\@tweak "Max bravery"
        \\@js
        \\@group "Party"
        \\@children none
        \\@tweak "Max HP"
        \\@data
        \\  u32 y = 4
        \\@js
        \\@end
        \\@end
        \\@group "Loot"
        \\@children on
        \\@tweak "More"
        \\@js
        \\@tweak "Rare"
        \\@js
        \\@end
        \\@group "Stats"
        \\@children off
        \\@tweak "Str"
        \\@js
        \\@end
        \\@tweak "Override item"
        \\@js
    ;

    fn expectHistory(fake: *support.Fake, want: []const u8) !void {
        defer fake.forget();
        if (std.mem.eql(u8, fake.history(), want)) return;
        std.debug.print("wanted: {s}\n   got: {s}\n", .{ want, fake.history() });
        return error.TestUnexpectedResult;
    }

    fn infoOf(list: []const Tweaks.Info, name: []const u8) Tweaks.Info {
        for (list) |t| if (std.mem.eql(u8, t.name, name)) return t;
        unreachable;
    }

    test "nested groups come up outside in, go down inside out and cascade as @children says" {
        var s: support.Setup = try .init(&.{.{ "tweaks/kai.rwt", kai_source }});
        defer s.deinit();
        var fake: support.Fake = .{ .ready = true };
        const tweaks = try Tweaks.create(testing.allocator, s.project, null, .{}, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        // A tree, in the file's order, named by path
        const list = try tweaks.snapshot(arena.allocator());
        const names = [_][]const u8{ "kai", "kai/Combat", "kai/Combat/Max bravery", "kai/Combat/Party", "kai/Combat/Party/Max HP", "kai/Loot", "kai/Loot/More", "kai/Loot/Rare", "kai/Stats", "kai/Stats/Str", "kai/Override item" };
        const depths = [_]u32{ 0, 1, 2, 2, 3, 1, 2, 2, 1, 2, 1 };
        try testing.expectEqual(names.len, list.len);
        for (names, depths, list) |n, d, t| {
            try testing.expectEqualStrings(n, t.name);
            try testing.expectEqual(d, t.depth);
        }
        try testing.expectEqualStrings("Party", list[3].title);
        try testing.expectEqualStrings("kai/Combat", list[3].group.?);
        try testing.expect(list[3].is_group and !list[4].is_group);
        try testing.expectEqualStrings("hits", list[1].fields[0].name);

        // A deep one brings up the groups it's in, outermost first, the file's with the first run
        tweaks.setOn("kai/Combat/Party/Max HP", true);
        tweaks.tick();
        try expectHistory(&fake, "run Combat;run Combat/Party;run Combat/Party/Max HP;");
        const session = fake.last_session;
        var base: u32 = 0;
        var hits: u32 = 0;
        var y: u32 = 0;
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = session, .names = &.{.{ .name = "base", .address = @intFromPtr(&base), .type = "u32" }} });
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = session, .part = "Combat", .names = &.{.{ .name = "hits", .address = @intFromPtr(&hits), .type = "u32" }} });
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = session, .part = "Combat/Party" });
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = session, .part = "Combat/Party/Max HP", .names = &.{.{ .name = "y", .address = @intFromPtr(&y), .type = "u32" }} });
        try testing.expectEqual(@intFromPtr(&base), try Names.global.get("Kai.base"));
        try testing.expectEqual(@intFromPtr(&hits), try Names.global.get("Kai.Combat.hits"));
        try testing.expectEqual(@intFromPtr(&y), try Names.global.get("Kai.Combat.Party.Max HP.y"));
        var now = try tweaks.snapshot(arena.allocator());
        for ([_][]const u8{ "kai", "kai/Combat", "kai/Combat/Party" }) |g| {
            const info = infoOf(now, g);
            try testing.expect(!info.on and info.partial and info.running);
        }
        try testing.expect(!infoOf(now, "kai/Loot").partial);

        // The last reason going takes them all, in one go from the outside
        tweaks.setOn("kai/Combat/Party/Max HP", false);
        try expectHistory(&fake, "stop ;");
        try testing.expectError(error.NotFound, Names.global.get("Kai.Combat.hits"));
        try testing.expectEqual(.off, stateOf(tweaks, "kai/Combat"));

        // The file's box with `on off` does its direct children, which do theirs as they say
        tweaks.setOn("kai", true);
        tweaks.tick();
        try expectHistory(&fake, "run Combat;run Combat/Max bravery;run Loot;run Loot/More;run Loot/Rare;run Override item;run Combat/Party;run Stats;");
        now = try tweaks.snapshot(arena.allocator());
        // none and off don't turn on what's in them
        try testing.expect(infoOf(now, "kai/Combat/Party").on and !infoOf(now, "kai/Combat/Party/Max HP").on);
        try testing.expect(infoOf(now, "kai/Stats").on and !infoOf(now, "kai/Stats/Str").on);
        try testing.expect(infoOf(now, "kai/Loot/Rare").on);

        // Up while it's on, with nothing in it on
        try testing.expectEqual(.starting, stateOf(tweaks, "kai/Stats"));
        // on only doesn't turn off what's in it
        tweaks.setOn("kai/Loot", false);
        try expectHistory(&fake, "");
        now = try tweaks.snapshot(arena.allocator());
        try testing.expect(!infoOf(now, "kai/Loot").on and infoOf(now, "kai/Loot").partial);
        // off turns off what's in it, which goes with its group
        tweaks.setOn("kai/Stats/Str", true);
        tweaks.tick();
        try expectHistory(&fake, "run Stats/Str;");
        tweaks.setOn("kai/Stats", false);
        try expectHistory(&fake, "stop Stats;");
        try testing.expect(!(try tweaks.snapshot(arena.allocator()))[9].on);

        // none leaves what's in it alone, so it keeps its groups up
        tweaks.setOn("kai/Combat/Party/Max HP", true);
        tweaks.tick();
        try expectHistory(&fake, "run Combat/Party/Max HP;");
        tweaks.setOn("kai/Combat", false);
        try expectHistory(&fake, "stop Combat/Max bravery;");
        now = try tweaks.snapshot(arena.allocator());
        try testing.expect(infoOf(now, "kai/Combat/Party/Max HP").on and infoOf(now, "kai/Combat").partial);
        tweaks.setOn("kai/Combat/Party/Max HP", false);
        try expectHistory(&fake, "stop Combat;");

        // Loot's on only, so More and Rare keep the file's group up past its own box
        tweaks.setOn("kai", false);
        try expectHistory(&fake, "stop Override item;");
        try testing.expect((try tweaks.snapshot(arena.allocator()))[0].partial);
        tweaks.setOn("kai/Loot/More", false);
        tweaks.setOn("kai/Loot/Rare", false);
        try expectHistory(&fake, "stop Loot/More;stop ;");
        try testing.expect(!(try tweaks.snapshot(arena.allocator()))[0].running);
    }

    test "a nested group failing takes what's on in it, and its file's group stays for the rest" {
        // Failing on purpose warns, which tests treat as noise
        const saved = core.log.mute(&.{.runtime});
        defer core.log.setFilter(saved);
        var s: support.Setup = try .init(&.{.{ "tweaks/kai.rwt", kai_source }});
        defer s.deinit();
        var fake: support.Fake = .{ .ready = true };
        const tweaks = try Tweaks.create(testing.allocator, s.project, null, .{}, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        tweaks.setOn("kai/Combat/Party", true);
        tweaks.setOn("kai/Combat/Party/Max HP", true);
        tweaks.setOn("kai/Combat/Max bravery", true);
        tweaks.setOn("kai/Override item", true);
        tweaks.tick();
        try expectHistory(&fake, "run Combat;run Combat/Max bravery;run Combat/Party;run Combat/Party/Max HP;run Override item;");
        try testing.expectEqual(.starting, stateOf(tweaks, "kai/Combat/Party"));

        try support.hear(tweaks, protocol.topics.output, protocol.Output{ .session = fake.last_session, .part = "Combat", .kind = .thrown, .text = "combat broke" });
        try expectHistory(&fake, "stop Combat;");
        const now = try tweaks.snapshot(arena.allocator());
        for ([_][]const u8{ "kai/Combat", "kai/Combat/Party", "kai/Combat/Max bravery", "kai/Combat/Party/Max HP" }) |n| {
            const info = infoOf(now, n);
            try testing.expect(!info.on and !info.running);
            try testing.expectEqualStrings("combat broke", info.problem.?);
        }
        try testing.expectEqual(.failed, stateOf(tweaks, "kai/Combat/Party/Max HP"));
        try testing.expect(infoOf(now, "kai/Override item").on and infoOf(now, "kai").running);
        try testing.expectEqual(null, infoOf(now, "kai").problem);

        // A late word from what's in it is dropped
        try support.hear(tweaks, protocol.topics.output, protocol.Output{ .session = fake.last_session, .part = "Combat/Party/Max HP", .kind = .thrown, .text = "its group isn't on" });
        try testing.expectEqualStrings("combat broke", infoOf(try tweaks.snapshot(arena.allocator()), "kai/Combat/Party/Max HP").problem.?);
    }

    test "groups' own boxes are kept by path, next to what files kept before" {
        var s: support.Setup = try .init(&.{ .{ "tweaks/kai.rwt", kai_source }, .{ "tweaks/combat.rwt", "@group Combat\n@js\n@tweak One\n@js\n@tweak Two\n@js\n" } });
        defer s.deinit();
        var fake: support.Fake = .{ .ready = true };
        const tweaks = try Tweaks.create(testing.allocator, s.project, null, .{ .on = &.{ "combat/One", "kai/Loot", "kai/Combat/Party/Max HP" } }, fake.env());
        defer tweaks.destroy();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();

        tweaks.tick();
        const now = try tweaks.snapshot(arena.allocator());
        // A flat group's tweak comes back on by itself, as it always has
        try testing.expect(infoOf(now, "combat/One").on and !infoOf(now, "combat/Two").on);
        try testing.expect(!infoOf(now, "combat").on and infoOf(now, "combat").partial);
        // A group's own box doesn't turn on what's in it when it comes back
        try testing.expect(infoOf(now, "kai/Loot").on and !infoOf(now, "kai/Loot/More").on);
        try testing.expect(infoOf(now, "kai/Combat/Party/Max HP").on);
        try testing.expectEqual(5, fake.runs);

        tweaks.setOn("combat/Two", true);
        try testing.expectEqual(4, fake.saved_on);
    }

    test "an action runs once and a bad file says why" {
        var s: support.Setup = try .init(&.{ .{ "tweaks/heal.rwt", "@mode action\n@js\n" }, .{ "tweaks/bad.rwt", "nope" } });
        defer s.deinit();

        var fake: support.Fake = .{ .ready = true };
        const tweaks = try Tweaks.create(testing.allocator, s.project, null, .{ .on = &.{"heal"} }, fake.env());
        defer tweaks.destroy();
        tweaks.tick();
        try testing.expectEqual(0, fake.runs);

        tweaks.toggle("heal");
        tweaks.tick();
        try testing.expectEqual(1, fake.runs);
        try testing.expectEqual(0, fake.saved_on);
        try support.hear(tweaks, protocol.topics.tweak, protocol.TweakState{ .session = fake.last_session });
        try testing.expectEqual(1, fake.stops);
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const list = try tweaks.snapshot(arena.allocator());
        try testing.expect(!list[1].on and !list[1].running and list[1].mode == .action);
        try testing.expectEqualStrings("line 1: put this under a section, like @js", list[0].problem.?);

        // The provider going mid-run doesn't leave it stuck on, so its key still works
        tweaks.toggle("heal");
        tweaks.tick();
        fake.ready = false;
        tweaks.tick();
        fake.ready = true;
        tweaks.tick();
        try testing.expect(!(try tweaks.snapshot(arena.allocator()))[1].on);
        const runs = fake.runs;
        tweaks.toggle("heal");
        tweaks.tick();
        try testing.expectEqual(runs + 1, fake.runs);
    }
};

test {
    _ = tests;
}
