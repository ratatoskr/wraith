//! Overlay themes, ImGui styles as ZON that override what they list.

const Themes = @This();

const std = @import("std");

const c = @import("imgui.zig").c;

const log = @import("wraith_core").log.scoped(.wraith_ui);
const appearance = @import("tuft_sys").appearance;

pub const default_name = "Dark";
pub const light_name = "Light";

/// A dark and a light one, so following the OS has both. Your own can go in the themes folder.
const builtin_files = [_][:0]const u8{
    @embedFile("themes/dark.zon"),
    @embedFile("themes/light.zon"),
};

pub const Base = enum { dark, light, classic };

/// Every `ImGuiStyle` size, padding and flag in snake_case, all optional.
pub const Style = blk: {
    @setEvalBranchQuota(100_000);
    const info = @typeInfo(c.ImGuiStyle).@"struct";
    var names: []const []const u8 = &.{};
    var types: []const type = &.{};
    for (info.field_names, info.field_types) |name, F| {
        const T = Override(F) orelse continue;
        if (!styled(name)) continue;
        names = names ++ .{snakeCase(name)};
        types = types ++ .{?T};
    }
    break :blk Optional(names, types);
};

/// Every `ImGuiCol_` in snake_case as RGBA, all optional.
pub const Colors = blk: {
    @setEvalBranchQuota(100_000);
    var names: []const []const u8 = &.{};
    var types: []const type = &.{};
    for (colorNames()) |name| {
        names = names ++ .{snakeCase(name)};
        types = types ++ .{?[4]f32};
    }
    break :blk Optional(names, types);
};

pub const File = struct {
    name: ?[]const u8 = null,
    base: Base = .dark,
    style: Style = .{},
    colors: Colors = .{},
};

pub const Theme = struct {
    name: [:0]const u8,
    file: File,
    builtin: bool,

    /// `defaults` is ImGui's unscaled default style.
    pub fn apply(self: *const Theme, style: *c.ImGuiStyle, defaults: *const c.ImGuiStyle) void {
        style.* = defaults.*;
        switch (self.file.base) {
            .dark => c.ImGui_StyleColorsDark(style),
            .light => c.ImGui_StyleColorsLight(style),
            .classic => c.ImGui_StyleColorsClassic(style),
        }
        const info = @typeInfo(c.ImGuiStyle).@"struct";
        inline for (info.field_names, info.field_types) |name, F| {
            if (comptime Override(F) != null and styled(name)) {
                if (@field(self.file.style, snakeCase(name))) |v| @field(style, name) = native(F, v);
            }
        }
        inline for (comptime colorNames()) |name| {
            if (@field(self.file.colors, snakeCase(name))) |v| {
                style.Colors[@intCast(@field(c, "ImGuiCol_" ++ name))] = .{ .x = v[0], .y = v[1], .z = v[2], .w = v[3] };
            }
        }
    }
};

arena: std.heap.ArenaAllocator,
themes: std.ArrayList(Theme) = .empty,

/// Unreadable ones get logged and skipped.
pub fn load(allocator: std.mem.Allocator, io: std.Io, user_dir: ?[]const u8) !Themes {
    var self: Themes = .{ .arena = .init(allocator) };
    errdefer self.arena.deinit();
    for (builtin_files) |source| {
        const theme = try self.parse(source, "built-in theme", true) orelse return error.BadBuiltinTheme;
        try self.themes.append(self.arena.allocator(), theme);
    }
    if (user_dir) |dir| self.loadDir(io, dir) catch |err| log.warn("Couldn't read themes from {s}: {t}", .{ dir, err });
    return self;
}

pub fn deinit(self: *Themes) void {
    self.arena.deinit();
}

pub fn find(self: *const Themes, name: []const u8) *const Theme {
    for (self.themes.items) |*t| {
        if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
    }
    for (self.themes.items) |*t| {
        if (std.mem.eql(u8, t.name, default_name)) return t;
    }
    return &self.themes.items[0];
}

/// The one named, or null for whichever of Dark and Light Windows wants for apps.
pub fn pick(self: *const Themes, name: ?[]const u8) *const Theme {
    if (name) |n| return self.find(n);
    return self.find(if (appearance.mode() == .light) light_name else default_name);
}

pub fn list(self: *const Themes) []const Theme {
    return self.themes.items;
}

fn loadDir(self: *Themes, io: std.Io, path: []const u8) !void {
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);
    const a = self.arena.allocator();
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zon")) continue;
        const source = dir.readFileAllocOptions(io, entry.name, a, .limited(1 << 20), .of(u8), 0) catch |err| {
            log.warn("Couldn't read theme {s}: {t}", .{ entry.name, err });
            continue;
        };
        var theme = try self.parse(source, entry.name, false) orelse continue;
        if (theme.file.name == null) theme.name = try a.dupeSentinel(u8, std.fs.path.stem(entry.name), 0);
        // A user theme with a built-in's name replaces it
        for (self.themes.items) |*t| {
            if (std.ascii.eqlIgnoreCase(t.name, theme.name)) {
                t.* = theme;
                break;
            }
        } else try self.themes.append(a, theme);
        log.info("Loaded theme {s} from {s}", .{ theme.name, entry.name });
    }
}

