//! A plugin's schemas: Wraith's, its dependencies' and its own, as one. What they declare is found
//! by name when first asked for, then kept.

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");
const mem = @import("tuft_mem");
const sigs = @import("tuft_schema").sigs;
const sync = @import("tuft_sys").sync;
const salamander_schema = @import("salamander_schema");
const bind = @import("salamander_bind");

const Loaded = @import("../PluginLoader.zig").Loaded;
const Names = @import("../Names.zig");
const managed_area = @import("managed_area.zig");
const managed_calls = @import("managed_calls.zig");

const SalSchema = salamander_schema.Schema;
const sal = api.salamander;
const log = core.log.scoped(.wraith_runtime);
const allocator = core.heap.main;

pub const Area = api.wraith.Schema;
pub const File = salamander_schema.File;

/// The biggest `.sal` a plugin can have.
const max_file = 4 << 20;

/// A function's signature worked out once and kept, since what it makes is the host's.
pub const Typed = struct {
    function: *const bind.Function,
    /// A fn value's trait with that signature, to call handlers through.
    trait: *const bind.Trait,
};

pub const Schemas = struct {
    /// Wraith's bundle, then the rest.
    text: []u8,
    parsed: salamander_schema.Parsed,
    /// Its dependencies' and its own, named like `plugin/path.sal`, for plugins that depend on it.
    files: []File = &.{},
    /// How it parsed, each plugin's files in its namespace, kept for signatures. In `arena`.
    options: salamander_schema.Options,
    arena: std.heap.ArenaAllocator,
    /// The plugin's own namespace, where names it's given as text are looked for first.
    home_buf: [core.manifest.namespace_max]u8 = undefined,
    lock: sync.RwLock = .{},
    found: std.StringHashMapUnmanaged(usize) = .empty,
    typed: std.StringHashMapUnmanaged(Typed) = .empty,

    pub fn schema(self: *const Schemas) SalSchema {
        return self.parsed.schema;
    }

    /// Takes `text` and `files` if it works. What's wrong goes in `diag`.
    fn create(text: []u8, files: []File, diag: *SalSchema.Diagnostic) error{ OutOfMemory, InvalidSchema }!*Schemas {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        errdefer arena.deinit();
        const options = try optionsFor(arena.allocator(), files);
        var parsed = try salamander_schema.parse(allocator, text, options, diag);
        errdefer parsed.deinit();
        try checkAnnotations(parsed.schema, parsed.source, diag);
        const self = try allocator.create(Schemas);
        self.* = .{ .text = text, .parsed = parsed, .files = files, .options = options, .arena = arena };
        return self;
    }

    /// Names given as text, like `Player.heal`, are looked for in plugin `name`'s namespace first.
    pub fn setHome(self: *Schemas, name: []const u8) void {
        self.options.namespace = core.manifest.namespaceOf(&self.home_buf, name);
    }

    /// The full name `name` means from the plugin's namespace. In `buf`.
    pub fn fullName(self: *const Schemas, buf: []u8, name: []const u8) []const u8 {
        return self.schema().nameFrom(buf, self.options.namespace, name);
    }

    pub fn destroy(self: *Schemas) void {
        var it = self.found.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.found.deinit(allocator);
        var typed_keys = self.typed.keyIterator();
        while (typed_keys.next()) |k| allocator.free(k.*);
        self.typed.deinit(allocator);
        freeFileList(self.files);
        self.parsed.deinit();
        self.arena.deinit();
        allocator.free(self.text);
        allocator.destroy(self);
    }

    /// `text`, like `[Thiscall] fn i32 (usize self)` or a declared name like `Player.heal`. Says what's wrong if unusable.
    pub fn typedOf(self: *Schemas, text: []const u8) error{ InvalidSignature, OutOfMemory }!Typed {
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            if (self.typed.get(text)) |found| return found;
        }
        var diag: SalSchema.Diagnostic = .{};
        var parsed = salamander_schema.parseSignature(allocator, self.text, text, self.options, &diag) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.NotASignature => sal.host().explain(error.InvalidSignature, "a signature looks like `fn i32 (u32 a)` or a declared name like `Player.heal`, not `{s}`", .{text}),
            else => sal.host().explain(error.InvalidSignature, "{s}", .{diag.message()}),
        };
        defer parsed.deinit();
        const s = parsed.schema;
        const sig = s.findType(salamander_schema.signature_name).?.kind.func;
        const function = bind.Function.init(sal.host(), s, sig) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.Unsupported => sal.host().explain(error.InvalidSignature, "`{s}` can't cross to native code", .{text}),
        };
        var methods = [_]SalSchema.Method{.{ .name = "call", .signature = sig }};
        const decl: SalSchema.Trait = .{ .name = "fn", .methods = &methods };
        const trait = bind.Trait.init(sal.host(), s, &decl) catch return error.OutOfMemory;
        const found: Typed = .{ .function = function, .trait = trait };
        self.lock.lock();
        defer self.lock.unlock();
        if (self.typed.get(text)) |already| return already;
        try self.typed.put(allocator, try allocator.dupe(u8, text), found);
        return found;
    }

    pub const Error = error{ Unknown, NotFound, NeedsObject };

    /// Where a function, method, static or vtable is. Kept once found. Looked for in its namespace first.
    pub fn address(self: *Schemas, written: []const u8) Error!usize {
        var buf: [512]u8 = undefined;
        const name = self.fullName(&buf, written);
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            if (self.found.get(name)) |a| return a;
        }
        const s = self.schema();
        const a = if (s.findStatic(name)) |v|
            if (managedOf(v.static.annotations, v.owner, v.static.name, self.options.file_namespaces)) |m|
                try findManaged(m, .static, name)
            else
                try locate(v.static.annotations, "Sig", name)
        else if (s.findFunction(name)) |f| blk: {
            if (f.method.virtual) |_| break :blk try readSlot(try self.slot(name));
            if (managedOf(f.method.annotations, f.owner, f.method.name, self.options.file_namespaces)) |m| {
                if (m.icall) break :blk try findManaged(m, .icall, name);
                // Called through Wraith, which converts what it's given and calls in where it can
                const typed = self.typedOf(name) catch |err| return switch (err) {
                    error.OutOfMemory => sal.host().explain(error.NotFound, "out of memory finding {s}", .{name}),
                    error.InvalidSignature => error.NotFound,
                };
                break :blk managed_calls.entry(name, m.class, m.member, s, f, typed.function) catch |err| switch (err) {
                    error.OutOfMemory => return sal.host().explain(error.NotFound, "out of memory finding {s}", .{name}),
                    error.NotFound => return error.NotFound,
                };
            }
            break :blk try locate(f.method.annotations, "Sig", name);
        } else if (s.findType(name)) |t|
            try self.vtable(t)
        else
            return sal.host().explain(error.Unknown, "the plugin's schemas don't declare {s}", .{name});
        self.lock.lock();
        defer self.lock.unlock();
        const key = allocator.dupe(u8, name) catch return a;
        self.found.put(allocator, key, a) catch allocator.free(key);
        return a;
    }

    /// Where a [Virtual(n)] method's function pointer is, in its struct's [VirtualTable].
    pub fn slot(self: *Schemas, written: []const u8) Error!usize {
        var buf: [512]u8 = undefined;
        const name = self.fullName(&buf, written);
        const s = self.schema();
        const f = s.findFunction(name) orelse return sal.host().explain(error.Unknown, "the plugin's schemas don't declare {s}", .{name});
        const n = f.method.virtual orelse return sal.host().explain(error.Unknown, "{s} isn't [Virtual(n)]", .{name});
        const in = f.in.?;
        const table = self.address(in.name) catch |err| return switch (err) {
            error.Unknown => sal.host().explain(error.NeedsObject, "{s} has no [VirtualTable], so {s} needs an object", .{ in.name, name }),
            else => err,
        };
        return table + n * s.pointer_size;
    }

    /// Where `object` has a method, through its own vtable for [Virtual(n)] ones.
    pub fn method(self: *Schemas, object: usize, written: []const u8) Error!usize {
        var buf: [512]u8 = undefined;
        const name = self.fullName(&buf, written);
        const s = self.schema();
        const f = s.findFunction(name) orelse return sal.host().explain(error.Unknown, "the plugin's schemas don't declare {s}", .{name});
        const n = f.method.virtual orelse return self.address(name);
        const table = try readSlot(object);
        return readSlot(table + n * s.pointer_size);
    }

    fn vtable(_: *Schemas, t: *const SalSchema.Type) Error!usize {
        if (SalSchema.findAnnotation(t.annotations, "wraith", "VirtualTable") == null) return error.Unknown;
        return locate(t.annotations, "VirtualTable", t.name);
    }

    /// The [Service] traits in `plugin`'s own files, not ones from plugins it depends on.
    pub fn services(self: *const Schemas, gpa: std.mem.Allocator, plugin: []const u8) error{OutOfMemory}![]const []const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer list.deinit(gpa);
        for (self.schema().traits) |t| {
            if (SalSchema.findAnnotation(t.annotations, "wraith", "Service") == null) continue;
            const file = SalSchema.fileOf(self.parsed.source, t.at);
            if (file.len > plugin.len and std.mem.startsWith(u8, file, plugin) and file[plugin.len] == '/') try list.append(gpa, t.name);
        }
        return list.toOwnedSlice(gpa);
    }
};

