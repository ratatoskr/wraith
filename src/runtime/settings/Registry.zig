//! Settings that Wraith, plugins and tweaks register, saved per scope; keybinds are key settings. Any thread.

const Registry = @This();

const std = @import("std");

const core = @import("wraith_core");
const tuft_sys = @import("tuft_sys");
const tuft_input = @import("tuft_input");
const Chord = tuft_input.Chord;
const Keys = tuft_input.Keys;
const Keybinds = tuft_input.Keybinds;

const log = core.log.scoped(.wraith_runtime);

pub const Scope = enum { global, game };

/// What sort of setting, shared by Kind and Value.
pub const Type = enum { toggle, number, choice, text, colour, key, path };

pub const Kind = union(Type) {
    toggle: bool,
    number: Number,
    choice: Choice,
    text: []const u8,
    colour: [4]f32,
    key: Key,
    path: Path,
};

pub const Number = struct {
    default: f64,
    min: f64,
    max: f64,
    /// 1 or more makes it whole steps. 0 is any.
    step: f64 = 0,
};

pub const Choice = struct {
    default: []const u8,
    options: []const []const u8,
};

/// A folder or file, picked with Windows' own dialog or typed. Empty means its `placeholder`.
pub const Path = struct {
    default: []const u8 = "",
    /// A file, not a folder.
    file: bool = false,
    /// The file type it picks, like ".json".
    extension: []const u8 = "",
    /// What it uses while it's empty, like `Pictures\Wraith`.
    placeholder: []const u8 = "",
};

pub const Key = struct {
    /// Null starts without one.
    default: ?Keys,
    /// Bound on the game's keys. Off for keys used only inside Wraith's own windows.
    in_game: bool = true,
    /// Hide the key from the game.
    consume: bool = true,
    /// Works while typing in a text box too.
    while_typing: bool = false,
    /// Held, like a key to move with: it works with any modifiers down and can be one, like Shift.
    held: bool = false,
};

pub const Value = union(Type) {
    toggle: bool,
    number: f64,
    choice: []const u8,
    text: []const u8,
    colour: [4]f32,
    /// Null is no key. Any of them does it.
    key: ?Keys,
    path: []const u8,

    pub fn eql(a: Value, b: Value) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .choice => |s| std.mem.eql(u8, s, b.choice),
            .text => |s| std.mem.eql(u8, s, b.text),
            .path => |s| std.mem.eql(u8, s, b.path),
            .key => |k| if (k) |x| (if (b.key) |y| x.eql(y) else false) else b.key == null,
            else => std.meta.eql(a, b),
        };
    }
};

pub const Definition = struct {
    /// Unique, like `wraith.overlay` or `<plugin>.<name>`.
    id: []const u8,
    name: []const u8,
    help: []const u8 = "",
    /// Who it's listed under, like "Wraith" or a plugin's name.
    group: []const u8,
    /// A heading in the group, like "Look & Feel". Can be empty.
    section: []const u8 = "",
    /// A subheading, like "Free camera keys". Add settings sharing one together.
    heading: []const u8 = "",
    scope: Scope = .global,
    kind: Kind,
    /// Saving it only takes effect next time the game starts.
    restart: bool = false,
    /// Kept, but not listed in Settings, like whether the welcome's been seen.
    hidden: bool = false,

    /// Who it's for and what it is, like `Tweaks: Speed: On and off`, for saying which.
    pub fn describe(self: *const Definition, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}: ", .{self.group});
        if (self.section.len > 0) try w.print("{s}: ", .{self.section});
        if (self.heading.len > 0) try w.print("{s}: ", .{self.heading});
        try w.writeAll(self.name);
    }
};

/// A key setting's action. On the render thread.
pub const KeyAction = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, phase: Keybinds.Phase) void,
};

/// After its value changes, on the thread that changed it.
pub const Changed = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, setting: *Setting) void,
};

pub const Hooks = struct {
    key: ?KeyAction = null,
    changed: ?Changed = null,
};

