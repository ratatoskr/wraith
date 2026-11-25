//! The game's named addresses for plugins and projects, see `Names`. Ids find entries. Each looks
//! names up the same way, through `Scope`.

const std = @import("std");

const mem = @import("tuft_mem");
const sigs = @import("tuft_schema").sigs;
const Owner = @import("tuft_event").Owner;
const OnGone = @import("Owned.zig").OnGone;
const api = @import("wraith_api");
const SalSchema = @import("salamander_schema").Schema;
const devtools = @import("tuft_devtools");

const Loaded = @import("../PluginLoader.zig").Loaded;
const Names = @import("../Names.zig");

pub fn get(_: *Loaded, id: []const u8) api.AddressError!usize {
    return Names.global.get(id);
}

pub fn add(loaded: *Loaded, entry: api.AddressEntry) api.AddressAddError!void {
    if (entry.id.len == 0 or std.mem.indexOfAny(u8, entry.id, " \t") != null) return error.InvalidId;
    if (entry.address.len == 0) return error.InvalidAddress;
    const lease = cleanup.lease(&loaded.owner) orelse return error.OutOfMemory;
    defer lease.end();
    var buf: [192]u8 = undefined;
    const full = loaded.ownName(&buf, entry.id) orelse return error.InvalidId;
    if (Names.global.has(.plugin, full)) return error.AlreadyAdded;
    var offsets: [16]isize = undefined;
    if (entry.offsets.len > offsets.len) return error.InvalidAddress;
    for (entry.offsets, 0..) |o, i| offsets[i] = @intCast(o);
    try Names.global.put(.{
        .origin = .plugin,
        .owner = &loaded.owner,
        .group = loaded.name,
        .name = full,
        .label = entry.name,
        .where = .{ .text = .{ .text = entry.address, .offsets = offsets[0..entry.offsets.len] } },
        .type = entry.type,
        .size = entry.size,
    });
}

pub fn remove(loaded: *Loaded, id: []const u8) void {
    var buf: [192]u8 = undefined;
    const full = loaded.ownName(&buf, id) orelse return;
    Names.global.remove(.plugin, &loaded.owner, full);
}

pub fn resolve(loaded: *Loaded, text: []const u8, names: []const api.Name, problem: *api.LocationProblem) api.AddressError!usize {
    return (try find(loaded, text, names, problem)).address;
}

pub const Found = struct { address: usize, source: mem.AddressSource };

/// Like `resolve`, saying which copy of the code it was worked out from.
pub fn find(loaded: *Loaded, text: []const u8, names: []const api.Name, problem: *api.LocationProblem) api.AddressError!Found {
    var found: mem.Location.Problem = .{};
    const scope: Scope = .{ .loaded = loaded, .names = names };
    const previous = Names.usePluginSources(sourcesOf(loaded));
    defer _ = Names.usePluginSources(previous);
    var source: mem.AddressSource = .live;
    const at = Names.global.evalFrom(text, scope.symbols(), &found, &source) catch |err| {
        problem.set(found.message());
        return switch (err) {
            error.Unreadable => error.Unreadable,
            error.NotFound => error.NotFound,
            else => error.InvalidAddress,
        };
    };
    return .{ .address = at, .source = source };
}

/// What it said its lookups may use, or null for Wraith's setting.
pub fn sourcesOf(loaded: *const Loaded) ?mem.Sources {
    const raw = loaded.address_sources.load(.acquire);
    return if (raw == 0) null else @bitCast(raw);
}

/// None at all goes back to Wraith's setting.
pub fn setSources(loaded: *Loaded, sources: mem.Sources) void {
    loaded.address_sources.store(if (sources.none()) 0 else @bitCast(sources), .release);
}

/// How a plugin, a project or a tweak looks names up, before everyone's in `Names`: `names` first,
/// then what its schemas declare, like `Player.instance`, then its own names without their
/// prefix, like `hp` for `kai.hp`.
pub const Scope = struct {
    loaded: ?*Loaded = null,
    names: []const api.Name = &.{},

    pub fn resolve(self: *const Scope, name: []const u8) ?usize {
        if (api.Name.find(self.names, name)) |at| return at;
        const loaded = self.loaded orelse return null;
        if (loaded.schemas) |s| {
            const schema = s.schema();
            if (schema.findStatic(name) != null or schema.findFunction(name) != null) return s.address(name) catch null;
        }
        var buf: [192]u8 = undefined;
        const own = loaded.ownName(&buf, name) orelse return null;
        if (own.len == name.len) return null;
        return Names.global.get(own) catch null;
    }

    /// Only good while `self` is.
    pub fn symbols(self: *const Scope) mem.Symbols {
        return .{ .context = @ptrCast(@constCast(self)), .vtable = &.{ .resolve = struct {
            fn resolve(context: ?*anyopaque, name: []const u8) ?usize {
                const scope: *const Scope = @ptrCast(@alignCast(context.?));
                return scope.resolve(name);
            }
        }.resolve } };
    }
};

/// The statics its own schemas declare, as names like `kai.Player.instance`, in place of what it
/// had. Not ones from plugins it depends on, which are theirs. Sessions name nothing.
pub fn publishStatics(loaded: *Loaded) void {
    if (loaded.session) return;
    const lease = cleanup.lease(&loaded.owner) orelse return;
    defer lease.end();
    Names.global.removeFrom(.schema, &loaded.owner);
    const s = loaded.schemas orelse return;
    const schema = &s.parsed.schema;
    const source = s.parsed.source;
    for (schema.statics) |st| nameStatic(loaded, schema, source, st, "");
    for (schema.functions) |f| nameFunction(loaded, source, f, "");
    for (schema.types) |t| switch (t.kind) {
        .@"struct" => |st| {
            for (st.statics) |one| nameStatic(loaded, schema, source, one, t.name);
            for (st.methods) |m| if (m.virtual == null) nameFunction(loaded, source, m, t.name);
        },
        else => {},
    };
}

