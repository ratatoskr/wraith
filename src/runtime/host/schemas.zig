//! A plugin's schemas: Wraith's, those of plugins it depends on and its own `schemas` folder, as one.
//! What they say about the game, like `[Sig("..")] i32 spawn(u32 kind);`, is found by name the first
//! time it's asked for, then kept. Plugins without schemas share one of Wraith's alone.

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");
const mem = @import("tuft_mem");
const sigs = @import("tuft_schema").sigs;
const sync = @import("tuft_sys").sync;
const salamander_schema = @import("salamander_schema");
const bind = @import("salamander_bind");

const Loaded = @import("../PluginLoader.zig").Loaded;

const SalSchema = salamander_schema.Schema;
const sal = api.salamander;
const log = core.log.scoped(.wraith_runtime);
const allocator = std.heap.page_allocator;

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
    lock: sync.RwLock = .{},
    found: std.StringHashMapUnmanaged(usize) = .empty,
    typed: std.StringHashMapUnmanaged(Typed) = .empty,

    pub fn schema(self: *const Schemas) SalSchema {
        return self.parsed.schema;
    }

    /// Takes `text` and `files` if it works. What's wrong goes in `diag`.
    fn create(text: []u8, files: []File, diag: *SalSchema.Diagnostic) error{ OutOfMemory, InvalidSchema }!*Schemas {
        var parsed = try salamander_schema.parse(allocator, text, api.sal_options, diag);
        errdefer parsed.deinit();
        try checkAnnotations(parsed.schema, parsed.source, diag);
        const self = try allocator.create(Schemas);
        self.* = .{ .text = text, .parsed = parsed, .files = files };
        return self;
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
        allocator.free(self.text);
        allocator.destroy(self);
    }

    /// `text`, like `[Thiscall] fn i32 (usize self, f32 amount)` or a declared name like `Player.heal`,
    /// with these types in scope. Says what's wrong with it if it can't be used.
    pub fn typedOf(self: *Schemas, text: []const u8) error{ InvalidSignature, OutOfMemory }!Typed {
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            if (self.typed.get(text)) |found| return found;
        }
        var diag: SalSchema.Diagnostic = .{};
        var parsed = salamander_schema.parseSignature(allocator, self.text, text, api.sal_options, &diag) catch |err| return switch (err) {
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

    /// Where a function, method or static is, or a struct's vtable. Kept once found.
    pub fn address(self: *Schemas, name: []const u8) Error!usize {
        {
            self.lock.lockShared();
            defer self.lock.unlockShared();
            if (self.found.get(name)) |a| return a;
        }
        const s = self.schema();
        const a = if (s.findStatic(name)) |v|
            try locate(v.static.annotations, "Sig", name)
        else if (s.findFunction(name)) |f| blk: {
            if (f.method.virtual) |_| break :blk try readSlot(try self.slot(name));
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
    pub fn slot(self: *Schemas, name: []const u8) Error!usize {
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
    pub fn method(self: *Schemas, object: usize, name: []const u8) Error!usize {
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

fn readSlot(at: usize) Schemas.Error!usize {
    var value: usize = 0;
    mem.Memory.local.read(at, std.mem.asBytes(&value)) catch return sal.host().explain(error.NotFound, "can't read 0x{x}", .{at});
    if (value == 0) return sal.host().explain(error.NotFound, "0x{x} is null", .{at});
    return value;
}

/// Runs the `[Sig]` or `[VirtualTable]` in `annotations`, with any `[Module]` and `[Section]` next to it.
fn locate(annotations: []const SalSchema.Annotation, which: []const u8, name: []const u8) Schemas.Error!usize {
    var steps: [sigs.max_steps]mem.Sig.Step = undefined;
    const sig = (sigs.of(annotations, "wraith", which, &steps) catch unreachable) orelse return sal.host().explain(error.NotFound, "{s} has no [{s}]", .{ name, which });
    const found = sig.locate(name).unwrap() catch |err| return sal.host().explain(error.NotFound, "{s}'s [{s}(\"{s}\")] wasn't found: {t}", .{ name, which, sig.pattern, err });
    return found;
}

/// So a `[Sig]` that can't mean anything fails as the plugin loads, saying where.
fn checkAnnotations(s: SalSchema, source: []const u8, diag: *SalSchema.Diagnostic) error{InvalidSchema}!void {
    for (s.types) |*t| {
        if (SalSchema.findAnnotation(t.annotations, "wraith", "Service")) |a| return diag.fail(source, a.at, "[Service] goes on a trait, and {s} isn't one", .{t.name});
        try checkOne(t.annotations, "VirtualTable", source, diag);
        const st = switch (t.kind) {
            .@"struct" => |st| st,
            else => continue,
        };
        for (st.methods) |m| try checkOne(m.annotations, "Sig", source, diag);
        for (st.statics) |v| try checkOne(v.annotations, "Sig", source, diag);
    }
    for (s.functions) |f| try checkOne(f.annotations, "Sig", source, diag);
    for (s.statics) |v| try checkOne(v.annotations, "Sig", source, diag);
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
    try readFolder(io, name, dir, &files);
    if (files.items.len == 0) return null;
    var diag: SalSchema.Diagnostic = .{};
    return fromFilesWhy(files.items, &diag) catch |err| {
        if (err == error.InvalidSchema) log.err("{s}", .{diag.message()});
        return err;
    };
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

/// A plugin's schemas with `text` as its file `name`, in place of one by that name, like a tweak's
/// types. The ones before stay till it's unloaded, since what they found is still in use.
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
    loaded.schemas = made;
    @import("shared_schemas.zig").publish(loaded);
}

pub const SchemaError = error{ OutOfMemory, Invalid };

fn readFolder(io: std.Io, name: []const u8, dir_path: []const u8, files: *std.ArrayList(File)) !void {
    const path = try std.fs.path.join(allocator, &.{ dir_path, "schemas" });
    defer allocator.free(path);
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    var walker = try dir.walk(allocator);
    defer walker.deinit(io);
    const start = files.items.len;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".sal")) continue;
        try files.ensureUnusedCapacity(allocator, 1);
        const text = try dir.readFileAlloc(io, entry.path, allocator, .limited(max_file));
        errdefer allocator.free(text);
        const file_name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ name, entry.path });
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
        return s.address(name);
    }

    pub fn method(loaded: *Loaded, object: usize, name: []const u8) sal.Plain(Area, "method") {
        const s = of(loaded) catch return error.Unknown;
        return s.method(object, name);
    }
};
