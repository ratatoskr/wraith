//! One Cheat Engine Auto Assembler script to a tweak's parts. It knows CE's templates, the
//! injection one and the patch one, plus data in `alloc`. Anything it isn't sure about comes back
//! for review instead of a guess.

const std = @import("std");

const script = @import("script.zig");
const numbers = @import("numbers.zig");
const machine = @import("machine.zig");
const lua = @import("lua.zig");

pub const Bits = machine.Bits;

pub const Status = enum {
    clean,
    /// Off, with the original kept, until someone looks.
    review,
    /// Lua, live under the CE layer.
    lua,
};

pub const Field = struct {
    name: []const u8,
    /// Like `u32` or `f32`.
    type: []const u8,
    value: []const u8,
    label: []const u8 = "",
    /// Like `Toggle` or `Choices("0:Off", "1:On")`.
    attrs: []const u8 = "",
};

pub const Sym = struct {
    name: []const u8,
    where: []const u8,
};

pub const Code = struct {
    kind: enum { patch, inject, bytes },
    where: []const u8,
    expect: []const u8 = "",
    /// Bytes a patch replaces, when there's nothing to expect.
    size: u32 = 0,
    lines: []const []const u8 = &.{},
};

/// `[ENABLE]` and `[DISABLE]`'s Lua.
pub const Lua = struct {
    on: []const u8,
    off: []const u8,
    /// Before both, like `local memrec = ...`.
    pre: []const u8 = "",
};

pub const Tweak = struct {
    status: Status = .clean,
    syms: []const Sym = &.{},
    fields: []Field = &.{},
    /// Where `@data` goes near, so x64 code can reach it.
    near: []const u8 = "",
    code: []const Code = &.{},
    /// A Lua tweak's whole script, or Lua next to the asm parts that run with it.
    lua: ?Lua = null,
    /// Short notes kept as comments in the tweak.
    comments: []const []const u8 = &.{},
    /// Why it needs a look. Empty when it's clean.
    problems: []const []const u8 = &.{},
    ambiguous: []const []const u8 = &.{},
    /// Names it uses that nothing defines.
    missing: []const []const u8 = &.{},
    /// Registered names that aren't data or a sym, so nothing else can use them now.
    unshared: []const []const u8 = &.{},
    /// `for` loops in its Lua that assign their variable, which got a copy for Lua 5.5.
    loops: u32 = 0,
    /// What changed from CE's behaviour, for the report.
    notes: []const []const u8 = &.{},

    /// The names others can use while it's on.
    pub fn publishes(self: Tweak, name: []const u8) bool {
        for (self.fields) |f| if (std.ascii.eqlIgnoreCase(f.name, name)) return true;
        for (self.syms) |s| if (std.ascii.eqlIgnoreCase(s.name, name)) return true;
        return false;
    }
};

pub const Env = struct {
    bits: Bits = .x64,
    main_module: ?[]const u8 = null,
    /// Names from elsewhere in the table, like other scripts' registered symbols.
    names: numbers.Names = .none,
};

/// Names CE scripts can't keep since ours mean something else by them.
const reserved = [_][]const u8{ "original", "resume", "data", "sym", "types", "tick", "off" };

/// What a script's own names are, the way it first spelled them.
pub fn localNames(arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    const s = try script.parse(arena, source);
    var out: std.ArrayList([]const u8) = .empty;
    for ([_]script.Section{ s.enable, s.disable }) |section| for (section.lines) |l| switch (l.statement) {
        .directive => |d| {
            const takes_all = std.mem.eql(u8, d.name, "label") or std.mem.eql(u8, d.name, "registersymbol");
            const first_only = std.mem.eql(u8, d.name, "alloc") or std.mem.eql(u8, d.name, "globalalloc") or
                std.mem.startsWith(u8, d.name, "aobscan");
            if (takes_all) {
                for (try script.names(arena, d.args)) |n| try out.append(arena, n);
            } else if (first_only and d.args.len > 0) {
                try out.append(arena, d.args[0]);
            }
        },
        else => {},
    };
    return out.items;
}

/// Registered names, the ones other scripts and records can use.
pub fn registeredNames(arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    const s = try script.parse(arena, source);
    var out: std.ArrayList([]const u8) = .empty;
    for (s.enable.lines) |l| switch (l.statement) {
        .directive => |d| {
            if (std.mem.eql(u8, d.name, "registersymbol")) {
                for (try script.names(arena, d.args)) |n| try out.append(arena, n);
            } else if (std.mem.eql(u8, d.name, "globalalloc") and d.args.len > 0) {
                try out.append(arena, d.args[0]);
            }
        },
        else => {},
    };
    return out.items;
}

pub fn convert(arena: std.mem.Allocator, gpa: std.mem.Allocator, source: []const u8, env: Env) !Tweak {
    const parsed = try script.parse(arena, source);
    // Lua that's only CE's syntax check is no Lua at all
    const lua_on = try script.withoutSyntaxCheck(arena, parsed.enable.lua);
    const lua_off = try script.withoutSyntaxCheck(arena, parsed.disable.lua);
    const has_lua = parsed.has_lua and (!parsed.has_asm or std.mem.trim(u8, lua_on, " \t\r\n").len > 0 or std.mem.trim(u8, lua_off, " \t\r\n").len > 0);
    if (!has_lua) return asmTweak(arena, gpa, parsed, env);
    if (!parsed.has_asm) return luaTweak(arena, parsed);
    // Lua that hands CE asm to assemble can't be told apart from what it'd make
    if (try lua.returnsValue(arena, lua_on) or try lua.returnsValue(arena, lua_off))
        return .{ .status = .review, .problems = try arena.dupe([]const u8, &.{"its Lua returns asm for CE to assemble, which a tweak can't do"}) };
    var t = try asmTweak(arena, gpa, parsed, env);
    if (t.status != .clean) return t;
    const on, const on_loops = try lua.fixLoops(arena, lua_on);
    const off, const off_loops = try lua.fixLoops(arena, lua_off);
    t.lua = .{ .on = on, .off = off };
    t.loops = on_loops + off_loops;
    return t;
}

fn asmTweak(arena: std.mem.Allocator, gpa: std.mem.Allocator, parsed: script.Script, env: Env) !Tweak {
    var c: Converter = .{ .arena = arena, .gpa = gpa, .env = env };
    if (parsed.has_c) return c.review("it has {$c} code, which there's no way to bring over");
    // Some are empty, just to switch their children on
    if (!parsed.has_asm) return .{ .comments = try arena.dupe([]const u8, &.{"it was empty in Cheat Engine"}) };
    if (parsed.has_try) try c.comment("it had {$try}, and its {$except} part is gone");
    c.run(parsed) catch |err| switch (err) {
        error.Review => return c.reviewed(),
        else => return err,
    };
    return c.finish();
}

fn luaTweak(arena: std.mem.Allocator, parsed: script.Script) !Tweak {
    const on, const on_loops = try lua.fixLoops(arena, try script.withoutSyntaxCheck(arena, parsed.enable.lua));
    const off, const off_loops = try lua.fixLoops(arena, try script.withoutSyntaxCheck(arena, parsed.disable.lua));
    return .{ .status = .lua, .lua = .{ .on = on, .off = off }, .loops = on_loops + off_loops };
}

const Item = union(enum) {
    label: []const u8,
    code: []const u8,
    /// `readmem(where, size)`, a copy of the bytes there.
    readmem: struct { where: []const u8, size: u32 },
    /// `reassemble(where)`, a copy of the instruction there.
    reassemble: []const u8,
};

const Region = struct {
    kind: enum { alloc, site },
    /// The alloc's name, or the site's address in CE's text.
    name: []const u8,
    items: std.ArrayList(Item) = .empty,
    used: bool = false,
};

const Restore = struct {
    key: []const u8,
    items: std.ArrayList([]const u8) = .empty,
};

/// What a site had before, from `[DISABLE]`.
const Original = struct {
    bytes: ?[]const u8 = null,
    /// Ours, one instruction each.
    instructions: ?[]const []const u8 = null,
    /// Some of it depends on where it is, like a jump.
    relative: bool = false,
    /// How many bytes, when that's all we know, from a `readmem`.
    size: u32 = 0,
};

const Segment = struct {
    label: ?[]const u8,
    items: []const Item,
};

