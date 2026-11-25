//! Every named address in the game: the user's address list, what plugins add, tweaks' own names,
//! schema statics and signature scans. Any thread. As `symbols`, address fields take these names
//! and listings show them.

const Names = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const tuft_sys = @import("tuft_sys");
const memory = @import("tuft_mem");
const devtools = @import("tuft_devtools");
const Schema = @import("salamander_schema").Schema;
const Owner = @import("tuft_event").Owner;
const Managed = @import("Managed.zig");

const Text = @import("tuft_text").Text;
const Outcome = memory.scans.Outcome;
const Location = memory.Location;
const Symbols = memory.Symbols;

/// Owner of the user's scans. Never closed.
pub var manual: Owner = .init("manual");

pub var global: Names = .{};

/// `global.symbols()`, for field defaults.
pub const global_symbols: Symbols = .{ .context = &global, .vtable = &full_vtable };

/// Earlier ones win when names clash.
pub const Origin = enum {
    /// The open project's address list, as the Addresses panel has it.
    user,
    /// A tweak's `@data` and `@sym`, while it's on.
    tweak,
    /// What plugins and scripts add, and installed projects' address lists.
    plugin,
    /// Statics and functions in schemas, a project's or a plugin's.
    schema,
    /// Signature scans, named after their owner and what they're called.
    scan,
};

/// Which copies of the game's code sigs are found in when the plugin looking hasn't said, see
/// `setDefaultSources`. Wraith's setting.
var default_sources: Atomic(u8) = .init(@bitCast(memory.Sources.all));
/// What the plugin looking on this thread said, while it looks.
threadlocal var plugin_sources: ?memory.Sources = null;

pub fn setDefaultSources(sources: memory.Sources) void {
    default_sources.store(@bitCast(sources), .release);
}

pub fn defaultSources() memory.Sources {
    return @bitCast(default_sources.load(.acquire));
}

/// For lookups on this thread till it's called with null, a plugin's own say over the default.
pub fn usePluginSources(sources: ?memory.Sources) ?memory.Sources {
    const old = plugin_sources;
    plugin_sources = sources;
    return old;
}

/// What a lookup on this thread may use, unless the sig says itself.
pub fn sourcesNow() memory.Sources {
    return plugin_sources orelse defaultSources();
}

pub const Where = union(enum) {
    /// Stays put, like a tweak's data.
    at: usize,
    /// Location text then pointer offsets, looked up each time it's asked for.
    text: struct {
        text: []const u8,
        offsets: []const isize = &.{},
    },
    /// What a signature scan found.
    scan: Scan,
};

pub const Scan = struct {
    pattern: []const u8,
    start: usize,
    len: usize,
    /// Took the first match of several.
    first_match: bool = false,
    scanned: Result,
    rescanned: ?Result = null,
};

pub const Result = struct {
    outcome: Outcome = .not_found,
    address: usize = 0,
    /// Capped at `max_matches`. Only counted on rescans.
    matches: ?usize = null,
    ns: u64 = 0,
    /// Which copy of the code it was found in, or looked in last.
    source: memory.AddressSource = .live,
    err: ?anyerror = null,
};

pub const max_matches = 64;

/// What a name is of, for filtering.
pub const Kind = enum {
    /// Not known, like what most scans find.
    other,
    /// A value, like a static or an address list entry with a type.
    data,
    function,
};

pub const Entry = struct {
    origin: Origin,
    kind: Kind = .other,
    /// Gone with it. Null for the user's, the runtime's and tweaks'.
    owner: ?*const Owner = null,
    /// What it's shown under, like its plugin or tweak.
    group: []const u8 = "",
    /// What it's looked up by, like `kai.health`.
    name: []const u8,
    /// What people see, if not its name.
    label: []const u8 = "",
    where: Where,
    /// Like `u32` or a schema type's name.
    type: []const u8 = "",
    /// Bytes, so addresses inside it are named after it.
    size: usize = 0,
};

/// A scan, copied for views.
pub const ScanInfo = struct {
    id: u64 = 0,
    /// Null for the runtime. Compare it, don't follow it.
    owner: ?*const Owner = null,
    owner_name: Text(64) = .{},
    name: Text(512) = .{},
    pattern: Text(512) = .{},
    module: Text(64) = .{},
    section: Text(16) = .{},
    start: usize = 0,
    len: usize = 0,
    scanned: Result = .{},
    rescanned: ?Result = null,
};

/// Why a name wasn't found.
pub const Failure = struct {
    err: GetError,
    message: Location.Problem = .{},
};

/// A record, copied for views.
pub const Info = struct {
    id: u64 = 0,
    origin: Origin = .user,
    kind: Kind = .other,
    /// Compare it, don't follow it.
    owner: ?*const Owner = null,
    group: Text(64) = .{},
    name: Text(512) = .{},
    label: Text(64) = .{},
    /// Location text. Empty for scans and ones that stay put.
    text: Text(512) = .{},
    offsets: [devtools.AddressList.max_offsets]isize = undefined,
    offsets_len: u8 = 0,
    type: Text(96) = .{},
    size: usize = 0,
    /// Where it was last worked out to be.
    address: ?usize = null,
    /// Why it wasn't found, if it wasn't.
    failed: ?Failure = null,
    /// Just for scans.
    scan: ?ScanInfo = null,
};

const Record = struct {
    id: u64,
    entry: Entry,
    /// Where it last was, for naming addresses. Never found by scanning just for that.
    cached: ?usize = null,
    /// Why it wasn't found the last time it was looked for. Text ones only, scans keep their own.
    failed: ?Failure = null,
    /// When it was scanned, so one that failed isn't retried every time.
    when_ns: u64 = 0,
};

allocator: std.mem.Allocator = std.heap.page_allocator,
lock: tuft_sys.sync.RwLock = .{},
records: std.ArrayList(*Record) = .empty,
next_id: u64 = 1,
/// Bumped when anything but the user's changes, so views can catch up.
changes: Atomic(u32) = .init(1),

/// How long a failed scan isn't tried again for.
const retry_ns = 5 * std.time.ns_per_s;
/// Names in names in names, before giving up on a loop.
const max_depth = 8;
threadlocal var depth: u8 = 0;

pub fn init(allocator: std.mem.Allocator) Names {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *Names) void {
    for (self.records.items) |r| self.destroy(r);
    self.records.deinit(self.allocator);
    self.* = .{};
}