/// Each plugin's files in its namespace, and every file using them all with Wraith's, like its build.
fn optionsFor(arena: std.mem.Allocator, files: []const File) error{OutOfMemory}!salamander_schema.Options {
    var o = api.sal_options;
    var spaces: std.ArrayList(salamander_schema.FileNamespace) = .empty;
    var uses: std.ArrayList([]const u8) = .empty;
    try uses.appendSlice(arena, api.sal_options.global_uses);
    outer: for (files) |f| {
        const slash = std.mem.indexOfScalar(u8, f.name, '/') orelse continue;
        const prefix = f.name[0 .. slash + 1];
        for (spaces.items) |s| if (std.mem.eql(u8, s.prefix, prefix)) continue :outer;
        var buf: [core.manifest.namespace_max]u8 = undefined;
        const ns = try arena.dupe(u8, core.manifest.namespaceOf(&buf, prefix[0..slash]));
        try spaces.append(arena, .{ .prefix = try arena.dupe(u8, prefix), .namespace = ns });
        try uses.append(arena, ns);
    }
    o.file_namespaces = spaces.items;
    o.global_uses = uses.items;
    return o;
}

/// How a script parses bundle `text`, matching `Schemas`, with namespace `home` first. In `arena`.
pub fn scriptOptions(arena: std.mem.Allocator, text: []const u8, home: []const u8) error{OutOfMemory}!salamander_schema.Options {
    var files: std.ArrayList(File) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, SalSchema.bundle_marker)) continue;
        const name = line[SalSchema.bundle_marker.len..];
        const end = std.mem.indexOfScalar(u8, name, '"') orelse continue;
        try files.append(arena, .{ .name = name[0..end], .text = "" });
    }
    var o = try optionsFor(arena, files.items);
    o.namespace = try arena.dupe(u8, home);
    return o;
}

