//! The overlay's settings window. Built from the registry, so Wraith's settings, plugins' and
//! every key bound on the game show up the same way. A sidebar has Wraith's sections, then a page
//! for each plugin, mod, your project and the address list with all its settings and keys, a fold
//! for each tweak or entry in it, and a page of every key at the end. Changes take effect as you
//! make them, and drags and typing get saved once they're done. Render thread.

const SettingsWindow = @This();

const std = @import("std");

const core = @import("wraith_core");
const ui = @import("wraith_ui");
const Chord = @import("wraith_platform").input.Chord;
const Keybinds = @import("tuft_input").Keybinds;
const tuft_window = @import("tuft_window");
const sync = @import("tuft_sys").sync;

const icons = @import("../fonts.zig").icons;
const Settings = @import("../../Settings.zig");
const Registry = Settings.Registry;
const Setting = Registry.Setting;
const Shell = @import("Shell.zig");
const Workbench = @import("../workbench/Workbench.zig");

const log = core.log.scoped(.wraith_ui);

window: ui.Window = .{ .title = "Wraith Settings###wraith.settings", .size = .{ 720, 560 } },
shell: *Shell = undefined,
allocator: std.mem.Allocator = std.heap.page_allocator,
/// What's registered, refreshed when the registry changes.
settings: []*Setting = &.{},
seen_changes: u32 = std.math.maxInt(u32),
search: [128]u8 = @splat(0),
/// Something changed only takes effect next start.
restart_pending: bool = false,
/// Keys on more than one thing, refreshed when the keys change.
clashes: []Keybinds.Clash = &.{},
seen_keys: u32 = std.math.maxInt(u32),
/// What the sidebar has picked, named by `page_name`.
page: PageKind = .wraith,
page_name: [96]u8 = undefined,
page_name_len: usize = 0,

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
    var sections: [16][]const u8 = undefined;
    for (self.wraithSections(&sections)) |section| self.pageItem(.wraith, section, if (section.len == 0) "General" else section);
    var names: [64][]const u8 = undefined;
    const others = self.owners(&names);
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
            var names: [64][]const u8 = undefined;
            const there = for (self.owners(&names)) |o| {
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
        },
        .all_keys => self.drawAllKeys(shell),
    }
    return false;
}

/// General first, then Wraith's sections in the order they were added. `last_sections` go at the
/// end, in that order.
fn wraithSections(self: *SettingsWindow, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    out[n] = "";
    n += 1;
    var last: [last_sections.len]bool = @splat(false);
    for (self.settings) |s| {
        if (s.def.hidden or !isWraith(s)) continue;
        if (lastIndex(s.def.section)) |i| {
            last[i] = true;
            continue;
        }
        if (n < out.len - last_sections.len) n = addName(out, n, s.def.section);
    }
    for (last_sections, last) |section, any| if (any) {
        out[n] = section;
        n += 1;
    };
    return out[0..n];
}

