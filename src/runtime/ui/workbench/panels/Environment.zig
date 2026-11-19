//! Wraith's environment.

const Environment = @This();

const std = @import("std");
const builtin = @import("builtin");

const core = @import("wraith_core");
const wraith_platform = @import("wraith_platform");
const memory = @import("tuft_mem");
const ui = @import("wraith_ui");
const wraith_api = @import("wraith_api");
const build_info = @import("build_info");

const Shell = @import("../../shell/Shell.zig");
const Settings = @import("../../../Settings.zig");
const GameInfo = @import("../../../GameInfo.zig");
const LogFile = @import("../../../LogFile.zig");
const Themes = @import("../../Themes.zig");
const Overlay = @import("../../Overlay.zig");
const Graphics = @import("../../../graphics/Graphics.zig");

window: ui.Window = .{ .title = "Wraith Environment", .size = .{ 620, 520 }, .min_size = .{ 420, 260 } },
/// Null without a runtime around it, like in tests.
shell: ?*Shell,

pub fn draw(self: *Environment) void {
    if (section("Wraith")) |t| {
        defer t.end();
        row("Version", "{s}", .{build_info.version});
        row("Platform", "{t}-{t}-{t} ({t})", .{ builtin.cpu.arch, builtin.os.tag, builtin.abi, builtin.mode });
        if (self.shell) |shell| row("Uptime", "{f}", .{Duration{ .ns = core.timing.now() -| shell.started_ns }});
        row("Log level", "{t}", .{logLevel()});
        if (self.shell) |shell| row("Plugins loaded", "{d}", .{shell.pluginCount()});
    }

    if (section("Game")) |t| {
        defer t.end();
        const game = &GameInfo.global;
        row("Executable", "{s}", .{game.name()});
        row("Path", "{s}", .{game.path()});
        row("ID", "{s}", .{game.id()});
        if (game.title().len > 0) row("From", "{t}: {s}", .{ game.store, game.title() });
        if (game.version) |v| {
            row("File version", "{f}", .{v.file});
            row("Product version", "{f}", .{v.product});
        } else row("Version", "none in the executable", .{});
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.textDisabled("sha-512", .{});
        _ = ui.tableNextColumn();
        switch (game.hash_state.load(.acquire)) {
            .idle, .hashing => ui.textDisabled("working it out...", .{}),
            .failed => ui.textDisabled("couldn't read the executable", .{}),
            .done => {
                var hex: [129]u8 = undefined;
                @memcpy(hex[0..128], &std.fmt.bytesToHex(game.digest, .lower));
                hex[128] = 0;
                ui.textDisabled("took {d:.0} ms", .{@as(f64, @floatFromInt(game.hash_ns)) / std.time.ns_per_ms});
                ui.copyableText("##sha512", "{s}", .{hex[0..128]});
            },
        }
    }

    if (section("Process")) |t| {
        defer t.end();
        var buf: [1024]u8 = undefined;
        row("Process ID", "{d}", .{wraith_platform.process.currentId()});
        const runtime = memory.Module.self();
        row("Runtime", "{s}", .{runtime.path(&buf) orelse "?"});
        row("Runtime base", "0x{x}", .{runtime.base});
        if (wraith_platform.process.memoryInfo()) |m| row("Working set", "{Bi:.1}", .{m.working_set});
    }

    const shell = self.shell orelse {
        self.drawToolchain();
        return;
    };

    if (section("Overlay")) |t| {
        defer t.end();
        const api = if (shell.overlay.graphicsApi()) |a| std.enums.tagName(Graphics.Api, a) orelse "unknown" else "none yet";
        row("Graphics", "{s}", .{api});
        if (shell.options.themes) |themes| themeRow(shell, themes);
        row("Cursor requests", "{d}", .{shell.overlay.cursor_requests.load(.acquire)});
        inline for (comptime std.enums.values(Overlay.Device)) |device| {
            row(@tagName(device), "taken {d}, {s}", .{ shell.overlay.takes.getPtrConst(device).load(.acquire), if (shell.overlay.enabled.getPtrConst(device).load(.acquire)) "on" else "off" });
        }
    }

    // Written once on the render thread before its first frame, which is when the API shows up
    if (shell.overlay.graphicsApi() != null) if (shell.overlay.graphics.dlls) |*report| if (section("Graphics DLLs")) |t| {
        defer t.end();
        for (report.dlls) |*d| {
            const scope = ui.id(d.name);
            defer scope.end();
            ui.tableNextRow();
            _ = ui.tableNextColumn();
            ui.textDisabled("{s}", .{d.name});
            _ = ui.tableNextColumn();
            ui.copyableText("##what", "{f}", .{Graphics.Described{ .dll = d }});
            ui.copyableText("##path", "{s}", .{d.path});
        }
    };

    if (section("Paths")) |t| {
        defer t.end();
        if (shell.acquireLoader()) |loader| {
            defer shell.releaseLoader();
            row("Mods", "{s}", .{loader.plugins_dir});
            row("Dev plugins", "{s}  (wraith dev add <folder>, then Rescan)", .{loader.dev_file});
            row("Load copies", "{s}", .{loader.copies_dir});
            row("Settings", "{s}", .{loader.config_dir});
            var buf: [1024]u8 = undefined;
            var fba: std.heap.FixedBufferAllocator = .init(&buf);
            if (Settings.valuesPathAlloc(fba.allocator(), loader.config_dir)) |path| row("Wraith's settings", "{s}", .{path}) else |_| {}
            row("This game's settings", "{s}", .{loader.game_config_dir});
        }
        if (shell.overlay.ini_path) |path| row("Window layout", "{s}", .{path});
        if (LogFile.global.path().len > 0) row("Log file", "{s}", .{LogFile.global.path()});
    }

    self.drawToolchain();
}

