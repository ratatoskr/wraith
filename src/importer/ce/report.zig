//! What needs a look after an import, as `import-report.md`.

const std = @import("std");

pub const Stats = struct {
    /// Scripts that came over as working tweaks.
    clean: u32 = 0,
    /// Scripts kept off with their original, for someone to look at.
    review: u32 = 0,
    /// Lua scripts that run live under the CE compatibility layer.
    lua: u32 = 0,
    /// `@tweak`s in the table's file, and `@group`s nested in it.
    tweaks: u32 = 0,
    tweak_groups: u32 = 0,
    injects: u32 = 0,
    patches: u32 = 0,
    bytes: u32 = 0,
    data_fields: u32 = 0,
    keys: u32 = 0,
    /// Entries in the Addresses list that aren't groups.
    records: u32 = 0,
    groups: u32 = 0,
    /// Records that became a tweak's `@data` field instead.
    absorbed: u32 = 0,
    choices: u32 = 0,
    tweak_files: u32 = 0,

    pub fn scripts(self: Stats) u32 {
        return self.clean + self.review + self.lua;
    }

    pub fn add(self: *Stats, other: Stats) void {
        inline for (@typeInfo(Stats).@"struct".field_names) |name| @field(self, name) += @field(other, name);
    }
};

pub const Line = struct {
    what: []const u8,
    why: []const u8,
    where: []const u8,
};

pub const Report = struct {
    arena: std.mem.Allocator,
    look: std.ArrayList(Line) = .empty,
    ambiguous: std.ArrayList(Line) = .empty,
    missing: std.ArrayList(Line) = .empty,
    notes: std.ArrayList([]const u8) = .empty,

    pub fn add(self: *Report, what: []const u8, where: []const u8, comptime format: []const u8, args: anytype) !void {
        try self.look.append(self.arena, .{ .what = what, .where = where, .why = try std.fmt.allocPrint(self.arena, format, args) });
    }

    pub fn note(self: *Report, comptime format: []const u8, args: anytype) !void {
        try self.notes.append(self.arena, try std.fmt.allocPrint(self.arena, format, args));
    }

    pub fn addMissing(self: *Report, name: []const u8, what: []const u8, where: []const u8) !void {
        for (self.missing.items) |*m| if (std.mem.eql(u8, m.why, name)) {
            if (std.mem.indexOf(u8, m.what, what) == null) m.what = try std.fmt.allocPrint(self.arena, "{s}, {s}", .{ m.what, what });
            return;
        };
        try self.missing.append(self.arena, .{ .why = name, .what = what, .where = where });
    }

    pub fn markdown(self: *const Report, name: []const u8, stats: Stats) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(self.arena);
        const w = &out.writer;
        try w.print("# Imported from {s}\n\n", .{name});
        try w.writeAll("The table's scripts are one tweak file in `tweaks/`, nested like the table, and its records are in the Addresses list. Anything below kept its Cheat Engine original as a comment, so nothing's lost.\n\n");
        try w.writeAll("## What came over\n\n| What | How many |\n| --- | --- |\n");
        const rows = [_]struct { []const u8, u32 }{
            .{ "Scripts converted to tweaks", stats.clean },
            .{ "Scripts off for review", stats.review },
            .{ "Lua scripts that run with the CE layer", stats.lua },
            .{ "Tweaks", stats.tweaks },
            .{ "Groups in the tweak file", stats.tweak_groups },
            .{ "`@inject` sections", stats.injects },
            .{ "`@patch` sections", stats.patches },
            .{ "`@bytes` sections", stats.bytes },
            .{ "`@data` fields", stats.data_fields },
            .{ "Hotkeys as `@key`", stats.keys },
            .{ "Address list entries", stats.records },
            .{ "Address list groups", stats.groups },
            .{ "Records that became `@data` fields", stats.absorbed },
            .{ "Dropdowns as Choices or Toggle", stats.choices },
            .{ "Tweak files", stats.tweak_files },
        };
        for (rows) |r| try w.print("| {s} | {d} |\n", .{ r[0], r[1] });

        if (self.notes.items.len > 0) {
            try w.writeAll("\n## Notes\n\n");
            for (self.notes.items) |n| try w.print("- {s}\n", .{n});
        }
        if (self.look.items.len > 0) {
            try w.writeAll("\n## Needs a look\n\n");
            for (self.look.items) |l| try w.print("- **{s}**: {s}. In {s}.\n", .{ l.what, l.why, l.where });
        }
        if (self.missing.items.len > 0) {
            try w.writeAll("\n## Missing names\n\nUsed but never defined in the table. They probably came from another table, a plugin or CE itself.\n\n");
            for (self.missing.items) |m| try w.print("- `{s}`, used by {s}\n", .{ m.why, m.what });
        }
        if (self.ambiguous.items.len > 0) {
            try w.writeAll("\n## Numbers that could be names\n\nCE reads a word like `add` or `BEEF` as hex when nothing has that name, and so did we. Check these are numbers.\n\n");
            for (self.ambiguous.items) |a| try w.print("- `{s}` in {s}\n", .{ a.why, a.what });
        }
        return out.written();
    }
};