/// Instead of one from the same origin and owner with the same name.
pub fn put(self: *Names, entry: Entry) !void {
    const record = try self.copy(entry);
    errdefer self.destroy(record);
    self.lock.lock();
    defer self.lock.unlock();
    record.id = self.next_id;
    self.next_id += 1;
    if (entry.where == .scan) record.when_ns = core.timing.now();
    if (entry.origin != .user) _ = self.changes.fetchAdd(1, .release);
    for (self.records.items) |*slot| {
        const r = slot.*;
        if (r.entry.origin == entry.origin and r.entry.owner == entry.owner and std.mem.eql(u8, r.entry.name, entry.name)) {
            self.destroy(r);
            slot.* = record;
            return;
        }
    }
    try self.records.append(self.allocator, record);
}

pub fn has(self: *Names, origin: Origin, name: []const u8) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    for (self.records.items) |r| {
        if (r.entry.origin == origin and std.mem.eql(u8, r.entry.name, name)) return true;
    }
    return false;
}

pub fn remove(self: *Names, origin: Origin, owner: ?*const Owner, name: []const u8) void {
    self.removeIf(struct {
        origin: Origin,
        owner: ?*const Owner,
        name: []const u8,
        fn match(m: @This(), e: *const Entry) bool {
            return e.origin == m.origin and e.owner == m.owner and std.mem.eql(u8, e.name, m.name);
        }
    }{ .origin = origin, .owner = owner, .name = name });
}

/// Everything it owns.
pub fn removeOwner(self: *Names, owner: *const Owner) void {
    self.removeIf(struct {
        owner: *const Owner,
        fn match(m: @This(), e: *const Entry) bool {
            return e.owner == m.owner;
        }
    }{ .owner = owner });
}

/// Everything `owner` has from `origin`.
pub fn removeFrom(self: *Names, origin: Origin, owner: ?*const Owner) void {
    self.removeIf(struct {
        origin: Origin,
        owner: ?*const Owner,
        fn match(m: @This(), e: *const Entry) bool {
            return e.origin == m.origin and e.owner == m.owner;
        }
    }{ .origin = origin, .owner = owner });
}

/// An address list as saved, like `addresses.rwa.zon`. In `arena`.
pub fn parseList(arena: std.mem.Allocator, text: []const u8) !devtools.AddressList.Saved {
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return .{};
    const source = try arena.dupeSentinel(u8, text, 0);
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(devtools.AddressList.Saved, .{ .gpa = arena, .arena = arena, .source = source, .diagnostics = &diagnostics, .ignore_unknown_fields = true });
}

/// Like a tweak's, when it stops.
pub fn removeGroup(self: *Names, origin: Origin, group: []const u8) void {
    self.removeIf(struct {
        origin: Origin,
        group: []const u8,
        fn match(m: @This(), e: *const Entry) bool {
            return e.origin == m.origin and std.mem.eql(u8, e.group, m.group);
        }
    }{ .origin = origin, .group = group });
}

fn removeIf(self: *Names, matcher: anytype) void {
    self.lock.lock();
    defer self.lock.unlock();
    var i: usize = 0;
    while (i < self.records.items.len) {
        const r = self.records.items[i];
        if (matcher.match(&r.entry)) {
            if (r.entry.origin != .user) _ = self.changes.fetchAdd(1, .release);
            self.destroy(r);
            _ = self.records.orderedRemove(i);
        } else i += 1;
    }
}

/// A project's address list, the open one's from the Addresses panel or an installed one's, in place
/// of what `owner` had from `origin`. Ones without an id aren't names, nor are groups without an
/// address. Each is published as location text with its groups and pointers folded in, so it's
/// found without the list. `schemas` give typed ones their size. Each is named with `prefix` and a
/// dot in front, if there's a prefix.
pub fn setList(self: *Names, origin: Origin, owner: ?*const Owner, group: []const u8, prefix: []const u8, items: []const devtools.AddressList.Item, schemas: []const *const Schema) void {
    self.removeFrom(origin, owner);
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    defer arena.deinit();
    for (items, 0..) |item, i| {
        if (item.id.len == 0) continue;
        if (item.group and std.mem.trim(u8, item.address, " \t").len == 0) continue;
        const text = devtools.AddressList.locationOf(items, i, arena.allocator()) catch continue;
        // Plans copy it out, so longer ones can't be found
        if (text.len > max_text) continue;
        var type_buf: [160]u8 = undefined;
        var name_buf: [192]u8 = undefined;
        self.put(.{
            .origin = origin,
            .owner = owner,
            .group = group,
            .name = if (prefix.len == 0) item.id else std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ prefix, item.id }) catch continue,
            .label = item.name,
            .where = .{ .text = .{ .text = text } },
            .type = devtools.AddressList.typeOfItem(item, &type_buf),
            .size = devtools.AddressList.sizeOfItem(item, schemas),
        }) catch {};
    }
}

/// Changes whenever anything but the user's entries do.
pub fn generation(self: *Names) u32 {
    return self.changes.load(.acquire);
}

pub const GetError = error{ NotFound, Unreadable, InvalidAddress };

/// Where the name is now.
pub fn get(self: *Names, name: []const u8) GetError!usize {
    return (try self.find(name, .full)) orelse error.NotFound;
}

/// Where the name is, if that's known without scanning.
pub fn peek(self: *Names, name: []const u8) ?usize {
    return self.find(name, .cheap) catch null;
}

/// Where location text is now, with `scope`'s names before ours.
pub fn eval(self: *Names, text: []const u8, scope: Symbols, problem: ?*Location.Problem) Location.Error!usize {
    return Location.eval(text, .{ .symbols = self.symbols(), .memory = .local, .scope = scope }, problem);
}

/// Like `eval`, with which copy of the code it was worked out from. Disk if any sig in it was
/// found on disk, else the snapshot if any was found there, else live.
pub fn evalFrom(self: *Names, text: []const u8, scope: Symbols, problem: ?*Location.Problem, source: *memory.AddressSource) Location.Error!usize {
    const outer = found_source;
    found_source = .live;
    defer {
        source.* = found_source;
        found_source = noteSource(outer, found_source);
    }
    return self.eval(text, scope, problem);
}

/// The furthest copy any sig was found in on this thread, for `evalFrom`.
threadlocal var found_source: memory.AddressSource = .live;

fn noteSource(a: memory.AddressSource, b: memory.AddressSource) memory.AddressSource {
    return if (@backingInt(b) > @backingInt(a)) b else a;
}

