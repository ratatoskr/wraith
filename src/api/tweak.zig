//! `.rwt` tweaks: `@kind` sections in asm, `.sal` or the tweak's JS or Lua, compiled line for line.
//! A `@group` or several `@tweak`s make a group; groups nest, and parts go by path like `Combat/Max bravery`.

const std = @import("std");

const input = @import("wraith_platform").input;
const Message = @import("tuft_text").Message;

pub const Kind = enum {
    /// `@group "Combat"`, at the top of a group's file, or opening one in it.
    group,
    /// `@children on off`, right after a `@group`. What its box does to what's in it.
    children,
    /// `@use ce`, a script library before a shared part's or lone tweak's code. Runs its `install(env, options)`.
    use,
    /// `@globals shared`, in a group's shared part: plain global writes in the group land in its top level.
    globals,
    /// Closes the innermost `@group` that isn't the file's.
    end,
    /// `@tweak "Infinite health"`, what it shows as.
    tweak,
    /// `@key Ctrl+F8`, the key it suggests.
    key,
    /// `@mode toggle` or `@mode action`.
    mode,
    /// Values asm and scripts use by name, edited in the UI.
    data,
    /// `@sym name = where`, a named address.
    sym,
    /// Code that replaces the code there, the instruction unless `(n)` or `expect` says how much.
    patch,
    /// Bytes over the code there.
    bytes,
    /// Code before the instruction there, which runs after it.
    inject,
    /// `@hook where as i32 (i32 a, f32 b)`, script in place of a function, with `original(a, b)`.
    hook,
    /// Types in `.sal`, as `types` in scripts.
    schema,
    js,
    lua,

    fn hasBody(self: Kind) bool {
        return switch (self) {
            .group, .children, .use, .globals, .end, .tweak, .key, .mode, .sym => false,
            else => true,
        };
    }

    /// The lines that say what a part is, which `@use` and `@globals` can come after.
    fn isHeading(self: Kind) bool {
        return switch (self) {
            .group, .children, .use, .globals, .tweak, .key, .mode => true,
            else => false,
        };
    }

    /// Code that can be asm or script, by an `@asm`, `@js` or `@lua` first line.
    fn hasCode(self: Kind) bool {
        return self == .patch or self == .inject or self == .hook;
    }
};

/// What a `patch`, `inject` or `hook`'s lines are.
pub const Lang = enum { @"asm", js, lua };

/// What a tweak's script parts are in, and which provider runs it.
pub const Script = enum {
    js,
    lua,

    fn of(l: Lang) ?Script {
        return switch (l) {
            .@"asm" => null,
            .js => .js,
            .lua => .lua,
        };
    }

    fn lang(self: Script) Lang {
        return switch (self) {
            .js => .js,
            .lua => .lua,
        };
    }
};

pub const Mode = enum {
    /// On until it's turned off.
    toggle,
    /// Runs once, then everything it did goes back.
    action,
};

pub const Section = struct {
    kind: Kind,
    /// The `@` line, from 1.
    line: u32,
    /// Index of the first line under it, from 0.
    first: u32,
    /// Lines under it.
    count: u32,
    /// For `sym`, `data`, `patch`, `bytes`, `inject` and `hook`. `data`'s is where to be near.
    where: []const u8 = "",
    /// What `patch` and `bytes` expect there, a byte pattern or asm like `cmp ecx, eax; jl 0x1234`.
    expect: []const u8 = "",
    /// Bytes a `patch` replaces, from `(n)`. 0 is what `expect` covers, or else the instruction there.
    size: u32 = 0,
    /// For `sym`.
    name: []const u8 = "",
    /// For `data`, into `Tweak.fields`.
    fields: struct { start: u32 = 0, len: u32 = 0 } = .{},
    /// What a `patch`, `inject` or `hook`'s lines are.
    lang: Lang = .@"asm",
    /// The `@asm`, `@js` or `@lua` line saying so, an index like `first`.
    marker: ?u32 = null,
    /// A `hook`'s, like `i32 (i32 a, f32 b)`.
    signature: []const u8 = "",
    /// A `hook`'s param names, for its code.
    params: []const []const u8 = &.{},

    /// Has `template` text, compiled to a string.
    fn template(self: Section) bool {
        return switch (self.kind) {
            .bytes, .schema => true,
            .patch, .inject => self.lang == .@"asm",
            else => false,
        };
    }

    fn isMarker(self: Section, at: usize) bool {
        const m = self.marker orelse return false;
        return m == at;
    }
};

pub const Type = enum {
    u8,
    u16,
    u32,
    u64,
    i8,
    i16,
    i32,
    i64,
    f32,
    f64,
    bool,

    pub fn size(self: Type) u8 {
        return switch (self) {
            .u8, .i8, .bool => 1,
            .u16, .i16 => 2,
            .u32, .i32, .f32 => 4,
            .u64, .i64, .f64 => 8,
        };
    }

    pub fn isFloat(self: Type) bool {
        return self == .f32 or self == .f64;
    }

    pub fn isSigned(self: Type) bool {
        return switch (self) {
            .i8, .i16, .i32, .i64, .f32, .f64 => true,
            else => false,
        };
    }
};

pub const Choice = struct {
    value: f64,
    label: []const u8,
};

pub const Field = struct {
    name: []const u8,
    type: Type,
    value: f64 = 0,
    /// From `Label("...")`, else the name.
    label: []const u8 = "",
    line: u32 = 0,
    /// `Toggle`, a checkbox for 0 and 1.
    toggle: bool = false,
    /// `Hex`, shown in hex.
    hex: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    /// `Key(F8)` flips a `Toggle`.
    key: ?input.Chord = null,
    /// `Choices(items)`, a function in the tweak's script that lists them once it's on.
    choices_fn: ?[]const u8 = null,
    /// `Choices("0:None", "1:Potion")`.
    choices: []const Choice = &.{},
};

pub const Tweak = struct {
    /// From `@tweak`, or a group's `@group`.
    title: ?[]const u8 = null,
    key: ?input.Chord = null,
    mode: Mode = .toggle,
    /// Lua if it has any `@lua`, else JS, even with no script at all.
    script: Script = .js,
    sections: []const Section = &.{},
    fields: []const Field = &.{},
    /// For a group's tweak, the index in `File.groups` of the group it's in.
    group: u32 = 0,
    /// For a group's tweak, its titles from the file's group down, joined by `/`.
    path: []const u8 = "",
    /// Its `@use`s, in order.
    uses: []const Use = &.{},
    /// A group's tweak's `@tweak` line. 0 for a file that's one tweak.
    line: u32 = 0,

    pub fn field(self: Tweak, name: []const u8) ?*const Field {
        for (self.fields) |*f| if (std.mem.eql(u8, f.name, name)) return f;
        return null;
    }
};

/// A `@use name` line.
pub const Use = struct {
    name: []const u8,
    line: u32,
};

/// What a group's own box does to what's in it, from `@children`.
pub const Children = struct {
    /// Turning the group on turns them on.
    on: bool = true,
    /// Turning it off turns them off.
    off: bool = true,
};

/// A file's group, or one nested in it.
pub const Group = struct {
    /// From `@group`. Only the file's can go without, and then it goes by the file's name.
    title: ?[]const u8 = null,
    /// Its `@group` line, 0 for a file's without one.
    line: u32 = 0,
    /// Its `@end` line. 0 for the file's, which has none.
    end: u32 = 0,
    /// The index in `File.groups` of the group it's in. Null for the file's.
    parent: ?u32 = null,
    children: Children = .{},
    /// `@globals shared`, so plain global writes from what's in it land in its top level.
    shares_globals: bool = false,
    /// Its part before its first `@tweak` or `@group`.
    shared: Tweak = .{},
    /// Its titles from the file's group down, joined by `/`. Empty for the file's.
    path: []const u8 = "",
};

/// A whole `.rwt` file, one tweak or a group of them.
pub const File = struct {
    /// From `@group`. A group without one goes by its file's name.
    group: ?[]const u8 = null,
    /// It has a `@group` or more than one `@tweak`.
    grouped: bool = false,
    script: Script = .js,
    /// A group's part before its first `@tweak`, the same as `groups[0].shared`.
    shared: Tweak = .{},
    /// The whole file for a lone tweak, else all of a group's in file order.
    tweaks: []const Tweak = &.{},
    /// A group's, the file's own first, then nested ones in the order they open.
    groups: []const Group = &.{},

    /// The index of the `@tweak` at `path`, which for the file's own tweaks is the title.
    pub fn find(self: File, path: []const u8) ?usize {
        for (self.tweaks, 0..) |t, i| if (std.mem.eql(u8, t.path, path)) return i;
        return null;
    }

    /// A group's tweak or group by its path. Empty is the file's group.
    pub fn resolve(self: File, path: []const u8) ?Part {
        if (!self.grouped) return null;
        if (path.len == 0) return .{ .group = 0 };
        if (self.find(path)) |i| return .{ .tweak = i };
        for (self.groups[1..], 1..) |g, i| if (std.mem.eql(u8, g.path, path)) return .{ .group = i };
        return null;
    }

    /// The group a part is in, null for the file's group or a lone tweak.
    pub fn parentOf(self: File, part: Part) ?usize {
        return switch (part) {
            .whole => null,
            .group => |g| if (self.groups[g].parent) |p| p else null,
            .tweak => |i| self.tweaks[i].group,
        };
    }

    /// The nearest group that says `@globals shared`, a group part's own included.
    pub fn sharerOf(self: File, part: Part) ?usize {
        var at: ?usize = switch (part) {
            .whole => return null,
            .group => |g| g,
            .tweak => |i| self.tweaks[i].group,
        };
        while (at) |g| {
            if (self.groups[g].shares_globals) return g;
            at = if (self.groups[g].parent) |p| p else null;
        }
        return null;
    }

    pub fn pathOf(self: File, part: Part) []const u8 {
        return switch (part) {
            .whole => "",
            .group => |g| self.groups[g].path,
            .tweak => |i| self.tweaks[i].path,
        };
    }
};

/// What of a file to run.
pub const Part = union(enum) {
    /// A file that's one tweak.
    whole,
    /// A group's shared part, by index in `File.groups`. 0 is the file's.
    group: usize,
    /// One of a group's tweaks, by index.
    tweak: usize,
};

pub const Problem = struct {
    line: u32 = 0,
    text: Message(256) = .{},

    pub fn message(self: *const Problem) []const u8 {
        return self.text.message();
    }

    fn fail(self: *Problem, line: u32, comptime format: []const u8, args: anytype) error{Invalid} {
        self.line = line;
        self.text.print(format, args);
        return error.Invalid;
    }
};

pub const Error = error{ OutOfMemory, Invalid };

/// Names asm and scripts already use.
const reserved = [_][]const u8{ "original", "resume", "data", "sym", "types", "tick", "off" };

/// The file as one tweak, as it was before groups. Everything points into `source` or `arena`.
pub fn parse(arena: std.mem.Allocator, source: []const u8, problem: *Problem) Error!Tweak {
    const lines = try splitLines(arena, source);
    var ctx: Context = .{};
    var tweak = try parsePart(arena, lines, 0, lines.len, .whole, &ctx, problem);
    ctx.finish(&tweak);
    return tweak;
}