pub const Setting = struct {
    def: Definition,
    /// Under the registry's lock.
    value: Value,
    hooks: Hooks,
    /// Key settings with a key, once bound.
    binding: ?*Keybinds.Binding = null,
    /// Overrides its key's `consume` while it's set, see `setConsume`. 0 leaves it, 1 is off, 2 on.
    consume_now: std.atomic.Value(u8) = .init(0),
    /// Taken out, but kept till the registry goes so nobody holding it reads freed memory.
    removed: bool = false,
    /// Its change hook running, which `remove` waits for.
    calls: std.atomic.Value(u32) = .init(0),

    fn fire(self: *Setting, phase: Keybinds.Phase) void {
        const action = self.hooks.key orelse return;
        action.call(action.ctx, phase);
    }
};

pub const Options = struct {
    /// Without it nothing's saved, like in tests.
    io: ?std.Io = null,
    global_path: ?[]const u8 = null,
    game_path: ?[]const u8 = null,
    /// Key settings bind here. Without it they keep their values but do nothing.
    keybinds: ?*Keybinds = null,
};

/// What's saved: only settings changed from their default.
const Stored = struct {
    values: []const Entry = &.{},
};

const Entry = struct {
    id: []const u8,
    value: Value,
};

const File = core.config.Lifecycle(Stored);

const Store = struct {
    config: ?*core.Config(Stored) = null,
    /// Owned keys. Kept for settings that aren't registered right now too.
    values: std.StringArrayHashMapUnmanaged(Value) = .empty,
    /// What `config` points at, rebuilt for each save.
    entries: []Entry = &.{},
    /// Changed without saving, mid-drag.
    unsaved: bool = false,
};

allocator: std.mem.Allocator,
keybinds: ?*Keybinds,
lock: tuft_sys.sync.RwLock = .{},
settings: std.ArrayList(*Setting) = .empty,
/// Removed ones, freed with the registry.
retired: std.ArrayList(*Setting) = .empty,
stores: [2]Store = .{ .{}, .{} },
/// Strings stay till the registry goes, so a value handed out is never freed under its reader.
strings: std.ArrayList([]const u8) = .empty,
option_lists: std.ArrayList([]const []const u8) = .empty,
/// Goes up whenever a setting comes, goes or changes, so a UI knows to look again.
changes: std.atomic.Value(u32) = .init(0),

/// Change hooks running on this thread, which removing can't wait for.
threadlocal var in_hook: u32 = 0;

pub fn create(allocator: std.mem.Allocator, options: Options) !*Registry {
    const self = try allocator.create(Registry);
    errdefer allocator.destroy(self);
    self.* = .{ .allocator = allocator, .keybinds = options.keybinds };
    errdefer {
        for (&self.stores) |*store| if (store.config) |cfg| File.discard(cfg);
        self.freeAll();
    }
    if (options.io) |io| {
        for ([_]?[]const u8{ options.global_path, options.game_path }, &self.stores) |path, *store| {
            const p = path orelse continue;
            store.config = try File.open(allocator, io, p);
            for (store.config.?.value.values) |e| try self.keep(store, e.id, e.value);
        }
    }
    return self;
}

/// Everything added should be removed first.
pub fn destroy(self: *Registry) void {
    if (self.settings.items.len != 0) log.warn("{d} setting(s) still registered at shutdown", .{self.settings.items.len});
    while (self.settings.pop()) |s| {
        if (s.binding) |b| b.unbind();
        self.allocator.destroy(s);
    }
    for (self.retired.items) |s| self.allocator.destroy(s);
    self.retired.deinit(self.allocator);
    for (&self.stores) |*store| if (store.config) |cfg| {
        self.fillEntries(store) catch {};
        File.close(cfg);
        store.config = null;
    };
    self.freeAll();
    self.allocator.destroy(self);
}

