//! The overlay's settings window, built from the registry: Wraith's sections, a page per plugin,
//! mod or project, and every key. Changes apply live; drags and typing save once done. Render thread.

const SettingsWindow = @This();

const std = @import("std");

const core = @import("wraith_core");
const ui = @import("wraith_ui");
const Chord = @import("wraith_platform").input.Chord;
const Keys = @import("wraith_platform").input.Keys;
const Keybinds = @import("tuft_input").Keybinds;
const tuft_window = @import("tuft_window");
const sync = @import("tuft_sys").sync;

const icons = @import("../fonts.zig").icons;
const Settings = @import("../../Settings.zig");
const Registry = Settings.Registry;
const Setting = Registry.Setting;
const Shell = @import("Shell.zig");
const Workbench = @import("../workbench/Workbench.zig");
const GameSpeed = @import("../GameSpeed.zig");
const slots = @import("../../host/slots.zig");

const log = core.log.scoped(.wraith_ui);

window: ui.Window = .{ .title = "Wraith Settings###wraith.settings", .size = .{ 720, 560 } },
shell: *Shell = undefined,
allocator: std.mem.Allocator = core.heap.main,
/// What's registered, refreshed when the registry changes.
settings: []*Setting = &.{},
seen_changes: u32 = std.math.maxInt(u32),
search: [128]u8 = @splat(0),
/// Something changed only takes effect next start.
restart_pending: bool = false,
/// Keys on more than one thing, refreshed when the keys change.
clashes: []Keybinds.Clash = &.{},
seen_keys: u32 = std.math.maxInt(u32),
/// A key setting getting another key, and whether that starts this frame.
adding: ?*Setting = null,
adding_starts: bool = false,
/// What the sidebar has picked, named by `page_name`.
page: PageKind = .wraith,
page_name: [96]u8 = undefined,
page_name_len: usize = 0,
/// The Game speed page's, the same speed the Workbench and Photo mode show.
speed: GameSpeed = .{},
/// This frame's lists, names and text boxes, freed at the start of the next.
frame: std.heap.ArenaAllocator = .init(core.heap.main),

const PageKind = enum {
    /// One of Wraith's sections, by name. Empty is General.
    wraith,
    /// Everything for a plugin, a mod, your project or the address list, by its group.
    owner,
    /// Every key on the game, whoever's it is.
    all_keys,
};

/// Unscaled.
const sidebar_width = 180;
/// Fresh, each time it's opened.
pub fn onOpen(self: *SettingsWindow) void {
    const shell = self.shell;
    self.allocator = shell.allocator;
    self.search = @splat(0);
    self.seen_changes = std.math.maxInt(u32);
    self.seen_keys = std.math.maxInt(u32);
    self.refresh(shell);
    shell.dev_plugins.refresh(shell);
}

pub fn deinit(self: *SettingsWindow) void {
    self.frame.deinit();
    if (self.settings.len > 0) self.allocator.free(self.settings);
    if (self.clashes.len > 0) Keybinds.freeClashes(self.allocator, self.clashes);
    self.* = .{};
}

fn refresh(self: *SettingsWindow, shell: *Shell) void {
    const now = shell.registry.changes.load(.acquire);
    if (now != self.seen_changes) {
        if (shell.registry.list(self.allocator)) |list| {
            if (self.settings.len > 0) self.allocator.free(self.settings);
            self.settings = list;
            self.seen_changes = now;
        } else |_| {}
    }
    const keys = shell.keybinds.changes.load(.acquire);
    if (keys != self.seen_keys) {
        if (shell.keybinds.clashesAlloc(self.allocator)) |found| {
            if (self.clashes.len > 0) Keybinds.freeClashes(self.allocator, self.clashes);
            self.clashes = found;
            self.seen_keys = keys;
        } else |_| {}
    }
}