fn nameStatic(loaded: *Loaded, schema: *const SalSchema, source: []const u8, st: SalSchema.Static, owner: []const u8) void {
    var type_buf: [256]u8 = undefined;
    const type_text = std.fmt.bufPrint(&type_buf, "{f}", .{st.type}) catch "";
    nameSig(loaded, source, st.at, st.annotations, owner, st.name, .data, type_text, schema.sizeOf(st.type) orelse 0);
}

fn nameFunction(loaded: *Loaded, source: []const u8, m: SalSchema.Method, owner: []const u8) void {
    var type_buf: [256]u8 = undefined;
    const type_text = std.fmt.bufPrint(&type_buf, "fn{f}", .{m.signature}) catch "fn";
    nameSig(loaded, source, m.at, m.annotations, owner, m.name, .function, type_text, 0);
}

/// Something of its own schemas with a `[Sig]`, as a name like `kai.Player.update`.
fn nameSig(loaded: *Loaded, source: []const u8, at: SalSchema.Pos, annotations: []const SalSchema.Annotation, owner: []const u8, member: []const u8, kind: Names.Kind, type_text: []const u8, size: usize) void {
    if (!ownFile(loaded, SalSchema.fileOf(source, at))) return;
    var steps: [sigs.max_steps]mem.Sig.Step = undefined;
    const sig = (sigs.of(annotations, "wraith", "Sig", &steps) catch return) orelse return;
    var id_buf: [192]u8 = undefined;
    const full = (if (owner.len > 0) std.fmt.bufPrint(&id_buf, "{s}.{s}", .{ owner, member }) else member) catch return;
    // Without its own namespace, which its name's prefix already says
    var ns_buf: [@import("wraith_core").manifest.namespace_max]u8 = undefined;
    const ns = @import("wraith_core").manifest.namespaceOf(&ns_buf, loaded.name);
    const id = if (ns.len > 0 and full.len > ns.len and std.mem.startsWith(u8, full, ns) and full[ns.len] == '.') full[ns.len + 1 ..] else full;
    var name_buf: [256]u8 = undefined;
    const name = loaded.ownName(&name_buf, id) orelse return;
    var text_buf: [1024]u8 = undefined;
    Names.global.put(.{
        .origin = .schema,
        .kind = kind,
        .owner = &loaded.owner,
        .group = loaded.displayName(),
        .name = name,
        .where = .{ .text = .{ .text = std.fmt.bufPrint(&text_buf, "{f}", .{sig}) catch return } },
        .type = type_text,
        .size = size,
    }) catch {};
}

/// One of its own files, like `kai/game.sal`, not a dependency's.
pub fn ownFile(loaded: *const Loaded, file: []const u8) bool {
    return file.len > loaded.name.len and std.mem.startsWith(u8, file, loaded.name) and file[loaded.name.len] == '/';
}

/// An address list it has, like a project's, as its own names. The open project's are the user's,
/// which come before everyone else's.
pub fn publishList(loaded: *Loaded, items: []const devtools.AddressList.Item) void {
    const lease = cleanup.lease(&loaded.owner) orelse return;
    defer lease.end();
    const schemas: []const *const SalSchema = if (loaded.schemas) |s| &.{&s.parsed.schema} else &.{};
    const origin: Names.Origin = if (loaded.prefix().len == 0) .user else .plugin;
    Names.global.setList(origin, &loaded.owner, loaded.displayName(), loaded.prefix(), items, schemas);
}

var cleanup: OnGone(.released, released) = .{};

fn released(owner: *Owner) void {
    Names.global.removeOwner(owner);
}

const tests = struct {
    const testing = std.testing;

    test "ids find plugin entries until the plugin goes" {
        Names.global = .init(testing.allocator);
        defer Names.global.deinit();
        var value: u32 = 5;
        var pointer: *u32 = &value;
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");

        var buf: [32]u8 = undefined;
        const before = Names.global.generation();
        try add(&loaded, .{ .id = "hp", .address = try std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(&pointer)}), .offsets = &.{0}, .type = "u32" });
        try testing.expect(Names.global.generation() != before);
        try testing.expectError(error.AlreadyAdded, add(&loaded, .{ .id = "hp", .address = "0x1" }));
        try testing.expectEqual(@intFromPtr(&value), try get(&loaded, "kai.hp"));

        var shown: [2]Names.Info = undefined;
        try testing.expectEqual(1, Names.global.list(&shown));
        try testing.expectEqual(.plugin, shown[0].origin);
        try testing.expectEqualStrings("kai", shown[0].group.get());

        var problem: api.LocationProblem = .{};
        const names = [_]api.Name{.of("mine", 0x40)};
        try testing.expectEqual(0x48, try resolve(&loaded, "mine + 8", &names, &problem));
        try testing.expectEqual(@intFromPtr(&value) + 2, try resolve(&loaded, "(kai.hp)+2", &.{}, &problem));
        // Its own, without its name in front
        try testing.expectEqual(@intFromPtr(&value), try resolve(&loaded, "hp", &.{}, &problem));
        try testing.expectError(error.InvalidAddress, resolve(&loaded, "nobody", &.{}, &problem));
        try testing.expectEqualStrings("there's no nobody", problem.message());

        remove(&loaded, "hp");
        try testing.expectError(error.NotFound, get(&loaded, "kai.hp"));
        try add(&loaded, .{ .id = "hp", .address = "0x1" });
        loaded.deinitForTest();
        try testing.expectError(error.NotFound, get(&loaded, "kai.hp"));
    }
};

test {
    _ = tests;
}