fn readSlot(at: usize) Schemas.Error!usize {
    var value: usize = 0;
    mem.Memory.local.read(at, std.mem.asBytes(&value)) catch return sal.host().explain(error.NotFound, "can't read 0x{x}", .{at});
    if (value == 0) return sal.host().explain(error.NotFound, "0x{x} is null", .{at});
    return value;
}

/// A schema member that's in the game's C#, from its `[Managed]` or `[Icall]`.
const ManagedName = struct {
    class: []const u8,
    member: []const u8,
    icall: bool,
};

/// `[Managed]`, `[Managed("Name")]` or `[Managed("Ns.Class:Name")]`, likewise `[Icall]`. Null if it has
/// neither or can't name a class.
fn managedOf(annotations: []const SalSchema.Annotation, owner: ?*const SalSchema.Type, own_name: []const u8, spaces: []const salamander_schema.FileNamespace) ?ManagedName {
    const icall = SalSchema.findAnnotation(annotations, "wraith", "Icall");
    const a = SalSchema.findAnnotation(annotations, "wraith", "Managed") orelse icall orelse return null;
    const given: ?[]const u8 = if (a.args.len > 0 and a.args[0] == .string) a.args[0].string else null;
    if (given) |g| if (splitMember(g)) |parts| return .{ .class = parts[0], .member = parts[1], .icall = icall != null };
    const t = owner orelse return null;
    return .{ .class = classOf(t, spaces), .member = given orelse own_name, .icall = icall != null };
}

