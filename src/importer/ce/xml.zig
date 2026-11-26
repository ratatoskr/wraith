//! Just enough XML for Cheat Engine tables. No namespaces or DTDs.

const std = @import("std");

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
};

pub const Node = struct {
    name: []const u8,
    attrs: []const Attr = &.{},
    children: []const Node = &.{},
    /// Its own text with entities decoded, not its children's.
    text: []const u8 = "",

    pub fn child(self: Node, name: []const u8) ?*const Node {
        for (self.children) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        return null;
    }

    /// The text of the first child called `name`.
    pub fn childText(self: Node, name: []const u8) ?[]const u8 {
        const c = self.child(name) orelse return null;
        return c.text;
    }

    pub fn attr(self: Node, name: []const u8) ?[]const u8 {
        for (self.attrs) |a| if (std.mem.eql(u8, a.name, name)) return a.value;
        return null;
    }
};

pub const Error = error{ OutOfMemory, InvalidXml };

/// The root element. Everything is in `arena`.
pub fn parse(arena: std.mem.Allocator, source: []const u8) Error!Node {
    var p: Parser = .{ .s = source, .arena = arena };
    p.skipBom();
    while (true) {
        p.skipSpace();
        if (p.startsWith("<?")) {
            try p.skipPast("?>");
        } else if (p.startsWith("<!--")) {
            try p.skipPast("-->");
        } else if (p.startsWith("<!")) {
            try p.skipPast(">");
        } else break;
    }
    if (!p.startsWith("<")) return error.InvalidXml;
    return p.element();
}

const Parser = struct {
    s: []const u8,
    i: usize = 0,
    arena: std.mem.Allocator,

    fn skipBom(self: *Parser) void {
        if (std.mem.startsWith(u8, self.s, "\xEF\xBB\xBF")) self.i = 3;
    }

    fn startsWith(self: *const Parser, text: []const u8) bool {
        return std.mem.startsWith(u8, self.s[self.i..], text);
    }

    fn skipSpace(self: *Parser) void {
        while (self.i < self.s.len and std.ascii.isWhitespace(self.s[self.i])) self.i += 1;
    }

    fn skipPast(self: *Parser, end: []const u8) Error!void {
        const at = std.mem.indexOfPos(u8, self.s, self.i, end) orelse return error.InvalidXml;
        self.i = at + end.len;
    }

    fn name(self: *Parser) Error![]const u8 {
        const start = self.i;
        while (self.i < self.s.len) : (self.i += 1) {
            const ch = self.s[self.i];
            if (std.ascii.isWhitespace(ch) or ch == '>' or ch == '/' or ch == '=') break;
        }
        if (self.i == start) return error.InvalidXml;
        return self.s[start..self.i];
    }

    /// At `<`, through its closing tag.
    fn element(self: *Parser) Error!Node {
        self.i += 1;
        var node: Node = .{ .name = try self.name() };
        var attrs: std.ArrayList(Attr) = .empty;
        while (true) {
            self.skipSpace();
            if (self.i >= self.s.len) return error.InvalidXml;
            if (self.startsWith("/>")) {
                self.i += 2;
                node.attrs = attrs.items;
                return node;
            }
            if (self.s[self.i] == '>') {
                self.i += 1;
                break;
            }
            const attr_name = try self.name();
            self.skipSpace();
            if (self.i >= self.s.len or self.s[self.i] != '=') return error.InvalidXml;
            self.i += 1;
            self.skipSpace();
            if (self.i >= self.s.len) return error.InvalidXml;
            const quote = self.s[self.i];
            if (quote != '"' and quote != '\'') return error.InvalidXml;
            const end = std.mem.indexOfScalarPos(u8, self.s, self.i + 1, quote) orelse return error.InvalidXml;
            try attrs.append(self.arena, .{ .name = attr_name, .value = try decode(self.arena, self.s[self.i + 1 .. end]) });
            self.i = end + 1;
        }
        node.attrs = attrs.items;

        var children: std.ArrayList(Node) = .empty;
        var text: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.i >= self.s.len) return error.InvalidXml;
            if (self.startsWith("</")) {
                self.i += 2;
                const closing = try self.name();
                if (!std.mem.eql(u8, closing, node.name)) return error.InvalidXml;
                self.skipSpace();
                if (self.i >= self.s.len or self.s[self.i] != '>') return error.InvalidXml;
                self.i += 1;
                break;
            }
            if (self.startsWith("<!--")) {
                try self.skipPast("-->");
            } else if (self.startsWith("<![CDATA[")) {
                const start = self.i + 9;
                const end = std.mem.indexOfPos(u8, self.s, start, "]]>") orelse return error.InvalidXml;
                try text.appendSlice(self.arena, self.s[start..end]);
                self.i = end + 3;
            } else if (self.startsWith("<?")) {
                try self.skipPast("?>");
            } else if (self.s[self.i] == '<') {
                try children.append(self.arena, try self.element());
            } else {
                const end = std.mem.indexOfScalarPos(u8, self.s, self.i, '<') orelse self.s.len;
                try text.appendSlice(self.arena, try decode(self.arena, self.s[self.i..end]));
                self.i = end;
            }
        }
        node.children = children.items;
        // Indentation between child elements isn't text
        node.text = if (children.items.len > 0 and std.mem.trim(u8, text.items, " \t\r\n").len == 0) "" else text.items;
        return node;
    }
};