/// The file, a group or one tweak. Everything points into `source` or `arena`.
pub fn parseFile(arena: std.mem.Allocator, source: []const u8, problem: *Problem) Error!File {
    const lines = try splitLines(arena, source);
    var tweak_count: usize = 0;
    var grouped = false;
    for (lines) |l| if (isHeader(l)) {
        const word = l[1..identEnd(l, 1)];
        if (std.mem.eql(u8, word, "tweak")) tweak_count += 1;
        if (std.mem.eql(u8, word, "group")) grouped = true;
    };
    if (!grouped and tweak_count < 2) {
        const one = try arena.alloc(Tweak, 1);
        one[0] = try parse(arena, source, problem);
        return .{ .script = one[0].script, .tweaks = one };
    }

    // Where each part's lines are, in file order. A group's runs to its first child
    const Span = struct { from: usize, to: usize = 0, group: bool, index: u32 };
    var groups: std.ArrayList(Group) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var open: std.ArrayList(u32) = .empty;
    try groups.append(arena, .{});
    try open.append(arena, 0);
    try spans.append(arena, .{ .from = 0, .group = true, .index = 0 });
    // The span lines go to, null between an `@end` and what comes next
    var current: ?usize = 0;
    var ended_at: usize = 0;
    var first_header = true;
    var top_group = false;
    for (lines, 0..) |l, i| {
        if (!isHeader(l)) continue;
        const word = l[1..identEnd(l, 1)];
        const number: u32 = @intCast(i + 1);
        const is_group = std.mem.eql(u8, word, "group");
        const at_top = first_header;
        first_header = false;
        // The file's own, which needs no @end
        if (is_group and at_top) {
            top_group = true;
            continue;
        }
        const is_tweak = std.mem.eql(u8, word, "tweak");
        const is_end = std.mem.eql(u8, word, "end");
        if (!is_group and !is_tweak and !is_end) {
            if (current == null) return problem.fail(number, "after @end comes a @tweak, a @group or another @end", .{});
            continue;
        }
        if (current) |c| spans.items[c].to = i else try checkAfterEnd(lines, ended_at, i, problem);
        if (is_end) {
            if (open.items.len == 1) return problem.fail(number, "{s}", .{if (top_group)
                "there's no @group open for this @end. The one at the top of the file needs none"
            else
                "there's no @group open for this @end"});
            groups.items[open.pop().?].end = number;
            current = null;
            ended_at = i + 1;
            continue;
        }
        const parent = open.items[open.items.len - 1];
        if (is_group) {
            const g: u32 = @intCast(groups.items.len);
            try groups.append(arena, .{ .parent = parent, .line = number });
            try open.append(arena, g);
            try spans.append(arena, .{ .from = i, .group = true, .index = g });
        } else try spans.append(arena, .{ .from = i, .group = false, .index = parent });
        current = spans.items.len - 1;
    }
    if (current) |c| spans.items[c].to = lines.len else try checkAfterEnd(lines, ended_at, lines.len, problem);
    if (open.items.len > 1) {
        const g = groups.items[open.items[open.items.len - 1]];
        return problem.fail(@intCast(lines.len), "@group \"{s}\" from line {d} needs an @end", .{ unquote(headerArgs(lines[g.line - 1])), g.line });
    }

    var ctx: Context = .{ .grouped = true, .groups = groups.items };
    var tweaks: std.ArrayList(Tweak) = .empty;
    const nested = groups.items.len > 1;
    for (spans.items) |s| {
        if (s.group) {
            const g = &groups.items[s.index];
            ctx.parent = g.parent;
            ctx.children = .{};
            ctx.shares_globals = false;
            g.shared = try parsePart(arena, lines, s.from, s.to, if (s.index == 0) .shared else .group, &ctx, problem);
            g.children = ctx.children;
            g.shares_globals = ctx.shares_globals;
            if (s.index == 0) {
                g.title = ctx.group;
                g.line = if (top_group) ctx.group_line else 0;
                continue;
            }
            g.title = g.shared.title;
            g.path = try joinPath(arena, groups.items[g.parent.?].path, g.title.?);
            try checkSibling(groups.items, tweaks.items, g.parent.?, g.title.?, g.line, nested, problem);
            continue;
        }
        ctx.parent = s.index;
        var t = try parsePart(arena, lines, s.from, s.to, .tweak, &ctx, problem);
        t.group = s.index;
        t.line = @intCast(s.from + 1);
        t.path = try joinPath(arena, groups.items[s.index].path, t.title.?);
        try checkSibling(groups.items, tweaks.items, s.index, t.title.?, @intCast(s.from + 1), nested, problem);
        try tweaks.append(arena, t);
    }
    // Every group has something in it
    for (groups.items, 0..) |g, k| {
        const has = for (tweaks.items) |t| {
            if (t.group == k) break true;
        } else for (groups.items) |other| {
            if (other.parent != null and other.parent.? == k) break true;
        } else false;
        if (has) continue;
        if (k == 0) return problem.fail(ctx.group_line, "a group needs a @tweak under the shared part", .{});
        return problem.fail(g.line, "@group \"{s}\" needs a @tweak or @group in it", .{g.title.?});
    }
    for (groups.items) |*g| ctx.finish(&g.shared);
    for (tweaks.items) |*t| ctx.finish(t);
    return .{
        .grouped = true,
        .group = groups.items[0].title,
        .script = groups.items[0].shared.script,
        .shared = groups.items[0].shared,
        .tweaks = tweaks.items,
        .groups = groups.items,
    };
}

/// `source` without the tweak or nested group (`@group` to `@end`) at `path`. Fails if what's left isn't valid.
pub fn removePart(gpa: std.mem.Allocator, source: []const u8, path: []const u8, problem: *Problem) Error![]u8 {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const file = try parseFile(arena, source, problem);
    const part = (if (path.len > 0) file.resolve(path) else null) orelse return problem.fail(0, "there's no \"{s}\" in it", .{path});
    const lines = try splitLines(arena, source);
    const from: usize, const to: usize = switch (part) {
        .whole => unreachable,
        .group => |g| .{ file.groups[g].line - 1, file.groups[g].end },
        .tweak => |i| blk: {
            const at = file.tweaks[i].line - 1;
            var next = at + 1;
            while (next < lines.len) : (next += 1) if (isHeader(lines[next])) {
                const word = lines[next][1..identEnd(lines[next], 1)];
                if (std.mem.eql(u8, word, "tweak") or std.mem.eql(u8, word, "group") or std.mem.eql(u8, word, "end")) break;
            };
            break :blk .{ at, next };
        },
    };
    const start = lines[from].ptr - source.ptr;
    const stop = if (to < lines.len) lines[to].ptr - source.ptr else source.len;
    const out = try std.mem.concat(gpa, u8, &.{ source[0..start], source[stop..] });
    errdefer gpa.free(out);
    _ = try parseFile(arena, out, problem);
    return out;
}

/// Lines between an `@end` and what comes next can only be blank or comments.
fn checkAfterEnd(lines: []const []const u8, from: usize, to: usize, problem: *Problem) error{Invalid}!void {
    for (lines[from..to], from + 1..) |l, n| {
        if (!isBlankOrComment(l)) return problem.fail(@intCast(n), "after @end comes a @tweak, a @group or another @end", .{});
    }
}

/// A tweak or group's title can't be one an earlier sibling has.
fn checkSibling(groups: []const Group, tweaks: []const Tweak, parent: u32, title: []const u8, line: u32, nested: bool, problem: *Problem) error{Invalid}!void {
    // Paths are joined by it
    if (nested and std.mem.indexOfScalar(u8, title, '/') != null) return problem.fail(line, "a title can't have / in a file with groups in it", .{});
    for (tweaks) |t| if (t.group == parent and std.mem.eql(u8, t.title.?, title))
        return problem.fail(line, "there's already a @tweak \"{s}\" in this group", .{title});
    for (groups) |g| if (g.line < line and g.parent == parent and std.mem.eql(u8, g.title orelse "", title))
        return problem.fail(line, "there's already a @group \"{s}\" in this group", .{title});
}

fn joinPath(arena: std.mem.Allocator, parent: []const u8, title: []const u8) ![]const u8 {
    if (parent.len == 0) return title;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ parent, title });
}

/// What's after `@word` on a header line.
fn headerArgs(line: []const u8) []const u8 {
    return std.mem.trim(u8, withoutComment(line[identEnd(line, 1)..]), " \t");
}

/// Letters, digits, `_`, `-` and `.`, like the runtime's library names.
fn validLibraryName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    return true;
}

/// What part of a file it's parsing. `shared` is the file group's, `group` a nested one's.
const Role = enum { whole, shared, group, tweak };

/// What a file's parts share while it's parsed.
const Context = struct {
    grouped: bool = false,
    /// The first line that said what the script is.
    script: ?struct { script: Script, line: u32 } = null,
    group: ?[]const u8 = null,
    group_line: u32 = 1,
    /// The file's groups, whose names what's in them can't take again.
    groups: []const Group = &.{},
    /// The group the part being parsed is in.
    parent: ?u32 = null,
    /// A group's `@children`, while its shared part is parsed.
    children: Children = .{},
    /// A group's `@globals shared`, while its shared part is parsed.
    shares_globals: bool = false,

    /// Once every part's parsed, since a hook's code is the file's script.
    fn finish(self: *const Context, tweak: *Tweak) void {
        if (self.script) |s| tweak.script = s.script;
        const sections: []Section = @constCast(tweak.sections);
        for (sections) |*s| if (s.kind == .hook) {
            s.lang = tweak.script.lang();
        };
    }
};

/// Lines `from` to `to`. A group's tweak starts at its `@tweak`, and a nested group at its `@group`.
fn parsePart(arena: std.mem.Allocator, lines: []const []const u8, from: usize, to: usize, role: Role, ctx: *Context, problem: *Problem) Error!Tweak {
    var sections: std.ArrayList(Section) = .empty;
    var fields: std.ArrayList(Field) = .empty;
    var syms: std.ArrayList([]const u8) = .empty;
    var use_list: std.ArrayList(Use) = .empty;
    var tweak: Tweak = .{};
    var seen: std.EnumSet(Kind) = .empty;
    const whole_or_group: []const u8 = if (ctx.grouped) "a group" else "a tweak";
    const is_group = role == .shared or role == .group;

    var i: usize = from;
    while (i < to) {
        const text = lines[i];
        const number: u32 = @intCast(i + 1);
        if (!isHeader(text)) {
            if (sections.items.len == 0 and !isBlankOrComment(text)) return problem.fail(number, "put this under a section, like @js", .{});
            i += 1;
            continue;
        }
        const word_end = identEnd(text, 1);
        const word = text[1..word_end];
        const kind = std.meta.stringToEnum(Kind, word) orelse
            return problem.fail(number, "there's no @{s}. It's @group, @children, @use, @globals, @end, @tweak, @key, @mode, @data, @sym, @patch, @bytes, @inject, @hook, @schema, @js or @lua", .{word});
        const args = std.mem.trim(u8, withoutComment(text[word_end..]), " \t");
        var end = i + 1;
        while (end < to and !isHeader(lines[end])) end += 1;
        var section: Section = .{ .kind = kind, .line = number, .first = @intCast(i + 1), .count = @intCast(end - i - 1) };

        if (!kind.hasBody()) for (lines[i + 1 .. end], i + 2..) |l, n| {
            if (!isBlankOrComment(l)) return problem.fail(@intCast(n), "@{s} has nothing under it. Start a section first, like @js", .{word});
        };
        // `@js` in column 0 starts a section of its own, which is easy to do by mistake
        if ((kind == .js or kind == .lua) and sections.items.len > 0) {
            const last = sections.items[sections.items.len - 1];
            if (last.kind.hasCode() and last.marker == null and isEmptyCode(lines[last.first..][0..last.count]))
                return problem.fail(number, "the @{t} above has no code. Indent this @{t} to make it the @{t}'s", .{ last.kind, kind, last.kind });
        }
        try findMarker(&section, lines, problem);
        const uses: ?struct { Script, u32 } = switch (kind) {
            .js => .{ .js, number },
            .lua => .{ .lua, number },
            else => if (section.marker) |m| if (Script.of(section.lang)) |s| .{ s, m + 1 } else null else null,
        };
        if (uses) |u| {
            if (ctx.script) |s| {
                if (s.script != u[0]) return problem.fail(u[1], "{s} is all JS or all Lua, and line {d} already has @{t}", .{ whole_or_group, s.line, s.script });
            } else ctx.script = .{ .script = u[0], .line = u[1] };
        }
        switch (kind) {
            .group => {
                if (role == .group and i == from) {
                    if (args.len == 0) return problem.fail(number, "@group needs a name", .{});
                    tweak.title = unquote(args);
                } else {
                    if (role != .shared or sections.items.len > 0) return problem.fail(number, "@group goes at the top of the file, before anything else", .{});
                    if (args.len == 0) return problem.fail(number, "@group needs a name", .{});
                    ctx.group = unquote(args);
                    ctx.group_line = number;
                    tweak.title = ctx.group;
                }
            },
            .children => {
                const right_after = is_group and sections.items.len == 1 and sections.items[0].kind == .group and !seen.contains(.children);
                if (!right_after) return problem.fail(number, "@children goes right after a @group line", .{});
                seen.insert(.children);
                ctx.children = parseChildren(args) orelse return problem.fail(number, "@children is on off, on, off or none", .{});
            },
            .use => {
                if (role == .tweak) return problem.fail(number, "@use goes in a group's shared part, where everything in the group gets it", .{});
                for (sections.items) |s| if (!s.kind.isHeading()) return problem.fail(number, "@use goes before the code, right under the @{s}", .{if (is_group) "group" else "tweak"});
                const name = unquote(args);
                if (name.len == 0) return problem.fail(number, "@use needs a library's name, like @use ce", .{});
                if (!validLibraryName(name)) return problem.fail(number, "`{s}` isn't a library's name. Use letters, digits, _, - and .", .{name});
                for (use_list.items) |u| if (std.mem.eql(u8, u.name, name)) return problem.fail(number, "there's already a @use {s} on line {d}", .{ name, u.line });
                try use_list.append(arena, .{ .name = name, .line = number });
            },
            .globals => {
                if (!is_group) return problem.fail(number, "@globals goes in a group's shared part, above its first @tweak", .{});
                for (sections.items) |s| {
                    if (s.kind == .globals) return problem.fail(number, "there's already a @globals on line {d}", .{s.line});
                    if (!s.kind.isHeading()) return problem.fail(number, "@globals goes before the code, right under the @group", .{});
                }
                if (!std.mem.eql(u8, args, "shared")) return problem.fail(number, "@globals is shared, like @globals shared", .{});
                ctx.shares_globals = true;
            },
            .end => return problem.fail(number, "there's no @group open for this @end", .{}),
            .tweak, .key, .mode => {
                // A group's key turns its own box on and off
                if (is_group and kind != .key) return problem.fail(number, "@{s} goes under a @tweak. The shared part above them has none", .{word});
                if (seen.contains(kind)) return problem.fail(number, "there's already a @{s}", .{word});
                seen.insert(kind);
                if (args.len == 0) return problem.fail(number, "@{s} needs a value", .{word});
                switch (kind) {
                    .tweak => tweak.title = unquote(args),
                    .key => tweak.key = parseChord(unquote(args)) orelse return problem.fail(number, "`{s}` isn't a key, like F8 or Ctrl+Shift+K", .{args}),
                    .mode => tweak.mode = std.meta.stringToEnum(Mode, args) orelse return problem.fail(number, "@mode is toggle or action", .{}),
                    else => unreachable,
                }
            },
            .sym => {
                const eq = std.mem.indexOfScalar(u8, args, '=') orelse return problem.fail(number, "it's @sym name = where", .{});
                const name = std.mem.trim(u8, args[0..eq], " \t");
                try checkName(name, number, fields.items, syms.items, problem);
                try checkShared(name, number, ctx, problem);
                section.name = name;
                section.where = std.mem.trim(u8, args[eq + 1 ..], " \t");
                if (section.where.len == 0) return problem.fail(number, "@sym {s} needs a where after the =", .{name});
                try syms.append(arena, name);
            },
            .data => {
                section.where = if (std.mem.startsWith(u8, args, "near ")) std.mem.trim(u8, args[5..], " \t") else args;
                section.fields.start = @intCast(fields.items.len);
                for (lines[i + 1 .. end], i + 2..) |l, n| {
                    const f = try parseField(arena, l, @intCast(n), problem) orelse continue;
                    try checkName(f.name, f.line, fields.items, syms.items, problem);
                    try checkShared(f.name, f.line, ctx, problem);
                    try fields.append(arena, f);
                }
                section.fields.len = @intCast(fields.items.len - section.fields.start);
            },
            .patch, .bytes, .inject => {
                const split = splitExpect(args);
                if (kind == .inject and split.expect.len > 0) return problem.fail(number, "expect goes on @patch, which replaces code. @inject puts code before the instruction there", .{});
                const sized = splitSize(split.where);
                if (sized.size) |size_text| {
                    if (kind != .patch) return problem.fail(number, "only @patch takes a size, for the bytes it replaces", .{});
                    const n = parseNumber(size_text) orelse 0;
                    if (n < 1 or n > 4096 or @floor(n) != n) return problem.fail(number, "the size is the bytes it replaces, like (5)", .{});
                    section.size = @intFromFloat(n);
                }
                section.where = sized.where;
                section.expect = split.expect;
                if (section.where.len == 0) return problem.fail(number, "@{s} needs a where, like @{s} game.exe+0x1234 or @{s} sig(\"48 8B ??\")", .{ word, word, word });
            },
            .hook => {
                const at = findWord(args, "as") orelse
                    return problem.fail(number, "@hook needs a signature, like @hook game.exe+0x10 as i32 (i32 a, f32 b)", .{});
                section.where = std.mem.trim(u8, args[0..at], " \t");
                section.signature = std.mem.trim(u8, args[at + 2 ..], " \t");
                if (section.where.len == 0) return problem.fail(number, "@hook needs a where before the as", .{});
                section.params = try paramNames(arena, section.signature, number, problem);
            },
            .schema, .js, .lua => if (args.len > 0) return problem.fail(number, "@{s} takes nothing after it", .{word}),
        }
        try sections.append(arena, section);
        i = end;
    }
    tweak.sections = sections.items;
    tweak.fields = fields.items;
    tweak.uses = use_list.items;
    return tweak;
}