/// Starts with what was saved for it, if it's the same kind, else its default.
pub fn add(self: *Registry, def: Definition, hooks: Hooks) !*Setting {
    const s = try self.allocator.create(Setting);
    errdefer self.allocator.destroy(s);
    s.* = .{ .def = undefined, .value = undefined, .hooks = hooks };
    {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.settings.items) |other| if (std.mem.eql(u8, other.def.id, def.id)) return error.AlreadyAdded;
        s.def = try self.ownDefinition(def);
        const saved = self.stores[@backingInt(def.scope)].values.get(def.id);
        s.value = if (saved) |v| (if (valid(s.def.kind, v)) v else defaultOf(s.def.kind)) else defaultOf(s.def.kind);
        try self.settings.append(self.allocator, s);
    }
    self.bindKey(s);
    _ = self.changes.fetchAdd(1, .release);
    return s;
}

/// Saved value stays. Waits for running hooks elsewhere, so their context can go once this returns.
pub fn remove(self: *Registry, s: *Setting) void {
    const kept = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.settings.items, 0..) |other, i| if (other == s) {
            _ = self.settings.orderedRemove(i);
            break;
        };
        s.removed = true;
        // Can't fail it, so a full list just frees it once it's done
        self.retired.append(self.allocator, s) catch break :blk false;
        break :blk true;
    };
    if (s.binding) |b| b.unbind();
    s.binding = null;
    // A hook from this thread is the caller's own, which can't be waited for
    while (s.calls.load(.acquire) != 0 and in_hook == 0) std.Thread.yield() catch {};
    if (!kept) self.allocator.destroy(s);
    _ = self.changes.fetchAdd(1, .release);
}

/// What's registered now, in order. They stay readable till the registry goes, even if removed.
pub fn list(self: *Registry, allocator: std.mem.Allocator) ![]*Setting {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return allocator.dupe(*Setting, self.settings.items);
}

/// Rebinds every key setting, or unbinds with null. Not while settings are being added or removed.
pub fn setKeybinds(self: *Registry, keybinds: ?*Keybinds) void {
    for (self.settings.items) |s| if (s.binding) |b| {
        b.unbind();
        s.binding = null;
    };
    self.keybinds = keybinds;
    for (self.settings.items) |s| self.bindKey(s);
}

pub fn find(self: *Registry, id: []const u8) ?*Setting {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    for (self.settings.items) |s| if (std.mem.eql(u8, s.def.id, id)) return s;
    return null;
}

/// Whether `group`, like a plugin's title, has settings or keys Settings lists.
pub fn listsAny(self: *Registry, group: []const u8) bool {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    for (self.settings.items) |s| {
        if (!s.def.hidden and std.mem.eql(u8, s.def.group, group)) return true;
    }
    return false;
}

/// Strings in it last as long as the registry.
pub fn get(self: *Registry, s: *const Setting) Value {
    self.lock.lockShared();
    defer self.lock.unlockShared();
    return s.value;
}

/// Saved on a worker. Numbers get clamped; a key that can't be bound is refused.
pub fn set(self: *Registry, s: *Setting, wanted: Value) !void {
    return self.setWith(s, wanted, .{});
}

pub const SetOptions = struct {
    /// Off for every frame of a drag. The next saved set writes it too, even one that changes nothing.
    save: bool = true,
};

pub fn setWith(self: *Registry, s: *Setting, wanted: Value, options: SetOptions) !void {
    if (!fits(s.def.kind, wanted)) return error.WrongKind;
    var v = wanted;
    switch (s.def.kind) {
        .number => |n| {
            var x = std.math.clamp(v.number, n.min, n.max);
            if (n.step >= 1) x = @round(x / n.step) * n.step;
            v.number = x;
        },
        .choice => |ch| for (ch.options) |o| {
            if (std.mem.eql(u8, o, v.choice)) break;
        } else return error.NotAnOption,
        .key => |k| if (v.key) |keys| if (!keys.isValid(k.held)) return error.InvalidChord,
        else => {},
    }
    const hook = blk: {
        self.lock.lock();
        defer self.lock.unlock();
        if (s.removed) return error.Removed;
        const store = &self.stores[@backingInt(s.def.scope)];
        if (s.value.eql(v)) {
            if (options.save and store.unsaved) self.save(store) catch |err| log.warn("Couldn't save {s}: {t}", .{ s.def.id, err });
            return;
        }
        const owned = try self.ownValue(v);
        if (owned.eql(defaultOf(s.def.kind))) {
            if (store.values.fetchSwapRemove(s.def.id)) |gone| self.allocator.free(gone.key);
        } else try self.keep(store, s.def.id, owned);
        s.value = owned;
        if (options.save) {
            self.save(store) catch |err| log.warn("Couldn't save {s}: {t}", .{ s.def.id, err });
        } else store.unsaved = true;
        // Counted under the lock, so `remove` sees it
        if (s.hooks.changed != null) _ = s.calls.fetchAdd(1, .acq_rel);
        break :blk s.hooks.changed;
    };
    self.bindKey(s);
    _ = self.changes.fetchAdd(1, .release);
    if (hook) |c| {
        in_hook += 1;
        defer in_hook -= 1;
        defer _ = s.calls.fetchSub(1, .acq_rel);
        c.call(c.ctx, s);
    }
}