/// Entities to their characters. Unknown ones stay as they are.
pub fn decode(arena: std.mem.Allocator, text: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '&') {
            try out.append(arena, text[i]);
            i += 1;
            continue;
        }
        const semi = std.mem.indexOfScalarPos(u8, text, i, ';') orelse {
            try out.append(arena, '&');
            i += 1;
            continue;
        };
        const entity = text[i + 1 .. semi];
        const named = [_]struct { []const u8, u8 }{ .{ "lt", '<' }, .{ "gt", '>' }, .{ "amp", '&' }, .{ "quot", '"' }, .{ "apos", '\'' } };
        const ch: ?u21 = for (named) |n| {
            if (std.mem.eql(u8, entity, n[0])) break n[1];
        } else if (entity.len > 1 and entity[0] == '#') blk: {
            const hex = entity[1] == 'x' or entity[1] == 'X';
            const digits = if (hex) entity[2..] else entity[1..];
            break :blk std.fmt.parseInt(u21, digits, if (hex) 16 else 10) catch null;
        } else null;
        if (ch) |c| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(c, &buf) catch 0;
            try out.appendSlice(arena, buf[0..n]);
            i = semi + 1;
        } else {
            try out.append(arena, '&');
            i += 1;
        }
    }
    return out.items;
}

const testing = std.testing;

test "entities, CDATA and nesting" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<CheatTable CheatEngineTableVersion="45">
        \\  <!-- a comment -->
        \\  <CheatEntries>
        \\    <CheatEntry>
        \\      <Description>"&lt;variables&gt; &amp; more &#65;&#x42;"</Description>
        \\      <Options moHideChildren="1" moActivateChildrenAsWell='1'/>
        \\      <CheatEntries>
        \\        <CheatEntry><Description>inner</Description></CheatEntry>
        \\      </CheatEntries>
        \\    </CheatEntry>
        \\  </CheatEntries>
        \\  <LuaScript><![CDATA[if a < b then print("<x>") end]]></LuaScript>
        \\</CheatTable>
    ;
    const root = try parse(arena.allocator(), source);
    try testing.expectEqualStrings("CheatTable", root.name);
    try testing.expectEqualStrings("45", root.attr("CheatEngineTableVersion").?);
    const entry = root.child("CheatEntries").?.children[0];
    try testing.expectEqualStrings("\"<variables> & more AB\"", entry.childText("Description").?);
    try testing.expectEqualStrings("1", entry.child("Options").?.attr("moActivateChildrenAsWell").?);
    try testing.expectEqualStrings("inner", entry.child("CheatEntries").?.children[0].childText("Description").?);
    try testing.expectEqualStrings("if a < b then print(\"<x>\") end", root.childText("LuaScript").?);
    try testing.expectError(error.InvalidXml, parse(arena.allocator(), "<a><b></a>"));
}
