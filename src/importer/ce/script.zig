//! Splits CE Auto Assembler scripts into statements, by `[ENABLE]`/`[DISABLE]`, keeping `{$lua}` text.

const std = @import("std");

pub const Directive = struct {
    /// Lowercase, like `alloc` or `aobscanmodule`.
    name: []const u8,
    args: []const []const u8,
};

pub const Statement = union(enum) {
    directive: Directive,
    /// `newmem:` or `"game.exe"+10:`, where what follows goes.
    place: []const u8,
    /// An instruction or data, in CE's own text.
    code: []const u8,
};

pub const Line = struct {
    statement: Statement,
    /// From 1, in the script.
    number: u32,
};

pub const Section = struct {
    lines: []const Line = &.{},
    /// Every `{$lua}` part, one after another.
    lua: []const u8 = "",
};

pub const Script = struct {
    enable: Section = .{},
    disable: Section = .{},
    /// The first `{ }` comment, which CE's templates use for who wrote it and what it does.
    header: []const u8 = "",
    /// From a template's `INJECTION POINT: "game.exe"+1234`.
    injection_point: ?[]const u8 = null,
    /// It had `{$try}`, so its `{$except}` part was dropped.
    has_try: bool = false,
    /// `{$c}` or `{$ccode}`, which we can't take.
    has_c: bool = false,
    /// Asm outside `{$lua}` that isn't blank.
    has_asm: bool = false,
    has_lua: bool = false,

    pub fn isLua(self: Script) bool {
        return self.has_lua;
    }
};

/// The names CE takes as `name(...)` statements.
const directives = [_][]const u8{
    "alloc",         "dealloc",       "label",        "registersymbol",      "unregistersymbol", "aobscan",
    "aobscanmodule", "aobscanregion", "define",       "globalalloc",         "assert",           "fullaccess",
    "readmem",       "reassemble",    "createthread", "createthreadandwait", "loadlibrary",      "loadbinary",
    "include",       "registerlabel", "kalloc",       "sharedallocate",      "luacall",          "aobscanex",
};

pub fn isDirective(name: []const u8) bool {
    for (directives) |d| if (std.ascii.eqlIgnoreCase(d, name)) return true;
    return false;
}

const Where = enum { both, enable, disable };

pub fn parse(arena: std.mem.Allocator, source: []const u8) !Script {
    var script: Script = .{};
    var lines: [2]std.ArrayList(Line) = .{ .empty, .empty };
    var lua: [2]std.ArrayList(u8) = .{ .empty, .empty };
    var where: Where = .both;
    var in_lua = false;
    var in_comment = false;
    // After `{$except}`, up to the section's end
    var skipping = false;
    var comment: std.ArrayList(u8) = .empty;
    var header_done = false;

    var it = std.mem.splitScalar(u8, source, '\n');
    var number: u32 = 0;
    while (it.next()) |raw| {
        number += 1;
        const text = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trim(u8, text, " \t");
        if (!in_comment) {
            if (std.ascii.eqlIgnoreCase(trimmed, "[ENABLE]")) {
                where = .enable;
                skipping = false;
                continue;
            }
            if (std.ascii.eqlIgnoreCase(trimmed, "[DISABLE]")) {
                where = .disable;
                skipping = false;
                continue;
            }
        }
        var clean: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            if (in_lua) {
                const end = indexOfIgnoreCase(text, i, "{$asm}") orelse {
                    if (!skipping) try addLua(arena, &lua, where, text[i..]);
                    i = text.len;
                    break;
                };
                if (!skipping) try addLua(arena, &lua, where, text[i..end]);
                in_lua = false;
                i = end + 6;
                continue;
            }
            if (in_comment) {
                const end = std.mem.indexOfScalarPos(u8, text, i, '}') orelse {
                    try comment.appendSlice(arena, text[i..]);
                    try comment.append(arena, '\n');
                    i = text.len;
                    break;
                };
                try comment.appendSlice(arena, text[i..end]);
                in_comment = false;
                i = end + 1;
                try noteComment(arena, &script, comment.items, &header_done, true);
                comment = .empty;
                continue;
            }
            const ch = text[i];
            if (ch == '"' or ch == '\'') {
                const end = std.mem.indexOfScalarPos(u8, text, i + 1, ch) orelse (text.len - 1);
                try clean.appendSlice(arena, text[i .. end + 1]);
                i = end + 1;
                continue;
            }
            if (ch == '/' and i + 1 < text.len and text[i + 1] == '/') {
                try noteComment(arena, &script, text[i + 2 ..], &header_done, false);
                break;
            }
            if (ch == '{') {
                if (i + 1 < text.len and text[i + 1] == '$') {
                    const end = std.mem.indexOfScalarPos(u8, text, i, '}') orelse (text.len - 1);
                    const name = text[i + 2 .. end];
                    i = end + 1;
                    // `{$luacode}` is Lua too, with registers passed in
                    if (std.ascii.eqlIgnoreCase(name, "lua") or std.ascii.startsWithIgnoreCase(name, "luacode")) {
                        in_lua = true;
                        script.has_lua = true;
                    } else if (std.ascii.eqlIgnoreCase(name, "try")) {
                        script.has_try = true;
                    } else if (std.ascii.eqlIgnoreCase(name, "except")) {
                        script.has_try = true;
                        skipping = true;
                    } else if (std.ascii.eqlIgnoreCase(name, "c") or std.ascii.eqlIgnoreCase(name, "ccode")) {
                        script.has_c = true;
                    }
                    continue;
                }
                in_comment = true;
                i += 1;
                continue;
            }
            try clean.append(arena, ch);
            i += 1;
        }
        if (in_comment) continue;
        if (skipping) continue;
        const statement_text = std.mem.trim(u8, clean.items, " \t");
        if (statement_text.len == 0) continue;
        script.has_asm = true;
        for (try statements(arena, statement_text)) |s| try addLine(arena, &lines, where, .{ .statement = s, .number = number });
    }
    script.enable = .{ .lines = lines[0].items, .lua = lua[0].items };
    script.disable = .{ .lines = lines[1].items, .lua = lua[1].items };
    return script;
}