pub fn draw(self: *SettingsWindow) void {
    _ = self.frame.reset(.retain_capacity);
    const shell = self.shell;
    self.refresh(shell);
    self.takePicked(shell);
    ui.setNextItemWidthPixels(-1);
    _ = ui.inputTextHint("##search", icons.search ++ "  Search settings", &self.search);
    const query = std.mem.sliceTo(&self.search, 0);

    var welcome = false;
    if (self.restart_pending) ui.textColored(.{ 1, 0.8, 0.3, 1 }, "{s}  Some changes take effect next time the game starts.", .{icons.triangle_alert});
    if (query.len > 0) {
        const found = ui.child("##found", .{ 0, 0 }, .{}) orelse return;
        defer found.end();
        self.drawFound(shell, query);
        return;
    }
    if (ui.child("##pages", .{ ui.scaled(sidebar_width), 0 }, .{ .border = true })) |side| {
        defer side.end();
        self.drawSidebar();
    }
    ui.sameLine();
    if (ui.child("##page", .{ 0, 0 }, .{})) |body| {
        defer body.end();
        welcome = self.drawPage(shell);
    }
    if (welcome) shell.showWelcome();
}

fn pageName(self: *const SettingsWindow) []const u8 {
    return self.page_name[0..self.page_name_len];
}

fn setPage(self: *SettingsWindow, kind: PageKind, name: []const u8) void {
    self.page = kind;
    self.page_name_len = @min(name.len, self.page_name.len);
    @memcpy(self.page_name[0..self.page_name_len], name[0..self.page_name_len]);
}

/// Shows everything for `group`, like a plugin's title, on its own page.
pub fn showGroup(self: *SettingsWindow, group: []const u8) void {
    self.setPage(.owner, group);
    self.search = @splat(0);
    self.window.show();
    self.window.focus();
}

/// Wraith's sections, then whoever else has settings or keys, then every key.
fn drawSidebar(self: *SettingsWindow) void {
    for (self.wraithSections()) |section| self.pageItem(.wraith, section, if (section.len == 0) "General" else section);
    const others = self.owners();
    if (others.len > 0) {
        ui.spacing();
        ui.separatorText("Plugins and mods");
    }
    for (others) |owner| self.pageItem(.owner, owner, owner);
    ui.spacing();
    ui.separator();
    self.pageItem(.all_keys, "", "All keys");
}

fn pageItem(self: *SettingsWindow, kind: PageKind, name: []const u8, label: []const u8) void {
    const picked = self.page == kind and std.mem.eql(u8, self.pageName(), name);
    var buf: [128]u8 = undefined;
    if (ui.selectable(std.fmt.bufPrintSentinel(&buf, "{s}##{t}", .{ label, kind }, 0) catch "?", picked)) self.setPage(kind, name);
}

/// True if it asked for the welcome.
fn drawPage(self: *SettingsWindow, shell: *Shell) bool {
    switch (self.page) {
        .wraith => return self.drawSection(shell, self.pageName()),
        .owner => {
            const group = self.pageName();
            const there = for (self.owners()) |o| {
                if (std.mem.eql(u8, o, group)) break true;
            } else false;
            // Like a plugin that's been turned off
            if (!there) {
                self.setPage(.wraith, "");
                return self.drawSection(shell, "");
            }
            {
                const bold = ui.bold();
                defer bold.end();
                var buf: [96]u8 = undefined;
                ui.separatorText(std.fmt.bufPrintSentinel(&buf, "{s}", .{group}, 0) catch "?");
            }
            self.drawGroup(shell, group);
            drawContributed(group);
        },
        .all_keys => self.drawAllKeys(shell),
    }
    return false;
}