/// What's in a group can't take a name its groups' shared parts have.
fn checkShared(name: []const u8, line: u32, ctx: *const Context, problem: *Problem) error{Invalid}!void {
    var at = ctx.parent;
    while (at) |k| : (at = ctx.groups[k].parent) {
        const g = ctx.groups[k];
        const taken = g.shared.field(name) != null or for (g.shared.sections) |s| {
            if (s.kind == .sym and std.mem.eql(u8, s.name, name)) break true;
        } else false;
        if (!taken) continue;
        if (k == 0) return problem.fail(line, "the shared part already has a {s}", .{name});
        return problem.fail(line, "@group \"{s}\" already has a {s}", .{ g.title orelse "", name });
    }
}

/// `on off`, `on`, `off` or `none`, in any order.
fn parseChildren(args: []const u8) ?Children {
    var c: Children = .{ .on = false, .off = false };
    var it = std.mem.tokenizeAny(u8, args, " \t");
    var count: usize = 0;
    while (it.next()) |word| : (count += 1) {
        if (std.mem.eql(u8, word, "on") and !c.on) {
            c.on = true;
        } else if (std.mem.eql(u8, word, "off") and !c.off) {
            c.off = true;
        } else if (std.mem.eql(u8, word, "none") and count == 0 and it.peek() == null) {
            return c;
        } else return null;
    }
    return if (count == 0) null else c;
}

/// Blank, or `//` comments.
fn isEmptyCode(lines: []const []const u8) bool {
    for (lines) |l| {
        const t = std.mem.trim(u8, withoutComment(l), " \t");
        if (t.len > 0) return false;
    }
    return true;
}

/// A `patch`, `inject` or `hook`'s language from an `@asm`, `@js` or `@lua` first line, else asm (script for `hook`).
fn findMarker(section: *Section, lines: []const []const u8, problem: *Problem) error{Invalid}!void {
    var seen_code = false;
    for (lines[section.first..][0..section.count], section.first..) |l, at| {
        const t = std.mem.trim(u8, withoutComment(l), " \t");
        if (t.len == 0 or std.mem.startsWith(u8, t, "--")) continue;
        const lang = std.meta.stringToEnum(Lang, if (t[0] == '@') t[1..] else "") orelse {
            seen_code = true;
            continue;
        };
        const n: u32 = @intCast(at + 1);
        if (!section.kind.hasCode()) return problem.fail(n, "only @patch, @inject and @hook take @{t}", .{lang});
        if (seen_code) return problem.fail(n, "@{t} goes on the first line of the @{t}", .{ lang, section.kind });
        if (section.kind == .hook and lang == .@"asm") return problem.fail(n, "a @hook's code is JS or Lua. Use @patch or @inject for asm", .{});
        section.lang = lang;
        section.marker = @intCast(at);
        seen_code = true;
    }
}

/// `word` alone, outside quotes and brackets, like `as` in `@hook x as i32 (i32 a)`.
fn findWord(args: []const u8, word: []const u8) ?usize {
    var depth: usize = 0;
    var quoted = false;
    for (args, 0..) |ch, i| {
        if (ch == '"') quoted = !quoted;
        if (quoted) continue;
        switch (ch) {
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            else => {},
        }
        if (depth != 0 or i == 0 or (args[i - 1] != ' ' and args[i - 1] != '\t')) continue;
        if (std.mem.startsWith(u8, args[i..], word) and identEnd(args, i) == i + word.len) return i;
    }
    return null;
}

/// A hook's param names. Unnamed ones are `arg1` and on, and `this` is `self` since JS has its own.
fn paramNames(arena: std.mem.Allocator, signature: []const u8, line: u32, problem: *Problem) Error![]const []const u8 {
    const usage = "a signature has its params in ( ), like i32 (i32 a, f32 b)";
    const close = std.mem.lastIndexOfScalar(u8, signature, ')') orelse return problem.fail(line, usage, .{});
    var depth: usize = 0;
    var k = close + 1;
    const open = while (k > 0) {
        k -= 1;
        switch (signature[k]) {
            ')' => depth += 1,
            '(' => {
                depth -= 1;
                if (depth == 0) break k;
            },
            else => {},
        }
    } else return problem.fail(line, usage, .{});
    var names: std.ArrayList([]const u8) = .empty;
    var start = open + 1;
    depth = 0;
    for (signature[open + 1 .. close + 1], open + 1..) |ch, i| {
        switch (ch) {
            '(', '[' => depth += 1,
            ']' => depth -|= 1,
            ')' => if (i != close) {
                depth -|= 1;
            },
            else => {},
        }
        if (!((ch == ',' and depth == 0) or i == close)) continue;
        const p = std.mem.trim(u8, signature[start..i], " \t");
        start = i + 1;
        if (p.len == 0 or (std.mem.eql(u8, p, "void") and names.items.len == 0 and i == close)) continue;
        var name_start = p.len;
        while (name_start > 0 and (std.ascii.isAlphanumeric(p[name_start - 1]) or p[name_start - 1] == '_')) name_start -= 1;
        const ident = p[name_start..];
        const named = ident.len > 0 and !std.ascii.isDigit(ident[0]) and std.mem.trim(u8, p[0..name_start], " \t").len > 0;
        var name: []const u8 = if (named) ident else try std.fmt.allocPrint(arena, "arg{d}", .{names.items.len + 1});
        if (std.mem.eql(u8, name, "this")) name = "self";
        for ([_][]const u8{ "original", "cpu", "resume" }) |taken| {
            if (std.mem.eql(u8, name, taken)) return problem.fail(line, "a param can't be called {s}, the code uses that", .{taken});
        }
        try names.append(arena, name);
    }
    return names.items;
}

fn checkName(name: []const u8, line: u32, fields: []const Field, syms: []const []const u8, problem: *Problem) error{Invalid}!void {
    if (name.len == 0 or identEnd(name, 0) != name.len or std.ascii.isDigit(name[0])) return problem.fail(line, "`{s}` isn't a name. Use letters, digits and _", .{name});
    for (reserved) |r| if (std.mem.eql(u8, r, name)) return problem.fail(line, "`{s}` is taken, pick another name", .{name});
    for (fields) |f| if (std.mem.eql(u8, f.name, name)) return problem.fail(line, "there's already a {s}", .{name});
    for (syms) |s| if (std.mem.eql(u8, s, name)) return problem.fail(line, "there's already a {s}", .{name});
}

fn splitLines(gpa: std.mem.Allocator, source: []const u8) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    while (it.next()) |l| try lines.append(gpa, std.mem.trimEnd(u8, l, "\r"));
    return lines.toOwnedSlice(gpa);
}

fn isHeader(line: []const u8) bool {
    return line.len > 1 and line[0] == '@' and std.ascii.isAlphabetic(line[1]);
}

fn isBlankOrComment(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    return t.len == 0 or std.mem.startsWith(u8, t, "//");
}

fn identEnd(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '_')) i += 1;
    return i;
}

/// Cuts a `//` comment that isn't in quotes.
fn withoutComment(text: []const u8) []const u8 {
    var quoted = false;
    for (text, 0..) |ch, i| {
        if (ch == '"') quoted = !quoted;
        if (!quoted and ch == '/' and i + 1 < text.len and text[i + 1] == '/') return text[0..i];
    }
    return text;
}

fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return text;
}

/// `where expect "pattern"`, with `expect` outside quotes and brackets.
fn splitExpect(args: []const u8) struct { where: []const u8, expect: []const u8 } {
    var depth: usize = 0;
    var quoted = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const ch = args[i];
        if (ch == '"') quoted = !quoted;
        if (quoted) continue;
        switch (ch) {
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            else => {},
        }
        if (depth != 0 or (i > 0 and args[i - 1] != ' ' and args[i - 1] != '\t')) continue;
        if (!std.mem.startsWith(u8, args[i..], "expect") or identEnd(args, i) != i + 6) continue;
        return .{ .where = std.mem.trim(u8, args[0..i], " \t"), .expect = unquote(std.mem.trim(u8, args[i + 6 ..], " \t")) };
    }
    return .{ .where = args, .expect = "" };
}

/// `where (n)`, with the `(n)` after a space so it's not part of the where, like `sig(...)`.
fn splitSize(text: []const u8) struct { where: []const u8, size: ?[]const u8 } {
    const where = std.mem.trimEnd(u8, text, " \t");
    if (!std.mem.endsWith(u8, where, ")")) return .{ .where = where, .size = null };
    var depth: usize = 0;
    var i = where.len;
    while (i > 0) {
        i -= 1;
        switch (where[i]) {
            ')' => depth += 1,
            '(' => {
                depth -= 1;
                if (depth == 0) break;
            },
            '"' => return .{ .where = where, .size = null },
            else => {},
        }
    }
    if (depth != 0 or i == 0 or (where[i - 1] != ' ' and where[i - 1] != '\t')) return .{ .where = where, .size = null };
    return .{ .where = std.mem.trimEnd(u8, where[0..i], " \t"), .size = std.mem.trim(u8, where[i + 1 .. where.len - 1], " \t") };
}

/// Like `F8`, `ctrl+shift+k`, `Alt+page_up` or `gamepad_back`.
pub fn parseChord(text: []const u8) ?input.Chord {
    var chord: input.Chord = .{ .key = undefined };
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t"), '+');
    var key: ?input.Key = null;
    while (it.next()) |part_raw| {
        if (key != null) return null;
        const part = std.mem.trim(u8, part_raw, " \t");
        var buf: [32]u8 = undefined;
        if (part.len == 0 or part.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, part);
        if (it.peek() != null) {
            if (std.mem.eql(u8, lower, "ctrl")) chord.mods.ctrl = true else if (std.mem.eql(u8, lower, "shift")) chord.mods.shift = true else if (std.mem.eql(u8, lower, "alt")) chord.mods.alt = true else if (std.mem.eql(u8, lower, "super") or std.mem.eql(u8, lower, "win")) chord.mods.super = true else return null;
            continue;
        }
        key = std.meta.stringToEnum(input.Key, lower) orelse return null;
    }
    chord.key = key orelse return null;
    if (!chord.isValid()) return null;
    return chord;
}