fn addLine(arena: std.mem.Allocator, lines: *[2]std.ArrayList(Line), where: Where, line: Line) !void {
    if (where != .disable) try lines[0].append(arena, line);
    if (where != .enable) try lines[1].append(arena, line);
}

fn addLua(arena: std.mem.Allocator, lua: *[2]std.ArrayList(u8), where: Where, text: []const u8) !void {
    // Another {$lua} while in Lua does nothing
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, text, " \t"), "{$lua}")) return;
    for ([_]Where{ .enable, .disable }, 0..) |w, k| {
        if (where != .both and where != w) continue;
        try lua[k].appendSlice(arena, text);
        try lua[k].append(arena, '\n');
    }
}

fn noteComment(arena: std.mem.Allocator, script: *Script, text: []const u8, header_done: *bool, block: bool) !void {
    if (std.mem.indexOf(u8, text, "INJECTION POINT:")) |at| {
        const rest = text[at + "INJECTION POINT:".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const point = std.mem.trim(u8, rest[0..end], " \t\r");
        if (point.len > 0 and script.injection_point == null) script.injection_point = try arena.dupe(u8, point);
        return;
    }
    if (block and !header_done.*) {
        header_done.* = true;
        script.header = try arena.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
    }
}

fn indexOfIgnoreCase(text: []const u8, from: usize, needle: []const u8) ?usize {
    if (text.len < needle.len) return null;
    var i = from;
    while (i + needle.len <= text.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(text[i..][0..needle.len], needle)) return i;
    }
    return null;
}

/// A line's statements. `name: code` on one line is two.
fn statements(arena: std.mem.Allocator, text: []const u8) ![]const Statement {
    var out: std.ArrayList(Statement) = .empty;
    var rest = text;
    if (placeEnd(rest)) |colon| {
        try out.append(arena, .{ .place = std.mem.trim(u8, rest[0..colon], " \t") });
        rest = std.mem.trim(u8, rest[colon + 1 ..], " \t");
        if (rest.len == 0) return out.items;
    }
    if (try directive(arena, rest)) |d| {
        try out.append(arena, .{ .directive = d });
    } else {
        try out.append(arena, .{ .code = rest });
    }
    return out.items;
}