/// General first, then Wraith's sections in the order added, then `last_sections`. Good for the frame.
fn wraithSections(self: *SettingsWindow) []const []const u8 {
    const a = self.frame.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    addName(a, &out, "");
    var last: [last_sections.len]bool = @splat(false);
    for (self.settings) |s| {
        if (s.def.hidden or !isWraith(s)) continue;
        if (lastIndex(s.def.section)) |i| {
            last[i] = true;
            continue;
        }
        addName(a, &out, s.def.section);
    }
    for (last_sections, last) |section, any| if (any) addName(a, &out, section);
    return out.items;
}

/// Everyone but Wraith with settings, keys or something in the `settings` slot, in the order they
/// came. Good for the frame.
fn owners(self: *SettingsWindow) []const []const u8 {
    const a = self.frame.allocator();
    var out: std.ArrayList([]const u8) = .empty;
    for (self.settings) |s| {
        if (s.def.hidden or isWraith(s)) continue;
        addName(a, &out, s.def.group);
    }
    var taken = slots.take(.settings);
    defer taken.end();
    // Copied, since a plugin can go once they're let go of
    for (taken.items()) |e| if (!e.own) {
        const kept = a.dupe(u8, e.ownerName()) catch break;
        addName(a, &out, kept);
    };
    return out.items;
}

/// What a plugin added to the `settings` slot, after its settings.
fn drawContributed(group: []const u8) void {
    var taken = slots.take(.settings);
    defer taken.end();
    for (taken.items()) |e| {
        if (e.own or !std.mem.eql(u8, e.ownerName(), group)) continue;
        if (e.presentation == .foldout) {
            if (e.focus_wanted.swap(false, .acq_rel)) ui.setNextItemOpen(true, .always);
            if (!ui.collapsingHeader(e.label, e.open)) continue;
        } else ui.spacing();
        const scope = ui.id(e.label);
        defer scope.end();
        slots.draw(e, .{});
    }
}

/// How much more a text box takes in a frame than what's in it, like a paste.
const typing_room = 4096;

/// At the end, after everything else.
const last_sections = [_][]const u8{ "Advanced", "Developer" };

fn lastIndex(section: []const u8) ?usize {
    for (last_sections, 0..) |l, i| if (std.mem.eql(u8, l, section)) return i;
    return null;
}

fn isWraith(s: *const Setting) bool {
    return std.mem.eql(u8, s.def.group, Settings.group);
}

fn isGameKey(s: *const Setting) bool {
    return switch (s.def.kind) {
        .key => |k| k.in_game,
        else => false,
    };
}

/// One of Wraith's own. True if it asked for the welcome.
fn drawSection(self: *SettingsWindow, shell: *Shell, section: []const u8) bool {
    if (std.mem.eql(u8, section, "Game speed")) {
        self.speed.draw(.{ .width = 0, .explain = true });
        ui.spacing();
    }
    var heading: []const u8 = "";
    for (self.settings) |s| {
        if (s.def.hidden or !isWraith(s) or !std.mem.eql(u8, s.def.section, section)) continue;
        if (!std.mem.eql(u8, s.def.heading, heading)) {
            heading = s.def.heading;
            if (heading.len > 0) {
                ui.spacing();
                var buf: [96]u8 = undefined;
                ui.separatorText(std.fmt.bufPrintSentinel(&buf, "{s}", .{heading}, 0) catch "?");
            }
        }
        self.row(shell, s);
    }
    if (std.mem.eql(u8, section, "Developer")) drawDevPlugins(shell);
    if (section.len != 0) return false;
    ui.spacing();
    {
        const bold = ui.bold();
        defer bold.end();
        ui.text("Welcome", .{});
    }
    const welcome = ui.button("Show the welcome");
    helpText("Go through the first-run welcome again.", false, .global);
    return welcome;
}

/// `name` added to `list` if it's not there yet. Out of memory leaves it off.
fn addName(a: std.mem.Allocator, list: *std.ArrayList([]const u8), name: []const u8) void {
    for (list.items) |have| if (std.mem.eql(u8, have, name)) return;
    list.append(a, name) catch {};
}