const Cursor = struct {
    s: []const u8,
    i: usize = 0,

    fn skip(self: *Cursor) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t')) self.i += 1;
    }

    fn eat(self: *Cursor, ch: u8) bool {
        self.skip();
        if (self.i < self.s.len and self.s[self.i] == ch) {
            self.i += 1;
            return true;
        }
        return false;
    }

    fn peek(self: *Cursor) ?u8 {
        self.skip();
        return if (self.i < self.s.len) self.s[self.i] else null;
    }

    fn ident(self: *Cursor) []const u8 {
        self.skip();
        const start = self.i;
        self.i = identEnd(self.s, self.i);
        return self.s[start..self.i];
    }

    fn string(self: *Cursor) ?[]const u8 {
        if (self.peek() != '"') return null;
        const end = std.mem.indexOfScalarPos(u8, self.s, self.i + 1, '"') orelse return null;
        defer self.i = end + 1;
        return self.s[self.i + 1 .. end];
    }

    /// Up to the `)`, for a bare key.
    fn until(self: *Cursor, ch: u8) []const u8 {
        self.skip();
        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] != ch) self.i += 1;
        return std.mem.trim(u8, self.s[start..self.i], " \t");
    }

    fn number(self: *Cursor) ?f64 {
        self.skip();
        const start = self.i;
        if (self.i < self.s.len and (self.s[self.i] == '-' or self.s[self.i] == '+')) self.i += 1;
        while (self.i < self.s.len and (std.ascii.isAlphanumeric(self.s[self.i]) or self.s[self.i] == '.' or self.s[self.i] == '_')) self.i += 1;
        return parseNumber(self.s[start..self.i]);
    }

    fn done(self: *Cursor) bool {
        self.skip();
        return self.i >= self.s.len;
    }
};

/// Decimal, `0x` or `10h` hex, or `0b` binary, like asm. Also `true` and `false`.
pub fn parseNumber(text: []const u8) ?f64 {
    if (std.mem.eql(u8, text, "true")) return 1;
    if (std.mem.eql(u8, text, "false")) return 0;
    if (text.len == 0) return null;
    const negative = text[0] == '-';
    const digits = if (text[0] == '-' or text[0] == '+') text[1..] else text;
    const base: u8, const rest = if (digits.len > 1 and std.ascii.isDigit(digits[0]) and (digits[digits.len - 1] == 'h' or digits[digits.len - 1] == 'H'))
        .{ 16, digits[0 .. digits.len - 1] }
    else if (std.ascii.startsWithIgnoreCase(digits, "0x"))
        .{ 16, digits[2..] }
    else if (std.ascii.startsWithIgnoreCase(digits, "0b"))
        .{ 2, digits[2..] }
    else
        .{ 10, digits };
    const value: f64 = if (base == 10)
        std.fmt.parseFloat(f64, rest) catch return null
    else
        @floatFromInt(std.fmt.parseInt(u64, rest, base) catch return null);
    return if (negative) -value else value;
}

/// Null for a blank or comment line.
fn parseField(arena: std.mem.Allocator, line: []const u8, number: u32, problem: *Problem) Error!?Field {
    const text = std.mem.trim(u8, withoutComment(line), " \t");
    if (text.len == 0) return null;
    var c: Cursor = .{ .s = text };
    var f: Field = .{ .name = "", .type = .u32, .label = "", .line = number };
    var choices: std.ArrayList(Choice) = .empty;
    while (c.eat('[')) {
        while (true) {
            const attr = c.ident();
            if (attr.len == 0) return problem.fail(number, "expected an attribute, like Label(\"...\"), Toggle, Hex, Min(n), Max(n), Key(F8) or Choices(...)", .{});
            const args = c.eat('(');
            if (std.mem.eql(u8, attr, "Toggle")) {
                f.toggle = true;
            } else if (std.mem.eql(u8, attr, "Hex")) {
                f.hex = true;
            } else if (std.mem.eql(u8, attr, "Label") and args) {
                f.label = c.string() orelse return problem.fail(number, "it's Label(\"text\")", .{});
            } else if ((std.mem.eql(u8, attr, "Min") or std.mem.eql(u8, attr, "Max")) and args) {
                const n = c.number() orelse return problem.fail(number, "{s} takes a number", .{attr});
                if (attr[1] == 'i') f.min = n else f.max = n;
            } else if (std.mem.eql(u8, attr, "Key") and args) {
                const key_text = c.string() orelse c.until(')');
                f.key = parseChord(key_text) orelse return problem.fail(number, "`{s}` isn't a key, like F8 or Ctrl+Shift+K", .{key_text});
            } else if (std.mem.eql(u8, attr, "Choices") and args) {
                if (c.peek() != '"') {
                    const name = c.ident();
                    if (name.len == 0) return problem.fail(number, "it's Choices(function) or Choices(\"1:One\", \"2:Two\")", .{});
                    f.choices_fn = name;
                } else while (true) {
                    const item = c.string() orelse return problem.fail(number, "it's Choices(function) or Choices(\"1:One\", \"2:Two\")", .{});
                    const colon = std.mem.indexOfScalar(u8, item, ':') orelse return problem.fail(number, "`{s}` needs a value first, like \"1:{s}\"", .{ item, item });
                    const value = parseNumber(std.mem.trim(u8, item[0..colon], " ")) orelse return problem.fail(number, "`{s}` isn't a number", .{item[0..colon]});
                    try choices.append(arena, .{ .value = value, .label = item[colon + 1 ..] });
                    if (!c.eat(',')) break;
                }
            } else {
                return problem.fail(number, "there's no attribute {s}{s}. It's Label(\"...\"), Toggle, Hex, Min(n), Max(n), Key(F8) or Choices(...)", .{ attr, if (args) "(...)" else "" });
            }
            if (args and !c.eat(')')) return problem.fail(number, "expected ) after {s}(", .{attr});
            if (c.eat(',')) continue;
            if (!c.eat(']')) return problem.fail(number, "expected ] after the attributes", .{});
            break;
        }
    }
    const type_name = c.ident();
    f.type = std.meta.stringToEnum(Type, type_name) orelse
        return problem.fail(number, "`{s}` isn't a type. It's u8, u16, u32, u64, i8, i16, i32, i64, f32, f64 or bool", .{type_name});
    f.name = c.ident();
    if (f.name.len == 0) return problem.fail(number, "expected a name after {s}", .{type_name});
    if (c.eat('=')) f.value = c.number() orelse return problem.fail(number, "expected a number after =", .{});
    _ = c.eat(';');
    if (!c.done()) return problem.fail(number, "didn't expect `{s}`", .{c.s[c.i..]});
    if (f.key != null and !f.toggle) return problem.fail(number, "Key(...) flips a Toggle, so it needs Toggle too", .{});
    if (f.label.len == 0) f.label = f.name;
    f.choices = choices.items;
    return f;
}

/// A value set in the UI, over the tweak's own.
pub const Value = struct {
    name: []const u8,
    value: f64,
};

/// A JS tweak as JS using the provider's `__t`, line for line plus a last line that turns it on.
pub fn compile(gpa: std.mem.Allocator, source: []const u8, tweak: Tweak, values: []const Value) ![]u8 {
    return compileJs(gpa, source, tweak, values, .{ .done = "__t.done();\n", .title = tweak.title orelse "" });
}

/// One part of a file, compiled for its language. Nested parts run in their own function, with
/// `data`, `sym` and `types` falling back to their group's, and see their groups' scopes.
pub fn compilePart(gpa: std.mem.Allocator, source: []const u8, file: File, part: Part, values: []const Value) ![]u8 {
    if (part == .whole) return if (file.script == .lua) compileLua(gpa, source, file.tweaks[0], values) else compile(gpa, source, file.tweaks[0], values);
    const top_shares = file.groups[0].shares_globals;
    if (part == .group and part.group == 0) return if (file.script == .lua)
        compileLuaWith(gpa, source, file.shared, values, .{ .prefix = if (top_shares) "local _ENV = __t.part(\"\", nil, true) " else "local _ENV = __t.part(\"\") ", .title = file.group orelse "" })
    else
        compileJs(gpa, source, file.shared, values, .{ .prefix = if (top_shares) "__t.globals();" else "", .done = "__t.done();\n", .title = file.group orelse "" });
    const own: Tweak, const path: []const u8, const is_group = switch (part) {
        .whole => unreachable,
        .group => |g| .{ file.groups[g].shared, file.groups[g].path, true },
        .tweak => |i| .{ file.tweaks[i], file.tweaks[i].path, false },
    };
    const parent = file.parentOf(part).?;
    const parent_path = file.groups[parent].path;
    const declares = part == .group and file.groups[part.group].shares_globals;
    if (file.script == .lua) {
        const lua_parent = if (parent == 0) try gpa.dupe(u8, "nil") else try std.fmt.allocPrint(gpa, "{f}", .{luaString(parent_path)});
        defer gpa.free(lua_parent);
        const prefix = if (declares)
            try std.fmt.allocPrint(gpa, "local _ENV = __t.part({f}, {s}, true) ", .{ luaString(path), lua_parent })
        else if (parent == 0)
            try std.fmt.allocPrint(gpa, "local _ENV = __t.part({f}) ", .{luaString(path)})
        else
            try std.fmt.allocPrint(gpa, "local _ENV = __t.part({f}, {s}) ", .{ luaString(path), lua_parent });
        defer gpa.free(prefix);
        return compileLuaWith(gpa, source, own, values, .{ .prefix = prefix, .head = false, .assign_types = true, .title = own.title orelse "" });
    }
    const sharer = file.sharerOf(part);
    var prefix: std.Io.Writer.Allocating = .init(gpa);
    defer prefix.deinit();
    // Plain writes under a nested sharer go to its globals. The file's are the real globals
    if (sharer) |k| if (k != 0) try prefix.writer.print("with (__t.shared({f})) ", .{json(file.groups[k].path)});
    if (parent != 0) try prefix.writer.print("with (__t.scope({f})) ", .{json(parent_path)});
    try prefix.writer.print("__t.part({f}, function (data, sym, types) {{ ", .{json(path)});
    // `eval` there sees its own functions, for `Choices`, `tick` and `off`. A group's also sets them
    const assign = if (is_group) ", (__n, __v) => eval(__n + \" = __v\")" else "";
    const js_parent = if (parent == 0) try gpa.dupe(u8, "undefined") else try std.fmt.allocPrint(gpa, "{f}", .{json(parent_path)});
    defer gpa.free(js_parent);
    const done = if (declares)
        try std.fmt.allocPrint(gpa, "return __t.done((name) => eval(name){s}); }}, {s}, true);\n", .{ assign, js_parent })
    else if (parent == 0)
        try std.fmt.allocPrint(gpa, "return __t.done((name) => eval(name){s}); }});\n", .{assign})
    else
        try std.fmt.allocPrint(gpa, "return __t.done((name) => eval(name){s}); }}, {s});\n", .{ assign, js_parent });
    defer gpa.free(done);
    return compileJs(gpa, source, own, values, .{ .prefix = prefix.written(), .head = false, .assign_types = true, .done = done, .title = own.title orelse "", .share = sharer != null });
}

/// How a part's code is put together.
const Wrap = struct {
    /// Before the first line.
    prefix: []const u8 = "",
    /// Lines before its first section kept as they are, like JS comments. Blank if not.
    head: bool = true,
    /// What it ends with, for JS. Lua's always gives `__t.done()` back.
    done: []const u8 = "",
    /// `@schema` gives `types` back, for a part whose `types` is its own.
    assign_types: bool = false,
    /// Its title, for `@use`'s options.
    title: []const u8 = "",
    /// It's under `@globals shared`, so its top-level `var` and `function` names go there too.
    share: bool = false,
};

/// `@use`s run first, before anything else in the part, all on its first line.
fn writeUses(w: *std.Io.Writer, tweak: Tweak, wrap: Wrap, script: Script) !void {
    for (tweak.uses) |u| switch (script) {
        .lua => try w.print("__t.use({d}, {f}, {f}) ", .{ u.line, luaString(u.name), luaString(wrap.title) }),
        .js => {
            // What's nested binds its name in its own function, the top binds a global
            if (!wrap.head and identEnd(u.name, 0) == u.name.len and !std.ascii.isDigit(u.name[0])) try w.print("const {s} = ", .{u.name});
            try w.print("__t.use({d}, {f}, {f});", .{ u.line, json(u.name), json(wrap.title) });
        },
    };
}

/// A top-level `var` or `function` in a part's JS.
const Declared = struct { name: []const u8, is_var: bool };