fn drawToolchain(_: *Environment) void {
    if (section("Toolchain")) |t| {
        defer t.end();
        row("Zig", "{s}", .{builtin.zig_version_string});
        row("ImGui", "{s} (built against {d}.{d}.{d})", .{ ui.getVersion(), ui.version / 10000, (ui.version / 100) % 100, ui.version % 100 });
    }
}

fn section(comptime title: [:0]const u8) ?ui.Table {
    if (!ui.collapsingHeader(title, true)) return null;
    const t = ui.table(title, 2, .{ .row_background = true, .sizing = .stretch_prop }) orelse return null;
    ui.tableColumnWith("name", .{ .fixed = true, .width = 130 });
    ui.tableColumnWith("value", .{ .stretch = true });
    return t;
}

fn row(comptime label: [:0]const u8, comptime fmt: []const u8, args: anytype) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.textDisabled(label, .{});
    _ = ui.tableNextColumn();
    ui.copyableText("##" ++ label, fmt, args);
}

fn themeRow(shell: *Shell, themes: *const Themes) void {
    ui.tableNextRow();
    _ = ui.tableNextColumn();
    ui.textDisabled("Theme", .{});
    _ = ui.tableNextColumn();
    // Following Windows comes first
    var names: [32][:0]const u8 = undefined;
    names[0] = "Match Windows";
    const all = themes.list();
    const n = @min(all.len, names.len - 1);
    var selected: usize = 0;
    for (all[0..n], names[1..][0..n], 1..) |*t, *name, i| {
        name.* = t.name;
        if (!shell.themeFollowsOs() and shell.overlay.currentTheme() == t) selected = i;
    }
    const before = selected;
    ui.setNextItemWidth(ui.fill);
    if (ui.combo("##theme", &selected, names[0 .. n + 1]) and selected != before) shell.setTheme(if (selected == 0) null else &all[selected - 1]);
    ui.tooltip("Dark, Light, or your own: .zon files in the themes folder beside the settings", .{});
}

fn logLevel() std.log.Level {
    const levels = core.log.filter().levels;
    var most: std.log.Level = .err;
    for (std.enums.values(std.log.Level)) |level| {
        if (levels.contains(level)) most = level;
    }
    return most;
}

const Duration = struct {
    ns: u64,

    pub fn format(self: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const s = self.ns / std.time.ns_per_s;
        if (s >= 3600) try w.print("{d}h ", .{s / 3600});
        if (s >= 60) try w.print("{d:0>2}m ", .{(s / 60) % 60});
        try w.print("{d:0>2}s", .{s % 60});
    }
};