/// Back to its default, which forgets the saved value.
pub fn reset(self: *Registry, s: *Setting) !void {
    try self.set(s, defaultOf(s.def.kind));
}

/// Moves what's saved under `from` to `to`, unless `to` has one. Call it before `to` is added.
pub fn rename(self: *Registry, scope: Scope, from: []const u8, to: []const u8) !void {
    self.lock.lock();
    defer self.lock.unlock();
    const store = &self.stores[@backingInt(scope)];
    if (store.values.contains(to)) return;
    const v = store.values.get(from) orelse return;
    try self.keep(store, to, v);
    if (store.values.fetchSwapRemove(from)) |gone| self.allocator.free(gone.key);
    try self.save(store);
}

pub fn isDefault(self: *Registry, s: *const Setting) bool {
    return self.get(s).eql(defaultOf(s.def.kind));
}

pub fn defaultOf(kind: Kind) Value {
    return switch (kind) {
        .toggle => |b| .{ .toggle = b },
        .number => |n| .{ .number = n.default },
        .choice => |ch| .{ .choice = ch.default },
        .text => |t| .{ .text = t },
        .colour => |c| .{ .colour = c },
        .key => |k| .{ .key = k.default },
        .path => |p| .{ .path = p.default },
    };
}

fn fits(kind: Kind, v: Value) bool {
    return std.meta.activeTag(kind) == std.meta.activeTag(v);
}

/// The right kind, and one of the options if it's a choice, since those can change.
fn valid(kind: Kind, v: Value) bool {
    if (!fits(kind, v)) return false;
    return switch (kind) {
        .choice => |ch| for (ch.options) |o| {
            if (std.mem.eql(u8, o, v.choice)) break true;
        } else false,
        else => true,
    };
}

/// To whatever it's set to now. Outside the lock, since unbinding waits for callbacks.
fn bindKey(self: *Registry, s: *Setting) void {
    const keybinds = self.keybinds orelse return;
    const key = switch (s.def.kind) {
        .key => |k| k,
        else => return,
    };
    if (!key.in_game) return;
    const keys = self.get(s).key;
    if (s.binding) |b| {
        if (keys) |c| {
            b.rebind(c) catch |err| log.warn("Couldn't rebind {s}: {t}", .{ s.def.id, err });
            return;
        }
        b.unbind();
        s.binding = null;
        return;
    }
    const c = keys orelse return;
    // Named in full, like `Mira: set 999999`, since keys are listed without their headings
    var name_buf: [256]u8 = undefined;
    const name = if (s.def.section.len > 0) std.fmt.bufPrint(&name_buf, "{s}: {s}", .{ s.def.section, s.def.name }) catch s.def.name else s.def.name;
    s.binding = keybinds.bindUnscoped(.{ .id = s.def.id, .name = name, .keys = c, .consume = consumes(s, key), .while_typing = key.while_typing, .held = key.held }, s, Setting.fire) catch |err| blk: {
        log.warn("Couldn't bind {f} for {s}: {t}", .{ c.first(), s.def.id, err });
        break :blk null;
    };
}

fn consumes(s: *const Setting, key: anytype) bool {
    return switch (s.consume_now.load(.acquire)) {
        1 => false,
        2 => true,
        else => key.consume,
    };
}

