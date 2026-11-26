//! A Script document, JavaScript or Lua run in a session of its own. The project's
//! `scripts/x.rws.js` or `scripts/x.rws.lua` once it's changed.

const ScriptEditor = @This();

const std = @import("std");

const api = @import("wraith_api");
const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");

const Workbench = @import("../Workbench.zig");
const Scripts = @import("../Scripts.zig");
const Project = @import("../../../Project.zig");

const max_code = 64 * 1024;
/// Typing pauses this long before the text goes to the project.
const write_delay_ns = 400 * std.time.ns_per_ms;

const example =
    \\// ui, memory, log, keybinds, config and schema are globals here.
    \\// What this starts keeps going until the session's reset (see Sessions)
    \\let frames = 0;
    \\threads.onDraw(() => {
    \\    ui.window("Hello", () => ui.text("frames:", ++frames));
    \\});
;

/// Lua has no ui yet, so it counts and logs.
const example_lua =
    \\-- memory, log, keybinds, config, threads and timers are globals here.
    \\-- What this starts keeps going until the session's reset (see Sessions)
    \\frames = 0
    \\threads.onDraw(function() frames = frames + 1 end)
    \\timers.setInterval(function() print("frames:", frames) end, 1000)
;

window: ui.Window = .{ .title = "Script" },
wb: *Workbench,
session: u32 = 0,
code: ?[:0]u8 = null,
/// After Ctrl+Enter took it.
refocus: bool = false,
/// Typed but not given to the project yet.
pending: bool = false,
last_edit_ns: u64 = 0,
/// It got a project name, so the workbench gives it a new title.
renamed: bool = false,

pub fn init(self: *ScriptEditor, text: ?[]const u8) !void {
    const buf = try self.wb.allocator.allocSentinel(u8, max_code, 0);
    // Empty, with the example as a hint
    const start = text orelse "";
    const n = @min(start.len, max_code);
    @memcpy(buf[0..n], start[0..n]);
    @memset(buf[n..], 0);
    self.code = buf;
}

pub fn deinit(self: *ScriptEditor) void {
    self.flush();
    if (self.code) |c| self.wb.allocator.free(c);
    self.code = null;
}

pub fn projectPath(self: *ScriptEditor) ?[]const u8 {
    const s = self.wb.scripts.find(self.session) orelse return null;
    return s.filePath();
}

/// Shows the project's `path`.
pub fn setProjectFile(self: *ScriptEditor, path: []const u8, text: []const u8) void {
    const code = self.code orelse return;
    const n = @min(text.len, max_code);
    @memcpy(code[0..n], text[0..n]);
    @memset(code[n..], 0);
    self.wb.scripts.bindFile(self.session, path);
    self.pending = false;
    self.renamed = true;
}

/// Gives what's typed to the project. The first time picks a free name.
pub fn flush(self: *ScriptEditor) void {
    if (!self.pending) return;
    self.pending = false;
    const code = self.code orelse return;
    const project = self.wb.project orelse return;
    const path = self.projectPath() orelse blk: {
        var buf: [64]u8 = undefined;
        const want = std.fmt.bufPrint(&buf, "scripts/script{s}", .{self.language().ext()}) catch return;
        const free = project.freeName(want) catch return;
        defer project.allocator.free(free);
        self.wb.scripts.bindFile(self.session, free);
        self.renamed = true;
        break :blk self.projectPath() orelse return;
    };
    project.write(path, std.mem.sliceTo(code, 0)) catch |err| core.log.scoped(.wraith_ui).warn("Couldn't keep {s}: {t}", .{ path, err });
}

fn language(self: *ScriptEditor) Scripts.Language {
    const s = self.wb.scripts.find(self.session) orelse return .js;
    return s.language;
}

fn thread(self: *ScriptEditor) api.script.Thread {
    const s = self.wb.scripts.find(self.session) orelse return .game;
    return s.thread;
}

/// Runs it as the other language from now on, moving its project file to that extension.
fn switchLanguage(self: *ScriptEditor) void {
    const to: Scripts.Language = switch (self.language()) {
        .js => .lua,
        .lua => .js,
    };
    self.wb.scripts.setLanguage(self.session, to);
    const project = self.wb.project orelse return;
    const old = self.projectPath() orelse return;
    const base = std.fs.path.basename(old);
    var buf: [160]u8 = undefined;
    const want = std.fmt.bufPrint(&buf, "{s}{s}{s}", .{ old[0 .. old.len - base.len], base[0 .. std.mem.indexOfScalar(u8, base, '.') orelse base.len], to.ext() }) catch return;
    const moved = project.freeName(want) catch return;
    defer project.allocator.free(moved);
    const code = self.code orelse return;
    project.write(moved, std.mem.sliceTo(code, 0)) catch |err| {
        core.log.scoped(.wraith_ui).warn("Couldn't keep {s}: {t}", .{ moved, err });
        return;
    };
    project.delete(old);
    self.wb.scripts.bindFile(self.session, moved);
    self.pending = false;
    self.renamed = true;
}