const Converter = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    env: Env,
    defines: std.ArrayList([2][]const u8) = .empty,
    aobs: std.ArrayList(Sym) = .empty,
    /// Registered `define`s, which are `@sym`s now.
    defined: std.ArrayList(Sym) = .empty,
    /// The site being worked on, for a `readmem` of it.
    here: ?struct { where: []const u8, original: Original } = null,
    /// Each of `aobs`' byte patterns, ours.
    patterns: std.ArrayList([]const u8) = .empty,
    allocs: std.ArrayList([]const u8) = .empty,
    /// Each of `allocs`' sizes.
    alloc_sizes: std.ArrayList(u64) = .empty,
    labels: std.ArrayList([]const u8) = .empty,
    registered: std.ArrayList([]const u8) = .empty,
    asserts: std.ArrayList([2][]const u8) = .empty,
    regions: std.ArrayList(Region) = .empty,
    restores: std.ArrayList(Restore) = .empty,
    notes: numbers.Notes = .{},
    problems: std.ArrayList([]const u8) = .empty,
    comments: std.ArrayList([]const u8) = .empty,
    /// For the report, see `Tweak.notes`.
    told: std.ArrayList([]const u8) = .empty,
    fields: std.ArrayList(Field) = .empty,
    code: std.ArrayList(Code) = .empty,

    fn fail(self: *Converter, comptime format: []const u8, args: anytype) error{ Review, OutOfMemory } {
        try self.problems.append(self.arena, try std.fmt.allocPrint(self.arena, format, args));
        return error.Review;
    }

    fn review(self: *Converter, why: []const u8) !Tweak {
        try self.problems.append(self.arena, why);
        return self.reviewed();
    }

    fn reviewed(self: *Converter) Tweak {
        return .{ .status = .review, .problems = self.problems.items, .comments = self.comments.items, .ambiguous = self.notes.ambiguous.items };
    }

    fn comment(self: *Converter, text: []const u8) !void {
        try self.comments.append(self.arena, text);
    }

    fn run(self: *Converter, parsed: script.Script) !void {
        for ([_]script.Section{ parsed.enable, parsed.disable }) |section| for (section.lines) |l| switch (l.statement) {
            .directive => |d| if (std.mem.eql(u8, d.name, "define")) {
                if (d.args.len != 2) return self.fail("line {d} has a define without a name and value", .{l.number});
                if (self.define(d.args[0]) == null) try self.defines.append(self.arena, .{ d.args[0], d.args[1] });
            },
            else => {},
        };
        // Declarations first, since CE takes them anywhere
        for (parsed.enable.lines) |l| switch (l.statement) {
            .directive => |d| if (!inCode(d.name)) try self.directive(d, l.number),
            else => {},
        };
        try self.implicitLabels(parsed.enable.lines);
        for (parsed.enable.lines) |l| try self.enableLine(l);
        try self.anonymousLabels();
        try self.splitBlocks();
        var restore: ?*Restore = null;
        for (parsed.disable.lines) |l| switch (l.statement) {
            .directive => |d| {
                if (std.mem.eql(u8, d.name, "readmem")) {
                    const r = restore orelse return self.fail("its [DISABLE] reads memory at line {d} without saying where to", .{l.number});
                    const size = if (d.args.len == 2) numbers.parse(try self.subst(d.args[1])) else null;
                    if (size == null or size.? <= 0 or size.? > 64) return self.fail("line {d}'s readmem size is odd", .{l.number});
                    try r.items.append(self.arena, try std.fmt.allocPrint(self.arena, "readmem {d}", .{size.?}));
                    continue;
                }
                const ok = [_][]const u8{ "dealloc", "unregistersymbol", "define", "label", "alloc", "registersymbol", "aobscanmodule", "aobscan", "fullaccess" };
                for (ok) |name| {
                    if (std.mem.eql(u8, d.name, name)) break;
                } else return self.fail("its [DISABLE] does {s}(), which only CE knows how to undo", .{d.name});
            },
            .place => |p| {
                const key = try self.placeKey(p);
                restore = for (self.restores.items) |*r| {
                    if (std.mem.eql(u8, r.key, key)) break r;
                } else blk: {
                    try self.restores.append(self.arena, .{ .key = key });
                    break :blk &self.restores.items[self.restores.items.len - 1];
                };
            },
            .code => |text| {
                const r = restore orelse return self.fail("its [DISABLE] writes code at line {d} without saying where", .{l.number});
                try r.items.append(self.arena, try self.subst(text));
            },
        };

        // Space that's never written to, used by name
        for (self.allocs.items, self.alloc_sizes.items) |name, size| {
            const placed = for (self.regions.items) |r| {
                if (r.kind == .alloc and std.mem.eql(u8, r.name, name)) break true;
            } else false;
            if (placed) continue;
            const ty: []const u8 = switch (size) {
                1 => "u8",
                2 => "u16",
                4 => "u32",
                8 => "u64",
                else => return self.fail("{s} is {d} bytes of space, which a @data field can't be", .{ name, size }),
            };
            try self.fields.append(self.arena, .{ .name = name, .type = ty, .value = "0" });
        }
        // Data first, so code can use it by name
        for (self.regions.items) |*r| if (r.kind == .alloc and isAllData(r.items.items)) {
            r.used = true;
            try self.dataOnly(r);
        };
        for (self.regions.items) |*r| if (r.kind == .site) try self.site(r);
        for (self.regions.items) |*r| if (r.kind == .alloc and !r.used) try self.dataOnly(r);
        for (self.restores.items) |r| {
            const matched = for (self.regions.items) |reg| {
                if (std.mem.eql(u8, try self.placeKey(reg.name), r.key)) break true;
            } else false;
            const ours = self.isLocal(r.key) != null;
            if (!matched and !ours) return self.fail("its [DISABLE] writes to {s}, which [ENABLE] didn't touch", .{r.key});
        }
        if (self.code.items.len == 0 and self.fields.items.len == 0 and self.aobs.items.len == 0 and self.defined.items.len == 0)
            return self.fail("it doesn't change any code or hold any data", .{});
    }

    fn enableLine(self: *Converter, l: script.Line) !void {
        switch (l.statement) {
            .directive => |d| if (inCode(d.name)) try self.directive(d, l.number),
            .place => |raw| {
                const p = try self.subst(raw);
                if (self.find(self.allocs.items, p)) |name| {
                    try self.regions.append(self.arena, .{ .kind = .alloc, .name = name });
                } else if (std.mem.eql(u8, p, "@@") or self.find(self.labels.items, p) != null) {
                    try self.firstAlloc();
                    if (self.regions.items.len == 0) return self.fail("line {d} puts {s} somewhere before any code", .{ l.number, p });
                    try self.current().items.append(self.arena, .{ .label = self.find(self.labels.items, p) orelse "@@" });
                } else {
                    try self.regions.append(self.arena, .{ .kind = .site, .name = p });
                }
            },
            .code => |text| {
                try self.firstAlloc();
                if (self.regions.items.len == 0) return self.fail("line {d} has code without saying where it goes", .{l.number});
                try self.current().items.append(self.arena, .{ .code = try self.subst(text) });
            },
        }
    }

    /// Code before any place goes in the first alloc, like CE does.
    fn firstAlloc(self: *Converter) !void {
        if (self.regions.items.len > 0 or self.allocs.items.len == 0) return;
        try self.regions.append(self.arena, .{ .kind = .alloc, .name = self.allocs.items[0] });
    }

    /// CE takes `name:` as a label without `label(name)` when it's not anything else.
    fn implicitLabels(self: *Converter, lines: []const script.Line) !void {
        for (lines, 0..) |l, k| {
            if (l.statement != .place) continue;
            const p = try self.subst(l.statement.place);
            if (p.len == 0 or std.ascii.isDigit(p[0])) continue;
            const plain = for (p) |ch| {
                if (!std.ascii.isAlphanumeric(ch) and ch != '_') break false;
            } else true;
            if (!plain or self.isLocal(p) != null) continue;
            // A place that jumps to our code is somewhere in the game, like a name from Lua
            if (k + 1 < lines.len and lines[k + 1].statement == .code and self.jumpsHome(lines[k + 1].statement.code, lines)) continue;
            // Another script's name, unless this one jumps there like a label
            if (self.env.names.find(p) != .unknown and !jumpedTo(lines, p)) continue;
            try self.labels.append(self.arena, try self.safeName(p));
        }
    }

    /// Whether `text` jumps to one of our allocs, or a label right at the start of one.
    fn jumpsHome(self: *Converter, text: []const u8, lines: []const script.Line) bool {
        if (!std.ascii.startsWithIgnoreCase(firstWord(text), "jmp")) return false;
        var words = Words{ .text = text };
        _ = words.next();
        while (words.next()) |w| {
            if (self.find(self.allocs.items, w) != null) return true;
            // Placed straight after an alloc's own place
            for (lines, 0..) |l, k| {
                if (l.statement != .place or !std.ascii.eqlIgnoreCase(l.statement.place, w)) continue;
                var j = k;
                while (j > 0 and lines[j - 1].statement == .place) : (j -= 1) {
                    if (self.find(self.allocs.items, lines[j - 1].statement.place) != null) return true;
                }
            }
        }
        return false;
    }

    /// Alloc code that more than one site jumps into, cut at each one's label.
    fn splitBlocks(self: *Converter) !void {
        var entries: std.ArrayList([]const u8) = .empty;
        for (self.regions.items) |r| {
            if (r.kind != .site) continue;
            for (r.items.items) |it| switch (it) {
                .label => continue,
                .code => |text| {
                    if (!std.ascii.startsWithIgnoreCase(firstWord(text), "jmp")) break;
                    var words = Words{ .text = text };
                    _ = words.next();
                    while (words.next()) |w| if (self.find(self.labels.items, w)) |l| try entries.append(self.arena, l);
                    break;
                },
                else => break,
            };
        }
        if (entries.items.len == 0) return;
        var k: usize = 0;
        while (k < self.regions.items.len) : (k += 1) {
            const r = &self.regions.items[k];
            if (r.kind != .alloc) continue;
            const items = r.items.items;
            var seen_code = false;
            for (items, 0..) |it, at| switch (it) {
                .label => |l| if (seen_code and containsName(entries.items, l)) {
                    // The rest is its own block, starting at that label
                    var rest: Region = .{ .kind = .alloc, .name = l };
                    try rest.items.appendSlice(self.arena, items[at..]);
                    r.items.shrinkRetainingCapacity(at);
                    try self.regions.insert(self.arena, k + 1, rest);
                    break;
                },
                else => seen_code = true,
            };
        }
    }

    /// `@@:` with `@f` and `@b` pointing at the next and last one, as named labels.
    fn anonymousLabels(self: *Converter) !void {
        var count: usize = 0;
        for (self.regions.items) |r| for (r.items.items) |it| {
            if (it == .label and std.mem.eql(u8, it.label, "@@")) count += 1;
        };
        if (count == 0) return;
        var seen: usize = 0;
        for (self.regions.items) |*r| for (r.items.items) |*it| switch (it.*) {
            .label => |l| if (std.mem.eql(u8, l, "@@")) {
                seen += 1;
                const name = try std.fmt.allocPrint(self.arena, "anon_{d}", .{seen});
                try self.labels.append(self.arena, name);
                it.* = .{ .label = name };
            },
            .code => |text| {
                var t = text;
                if (seen < count) t = try replaceWord(self.arena, t, "@f", try std.fmt.allocPrint(self.arena, "anon_{d}", .{seen + 1}));
                if (seen > 0) t = try replaceWord(self.arena, t, "@b", try std.fmt.allocPrint(self.arena, "anon_{d}", .{seen}));
                it.* = .{ .code = t };
            },
            .readmem, .reassemble => {},
        };
    }

    fn current(self: *Converter) *Region {
        return &self.regions.items[self.regions.items.len - 1];
    }

    fn directive(self: *Converter, d: script.Directive, line: u32) !void {
        const args = try self.arena.alloc([]const u8, d.args.len);
        for (d.args, args) |a, *b| b.* = try self.subst(a);
        const is = struct {
            fn is(name: []const u8, want: []const u8) bool {
                return std.mem.eql(u8, name, want);
            }
        }.is;
        if (is(d.name, "aobscanmodule") or is(d.name, "aobscan")) {
            const module = is(d.name, "aobscanmodule");
            if (args.len != @as(usize, if (module) 3 else 2)) return self.fail("line {d}'s {s} has the wrong arguments", .{ line, d.name });
            const bytes = args[args.len - 1];
            const pat = numbers.pattern(self.arena, bytes) catch return self.fail("line {d}'s pattern `{s}` isn't one we can read", .{ line, bytes });
            const where = if (!module) blk: {
                try self.comment("it used aobscan, which searched all memory. This only looks in the game's exe");
                break :blk try std.fmt.allocPrint(self.arena, "sig(\"{s}\")", .{pat});
            } else if (std.mem.eql(u8, args[1], "$process") or self.isMain(args[1]))
                try std.fmt.allocPrint(self.arena, "sig(\"{s}\")", .{pat})
            else
                try std.fmt.allocPrint(self.arena, "sig(\"{s}\", Module(\"{s}\"))", .{ pat, std.mem.trim(u8, args[1], "\"") });
            try self.aobs.append(self.arena, .{ .name = try self.safeName(args[0]), .where = where });
            try self.patterns.append(self.arena, pat);
        } else if (is(d.name, "alloc") or is(d.name, "globalalloc")) {
            if (args.len < 2) return self.fail("line {d}'s {s} has the wrong arguments", .{ line, d.name });
            try self.allocs.append(self.arena, try self.safeName(args[0]));
            const size = numbers.parse(args[1]) orelse return self.fail("line {d}'s {s} size isn't a number", .{ line, d.name });
            try self.alloc_sizes.append(self.arena, @intCast(@max(size, 0)));
            if (is(d.name, "globalalloc")) try self.registered.append(self.arena, args[0]);
        } else if (is(d.name, "label")) {
            for (try script.names(self.arena, args)) |n| try self.labels.append(self.arena, try self.safeName(n));
        } else if (is(d.name, "registersymbol")) {
            for (try script.names(self.arena, d.args)) |n| {
                try self.registered.append(self.arena, n);
                // A shared `define` is a name for an address
                if (self.define(n)) |value| try self.defined.append(self.arena, .{ .name = n, .where = try self.address(value) });
            }
        } else if (is(d.name, "assert")) {
            if (args.len != 2) return self.fail("line {d}'s assert has the wrong arguments", .{line});
            try self.asserts.append(self.arena, .{ try self.placeKey(args[0]), args[1] });
        } else if (is(d.name, "readmem")) {
            if (args.len != 2 or self.regions.items.len == 0) return self.fail("line {d}'s readmem isn't in a block of code", .{line});
            const size = numbers.parse(args[1]) orelse return self.fail("line {d}'s readmem size isn't a number", .{line});
            if (size <= 0 or size > 64) return self.fail("line {d}'s readmem size is odd", .{line});
            try self.current().items.append(self.arena, .{ .readmem = .{ .where = args[0], .size = @intCast(size) } });
        } else if (is(d.name, "reassemble")) {
            if (args.len != 1 or self.regions.items.len == 0) return self.fail("line {d}'s reassemble isn't in a block of code", .{line});
            try self.current().items.append(self.arena, .{ .reassemble = args[0] });
        } else if (is(d.name, "define") or is(d.name, "fullaccess") or is(d.name, "dealloc") or is(d.name, "unregistersymbol")) {
            // Nothing to do, or done already
        } else {
            return self.fail("it uses {s}(), which tweaks don't have", .{d.name});
        }
    }

    fn isMain(self: *const Converter, module: []const u8) bool {
        const main = self.env.main_module orelse return false;
        return std.ascii.eqlIgnoreCase(std.mem.trim(u8, module, "\""), main);
    }

    /// Ours if it's a name we'd mean something else by.
    fn safeName(self: *Converter, name: []const u8) ![]const u8 {
        for (reserved) |r| if (std.ascii.eqlIgnoreCase(r, name)) return std.fmt.allocPrint(self.arena, "{s}_", .{name});
        return name;
    }

    fn find(self: *const Converter, list: []const []const u8, name: []const u8) ?[]const u8 {
        _ = self;
        for (list) |n| if (std.ascii.eqlIgnoreCase(n, name) or (n.len == name.len + 1 and n[n.len - 1] == '_' and std.ascii.eqlIgnoreCase(n[0..name.len], name))) return n;
        return null;
    }

    fn define(self: *const Converter, name: []const u8) ?[]const u8 {
        for (self.defines.items) |d| if (std.ascii.eqlIgnoreCase(d[0], name)) return d[1];
        return null;
    }

    /// `define`d words swapped for their text.
    fn subst(self: *Converter, text: []const u8) ![]const u8 {
        if (self.defines.items.len == 0) return text;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        var changed = false;
        while (i < text.len) {
            const ch = text[i];
            if (ch == '"' or ch == '\'') {
                const end = std.mem.indexOfScalarPos(u8, text, i + 1, ch) orelse (text.len - 1);
                try out.appendSlice(self.arena, text[i .. end + 1]);
                i = end + 1;
                continue;
            }
            if (!isWordChar(ch)) {
                try out.append(self.arena, ch);
                i += 1;
                continue;
            }
            const start = i;
            while (i < text.len and isWordChar(text[i])) i += 1;
            if (self.define(text[start..i])) |value| {
                try out.appendSlice(self.arena, value);
                changed = true;
            } else try out.appendSlice(self.arena, text[start..i]);
        }
        return if (changed) out.items else text;
    }

    /// For matching places, like `INJECT` in [ENABLE] and `inject` in [DISABLE].
    fn placeKey(self: *Converter, place: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        for (try self.subst(place)) |ch| {
            if (ch == ' ' or ch == '\t' or ch == '"') continue;
            try out.append(self.arena, std.ascii.toLower(ch));
        }
        return out.items;
    }

    /// The script's own name for `word`, if it has one.
    fn isLocal(self: *const Converter, word: []const u8) ?[]const u8 {
        if (self.find(self.labels.items, word)) |n| return n;
        if (self.find(self.allocs.items, word)) |n| return n;
        for (self.aobs.items) |a| if (self.find(&.{a.name}, word) != null) return a.name;
        for (self.fields.items) |f| if (std.ascii.eqlIgnoreCase(f.name, word)) return f.name;
        return null;
    }

    fn lookup(context: ?*const anyopaque, word: []const u8) numbers.Lookup {
        const self: *const Converter = @ptrCast(@alignCast(context.?));
        if (self.isLocal(word)) |n| return if (std.mem.eql(u8, n, word)) .known else .{ .rename = n };
        for (self.registered.items) |r| if (std.ascii.eqlIgnoreCase(r, word)) return .known;
        return self.env.names.find(word);
    }

    fn names(self: *const Converter) numbers.Names {
        return .{ .context = self, .lookup = lookup };
    }

    fn address(self: *Converter, text: []const u8) ![]const u8 {
        return numbers.address(self.arena, text, self.names(), &self.notes) catch self.fail("`{s}` isn't an address we can read", .{text});
    }

    /// Ours, split at `;` so `nop 3` is three.
    fn statement(self: *Converter, text: []const u8, out: *std.ArrayList([]const u8)) !void {
        const converted = numbers.asmStatement(self.arena, text, self.names(), &self.notes) catch
            return self.fail("`{s}` has a number we can't read", .{text});
        var it = std.mem.splitSequence(u8, converted, "; ");
        while (it.next()) |s| try out.append(self.arena, try sizedMemory(self.arena, try plainBranch(self.arena, try threeImul(self.arena, if (self.env.bits == .x64) try widenPush(self.arena, s) else s))));
    }

    /// A write to the game's code, from [ENABLE], with what [DISABLE] puts back.
    fn site(self: *Converter, region: *Region) !void {
        const where = try self.address(region.name);
        var original = try self.originalAt(region.name, where);
        var items = region.items.items;
        // Labels right at the start are other names for it
        while (items.len > 0 and items[0] == .label) : (items = items[1..]) {
            const alias = items[0].label;
            if (original == null) original = try self.originalAt(alias, where);
            if (self.isRegistered(alias)) try self.defined.append(self.arena, .{ .name = alias, .where = where });
        }
        region.items.items = @constCast(items);
        // `jmp newmem`, then nops and the return label
        if (items.len > 0 and items[0] == .code) {
            if (self.jumpTarget(items[0].code)) |alloc| {
                const target = alloc.name;
                var back: ?[]const u8 = null;
                for (items[1..]) |it| switch (it) {
                    .label => |l| if (back == null) {
                        back = l;
                    } else return self.fail("{s} has more than one label after its jump", .{region.name}),
                    .code => |text| if (!isNop(text)) return self.fail("{s} has more code after its jump to {s}", .{ region.name, target }),
                    .readmem, .reassemble => return self.fail("{s} copies code after its jump", .{region.name}),
                };
                if (alloc.used) return self.fail("more than one place jumps to {s}", .{target});
                alloc.used = true;
                return self.injection(where, original orelse return self.fail("its [DISABLE] doesn't put {s} back", .{region.name}), alloc, back);
            }
        }
        try self.patchSite(region, where, original orelse return self.fail("its [DISABLE] doesn't put {s} back", .{region.name}));
    }

    /// The alloc a `jmp` goes to, if that's what it is. A label at its very start counts.
    fn jumpTarget(self: *Converter, text: []const u8) ?*Region {
        var it = std.mem.tokenizeAny(u8, text, " \t");
        const mnemonic = it.next() orelse return null;
        // `jmp1` is CE's too
        if (!std.ascii.eqlIgnoreCase(mnemonic, "jmp") and !std.ascii.eqlIgnoreCase(mnemonic, "jmp1")) return null;
        var operand = std.mem.trim(u8, it.rest(), " \t");
        for ([_][]const u8{ "short ", "near ", "far " }) |w| if (std.ascii.startsWithIgnoreCase(operand, w)) {
            operand = std.mem.trim(u8, operand[w.len..], " \t");
        };
        if (self.find(self.allocs.items, operand)) |name| {
            for (self.regions.items) |*r| if (r.kind == .alloc and std.mem.eql(u8, r.name, name)) return r;
            return null;
        }
        const label = self.find(self.labels.items, operand) orelse return null;
        for (self.regions.items) |*r| {
            if (r.kind != .alloc) continue;
            for (r.items.items) |item| switch (item) {
                .label => |l| if (std.mem.eql(u8, l, label)) return r,
                else => break,
            };
        }
        return null;
    }

    /// The aob's own bytes at `where`, if it covers them all with none left to `??`.
    fn aobBytes(self: *Converter, where: []const u8, len: usize) !?[]const u8 {
        const split = splitOffset(where);
        const k = for (self.aobs.items, 0..) |a, k| {
            if (std.ascii.eqlIgnoreCase(a.name, split.name)) break k;
        } else return null;
        var bytes: std.ArrayList(u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, self.patterns.items[k], ' ');
        var at: u64 = 0;
        while (it.next()) |token| : (at += 1) {
            if (at < split.offset) continue;
            if (bytes.items.len == len) break;
            try bytes.append(self.arena, std.fmt.parseInt(u8, token, 16) catch return null);
        }
        return if (bytes.items.len == len) bytes.items else null;
    }

    fn fromBytes(self: *Converter, bytes: []const u8, where: []const u8) !Original {
        var out: Original = .{ .bytes = bytes };
        const decoded = try machine.decode(self.arena, bytes, self.env.bits, self.fake(where));
        if (decoded) |insns| {
            const list = try self.arena.alloc([]const u8, insns.len);
            for (insns, list) |i, *s| {
                s.* = i.text;
                out.relative = out.relative or i.relative;
            }
            out.instructions = list;
        }
        return out;
    }

    fn originalAt(self: *Converter, place: []const u8, where: []const u8) !?Original {
        const k = try self.placeKey(place);
        const texts: []const []const u8 = for (self.restores.items) |r| {
            if (std.mem.eql(u8, r.key, k)) break r.items.items;
        } else for (self.asserts.items) |a| {
            if (std.mem.eql(u8, a[0], k)) break &.{try std.fmt.allocPrint(self.arena, "db {s}", .{a[1]})};
        } else return null;
        if (texts.len == 0) return null;

        // A copy CE kept, so all we know is how long, unless the aob has it
        if (texts.len == 1 and std.mem.startsWith(u8, texts[0], "readmem ")) {
            const size = try std.fmt.parseInt(u32, texts[0][8..], 10);
            if (try self.aobBytes(where, size)) |bytes| {
                var out = try self.fromBytes(bytes, where);
                out.size = size;
                return out;
            }
            return .{ .size = size };
        }

        var all_data = true;
        var any_data = false;
        for (texts) |t| {
            const data = isDb(t);
            all_data = all_data and data;
            any_data = any_data or data;
        }
        if (all_data) {
            var bytes: std.ArrayList(u8) = .empty;
            for (texts) |t| try bytes.appendSlice(self.arena, rawBytes(self.arena, t) catch return self.fail("its [DISABLE] has bytes we can't read: {s}", .{t}));
            return try self.fromBytes(bytes.items, where);
        }
        if (any_data) return self.fail("its [DISABLE] mixes bytes and code at {s}", .{place});
        var list: std.ArrayList([]const u8) = .empty;
        for (texts) |t| try self.statement(t, &list);
        var out: Original = .{ .instructions = list.items };
        for (list.items) |s| out.relative = out.relative or isBranch(s);
        return out;
    }

    /// Where `where` would be, made up, so relative code can be compared.
    fn fake(self: *const Converter, where: []const u8) u64 {
        const split = splitOffset(where);
        const base = self.fakeName(split.name) orelse return 0x10_0000;
        return base +% split.offset;
    }

    fn fakeName(self: *const Converter, name: []const u8) ?u64 {
        if (name.len == 0) return 0;
        for (self.aobs.items, 0..) |a, k| if (std.ascii.eqlIgnoreCase(a.name, name)) return 0x1000_0000 + k * 0x100_0000;
        if (numbers.isModule(name)) return self.env.bits.base();
        return null;
    }

    fn resolveFake(context: ?*const anyopaque, name: []const u8) ?u64 {
        const self: *const Converter = @ptrCast(@alignCast(context.?));
        return self.fakeName(name);
    }

    fn expectOf(self: *Converter, o: Original) ![]const u8 {
        if (o.instructions) |list| if (!o.relative or o.bytes == null) return std.mem.join(self.arena, "; ", list);
        return hexBytes(self.arena, o.bytes orelse return "");
    }

    /// A `@patch` over what `o` was, by what it was or how long when that's all we know.
    fn patchOver(self: *Converter, where: []const u8, o: Original, lines: []const []const u8) !Code {
        const expect = try self.expectOf(o);
        return .{ .kind = .patch, .where = where, .expect = expect, .size = if (expect.len == 0) o.size else 0, .lines = lines };
    }

    /// `kai.exe+10:` and its code, with no alloc involved.
    fn patchSite(self: *Converter, region: *Region, where: []const u8, o: Original) !void {
        var all_data = true;
        var items = region.items.items;
        // A label after it all that nothing uses, like a template's leftover `return:`
        while (items.len > 0 and items[items.len - 1] == .label) : (items = items[0 .. items.len - 1]) {
            const l = items[items.len - 1].label;
            if (self.usedAnywhere(l)) return self.fail("{s} has a label {s} in it", .{ region.name, l });
        }
        for (items) |it| switch (it) {
            .code => |t| all_data = all_data and isDb(t),
            .label => |l| return self.fail("{s} has a label {s} in it", .{ region.name, l }),
            .readmem, .reassemble => return self.fail("{s} copies code in it", .{region.name}),
        };
        if (items.len == 0) return self.fail("{s} has nothing written to it", .{region.name});

        if (all_data and o.bytes != null) {
            var bytes: std.ArrayList(u8) = .empty;
            for (items) |it| try bytes.appendSlice(self.arena, rawBytes(self.arena, it.code) catch return self.fail("{s} has bytes we can't read", .{region.name}));
            const new = bytes.items;
            const old = o.bytes.?;
            if (std.mem.eql(u8, new, old)) {
                const why = "no real restore in the table, so the original isn't checked";
                try self.comment(why);
                try self.told.append(self.arena, why);
                return self.code.append(self.arena, .{ .kind = .bytes, .where = where, .lines = try self.one(try hexBytes(self.arena, new)) });
            }
            if (new.len > old.len) return self.fail("{s} writes {d} bytes but [DISABLE] only puts {d} back", .{ region.name, new.len, old.len });
            // Whole instructions it covers, exactly, or else it's just bytes
            const covered = try self.coveredBytes(old, new.len, where);
            if (covered == null or o.instructions == null) {
                const line = try hexBytes(self.arena, new);
                return self.code.append(self.arena, .{ .kind = .bytes, .where = where, .expect = try hexBytes(self.arena, old[0..new.len]), .lines = try self.one(line) });
            }
            const used = covered.?;
            const expect_original: Original = .{ .bytes = old[0..used.len], .instructions = used.text, .relative = used.relative };
            // Exactly its bytes, since asm put back together might not be
            const body = if (std.mem.allEqual(u8, new, 0x90)) try self.one("nop") else try self.one(try dbLine(self.arena, new));
            return self.code.append(self.arena, .{ .kind = .patch, .where = where, .expect = try self.expectOf(expect_original), .lines = body });
        }

        var lines: std.ArrayList([]const u8) = .empty;
        for (items) |it| try self.statement(it.code, &lines);
        if (lines.items.len > 1 and allNops(lines.items)) {
            lines.clearRetainingCapacity();
            try lines.append(self.arena, "nop");
        }
        // [DISABLE] writing what [ENABLE] did puts nothing back, so it says nothing of the original
        if (o.instructions) |was| if (machine.same(self.gpa, lines.items, was, .{ .context = self, .func = resolveFake })) {
            return self.unchecked(where, lines.items);
        };
        try self.code.append(self.arena, try self.patchOver(where, o, lines.items));
    }

    /// A patch as long as its own code, over whatever's there.
    fn unchecked(self: *Converter, where: []const u8, lines: []const []const u8) !void {
        const why = "no real restore in the table, so the original isn't checked";
        try self.comment(why);
        try self.told.append(self.arena, why);
        const size = try machine.length(self.arena, try std.mem.join(self.arena, "\n", lines), self.env.bits) orelse 0;
        try self.code.append(self.arena, .{ .kind = .patch, .where = where, .size = @intCast(size), .lines = lines });
    }

    /// Whether any code in the script names `label`.
    fn usedAnywhere(self: *const Converter, label: []const u8) bool {
        for (self.regions.items) |r| for (r.items.items) |it| {
            if (it != .code) continue;
            var words = Words{ .text = it.code };
            while (words.next()) |w| if (std.ascii.eqlIgnoreCase(w, label)) return true;
        };
        return false;
    }

    const Covered = struct { len: usize, text: []const []const u8, relative: bool };

    /// The instructions in `bytes` that make up exactly its first `len`, or null if `len`
    /// splits one.
    fn coveredBytes(self: *Converter, bytes: []const u8, len: usize, where: []const u8) !?Covered {
        const insns = try machine.decode(self.arena, bytes, self.env.bits, self.fake(where)) orelse return null;
        var at: usize = 0;
        var text: std.ArrayList([]const u8) = .empty;
        var relative = false;
        for (insns) |i| {
            if (at >= len) break;
            at += i.len;
            try text.append(self.arena, i.text);
            relative = relative or i.relative;
        }
        if (at != len) return null;
        return .{ .len = len, .text = text.items, .relative = relative };
    }

    fn one(self: *Converter, line: []const u8) ![]const []const u8 {
        const list = try self.arena.alloc([]const u8, 1);
        list[0] = line;
        return list;
    }

    /// CE's injection template and its cousins.
    fn injection(self: *Converter, where: []const u8, o: Original, alloc: *Region, back_label: ?[]const u8) !void {
        var back = back_label;
        self.here = .{ .where = where, .original = o };
        defer self.here = null;
        // Some go back with `jmp INJECT+7` instead of a label, so that's the label now
        const len: u64 = if (o.bytes) |b| b.len else o.size;
        if (back == null and len > 0) {
            const here = splitOffset(where);
            for (alloc.items.items) |*it| {
                if (it.* != .code or std.ascii.toLower(firstWord(it.code)[0]) != 'j') continue;
                const text = it.code;
                const space = std.mem.indexOfAny(u8, text, " \t") orelse continue;
                var scratch: numbers.Notes = .{};
                const operand = numbers.address(self.arena, std.mem.trim(u8, text[space..], " \t"), self.names(), &scratch) catch continue;
                const there = splitOffset(operand);
                if (here.name.len == 0 or !std.ascii.eqlIgnoreCase(here.name, there.name) or there.offset != here.offset +% len) continue;
                it.* = .{ .code = try std.fmt.allocPrint(self.arena, "{s} ce_return", .{text[0..space]}) };
                if (back == null) try self.labels.append(self.arena, "ce_return");
                back = "ce_return";
            }
        }
        // Cut it at its labels, with data pulled out
        var segments: std.ArrayList(Segment) = .empty;
        var data: std.ArrayList([]const u8) = .empty;
        {
            var start: usize = 0;
            var label: ?[]const u8 = null;
            const items = alloc.items.items;
            for (items, 0..) |it, k| {
                if (it != .label) continue;
                try self.segment(&segments, &data, label, items[start..k]);
                label = it.label;
                start = k + 1;
            }
            try self.segment(&segments, &data, label, items[start..]);
        }

        const instructions: []const []const u8 = o.instructions orelse if (o.size > 0) &.{} else return self.fail("the bytes [DISABLE] puts back at {s} don't disassemble", .{where});
        // The part that's the original code, then jumps back
        var orig: ?usize = null;
        var orig_same = false;
        for (segments.items, 0..) |s, k| {
            if (s.label == null or !endsWithJump(s.items, back)) continue;
            const same = try self.sameAs(s.items[0 .. s.items.len - 1], instructions, where);
            if (orig == null or same) {
                orig = k;
                orig_same = same;
            }
            if (same) break;
        }
        const jumps_back = countJumps(segments.items, back) - @as(usize, if (orig) |k| (if (endsWithJump(segments.items[k].items, back)) 1 else 0) else 0);

        var body: std.ArrayList([]const u8) = .empty;
        if (orig != null and orig_same and (instructions.len == 1 or jumps_back == 0)) {
            const k = orig.?;
            const orig_label = segments.items[k].label.?;
            for (segments.items[0..k]) |s| try self.emitSegment(&body, s, back, orig_label);
            if (k + 1 < segments.items.len) {
                try body.append(self.arena, "jmp original");
                for (segments.items[k + 1 ..]) |s| try self.emitSegment(&body, s, back, orig_label);
            }
            try self.endBody(&body, &data, "jmp original");
            return self.finishCode(.{ .kind = .inject, .where = where, .lines = body.items }, alloc.name);
        }
        // Its own code, then the original, then back, and nothing else jumps back
        if (segments.items.len == 1 and jumps_back == 1 and endsWithJump(segments.items[0].items, back)) {
            const items = segments.items[0].items;
            const n = instructions.len;
            if (n > 0 and items.len > n and try self.sameAs(items[items.len - 1 - n .. items.len - 1], instructions, where)) {
                try self.emitSegment(&body, .{ .label = null, .items = items[0 .. items.len - 1 - n] }, back, null);
                try self.endBody(&body, &data, "jmp original");
                return self.finishCode(.{ .kind = .inject, .where = where, .lines = body.items }, alloc.name);
            }
        }
        // Anything else replaces the original, and falls into what's after it
        for (segments.items) |s| try self.emitSegment(&body, s, back, null);
        if (body.items.len > 0 and std.mem.eql(u8, body.items[body.items.len - 1], "jmp resume")) _ = body.pop();
        try self.endBody(&body, &data, "jmp resume");
        try self.finishCode(try self.patchOver(where, o, body.items), alloc.name);
    }

    /// Data after the code, behind a jump so it's never run.
    fn endBody(self: *Converter, body: *std.ArrayList([]const u8), data: *const std.ArrayList([]const u8), jump: []const u8) !void {
        if (data.items.len == 0) return;
        const last = if (body.items.len > 0) body.items[body.items.len - 1] else "";
        if (!isUnconditional(last)) try body.append(self.arena, jump);
        try body.appendSlice(self.arena, data.items);
    }

    fn finishCode(self: *Converter, code: Code, alloc_name: []const u8) !void {
        // Labels from another block don't reach this one
        var defined: std.ArrayList([]const u8) = .empty;
        for (code.lines) |l| if (std.mem.endsWith(u8, l, ":")) try defined.append(self.arena, l[0 .. l.len - 1]);
        for (code.lines) |l| {
            var words = Words{ .text = l };
            while (words.next()) |w| {
                if (std.ascii.eqlIgnoreCase(w, alloc_name) and !containsName(defined.items, w)) return self.fail("its code uses {s} itself, which is ours to place now", .{alloc_name});
                const label = self.find(self.labels.items, w) orelse self.find(self.allocs.items, w) orelse continue;
                if (self.isField(label)) continue;
                const here = for (defined.items) |d| {
                    if (std.mem.eql(u8, d, label)) break true;
                } else false;
                if (!here) return self.fail("its code jumps to {s}, which is in another block", .{label});
            }
        }
        try self.code.append(self.arena, code);
    }

    fn isField(self: *const Converter, name: []const u8) bool {
        for (self.fields.items) |f| if (std.mem.eql(u8, f.name, name)) return true;
        return false;
    }

    /// A segment's code, or its data as a field or kept data.
    fn segment(self: *Converter, segments: *std.ArrayList(Segment), data: *std.ArrayList([]const u8), label: ?[]const u8, items: []const Item) !void {
        const all_data = items.len > 0 and for (items) |it| {
            if (it != .code or !isDataStatement(it.code)) break false;
        } else true;
        if (label != null and all_data) {
            if (items.len == 1) {
                if (try self.field(label.?, items[0].code)) |f| return self.fields.append(self.arena, f);
            }
            if (self.isRegistered(label.?)) return self.fail("{s} is shared but its data isn't one value, so it can't be a @data field", .{label.?});
            try data.append(self.arena, try std.fmt.allocPrint(self.arena, "{s}:", .{label.?}));
            for (items) |it| try self.statement(it.code, data);
            return;
        }
        if (label == null and items.len == 0) return;
        // A copy of the original bytes for [DISABLE], which we don't need
        const backup = items.len > 0 and for (items) |it| {
            if (it != .readmem) break false;
        } else true;
        if (label != null and backup) return;
        try segments.append(self.arena, .{ .label = label, .items = items });
    }

    fn isRegistered(self: *const Converter, name: []const u8) bool {
        for (self.registered.items) |r| if (std.ascii.eqlIgnoreCase(r, name)) return true;
        return false;
    }

    /// `dd 0` or `dq (float)1.5` as a field, if it's one plain value.
    fn field(self: *Converter, name: []const u8, text: []const u8) !?Field {
        var list: std.ArrayList([]const u8) = .empty;
        try self.statement(text, &list);
        if (list.items.len != 1) return null;
        const converted = list.items[0];
        const unit = std.ascii.lowerString(try self.arena.alloc(u8, 2), converted[0..2]);
        var value = std.mem.trim(u8, converted[2..], " \t");
        if (value.len == 0 or std.mem.indexOfAny(u8, value, ", \t'\"") != null) return null;
        var float: ?[]const u8 = null;
        if (std.mem.startsWith(u8, value, "(float)")) {
            value = value[7..];
            float = "f32";
        } else if (std.mem.startsWith(u8, value, "(double)")) {
            value = value[8..];
            float = "f64";
        } else if (std.mem.indexOfScalar(u8, value, '.') != null) {
            float = if (std.mem.eql(u8, unit, "dq")) "f64" else "f32";
        }
        const n = parseOurs(value) orelse return null;
        if (float) |t| return .{ .name = name, .type = t, .value = try std.fmt.allocPrint(self.arena, "{d}", .{n}) };
        if (@floor(n) != n) return null;
        const negative = n < 0;
        const ty: []const u8 = if (std.mem.eql(u8, unit, "db"))
            (if (negative) "i8" else "u8")
        else if (std.mem.eql(u8, unit, "dw"))
            (if (negative) "i16" else "u16")
        else if (std.mem.eql(u8, unit, "dd"))
            (if (negative) "i32" else "u32")
        else if (negative) "i64" else "u64";
        return .{ .name = name, .type = ty, .value = value };
    }

    /// An alloc that's only data, like `GodMode: dd 0`.
    fn dataOnly(self: *Converter, region: *Region) !void {
        var label: ?[]const u8 = region.name;
        var k: usize = 0;
        const items = region.items.items;
        while (k < items.len) {
            switch (items[k]) {
                .label => |l| {
                    label = l;
                    k += 1;
                    continue;
                },
                .code => |text| {
                    if (!isDataStatement(text)) return self.fail("{s} has code that nothing jumps to, maybe called from somewhere else", .{region.name});
                    const name = label orelse return self.fail("{s} has more data than a @data field takes", .{region.name});
                    const f = try self.field(name, text) orelse return self.fail("{s} isn't one plain value, so it can't be a @data field", .{name});
                    try self.fields.append(self.arena, f);
                    label = null;
                },
                .readmem => label = null,
                .reassemble => return self.fail("{s} copies code with reassemble", .{region.name}),
            }
            k += 1;
        }
        // An empty one is space the script uses by name
        if (label) |l| if (items.len == 0 or items[items.len - 1] == .label) {
            try self.fields.append(self.arena, .{ .name = l, .type = "u64", .value = "0" });
        };
    }

    /// Whether `items` are the same instructions as `want`, any spelling.
    fn sameAs(self: *Converter, items: []const Item, want: []const []const u8, where: []const u8) !bool {
        if (items.len == 1 and items[0] == .readmem) {
            const r = items[0].readmem;
            if (std.mem.eql(u8, try self.placeKey(r.where), try self.placeKey(where))) return true;
            return std.mem.eql(u8, try self.address(r.where), where);
        }
        var ours: std.ArrayList([]const u8) = .empty;
        for (items) |it| switch (it) {
            .code => |t| self.statement(t, &ours) catch return false,
            .reassemble => |w| try ours.append(self.arena, try self.copied(w, true) orelse return false),
            else => return false,
        };
        return machine.same(self.gpa, ours.items, want, .{ .context = self, .func = resolveFake });
    }

    /// The site's own instruction that `reassemble(where)` copies, if we know it and it
    /// doesn't depend on where it is.
    fn copied(self: *Converter, where: []const u8, relative_ok: bool) !?[]const u8 {
        const h = self.here orelse return null;
        const bytes = h.original.bytes orelse return null;
        const at = splitOffset(try self.address(where));
        const start = splitOffset(h.where);
        if (!std.ascii.eqlIgnoreCase(at.name, start.name) or at.offset < start.offset) return null;
        const insns = try machine.decode(self.arena, bytes, self.env.bits, self.fake(h.where)) orelse return null;
        var offset: u64 = start.offset;
        for (insns) |i| {
            if (offset == at.offset) return if (i.relative and !relative_ok) null else i.text;
            offset += i.len;
        }
        return null;
    }

    fn emitSegment(self: *Converter, body: *std.ArrayList([]const u8), s: Segment, back: ?[]const u8, orig: ?[]const u8) !void {
        if (s.label) |l| try body.append(self.arena, try std.fmt.allocPrint(self.arena, "{s}:", .{l}));
        for (s.items) |it| switch (it) {
            .label => unreachable,
            .readmem => |r| {
                // A copy of the site's own code is that code, if we know it
                const h = self.here orelse return self.fail("its code copies bytes with readmem somewhere we can't follow", .{});
                const same_place = std.mem.eql(u8, try self.address(r.where), h.where);
                const o = h.original;
                const known = o.instructions != null and !o.relative and o.bytes != null and o.bytes.?.len == r.size;
                if (!same_place or !known) return self.fail("its code copies bytes with readmem somewhere we can't follow", .{});
                try body.appendSlice(self.arena, o.instructions.?);
            },
            .reassemble => |w| try body.append(self.arena, try self.copied(w, false) orelse return self.fail("its code copies an instruction with reassemble that we can't follow", .{})),
            .code => |text| {
                const start = body.items.len;
                try self.statement(text, body);
                for (body.items[start..]) |*line| {
                    if (back) |b| line.* = try replaceWord(self.arena, line.*, b, "resume");
                    if (orig) |o| line.* = try replaceWord(self.arena, line.*, o, "original");
                }
            },
        };
    }

    fn finish(self: *Converter) !Tweak {
        var syms: std.ArrayList(Sym) = .empty;
        for (self.aobs.items) |a| try syms.append(self.arena, a);
        for (self.defined.items) |a| try syms.append(self.arena, a);
        var unshared: std.ArrayList([]const u8) = .empty;
        for (self.registered.items) |r| {
            const published = for (syms.items) |s| {
                if (std.ascii.eqlIgnoreCase(s.name, r)) break true;
            } else self.isField(self.find(self.labels.items, r) orelse self.find(self.allocs.items, r) orelse r);
            if (!published) try unshared.append(self.arena, r);
        }
        // Names nothing defines, besides the game's modules
        var missing: std.ArrayList([]const u8) = .empty;
        for (self.notes.unknown.items) |n| {
            if (self.isRegistered(n)) continue;
            try missing.append(self.arena, n);
        }
        if (missing.items.len > 0) {
            try self.problems.append(self.arena, try std.fmt.allocPrint(self.arena, "it uses {s}, which nothing in the table defines", .{try std.mem.join(self.arena, ", ", missing.items)}));
            var t = self.reviewed();
            t.missing = missing.items;
            return t;
        }
        var near: []const u8 = "";
        if (self.env.bits == .x64 and self.fields.items.len > 0) {
            if (self.code.items.len > 0) {
                near = self.code.items[0].where;
            } else if (self.env.main_module) |m| {
                near = try numbers.address(self.arena, m, .none, &self.notes);
            }
        }
        return .{
            .syms = syms.items,
            .fields = self.fields.items,
            .near = near,
            .code = self.code.items,
            .comments = self.comments.items,
            .ambiguous = self.notes.ambiguous.items,
            .unshared = unshared.items,
            .notes = self.told.items,
        };
    }
};

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '@' or ch == '$' or ch == '#' or ch == '?' or ch == '!';
}