/// The C# class a struct stands for, from `[Managed("Ns.Class")]` else its name, without the plugin's namespace.
fn classOf(t: *const SalSchema.Type, spaces: []const salamander_schema.FileNamespace) []const u8 {
    if (SalSchema.findAnnotation(t.annotations, "wraith", "Managed")) |a|
        if (a.args.len > 0 and a.args[0] == .string) return a.args[0].string;
    for (spaces) |s| {
        if (t.name.len > s.namespace.len and std.mem.startsWith(u8, t.name, s.namespace) and t.name[s.namespace.len] == '.')
            return t.name[s.namespace.len + 1 ..];
    }
    return t.name;
}

/// `Ns.Class:Name`, or `Ns.Class::Name` as engine calls are written.
fn splitMember(text: []const u8) ?[2][]const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, text, ':') orelse return null;
    const class = std.mem.trimEnd(u8, text[0..colon], ":");
    if (class.len == 0 or colon + 1 == text.len) return null;
    return .{ class, text[colon + 1 ..] };
}

fn findManaged(m: ManagedName, member: managed_area.Member, name: []const u8) Schemas.Error!usize {
    const sep = if (m.icall) "::" else ":";
    return managed_area.memberAddress(m.class, m.member, member) catch |err| sal.host().explain(error.NotFound, "{s} is {s}{s}{s} in the game's C#, which {s}", .{ name, m.class, sep, m.member, switch (err) {
        error.NotRunning => "isn't running yet",
        error.Unsupported => "can't say where it is, like a thread static",
        error.NotFound => "doesn't have it",
        else => "couldn't find it",
    } });
}

/// Runs the `[Sig]` or `[VirtualTable]` with its `[Module]` and `[Section]`, through `Names` so it's cached and listed.
fn locate(annotations: []const SalSchema.Annotation, which: []const u8, name: []const u8) Schemas.Error!usize {
    var steps: [sigs.max_steps]mem.Sig.Step = undefined;
    const sig = (sigs.of(annotations, "wraith", which, &steps) catch unreachable) orelse return sal.host().explain(error.NotFound, "{s} has no [{s}]", .{ name, which });
    const found = Names.global.symbols().scan(sig, name).unwrap() catch |err| return sal.host().explain(error.NotFound, "{s}'s [{s}(\"{s}\")] wasn't found: {t}", .{ name, which, sig.pattern, err });
    return found;
}

/// So a `[Sig]` that can't mean anything fails as the plugin loads, saying where.
fn checkAnnotations(s: SalSchema, source: []const u8, diag: *SalSchema.Diagnostic) error{InvalidSchema}!void {
    for (s.types) |*t| {
        if (SalSchema.findAnnotation(t.annotations, "wraith", "Service")) |a| return diag.fail(source, a.at, "[Service] goes on a trait, and {s} isn't one", .{t.name});
        try checkOne(t.annotations, "VirtualTable", source, diag);
        try checkTweak(s, t, source, diag);
        const st = switch (t.kind) {
            .@"struct" => |st| st,
            else => continue,
        };
        for (st.fields) |f| try checkField(s, t.name, f, source, diag);
        for (st.methods) |m| try checkOne(m.annotations, "Sig", source, diag);
        for (st.statics) |v| try checkOne(v.annotations, "Sig", source, diag);
        if (SalSchema.findAnnotation(t.annotations, "wraith", "Managed")) |a| {
            if (a.args.len != 1 or a.args[0] != .string) return diag.fail(source, a.at, "[Managed] on a struct takes its C# class, like [Managed(\"Game.Player\")]", .{});
        }
        for (st.methods) |m| try checkManaged(m.annotations, true, false, source, diag);
        for (st.statics) |v| try checkManaged(v.annotations, true, true, source, diag);
    }
    for (s.functions) |f| try checkOne(f.annotations, "Sig", source, diag);
    for (s.statics) |v| try checkOne(v.annotations, "Sig", source, diag);
    for (s.functions) |f| try checkManaged(f.annotations, false, false, source, diag);
    for (s.statics) |v| try checkManaged(v.annotations, false, true, source, diag);
}