pub fn draw(self: *ScriptEditor) void {
    const code = self.code orelse return;
    self.drawStatus();
    const keys = &devtools.keys;
    var go = blk: {
        const mono = ui.monospace();
        defer mono.end();
        if (self.refocus) {
            self.refocus = false;
            ui.focusNext();
        }
        const entered = ui.inputTextMultilineHint("##code", code, .{ ui.fill, ui.fill }, .{ .enter_returns_true = true }, switch (self.language()) {
            .js => example,
            .lua => example_lua,
        });
        if (ui.isItemEdited()) {
            self.pending = true;
            self.last_edit_ns = core.timing.now();
        }
        break :blk entered;
    };
    // Ctrl+Enter makes ImGui let go of the code, so keep typing where you were
    if (go) self.refocus = true;
    // A rebound Run key works while typing too
    if (ui.isItemActive()) if (keys.run) |chord| if (chord.pressed()) {
        go = true;
    };
    if (go) self.run();
    if (self.pending and (core.timing.now() -| self.last_edit_ns > write_delay_ns or !ui.isAnyItemActive())) self.flush();

    var menu = ui.commands("script", .{});
    defer menu.end();
    const lang = self.language();
    if (menu.item(.{ .label = "Run", .chord = keys.run, .tooltip = "All of it, in this document's session" })) self.run();
    if (menu.item(.{ .label = "Reset session", .tooltip = "Stop what it started and forget its variables" })) self.wb.scripts.reset(self.session);
    const switch_label: [:0]const u8 = switch (lang) {
        .js => "Switch to Lua",
        .lua => "Switch to JavaScript",
    };
    if (menu.item(.{ .label = switch_label, .tooltip = "Runs it in the other language from now on, as a .rws.lua or .rws.js file" })) self.switchLanguage();
    const runs_on = self.thread();
    const thread_label: [:0]const u8 = switch (runs_on) {
        .game => "Run on the render thread",
        .render => "Run on the game thread",
    };
    const thread_tip = switch (runs_on) {
        .game => "Where ImGui can be drawn. Starts the session afresh",
        .render => "Where game engines' objects can be used, like Unreal's. Starts the session afresh",
    };
    if (menu.item(.{ .label = thread_label, .tooltip = thread_tip })) self.wb.scripts.setThread(self.session, switch (runs_on) {
        .game => .render,
        .render => .game,
    });
    if (self.projectPath()) |path| if (menu.item(.{ .label = "Remove from the project", .tooltip = "Gone when the project's saved" })) {
        if (self.wb.project) |project| project.delete(path);
        self.wb.scripts.bindFile(self.session, "");
        self.pending = false;
        self.window.open = false;
    };
    menu.separator();
    const files = self.wb.io != null;
    const file_type = switch (lang) {
        .js => Workbench.FileType.script,
        .lua => Workbench.FileType.script_lua,
    };
    if (menu.item(.{ .label = "Export...", .chord = keys.export_file, .enabled = files, .tooltip = "To a .rws.js or .rws.lua file of its own" })) {
        const name = if (self.projectPath()) |p| std.fs.path.basename(p) else switch (lang) {
            .js => "script" ++ Project.ext.script,
            .lua => "script" ++ Project.ext.script_lua,
        };
        self.wb.exportText(file_type, name, std.mem.sliceTo(code, 0));
    }
    if (menu.item(.{ .label = "Import...", .chord = keys.import_file, .enabled = files and self.wb.project != null, .tooltip = "A script file in this document's language, into the project as a new script" })) {
        if (self.wb.importFile(file_type, "scripts")) |path| {
            defer self.wb.project.?.allocator.free(path);
            self.wb.openProjectScript(path);
        }
    }
    menu.separator();
    if (menu.item(.{ .label = "Show console" })) self.wb.groups.scripts.focus(&self.wb.panels.console);
    if (menu.item(.{ .label = "Show sessions" })) self.wb.groups.scripts.focus(&self.wb.panels.sessions);
}

fn run(self: *ScriptEditor) void {
    const code = self.code orelse return;
    const text = std.mem.sliceTo(code, 0);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
    // Where what it prints goes
    self.wb.groups.scripts.show(&self.wb.panels.console);
    self.wb.scripts.run(self.session, text);
}

fn drawStatus(self: *ScriptEditor) void {
    const scripts = &self.wb.scripts;
    const lang = self.language();
    const title = lang.title();
    if (!scripts.ready()) return ui.textDisabled("{s}. Scripts run once Wraith's plugins are up", .{title});
    const on = switch (self.thread()) {
        .game => "the game thread",
        .render => "the render thread",
    };
    const s = scripts.find(self.session);
    if (s != null and s.?.running != null) {
        const r = s.?.running.?;
        ui.textDisabled("{s} session running on {s}: {d} draw callback(s), {d} keybind(s), {d} hook(s)", .{ title, on, r.frames, r.keybinds, r.hooks });
    } else {
        ui.textDisabled("{s}, on {s}. Ctrl+Enter runs it. Right-click for more", .{ title, on });
    }
}