/// Words outside quotes.
const Words = struct {
    text: []const u8,
    i: usize = 0,

    fn next(self: *Words) ?[]const u8 {
        while (self.i < self.text.len) {
            const ch = self.text[self.i];
            if (ch == '"' or ch == '\'') {
                self.i = (std.mem.indexOfScalarPos(u8, self.text, self.i + 1, ch) orelse (self.text.len - 1)) + 1;
                continue;
            }
            if (!isWordChar(ch)) {
                self.i += 1;
                continue;
            }
            const start = self.i;
            while (self.i < self.text.len and isWordChar(self.text[self.i])) self.i += 1;
            return self.text[start..self.i];
        }
        return null;
    }
};

/// `from` as a whole word, any case, to `to`.
fn replaceWord(arena: std.mem.Allocator, text: []const u8, from: []const u8, to: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var words = Words{ .text = text };
    var copied: usize = 0;
    while (words.next()) |w| {
        if (!std.ascii.eqlIgnoreCase(w, from)) continue;
        const start = words.i - w.len;
        try out.appendSlice(arena, text[copied..start]);
        try out.appendSlice(arena, to);
        copied = words.i;
    }
    if (copied == 0) return text;
    try out.appendSlice(arena, text[copied..]);
    return out.items;
}

fn firstWord(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t");
    const end = std.mem.indexOfAny(u8, t, " \t") orelse t.len;
    return t[0..end];
}