/// Overrides whether a key setting hides its key from the game; null restores it. Any thread.
pub fn setConsume(self: *Registry, s: *Setting, on: ?bool) void {
    _ = self;
    s.consume_now.store(if (on) |o| (if (o) 2 else 1) else 0, .release);
    const key = switch (s.def.kind) {
        .key => |k| k,
        else => return,
    };
    if (s.binding) |b| b.setConsume(consumes(s, key));
}

/// Under the lock, or before anyone else has it.
fn keep(self: *Registry, store: *Store, id: []const u8, v: Value) !void {
    const owned = try self.ownValue(v);
    const entry = try store.values.getOrPut(self.allocator, id);
    if (!entry.found_existing) entry.key_ptr.* = self.allocator.dupe(u8, id) catch |err| {
        store.values.swapRemoveAt(entry.index);
        return err;
    };
    entry.value_ptr.* = owned;
}

/// Under the lock. Writes on a worker.
fn save(self: *Registry, store: *Store) !void {
    const cfg = store.config orelse return;
    try self.fillEntries(store);
    try cfg.save();
    store.unsaved = false;
}

fn fillEntries(self: *Registry, store: *Store) !void {
    const cfg = store.config orelse return;
    const entries = try self.allocator.alloc(Entry, store.values.count());
    for (entries, store.values.keys(), store.values.values()) |*e, id, v| e.* = .{ .id = id, .value = v };
    self.allocator.free(store.entries);
    store.entries = entries;
    cfg.value.values = entries;
}

fn ownValue(self: *Registry, v: Value) !Value {
    return switch (v) {
        .choice => |s| .{ .choice = try self.ownString(s) },
        .text => |s| .{ .text = try self.ownString(s) },
        .path => |s| .{ .path = try self.ownString(s) },
        else => v,
    };
}

fn ownString(self: *Registry, s: []const u8) ![]const u8 {
    const copy = try self.allocator.dupe(u8, s);
    errdefer self.allocator.free(copy);
    try self.strings.append(self.allocator, copy);
    return copy;
}

fn ownDefinition(self: *Registry, def: Definition) !Definition {
    var d = def;
    d.id = try self.ownString(def.id);
    d.name = try self.ownString(def.name);
    d.help = try self.ownString(def.help);
    d.group = try self.ownString(def.group);
    d.section = try self.ownString(def.section);
    d.heading = try self.ownString(def.heading);
    switch (def.kind) {
        .choice => |ch| {
            const options = try self.allocator.alloc([]const u8, ch.options.len);
            self.option_lists.append(self.allocator, options) catch |err| {
                self.allocator.free(options);
                return err;
            };
            for (options, ch.options) |*o, src| o.* = try self.ownString(src);
            d.kind = .{ .choice = .{ .default = try self.ownString(ch.default), .options = options } };
        },
        .text => |t| d.kind = .{ .text = try self.ownString(t) },
        .path => |p| d.kind = .{ .path = .{
            .default = try self.ownString(p.default),
            .file = p.file,
            .extension = try self.ownString(p.extension),
            .placeholder = try self.ownString(p.placeholder),
        } },
        else => {},
    }
    return d;
}

fn freeAll(self: *Registry) void {
    for (&self.stores) |*store| {
        for (store.values.keys()) |k| self.allocator.free(k);
        store.values.deinit(self.allocator);
        self.allocator.free(store.entries);
    }
    for (self.strings.items) |s| self.allocator.free(s);
    self.strings.deinit(self.allocator);
    for (self.option_lists.items) |o| self.allocator.free(o);
    self.option_lists.deinit(self.allocator);
    self.settings.deinit(self.allocator);
}

