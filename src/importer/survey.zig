//! `zig build ce-survey` imports every Cheat Engine table under a folder, `D:\Modding` unless
//! one's given, and says how each game's went. Every file it makes goes through the tweak parser,
//! and every Lua part through Lua 5.5's compiler, the way the runtime would load them. For
//! working on the importer, not shipped. `--out <folder>` writes each project there too.

const std = @import("std");
const ce = @import("wraith_importer").ce;
const tweak = @import("wraith_api").tweak;
const lua = @import("lua");

const Folder = struct {
    name: []const u8,
    stats: ce.Stats = .{},
    tables: u32 = 0,
    failed: u32 = 0,
    /// Files the parser turned down, and Lua parts that don't compile.
    unparsed: u32 = 0,
    uncompiled: u32 = 0,
};

const Reason = struct {
    text: []const u8,
    n: u32,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    var root: []const u8 = "D:\\Modding";
    var out_dir: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) out_dir = args.next() else root = arg;
    }

    var buf: [8192]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buf);
    const w = &stdout.interface;

    var tables: std.ArrayList([]const u8) = .empty;
    var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit(io);
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.ascii.endsWithIgnoreCase(entry.basename, ".ct")) try tables.append(arena, try arena.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, tables.items, {}, lessThan);

    const state = lua.luaL_newstate() orelse return error.OutOfMemory;
    defer lua.lua_close(state);

    var folders: std.ArrayList(Folder) = .empty;
    var reasons: std.ArrayList(Reason) = .empty;
    var problems: std.ArrayList([]const u8) = .empty;
    var total: Folder = .{ .name = "total" };
    for (tables.items) |path| {
        const folder_name = std.fs.path.dirname(path) orelse ".";
        const folder = for (folders.items) |*f| {
            if (std.mem.eql(u8, f.name, folder_name)) break f;
        } else blk: {
            try folders.append(arena, .{ .name = folder_name });
            break :blk &folders.items[folders.items.len - 1];
        };
        folder.tables += 1;
        total.tables += 1;

        var scratch: std.heap.ArenaAllocator = .init(gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const source = try dir.readFileAlloc(io, path, a, .limited(64 << 20));
        const project = ce.import(a, gpa, source, .{ .name = std.fs.path.basename(path) }) catch |err| {
            try w.print("{s}: {t}\n", .{ path, err });
            folder.failed += 1;
            total.failed += 1;
            continue;
        };
        folder.stats.add(project.stats);
        total.stats.add(project.stats);
        for (project.reviews) |why| try tally(arena, &reasons, why);
        for (project.files) |f| {
            if (!std.mem.endsWith(u8, f.path, ".rwt")) continue;
            var problem: tweak.Problem = .{};
            const file = tweak.parseFile(a, f.text, &problem) catch {
                folder.unparsed += 1;
                total.unparsed += 1;
                try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s} line {d}: {s}", .{ path, f.path, problem.line, problem.message() }));
                continue;
            };
            if (file.script != .lua) continue;
            var parts: std.ArrayList(tweak.Part) = .empty;
            for (0..file.groups.len) |g| try parts.append(a, .{ .group = g });
            for (0..file.tweaks.len) |i| try parts.append(a, .{ .tweak = i });
            for (parts.items) |part| {
                const code = try tweak.compilePart(a, f.text, file, part, &.{});
                if (lua.luaL_loadbufferx(state, @ptrCast(code.ptr), code.len, @ptrCast("=part"), @ptrCast("t")) == lua.LUA_OK) {
                    lua.lua_settop(state, 0);
                    continue;
                }
                var len: usize = 0;
                const msg = lua.lua_tolstring(state, -1, &len);
                const text = if (msg) |m| @as([*]const u8, @ptrCast(m))[0..len] else "?";
                try problems.append(arena, try std.fmt.allocPrint(arena, "{s}: {s} {s}: {s}", .{ path, f.path, file.pathOf(part), text }));
                lua.lua_settop(state, 0);
                folder.uncompiled += 1;
                total.uncompiled += 1;
            }
        }
        if (out_dir) |o| {
            const stem = std.fs.path.stem(path);
            const target = try std.fs.path.join(a, &.{ o, folder_name, stem });
            try ce.zip.save(io, gpa, target, project.files);
        }
    }

    try w.print("{s: <16} {s: >6} {s: >6} {s: >6} {s: >6} {s: >6} {s: >5} {s: >7} {s: >7}\n", .{ "folder", "tables", "groups", "tweaks", "clean", "review", "lua", "noparse", "nocomp" });
    for (folders.items) |f| try row(w, f);
    try row(w, total);
    for (folders.items) |f| if (f.failed > 0) try w.print("{s}: {d} tables didn't read\n", .{ f.name, f.failed });

    std.mem.sort(Reason, reasons.items, {}, moreCommon);
    try w.writeAll("\nWhy scripts are off for review, most common first\n");
    for (reasons.items[0..@min(reasons.items.len, 40)]) |r| try w.print("{d: >5}  {s}\n", .{ r.n, r.text });
    if (problems.items.len > 0) {
        try w.writeAll("\nFiles that don't parse and Lua that doesn't compile\n");
        for (problems.items) |p| try w.print("  {s}\n", .{p[0..@min(p.len, 220)]});
    }
    try w.flush();
}

fn row(w: *std.Io.Writer, f: Folder) !void {
    const s = f.stats;
    try w.print("{s: <16} {d: >6} {d: >6} {d: >6} {d: >6} {d: >6} {d: >5} {d: >7} {d: >7}\n", .{ f.name[0..@min(f.name.len, 16)], f.tables, s.tweak_groups, s.tweaks, s.clean, s.review, s.lua, f.unparsed, f.uncompiled });
}

/// Names and numbers taken out so alike ones group.
fn tally(arena: std.mem.Allocator, reasons: *std.ArrayList(Reason), why: []const u8) !void {
    var it = std.mem.splitSequence(u8, why, ", and ");
    while (it.next()) |one| {
        var out: std.ArrayList(u8) = .empty;
        var skipping = false;
        for (one) |ch| {
            if (ch == '`') skipping = !skipping;
            if (skipping) continue;
            if (std.ascii.isDigit(ch)) continue;
            try out.append(arena, ch);
        }
        const text = generic(out.items);
        const found = for (reasons.items) |*r| {
            if (std.mem.eql(u8, r.text, text)) break r;
        } else null;
        if (found) |r| r.n += 1 else try reasons.append(arena, .{ .text = try arena.dupe(u8, text), .n = 1 });
    }
}

/// Cut where the specifics start, like the name after "uses".
fn generic(text: []const u8) []const u8 {
    const cuts = [_][]const u8{ " uses ", " writes to ", " jumps to ", " has more ", " doesn't put ", ", which", " didn't come over:", " has a label", " isn't ", " is shared", " doesn't assemble", " didn't parse" };
    var end = @min(text.len, 110);
    for (cuts) |c| if (std.mem.indexOf(u8, text, c)) |at| {
        end = @min(end, at + c.len);
    };
    return text[0..end];
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.ascii.lessThanIgnoreCase(a, b);
}

fn moreCommon(_: void, a: Reason, b: Reason) bool {
    return a.n > b.n;
}
