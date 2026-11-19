//! Converted scripts to `.rwt` text.

const std = @import("std");

const convert = @import("convert.zig");
const lua = @import("lua.zig");

/// One `@tweak`, or a group's shared part.
pub const Part = struct {
    title: []const u8,
    key: ?[]const u8 = null,
    tweak: convert.Tweak,
    /// The CE script, kept as a comment when it's off.
    original: []const u8 = "",
};

pub const File = struct {
    /// Null for a file that's one tweak.
    group: ?[]const u8 = null,
    shared: ?Part = null,
    tweaks: []const Part,
};

/// The file, and the line each part starts on, from 1.
pub const Rendered = struct {
    text: []const u8,
    /// One for each tweak, after the shared part's if there is one.
    starts: []const u32,
};

pub fn file(arena: std.mem.Allocator, f: File) !Rendered {
    var w: Writer = .{ .arena = arena };
    var starts: std.ArrayList(u32) = .empty;
    if (f.group) |g| {
        try starts.append(arena, w.line);
        try w.print("@group \"{s}\"\n", .{g});
        if (f.shared) |s| try part(&w, s);
    }
    for (f.tweaks) |t| {
        if (w.out.items.len > 0) try w.text("\n");
        try starts.append(arena, w.line);
        try w.print("@tweak \"{s}\"\n", .{t.title});
        if (t.key) |k| try w.print("@key {s}\n", .{k});
        try part(&w, t);
    }
    return .{ .text = w.out.items, .starts = starts.items };
}

/// A group or a tweak in a table's one file, nested like the table.
pub const Node = struct {
    group: bool,
    title: []const u8,
    /// `@children`, when it isn't the default `on off`.
    children: ?[]const u8 = null,
    /// `@use`s, for the file's group.
    uses: []const []const u8 = &.{},
    /// `@globals shared`, for the file's group, since CE runs a table in one Lua state.
    shares_globals: bool = false,
    /// A group's shared code from its CE script, or a tweak's.
    part: ?Part = null,
    /// Lua at the top of a group's shared part, like the records manifest and the table's own.
    lua_head: []const u8 = "",
    nodes: []const Node = &.{},
};

/// The table's file from its top group. `starts` has a line for each node, in order.
pub fn tree(arena: std.mem.Allocator, top: Node) !Rendered {
    var w: Writer = .{ .arena = arena };
    var starts: std.ArrayList(u32) = .empty;
    try node(&w, &starts, top, true);
    return .{ .text = w.out.items, .starts = starts.items };
}

fn node(w: *Writer, starts: *std.ArrayList(u32), n: Node, top: bool) !void {
    if (w.out.items.len > 0) try w.text("\n");
    try starts.append(w.arena, w.line);
    if (!n.group) {
        try w.print("@tweak \"{s}\"\n", .{n.title});
        if (n.part) |p| {
            if (p.key) |k| try w.print("@key {s}\n", .{k});
            try part(w, p);
        }
        return;
    }
    try w.print("@group \"{s}\"\n", .{n.title});
    if (n.children) |c| try w.print("@children {s}\n", .{c});
    if (n.part) |p| if (p.key) |k| try w.print("@key {s}\n", .{k});
    if (n.shares_globals) try w.text("@globals shared\n");
    for (n.uses) |u| try w.print("@use {s}\n", .{u});
    if (n.lua_head.len > 0) {
        var code: std.ArrayList(u8) = .empty;
        try code.appendSlice(w.arena, "@lua\n");
        try lua.appendCode(w.arena, &code, n.lua_head);
        try w.text(code.items);
    }
    if (n.part) |p| try part(w, p);
    for (n.nodes) |c| try node(w, starts, c, false);
    if (!top) try w.text("@end\n");
}