/// Names, then modules and their exports, for address fields and asm.
pub fn symbols(self: *Names) Symbols {
    return .{ .context = self, .vtable = &full_vtable };
}

const full_vtable: Symbols.VTable = .{ .resolve = resolveFull, .describe = describeThunk, .extent = extentThunk, .scan = scanFull, .why = whyThunk };
/// Doesn't scan, for keeping `cached` up to date.
const cheap_vtable: Symbols.VTable = .{ .resolve = resolveCheap, .describe = describeThunk, .extent = extentThunk, .scan = scanCheap, .why = whyThunk };

fn of(context: ?*anyopaque) *Names {
    return @ptrCast(@alignCast(context.?));
}

fn resolveFull(context: ?*anyopaque, name: []const u8) ?usize {
    return (of(context).find(name, .full) catch null) orelse Symbols.local.resolve(name) orelse Managed.global.methodAddress(name);
}

fn resolveCheap(context: ?*anyopaque, name: []const u8) ?usize {
    return (of(context).find(name, .cheap) catch null) orelse Symbols.local.resolve(name) orelse Managed.global.cachedMethodAddress(name);
}

fn describeThunk(context: ?*anyopaque, address: usize, buf: []u8) ?[]const u8 {
    return of(context).describe(address, buf);
}

fn whyThunk(context: ?*anyopaque, name: []const u8, buf: []u8) ?Symbols.Miss {
    if (of(context).why(name, buf)) |miss| return miss;
    const message = Managed.global.whyMissing(name) orelse return null;
    const n = @min(message.len, buf.len);
    @memcpy(buf[0..n], message[0..n]);
    return .{ .err = error.NotFound, .message = buf[0..n] };
}

fn extentThunk(_: ?*anyopaque, name: []const u8) ?Symbols.Extent {
    return Symbols.local.extent(name);
}

fn scanFull(context: ?*anyopaque, sig: memory.Sig, name: []const u8) memory.Address {
    return of(context).scanSig(sig, name, .full);
}

fn scanCheap(context: ?*anyopaque, sig: memory.Sig, name: []const u8) memory.Address {
    return of(context).scanSig(sig, name, .cheap);
}

const Cost = enum { full, cheap };

/// Longest location text a name can have.
pub const max_text = 2048;

/// What it takes to work out where a record is, copied out from under the lock.
const Plan = struct {
    at: union(enum) { at: usize, text: void, none: void } = .none,
    text: [max_text]u8 = undefined,
    text_len: usize = 0,
    offsets: [devtools.AddressList.max_offsets]isize = undefined,
    offsets_len: usize = 0,
    id: u64 = 0,
};

/// Null if there's no such name. Remembers why it failed for `why`.
fn find(self: *Names, name: []const u8, cost: Cost) GetError!?usize {
    if (depth == 0) too_deep = false;
    if (depth >= max_depth) {
        too_deep = true;
        self.failName(name, error.InvalidAddress, too_deep_message);
        return error.InvalidAddress;
    }
    var plan: Plan = .{};
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        const r = self.lookup(name) orelse return null;
        plan.id = r.id;
        switch (r.entry.where) {
            .at => |a| plan.at = .{ .at = a },
            .scan => |s| {
                const result = s.rescanned orelse s.scanned;
                if (result.err != null or result.outcome != .found) return error.NotFound;
                plan.at = .{ .at = result.address };
            },
            .text => |t| {
                if (t.text.len > plan.text.len or t.offsets.len > plan.offsets.len) return error.InvalidAddress;
                @memcpy(plan.text[0..t.text.len], t.text);
                plan.text_len = t.text.len;
                @memcpy(plan.offsets[0..t.offsets.len], t.offsets);
                plan.offsets_len = t.offsets.len;
                plan.at = .text;
            },
        }
    }
    const at = switch (plan.at) {
        .at => |a| return a,
        .none => unreachable,
        .text => blk: {
            depth += 1;
            defer depth -= 1;
            const vtable = if (cost == .full) &full_vtable else &cheap_vtable;
            var problem: Location.Problem = .{};
            const base = Location.eval(plan.text[0..plan.text_len], .{ .symbols = .{ .context = self, .vtable = vtable }, .memory = .local }, &problem) catch |err| {
                const e: GetError = switch (err) {
                    error.Unreadable => error.Unreadable,
                    error.NotFound => error.NotFound,
                    else => error.InvalidAddress,
                };
                // Names in names all the way down would only say so over and over
                if (too_deep) problem.set(too_deep_message);
                self.setFailed(plan.id, e, problem.message());
                return e;
            };
            var here = base;
            for (plan.offsets[0..plan.offsets_len]) |offset| {
                const pointer = memory.Memory.local.load(usize, here) catch {
                    problem.print("can't read [0x{x}]", .{here});
                    self.setFailed(plan.id, error.Unreadable, problem.message());
                    return error.Unreadable;
                };
                here = pointer +% @as(usize, @bitCast(offset));
            }
            break :blk here;
        },
    };
    self.setCached(plan.id, at);
    return at;
}

const too_deep_message = "it's names in names too deep, maybe a loop";
/// Hit `max_depth` somewhere under the name being found.
threadlocal var too_deep: bool = false;

/// Needs `lock`.
fn lookup(self: *Names, name: []const u8) ?*Record {
    var best: ?*Record = null;
    for (self.records.items) |r| {
        if (!std.mem.eql(u8, r.entry.name, name)) continue;
        if (r.entry.where == .scan and !isId(name)) continue;
        if (best == null or @backingInt(r.entry.origin) < @backingInt(best.?.entry.origin)) best = r;
    }
    return best;
}

fn setCached(self: *Names, id: u64, at: usize) void {
    self.lock.lock();
    defer self.lock.unlock();
    for (self.records.items) |r| if (r.id == id) {
        r.cached = at;
        r.failed = null;
        return;
    };
}

fn setFailed(self: *Names, id: u64, err: GetError, message: []const u8) void {
    self.lock.lock();
    defer self.lock.unlock();
    for (self.records.items) |r| if (r.id == id) {
        r.cached = null;
        r.failed = .{ .err = err };
        r.failed.?.message.set(message);
        return;
    };
}

fn failName(self: *Names, name: []const u8, err: GetError, message: []const u8) void {
    const id = blk: {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        break :blk (self.lookup(name) orelse return).id;
    };
    self.setFailed(id, err, message);
}