/// Its settings and keys without a section first, then a fold for each section.
fn drawGroup(self: *SettingsWindow, shell: *Shell, group: []const u8) void {
    const a = self.frame.allocator();
    var sections: std.ArrayList([]const u8) = .empty;
    for (self.settings) |s| {
        if (s.def.hidden or !std.mem.eql(u8, s.def.group, group)) continue;
        if (s.def.section.len == 0) self.row(shell, s) else addName(a, &sections, s.def.section);
    }
    for (sections.items) |section| {
        ui.setNextItemOpen(true, .once);
        const node = ui.treeNode(a.dupeSentinel(u8, section, 0) catch "?") orelse continue;
        defer node.end();
        for (self.settings) |s| {
            if (s.def.hidden or !std.mem.eql(u8, s.def.group, group) or !std.mem.eql(u8, s.def.section, section)) continue;
            self.row(shell, s);
        }
    }
}

/// Every key on the game in one list, whoever's it is, Wraith's first. Clashes say so.
fn drawAllKeys(self: *SettingsWindow, shell: *Shell) void {
    const others = self.owners();
    const groups = std.mem.concat(self.frame.allocator(), []const u8, &.{ &.{Settings.group}, others }) catch return;
    const table = ui.table("##keys", 2, .{ .row_background = true }) orelse return;
    defer table.end();
    ui.tableColumnWith("What", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Key", .{ .stretch = true, .width = 1 });
    ui.tableHeaders();
    var any = false;
    for (groups) |group| for (self.settings) |s| {
        if (s.def.hidden or !isGameKey(s) or !std.mem.eql(u8, s.def.group, group)) continue;
        any = true;
        const scope = ui.id(s);
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.alignTextToFramePadding();
        ui.textDisabled("{s}", .{group});
        ui.sameLine();
        const where = if (s.def.heading.len > 0) s.def.heading else s.def.section;
        if (where.len > 0) ui.text("{s}: {s}", .{ where, s.def.name }) else ui.text("{s}", .{s.def.name});
        _ = ui.tableNextColumn();
        self.keyRow(shell, s, shell.registry.get(s).key);
    };
    if (!any) {
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.textDisabled("No keys yet", .{});
    }
}

/// With where each is from over it.
fn drawFound(self: *SettingsWindow, shell: *Shell, query: []const u8) void {
    var any = false;
    var group: []const u8 = "";
    var section: []const u8 = "";
    var heading: []const u8 = "";
    for (self.settings) |s| {
        if (s.def.hidden) continue;
        const hit = std.ascii.findIgnoreCase(s.def.name, query) != null or
            std.ascii.findIgnoreCase(s.def.help, query) != null or
            std.ascii.findIgnoreCase(s.def.group, query) != null or
            std.ascii.findIgnoreCase(s.def.section, query) != null or
            std.ascii.findIgnoreCase(s.def.heading, query) != null;
        if (!hit) continue;
        if (!any or !std.mem.eql(u8, group, s.def.group) or !std.mem.eql(u8, section, s.def.section) or !std.mem.eql(u8, heading, s.def.heading)) {
            group = s.def.group;
            section = s.def.section;
            heading = s.def.heading;
            ui.spacing();
            if (heading.len > 0) {
                ui.textDisabled("{s} / {s} / {s}", .{ group, section, heading });
            } else if (section.len > 0) ui.textDisabled("{s} / {s}", .{ group, section }) else ui.textDisabled("{s}", .{group});
        }
        any = true;
        self.row(shell, s);
    }
    if (!any) ui.textDisabled("Nothing matches", .{});
}
/// Takes effect now. Saved too, unless it's mid-drag or mid-typing.
fn apply(self: *SettingsWindow, shell: *Shell, s: *Setting, v: Registry.Value, save: bool) void {
    const was = shell.registry.get(s);
    shell.registry.setWith(s, v, .{ .save = save }) catch |err| return log.warn("Couldn't change {s}: {t}", .{ s.def.id, err });
    if (s.def.restart and !was.eql(shell.registry.get(s))) self.restart_pending = true;
}

/// Once a drag or typing's done, so it's written.
fn finish(self: *SettingsWindow, shell: *Shell, s: *Setting) void {
    if (ui.isItemDeactivated()) self.apply(shell, s, shell.registry.get(s), true);
}

fn row(self: *SettingsWindow, shell: *Shell, s: *Setting) void {
    const scope = ui.id(s);
    defer scope.end();
    const v = shell.registry.get(s);
    ui.spacing();
    var name_buf: [128]u8 = undefined;
    const name = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{s.def.name}, 0) catch "?";
    switch (s.def.kind) {
        .toggle => {
            var on = v.toggle;
            const bold = ui.bold();
            defer bold.end();
            if (ui.checkbox(name, &on)) self.apply(shell, s, .{ .toggle = on }, true);
        },
        else => {
            const bold = ui.bold();
            defer bold.end();
            ui.alignTextToFramePadding();
            ui.text("{s}", .{name});
        },
    }
    if (!v.eql(Registry.defaultOf(s.def.kind))) {
        ui.sameLine();
        if (ui.iconButton(icons.rotate_ccw ++ "##reset", "Back to its default")) self.apply(shell, s, Registry.defaultOf(s.def.kind), true);
    }
    switch (s.def.kind) {
        .toggle => {},
        .number => |n| {
            var x: f32 = @floatCast(v.number);
            ui.setNextItemWidth(240);
            const format: [:0]const u8 = if (n.step >= 1) "%.0f" else "%.2f";
            if (ui.sliderWith("##value", &x, @floatCast(n.min), @floatCast(n.max), .{ .format = format })) self.apply(shell, s, .{ .number = x }, false);
            self.finish(shell, s);
        },
        .choice => |ch| {
            const a = self.frame.allocator();
            const names = a.alloc([:0]const u8, ch.options.len) catch return;
            var index: usize = names.len;
            for (ch.options, names, 0..) |o, *label, i| {
                label.* = a.dupeSentinel(u8, o, 0) catch "?";
                if (std.mem.eql(u8, o, v.choice)) index = i;
            }
            ui.setNextItemWidth(240);
            if (ui.combo("##value", &index, names)) self.apply(shell, s, .{ .choice = ch.options[index] }, true);
        },
        .text => {
            // Room to type past what's there, and it's made again from the new value each frame
            const buf = self.frame.allocator().alloc(u8, v.text.len + typing_room) catch return;
            @memset(buf, 0);
            @memcpy(buf[0..v.text.len], v.text);
            ui.setNextItemWidth(320);
            if (ui.inputText("##value", buf)) self.apply(shell, s, .{ .text = std.mem.sliceTo(buf, 0) }, false);
            self.finish(shell, s);
        },
        .colour => {
            var colour = v.colour;
            if (ui.colorEdit("##value", &colour)) self.apply(shell, s, .{ .colour = colour }, false);
            self.finish(shell, s);
        },
        .key => self.keyRow(shell, s, v.key),
        .path => |p| {
            const a = self.frame.allocator();
            const buf = a.alloc(u8, v.path.len + typing_room) catch return;
            @memset(buf, 0);
            @memcpy(buf[0..v.path.len], v.path);
            const hint = a.dupeSentinel(u8, p.placeholder, 0) catch "";
            ui.setNextItemWidth(320);
            if (ui.inputTextHint("##value", hint, buf)) self.apply(shell, s, .{ .path = std.mem.sliceTo(buf, 0) }, false);
            self.finish(shell, s);
            ui.sameLine();
            const off = ui.disabled(pickerBusy());
            defer off.end();
            if (ui.button("Browse...")) browse(s, p, v.path);
        },
    }
    helpText(s.def.help, s.def.restart, s.def.scope);
}