/// CE takes `imul edx,100` for `imul edx,edx,100`, which is the only form there is.
fn threeImul(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const w = firstWord(text);
    if (!std.ascii.eqlIgnoreCase(w, "imul")) return text;
    const operands = std.mem.trim(u8, std.mem.trim(u8, text, " \t")[w.len..], " \t");
    const comma = std.mem.indexOfScalar(u8, operands, ',') orelse return text;
    const first = std.mem.trim(u8, operands[0..comma], " \t");
    const second = std.mem.trim(u8, operands[comma + 1 ..], " \t");
    if (std.mem.indexOfScalar(u8, second, ',') != null or std.mem.indexOfScalar(u8, second, '[') != null) return text;
    if (!numbers.isReserved(first) or numbers.isReserved(second)) return text;
    return std.fmt.allocPrint(arena, "{s} {s},{s},{s}", .{ w, first, first, second });
}

/// CE takes `push r8d` on x64 as `push r8`, the only push there is.
fn widenPush(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const w = firstWord(text);
    if (!std.ascii.eqlIgnoreCase(w, "push") and !std.ascii.eqlIgnoreCase(w, "pop")) return text;
    const operand = std.mem.trim(u8, std.mem.trim(u8, text, " \t")[w.len..], " \t");
    var buf: [8]u8 = undefined;
    if (operand.len > buf.len) return text;
    const r = std.ascii.lowerString(&buf, operand);
    const wide: []const u8 = for ([_][2][]const u8{
        .{ "eax", "rax" }, .{ "ebx", "rbx" }, .{ "ecx", "rcx" }, .{ "edx", "rdx" },
        .{ "esi", "rsi" }, .{ "edi", "rdi" }, .{ "ebp", "rbp" }, .{ "esp", "rsp" },
    }) |pair| {
        if (std.mem.eql(u8, r, pair[0])) break pair[1];
    } else if (r.len >= 3 and r[0] == 'r' and r[r.len - 1] == 'd' and std.ascii.isDigit(r[1]))
        r[0 .. r.len - 1]
    else
        return text;
    return std.fmt.allocPrint(arena, "{s} {s}", .{ w, wide });
}

