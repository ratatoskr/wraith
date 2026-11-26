//! Lua from CE tables, run under the `ce` script library (`ce.lua`). See `lua/API.md`.

const std = @import("std");

const luaString = @import("wraith_api").tweak.luaString;

/// CE's Lua API on top of Wraith's, registered as the script library `library_name`.
pub const compat_source = @embedFile("lua/ce.lua");
pub const library_name = "ce";
/// What the layer does with each of CE's builtins.
pub const api_md = @embedFile("lua/API.md");

comptime {
    _ = compat_source;
}

/// A whole `@lua` section, with `on` as its top level and `off` as `off()`, both after `pre`.
pub fn section(arena: std.mem.Allocator, pre: []const u8, on: []const u8, off: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "@lua\n");
    try appendCode(arena, &out, std.mem.trim(u8, pre, "\r\n"));
    try appendCode(arena, &out, try body(arena, std.mem.trim(u8, on, "\r\n")));
    if (std.mem.trim(u8, off, " \t\r\n").len > 0) {
        try out.appendSlice(arena, "\nfunction off()\n");
        try appendCode(arena, &out, std.mem.trim(u8, off, "\r\n"));
        try out.appendSlice(arena, "end\n");
    }
    return out.items;
}

/// Wraps a block with a top-level `return` in a function, as CE ran it, so it doesn't end the part.
pub fn body(arena: std.mem.Allocator, code: []const u8) ![]const u8 {
    if (!try returnsAtTop(arena, code)) return code;
    return std.fmt.allocPrint(arena, "-- ce: CE ran this as a function, which its return needs\n;(function()\n{s}\nend)()", .{code});
}

/// Each line, with one starting with `@` moved over so it doesn't start a section.
pub fn appendCode(arena: std.mem.Allocator, out: *std.ArrayList(u8), code: []const u8) !void {
    if (code.len == 0) return;
    var lines = std.mem.splitScalar(u8, code, '\n');
    while (lines.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len > 0 and l[0] == '@') try out.append(arena, ' ');
        try out.appendSlice(arena, l);
        try out.append(arena, '\n');
    }
}

/// Lua 5.5 `for` variables are read-only, so loops assigning one get a local copy. Returns the count.
pub fn fixLoops(arena: std.mem.Allocator, code: []const u8) !struct { []const u8, u32 } {
    const tokens = try tokenize(arena, code);
    var inserts: std.ArrayList(struct { at: usize, text: []const u8 }) = .empty;
    for (tokens, 0..) |tok, i| {
        if (!tok.is(code, "for")) continue;
        var names: std.ArrayList([]const u8) = .empty;
        var k = i + 1;
        while (k < tokens.len and tokens[k].kind == .name) : (k += 1) {
            try names.append(arena, tokens[k].text(code));
            if (k + 1 < tokens.len and tokens[k + 1].is(code, ",")) k += 1 else {
                k += 1;
                break;
            }
        }
        if (names.items.len == 0) continue;
        // Its `do`, past the header's expressions
        var depth: usize = 0;
        const do_at = while (k < tokens.len) : (k += 1) {
            const t = tokens[k];
            if (t.is(code, "(") or t.is(code, "{") or t.is(code, "[")) depth += 1;
            if (t.is(code, ")") or t.is(code, "}") or t.is(code, "]")) depth -|= 1;
            if (depth == 0 and t.is(code, "do")) break k;
        } else continue;
        const end_at = blockEnd(code, tokens, do_at) orelse continue;
        var assigned: std.ArrayList([]const u8) = .empty;
        for (names.items) |n| {
            for (tokens[do_at + 1 .. end_at], do_at + 1..) |t, at| {
                if (t.kind != .name or !std.mem.eql(u8, t.text(code), n)) continue;
                if (at + 1 >= tokens.len or !tokens[at + 1].is(code, "=")) continue;
                const before = tokens[at - 1];
                if (before.is(code, ".") or before.is(code, ":") or before.is(code, "local")) continue;
                try assigned.append(arena, n);
                break;
            }
        }
        if (assigned.items.len == 0) continue;
        var text: std.ArrayList(u8) = .empty;
        for (assigned.items) |n| try text.print(arena, " local {s} = {s}", .{ n, n });
        try inserts.append(arena, .{ .at = tokens[do_at].end, .text = text.items });
    }
    if (inserts.items.len == 0) return .{ code, 0 };
    var out: std.ArrayList(u8) = .empty;
    var from: usize = 0;
    for (inserts.items) |ins| {
        try out.appendSlice(arena, code[from..ins.at]);
        try out.appendSlice(arena, ins.text);
        from = ins.at;
    }
    try out.appendSlice(arena, code[from..]);
    return .{ out.items, @intCast(inserts.items.len) };
}