fn checkManaged(annotations: []const SalSchema.Annotation, in_struct: bool, is_static: bool, source: []const u8, diag: *SalSchema.Diagnostic) error{InvalidSchema}!void {
    const icall = SalSchema.findAnnotation(annotations, "wraith", "Icall");
    const managed = SalSchema.findAnnotation(annotations, "wraith", "Managed");
    const a = managed orelse icall orelse return;
    const which = if (managed != null) "Managed" else "Icall";
    if (managed != null and icall != null) return diag.fail(source, a.at, "it's [Managed] or [Icall], not both", .{});
    if (SalSchema.findAnnotation(annotations, "wraith", "Sig") != null) return diag.fail(source, a.at, "[{s}] finds it by name, so it can't have a [Sig] too", .{which});
    if (icall != null and is_static) return diag.fail(source, a.at, "[Icall] is for functions. Statics are [Managed]", .{});
    if (a.args.len > 1 or (a.args.len == 1 and a.args[0] != .string)) return diag.fail(source, a.at, "[{s}] takes nothing, its C# name, or its class and name like \"Game.Player:Update\"", .{which});
    const full = a.args.len == 1 and splitMember(a.args[0].string) != null;
    if (!in_struct and !full) return diag.fail(source, a.at, "[{s}] outside a struct needs its class too, like [{s}(\"Game.Player:Update\")]", .{ which, which });
}

/// `[Tweak("..")]` goes on a struct Wraith can find, so one with `[Instance]`.
fn checkTweak(s: SalSchema, t: *const SalSchema.Type, source: []const u8, diag: *SalSchema.Diagnostic) error{InvalidSchema}!void {
    const a = SalSchema.findAnnotation(t.annotations, "wraith", "Tweak") orelse return;
    if (t.kind != .@"struct") return diag.fail(source, a.at, "[Tweak] goes on a struct, and {s} isn't one", .{t.name});
    if (a.args.len != 1 or a.args[0] != .string) return diag.fail(source, a.at, "[Tweak] takes its title, like [Tweak(\"Money\")]", .{});
    if (s.staticOf(t, "instance") == null) return diag.fail(source, a.at, "[Tweak] needs [Instance] too, so Wraith can find {s} in the game", .{t.name});
}

fn checkField(s: SalSchema, owner: []const u8, f: SalSchema.Field, source: []const u8, diag: *SalSchema.Diagnostic) error{InvalidSchema}!void {
    if (SalSchema.findAnnotation(f.annotations, "wraith", "Label")) |a| {
        if (a.args.len != 1 or a.args[0] != .string) return diag.fail(source, a.at, "[Label] takes the text to show, like [Label(\"Mira\")]", .{});
    }
    if (SalSchema.findAnnotation(f.annotations, "wraith", "Range")) |a| {
        const numbers = a.args.len == 2 and for (a.args) |arg| {
            if (arg != .int and arg != .float) break false;
        } else true;
        if (!numbers) return diag.fail(source, a.at, "[Range] takes the lowest and highest, like [Range(0, 9999999)]", .{});
    }
    if (SalSchema.findAnnotation(f.annotations, "wraith", "Choices")) |a| try checkChoices(s, owner, a, source, diag);
}