/// `jmp short x` as `jmp x`, since ours picks the shortest that reaches. And `sal`, which is
/// `shl` by another name.
fn plainBranch(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, text, " \t");
    const w = firstWord(t);
    if (std.ascii.eqlIgnoreCase(w, "sal")) return std.fmt.allocPrint(arena, "shl{s}", .{t[w.len..]});
    if (!isBranch(t)) return text;
    const operand = std.mem.trim(u8, t[w.len..], " \t");
    for ([_][]const u8{ "short ", "near " }) |hint| {
        if (std.ascii.startsWithIgnoreCase(operand, hint)) return std.fmt.allocPrint(arena, "{s} {s}", .{ w, std.mem.trim(u8, operand[hint.len..], " \t") });
    }
    return text;
}

/// CE takes a memory operand with no size next to a number as a dword, like `cmp [x],1`. Ours
/// does too, but saying so means nobody has to know that.
fn sizedMemory(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const w = firstWord(text);
    const sized = [_][]const u8{ "mov", "cmp", "add", "sub", "and", "or", "xor", "adc", "sbb", "test", "shl", "shr", "sal", "sar", "rol", "ror", "rcl", "rcr", "bt", "bts", "btr", "btc" };
    for (sized) |m| {
        if (std.ascii.eqlIgnoreCase(w, m)) break;
    } else return text;
    const t = std.mem.trim(u8, text, " \t");
    var memory: ?usize = null;
    var number = false;
    var depth: usize = 0;
    var start = w.len;
    for (w.len..t.len + 1) |i| {
        if (i < t.len) {
            if (t[i] == '[') depth += 1;
            if (t[i] == ']') depth -|= 1;
            if (t[i] != ',' or depth > 0) continue;
        }
        const op = std.mem.trim(u8, t[start..i], " \t");
        start = i + 1;
        if (op.len == 0) return text;
        if (op[0] == '[') {
            if (memory != null) return text;
            memory = @intFromPtr(op.ptr) - @intFromPtr(t.ptr);
        } else if (isImmediate(op)) {
            number = true;
        } else return text;
    }
    const at = memory orelse return text;
    if (!number) return text;
    return std.fmt.allocPrint(arena, "{s}dword ptr {s}", .{ t[0..at], t[at..] });
}