/// A Browse dialog's pick. Static, since the dialog runs on its own thread and can outlast the window.
const Picked = struct {
    lock: sync.RwLock = .{},
    busy: bool = false,
    ready: bool = false,
    id: [160]u8 = undefined,
    id_len: usize = 0,
    path: ?[]u8 = null,
};

var mailbox: Picked = .{};
const picker_allocator = core.heap.main;

fn pickerBusy() bool {
    mailbox.lock.lockShared();
    defer mailbox.lock.unlockShared();
    return mailbox.busy;
}

const PickJob = struct {
    arena: std.heap.ArenaAllocator,
    file: bool,
    title: []const u8,
    folder: []const u8,
    extension: []const u8,
};

/// Starts where it is now, or where its file is.
fn browse(s: *const Setting, path: Registry.Path, now: []const u8) void {
    {
        mailbox.lock.lock();
        defer mailbox.lock.unlock();
        if (mailbox.busy) return;
        mailbox.busy = true;
        mailbox.ready = false;
        mailbox.id_len = @min(s.def.id.len, mailbox.id.len);
        @memcpy(mailbox.id[0..mailbox.id_len], s.def.id[0..mailbox.id_len]);
    }
    const started = start: {
        const job = picker_allocator.create(PickJob) catch break :start false;
        job.* = .{ .arena = .init(picker_allocator), .file = path.file, .title = "", .folder = "", .extension = "" };
        const a = job.arena.allocator();
        const folder = if (path.file) std.fs.path.dirname(now) orelse "" else now;
        job.title = a.dupe(u8, s.def.name) catch "";
        job.folder = a.dupe(u8, folder) catch "";
        job.extension = a.dupe(u8, path.extension) catch "";
        const thread = std.Thread.spawn(.{}, pick, .{job}) catch {
            job.arena.deinit();
            picker_allocator.destroy(job);
            break :start false;
        };
        thread.detach();
        break :start true;
    };
    if (started) return;
    mailbox.lock.lock();
    defer mailbox.lock.unlock();
    mailbox.busy = false;
}

