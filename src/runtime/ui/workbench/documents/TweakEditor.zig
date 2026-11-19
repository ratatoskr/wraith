//! A tweak, a project's `.rwt`. The text lives in the project, so closing this loses nothing.

const TweakEditor = @This();

const std = @import("std");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const ui = @import("wraith_ui");
const Text = @import("tuft_text").Text;

const Workbench = @import("../Workbench.zig");
const Project = @import("../../../Project.zig");

const max_code = 64 * 1024;
/// Typing pauses this long before the text goes to the project.
const write_delay_ns = 400 * std.time.ns_per_ms;
const red: ui.Color = .{ 1, 0.4, 0.4, 1 };

pub const template =
    \\// @tweak "Its name in the menu"
    \\// @key F8
    \\// @mode action runs it once, like a button
    \\
    \\// Values asm and scripts use by name. They show as controls with the tweak
    \\@data
    \\  [Label("Multiplier"), Min(1), Max(100)] u32 multiplier = 2
    \\
    \\// Code changes go in when it's on and come back out when it's off. Hex needs 0x
    \\// Addresses can use the game's names too, like (kai.hp)+8 or [player.base]+0x10
    \\// While it's on, everything else sees its names like xp.multiplier for tweaks/xp.rwt
    \\// @patch replaces the instruction there, or (n) bytes, or what expect matches
    \\// expect takes bytes like "8B 80 98 00 00 00" or asm like "mov eax, [rax+0x98]; ret"
    \\// @patch game.exe+0x1234 expect "mov eax, [rax+0x98]"
    \\//   mov eax, [rax+0x98]
    \\//   imul eax, [multiplier]
    \\// @inject puts code before the instruction there, which still runs after it
    \\// @inject sig("8B 80 98 00 00 00")
    \\//   inc dword ptr [multiplier]
    \\// Either takes JS instead with an @js first line, given cpu, original() and resume()
    \\// @patch game.exe+0x1234
    \\//   @js
    \\//   cpu.rax = Number(cpu.rax) * data.multiplier
    \\// @hook replaces a function, calling the real one with original(...)
    \\// @hook sig("40 53 48 83 EC 20") as i32 (i32 damage)
    \\//   return original(damage * data.multiplier)
    \\// Like Lua better? Use @lua wherever @js goes. A tweak is all JS or all Lua
    \\// More than one @tweak makes the file a group, sharing what's above the first. Groups nest
    \\// with @group "Name" ... @end. See New group
    \\
    \\@js
    \\// Runs when it's turned on. tick() runs each frame, off() when it's turned off
    \\
;

/// For "New group". Same as a tweak's, apart from the shared parts and a group nested in it.
pub const group_template =
    \\// A group's tweaks share what's above the first @tweak or @group. Its shared part is up while
    \\// its box is on or anything in it is
    \\// @group "Its name in the menu", else it goes by the file's
    \\// @children right after it says what its box does to what's in it: on off, on, off or none
    \\
    \\// Data, names, code changes and script everything below can use
    \\@data
    \\  [Label("Multiplier"), Min(1), Max(100)] u32 multiplier = 2
    \\
    \\@js
    \\// Functions here can be called from each tweak, and Choices(...) there can name them
    \\function twice(n) { return n * 2; }
    \\
    \\@tweak "First"
    \\// @key F8
    \\@js
    \\// Its own top level, so its names don't meet the other tweaks'. off() runs when it's turned off
    \\
    \\// A group in a group runs to its @end, with a shared part and a box of its own
    \\@group "Inner"
    \\@children on off
    \\@js
    \\function thrice(n) { return n * 3; }
    \\
    \\@tweak "Second"
    \\@js
    \\// Sees thrice() and twice() both
    \\
    \\@end
    \\
;

window: ui.Window = .{ .title = "Tweak" },
wb: *Workbench,
/// Empty for a new one, till something's typed and it gets a file.
path: Text(128) = .{},
/// What a new one's hint shows, and what its file's called.
kind: Kind = .tweak,
/// It got a file, so the workbench gives it a new title.
renamed: bool = false,
code: ?[:0]u8 = null,
/// The project's version when the text was read, to notice changes from elsewhere.
seen_version: u32 = 0,
/// Typed but not given to the project yet.
pending: bool = false,
last_edit_ns: u64 = 0,
refocus: bool = false,

pub const Kind = enum { tweak, group };

/// A project's tweak, or a new one with no file yet for null.
pub fn init(self: *TweakEditor, path: ?[]const u8, kind: Kind) !void {
    if (path) |p| {
        if (p.len > self.path.buf.len) return error.NameTooLong;
        self.path.set(p);
    }
    self.kind = kind;
    self.code = try self.wb.allocator.allocSentinel(u8, max_code, 0);
    @memset(self.code.?, 0);
    self.reload();
}

pub fn isNew(self: *const TweakEditor) bool {
    return self.path.len() == 0;
}

/// Empty again, for when the project goes.
pub fn clear(self: *TweakEditor) void {
    if (self.code) |c| @memset(c, 0);
    self.pending = false;
}

pub fn deinit(self: *TweakEditor) void {
    self.flush();
    if (self.code) |c| self.wb.allocator.free(c);
    self.code = null;
}

pub fn filePath(self: *const TweakEditor) []const u8 {
    return self.path.get();
}

/// `x` for `tweaks/x.rwt`.
pub fn name(self: *const TweakEditor) []const u8 {
    const base = std.fs.path.basename(self.filePath());
    return base[0..base.len -| Project.ext.tweak.len];
}

fn project(self: *TweakEditor) ?*Project {
    return self.wb.project;
}