/// Why a name that's here wasn't found the last time it was looked for. Null if there's no such
/// name. `buf` holds the message.
pub fn why(self: *Names, name: []const u8, buf: []u8) ?Symbols.Miss {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const r = self.lookup(name) orelse return null;
    const f = failureOf(r) orelse return .{ .err = error.NotFound, .message = "it isn't anywhere right now" };
    const message = f.message.message();
    const n = @min(message.len, buf.len);
    @memcpy(buf[0..n], message[0..n]);
    return .{ .err = f.err, .message = buf[0..n] };
}

/// Needs `lock`.
/// Typed ones are data, unless they said.
fn kindOf(e: *const Entry) Kind {
    if (e.kind == .other and e.type.len > 0) return .data;
    return e.kind;
}

fn failureOf(r: *const Record) ?Failure {
    const s = switch (r.entry.where) {
        .at => return null,
        .text => return r.failed,
        .scan => |s| s,
    };
    const result = s.rescanned orelse s.scanned;
    var f: Failure = .{ .err = error.NotFound };
    if (result.err) |err| {
        f.message.print("sig(\"{s}\"): {t}", .{ s.pattern, err });
        return f;
    }
    switch (result.outcome) {
        .found => return null,
        .not_found => f.message.print("sig(\"{s}\") wasn't found", .{s.pattern}),
        .not_unique => f.message.print("sig(\"{s}\") matches more than once", .{s.pattern}),
    }
    return f;
}

/// Like `kai.health` or `kai.health+0x4`, else its module and offset.
pub fn describe(self: *Names, address: usize, buf: []u8) ?[]const u8 {
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        var best: ?*Record = null;
        var best_off: usize = 0;
        for (self.records.items) |r| {
            const start = placeOf(r) orelse continue;
            if (address < start) continue;
            const off = address - start;
            if (off >= @max(r.entry.size, 1)) continue;
            if (best == null or off < best_off or (off == best_off and @backingInt(r.entry.origin) < @backingInt(best.?.entry.origin))) {
                best = r;
                best_off = off;
            }
        }
        if (best) |r| {
            return if (best_off == 0)
                std.fmt.bufPrint(buf, "{s}", .{r.entry.name}) catch null
            else
                std.fmt.bufPrint(buf, "{s}+0x{x}", .{ r.entry.name, best_off }) catch null;
        }
    }
    return Symbols.local.describe(address, buf);
}

/// Where it is for naming addresses, if it's known without looking.
fn placeOf(r: *const Record) ?usize {
    return switch (r.entry.where) {
        .at => |a| a,
        .text => r.cached,
        .scan => |s| blk: {
            if (!isId(r.entry.name)) break :blk null;
            const result = s.rescanned orelse s.scanned;
            break :blk if (result.err == null and result.outcome == .found) result.address else null;
        },
    };
}

/// Works out where text entries are now without scanning, so `describe` keeps up. Every so often,
/// from the workbench.
pub fn refresh(self: *Names) void {
    var ids: [256]u64 = undefined;
    var names_buf: [256][96]u8 = undefined;
    var lens: [256]usize = undefined;
    var n: usize = 0;
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        for (self.records.items) |r| {
            if (r.entry.where != .text or n == ids.len or r.entry.name.len > names_buf[0].len) continue;
            ids[n] = r.id;
            @memcpy(names_buf[n][0..r.entry.name.len], r.entry.name);
            lens[n] = r.entry.name.len;
            n += 1;
        }
    }
    for (0..n) |i| _ = self.find(names_buf[i][0..lens[i]], .cheap) catch {};
}

/// Every name, copied into `out` for views. Returns how many fit.
pub fn list(self: *Names, out: []Info) usize {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    const n = @min(self.records.items.len, out.len);
    for (self.records.items[0..n], out[0..n]) |r, *info| {
        const e = &r.entry;
        info.* = .{ .id = r.id, .origin = e.origin, .kind = kindOf(e), .owner = e.owner, .size = e.size, .failed = failureOf(r) };
        info.group.set(e.group);
        info.name.set(e.name);
        info.label.set(e.label);
        info.type.set(e.type);
        switch (e.where) {
            .at => |a| info.address = a,
            .text => |t| {
                info.text.set(t.text);
                const k = @min(t.offsets.len, info.offsets.len);
                @memcpy(info.offsets[0..k], t.offsets[0..k]);
                info.offsets_len = @intCast(k);
                info.address = r.cached;
            },
            .scan => |s| {
                info.scan = scanInfoOf(r, s);
                const result = s.rescanned orelse s.scanned;
                if (result.err == null and result.outcome != .not_found) info.address = result.address;
            },
        }
    }
    return n;
}

pub fn count(self: *Names) usize {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return self.records.items.len;
}

/// Ids are names without spaces or brackets. Scans called other things, like their own text, are
/// only listed.
fn isId(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.' and ch != '-') return false;
    return true;
}

// Scans

/// The runtime's own scans.
pub fn recordOwn(record_: *const memory.scans.Record) void {
    global.recordScan(null, record_) catch {};
}

/// Null owner means the runtime. Call `removeOwner` before the owner is gone.
pub fn recordScan(self: *Names, owner: ?*const Owner, r: *const memory.scans.Record) !void {
    const group = if (owner) |o| o.name else "wraith";
    var buf: [192]u8 = undefined;
    // Named after their owner, like plugins' addresses, except the runtime's and the user's
    const name = if (owner == null or owner == &manual) r.name else std.fmt.bufPrint(&buf, "{s}.{s}", .{ group, r.name }) catch r.name;
    try self.put(.{
        .origin = .scan,
        .owner = owner,
        .group = group,
        .name = name,
        .label = r.name,
        .where = .{ .scan = .{
            .pattern = r.pattern,
            .start = r.start,
            .len = r.len,
            .first_match = r.first_match,
            .scanned = .{ .outcome = r.outcome, .address = r.address, .ns = r.ns, .source = r.source },
        } },
        .size = (r.pattern.len + 1) / 3,
    });
}

/// The last copy a lookup allowed `allowed` would get to in `range`, of the ones there are.
fn furthest(allowed: memory.Sources, range: memory.Range) memory.AddressSource {
    var i = memory.AddressSource.order.len;
    while (i > 1) {
        i -= 1;
        const s = memory.AddressSource.order[i];
        if (allowed.has(s) and memory.originals.find(s, range.start, 1) != null) return s;
    }
    return .live;
}

