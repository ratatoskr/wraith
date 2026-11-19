//! Xbox and Microsoft Store games.

const std = @import("std");

const platform = @import("wraith_platform");

const game = @import("root.zig");
const fs = @import("fs.zig");

pub const store: game.Store = .xbox;

pub fn discover(arena: std.mem.Allocator, io: std.Io, _: game.Options, into: *std.ArrayList(game.Game)) !void {
    var buf: [26][3]u8 = undefined;
    for (platform.fs.fixedDriveRoots(&buf)) |*root| try discoverIn(arena, io, root, into);
}

pub fn discoverIn(arena: std.mem.Allocator, io: std.Io, drive_root: []const u8, into: *std.ArrayList(game.Game)) !void {
    const gaming_root = try std.fs.path.join(arena, &.{ drive_root, ".GamingRoot" });
    // `.GamingRoot` is `RGBX`, a count, then null-terminated UTF-16 paths
    const bytes = (fs.read(arena, io, gaming_root) catch return) orelse return;
    for (try parseGamingRoot(arena, bytes)) |folder| {
        const games_dir = try std.fs.path.join(arena, &.{ drive_root, folder });
        for (try fs.subdirs(arena, io, games_dir)) |sub| {
            const content_dir = try std.fs.path.join(arena, &.{ games_dir, sub, "Content" });
            var found = try fromFile(arena, io, content_dir, "MicrosoftGame.config") orelse continue;
            found.store_exe = try executable(arena, io, content_dir);
            try into.append(arena, found);
        }
    }
}

fn parseGamingRoot(arena: std.mem.Allocator, bytes: []const u8) ![]const []const u8 {
    if (bytes.len < 8 or !std.mem.eql(u8, bytes[0..4], "RGBX")) return error.InvalidGamingRoot;
    const count = std.mem.readInt(u32, bytes[4..8], .little);
    var folders: std.ArrayList([]const u8) = .empty;
    var rest = bytes[8..];
    for (0..count) |_| {
        var len: usize = 0;
        while (len * 2 + 1 < rest.len and std.mem.readInt(u16, rest[len * 2 ..][0..2], .little) != 0) len += 1;
        if (len * 2 + 1 >= rest.len) return error.InvalidGamingRoot;
        const wide = try arena.alloc(u16, len);
        for (wide, 0..) |*c, i| c.* = std.mem.readInt(u16, rest[i * 2 ..][0..2], .little);
        const utf8 = try arena.alloc(u8, std.unicode.calcWtf8Len(wide));
        try folders.append(arena, utf8[0..std.unicode.wtf16LeToWtf8(utf8, wide)]);
        rest = rest[(len + 1) * 2 ..];
    }
    return folders.items;
}

fn executable(arena: std.mem.Allocator, io: std.Io, content_dir: []const u8) !?[]const u8 {
    const path = try std.fs.path.join(arena, &.{ content_dir, "MicrosoftGame.config" });
    const text = try fs.read(arena, io, path) orelse return null;
    const name = attribute(element(text, "Executable") orelse return null, "Name") orelse return null;
    return try std.fs.path.join(arena, &.{ content_dir, try unescape(arena, name) });
}

pub fn identify(arena: std.mem.Allocator, io: std.Io, exe: []const u8, _: game.Options) !?game.Game {
    var dirs = fs.ancestors(exe, fs.max_depth);
    while (dirs.next()) |dir| {
        if (try fromFile(arena, io, dir, "MicrosoftGame.config")) |found| return found;
        if (try fromFile(arena, io, dir, "AppxManifest.xml")) |found| return found;
    }
    return null;
}

fn fromFile(arena: std.mem.Allocator, io: std.Io, dir: []const u8, file: []const u8) !?game.Game {
    const path = try std.fs.path.join(arena, &.{ dir, file });
    const text = try fs.read(arena, io, path) orelse return null;
    const name = attribute(element(text, "Identity") orelse return null, "Name") orelse return null;
    if (name.len == 0) return null;
    // MicrosoftGame.config has one, AppxManifest.xml has the other. Skip resource references
    const display = attribute(element(text, "ShellVisuals") orelse "", "DefaultDisplayName") orelse
        content(text, "DisplayName");
    const title = if (display) |d| if (std.mem.startsWith(u8, d, "ms-resource:")) null else try unescape(arena, d) else null;
    return .{ .id = try game.id(arena, .xbox, try unescape(arena, name)), .store = .xbox, .name = title, .dir = dir };
}

fn element(text: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '<')) |open| {
        pos = open + 1;
        if (!std.mem.startsWith(u8, text[pos..], name)) continue;
        const after = pos + name.len;
        if (after == text.len or !(std.ascii.isWhitespace(text[after]) or text[after] == '>' or text[after] == '/')) continue;
        const close = std.mem.indexOfScalarPos(u8, text, after, '>') orelse return null;
        return text[after..close];
    }
    return null;
}

/// Still escaped.
fn attribute(attrs: []const u8, name: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, attrs, pos, name)) |at| {
        pos = at + name.len;
        if (at > 0 and !std.ascii.isWhitespace(attrs[at - 1])) continue;
        var i = pos;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i == attrs.len or attrs[i] != '=') continue;
        i += 1;
        while (i < attrs.len and std.ascii.isWhitespace(attrs[i])) i += 1;
        if (i == attrs.len or (attrs[i] != '"' and attrs[i] != '\'')) continue;
        const end = std.mem.indexOfScalarPos(u8, attrs, i + 1, attrs[i]) orelse return null;
        return attrs[i + 1 .. end];
    }
    return null;
}

/// Still escaped.
fn content(text: []const u8, name: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    var close_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{name}) catch return null;
    const close = std.fmt.bufPrint(&close_buf, "</{s}>", .{name}) catch return null;
    const start = (std.mem.indexOf(u8, text, open) orelse return null) + open.len;
    const end = std.mem.indexOfPos(u8, text, start, close) orelse return null;
    return std.mem.trim(u8, text[start..end], " \t\r\n");
}

fn unescape(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '&') == null) return text;
    const entities = [_]struct { []const u8, u8 }{ .{ "&amp;", '&' }, .{ "&lt;", '<' }, .{ "&gt;", '>' }, .{ "&quot;", '"' }, .{ "&apos;", '\'' } };
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    outer: while (i < text.len) {
        for (entities) |e| {
            if (std.mem.startsWith(u8, text[i..], e[0])) {
                try out.append(arena, e[1]);
                i += e[0].len;
                continue :outer;
            }
        }
        try out.append(arena, text[i]);
        i += 1;
    }
    return out.items;
}