/// `[Choices("Type.path.to.list", id, name)]`: a type with `[Instance]`, fields down to an array of
/// structs, and the two fields in those. Just the path means `id` and `name`.
fn checkChoices(s: SalSchema, owner: []const u8, a: *const SalSchema.Annotation, source: []const u8, diag: *SalSchema.Diagnostic) error{InvalidSchema}!void {
    const usage = "[Choices] takes where the list is, then its id and name fields if not id and name, like [Choices(\"DataTables.items\", id, name)]";
    if ((a.args.len != 1 and a.args.len != 3) or a.args[0] != .string) return diag.fail(source, a.at, usage, .{});
    const id = if (a.args.len > 1) a.args[1].name() orelse return diag.fail(source, a.at, usage, .{}) else "id";
    const name = if (a.args.len > 2) a.args[2].name() orelse return diag.fail(source, a.at, usage, .{}) else "name";
    const path = a.args[0].string;
    // Its type can be in a namespace, so it's the longest start that names one
    var buf: [512]u8 = undefined;
    const found = choicesPath(s, &buf, owner, path);
    const full = if (found) |p| p.path else path;
    const dot = if (found) |p| p.dot else std.mem.indexOfScalar(u8, path, '.') orelse path.len;
    var parts = std.mem.splitScalar(u8, if (dot < full.len) full[dot + 1 ..] else "", '.');
    const root = full[0..dot];
    var t = s.findType(root) orelse return diag.fail(source, a.at, "[Choices] starts at a type, and there's no {s}", .{root});
    if (s.staticOf(t, "instance") == null) return diag.fail(source, a.at, "[Choices] starts at a type with [Instance], and {s} has none", .{root});
    var list: ?SalSchema.Ref = null;
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        if (list != null) return diag.fail(source, a.at, "[Choices] path {s} goes on past its list", .{path});
        const f = s.findField(t, part) orelse return diag.fail(source, a.at, "{s} has no field {s}", .{ t.name, part });
        var ty = f.type;
        while (ty == .pointer or ty == .optional) ty = if (ty == .pointer) ty.pointer.* else ty.optional.*;
        switch (ty) {
            .array => |arr| list = arr.child.*,
            .named => |n| t = s.findType(n) orelse return diag.fail(source, a.at, "there's no {s}", .{n}),
            else => return diag.fail(source, a.at, "[Choices] path {s} has to lead to an array", .{path}),
        }
    }
    const item_name = switch (list orelse return diag.fail(source, a.at, "[Choices] path {s} has to lead to an array", .{path})) {
        .named => |n| n,
        else => return diag.fail(source, a.at, "[Choices] needs a list of structs, to find {s} and {s} in", .{ id, name }),
    };
    const item = s.findType(item_name) orelse return diag.fail(source, a.at, "there's no {s}", .{item_name});
    if (s.findField(item, id) == null) return diag.fail(source, a.at, "{s} has no field {s}", .{ item.name, id });
    if (s.findField(item, name) == null) return diag.fail(source, a.at, "{s} has no field {s}", .{ item.name, name });
}

/// `[Choices]` `path` with its type's full name, in `buf` if longer, and where that name ends. Resolved
/// from namespace `owner` outward, like other schema names.
pub fn choicesPath(s: SalSchema, buf: []u8, owner: []const u8, path: []const u8) ?struct { path: []const u8, dot: usize } {
    var at = owner[0 .. std.mem.lastIndexOfScalar(u8, owner, '.') orelse 0];
    while (at.len > 0) : (at = at[0 .. std.mem.lastIndexOfScalar(u8, at, '.') orelse 0]) {
        const full = std.fmt.bufPrint(buf, "{s}.{s}", .{ at, path }) catch break;
        if (s.typePrefix(full)) |dot| return .{ .path = full, .dot = dot };
    }
    return if (s.typePrefix(path)) |dot| .{ .path = path, .dot = dot } else null;
}

fn checkOne(annotations: []const SalSchema.Annotation, which: []const u8, source: []const u8, diag: *SalSchema.Diagnostic) error{InvalidSchema}!void {
    var steps: [sigs.max_steps]mem.Sig.Step = undefined;
    const at = if (sigs.find(annotations, "wraith", which)) |a| a.at else return;
    _ = sigs.of(annotations, "wraith", which, &steps) catch |err| return diag.fail(source, at, "{s}", .{sigs.explain(err)});
}

var shared_lock: sync.RwLock = .{};
var shared: ?*Schemas = null;

/// Wraith's alone, for plugins without their own.
pub fn wraithOnly() error{ OutOfMemory, InvalidSchema }!*Schemas {
    shared_lock.lock();
    defer shared_lock.unlock();
    if (shared) |s| return s;
    const text = try allocator.dupe(u8, api.wraith_sal);
    errdefer allocator.free(text);
    var diag: SalSchema.Diagnostic = .{};
    const s = Schemas.create(text, &.{}, &diag) catch |err| {
        if (err == error.InvalidSchema) log.err("{s}", .{diag.message()});
        return err;
    };
    shared = s;
    return s;
}

/// The plugin's, or Wraith's alone.
pub fn of(loaded: *Loaded) error{ OutOfMemory, InvalidSchema }!*Schemas {
    return loaded.schemas orelse wraithOnly();
}