/// From an earlier scan of the same pattern in the same place if there was one, else scanned now.
/// Found in the copies `sourcesNow` allows, unless the sig says which.
fn scanSig(self: *Names, sig: memory.Sig, name: []const u8, cost: Cost) memory.Address {
    const range = sig.range() catch |err| return .fail(err);
    var buf: [memory.Sig.max_len]?u8 = undefined;
    const p = memory.pattern.parseInto(sig.pattern, &buf) catch |err| return .fail(err);
    var text: [memory.Sig.max_len * 3]u8 = undefined;
    const pattern = memory.scans.format(p, &text);
    const allowed = sig.sources orelse sourcesNow();
    // Before the lock, since the disk copy can still be on its way
    const far = if (cost == .cheap) .live else furthest(allowed, range);
    const now = core.timing.now();
    const Match = struct { at: usize, source: memory.AddressSource };
    const match: ?Match = blk: {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        for (self.records.items) |r| {
            const s = switch (r.entry.where) {
                .scan => |s| s,
                else => continue,
            };
            if (s.start != range.start or s.len != range.len or s.first_match != sig.first_match or !std.mem.eql(u8, s.pattern, pattern)) continue;
            const result = s.rescanned orelse s.scanned;
            if (result.err == null and result.outcome == .found) {
                // Found somewhere this lookup can't use, so it looks again itself
                if (!allowed.has(result.source)) continue;
                break :blk .{ .at = result.address, .source = result.source };
            }
            // Without scanning, one that failed stays failed, if it looked as far as this one would
            if (cost == .cheap or (now -| r.when_ns < retry_ns and @backingInt(result.source) >= @backingInt(far))) return .fail(if (result.err == null and result.outcome == .not_unique) error.PatternNotUnique else error.SignatureNotFound);
        }
        break :blk null;
    };
    const found = if (match) |m| sig.fromIn(name, m.at, m.source) else if (cost == .cheap) return .fail(error.NotScanned) else sig.locateWith(name, allowed);
    if (found.orNull() != null) found_source = noteSource(found_source, found.source);
    return found;
}

pub fn scanList(self: *Names, out: []ScanInfo) usize {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    var n: usize = 0;
    for (self.records.items) |r| {
        const s = switch (r.entry.where) {
            .scan => |s| s,
            else => continue,
        };
        if (n == out.len) break;
        out[n] = scanInfoOf(r, s);
        n += 1;
    }
    return n;
}

/// Needs `lock`.
fn scanInfoOf(r: *const Record, s: Scan) ScanInfo {
    var info: ScanInfo = .{ .id = r.id, .owner = r.entry.owner, .start = s.start, .len = s.len, .scanned = s.scanned, .rescanned = s.rescanned };
    if (r.entry.owner) |o| info.owner_name.set(o.name);
    info.name.set(r.entry.label);
    info.pattern.set(s.pattern);
    describeRange(s.start, s.len, &info);
    return info;
}

pub fn scanCount(self: *Names) usize {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    var n: usize = 0;
    for (self.records.items) |r| n += @intFromBool(r.entry.where == .scan);
    return n;
}

pub fn rescan(self: *Names, id: u64, sources: memory.Sources) bool {
    var pattern_buf: [256 * 3]u8 = undefined;
    var start: usize = 0;
    var len: usize = 0;
    var pattern_len: usize = 0;
    var first_match = false;
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        const s = self.scanOf(id) orelse return false;
        pattern_len = @min(s.pattern.len, pattern_buf.len);
        @memcpy(pattern_buf[0..pattern_len], s.pattern[0..pattern_len]);
        start = s.start;
        len = s.len;
        first_match = s.first_match;
    }
    // Scan outside the lock since a big range takes a while
    const result = scanRange(pattern_buf[0..pattern_len], start, len, sources, first_match) catch |err| Result{ .err = err };

    self.lock.lock();
    defer self.lock.unlock();
    const s = self.scanOf(id) orelse return false;
    s.rescanned = result;
    _ = self.changes.fetchAdd(1, .release);
    return true;
}

pub fn rescanAll(self: *Names, sources: memory.Sources) void {
    const ids = self.scanIds(self.allocator) catch return;
    defer self.allocator.free(ids);
    for (ids) |id| _ = self.rescan(id, sources);
}

/// How `scanEverything` is going, for showing while it runs on another thread.
pub const Progress = struct {
    done: Atomic(u32) = .init(0),
    total: Atomic(u32) = .init(0),
    cancel: Atomic(bool) = .init(false),
};

/// Scans every signature that was scanned before again, then looks up every name that isn't
/// anywhere yet, which scans signatures nothing's used so far. Those look where their sigs and the
/// default say, not in `sources`. Takes a while with a lot of them, so it's for a thread of its own.
pub fn scanEverything(self: *Names, sources: memory.Sources, progress: *Progress) void {
    const gpa = self.allocator;
    const before = self.scanIds(gpa) catch return;
    defer gpa.free(before);
    var unfound: std.ArrayList([]u8) = .empty;
    defer {
        for (unfound.items) |n| gpa.free(n);
        unfound.deinit(gpa);
    }
    {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        for (self.records.items) |r| {
            if (r.entry.where != .text or r.cached != null) continue;
            const name = gpa.dupe(u8, r.entry.name) catch break;
            unfound.append(gpa, name) catch {
                gpa.free(name);
                break;
            };
        }
    }
    progress.total.store(@intCast(unfound.items.len + before.len), .release);
    for (before) |id| {
        if (progress.cancel.load(.acquire)) return;
        _ = self.rescan(id, sources);
        _ = progress.done.fetchAdd(1, .acq_rel);
    }
    for (unfound.items) |name| {
        if (progress.cancel.load(.acquire)) return;
        _ = self.find(name, .full) catch {};
        _ = progress.done.fetchAdd(1, .acq_rel);
    }
    _ = self.changes.fetchAdd(1, .release);
}

/// Every scan's id, in `gpa`.
fn scanIds(self: *Names, gpa: std.mem.Allocator) ![]u64 {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    var ids: std.ArrayList(u64) = .empty;
    errdefer ids.deinit(gpa);
    for (self.records.items) |r| if (r.entry.where == .scan) try ids.append(gpa, r.id);
    return ids.toOwnedSlice(gpa);
}