/// A `return` outside any block, which can't have the part's own code after it.
fn returnsAtTop(arena: std.mem.Allocator, code: []const u8) !bool {
    var depth: usize = 0;
    for (try tokenize(arena, code)) |t| {
        if (t.kind != .name) continue;
        const w = t.text(code);
        if (std.mem.eql(u8, w, "do") or std.mem.eql(u8, w, "if") or std.mem.eql(u8, w, "function") or std.mem.eql(u8, w, "repeat")) depth += 1;
        if (std.mem.eql(u8, w, "end") or std.mem.eql(u8, w, "until")) depth -|= 1;
        if (depth == 0 and std.mem.eql(u8, w, "return")) return true;
    }
    return false;
}

/// A top-level `return` with a value, which in CE's `{$lua}` is asm to assemble.
pub fn returnsValue(arena: std.mem.Allocator, code: []const u8) !bool {
    const tokens = try tokenize(arena, code);
    // Each open block, and whether it's a function
    var blocks: std.ArrayList(bool) = .empty;
    var functions: usize = 0;
    for (tokens, 0..) |t, i| {
        if (t.kind != .name) continue;
        const w = t.text(code);
        if (std.mem.eql(u8, w, "function") or std.mem.eql(u8, w, "do") or std.mem.eql(u8, w, "if") or std.mem.eql(u8, w, "repeat")) {
            const is_function = std.mem.eql(u8, w, "function");
            try blocks.append(arena, is_function);
            if (is_function) functions += 1;
        } else if (std.mem.eql(u8, w, "end") or std.mem.eql(u8, w, "until")) {
            if (blocks.pop()) |was_function| {
                if (was_function) functions -= 1;
            }
        } else if (functions == 0 and std.mem.eql(u8, w, "return")) {
            // Strings and numbers aren't tokens, so a return of one has nothing after it
            if (i + 1 == tokens.len) return std.mem.trim(u8, code[t.end..], " \t\r\n;").len > 0;
            const next = tokens[i + 1];
            const between = std.mem.trim(u8, code[t.end..next.start], " \t\r\n");
            if (between.len > 0) return true;
            const n = next.text(code);
            const ends = [_][]const u8{ "end", "else", "elseif", "until", ";" };
            for (ends) |e| {
                if (std.mem.eql(u8, n, e)) break;
            } else return true;
        }
    }
    return false;
}