/// Our number text that fits a dword, signed or not.
fn isImmediate(text: []const u8) bool {
    const t = if (text[0] == '-') text[1..] else text;
    const v = (if (std.ascii.startsWithIgnoreCase(t, "0x")) std.fmt.parseInt(u64, t[2..], 16) else std.fmt.parseInt(u64, t, 10)) catch return false;
    return v <= std.math.maxInt(u32);
}

fn containsName(list: []const []const u8, name: []const u8) bool {
    for (list) |n| if (std.ascii.eqlIgnoreCase(n, name)) return true;
    return false;
}

/// Whether some jump in `lines` goes to `name`.
fn jumpedTo(lines: []const script.Line, name: []const u8) bool {
    for (lines) |l| {
        if (l.statement != .code) continue;
        const text = l.statement.code;
        if (!isBranch(text)) continue;
        var words = Words{ .text = text };
        _ = words.next();
        while (words.next()) |w| if (std.ascii.eqlIgnoreCase(w, name)) return true;
    }
    return false;
}

fn isDb(text: []const u8) bool {
    return std.ascii.eqlIgnoreCase(firstWord(text), "db");
}

fn isDataStatement(text: []const u8) bool {
    return numbers.isData(firstWord(text));
}

/// Labels, data and backups, but no code.
fn isAllData(items: []const Item) bool {
    for (items) |it| switch (it) {
        .code => |t| if (!isDataStatement(t)) return false,
        .reassemble => return false,
        .label, .readmem => {},
    };
    return true;
}