/// Shares a part's top-level `var` and `function` names as live getter/setter pairs, before its code.
fn writeShares(gpa: std.mem.Allocator, w: *std.Io.Writer, source: []const u8, lines: []const []const u8, tweak: Tweak) !void {
    var list: std.ArrayList(Declared) = .empty;
    defer list.deinit(gpa);
    for (tweak.sections) |s| {
        if (s.kind != .js or s.count == 0) continue;
        const from = @intFromPtr(lines[s.first].ptr) - @intFromPtr(source.ptr);
        const last = lines[s.first + s.count - 1];
        try jsDeclared(gpa, source[from .. @intFromPtr(last.ptr) + last.len - @intFromPtr(source.ptr)], &list);
    }
    if (list.items.len == 0) return;
    try w.writeAll("__t.share([");
    for (list.items, 0..) |d, i| {
        if (i > 0) try w.writeAll(", ");
        try w.print("[\"{s}\", () => {s}, (__v) => {{ {s} = __v; }}, {}]", .{ d.name, d.name, d.name, d.is_var });
    }
    try w.writeAll("]);");
}

/// Top-level `var` and `function` names in JS, near enough: skips strings, comments and regexes.
fn jsDeclared(gpa: std.mem.Allocator, text: []const u8, list: *std.ArrayList(Declared)) !void {
    var depth: usize = 0;
    // The last thing that wasn't a space or a comment, 0 at the start and `a` for a word
    var prev: u8 = 0;
    var prev_word: []const u8 = "";
    var word_started = false;
    var line_break = false;
    var in_var = false;
    var want_name = false;
    var i: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\n') line_break = true;
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
            continue;
        }
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            continue;
        }
        if (ch == '/' and i + 1 < text.len and text[i + 1] == '*') {
            const end = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 2 else text.len;
            if (std.mem.indexOfScalar(u8, text[i..end], '\n') != null) line_break = true;
            i = end;
            continue;
        }
        const carries = jsCarriesOn(prev, prev_word);
        const at_start = prev == 0 or prev == ';' or prev == '}' or (line_break and !carries);
        if (in_var and depth == 0 and line_break and !carries) {
            in_var = false;
            want_name = false;
        }
        line_break = false;
        if (std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$') {
            var end = i;
            while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_' or text[end] == '$')) end += 1;
            const word = text[i..end];
            if (depth == 0) {
                if (want_name) {
                    try addDeclared(gpa, list, word, true);
                } else if (at_start and std.mem.eql(u8, word, "var")) {
                    in_var = true;
                    want_name = true;
                    prev = 'a';
                    prev_word = word;
                    word_started = at_start;
                    i = end;
                    continue;
                } else if (std.mem.eql(u8, word, "function") and (at_start or (std.mem.eql(u8, prev_word, "async") and word_started))) {
                    var j = end;
                    while (j < text.len and (std.ascii.isWhitespace(text[j]) or text[j] == '*')) j += 1;
                    const name_end = identEnd(text, j);
                    if (name_end > j) try addDeclared(gpa, list, text[j..name_end], false);
                }
            }
            want_name = false;
            prev = 'a';
            prev_word = word;
            word_started = at_start;
            i = end;
            continue;
        }
        want_name = false;
        prev_word = "";
        if (std.ascii.isDigit(ch)) {
            while (i < text.len and (std.ascii.isAlphanumeric(text[i]) or text[i] == '.' or text[i] == '_')) i += 1;
            prev = '0';
            continue;
        }
        if (ch == '"' or ch == '\'' or ch == '`' or (ch == '/' and jsRegexCanStart(prev))) {
            i = skipJsLiteral(text, i);
            prev = '"';
            continue;
        }
        switch (ch) {
            '{', '(', '[' => depth += 1,
            '}', ')', ']' => depth -|= 1,
            ',' => want_name = in_var and depth == 0,
            ';' => if (depth == 0) {
                in_var = false;
            },
            else => {},
        }
        prev = ch;
        i += 1;
    }
}

fn addDeclared(gpa: std.mem.Allocator, list: *std.ArrayList(Declared), name: []const u8, is_var: bool) !void {
    // Each part keeps these, see `reserved`
    for (reserved) |r| if (std.mem.eql(u8, r, name)) return;
    for (list.items) |*d| if (std.mem.eql(u8, d.name, name)) {
        d.is_var = d.is_var and is_var;
        return;
    };
    try list.append(gpa, .{ .name = name, .is_var = is_var });
}

/// Whether a statement carries on past a line break after this.
fn jsCarriesOn(prev: u8, prev_word: []const u8) bool {
    if (prev == 'a') {
        const operators = [_][]const u8{ "return", "typeof", "new", "in", "of", "instanceof", "void", "delete", "await", "yield", "var", "let", "const" };
        for (operators) |o| if (std.mem.eql(u8, o, prev_word)) return true;
        return false;
    }
    return std.mem.indexOfScalar(u8, "=(,:?+-*/%!&|^~<>[.{", prev) != null;
}

/// A `/` here starts a regex rather than dividing.
fn jsRegexCanStart(prev: u8) bool {
    return prev == 0 or std.mem.indexOfScalar(u8, "(,=:[!&|?{};+-*%<>~^", prev) != null;
}

/// Past the string, template or regex at `from`.
fn skipJsLiteral(text: []const u8, from: usize) usize {
    const open = text[from];
    var i = from + 1;
    var class = false;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\\') {
            i += 2;
            continue;
        }
        if (open == '`' and ch == '$' and i + 1 < text.len and text[i + 1] == '{') {
            // What's in `${}` until its brace closes
            var depth: usize = 1;
            i += 2;
            while (i < text.len and depth > 0) {
                switch (text[i]) {
                    '{' => depth += 1,
                    '}' => depth -= 1,
                    '"', '\'', '`' => {
                        i = skipJsLiteral(text, i);
                        continue;
                    },
                    else => {},
                }
                i += 1;
            }
            continue;
        }
        if (open == '/') {
            if (ch == '\n') return i;
            if (ch == '[') class = true;
            if (ch == ']') class = false;
            if (ch == '/' and !class) {
                i += 1;
                while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
                return i;
            }
        } else {
            if (ch == open) return i + 1;
            if (ch == '\n' and open != '`') return i;
        }
        i += 1;
    }
    return text.len;
}

fn compileJs(gpa: std.mem.Allocator, source: []const u8, tweak: Tweak, values: []const Value, wrap: Wrap) ![]u8 {
    const lines = try splitLines(gpa, source);
    defer gpa.free(lines);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll(wrap.prefix);
    try writeUses(w, tweak, wrap, .js);
    if (wrap.share) try writeShares(gpa, w, source, lines, tweak);
    const first = if (tweak.sections.len > 0) tweak.sections[0].line - 1 else lines.len;
    for (lines[0..first]) |l| try w.print("{s}\n", .{if (wrap.head) l else ""});
    // A JS body's function closes on the next line that's ours, in case its last line is a comment
    var close = false;
    for (tweak.sections) |s| {
        const body = lines[s.first..][0..s.count];
        if (close) try w.writeAll("});");
        close = false;
        switch (s.kind) {
            .group, .children, .use, .globals, .end, .tweak, .key, .mode, .schema, .patch, .bytes, .inject, .hook, .js, .lua => {},
            .sym => try w.print("__t.sym({d}, {f}, {f});", .{ s.line, json(s.name), json(s.where) }),
            .data => {
                try w.print("__t.data({d}, {f}, [", .{ s.line, json(s.where) });
                for (tweak.fields[s.fields.start..][0..s.fields.len], 0..) |f, i| {
                    var value = f.value;
                    for (values) |v| if (std.mem.eql(u8, v.name, f.name)) {
                        value = v.value;
                    };
                    if (i > 0) try w.writeAll(", ");
                    try w.print("{{\"name\":{f},\"type\":\"{t}\",\"value\":{d},\"choices\":{f},\"line\":{d}}}", .{ json(f.name), f.type, value, json(f.choices_fn), f.line });
                }
                try w.writeAll("]);");
            },
        }
        const js_body = s.kind.hasCode() and s.lang == .js;
        switch (s.kind) {
            .patch => if (js_body)
                try w.print("__t.patchJs({d}, {f}, {f}, {d}, function (cpu, original, resume) {{", .{ s.line, json(s.where), json(s.expect), s.size })
            else
                try w.print("__t.patch({d}, {f}, {f}, {d}, `", .{ s.line, json(s.where), json(s.expect), s.size }),
            .inject => if (js_body)
                try w.print("__t.injectJs({d}, {f}, function (cpu, original, resume) {{", .{ s.line, json(s.where) })
            else
                try w.print("__t.inject({d}, {f}, `", .{ s.line, json(s.where) }),
            .hook => {
                try w.print("__t.hook({d}, {f}, {f}, function (original", .{ s.line, json(s.where), json(s.signature) });
                for (s.params) |p| try w.print(", {s}", .{p});
                try w.writeAll(") {");
            },
            .bytes => try w.print("__t.bytes({d}, {f}, {f}, `", .{ s.line, json(s.where), json(s.expect) }),
            .schema => try w.print("{s}__t.schema({d}, `", .{ if (wrap.assign_types) "types = " else "", s.line }),
            else => {},
        }
        if (s.template()) {
            for (body, s.first..) |l, at| {
                try w.writeByte('\n');
                if (s.isMarker(at)) continue;
                for (l) |ch| switch (ch) {
                    '\\' => try w.writeAll("\\\\"),
                    '`' => try w.writeAll("\\`"),
                    else => try w.writeByte(ch),
                };
            }
            try w.writeAll("`);\n");
        } else {
            try w.writeByte('\n');
            for (body, s.first..) |l, at| try w.print("{s}\n", .{if ((s.kind == .js or js_body) and !s.isMarker(at)) l else ""});
            close = js_body;
        }
    }
    if (close) try w.writeAll("});");
    try w.writeAll(wrap.done);
    return out.toOwnedSlice();
}

/// Like `compile` for Lua. Returns what `__t.done()` gives.
pub fn compileLua(gpa: std.mem.Allocator, source: []const u8, tweak: Tweak, values: []const Value) ![]u8 {
    return compileLuaWith(gpa, source, tweak, values, .{ .title = tweak.title orelse "" });
}

fn compileLuaWith(gpa: std.mem.Allocator, source: []const u8, tweak: Tweak, values: []const Value, wrap: Wrap) ![]u8 {
    const lines = try splitLines(gpa, source);
    defer gpa.free(lines);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    try w.writeAll(wrap.prefix);
    try writeUses(w, tweak, wrap, .lua);
    // Only blanks and `//` comments come before the first section, and `//` isn't Lua's
    const first = if (tweak.sections.len > 0) tweak.sections[0].line - 1 else lines.len;
    for (lines[0..first]) |_| try w.writeByte('\n');
    var close = false;
    for (tweak.sections) |s| {
        const body = lines[s.first..][0..s.count];
        if (close) try w.writeAll("end) ");
        close = false;
        switch (s.kind) {
            .group, .children, .use, .globals, .end, .tweak, .key, .mode, .schema, .patch, .bytes, .inject, .hook, .js, .lua => {},
            .sym => try w.print("__t.sym({d}, {f}, {f})", .{ s.line, luaString(s.name), luaString(s.where) }),
            .data => {
                try w.print("__t.data({d}, {f}, {{", .{ s.line, luaString(s.where) });
                for (tweak.fields[s.fields.start..][0..s.fields.len], 0..) |f, i| {
                    var value = f.value;
                    for (values) |v| if (std.mem.eql(u8, v.name, f.name)) {
                        value = v.value;
                    };
                    try w.writeAll(if (i > 0) ", " else " ");
                    try w.print("{{ name = {f}, type = \"{t}\", value = {d}, ", .{ luaString(f.name), f.type, value });
                    if (f.choices_fn) |c| try w.print("choices = {f}, ", .{luaString(c)});
                    try w.print("line = {d} }}", .{f.line});
                }
                try w.writeAll(if (s.fields.len > 0) " })" else "})");
            },
        }
        const lua_body = s.kind.hasCode() and s.lang == .lua;
        switch (s.kind) {
            .patch => if (lua_body)
                try w.print("__t.patchLua({d}, {f}, {f}, {d}, function(cpu, original, resume)", .{ s.line, luaString(s.where), luaString(s.expect), s.size })
            else
                try w.print("__t.patch({d}, {f}, {f}, {d}, ", .{ s.line, luaString(s.where), luaString(s.expect), s.size }),
            .inject => if (lua_body)
                try w.print("__t.injectLua({d}, {f}, function(cpu, original, resume)", .{ s.line, luaString(s.where) })
            else
                try w.print("__t.inject({d}, {f}, ", .{ s.line, luaString(s.where) }),
            .hook => {
                try w.print("__t.hook({d}, {f}, {f}, function(original", .{ s.line, luaString(s.where), luaString(s.signature) });
                for (s.params) |p| try w.print(", {s}{s}", .{ p, if (isLuaKeyword(p)) "_" else "" });
                try w.writeAll(")");
            },
            .bytes => try w.print("__t.bytes({d}, {f}, {f}, ", .{ s.line, luaString(s.where), luaString(s.expect) }),
            .schema => try w.print("{s}__t.schema({d}, ", .{ if (wrap.assign_types) "types = " else "", s.line }),
            else => {},
        }
        if (s.template()) {
            // A long string, which skips the newline right after its opening
            const level = try longLevel(gpa, body);
            try w.writeByte('[');
            try w.splatByteAll('=', level);
            try w.writeByte('[');
            for (body, s.first..) |l, at| try w.print("\n{s}", .{if (s.isMarker(at)) "" else l});
            try w.writeByte(']');
            try w.splatByteAll('=', level);
            try w.writeAll("])\n");
        } else {
            try w.writeByte('\n');
            // Lines up to a body's marker are blanks and `//` comments
            const from = if (s.marker) |m| m + 1 else s.first;
            for (body, s.first..) |l, at| try w.print("{s}\n", .{if (s.kind == .lua or (lua_body and at >= from)) l else ""});
            close = lua_body;
        }
    }
    if (close) try w.writeAll("end) ");
    try w.writeAll("return __t.done()\n");
    return out.toOwnedSlice();
}