const tests = struct {
    const testing = std.testing;

    test "values, defaults and kinds" {
        const r = try Registry.create(testing.allocator, .{});
        defer r.destroy();
        const fov = try r.add(.{ .id = "kai.fov", .name = "Field of view", .group = "Kai", .kind = .{ .number = .{ .default = 90, .min = 60, .max = 120, .step = 1 } } }, .{});
        defer r.remove(fov);
        try testing.expectEqual(90, r.get(fov).number);
        try testing.expect(r.isDefault(fov));
        try r.set(fov, .{ .number = 200.4 });
        try testing.expectEqual(120, r.get(fov).number);
        try testing.expect(!r.isDefault(fov));
        try testing.expectError(error.WrongKind, r.set(fov, .{ .toggle = true }));
        try r.reset(fov);
        try testing.expect(r.isDefault(fov));
        try testing.expectError(error.AlreadyAdded, r.add(.{ .id = "kai.fov", .name = "Again", .group = "Kai", .kind = .{ .toggle = false } }, .{}));

        const mode = try r.add(.{ .id = "kai.mode", .name = "Mode", .group = "Kai", .kind = .{ .choice = .{ .default = "fast", .options = &.{ "fast", "slow" } } } }, .{});
        defer r.remove(mode);
        try testing.expectError(error.NotAnOption, r.set(mode, .{ .choice = "medium" }));
        try r.set(mode, .{ .choice = "slow" });
        try testing.expectEqualStrings("slow", r.get(mode).choice);
        try testing.expectEqual(mode, r.find("kai.mode").?);
    }

    test "a key saved before lists came still loads" {
        const a = testing.allocator;
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        // Like an older Wraith wrote it, with one chord
        try tmp.dir.writeFile(io, .{ .sub_path = "game.zon", .data = ".{ .values = .{ .{ .id = \"kai.go\", .value = .{ .key = .{ .key = .f9, .mods = .{ .ctrl = true } } } } } }\n" });
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const game_path = try std.fs.path.join(a, &.{ root, "game.zon" });
        defer a.free(game_path);
        const r = try Registry.create(a, .{ .io = io, .game_path = game_path });
        defer r.destroy();
        const k = try r.add(.{ .id = "kai.go", .name = "Go", .group = "Kai", .scope = .game, .kind = .{ .key = .{ .default = .{ .key = .f8 } } } }, .{});
        defer r.remove(k);
        try testing.expect(r.get(k).key.?.eql(.one(.{ .key = .f9, .mods = .{ .ctrl = true } })));
    }

    test "a renamed setting keeps what was saved, unless the new one has its own" {
        const a = testing.allocator;
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "global.zon", .data = ".{ .values = .{ .{ .id = \"shot.folder\", .value = .{ .path = \"D:\\\\Shots\" } }, .{ .id = \"shot.exr\", .value = .{ .toggle = false } }, .{ .id = \"wraith.exr\", .value = .{ .toggle = true } } } }\n" });
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const global_path = try std.fs.path.join(a, &.{ root, "global.zon" });
        defer a.free(global_path);
        {
            const r = try Registry.create(a, .{ .io = io, .global_path = global_path });
            defer r.destroy();
            try r.rename(.global, "shot.folder", "wraith.folder");
            try r.rename(.global, "shot.exr", "wraith.exr");
            try r.rename(.global, "shot.nothing", "wraith.nothing");
            const folder = try r.add(.{ .id = "wraith.folder", .name = "Folder", .group = "Wraith", .kind = .{ .path = .{} } }, .{});
            defer r.remove(folder);
            try testing.expectEqualStrings("D:\\Shots", r.get(folder).path);
            try testing.expectEqual(null, r.stores[0].values.get("shot.folder"));
            try testing.expect(r.stores[0].values.get("wraith.exr").?.toggle);
            try testing.expectEqual(null, r.stores[0].values.get("wraith.nothing"));
        }
        const text = try tmp.dir.readFileAlloc(io, "global.zon", a, .limited(4096));
        defer a.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "wraith.folder") != null);
        try testing.expect(std.mem.indexOf(u8, text, "shot.folder") == null);
    }

    test "saved to its scope's file, and back next time" {
        const a = testing.allocator;
        const io = testing.io;
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const root = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(root);
        const global_path = try std.fs.path.join(a, &.{ root, "global.zon" });
        defer a.free(global_path);
        const game_path = try std.fs.path.join(a, &.{ root, "game.zon" });
        defer a.free(game_path);
        const options: Options = .{ .io = io, .global_path = global_path, .game_path = game_path };
        const theme: Definition = .{ .id = "wraith.theme", .name = "Theme", .group = "Wraith", .kind = .{ .text = "" } };
        const hold: Definition = .{ .id = "wraith.tweak.hold", .name = "Hold", .group = "Tweaks", .scope = .game, .kind = .{ .key = .{ .default = null } } };

        {
            const r = try Registry.create(a, options);
            defer r.destroy();
            const t = try r.add(theme, .{});
            defer r.remove(t);
            const k = try r.add(hold, .{});
            defer r.remove(k);
            try r.set(t, .{ .text = "Light" });
            try r.set(k, .{ .key = Keys.one(.{ .key = .f8 }).with(.{ .key = .gamepad_y }) });
            // One that's not registered now stays too
            try r.keep(&r.stores[0], "gone.plugin", .{ .toggle = true });
        }
        const global_text = try tmp.dir.readFileAlloc(io, "global.zon", a, .limited(4096));
        defer a.free(global_text);
        try testing.expect(std.mem.indexOf(u8, global_text, "Light") != null);
        try testing.expect(std.mem.indexOf(u8, global_text, "f8") == null);
        const game_text = try tmp.dir.readFileAlloc(io, "game.zon", a, .limited(4096));
        defer a.free(game_text);
        try testing.expect(std.mem.indexOf(u8, game_text, "f8") != null);

        const r = try Registry.create(a, options);
        defer r.destroy();
        const t = try r.add(theme, .{});
        defer r.remove(t);
        const k = try r.add(hold, .{});
        defer r.remove(k);
        try testing.expectEqualStrings("Light", r.get(t).text);
        try testing.expectEqual(.f8, r.get(k).key.?.key);
        try testing.expectEqual(.gamepad_y, r.get(k).key.?.get(1).?.key);
        try testing.expect(r.stores[0].values.get("gone.plugin").?.toggle);

        // Back to the default isn't saved
        try r.reset(t);
        try testing.expectEqual(null, r.stores[0].values.get("wraith.theme"));

        // A drag's last set saves it, though it changes nothing
        try r.setWith(t, .{ .text = "Dark" }, .{ .save = false });
        try testing.expect(r.stores[0].unsaved);
        try r.set(t, .{ .text = "Dark" });
        try testing.expect(!r.stores[0].unsaved);
    }

    test "key settings bind, follow their value and fire" {
        const Rig = @import("../testing/Rig.zig");
        const api = @import("wraith_platform").win.api;
        var rig: Rig = undefined;
        try rig.init(.{});
        defer rig.deinit();
        rig.present();
        const r = try Registry.create(testing.allocator, .{ .keybinds = rig.keybinds });
        defer r.destroy();

        const Counter = struct {
            presses: u32 = 0,
            fn call(ctx: *anyopaque, phase: Keybinds.Phase) void {
                const self: *@This() = @ptrCast(@alignCast(ctx));
                if (phase == .pressed) self.presses += 1;
            }
        };
        var counter: Counter = .{};
        const k = try r.add(.{ .id = "test.go", .name = "Go", .group = "Test", .kind = .{ .key = .{ .default = .{ .key = .f8 } } } }, .{ .key = .{ .ctx = &counter, .call = Counter.call } });
        defer r.remove(k);
        try testing.expectEqual(1, rig.keybinds.countPrefix("test.go"));

        try r.set(k, .{ .key = .{ .key = .f9 } });
        try testing.expectEqual(.f9, k.binding.?.keys.key);
        _ = rig.send(api.WM_KEYDOWN, 0x78, 1);
        _ = rig.send(api.WM_KEYUP, 0x78, @bitCast(@as(usize, 0xC000_0001)));
        rig.present();
        try testing.expectEqual(1, counter.presses);

        // No key unbinds it, and a modifier on its own can't be one
        try r.set(k, .{ .key = null });
        try testing.expectEqual(0, rig.keybinds.countPrefix("test.go"));
        try testing.expectError(error.InvalidChord, r.set(k, .{ .key = .{ .key = .left_shift } }));
        try r.reset(k);
        try testing.expectEqual(.f8, k.binding.?.keys.key);
    }
};

test {
    _ = tests;
}