/// Where the `:` of a `place:` is, if the line starts with one. `mov rax,fs:[30]` isn't one.
fn placeEnd(text: []const u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        switch (ch) {
            '"', '\'' => i = std.mem.indexOfScalarPos(u8, text, i + 1, ch) orelse return null,
            '[', '(' => depth += 1,
            ']', ')' => depth -|= 1,
            ',' => return null,
            ':' => {
                if (depth != 0 or i == 0) return null;
                const name = text[0..i];
                // A module with spaces in it, like `Tales of Arise.exe+10:`
                if (std.mem.indexOfAny(u8, name, " \t") != null and std.ascii.findIgnoreCase(name, ".exe") == null and std.ascii.findIgnoreCase(name, ".dll") == null) return null;
                return i;
            },
            else => {},
        }
    }
    return null;
}

fn directive(arena: std.mem.Allocator, text: []const u8) !?Directive {
    const open = std.mem.indexOfScalar(u8, text, '(') orelse return null;
    const name = std.mem.trim(u8, text[0..open], " \t");
    if (!isDirective(name)) return null;
    if (text[text.len - 1] != ')') return null;
    var args: std.ArrayList([]const u8) = .empty;
    const inner = text[open + 1 .. text.len - 1];
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const ch = inner[i];
        switch (ch) {
            '"', '\'' => i = std.mem.indexOfScalarPos(u8, inner, i + 1, ch) orelse (inner.len - 1),
            '(', '[' => depth += 1,
            ')', ']' => depth -|= 1,
            ',' => if (depth == 0) {
                try args.append(arena, std.mem.trim(u8, inner[start..i], " \t"));
                start = i + 1;
            },
            else => {},
        }
    }
    const last = std.mem.trim(u8, inner[start..], " \t");
    if (last.len > 0 or args.items.len > 0) try args.append(arena, last);
    return .{ .name = try std.ascii.allocLowerString(arena, name), .args = args.items };
}

/// `registersymbol(a b, c)` names each of them.
pub fn names(arena: std.mem.Allocator, args: []const []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (args) |a| {
        var it = std.mem.tokenizeAny(u8, a, " \t");
        while (it.next()) |n| try out.append(arena, n);
    }
    return out.items;
}

/// Drops `if syntaxcheck then return end`, which only CE's checker needs.
pub fn withoutSyntaxCheck(arena: std.mem.Allocator, lua: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.splitScalar(u8, lua, '\n');
    var first = true;
    while (it.next()) |l| {
        var squashed: std.ArrayList(u8) = .empty;
        var tokens = std.mem.tokenizeAny(u8, l, " \t\r");
        while (tokens.next()) |t| {
            if (squashed.items.len > 0) try squashed.append(arena, ' ');
            try squashed.appendSlice(arena, t);
        }
        if (std.mem.eql(u8, squashed.items, "if syntaxcheck then return end")) continue;
        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, l);
    }
    return std.mem.trim(u8, out.items, "\n\r");
}

const testing = std.testing;

test "sections, comments and lua" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\{ Game   : kai.exe
        \\  Author : someone
        \\}
        \\define(bytes,48 8B 05)
        \\[ENABLE]
        \\aobscanmodule(INJECT,kai.exe,48 8B 05) // should be unique
        \\alloc(newmem,$1000,INJECT)
        \\newmem: mov eax,1
        \\  mov rax,fs:[30]
        \\  db 'a // b'
        \\{$lua}
        \\if syntaxcheck then return end
        \\print("{x}")
        \\{$asm}
        \\[DISABLE]
        \\INJECT:
        \\  db 48 8B 05
        \\{
        \\// ORIGINAL CODE - INJECTION POINT: "kai.exe"+1234
        \\}
    ;
    const s = try parse(arena.allocator(), source);
    try testing.expect(s.has_lua and s.has_asm);
    try testing.expectEqualStrings("Game   : kai.exe\n  Author : someone", s.header);
    try testing.expectEqualStrings("\"kai.exe\"+1234", s.injection_point.?);
    const e = s.enable.lines;
    try testing.expectEqualStrings("define", e[0].statement.directive.name);
    try testing.expectEqualStrings("48 8B 05", e[1].statement.directive.args[2]);
    try testing.expectEqualStrings("newmem", e[3].statement.place);
    try testing.expectEqualStrings("mov eax,1", e[4].statement.code);
    try testing.expectEqualStrings("mov rax,fs:[30]", e[5].statement.code);
    try testing.expectEqualStrings("db 'a // b'", e[6].statement.code);
    try testing.expectEqual(7, e.len);
    try testing.expectEqualStrings("print(\"{x}\")", try withoutSyntaxCheck(arena.allocator(), s.enable.lua));
    try testing.expectEqualStrings("INJECT", s.disable.lines[1].statement.place);
}