/// The fewest `=` that keep `body`'s text from closing a long string early.
fn longLevel(gpa: std.mem.Allocator, body: []const []const u8) !usize {
    const text = try std.mem.join(gpa, "\n", body);
    defer gpa.free(text);
    var closer: std.ArrayList(u8) = .empty;
    defer closer.deinit(gpa);
    var level: usize = 0;
    while (true) : (level += 1) {
        closer.clearRetainingCapacity();
        try closer.append(gpa, ']');
        try closer.appendNTimes(gpa, '=', level);
        try closer.append(gpa, ']');
        const whole = try std.mem.concat(gpa, u8, &.{ text, closer.items });
        defer gpa.free(whole);
        if (std.mem.indexOf(u8, whole, closer.items) == text.len) return level;
    }
}

const lua_keywords = [_][]const u8{ "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "global", "goto", "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while" };

/// Hook params can't be called these, so they get a `_` after, like the API's names.
fn isLuaKeyword(name: []const u8) bool {
    for (lua_keywords) |k| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

/// Quoted for Lua.
pub fn luaString(text: []const u8) LuaString {
    return .{ .text = text };
}

/// A quoted Lua string, with control bytes as `\ddd`.
const LuaString = struct {
    text: []const u8,

    pub fn format(self: LuaString, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.writeByte('"');
        for (self.text) |ch| switch (ch) {
            '"', '\\' => try w.print("\\{c}", .{ch}),
            0...0x1f, 0x7f => try w.print("\\{d:0>3}", .{ch}),
            else => try w.writeByte(ch),
        };
        try w.writeByte('"');
    }
};

fn json(value: anytype) std.json.Formatter(@TypeOf(value)) {
    return std.json.fmt(value, .{});
}

const tests = struct {
    const testing = std.testing;

    const xp =
        \\// Gets you more XP
        \\@tweak "Character XP multiplier"
        \\@key Ctrl+F8
        \\
        \\@data
        \\  [Label("Multiplier"), Min(1), Max(100)] u32 multiplier = 10;
        \\  [Toggle, Key(F9)] bool on = true // comment
        \\  [Choices("0:None", "1:Tear Balm")] u16 item
        \\
        \\@sym site = sig("8B 80 98 00 00 00", Offset(2))
        \\@inject site expect "nope"
    ;

    test "sections, fields and problems" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var problem: Problem = .{};

        try testing.expectError(error.Invalid, parse(a, xp, &problem));
        try testing.expectEqual(11, problem.line);

        const ok = comptime xp[0..std.mem.lastIndexOf(u8, xp, " expect").?] ++
            \\
            \\  mov eax,[rax+0x98]
            \\  imul eax,[multiplier]
            \\  jmp resume
            \\@patch game.exe+0x10 expect "29 D0" // nop it
            \\  nop 2
            \\@js
            \\function tick() {}
        ;
        const t = try parse(a, ok, &problem);
        try testing.expectEqualStrings("Character XP multiplier", t.title.?);
        try testing.expect(t.key.?.mods.ctrl and t.key.?.key == .f8);
        try testing.expectEqual(.toggle, t.mode);
        try testing.expectEqual(3, t.fields.len);
        const m = t.field("multiplier").?;
        try testing.expectEqualStrings("Multiplier", m.label);
        try testing.expectEqual(10, m.value);
        try testing.expectEqual(100, m.max.?);
        try testing.expect(t.fields[1].toggle and t.fields[1].key.?.key == .f9);
        try testing.expectEqual(1, t.fields[1].value);
        try testing.expectEqualStrings("Tear Balm", t.fields[2].choices[1].label);
        const kinds = [_]Kind{ .tweak, .key, .data, .sym, .inject, .patch, .js };
        for (kinds, t.sections) |k, s| try testing.expectEqual(k, s.kind);
        try testing.expectEqualStrings("sig(\"8B 80 98 00 00 00\", Offset(2))", t.sections[3].where);
        try testing.expectEqualStrings("game.exe+0x10", t.sections[5].where);
        try testing.expectEqualStrings("29 D0", t.sections[5].expect);
        try testing.expectEqual(3, t.sections[4].count);
    }

    test "problems say where" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cases = [_]struct { []const u8, u32, []const u8 }{
            .{ "nop", 1, "under a section" },
            .{ "@js\n@nope", 2, "no @nope" },
            .{ "@data\n  u32 a\n  u24 b", 3, "isn't a type" },
            .{ "@data\n  u32 a\n@sym a = 1", 3, "already" },
            .{ "@data\n  [Size(4)] u32 a", 2, "no attribute" },
            .{ "@data\n  [Key(F8)] u32 a", 2, "needs Toggle" },
            .{ "@sym resume = 1", 1, "taken" },
            .{ "@key Ctrl", 1, "isn't a key" },
            .{ "@mode sometimes", 1, "toggle or action" },
            .{ "@patch\n  nop", 1, "needs a where" },
            .{ "@sym x = 1\n  nop", 2, "nothing under it" },
            .{ "@inject x expect \"90\"", 1, "expect goes on @patch" },
            .{ "@inject x (5)", 1, "only @patch takes a size" },
            .{ "@bytes x (5)", 1, "only @patch takes a size" },
            .{ "@patch x (0)", 1, "like (5)" },
            .{ "@patch x (two)", 1, "like (5)" },
        };
        for (cases) |case| {
            var problem: Problem = .{};
            try testing.expectError(error.Invalid, parse(arena.allocator(), case[0], &problem));
            try testing.expectEqual(case[1], problem.line);
            if (std.mem.indexOf(u8, problem.message(), case[2]) == null) {
                std.debug.print("{s}: {s}\n", .{ case[0], problem.message() });
                return error.TestUnexpectedResult;
            }
        }
    }

    test "compiles line for line" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const source =
            \\// top
            \\@tweak Mira
            \\@data near game.exe
            \\  [Toggle] u32 keep = 1
            \\@inject game.exe+0x10
            \\  mov eax, `${1}` \ 2
            \\  jmp resume
            \\@js
            \\const x = data.keep;
        ;
        var problem: Problem = .{};
        const t = try parse(arena.allocator(), source, &problem);
        const js = try compile(testing.allocator, source, t, &.{.{ .name = "keep", .value = 0 }});
        defer testing.allocator.free(js);
        const expected =
            \\// top
            \\
            \\__t.data(3, "game.exe", [{"name":"keep","type":"u32","value":0,"choices":null,"line":4}]);
            \\
            \\__t.inject(5, "game.exe+0x10", `
            \\  mov eax, \`${1}\` \\ 2
            \\  jmp resume`);
            \\
            \\const x = data.keep;
            \\__t.done();
            \\
        ;
        try testing.expectEqualStrings(expected, js);
    }

    test "patch sizes" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const source =
            \\@patch sig("8B ?? (", Offset(2)) (8) expect "29 D0"
            \\  nop
            \\@patch [game.exe+0x10] + 4
            \\@patch (game.exe+0x10)
        ;
        var problem: Problem = .{};
        const t = try parse(arena.allocator(), source, &problem);
        try testing.expectEqualStrings("sig(\"8B ?? (\", Offset(2))", t.sections[0].where);
        try testing.expectEqual(8, t.sections[0].size);
        try testing.expectEqualStrings("29 D0", t.sections[0].expect);
        try testing.expectEqualStrings("[game.exe+0x10] + 4", t.sections[1].where);
        try testing.expectEqual(0, t.sections[1].size);
        try testing.expectEqualStrings("(game.exe+0x10)", t.sections[2].where);
        const js = try compile(testing.allocator, source, t, &.{});
        defer testing.allocator.free(js);
        try testing.expect(std.mem.startsWith(u8, js, "__t.patch(1, \"sig(\\\"8B ?? (\\\", Offset(2))\", \"29 D0\", 8, `\n  nop`);\n"));
    }

    test "code bodies in asm or JS, and hooks" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const source =
            \\@patch game.exe+0x10 (6)
            \\  // why
            \\  @js
            \\  cpu.rax = 1 // a comment at the end
            \\@inject game.exe+0x20
            \\  @asm
            \\  nop
            \\@hook sig("40 53") as [Thiscall] i32 Attack(Player* this, i32 damage, f32)
            \\  return original(self, damage * 2, arg3)
        ;
        var problem: Problem = .{};
        const t = try parse(arena.allocator(), source, &problem);
        try testing.expectEqual(.js, t.sections[0].lang);
        try testing.expectEqual(2, t.sections[0].marker.?);
        try testing.expectEqual(.@"asm", t.sections[1].lang);
        try testing.expectEqualStrings("sig(\"40 53\")", t.sections[2].where);
        try testing.expectEqualStrings("[Thiscall] i32 Attack(Player* this, i32 damage, f32)", t.sections[2].signature);
        try testing.expectEqual(3, t.sections[2].params.len);
        for ([_][]const u8{ "self", "damage", "arg3" }, t.sections[2].params) |want, got| try testing.expectEqualStrings(want, got);

        const js = try compile(testing.allocator, source, t, &.{});
        defer testing.allocator.free(js);
        const expected =
            \\__t.patchJs(1, "game.exe+0x10", "", 6, function (cpu, original, resume) {
            \\  // why
            \\
            \\  cpu.rax = 1 // a comment at the end
            \\});__t.inject(5, "game.exe+0x20", `
            \\
            \\  nop`);
            \\__t.hook(8, "sig(\"40 53\")", "[Thiscall] i32 Attack(Player* this, i32 damage, f32)", function (original, self, damage, arg3) {
            \\  return original(self, damage * 2, arg3)
            \\});__t.done();
            \\
        ;
        try testing.expectEqualStrings(expected, js);

        const cases = [_]struct { []const u8, u32, []const u8 }{
            .{ "@patch x\n@js\ncpu.rax = 1", 2, "Indent this @js" },
            .{ "@patch x\n  nop\n  @js", 3, "@js goes on the first line of the @patch" },
            .{ "@hook x as i32 (i32 a)\n  @asm\n  nop", 2, "a @hook's code is JS" },
            .{ "@hook x", 1, "needs a signature" },
            .{ "@hook x as i32", 1, "params in ( )" },
            .{ "@hook x as i32 (i32 original)", 1, "can't be called original" },
            .{ "@bytes x\n  @js", 2, "only @patch, @inject and @hook" },
        };
        for (cases) |case| {
            try testing.expectError(error.Invalid, parse(arena.allocator(), case[0], &problem));
            try testing.expectEqual(case[1], problem.line);
            if (std.mem.indexOf(u8, problem.message(), case[2]) == null) {
                std.debug.print("{s}: {s}\n", .{ case[0], problem.message() });
                return error.TestUnexpectedResult;
            }
        }
    }

    test "Lua tweaks compile line for line" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const source =
            \\// top
            \\@tweak Mira
            \\@data
            \\  [Choices(picks)] u32 keep = 1
            \\@inject game.exe+0x10
            \\  mov eax, [[keep]]
            \\@patch game.exe+0x20 (5)
            \\  // why
            \\  @lua
            \\  cpu.rax = data.keep -- a comment at the end
            \\@hook game.exe+0x30 as i32 (i32 end, i32)
            \\  return original(end_, arg2)
            \\@lua
            \\function picks() return { "1:One" } end
        ;
        var problem: Problem = .{};
        const t = try parse(arena.allocator(), source, &problem);
        try testing.expectEqual(.lua, t.script);
        try testing.expectEqual(.@"asm", t.sections[2].lang);
        try testing.expectEqual(.lua, t.sections[3].lang);
        try testing.expectEqual(.lua, t.sections[4].lang);

        const code = try compileLua(testing.allocator, source, t, &.{.{ .name = "keep", .value = 0 }});
        defer testing.allocator.free(code);
        const expected =
            \\
            \\
            \\__t.data(3, "", { { name = "keep", type = "u32", value = 0, choices = "picks", line = 4 } })
            \\
            \\__t.inject(5, "game.exe+0x10", [=[
            \\  mov eax, [[keep]]]=])
            \\__t.patchLua(7, "game.exe+0x20", "", 5, function(cpu, original, resume)
            \\
            \\
            \\  cpu.rax = data.keep -- a comment at the end
            \\end) __t.hook(11, "game.exe+0x30", "i32 (i32 end, i32)", function(original, end_, arg2)
            \\  return original(end_, arg2)
            \\end) 
            \\function picks() return { "1:One" } end
            \\return __t.done()
            \\
        ;
        try testing.expectEqualStrings(expected, code);

        // Asm only is JS, and quotes are escaped for Lua
        const plain = try parse(arena.allocator(), "@sym a = sig(\"90\\x\")\n@patch a\n  nop", &problem);
        try testing.expectEqual(.js, plain.script);
        const quoted = try compileLua(testing.allocator, "@sym a = sig(\"90\\x\")\n@patch a\n  nop", plain, &.{});
        defer testing.allocator.free(quoted);
        try testing.expectEqualStrings("__t.sym(1, \"a\", \"sig(\\\"90\\\\x\\\")\")\n__t.patch(2, \"a\", \"\", 0, [[\n  nop]])\nreturn __t.done()\n", quoted);
    }

    test "a tweak is all JS or all Lua" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cases = [_]struct { []const u8, u32, []const u8 }{
            .{ "@patch x\n  @js\n  cpu.rax = 1\n@lua\nx = 1", 4, "a tweak is all JS or all Lua, and line 2 already has @js" },
            .{ "@lua\n@inject x\n  @js\n  a()", 3, "line 1 already has @lua" },
            .{ "@hook x as i32 (i32 a)\n  @lua\n  return 1\n@js", 4, "line 2 already has @lua" },
            .{ "@patch x\n@lua\ncpu.rax = 1", 2, "Indent this @lua to make it the @patch's" },
            .{ "@hook x as i32 (i32 a)\n  @asm\n  nop", 2, "a @hook's code is JS or Lua" },
            .{ "@bytes x\n  @lua", 2, "only @patch, @inject and @hook take @lua" },
            .{ "@lua x", 1, "@lua takes nothing after it" },
        };
        for (cases) |case| {
            var problem: Problem = .{};
            try testing.expectError(error.Invalid, parse(arena.allocator(), case[0], &problem));
            try testing.expectEqual(case[1], problem.line);
            if (std.mem.indexOf(u8, problem.message(), case[2]) == null) {
                std.debug.print("{s}: {s}\n", .{ case[0], problem.message() });
                return error.TestUnexpectedResult;
            }
        }
    }

    test "a @group or more than one @tweak makes a group" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var problem: Problem = .{};
        const source =
            \\// Combat
            \\@group "Combat"
            \\@data
            \\  u32 table
            \\@sym base = 0x10
            \\@js
            \\function itemName(id) { return "x" + id; }
            \\
            \\@tweak "Max bravery"
            \\@key F5
            \\@inject base
            \\  nop
            \\
            \\@tweak "Override item"
            \\@data
            \\  [Choices(itemList)] u64 item
            \\@js
            \\function itemList() { return [[1, itemName(1)]]; }
        ;
        const file = try parseFile(a, source, &problem);
        try testing.expect(file.grouped);
        try testing.expectEqualStrings("Combat", file.group.?);
        try testing.expectEqual(.js, file.script);
        try testing.expectEqualStrings("table", file.shared.fields[0].name);
        try testing.expectEqual(2, file.tweaks.len);
        try testing.expectEqualStrings("Max bravery", file.tweaks[0].title.?);
        try testing.expectEqual(.f5, file.tweaks[0].key.?.key);
        try testing.expectEqual(1, file.find("Override item").?);
        // Lines are the file's
        try testing.expectEqual(16, file.tweaks[1].fields[0].line);
        try testing.expectEqualStrings("itemList", file.tweaks[1].fields[0].choices_fn.?);

        // Two tweaks and no @group go by the file's name
        const unnamed = try parseFile(a, "@tweak A\n@js\n@tweak B\n@js", &problem);
        try testing.expect(unnamed.grouped and unnamed.group == null);
        try testing.expectEqual(0, unnamed.shared.sections.len);
    }

    test "one @tweak is the file as it always was" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var problem: Problem = .{};
        // Even with sections before its @tweak
        for ([_][]const u8{ "@data\n  u32 a = 2\n@tweak Late\n@js\nx()", "// hi\n@tweak Mira\n@inject 0x10\n  nop\n@js\ny()", "@js\nz()" }) |source| {
            const file = try parseFile(a, source, &problem);
            try testing.expect(!file.grouped);
            try testing.expectEqual(1, file.tweaks.len);
            const old = try compile(testing.allocator, source, try parse(a, source, &problem), &.{});
            defer testing.allocator.free(old);
            const now = try compilePart(testing.allocator, source, file, .whole, &.{});
            defer testing.allocator.free(now);
            try testing.expectEqualStrings(old, now);
        }
    }

    test "a group's tweak compiles to its own scope" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var problem: Problem = .{};
        const source =
            \\@group G
            \\@js
            \\function shared() {}
            \\@tweak A
            \\@data
            \\  u8 x = 1
            \\@schema
            \\struct S { u8 a; }
            \\@js
            \\off = 1
        ;
        const file = try parseFile(arena.allocator(), source, &problem);
        const js = try compilePart(testing.allocator, source, file, .{ .tweak = 0 }, &.{});
        defer testing.allocator.free(js);
        const expected = "__t.part(\"A\", function (data, sym, types) { \n\n\n\n" ++
            "__t.data(5, \"\", [{\"name\":\"x\",\"type\":\"u8\",\"value\":1,\"choices\":null,\"line\":6}]);\n\n" ++
            "types = __t.schema(7, `\nstruct S { u8 a; }`);\n" ++
            "\noff = 1\n" ++
            "return __t.done((name) => eval(name)); });\n";
        try testing.expectEqualStrings(expected, js);
        const shared = try compilePart(testing.allocator, source, file, .{ .group = 0 }, &.{});
        defer testing.allocator.free(shared);
        try testing.expectEqualStrings("\n\nfunction shared() {}\n__t.done();\n", shared);

        const lua_source = "@group G\n@lua\nfunction shared() end\n@tweak A\n@lua\nx = 1";
        const lua_file = try parseFile(arena.allocator(), lua_source, &problem);
        const lua = try compilePart(testing.allocator, lua_source, lua_file, .{ .tweak = 0 }, &.{});
        defer testing.allocator.free(lua);
        try testing.expectEqualStrings("local _ENV = __t.part(\"A\") \n\n\n\n\nx = 1\nreturn __t.done()\n", lua);
    }

    test "group problems say where" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cases = [_]struct { []const u8, u32, []const u8 }{
            .{ "@data\n  u8 x\n@group G\n@tweak A\n@js", 5, "@group \"G\" from line 3 needs an @end" },
            .{ "@group G\n@tweak A\n@group H\n@tweak B", 4, "@group \"H\" from line 3 needs an @end" },
            .{ "@tweak A\n@js\n@tweak A\n@js", 3, "there's already a @tweak \"A\"" },
            .{ "@group G\n@mode action\n@tweak A", 2, "@mode goes under a @tweak" },
            .{ "@group G\n@data\n  u8 x\n@tweak A\n@data\n  u8 x", 6, "the shared part already has a x" },
            .{ "@group G\n@sym s = 1\n@tweak A\n@sym s = 2", 4, "the shared part already has a s" },
            .{ "@group G\n@js\n@tweak A\n@lua", 4, "a group is all JS or all Lua, and line 2 already has @js" },
            .{ "@group G\n@js", 1, "a group needs a @tweak" },
            .{ "@group\n@tweak A", 1, "@group needs a name" },
        };
        for (cases) |case| {
            var problem: Problem = .{};
            try testing.expectError(error.Invalid, parseFile(arena.allocator(), case[0], &problem));
            try testing.expectEqual(case[1], problem.line);
            if (std.mem.indexOf(u8, problem.message(), case[2]) == null) {
                std.debug.print("{s}: {s}\n", .{ case[0], problem.message() });
                return error.TestUnexpectedResult;
            }
        }
    }

    const kai =
        \\@group "Kai"
        \\@key F4
        \\@sym table = 0x10
        \\@lua
        \\function itemName(id) return "x" .. id end
        \\
        \\@group "Combat"
        \\@children on
        \\@data
        \\  [Toggle] bool logHits
        \\@lua
        \\function combatHelper() end
        \\
        \\@tweak "Max bravery"
        \\@inject table
        \\  nop
        \\
        \\@group "Party"
        \\@children none
        \\@tweak "Max HP"
        \\@data
        \\  u32 y
        \\@end
        \\
        \\@end
        \\
        \\@tweak "Override item"
        \\@lua
        \\x = 1
    ;

    test "groups nest, with @end and @children" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var problem: Problem = .{};
        const file = parseFile(arena.allocator(), kai, &problem) catch |err| {
            std.debug.print("line {d}: {s}\n", .{ problem.line, problem.message() });
            return err;
        };
        try testing.expect(file.grouped);
        try testing.expectEqual(.lua, file.script);
        try testing.expectEqualStrings("Kai", file.group.?);
        try testing.expectEqual(.f4, file.shared.key.?.key);
        try testing.expectEqual(3, file.groups.len);
        const combat = file.groups[1];
        try testing.expectEqualStrings("Combat", combat.title.?);
        try testing.expectEqualStrings("Combat", combat.path);
        try testing.expectEqual(0, combat.parent.?);
        try testing.expectEqual(7, combat.line);
        try testing.expect(combat.children.on and !combat.children.off);
        try testing.expectEqualStrings("logHits", combat.shared.fields[0].name);
        try testing.expectEqual(.lua, combat.shared.script);
        const party = file.groups[2];
        try testing.expectEqualStrings("Combat/Party", party.path);
        try testing.expect(!party.children.on and !party.children.off);
        try testing.expect(file.groups[0].children.on and file.groups[0].children.off);

        try testing.expectEqual(3, file.tweaks.len);
        const paths = [_][]const u8{ "Combat/Max bravery", "Combat/Party/Max HP", "Override item" };
        const in = [_]u32{ 1, 2, 0 };
        for (paths, in, file.tweaks) |p, g, t| {
            try testing.expectEqualStrings(p, t.path);
            try testing.expectEqual(g, t.group);
        }
        try testing.expectEqual(Part{ .tweak = 1 }, file.resolve("Combat/Party/Max HP").?);
        try testing.expectEqual(Part{ .group = 2 }, file.resolve("Combat/Party").?);
        try testing.expectEqual(Part{ .group = 0 }, file.resolve("").?);
        try testing.expectEqual(null, file.resolve("Party"));
        try testing.expectEqual(2, file.parentOf(.{ .tweak = 1 }).?);

        // All four @children
        for ([_]struct { []const u8, bool, bool }{ .{ "on off", true, true }, .{ "off  on", true, true }, .{ "on", true, false }, .{ "off", false, true }, .{ "none", false, false } }) |c| {
            const source = try std.fmt.allocPrint(arena.allocator(), "@group G\n@children {s}\n@tweak A\n@js", .{c[0]});
            const f = try parseFile(arena.allocator(), source, &problem);
            try testing.expectEqual(c[1], f.groups[0].children.on);
            try testing.expectEqual(c[2], f.groups[0].children.off);
        }
    }

    test "a nested group's parts compile to scopes in its group's" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var problem: Problem = .{};
        const lua_file = try parseFile(arena.allocator(), kai, &problem);
        const party = try compilePart(testing.allocator, kai, lua_file, .{ .group = 2 }, &.{});
        defer testing.allocator.free(party);
        const blank: [19]u8 = @splat('\n');
        try testing.expect(std.mem.startsWith(u8, party, "local _ENV = __t.part(\"Combat/Party\", \"Combat\") " ++ blank ++ "return __t.done()\n"));
        const combat = try compilePart(testing.allocator, kai, lua_file, .{ .group = 1 }, &.{});
        defer testing.allocator.free(combat);
        try testing.expect(std.mem.startsWith(u8, combat, "local _ENV = __t.part(\"Combat\") "));
        // Line for line, so it says the file's lines, and then the line that turns it on
        try testing.expectEqual(std.mem.count(u8, kai[0 .. std.mem.indexOf(u8, kai, "@tweak \"Max").? - 1], "\n") + 2, std.mem.count(u8, combat, "\n"));

        const source =
            \\@group G
            \\@group H
            \\@js
            \\function h() {}
            \\@tweak A
            \\@js
            \\h()
            \\@end
        ;
        const file = try parseFile(arena.allocator(), source, &problem);
        const h = try compilePart(testing.allocator, source, file, .{ .group = 1 }, &.{});
        defer testing.allocator.free(h);
        try testing.expectEqualStrings("__t.part(\"H\", function (data, sym, types) { \n\n\nfunction h() {}\nreturn __t.done((name) => eval(name), (__n, __v) => eval(__n + \" = __v\")); });\n", h);
        const a = try compilePart(testing.allocator, source, file, .{ .tweak = 0 }, &.{});
        defer testing.allocator.free(a);
        try testing.expectEqualStrings("with (__t.scope(\"H\")) __t.part(\"H/A\", function (data, sym, types) { \n\n\n\n\n\nh()\nreturn __t.done((name) => eval(name)); }, \"H\");\n", a);
    }

    test "removePart cuts a tweak or a whole nested group" {
        var problem: Problem = .{};
        const source =
            \\@group G
            \\@tweak A
            \\@js
            \\a()
            \\@group H
            \\@tweak B
            \\@js
            \\@tweak C
            \\@js
            \\@end
            \\@tweak D
            \\@js
        ;
        const no_b = try removePart(testing.allocator, source, "H/B", &problem);
        defer testing.allocator.free(no_b);
        try testing.expectEqualStrings("@group G\n@tweak A\n@js\na()\n@group H\n@tweak C\n@js\n@end\n@tweak D\n@js", no_b);
        const no_h = try removePart(testing.allocator, source, "H", &problem);
        defer testing.allocator.free(no_h);
        try testing.expectEqualStrings("@group G\n@tweak A\n@js\na()\n@tweak D\n@js", no_h);
        const no_d = try removePart(testing.allocator, source, "D", &problem);
        defer testing.allocator.free(no_d);
        try testing.expectEqualStrings("@group G\n@tweak A\n@js\na()\n@group H\n@tweak B\n@js\n@tweak C\n@js\n@end\n", no_d);
        try testing.expectError(error.Invalid, removePart(testing.allocator, source, "Nope", &problem));
        // H would be empty
        try testing.expectError(error.Invalid, removePart(testing.allocator, "@group G\n@tweak A\n@js\n@group H\n@tweak B\n@js\n@end", "H/B", &problem));
    }

    test "flat groups keep their names and paths" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        var problem: Problem = .{};
        const file = try parseFile(arena.allocator(), "@group G\n@js\n@tweak A/B\n@js\n@tweak C\n@js", &problem);
        try testing.expectEqual(1, file.groups.len);
        try testing.expectEqualStrings("A/B", file.tweaks[0].path);
        try testing.expectEqual(0, file.find("A/B").?);
        try testing.expectEqual(Part{ .tweak = 1 }, file.resolve("C").?);
    }

    test "nesting problems say where" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const cases = [_]struct { []const u8, u32, []const u8 }{
            .{ "@group G\n@tweak A\n@group H\n@tweak B\n@js", 5, "@group \"H\" from line 3 needs an @end" },
            .{ "@group G\n@tweak A\n@end", 3, "The one at the top of the file needs none" },
            .{ "@tweak A\n@tweak B\n@end", 3, "there's no @group open for this @end" },
            .{ "@tweak A\n@end", 2, "there's no @group open for this @end" },
            .{ "@group G\n@tweak A\n@children on", 3, "@children goes right after a @group line" },
            .{ "@group G\n@data\n  u8 x\n@children on\n@tweak A", 4, "@children goes right after a @group line" },
            .{ "@group G\n@children on\n@children off\n@tweak A", 3, "@children goes right after a @group line" },
            .{ "@group G\n@tweak A\n@group H\n@js\n@children on\n@tweak B\n@end", 5, "@children goes right after a @group line" },
            .{ "@js\n@children on", 2, "@children goes right after a @group line" },
            .{ "@group G\n@children sometimes\n@tweak A", 2, "@children is on off, on, off or none" },
            .{ "@group G\n@children on on\n@tweak A", 2, "@children is on off, on, off or none" },
            .{ "@group G\n@children none off\n@tweak A", 2, "@children is on off, on, off or none" },
            .{ "@group G\n@tweak A\n@group A\n@tweak B\n@end", 3, "there's already a @tweak \"A\"" },
            .{ "@group G\n@group A\n@tweak B\n@end\n@tweak A", 5, "there's already a @group \"A\"" },
            .{ "@group G\n@group A\n@tweak B\n@end\n@group A\n@tweak C\n@end", 5, "there's already a @group \"A\"" },
            .{ "@group G\n@group A\n@tweak B\n@tweak B\n@end", 4, "there's already a @tweak \"B\"" },
            // The same title in different groups is fine, so this one's about the mode
            .{ "@group G\n@tweak B\n@group A\n@mode action\n@tweak B\n@end", 4, "@mode goes under a @tweak" },
            .{ "@group G\n@group A\n@js\n@tweak B\n@lua\n@end", 5, "a group is all JS or all Lua, and line 3 already has @js" },
            .{ "@group G\n@group A\n@data\n  u8 x\n@tweak B\n@data\n  u8 x\n@end", 7, "@group \"A\" already has a x" },
            .{ "@group G\n@sym s = 1\n@group A\n@sym s = 2\n@tweak B\n@end", 4, "the shared part already has a s" },
            .{ "@group G\n@group A\n@js\n@end\n@tweak B", 2, "@group \"A\" needs a @tweak or @group in it" },
            .{ "@group G\n@group A/B\n@tweak C\n@end", 2, "can't have /" },
            .{ "@group G\n@tweak A/B\n@group C\n@tweak D\n@end", 2, "can't have /" },
            .{ "@group G\n@group\n@tweak C\n@end", 2, "@group needs a name" },
            .{ "@group G\n@group A\n@tweak B\n@end\n@js", 5, "after @end comes a @tweak" },
            .{ "@group G\n@group A\n@tweak B\n@end\nx = 1\n@tweak C", 5, "after @end comes a @tweak" },
        };
        for (cases) |case| {
            var problem: Problem = .{};
            if (parseFile(arena.allocator(), case[0], &problem)) |_| {
                std.debug.print("{s}: parsed\n", .{case[0]});
                return error.TestExpectedError;
            } else |_| {}
            if (problem.line != case[1] or std.mem.indexOf(u8, problem.message(), case[2]) == null) {
                std.debug.print("{s}: line {d}: {s}\n", .{ case[0], problem.line, problem.message() });
                return error.TestUnexpectedResult;
            }
        }
        // Nested groups can have keys and comments after @end
        var problem: Problem = .{};
        const file = try parseFile(arena.allocator(), "@group G\n@group A\n@key F2\n@tweak B\n@end // A\n\n// next\n@tweak C", &problem);
        try testing.expectEqual(.f2, file.groups[1].shared.key.?.key);
    }

    test "chords" {
        try testing.expectEqual(input.Chord{ .key = .f8 }, parseChord("F8").?);
        try testing.expectEqual(input.Chord{ .key = .gamepad_start }, parseChord("Gamepad_Start").?);
        try testing.expectEqual(null, parseChord("Ctrl+gamepad_start"));
        const c = parseChord("ctrl + Shift+page_up").?;
        try testing.expect(c.mods.ctrl and c.mods.shift and !c.mods.alt and c.key == .page_up);
        try testing.expectEqual(null, parseChord("Ctrl+Shift"));
        try testing.expectEqual(null, parseChord("F8+Ctrl"));
        try testing.expectEqual(null, parseChord("Hyper+F8"));
    }

    test "numbers" {
        try testing.expectEqual(255, parseNumber("0xFF").?);
        try testing.expectEqual(-5, parseNumber("-5").?);
        try testing.expectEqual(1.5, parseNumber("1.5").?);
        try testing.expectEqual(null, parseNumber("4EFF"));
        try testing.expectEqual(-255, parseNumber("-0FFh").?);
        try testing.expectEqual(null, parseNumber("FFh"));
    }

    test "@use goes before a shared part's code and runs first" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var problem: Problem = .{};
        const source = "@group \"Kai\"\n@use ce\n@lua\nx = 1\n@group \"Combat\"\n@children none\n@use util\n@lua\n@tweak \"One\"\n@lua\n@end\n";
        const f = try parseFile(a, source, &problem);
        try testing.expectEqualStrings("ce", f.shared.uses[0].name);
        try testing.expectEqual(2, f.shared.uses[0].line);
        try testing.expectEqualStrings("util", f.groups[1].shared.uses[0].name);
        const top = try compilePart(a, source, f, .{ .group = 0 }, &.{});
        try testing.expect(std.mem.startsWith(u8, top, "local _ENV = __t.part(\"\") __t.use(2, \"ce\", \"Kai\") \n"));
        const combat = try compilePart(a, source, f, .{ .group = 1 }, &.{});
        try testing.expect(std.mem.indexOf(u8, combat, "__t.use(7, \"util\", \"Combat\") ") != null);
        const lone = try parseFile(a, "@tweak \"X\"\n@use ce\n@lua\n", &problem);
        try testing.expectEqualStrings("ce", lone.tweaks[0].uses[0].name);

        const bad = [_]struct { []const u8, []const u8 }{
            .{ "@group G\n@tweak One\n@use ce\n@lua\n", "@use goes in a group's shared part" },
            .{ "@tweak X\n@lua\nx = 1\n@use ce\n", "@use goes before the code" },
            .{ "@tweak X\n@use no good\n", "isn't a library's name" },
            .{ "@tweak X\n@use ce\n@use ce\n", "there's already a @use ce on line 2" },
        };
        for (bad) |b| {
            try testing.expectError(error.Invalid, parseFile(a, b[0], &problem));
            try testing.expect(std.mem.indexOf(u8, problem.message(), b[1]) != null);
        }
    }

    test "@globals shared goes in a group's shared part, and what's in it writes there" {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var problem: Problem = .{};
        const source = "@group \"Kai\"\n@globals shared\n@lua\n@tweak \"One\"\n@lua\n@group \"Combat\"\n@use ce\n@globals shared\n@lua\n@tweak \"Two\"\n@lua\n@end\n";
        const f = try parseFile(a, source, &problem);
        try testing.expect(f.groups[0].shares_globals and f.groups[1].shares_globals);
        try testing.expectEqual(1, f.sharerOf(.{ .tweak = 1 }));
        try testing.expectEqual(0, f.sharerOf(.{ .tweak = 0 }));
        try testing.expect(std.mem.startsWith(u8, try compilePart(a, source, f, .{ .group = 0 }, &.{}), "local _ENV = __t.part(\"\", nil, true) "));
        try testing.expect(std.mem.startsWith(u8, try compilePart(a, source, f, .{ .group = 1 }, &.{}), "local _ENV = __t.part(\"Combat\", nil, true) "));
        try testing.expect(std.mem.startsWith(u8, try compilePart(a, source, f, .{ .tweak = 1 }, &.{}), "local _ENV = __t.part(\"Combat/Two\", \"Combat\") "));
        const plain = try parseFile(a, "@group G\n@tweak A\n@js\n", &problem);
        try testing.expect(!plain.groups[0].shares_globals);
        try testing.expectEqual(null, plain.sharerOf(.{ .tweak = 0 }));

        // JS hands its top-level var and function names over, but not off or tick
        const js_source =
            \\@group "Kai"
            \\@globals shared
            \\@js
            \\@group "Combat"
            \\@globals shared
            \\@js
            \\@tweak "One"
            \\@js
            \\var a = 1, b = { c: [1, 2] }, d
            \\var e = `${"}"}` + '{' // var no
            \\function f() { var g = 1; function h() {} }
            \\async function* i() {}
            \\const j = function k() {}; let l = /{/
            \\function off() {}
            \\if (a) { var m = 2 }
            \\/* function n() {} */ var o
            \\@end
        ;
        const jf = try parseFile(a, js_source, &problem);
        try testing.expectEqualStrings("__t.globals();", (try compilePart(a, js_source, jf, .{ .group = 0 }, &.{}))[0..14]);
        const combat = try compilePart(a, js_source, jf, .{ .group = 1 }, &.{});
        try testing.expect(std.mem.startsWith(u8, combat, "with (__t.shared(\"Combat\")) __t.part(\"Combat\", function (data, sym, types) { "));
        try testing.expect(std.mem.endsWith(u8, combat, "}, undefined, true);\n"));
        const one = try compilePart(a, js_source, jf, .{ .tweak = 0 }, &.{});
        const want = "with (__t.shared(\"Combat\")) with (__t.scope(\"Combat\")) __t.part(\"Combat/One\", function (data, sym, types) { " ++
            "__t.share([[\"a\", () => a, (__v) => { a = __v; }, true], [\"b\", () => b, (__v) => { b = __v; }, true], " ++
            "[\"d\", () => d, (__v) => { d = __v; }, true], [\"e\", () => e, (__v) => { e = __v; }, true], " ++
            "[\"f\", () => f, (__v) => { f = __v; }, false], [\"i\", () => i, (__v) => { i = __v; }, false], " ++
            "[\"o\", () => o, (__v) => { o = __v; }, true]]);";
        try testing.expect(std.mem.startsWith(u8, one, want));

        const bad = [_]struct { []const u8, u32, []const u8 }{
            .{ "@group G\n@globals local\n@tweak A\n@lua\n", 2, "@globals is shared, like @globals shared" },
            .{ "@group G\n@globals\n@tweak A\n@lua\n", 2, "@globals is shared, like @globals shared" },
            .{ "@group G\n@tweak A\n@globals shared\n@lua\n", 3, "@globals goes in a group's shared part" },
            .{ "@tweak A\n@globals shared\n@lua\n", 2, "@globals goes in a group's shared part" },
            .{ "@group G\n@lua\nx = 1\n@globals shared\n@tweak A\n@lua\n", 4, "@globals goes before the code, right under the @group" },
            .{ "@group G\n@data\n  u8 x\n@globals shared\n@tweak A\n@lua\n", 4, "@globals goes before the code, right under the @group" },
            .{ "@group G\n@globals shared\n@globals shared\n@tweak A\n@lua\n", 3, "there's already a @globals on line 2" },
            .{ "@group G\n@tweak A\n@lua\n@group H\n@lua\n@globals shared\n@tweak B\n@lua\n@end\n", 6, "@globals goes before the code" },
        };
        for (bad) |b| {
            try testing.expectError(error.Invalid, parseFile(a, b[0], &problem));
            try testing.expectEqual(b[1], problem.line);
            try testing.expect(std.mem.indexOf(u8, problem.message(), b[2]) != null);
        }
    }
};

test {
    _ = tests;
}