const Writer = struct {
    arena: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    line: u32 = 1,

    fn text(self: *Writer, t: []const u8) !void {
        try self.out.appendSlice(self.arena, t);
        self.line += @intCast(std.mem.count(u8, t, "\n"));
    }

    fn print(self: *Writer, comptime format: []const u8, args: anytype) !void {
        try self.text(try std.fmt.allocPrint(self.arena, format, args));
    }

    /// Each line of `t` as a `//` comment.
    fn commented(self: *Writer, t: []const u8) !void {
        var it = std.mem.splitScalar(u8, std.mem.trim(u8, t, "\r\n"), '\n');
        while (it.next()) |l| {
            const trimmed = std.mem.trimEnd(u8, l, " \t\r");
            try self.print("//{s}{s}\n", .{ if (trimmed.len > 0) " " else "", trimmed });
        }
    }
};

fn part(w: *Writer, p: Part) !void {
    const t = p.tweak;
    for (t.comments) |c| try w.print("// ce: {s}\n", .{c});
    switch (t.status) {
        .review => {
            for (t.problems) |why| try w.print("// ce: off for review, {s}\n", .{why});
            try w.text("// ce: the original script, from Cheat Engine\n");
            try w.commented(p.original);
            return;
        },
        .lua => {
            const l = t.lua.?;
            try w.text(try lua.section(w.arena, l.pre, l.on, l.off));
            return;
        },
        .clean => {},
    }
    for (t.syms) |s| try w.print("@sym {s} = {s}\n", .{ s.name, s.where });
    if (t.fields.len > 0) {
        if (t.near.len > 0) try w.print("@data near {s}\n", .{t.near}) else try w.text("@data\n");
        for (t.fields) |f| {
            try w.text("  ");
            if (f.label.len > 0 or f.attrs.len > 0) {
                try w.text("[");
                if (f.label.len > 0) try w.print("Label(\"{s}\")", .{f.label});
                if (f.label.len > 0 and f.attrs.len > 0) try w.text(", ");
                try w.text(f.attrs);
                try w.text("] ");
            }
            try w.print("{s} {s} = {s}\n", .{ f.type, f.name, f.value });
        }
    }
    for (t.code) |c| {
        try w.print("@{t} {s}", .{ c.kind, c.where });
        if (c.size > 0) try w.print(" ({d})", .{c.size});
        if (c.expect.len > 0) try w.print(" expect \"{s}\"", .{c.expect});
        try w.text("\n");
        for (c.lines) |l| try w.print("  {s}\n", .{l});
    }
    // Its {$lua} parts, run as it turns on, with the asm parts' data there
    if (t.lua) |l| try w.text(try lua.section(w.arena, l.pre, l.on, l.off));
}

/// A file name for `title`, like `infinite_hp` for "Infinite HP".
pub fn slug(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var gap = false;
    for (text) |ch| {
        if (std.ascii.isAlphanumeric(ch)) {
            if (gap and out.items.len > 0) try out.append(arena, '_');
            gap = false;
            try out.append(arena, std.ascii.toLower(ch));
            if (out.items.len >= 40) break;
        } else gap = true;
    }
    if (out.items.len == 0) return "tweak";
    if (std.ascii.isDigit(out.items[0])) try out.insert(arena, 0, '_');
    return out.items;
}

/// Something that can go in `"..."`, on one line.
pub fn title(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (std.mem.trim(u8, text, " \t\r\n")) |ch| switch (ch) {
        '"' => try out.append(arena, '\''),
        '\r', '\n', '\t' => try out.append(arena, ' '),
        else => try out.append(arena, ch),
    };
    if (out.items.len == 0) return "Untitled";
    return out.items;
}

test "names for files and titles" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("infinite_hp_mp", try slug(a, "Infinite HP/MP!"));
    try std.testing.expectEqualStrings("_2x_exp", try slug(a, "2x EXP"));
    try std.testing.expectEqualStrings("tweak", try slug(a, "???"));
    try std.testing.expectEqualStrings("Say 'hi'", try title(a, " Say \"hi\"\n"));
}