fn pick(job: *PickJob) void {
    defer {
        job.arena.deinit();
        picker_allocator.destroy(job);
    }
    const window = @import("../../host/ui.zig").gameWindow();
    // Over the game, not owned by it, which would tie the dialog to the game's message loop
    const over: ?tuft_window.Handle = if (window != 0) @ptrFromInt(window) else null;
    const result = if (job.file)
        tuft_window.pickFile(picker_allocator, .{ .mode = .open, .over = over, .title = job.title, .folder = job.folder, .extension = job.extension })
    else
        tuft_window.pickFolder(picker_allocator, .{ .over = over, .title = job.title, .folder = job.folder });
    const path = result catch |err| blk: {
        log.warn("Couldn't show the dialog: {t}", .{err});
        break :blk null;
    };
    mailbox.lock.lock();
    defer mailbox.lock.unlock();
    if (mailbox.path) |old| picker_allocator.free(old);
    mailbox.path = path;
    mailbox.ready = true;
    mailbox.busy = false;
}

/// Puts what the dialog picked in its setting, once it's closed.
fn takePicked(self: *SettingsWindow, shell: *Shell) void {
    var id_buf: [160]u8 = undefined;
    const id, const path = blk: {
        mailbox.lock.lock();
        defer mailbox.lock.unlock();
        if (!mailbox.ready) return;
        mailbox.ready = false;
        const path = mailbox.path orelse return;
        mailbox.path = null;
        @memcpy(id_buf[0..mailbox.id_len], mailbox.id[0..mailbox.id_len]);
        break :blk .{ id_buf[0..mailbox.id_len], path };
    };
    defer picker_allocator.free(path);
    const s = shell.registry.find(id) orelse return;
    self.apply(shell, s, .{ .path = path }, true);
}