fn reload(self: *TweakEditor) void {
    const code = self.code orelse return;
    const p = self.project() orelse return;
    self.seen_version = p.version();
    if (self.isNew()) return;
    const text = (p.read(self.wb.allocator, self.filePath()) catch null) orelse return;
    defer self.wb.allocator.free(text);
    const n = @min(text.len, max_code);
    @memcpy(code[0..n], text[0..n]);
    @memset(code[n..], 0);
    self.pending = false;
}

/// Gives what's typed to the project.
pub fn flush(self: *TweakEditor) void {
    if (!self.pending) return;
    self.pending = false;
    const code = self.code orelse return;
    const p = self.project() orelse return;
    if (self.isNew()) {
        if (code[0] == 0) return;
        const want = switch (self.kind) {
            .tweak => "tweaks/tweak" ++ Project.ext.tweak,
            .group => "tweaks/group" ++ Project.ext.tweak,
        };
        const free = p.freeName(want) catch return;
        defer p.allocator.free(free);
        if (free.len > self.path.buf.len) return;
        self.path.set(free);
        self.renamed = true;
    }
    p.write(self.filePath(), std.mem.sliceTo(code, 0)) catch |err| core.log.scoped(.wraith_ui).warn("Couldn't keep {s}: {t}", .{ self.filePath(), err });
    self.seen_version = p.version();
}

pub fn draw(self: *TweakEditor) void {
    const code = self.code orelse return;
    const p = self.project() orelse {
        ui.textDisabled("No project open", .{});
        return;
    };
    // Changed elsewhere, like a merge
    if (!self.pending and p.version() != self.seen_version) self.reload();
    self.drawStatus();

    const keys = &devtools.keys;
    var run = false;
    {
        const mono = ui.monospace();
        defer mono.end();
        if (self.refocus) {
            self.refocus = false;
            ui.focusNext();
        }
        const hint = switch (self.kind) {
            .tweak => template,
            .group => group_template,
        };
        if (ui.inputTextMultilineHint("##code", code, .{ ui.fill, ui.fill }, .{ .enter_returns_true = true }, hint)) {
            run = true;
            self.refocus = true;
        }
        if (ui.isItemEdited()) {
            self.pending = true;
            self.last_edit_ns = core.timing.now();
        }
        if (ui.isItemActive() and pressed(keys.run)) run = true;
    }
    if (self.pending and (core.timing.now() -| self.last_edit_ns > write_delay_ns or !ui.isAnyItemActive())) self.flush();
    if (run) self.runNow();

    var menu = ui.commands("tweak", .{});
    defer menu.end();
    const tweaks = self.wb.tweaks;
    const on = self.isOn();
    if (menu.item(.{ .label = if (on) "Run again" else "Turn on", .chord = keys.run, .enabled = tweaks != null, .tooltip = "As it is now, saved or not" })) self.runNow();
    if (menu.item(.{ .label = "Turn off", .enabled = on, .tooltip = "With everything in it" })) tweaks.?.turnOff(self.name());
    menu.separator();
    const files = self.wb.io != null;
    if (menu.item(.{ .label = "Export...", .chord = keys.export_file, .enabled = files and !self.isNew(), .tooltip = "To a .rwt file of its own" })) {
        @import("../panels/Tweaks.zig").exportTweak(self.wb, self.filePath());
    }
    if (menu.item(.{ .label = "Import...", .chord = keys.import_file, .enabled = files, .tooltip = "A .rwt file, into the project as a new tweak" })) {
        if (self.wb.importFile(Workbench.FileType.tweak, "tweaks")) |path| {
            defer p.allocator.free(path);
            self.wb.openTweak(path);
        }
    }
    menu.separator();
    if (menu.item(.{ .label = "Show tweaks" })) self.wb.panels.tweaks.window.focus();
}

fn pressed(chord: ?ui.Chord) bool {
    const ch = chord orelse return false;
    return ch.pressed();
}

fn isOn(self: *TweakEditor) bool {
    if (self.isNew()) return false;
    const tweaks = self.wb.tweaks orelse return false;
    var arena: std.heap.ArenaAllocator = .init(self.wb.allocator);
    defer arena.deinit();
    const list = tweaks.snapshot(arena.allocator()) catch return false;
    for (list) |t| if (std.mem.eql(u8, t.name, self.name())) return t.on or t.partial;
    return false;
}

fn runNow(self: *TweakEditor) void {
    self.flush();
    if (self.isNew()) return;
    const tweaks = self.wb.tweaks orelse return;
    if (self.isOn()) tweaks.rerun(self.name()) else tweaks.setOn(self.name(), true);
}

fn drawStatus(self: *TweakEditor) void {
    if (self.isNew()) return ui.textDisabled("A new {s}. It goes in the project once you type, and Ctrl+Enter turns it on", .{@tagName(self.kind)});
    const tweaks = self.wb.tweaks orelse {
        ui.textDisabled("{s}", .{self.filePath()});
        return;
    };
    var arena: std.heap.ArenaAllocator = .init(self.wb.allocator);
    defer arena.deinit();
    const list = tweaks.snapshot(arena.allocator()) catch return;
    for (list) |t| if (std.mem.eql(u8, t.name, self.name())) {
        if (t.problem) |problem| return ui.textColored(red, "{s}", .{problem});
        if (t.on or t.partial) return ui.textDisabled("On. Ctrl+Enter runs it again as it is now", .{});
        return ui.textDisabled("Off. Ctrl+Enter turns it on", .{});
    };
    ui.textDisabled("{s}", .{self.filePath()});
}