/// Its `schemas` folder's files with its dependencies'. Null if there are none.
pub fn load(io: std.Io, name: []const u8, dir: []const u8, depends: []const *Loaded) !?*Schemas {
    var files: std.ArrayList(File) = .empty;
    defer {
        freeFiles(files.items);
        files.deinit(allocator);
    }
    for (depends) |d| {
        const theirs = d.schemas orelse continue;
        outer: for (theirs.files) |f| {
            for (files.items) |have| if (std.mem.eql(u8, have.name, f.name)) continue :outer;
            try files.ensureUnusedCapacity(allocator, 1);
            const n = try allocator.dupe(u8, f.name);
            errdefer allocator.free(n);
            files.appendAssumeCapacity(.{ .name = n, .text = try allocator.dupe(u8, f.text) });
        }
    }
    try readFolder(allocator, io, name, dir, &files);
    if (files.items.len == 0) return null;
    var diag: SalSchema.Diagnostic = .{};
    const made = fromFilesWhy(files.items, &diag) catch |err| {
        if (err == error.InvalidSchema) log.err("{s}", .{diag.message()});
        return err;
    };
    made.setHome(name);
    return made;
}

/// Wraith's with `files`, named like `plugin/path.sal`. Copied.
pub fn fromFiles(files: []const File) error{ OutOfMemory, InvalidSchema }!*Schemas {
    var diag: SalSchema.Diagnostic = .{};
    return fromFilesWhy(files, &diag);
}

/// Like `fromFiles`, saying what's wrong in `diag`.
pub fn fromFilesWhy(files: []const File, diag: *SalSchema.Diagnostic) error{ OutOfMemory, InvalidSchema }!*Schemas {
    const rest = salamander_schema.bundle(allocator, files) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidFileName => error.InvalidSchema,
    };
    defer allocator.free(rest);
    const text = try std.mem.concat(allocator, u8, &.{ api.wraith_sal, "\n", rest });
    errdefer allocator.free(text);
    const owned = try allocator.alloc(File, files.len);
    errdefer allocator.free(owned);
    var done: usize = 0;
    errdefer freeFiles(owned[0..done]);
    for (files, owned) |f, *o| {
        const n = try allocator.dupe(u8, f.name);
        errdefer allocator.free(n);
        o.* = .{ .name = n, .text = try allocator.dupe(u8, f.text) };
        done += 1;
    }
    return Schemas.create(text, owned, diag);
}

var adding: sync.RwLock = .{};

/// Adds or replaces file `name` in a plugin's schemas, like a tweak's types. The old ones stay till
/// it's unloaded, since what they found is in use.
pub fn addFile(loaded: *Loaded, name: []const u8, text: []const u8) SchemaError!void {
    adding.lock();
    defer adding.unlock();
    var files: std.ArrayList(File) = .empty;
    defer files.deinit(allocator);
    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ loaded.name, name }) catch return error.OutOfMemory;
    defer allocator.free(full);
    if (loaded.schemas) |old| for (old.files) |f| {
        if (!std.mem.eql(u8, f.name, full)) files.append(allocator, f) catch return error.OutOfMemory;
    };
    files.append(allocator, .{ .name = full, .text = text }) catch return error.OutOfMemory;
    var diag: SalSchema.Diagnostic = .{};
    const made = fromFilesWhy(files.items, &diag) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidSchema => sal.host().explain(error.Invalid, "{s}", .{diag.message()}),
    };
    if (loaded.schemas) |old| loaded.retired_schemas.append(allocator, old) catch {};
    made.setHome(loaded.name);
    loaded.schemas = made;
    @import("shared_schemas.zig").publish(loaded);
}

pub const SchemaError = error{ OutOfMemory, Invalid };