/// The `end` that closes the block opened by `do` at `open`.
fn blockEnd(code: []const u8, tokens: []const Token, open: usize) ?usize {
    var depth: usize = 1;
    for (tokens[open + 1 ..], open + 1..) |t, i| {
        if (t.kind != .name) continue;
        const w = t.text(code);
        if (std.mem.eql(u8, w, "do") or std.mem.eql(u8, w, "if") or std.mem.eql(u8, w, "function") or std.mem.eql(u8, w, "repeat")) depth += 1;
        if (std.mem.eql(u8, w, "end") or std.mem.eql(u8, w, "until")) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

const Token = struct {
    kind: enum { name, other },
    start: usize,
    end: usize,

    fn text(self: Token, code: []const u8) []const u8 {
        return code[self.start..self.end];
    }

    fn is(self: Token, code: []const u8, s: []const u8) bool {
        return std.mem.eql(u8, self.text(code), s);
    }
};

/// Names, keywords and punctuation, skipping strings, numbers and comments.
fn tokenize(arena: std.mem.Allocator, code: []const u8) ![]const Token {
    var out: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    while (i < code.len) {
        const ch = code[i];
        if (std.ascii.isWhitespace(ch)) {
            i += 1;
        } else if (ch == '-' and i + 1 < code.len and code[i + 1] == '-') {
            i += 2;
            if (longOpen(code, i)) |level| {
                i = longClose(code, i, level);
            } else {
                while (i < code.len and code[i] != '\n') i += 1;
            }
        } else if (ch == '[' and longOpen(code, i) != null) {
            i = longClose(code, i, longOpen(code, i).?);
        } else if (ch == '"' or ch == '\'') {
            i += 1;
            while (i < code.len and code[i] != ch and code[i] != '\n') : (i += 1) {
                if (code[i] == '\\') i += 1;
            }
            i += 1;
        } else if (std.ascii.isAlphabetic(ch) or ch == '_') {
            const start = i;
            while (i < code.len and (std.ascii.isAlphanumeric(code[i]) or code[i] == '_')) i += 1;
            try out.append(arena, .{ .kind = .name, .start = start, .end = i });
        } else if (std.ascii.isDigit(ch)) {
            while (i < code.len and (std.ascii.isAlphanumeric(code[i]) or code[i] == '.')) i += 1;
        } else {
            // `==`, `~=`, `<=` and `>=` aren't assignments
            const two = i + 1 < code.len and code[i + 1] == '=' and std.mem.indexOfScalar(u8, "=~<>", ch) != null;
            const len: usize = if (two) 2 else 1;
            try out.append(arena, .{ .kind = .other, .start = i, .end = @min(i + len, code.len) });
            i += len;
        }
    }
    return out.items;
}

/// The level of a long bracket like `[==[` at `i`.
fn longOpen(code: []const u8, i: usize) ?usize {
    if (i >= code.len or code[i] != '[') return null;
    var k = i + 1;
    while (k < code.len and code[k] == '=') k += 1;
    if (k < code.len and code[k] == '[') return k - i - 1;
    return null;
}

fn longClose(code: []const u8, i: usize, level: usize) usize {
    var k = i + level + 2;
    while (k < code.len) : (k += 1) {
        if (code[k] != ']') continue;
        var e = k + 1;
        while (e < code.len and code[e] == '=') e += 1;
        if (e - k - 1 == level and e < code.len and code[e] == ']') return e + 1;
    }
    return code.len;
}

/// One record for the manifest, see `lua/API.md`.
pub const Record = struct {
    id: i64,
    parent: ?i64 = null,
    description: []const u8,
    type: []const u8 = "",
    hex: bool = false,
    signed: bool = false,
    length: ?u32 = null,
    unicode: bool = false,
    bitstart: ?u8 = null,
    options: []const u8 = "",
    dropdown: []const []const u8 = &.{},
    dropdown_link: ?[]const u8 = null,
    what: union(enum) {
        header,
        tweak: []const u8,
        data: []const u8,
        /// Its entry in the Addresses list, by id.
        address: []const u8,
        location: struct { text: []const u8, offsets: []const []const u8 },
    } = .header,
};

/// `ce.load { ... }`, one record a line.
pub fn manifest(arena: std.mem.Allocator, records: []const Record) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("ce.load {\n");
    for (records) |r| {
        try w.print("  {{ id = {d}", .{r.id});
        if (r.parent) |p| try w.print(", parent = {d}", .{p});
        try w.print(", description = {f}", .{luaString(r.description)});
        if (r.type.len > 0) try w.print(", type = {f}", .{luaString(r.type)});
        if (r.hex) try w.writeAll(", hex = true");
        if (r.signed) try w.writeAll(", signed = true");
        if (r.length) |n| try w.print(", length = {d}", .{n});
        if (r.unicode) try w.writeAll(", unicode = true");
        if (r.bitstart) |b| try w.print(", bitstart = {d}", .{b});
        if (r.options.len > 0) try w.print(", options = {f}", .{luaString(r.options)});
        if (r.dropdown.len > 0) {
            try w.writeAll(", dropdown = {");
            for (r.dropdown, 0..) |d, i| try w.print("{s} {f}", .{ if (i > 0) "," else "", luaString(d) });
            try w.writeAll(" }");
        }
        if (r.dropdown_link) |l| try w.print(", dropdownLink = {f}", .{luaString(l)});
        switch (r.what) {
            .header => {},
            .tweak => |t| try w.print(", tweak = {f}", .{luaString(t)}),
            .data => |d| try w.print(", data = {f}", .{luaString(d)}),
            .address => |id| try w.print(", address = {f}", .{luaString(id)}),
            .location => |l| {
                try w.print(", location = {f}", .{luaString(l.text)});
                if (l.offsets.len > 0) {
                    try w.writeAll(", offsets = {");
                    for (l.offsets, 0..) |o, i| try w.print("{s} {f}", .{ if (i > 0) "," else "", luaString(o) });
                    try w.writeAll(" }");
                }
            },
        }
        try w.writeAll(" },\n");
    }
    try w.writeAll("}\n");
    return out.written();
}

/// `ce.files { ... }` in base64, since scripts can't read files. Base64 can't close a long string.
pub fn files(arena: std.mem.Allocator, list: []const @import("files.zig").File) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("ce.files {\n");
    const encoder = std.base64.standard.Encoder;
    for (list) |f| {
        try w.print("  [{f}] = [[\n", .{luaString(f.name)});
        const text = try arena.alloc(u8, encoder.calcSize(f.data.len));
        _ = encoder.encode(text, f.data);
        var i: usize = 0;
        while (i < text.len) : (i += line_len) try w.print("{s}\n", .{text[i..@min(i + line_len, text.len)]});
        try w.writeAll("]],\n");
    }
    try w.writeAll("}\n");
    return out.written();
}