/// Live memory first, then each copy `sources` has, till one has a match. Counts the matches there.
pub fn scanRange(pattern: []const u8, start: usize, len: usize, sources: memory.Sources, first_match: bool) !Result {
    var buf: [256]?u8 = undefined;
    const p = try memory.pattern.parseInto(pattern, &buf);
    const started = core.timing.now();
    var last: anyerror!Result = error.NoSources;
    for (memory.AddressSource.order) |source| {
        if (!sources.has(source)) continue;
        const range = (memory.Range{ .start = start, .len = len }).from(source);
        if (source == .live and !memory.isReadable(start, len)) {
            last = error.RangeUnreadable;
            continue;
        }
        var matches: [max_matches]usize = undefined;
        const n = range.findAll(p, &matches) catch |err| {
            // A copy that isn't there says less than a miss somewhere else
            if (last) |_| {} else |_| last = err;
            continue;
        };
        const result: Result = .{
            .outcome = switch (n) {
                0 => .not_found,
                1 => .found,
                else => if (first_match) .found else .not_unique,
            },
            .address = if (n == 0) 0 else matches[0],
            .matches = n,
            .ns = core.timing.now() -| started,
            .source = source,
        };
        if (n > 0) return result;
        last = result;
    }
    return last;
}

/// Empty `module` means the game's exe, empty `section` the whole image.
pub fn scanManual(self: *Names, name: []const u8, module: []const u8, section: []const u8, pattern: []const u8, sources: memory.Sources) !Result {
    const m = if (module.len == 0) memory.Module.main() else try memory.Module.find(module);
    const range = if (section.len == 0) try m.range() else try m.section(section);
    const result = try scanRange(pattern, range.start, range.len, sources, false);
    // Store the pattern the way scans format it
    var buf: [256]?u8 = undefined;
    var text: [768]u8 = undefined;
    const p = try memory.pattern.parseInto(pattern, &buf);
    try self.recordScan(&manual, &.{
        .name = name,
        .pattern = memory.scans.format(p, &text),
        .start = range.start,
        .len = range.len,
        .source = result.source,
        .outcome = result.outcome,
        .address = result.address,
        .ns = result.ns,
    });
    return result;
}

/// Needs `lock`.
fn scanOf(self: *Names, id: u64) ?*Scan {
    for (self.records.items) |r| {
        if (r.id != id) continue;
        return switch (r.entry.where) {
            .scan => |*s| s,
            else => null,
        };
    }
    return null;
}

fn describeRange(start: usize, len: usize, info: *ScanInfo) void {
    const module = memory.Module.containing(start) catch return;
    var name_buf: [260]u8 = undefined;
    if (module.name(&name_buf)) |name| info.module.set(name);
    var sections = module.sections() catch return;
    while (sections.next()) |s| {
        if (s.start == start and s.len == len) {
            info.section.set(s.name());
            return;
        }
    }
}

// Memory