fn parse(self: *Themes, source: [:0]const u8, what: []const u8, builtin: bool) !?Theme {
    const a = self.arena.allocator();
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const file = std.zon.parse.fromSlice(File, .{
        .gpa = self.arena.child_allocator,
        .arena = a,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| {
        if (err == error.ParseZon) log.warn("{f}", .{diagnostics.fmt(what)}) else log.warn("Couldn't load {s}: {t}", .{ what, err });
        return null;
    };
    return .{ .name = try a.dupeSentinel(u8, file.name orelse "unnamed", 0), .file = file, .builtin = builtin };
}

// Building `Style` and `Colors` from ImGui's own declarations

fn Override(comptime T: type) ?type {
    if (T == f32) return f32;
    if (T == bool) return bool;
    if (T == c.ImVec2) return [2]f32;
    return null;
}

fn native(comptime T: type, value: anytype) T {
    if (T == c.ImVec2) return .{ .x = value[0], .y = value[1] };
    return value;
}

/// Not ImGui's internals or the font scales, those are the overlay's.
fn styled(comptime name: []const u8) bool {
    return name[0] != '_' and !std.mem.startsWith(u8, name, "Font");
}

fn colorNames() []const []const u8 {
    comptime {
        @setEvalBranchQuota(1_000_000);
        var names: []const []const u8 = &.{};
        for (std.meta.declarations(c)) |decl| {
            if (!std.mem.startsWith(u8, decl, "ImGuiCol_") or std.mem.eql(u8, decl, "ImGuiCol_COUNT")) continue;
            if (@TypeOf(@field(c, decl)) != c_int) continue;
            names = names ++ .{decl["ImGuiCol_".len..]};
        }
        return names;
    }
}

fn snakeCase(comptime name: []const u8) []const u8 {
    comptime {
        @setEvalBranchQuota(10_000);
        var out: []const u8 = "";
        for (name, 0..) |ch, i| {
            if (std.ascii.isUpper(ch)) {
                if (i != 0 and (std.ascii.isLower(name[i - 1]) or std.ascii.isDigit(name[i - 1]))) out = out ++ "_";
                out = out ++ .{std.ascii.toLower(ch)};
            } else {
                out = out ++ .{ch};
            }
        }
        return out;
    }
}

fn Optional(comptime names: []const []const u8, comptime types: []const type) type {
    var attrs: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;
    for (types, &attrs) |T, *attr| {
        const default: T = null;
        attr.* = .{ .default_value_ptr = @ptrCast(&default) };
    }
    return @Struct(.auto, null, names, types[0..names.len], &attrs);
}

const tests = struct {
    const testing = std.testing;

    test "snake_case names" {
        try testing.expectEqualStrings("window_bg", comptime snakeCase("WindowBg"));
        try testing.expectEqualStrings("table_row_bg_alt", comptime snakeCase("TableRowBgAlt"));
        try testing.expect(@hasField(Colors, "tab_selected"));
        try testing.expect(@hasField(Colors, "nav_highlight")); // an old name
        try testing.expect(@hasField(Style, "window_padding"));
        try testing.expect(!@hasField(Style, "font_scale_dpi"));
    }

    test "built-in themes" {
        const saved = @import("wraith_core").log.mute(&.{.ui});
        defer @import("wraith_core").log.setFilter(saved);
        var themes = try Themes.load(testing.allocator, testing.io, null);
        defer themes.deinit();
        try testing.expectEqual(builtin_files.len, themes.list().len);
        const dark = themes.find("dark");
        try testing.expectEqualStrings("Dark", dark.name);
        try testing.expectEqualStrings(default_name, themes.find("no such theme").name);
        try testing.expectEqualStrings(light_name, themes.pick("Light").name);
        // Null asks Windows, which says one or the other
        const os = themes.pick(null);
        try testing.expect(os.builtin and (os == themes.find(default_name) or os == themes.find(light_name)));

        const context = c.ImGui_CreateContext(null);
        defer c.ImGui_DestroyContext(context);
        const defaults = c.ImGui_GetStyle().*;
        var style: c.ImGuiStyle = undefined;
        dark.apply(&style, &defaults);
        try testing.expectEqual(4, style.FrameRounding);
        try testing.expectEqual(10, style.WindowPadding.x);
        try testing.expectApproxEqAbs(0.118, style.Colors[c.ImGuiCol_WindowBg].x, 0.001);
        // Not in the theme, so ImGui's default
        try testing.expectEqual(defaults.Alpha, style.Alpha);
    }

    test "user themes" {
        const io = testing.io;
        const saved = @import("wraith_core").log.mute(&.{.ui});
        defer @import("wraith_core").log.setFilter(saved);
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(io, .{ .sub_path = "neon.zon", .data = ".{ .base = .light, .style = .{ .frame_rounding = 7.0 } }" });
        try tmp.dir.writeFile(io, .{ .sub_path = "mine.zon", .data = ".{ .name = \"Dark\", .colors = .{ .text = .{ 1.0, 0.0, 0.0, 1.0 } } }" });
        try tmp.dir.writeFile(io, .{ .sub_path = "broken.zon", .data = ".{ .style = .{ .not_a_thing = 1.0 } }" });
        const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
        defer testing.allocator.free(root);

        var themes = try Themes.load(testing.allocator, io, root);
        defer themes.deinit();
        try testing.expectEqual(builtin_files.len + 1, themes.list().len);
        const neon = themes.find("neon");
        try testing.expectEqual(.light, neon.file.base);
        try testing.expect(!neon.builtin);
        try testing.expect(!themes.find("Dark").builtin);
    }
};

test {
    _ = tests;
}