const line_len = 76;

test "table files" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try files(arena.allocator(), &.{.{ .name = "ding.wav", .data = "RIFF" }});
    try testing.expectEqualStrings(
        \\ce.files {
        \\  ["ding.wav"] = [[
        \\UklGRg==
        \\]],
        \\}
        \\
    , text);
}

const testing = std.testing;

test "lua comes in live, split into on and off" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try section(arena.allocator(), "", "print(t[a[1]])\n@weird", "print('bye')");
    try testing.expectEqualStrings(
        \\@lua
        \\print(t[a[1]])
        \\ @weird
        \\
        \\function off()
        \\print('bye')
        \\end
        \\
    , text);
}

test "a return at the top runs in a function of its own" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try section(arena.allocator(), "", "if done then return end\nx = 1\nreturn", "");
    try testing.expectEqualStrings(
        \\@lua
        \\-- ce: CE ran this as a function, which its return needs
        \\;(function()
        \\if done then return end
        \\x = 1
        \\return
        \\end)()
        \\
    , text);
    try testing.expect(!try returnsAtTop(arena.allocator(), "function f() return 1 end"));
}

test "lua that returns asm for CE" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect(try returnsValue(a, "local s = 'nop'\nreturn s"));
    try testing.expect(try returnsValue(a, "if x then return [[\nnop\n]] end"));
    try testing.expect(try returnsValue(a, "return \"db 90\""));
    try testing.expect(!try returnsValue(a, "if syntaxcheck then return end\nx = 1"));
    try testing.expect(!try returnsValue(a, "local function f() return 1 end\nfor i = 1, 2 do f() end\nreturn"));
}

test "a loop that assigns its variable gets a copy" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const code =
        \\for i = 1, 10 do
        \\  if i == 3 then i = i + 1 end
        \\  t.i = 1
        \\end
        \\for k, v in pairs(t) do v = v .. "-" -- v = 1 in a comment
        \\  print(k, "for x = 1 do")
        \\end
        \\for j = 1, 2 do local j = 3 print(j) end
    ;
    const fixed, const n = try fixLoops(a, code);
    try testing.expectEqual(2, n);
    try testing.expectEqualStrings(
        \\for i = 1, 10 do local i = i
        \\  if i == 3 then i = i + 1 end
        \\  t.i = 1
        \\end
        \\for k, v in pairs(t) do local v = v v = v .. "-" -- v = 1 in a comment
        \\  print(k, "for x = 1 do")
        \\end
        \\for j = 1, 2 do local j = 3 print(j) end
    , fixed);
}

test "the manifest" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const text = try manifest(arena.allocator(), &.{
        .{ .id = 0, .description = "Scripts", .options = "[moActivateChildrenAsWell]" },
        .{ .id = 1, .parent = 0, .description = "God \"mode\"", .type = "Auto Assembler Script", .what = .{ .tweak = "./Scripts/God mode" } },
        .{ .id = 2, .description = "Gold", .type = "4 Bytes", .dropdown = &.{"0:None"}, .what = .{ .location = .{ .text = "[game.exe+1234]+10", .offsets = &.{ "8", "1C" } } } },
        .{ .id = 3, .parent = 2, .description = "Rank", .type = "Byte", .what = .{ .address = "small.Rank" } },
    });
    try testing.expectEqualStrings(
        \\ce.load {
        \\  { id = 0, description = "Scripts", options = "[moActivateChildrenAsWell]" },
        \\  { id = 1, parent = 0, description = "God \"mode\"", type = "Auto Assembler Script", tweak = "./Scripts/God mode" },
        \\  { id = 2, description = "Gold", type = "4 Bytes", dropdown = { "0:None" }, location = "[game.exe+1234]+10", offsets = { "8", "1C" } },
        \\  { id = 3, parent = 2, description = "Rank", type = "Byte", address = "small.Rank" },
        \\}
        \\
    , text);
}