fn keyRow(self: *SettingsWindow, shell: *Shell, s: *Setting, current: ?Keys) void {
    const held = switch (s.def.kind) {
        .key => |k| k.held,
        else => false,
    };
    var buf: [Keys.max]Chord = undefined;
    const chords: []Chord = if (current) |k| k.slice(&buf) else buf[0..0];
    const width = 150;
    // Each key, with a minus to take it off
    for (chords, 0..) |chord, i| {
        const scope = ui.id(i);
        defer scope.end();
        if (i > 0) ui.sameLine();
        var picked: ?Chord = chord;
        ui.setNextItemWidth(width);
        if (ui.chordInput("##key", &picked, .{ .none = "No key", .held = held })) if (picked) |p| self.apply(shell, s, .{ .key = current.?.replaced(i, p) }, true);
        ui.sameLine();
        if (ui.iconButton(icons.minus ++ "##remove", "Take this key off")) self.apply(shell, s, .{ .key = current.?.without(i) }, true);
    }
    // Another key, listening straight away, or the first
    const adding = self.adding == s;
    if (chords.len == 0 or adding) {
        if (chords.len > 0) ui.sameLine();
        var picked: ?Chord = null;
        ui.setNextItemWidth(width);
        if (ui.chordInput("##new", &picked, .{ .none = "No key", .held = held, .listen = adding and self.adding_starts })) {
            if (picked) |p| self.apply(shell, s, .{ .key = if (current) |k| k.with(p) else .one(p) }, true);
            self.adding = null;
        } else if (adding and !self.adding_starts and !ui.listeningForKeys()) {
            // Escape, or a click elsewhere
            self.adding = null;
        }
        self.adding_starts = false;
    } else if (chords.len < Keys.max) {
        ui.sameLine();
        if (ui.iconButton(icons.plus ++ "##add", "Add another key that does the same")) {
            self.adding = s;
            self.adding_starts = true;
        }
    }
    // Who else is on them, as they're bound now
    for (self.clashes) |clash| {
        const mine = for (clash.ids) |id| {
            if (std.mem.eql(u8, id, s.def.id)) break true;
        } else false;
        if (!mine) continue;
        var text_buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&text_buf);
        var key_buf: [64]u8 = undefined;
        w.print(icons.triangle_alert ++ "  Also on {s}: ", .{ui.chordName(&key_buf, clash.chord)}) catch {};
        var first = true;
        for (clash.ids) |id| {
            if (std.mem.eql(u8, id, s.def.id)) continue;
            const sep = if (first) "" else ", ";
            first = false;
            if (shell.registry.find(id)) |other| {
                w.writeAll(sep) catch {};
                other.def.describe(&w) catch {};
            } else w.print("{s}{s}", .{ sep, id }) catch {};
        }
        ui.textColored(.{ 1, 0.75, 0.3, 1 }, "{s}", .{w.buffered()});
        ui.tooltip("They all go off when it's pressed", .{});
    }
}