/// Directives that go where they are, like code.
fn inCode(name: []const u8) bool {
    return std.mem.eql(u8, name, "readmem") or std.mem.eql(u8, name, "reassemble");
}

fn isNop(text: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(firstWord(text), "nop")) return true;
    if (!isDb(text)) return false;
    var it = std.mem.tokenizeAny(u8, std.mem.trim(u8, text, " \t")[2..], " \t,");
    while (it.next()) |t| if (!std.ascii.eqlIgnoreCase(t, "90")) return false;
    return true;
}

fn allNops(lines: []const []const u8) bool {
    for (lines) |l| if (!std.mem.eql(u8, l, "nop")) return false;
    return true;
}

/// Jumps, calls and loops, which depend on where they are.
fn isBranch(text: []const u8) bool {
    const w = firstWord(text);
    if (w.len == 0) return false;
    if (std.ascii.toLower(w[0]) == 'j') return true;
    return std.ascii.eqlIgnoreCase(w, "call") or std.ascii.startsWithIgnoreCase(w, "loop");
}

fn isUnconditional(text: []const u8) bool {
    const w = firstWord(text);
    return std.ascii.eqlIgnoreCase(w, "jmp") or std.ascii.eqlIgnoreCase(w, "ret");
}

/// Whether the last of `items` is `jmp back`.
fn endsWithJump(items: []const Item, back: ?[]const u8) bool {
    const b = back orelse return false;
    if (items.len == 0) return false;
    const last = items[items.len - 1];
    return last == .code and isJumpTo(last.code, b);
}