/// Everyone but Wraith with settings or keys, in the order they came.
fn owners(self: *SettingsWindow, out: [][]const u8) [][]const u8 {
    var n: usize = 0;
    for (self.settings) |s| {
        if (s.def.hidden or isWraith(s)) continue;
        n = addName(out, n, s.def.group);
    }
    return out[0..n];
}

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
    for (self.settings) |s| {
        if (s.def.hidden or !isWraith(s) or !std.mem.eql(u8, s.def.section, section)) continue;
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

/// `name` added to `list`'s first `n` if it's not there yet. The new count.
fn addName(list: [][]const u8, n: usize, name: []const u8) usize {
    for (list[0..n]) |have| if (std.mem.eql(u8, have, name)) return n;
    if (n == list.len) return n;
    list[n] = name;
    return n + 1;
}

/// Its settings and keys without a section first, then one that folds for each section, like
/// each tweak.
fn drawGroup(self: *SettingsWindow, shell: *Shell, group: []const u8) void {
    var sections: [256][]const u8 = undefined;
    var n: usize = 0;
    for (self.settings) |s| {
        if (s.def.hidden or !std.mem.eql(u8, s.def.group, group)) continue;
        if (s.def.section.len == 0) self.row(shell, s) else n = addName(&sections, n, s.def.section);
    }
    for (sections[0..n]) |section| {
        var buf: [192]u8 = undefined;
        ui.setNextItemOpen(true, .once);
        const node = ui.treeNode(std.fmt.bufPrintSentinel(&buf, "{s}", .{section}, 0) catch "?") orelse continue;
        defer node.end();
        for (self.settings) |s| {
            if (s.def.hidden or !std.mem.eql(u8, s.def.group, group) or !std.mem.eql(u8, s.def.section, section)) continue;
            self.row(shell, s);
        }
    }
}

/// Every key on the game in one list, whoever's it is, Wraith's first. Clashes say so.
fn drawAllKeys(self: *SettingsWindow, shell: *Shell) void {
    var groups: [65][]const u8 = undefined;
    groups[0] = Settings.group;
    const others = self.owners(groups[1..]);
    const table = ui.table("##keys", 2, .{ .row_background = true }) orelse return;
    defer table.end();
    ui.tableColumnWith("What", .{ .stretch = true, .width = 1 });
    ui.tableColumnWith("Key", .{ .stretch = true, .width = 1 });
    ui.tableHeaders();
    var any = false;
    for (groups[0 .. others.len + 1]) |group| for (self.settings) |s| {
        if (s.def.hidden or !isGameKey(s) or !std.mem.eql(u8, s.def.group, group)) continue;
        any = true;
        const scope = ui.id(s);
        defer scope.end();
        ui.tableNextRow();
        _ = ui.tableNextColumn();
        ui.alignTextToFramePadding();
        ui.textDisabled("{s}", .{group});
        ui.sameLine();
        if (s.def.section.len > 0) ui.text("{s}: {s}", .{ s.def.section, s.def.name }) else ui.text("{s}", .{s.def.name});
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
    for (self.settings) |s| {
        if (s.def.hidden) continue;
        const hit = std.ascii.findIgnoreCase(s.def.name, query) != null or
            std.ascii.findIgnoreCase(s.def.help, query) != null or
            std.ascii.findIgnoreCase(s.def.group, query) != null or
            std.ascii.findIgnoreCase(s.def.section, query) != null;
        if (!hit) continue;
        if (!any or !std.mem.eql(u8, group, s.def.group) or !std.mem.eql(u8, section, s.def.section)) {
            group = s.def.group;
            section = s.def.section;
            ui.spacing();
            if (section.len > 0) ui.textDisabled("{s} / {s}", .{ group, section }) else ui.textDisabled("{s}", .{group});
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
            var names: [64][:0]const u8 = undefined;
            var bufs: [64][64]u8 = undefined;
            const count = @min(ch.options.len, names.len);
            var index: usize = count;
            for (ch.options[0..count], 0..) |o, i| {
                names[i] = std.fmt.bufPrintSentinel(&bufs[i], "{s}", .{o}, 0) catch "?";
                if (std.mem.eql(u8, o, v.choice)) index = i;
            }
            ui.setNextItemWidth(240);
            if (ui.combo("##value", &index, names[0..count])) self.apply(shell, s, .{ .choice = ch.options[index] }, true);
        },
        .text => {
            var buf: [256]u8 = @splat(0);
            const n = @min(v.text.len, buf.len - 1);
            @memcpy(buf[0..n], v.text[0..n]);
            ui.setNextItemWidth(320);
            if (ui.inputText("##value", &buf)) self.apply(shell, s, .{ .text = std.mem.sliceTo(&buf, 0) }, false);
            self.finish(shell, s);
        },
        .colour => {
            var colour = v.colour;
            if (ui.colorEdit("##value", &colour)) self.apply(shell, s, .{ .colour = colour }, false);
            self.finish(shell, s);
        },
        .key => self.keyRow(shell, s, v.key),
        .path => |p| {
            var buf: [512]u8 = @splat(0);
            const n = @min(v.path.len, buf.len - 1);
            @memcpy(buf[0..n], v.path[0..n]);
            var hint_buf: [256]u8 = undefined;
            const hint = std.fmt.bufPrintSentinel(&hint_buf, "{s}", .{p.placeholder}, 0) catch "";
            ui.setNextItemWidth(320);
            if (ui.inputTextHint("##value", hint, &buf)) self.apply(shell, s, .{ .path = std.mem.sliceTo(&buf, 0) }, false);
            self.finish(shell, s);
            ui.sameLine();
            const off = ui.disabled(pickerBusy());
            defer off.end();
            if (ui.button("Browse...")) browse(s, p, v.path);
        },
    }
    helpText(s.def.help, s.def.restart, s.def.scope);
}

/// What a path's Browse dialog picked, for the setting it was for. Static, since the dialog's on a
/// thread of its own so the game keeps going, and it can outlast the window.
const Picked = struct {
    lock: sync.RwLock = .{},
    busy: bool = false,
    ready: bool = false,
    id: [160]u8 = undefined,
    id_len: usize = 0,
    path: ?[]u8 = null,
};

var mailbox: Picked = .{};
const picker_allocator = std.heap.smp_allocator;

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

fn keyRow(self: *SettingsWindow, shell: *Shell, s: *Setting, current: ?Chord) void {
    var picked = current;
    ui.setNextItemWidth(200);
    if (ui.chordInput("##key", &picked, .{ .none = "No key" })) self.apply(shell, s, .{ .key = picked }, true);
    if (current != null) {
        ui.sameLine();
        if (ui.iconButton(icons.x ++ "##clear", "No key")) self.apply(shell, s, .{ .key = null }, true);
    }
    // Who else is on it, as it's bound now
    for (self.clashes) |clash| {
        const mine = for (clash.ids) |id| {
            if (std.mem.eql(u8, id, s.def.id)) break true;
        } else false;
        if (!mine) continue;
        var text_buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&text_buf);
        w.writeAll(icons.triangle_alert ++ "  Also on this key: ") catch {};
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
            ui.alignTextToFramePadding();
            if (e.id) |id| {
                ui.text("{s}", .{id});
                ui.sameLine();
                ui.textDisabled("{s}", .{e.folder});
            } else {
                ui.textColored(.{ 1, 0.75, 0.3, 1 }, "{s}  {s}", .{ icons.triangle_alert, e.folder });
                ui.tooltip("No usable wraith.json: {t}", .{e.problem orelse error.NoManifest});
            }
        }
        if (v.problem().len > 0) ui.textColored(.{ 1, 0.5, 0.5, 1 }, "{s}", .{v.problem()});
    }
    if (remove) |folder| shell.dev_plugins.remove(shell, folder);
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