fn copy(self: *Names, entry: Entry) !*Record {
    var arena: std.heap.ArenaAllocator = .init(self.allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var e = entry;
    e.group = try a.dupe(u8, entry.group);
    e.name = try a.dupe(u8, entry.name);
    e.label = try a.dupe(u8, entry.label);
    e.type = try a.dupe(u8, entry.type);
    e.where = switch (entry.where) {
        .at => entry.where,
        .text => |t| .{ .text = .{ .text = try a.dupe(u8, t.text), .offsets = try a.dupe(isize, t.offsets) } },
        .scan => |s| blk: {
            var c = s;
            c.pattern = try a.dupe(u8, s.pattern);
            break :blk .{ .scan = c };
        },
    };
    const holder = try a.create(Held);
    holder.* = .{ .arena = arena, .record = .{ .id = 0, .entry = e } };
    return &holder.record;
}

/// A record and the arena its copies are in.
const Held = struct {
    arena: std.heap.ArenaAllocator,
    record: Record,
};

fn destroy(_: *Names, r: *Record) void {
    const held: *Held = @fieldParentPtr("record", r);
    var arena = held.arena;
    arena.deinit();
}

const tests = struct {
    const testing = std.testing;

    fn code() callconv(.naked) void {
        asm volatile (
            \\.intel_syntax noprefix
            \\mov eax, 0x5EEDF00D
            \\mov ecx, 0x5EEDF00D
            \\ret
            \\.att_syntax prefix
        );
    }

    test "names, priority and descriptions" {
        var names: Names = .init(testing.allocator);
        defer names.deinit();
        var value: [4]u32 = .{ 1, 2, 3, 4 };
        var pointer: *[4]u32 = &value;
        var kai: Owner = .init("kai");
        try names.put(.{ .origin = .plugin, .owner = &kai, .group = "kai", .name = "kai.hp", .where = .{ .at = @intFromPtr(&value) }, .size = 16 });
        var buf: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(&pointer)});
        try names.put(.{ .origin = .tweak, .group = "xp", .name = "xp.ptr", .where = .{ .text = .{ .text = text, .offsets = &.{4} } } });

        try testing.expectEqual(@intFromPtr(&value), try names.get("kai.hp"));
        try testing.expectEqual(@intFromPtr(&value) + 4, try names.get("xp.ptr"));
        try testing.expectError(error.NotFound, names.get("nobody"));
        // A tweak's comes before a plugin's of the same name
        try names.put(.{ .origin = .tweak, .group = "kai", .name = "kai.hp", .where = .{ .at = 0x10 } });
        try testing.expectEqual(0x10, try names.get("kai.hp"));
        names.removeGroup(.tweak, "kai");
        try testing.expectEqual(@intFromPtr(&value), try names.get("kai.hp"));

        var out: [64]u8 = undefined;
        try testing.expectEqualStrings("kai.hp+0x8", names.describe(@intFromPtr(&value) + 8, &out).?);
        try testing.expectEqualStrings("kai.hp", names.describe(@intFromPtr(&value), &out).?);

        var problem: Location.Problem = .{};
        try testing.expectEqual(@intFromPtr(&value) + 12, try names.eval("(kai.hp) + 0xC", .none, &problem));
        try testing.expectEqual(@intFromPtr(&value) + 12, try names.eval("xp.ptr + 8", .none, &problem));

        names.removeOwner(&kai);
        try testing.expectError(error.NotFound, names.get("kai.hp"));
    }

    test "loops give up" {
        var names: Names = .init(testing.allocator);
        defer names.deinit();
        try names.put(.{ .origin = .plugin, .name = "a", .where = .{ .text = .{ .text = "b" } } });
        try names.put(.{ .origin = .plugin, .name = "b", .where = .{ .text = .{ .text = "a+1" } } });
        try testing.expectError(error.InvalidAddress, names.get("a"));
        var buf: [256]u8 = undefined;
        try testing.expectEqualStrings(too_deep_message, names.why("a", &buf).?.message);
    }

    test "known names say why they weren't found" {
        var names: Names = .init(testing.allocator);
        defer names.deinit();
        var kai: Owner = .init("kai");
        try names.recordScan(&kai, &.{ .name = "seed", .pattern = "48 8B 0D", .start = 0, .len = 0, .outcome = .not_found, .ns = 0 });
        try names.put(.{ .origin = .schema, .name = "Game.instance", .where = .{ .text = .{ .text = "[kai.seed]" } } });
        try names.put(.{ .origin = .plugin, .name = "kai.hp", .where = .{ .text = .{ .text = "[0x10]" } } });
        try names.put(.{ .origin = .plugin, .name = "kai.mp", .where = .{ .text = .{ .text = "kai.hp + 4" } } });

        var problem: Location.Problem = .{};
        try testing.expectError(error.NotFound, names.eval("[Game.instance]", .none, &problem));
        try testing.expectEqualStrings("Game.instance: kai.seed: sig(\"48 8B 0D\") wasn't found", problem.message());
        try testing.expectError(error.Unreadable, names.eval("kai.mp", .none, &problem));
        try testing.expectEqualStrings("kai.mp: kai.hp: can't read [0x10]", problem.message());
        try testing.expectError(error.UnknownName, names.eval("nobody", .none, &problem));
        try testing.expectEqualStrings("there's no nobody", problem.message());

        // Remembered without looking again, and listed
        var buf: [256]u8 = undefined;
        const miss = names.why("kai.hp", &buf).?;
        try testing.expectEqual(error.Unreadable, miss.err);
        try testing.expectEqualStrings("can't read [0x10]", miss.message);
        try testing.expectEqual(null, names.why("nobody", &buf));
        var out: [4]Info = undefined;
        try testing.expectEqual(4, names.list(&out));
        try testing.expectEqualStrings("kai.hp", out[2].name.get());
        try testing.expectEqualStrings("can't read [0x10]", out[2].failed.?.message.message());

        // Gone once it's found
        var value: usize = 0;
        var text: [32]u8 = undefined;
        try names.put(.{ .origin = .plugin, .name = "kai.hp", .where = .{ .text = .{ .text = try std.fmt.bufPrint(&text, "0x{x}", .{@intFromPtr(&value)}) } } });
        try testing.expectEqual(@intFromPtr(&value) + 4, try names.get("kai.mp"));
        _ = names.list(&out);
        try testing.expectEqual(null, out[3].failed);
        try testing.expectEqual(@intFromPtr(&value) + 4, out[3].address.?);
    }

    test "user entries" {
        var names: Names = .init(testing.allocator);
        defer names.deinit();
        var value: u32 = 5;
        var buf: [32]u8 = undefined;
        names.setList(.user, null, "", "", &.{
            .{ .id = "player.health", .address = try std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(&value)}) },
            .{ .name = "no id", .address = "0x1" },
        }, &.{});
        try testing.expectEqual(@intFromPtr(&value), try names.get("player.health"));
        const before = names.generation();
        names.setList(.user, null, "", "", &.{}, &.{});
        try testing.expectError(error.NotFound, names.get("player.health"));
        try testing.expectEqual(before, names.generation());
    }

    test "user entries in groups" {
        var names: Names = .init(testing.allocator);
        defer names.deinit();
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var data: [0x40]u8 align(8) = @splat(0);
        var other: [0x10]u8 align(8) = @splat(0);
        var pointer: usize = @intFromPtr(&data) - 8;
        std.mem.writeInt(usize, data[0x20..][0..@sizeOf(usize)], @intFromPtr(&other), .little);
        const items: []const devtools.AddressList.Item = &.{
            .{ .name = "Player", .id = "player", .group = true, .address = try std.fmt.allocPrint(a, "0x{x}", .{@intFromPtr(&pointer)}), .offsets = &.{"8"} },
            .{ .name = "Health", .id = "player.hp", .depth = 1, .address = "+0x10", .kind = .float },
            .{ .name = "Folder", .id = "folder", .depth = 1, .group = true },
            .{ .name = "Bag", .id = "player.bag", .depth = 2, .group = true, .address = "+0x20", .offsets = &.{"0"} },
            .{ .name = "Gold", .id = "player.gold", .depth = 3, .address = "+4" },
            .{ .name = "Ids", .id = "player.ids", .depth = 1, .address = "+0x18", .kind = .two_bytes, .count = "4" },
            .{ .name = "Lost", .id = "lost", .address = "+4" },
        };
        names.setList(.user, null, "", "", items, &.{});

        var addresses: devtools.AddressList = .{ .allocator = testing.allocator, .memory = .local, .symbols = .local };
        defer addresses.deinit();
        try addresses.load(items);
        for ([_][]const u8{ "player", "player.hp", "player.bag", "player.gold", "player.ids" }, [_]usize{ 0, 1, 3, 4, 5 }) |name, i| {
            try testing.expectEqual(addresses.targetOf(i).?.address, try names.get(name));
        }
        try testing.expectEqual(@intFromPtr(&other) + 4, try names.get("player.gold"));
        try testing.expectError(error.NotFound, names.get("folder"));
        try testing.expectError(error.NotFound, names.get("lost"));

        names.refresh();
        var out: [64]u8 = undefined;
        try testing.expectEqualStrings("player.ids+0x6", names.describe(@intFromPtr(&data) + 0x18 + 6, &out).?);
    }

    test "scans record, rescan and are reused" {
        const saved = core.log.mute(&.{.memory});
        defer core.log.setFilter(saved);
        var names: Names = .init(testing.allocator);
        defer names.deinit();

        const text = try memory.Module.main().text();
        const r: memory.scans.Record = .{ .name = "seed", .pattern = "B8 0D F0 ED 5E B9 0D F0 ED 5E", .start = text.start, .len = text.len, .outcome = .found, .address = @intFromPtr(&code), .ns = 1 };
        var kai: Owner = .init("kai");
        var other: Owner = .init("other");
        try names.recordScan(&kai, &r);
        try names.recordScan(&kai, &r); // same again, replaced not added
        try names.recordScan(&other, &r);
        try testing.expectEqual(2, names.scanCount());
        try testing.expectEqual(@intFromPtr(&code), try names.get("kai.seed"));

        var out: [4]ScanInfo = undefined;
        try testing.expectEqual(2, names.scanList(&out));
        const first = out[0];
        try testing.expectEqual(&kai, first.owner.?);
        try testing.expectEqualStrings("kai", first.owner_name.get());
        try testing.expectEqualStrings("seed", first.name.get());
        try testing.expectEqualStrings(".text", first.section.get());

        try testing.expect(names.rescan(first.id, .live_only));
        _ = names.scanList(&out);
        try testing.expectEqual(1, out[0].rescanned.?.matches.?);

        // Location text finds it from the scan already made, then runs the steps
        var problem: Location.Problem = .{};
        try testing.expectEqual(@intFromPtr(&code) + 5, try names.eval("sig(\"B8 0D F0 ED 5E B9 0D F0 ED 5E\", Offset(5), Section(\".text\"))", .none, &problem));

        names.removeOwner(&kai);
        try testing.expectEqual(1, names.scanCount());
        try testing.expect(!names.rescan(first.id, .live_only));
    }

    test "scanning everything finds signatures nothing used yet" {
        // Scans are recorded in global, and looking again finds them there
        global = .init(testing.allocator);
        defer global.deinit();
        const previous = memory.scans.setRecorder(recordOwn);
        defer _ = memory.scans.setRecorder(previous);
        const names = &global;
        try names.put(.{ .origin = .schema, .name = "Game.seed", .where = .{ .text = .{ .text = "sig(\"B8 0D F0 ED 5E B9 0D F0 ED 5E\", Section(\".text\"))" } } });
        try testing.expectEqual(null, names.find("Game.seed", .cheap) catch null);
        try testing.expectEqual(0, names.scanCount());

        var progress: Progress = .{};
        names.scanEverything(.live_only, &progress);
        try testing.expectEqual(1, progress.done.load(.acquire));
        try testing.expectEqual(@intFromPtr(&code), try names.find("Game.seed", .cheap));

        // Then it's a scan of its own, so it's rescanned instead
        progress = .{};
        names.scanEverything(.live_only, &progress);
        try testing.expectEqual(1, progress.total.load(.acquire));
        try testing.expectEqual(1, names.scanCount());
    }

    test "hooked code is found in the copies a lookup may use" {
        global = .init(testing.allocator);
        defer global.deinit();
        const previous = memory.scans.setRecorder(recordOwn);
        defer _ = memory.scans.setRecorder(previous);
        // A disk copy of .text where a marker sits, as if something hooked it live
        const text = try memory.Module.main().text();
        const Disk = struct {
            var bytes: []u8 = &.{};
            var start: usize = 0;
            fn provide(s: usize, len: usize) ?[*]const u8 {
                if (s < start or s + len > start + bytes.len) return null;
                return bytes[s - start ..].ptr;
            }
        };
        Disk.bytes = try testing.allocator.dupe(u8, @as([*]const u8, @ptrFromInt(text.start))[0..text.len]);
        defer testing.allocator.free(Disk.bytes);
        Disk.start = text.start;
        const marker = [_]u8{ 0xF1, 0xE2, 0xD3, 0xC4, 0xB5, 0xA6, 0x97, 0x88, 0x79, 0x6A, 0x5B, 0x4C, 0x3E };
        const at = Disk.bytes.len / 3;
        @memcpy(Disk.bytes[at..][0..marker.len], &marker);
        @memcpy(Disk.bytes[at + 100 ..][0..marker.len], &marker);
        const previous_disk = memory.originals.setProvider(.disk, Disk.provide);
        defer _ = memory.originals.setProvider(.disk, previous_disk);

        const sig = "sig(\"F1 E2 D3 C4 B5 A6 97 88 79 6A 5B 4C 3E\", FirstMatch, Section(\".text\"))";
        // A plugin that only wants live code doesn't get it
        const before = usePluginSources(.live_only);
        try testing.expectError(error.NotFound, global.eval(sig, .none, null));
        _ = usePluginSources(before);
        // Nor does anyone while Wraith's setting says so
        setDefaultSources(.live_only);
        try testing.expectError(error.NotFound, global.eval(sig, .none, null));
        setDefaultSources(.all);
        // Else it falls through to disk, and says so, even through a name
        try global.put(.{ .origin = .schema, .name = "Game.hooked", .where = .{ .text = .{ .text = "sig(\"F1 E2 D3 C4 B5 A6 97 88 79 6A 5B 4C 3E\", FirstMatch, Section(\".text\"))" } } });
        var source: memory.AddressSource = .live;
        try testing.expectEqual(text.start + at + 2, try global.evalFrom("Game.hooked + 2", .none, null, &source));
        try testing.expectEqual(.disk, source);
        // A sig's own say wins over the plugin's
        _ = usePluginSources(.live_only);
        defer _ = usePluginSources(null);
        source = .live;
        try testing.expectEqual(text.start + at, try global.evalFrom("sig(\"F1 E2 D3 C4 B5 A6 97 88 79 6A 5B 4C 3E\", FirstMatch, Sources(Disk), Section(\".text\"))", .none, null, &source));
        try testing.expectEqual(.disk, source);
    }

    test "manual scan" {
        var names: Names = .init(testing.allocator);
        defer names.deinit();
        const result = try names.scanManual("seed", "", ".text", "B80DF0ED5EB90DF0ED5E", .live_only);
        try testing.expectEqual(.found, result.outcome);
        try testing.expectEqual(@intFromPtr(&code), result.address);

        var out: [1]ScanInfo = undefined;
        _ = names.scanList(&out);
        try testing.expectEqual(&manual, out[0].owner.?);
        try testing.expectEqualStrings("manual", out[0].owner_name.get());
        try testing.expectEqualStrings("B8 0D F0 ED 5E B9 0D F0 ED 5E", out[0].pattern.get());
        try testing.expectEqual(@intFromPtr(&code), try names.get("seed"));
        try testing.expectError(error.InvalidSignature, names.scanManual("bad", "", ".text", "4", .live_only));

        try testing.expect(names.rescan(out[0].id, .only(.snapshot)));
        _ = names.scanList(&out);
        try testing.expectEqual(error.NoOriginalCopy, out[0].rescanned.?.err.?);
    }
};

test {
    _ = tests;
}