/// The `.sal` files under `dir_path/schemas`, recursively, named like `name/game.sal`, sorted, onto `files`.
pub fn readFolder(gpa: std.mem.Allocator, io: std.Io, name: []const u8, dir_path: []const u8, files: *std.ArrayList(File)) !void {
    const path = try std.fs.path.join(gpa, &.{ dir_path, "schemas" });
    defer gpa.free(path);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(gpa);
    defer walker.deinit(io);
    const start = files.items.len;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".sal")) continue;
        try files.ensureUnusedCapacity(gpa, 1);
        const text = try dir.readFileAlloc(io, entry.path, gpa, .limited(max_file));
        errdefer gpa.free(text);
        const file_name = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ name, entry.path });
        std.mem.replaceScalar(u8, file_name, '\\', '/');
        files.appendAssumeCapacity(.{ .name = file_name, .text = text });
    }
    // A bundle's sorted by name, so it's always the same
    std.mem.sort(File, files.items[start..], {}, struct {
        fn less(_: void, a: File, b: File) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
}

fn freeFiles(files: []File) void {
    for (files) |f| {
        allocator.free(f.name);
        allocator.free(f.text);
    }
}

fn freeFileList(files: []File) void {
    freeFiles(files);
    if (files.len > 0) allocator.free(files);
}

// The `Schema` area

pub const SchemaImpl = struct {
    pub fn add(loaded: *Loaded, name: []const u8, text: []const u8) sal.Plain(Area, "add") {
        return addFile(loaded, name, text) catch |err| switch (err) {
            error.Invalid => error.Invalid,
            error.OutOfMemory => error.Failed,
        };
    }

    pub fn address(loaded: *Loaded, name: []const u8) sal.Plain(Area, "address") {
        const s = of(loaded) catch return error.Unknown;
        const previous = Names.usePluginSources(@import("addresses.zig").sourcesOf(loaded));
        defer _ = Names.usePluginSources(previous);
        return s.address(name);
    }

    pub fn method(loaded: *Loaded, object: usize, name: []const u8) sal.Plain(Area, "method") {
        const s = of(loaded) catch return error.Unknown;
        return s.method(object, name);
    }
};

test "[Managed] and [Icall] are checked as the schemas load" {
    const testing = std.testing;
    const bad = [_][2][]const u8{
        .{ "[Managed] i32 update();", "[Managed] outside a struct needs its class too, like [Managed(\"Game.Player:Update\")]" },
        .{ "[Managed] struct Player { i32 hp; }", "[Managed] on a struct takes its C# class, like [Managed(\"Game.Player\")]" },
        .{ "struct Player { [Managed] [Sig(\"90\")] void update(); }", "[Managed] finds it by name, so it can't have a [Sig] too" },
        .{ "struct Player { [Icall] static i32 count; }", "[Icall] is for functions. Statics are [Managed]" },
        .{ "struct Player { [Managed(1)] void update(); }", "[Managed] takes nothing, its C# name, or its class and name like \"Game.Player:Update\"" },
        .{ "struct Player { [Managed] [Icall] void update(); }", "it's [Managed] or [Icall], not both" },
    };
    for (bad) |case| {
        var diag: SalSchema.Diagnostic = .{};
        try testing.expectError(error.InvalidSchema, fromFilesWhy(&.{.{ .name = "kai/game.sal", .text = case[0] }}, &diag));
        try testing.expect(std.mem.indexOf(u8, diag.message(), case[1]) != null);
    }

    const good = try fromFiles(&.{.{ .name = "kai/game.sal", .text =
        \\[Managed("Game.Player")]
        \\struct Player {
        \\    [Managed] void Update();
        \\    [Managed("get_Health")] f32 health();
        \\    [Managed] static Player* s_main;
        \\}
        \\struct Spawner { [Managed] void Spawn(); }
        \\[Icall("UnityEngine.Time::get_deltaTime")] f32 deltaTime();
    }});
    defer good.destroy();
    good.setHome("kai");
    const s = good.schema();
    const update = managedOf(s.findFunction("Kai.Player.Update").?.method.annotations, s.findFunction("Kai.Player.Update").?.owner, "Update", good.options.file_namespaces).?;
    try testing.expectEqualStrings("Game.Player", update.class);
    try testing.expectEqualStrings("Update", update.member);
    try testing.expectEqualStrings("get_Health", managedOf(s.findFunction("Kai.Player.health").?.method.annotations, s.findFunction("Kai.Player.health").?.owner, "health", good.options.file_namespaces).?.member);
    // No [Managed] on the struct means it's named like the C# class
    try testing.expectEqualStrings("Spawner", managedOf(s.findFunction("Kai.Spawner.Spawn").?.method.annotations, s.findFunction("Kai.Spawner.Spawn").?.owner, "Spawn", good.options.file_namespaces).?.class);
    const delta = managedOf(s.findFunction("Kai.deltaTime").?.method.annotations, null, "deltaTime", good.options.file_namespaces).?;
    try testing.expectEqualStrings("UnityEngine.Time", delta.class);
    try testing.expectEqualStrings("get_deltaTime", delta.member);
    try testing.expect(delta.icall);
    // Not running here. A method's function exists anyway and finds the C# on first call. An engine
    // call's doesn't, and a miss isn't kept
    try testing.expect(try good.address("Player.Update") != 0);
    try testing.expectError(error.NotFound, good.address("deltaTime"));
    try testing.expectEqual(1, good.found.count());
}