/// Folders Wraith loads plugins from while you build them. Changes take effect right away.
fn drawDevPlugins(shell: *Shell) void {
    const io = shell.options.io orelse return;
    ui.spacing();
    {
        const bold = ui.bold();
        defer bold.end();
        ui.alignTextToFramePadding();
        ui.text("Dev plugins", .{});
    }
    var remove_buf: [512]u8 = undefined;
    var remove: ?[]const u8 = null;
    var switch_buf: [512]u8 = undefined;
    var switched: ?struct { folder: []const u8, on: bool } = null;
    {
        const v = shell.dev_plugins.view(io);
        defer v.end();
        if (!v.loaded()) {
            ui.textDisabled("Reading the list...", .{});
        } else if (v.entries().len == 0) {
            ui.textDisabled("None yet", .{});
        }
        for (v.entries(), 0..) |e, i| {
            const scope = ui.id(i);
            defer scope.end();
            if (ui.iconButton(icons.x ++ "##remove", "Stop loading it from here")) {
                const n = @min(e.folder.len, remove_buf.len);
                @memcpy(remove_buf[0..n], e.folder[0..n]);
                remove = remove_buf[0..n];
            }
            ui.sameLine();
            var on = e.on;
            if (ui.checkbox("##on", &on)) {
                const n = @min(e.folder.len, switch_buf.len);
                @memcpy(switch_buf[0..n], e.folder[0..n]);
                switched = .{ .folder = switch_buf[0..n], .on = on };
            }
            if (e.on) ui.tooltip("Loaded. Untick to skip it for now", .{}) else ui.tooltip("Skipped for now. Tick to load it again", .{});
            ui.sameLine();
            ui.alignTextToFramePadding();
            if (e.name) |id| {
                if (e.on) ui.text("{s}", .{id}) else ui.textDisabled("{s}", .{id});
                ui.sameLine();
                ui.textDisabled("{s}", .{e.folder});
            } else {
                ui.textColored(.{ 1, 0.75, 0.3, 1 }, "{s}  {s}", .{ icons.triangle_alert, e.folder });
                ui.tooltip("No usable wraith.json: {s}", .{core.dev_plugins.describe(e.problem orelse error.NoManifest)});
            }
        }
        if (v.problem().len > 0) ui.textColored(.{ 1, 0.5, 0.5, 1 }, "{s}", .{v.problem()});
    }
    if (remove) |folder| shell.dev_plugins.remove(shell, folder);
    if (switched) |s| shell.dev_plugins.setOn(shell, s.folder, s.on);
    {
        const off = ui.disabled(shell.dev_plugins.isBusy());
        defer off.end();
        if (ui.button(icons.folder_plus ++ "  Add plugin folder")) addDevPlugin(shell);
    }
    helpText("Plugins you're building. Wraith loads them from these folders instead of installed copies. Pick a plugin's wraith.json. Changes take effect right away.", false, .global);
}

fn addDevPlugin(shell: *Shell) void {
    const picked = tuft_window.pickFile(shell.allocator, .{
        .mode = .open,
        .owner = Workbench.dialogOwner(shell.workbench),
        .alive = Workbench.dialogAlive(shell.workbench),
        .title = "Pick a plugin's wraith.json",
        .kind = "Plugin manifest",
        .extension = ".json",
        .file_name = core.manifest.file_name,
    }) catch |err| return log.warn("Couldn't show the file dialog: {t}", .{err});
    const path = picked orelse return;
    defer shell.allocator.free(path);
    const folder = std.fs.path.dirname(path) orelse return;
    shell.dev_plugins.add(shell, folder);
}

fn helpText(help: []const u8, restart: bool, scope: Registry.Scope) void {
    if (help.len == 0 and !restart and scope == .global) return;
    const dim = ui.withStyleColor(.text, .text_disabled);
    defer dim.end();
    ui.textWrapped("{s}{s}{s}", .{
        help,
        if (restart) " Takes a restart." else "",
        if (scope == .game) " Just for this game." else "",
    });
}

/// As if picked in the window, for tests.
pub fn edit(self: *SettingsWindow, shell: *Shell, id: []const u8, v: Registry.Value) !void {
    const s = shell.registry.find(id) orelse return error.NoSuchSetting;
    self.apply(shell, s, v, true);
}

/// As if a path's Browse dialog picked `path`, for tests. It lands next frame.
pub fn browsed(id: []const u8, path: []const u8) !void {
    mailbox.lock.lock();
    defer mailbox.lock.unlock();
    mailbox.id_len = @min(id.len, mailbox.id.len);
    @memcpy(mailbox.id[0..mailbox.id_len], id[0..mailbox.id_len]);
    if (mailbox.path) |old| picker_allocator.free(old);
    mailbox.path = try picker_allocator.dupe(u8, path);
    mailbox.ready = true;
}