fn isJumpTo(text: []const u8, target: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, text, " \t");
    const mnemonic = it.next() orelse return false;
    if (!std.ascii.eqlIgnoreCase(mnemonic, "jmp")) return false;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, it.rest(), " \t"), target);
}

/// How many times the code goes to `back`, conditionally or not.
fn countJumps(segments: []const Segment, back: ?[]const u8) usize {
    const b = back orelse return 0;
    var n: usize = 0;
    for (segments) |s| for (s.items) |it| {
        if (it != .code) continue;
        var words = Words{ .text = it.code };
        while (words.next()) |w| if (std.ascii.eqlIgnoreCase(w, b)) {
            n += 1;
        };
    };
    return n;
}

/// CE's `db` bytes.
fn rawBytes(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const t = std.mem.trim(u8, text, " \t");
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, t[2..], " \t,");
    while (it.next()) |token| {
        const n = numbers.parse(token) orelse return error.InvalidNumber;
        if (n < 0 or n > 255) return error.InvalidNumber;
        try out.append(arena, @intCast(n));
    }
    if (out.items.len == 0) return error.InvalidNumber;
    return out.items;
}

fn hexBytes(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (bytes, 0..) |b, k| try out.print(arena, "{s}{X:0>2}", .{ if (k == 0) "" else " ", b });
    return out.items;
}

fn dbLine(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "db");
    for (bytes, 0..) |b, k| try out.print(arena, "{s}0x{X:0>2}", .{ if (k == 0) " " else ", ", b });
    return out.items;
}

/// Our number text, `0x` hex or decimal.
fn parseOurs(text: []const u8) ?f64 {
    var t = text;
    var negative = false;
    if (t.len > 0 and t[0] == '-') {
        negative = true;
        t = t[1..];
    }
    const v: f64 = if (std.ascii.startsWithIgnoreCase(t, "0x"))
        @floatFromInt(std.fmt.parseInt(u64, t[2..], 16) catch return null)
    else
        std.fmt.parseFloat(f64, t) catch return null;
    return if (negative) -v else v;
}

/// `name+0x10` to its parts. A bare number has no name.
fn splitOffset(where: []const u8) struct { name: []const u8, offset: u64 } {
    var depth: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i < where.len) : (i += 1) {
        const ch = where[i];
        if (ch == '"') quoted = !quoted;
        if (quoted) continue;
        switch (ch) {
            '[', '(' => depth += 1,
            ']', ')' => depth -|= 1,
            '+', '-' => if (depth == 0 and i > 0) {
                const name = std.mem.trim(u8, where[0..i], " \t\"");
                const rest = std.mem.trim(u8, where[i + 1 ..], " \t");
                const n = parseOurs(rest) orelse return .{ .name = "", .offset = 0 };
                const v: u64 = @intFromFloat(@abs(n));
                return .{ .name = name, .offset = if (ch == '-') 0 -% v else v };
            },
            else => {},
        }
    }
    return .{ .name = std.mem.trim(u8, where, " \t\""), .offset = 0 };
}
