//! The overlay's Mods window. What's installed, dev plugins included, and what the
//! Wraith Hub has for this game or any game, to install, update, load and unload. The hub, files
//! and the loader are only touched on a worker. Render thread.

const ModsWindow = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const build_info = @import("build_info");
const core = @import("wraith_core");
const platform = @import("wraith_platform");
const registry = @import("wraith_registry");
const ui = @import("wraith_ui");
const Message = @import("tuft_text").Message;
const Text = @import("tuft_text").Text;

const icons = @import("../fonts.zig").icons;
const PluginLoader = @import("../../PluginLoader.zig");
const Manifest = @import("../../Manifest.zig");
const Shell = @import("Shell.zig");

const log = core.log.scoped(.wraith_ui);
const Listed = registry.mods.Listed;
const Info = PluginLoader.Info;

window: ui.Window = .{ .title = "Mods###wraith.mods", .size = .{ 880, 600 } },
shell: *Shell = undefined,
section: Section = .installed,
search: [128]u8 = @splat(0),
/// The row that's open, by id.
expanded: Text(64) = .{},
/// The loader's plugins, copied each frame.
plugins: [max_plugins]Info = undefined,
plugins_len: usize = 0,
mods_dir: Text(260) = .{},
rows: [max_rows]Row = undefined,
work: Work = .{},

pub const Section = enum { installed, dev, browse, updates };

pub const max_plugins = 64;
const max_rows = 256;
const sidebar_width = 170;
const footer_height = 36;

const green: ui.Color = .{ 0.45, 0.85, 0.45, 1 };
const amber: ui.Color = .{ 1, 0.75, 0.3, 1 };
const red: ui.Color = .{ 1, 0.5, 0.5, 1 };
const blue: ui.Color = .{ 0.5, 0.75, 1, 1 };

/// A plugin the loader knows, a mod on the hub, or both.
const Row = struct {
    id: []const u8,
    plugin: ?*const Info = null,
    listed: ?*const Listed = null,
    dev: bool = false,
    /// Its copy in the mods folder. A dev plugin is loaded over it.
    folder: ?*const Folder = null,

    fn title(self: Row) []const u8 {
        if (self.plugin) |p| if (p.about.title.len() > 0) return p.about.title.get();
        if (self.listed) |l| if (l.title.len > 0) return l.title;
        return self.id;
    }

    fn version(self: Row) []const u8 {
        if (self.plugin) |p| if (p.about.version.len() > 0) return p.about.version.get();
        if (self.listed) |l| return l.installed orelse l.latest orelse "";
        return "";
    }

    fn author(self: Row) []const u8 {
        if (self.plugin) |p| if (p.about.author.len() > 0) return p.about.author.get();
        if (self.listed) |l| return l.author;
        return "";
    }

    fn summary(self: Row) []const u8 {
        return if (self.listed) |l| l.summary else "";
    }

    fn isProject(self: Row) bool {
        return if (self.listed) |l| l.kind == .project else false;
    }

    /// Installed from the hub, so it can be uninstalled. The folder says so even when the hub can't.
    pub fn fromHub(self: Row) bool {
        if (self.folder) |f| if (f.from_hub) return true;
        return if (self.listed) |l| l.installed != null else false;
    }

    /// The installed copy a dev plugin's loaded over.
    pub fn over(self: Row) ?*const Folder {
        return if (self.dev) self.folder else null;
    }

    fn hasUpdate(self: Row) bool {
        return if (self.listed) |l| l.hasUpdate() else false;
    }

    fn matches(self: Row, query: []const u8) bool {
        if (query.len == 0) return true;
        for ([_][]const u8{ self.id, self.title(), self.summary(), self.author() }) |s| {
            if (std.ascii.findIgnoreCase(s, query) != null) return true;
        }
        return false;
    }
};

/// Gets what the hub has, the first time.
pub fn onOpen(self: *ModsWindow) void {
    const shell = self.shell;
    self.search = @splat(0);
    self.expanded = .{};
    if (!self.work.fetched.load(.acquire)) self.start(shell, .refresh);
}

/// Waits for work in flight.
pub fn deinit(self: *ModsWindow, io: ?std.Io) void {
    if (io) |i| self.work.group.await(i) catch {};
    if (self.work.arena) |*a| a.deinit();
    if (self.work.folders_arena) |*a| a.deinit();
    self.work = .{};
}

pub fn draw(self: *ModsWindow) void {
    const shell = self.shell;
    const io = shell.options.io orelse return ui.textDisabled("Mods need Wraith's folders, which it doesn't have here.", .{});
    self.snapshot(shell);
    ui.setNextItemWidthPixels(-ui.scaled(40));
    _ = ui.inputTextHint("##search", icons.search ++ "  Search mods", &self.search);
    ui.sameLine();
    {
        const off = ui.disabled(self.work.isBusy());
        defer off.end();
        if (ui.iconButton(icons.refresh_cw ++ "##refresh", "Look for new plugin folders and check the hub again")) self.start(shell, .refresh);
    }
    const query = std.mem.trim(u8, std.mem.sliceTo(&self.search, 0), " ");

    self.work.lock.lockUncancelable(io);
    defer self.work.lock.unlock(io);
    const installed = self.collect(.installed, "");
    const updates = self.collect(.updates, "");
    const installed_n = installed.len;
    const updates_n = updates.len;
    const dev_n = self.collect(.dev, "").len;
    const browse_n = self.collect(.browse, "").len;
    if (self.section == .updates and updates_n == 0) self.section = .installed;
    if (self.section == .dev and dev_n == 0) self.section = .installed;

    const body_height = -ui.scaled(footer_height);
    if (ui.child("##sections", .{ ui.scaled(sidebar_width), body_height }, .{ .border = true })) |side| {
        defer side.end();
        var buf: [48]u8 = undefined;
        if (ui.selectable(label(&buf, "Installed ({d})", .{installed_n}), self.section == .installed)) self.section = .installed;
        if (dev_n > 0 and ui.selectable(label(&buf, "Dev ({d})", .{dev_n}), self.section == .dev)) self.section = .dev;
        if (ui.selectable(label(&buf, "Browse ({d})", .{browse_n}), self.section == .browse)) self.section = .browse;
        if (updates_n > 0 and ui.selectable(label(&buf, "Updates ({d})", .{updates_n}), self.section == .updates)) self.section = .updates;
    }
    ui.sameLine();
    if (ui.child("##mods", .{ 0, body_height }, .{})) |list| {
        defer list.end();
        self.drawRows(shell, query);
    }
    self.drawFooter(shell, updates_n);
}

fn label(buf: []u8, comptime fmt: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, fmt, args, 0) catch "?";
}

/// The loader's plugins and where things are, for this frame.
pub fn snapshot(self: *ModsWindow, shell: *Shell) void {
    const loader = shell.acquireLoader() orelse {
        self.plugins_len = 0;
        return;
    };
    defer shell.releaseLoader();
    self.plugins_len = loader.list(&self.plugins);
    self.mods_dir.set(loader.plugins_dir);
}

fn findPlugin(self: *ModsWindow, id: []const u8) ?*const Info {
    for (self.plugins[0..self.plugins_len]) |*p| if (std.mem.eql(u8, p.name.get(), id)) return p;
    return null;
}

/// Hold `work.lock`. Good till the next call.
pub fn collect(self: *ModsWindow, section: Section, query: []const u8) []const Row {
    var n: usize = 0;
    const listing = self.work.listing;
    switch (section) {
        .installed, .updates, .dev => {
            for (self.plugins[0..self.plugins_len]) |*p| {
                var row: Row = .{
                    .id = p.name.get(),
                    .plugin = p,
                    .listed = if (listing) |l| l.find(p.name.get()) else null,
                    .dev = !std.mem.startsWith(u8, p.source_dir.get(), self.mods_dir.get()),
                };
                if (row.dev != (section == .dev)) continue;
                row.folder = self.work.folder(row.id);
                if (section == .updates and !row.hasUpdate()) continue;
                if (n < max_rows and row.matches(query)) {
                    self.rows[n] = row;
                    n += 1;
                }
            }
            // Projects, and anything installed the loader doesn't list
            if (section != .dev) if (listing) |l| for (l.mods) |*m| {
                if (m.installed == null or self.findPlugin(m.id) != null) continue;
                const row: Row = .{ .id = m.id, .listed = m };
                if (section == .updates and !row.hasUpdate()) continue;
                if (n < max_rows and row.matches(query)) {
                    self.rows[n] = row;
                    n += 1;
                }
            };
        },
        .browse => if (listing) |l| for (l.mods) |*m| {
            // They come with the mods that need them
            if (m.library or m.installed != null or self.findPlugin(m.id) != null) continue;
            const row: Row = .{ .id = m.id, .listed = m };
            if (n < max_rows and row.matches(query)) {
                self.rows[n] = row;
                n += 1;
            }
        },
    }
    const rows = self.rows[0..n];
    std.mem.sort(Row, rows, {}, struct {
        fn lessThan(_: void, a: Row, b: Row) bool {
            const fa = if (a.listed) |l| l.featured else false;
            const fb = if (b.listed) |l| l.featured else false;
            if (fa != fb) return fa;
            return std.ascii.lessThanIgnoreCase(a.title(), b.title());
        }
    }.lessThan);
    return rows;
}

fn drawRows(self: *ModsWindow, shell: *Shell, query: []const u8) void {
    const rows = self.collect(self.section, query);
    if (rows.len == 0) {
        const fetched = self.work.fetched.load(.acquire);
        if (self.section == .browse and !fetched) {
            ui.textDisabled("Getting mods from the hub...", .{});
        } else if (query.len > 0) {
            ui.textDisabled("Nothing matches", .{});
        } else switch (self.section) {
            .installed => ui.textDisabled("Nothing installed yet. Browse has what's on the hub.", .{}),
            .dev => ui.textDisabled("No dev plugins. Add their folders in Settings, under Developer.", .{}),
            .browse => ui.textDisabled("Nothing more on the hub for this game yet.", .{}),
            .updates => ui.textDisabled("Everything's up to date.", .{}),
        }
        if (self.work.hub_problem.message().len > 0) ui.textColored(red, "{s}", .{self.work.hub_problem.message()});
        return;
    }
    for (rows) |row| {
        const scope = ui.id(row.id);
        defer scope.end();
        self.drawRow(shell, row);
        ui.separator();
    }
}

fn drawRow(self: *ModsWindow, shell: *Shell, row: Row) void {
    const is_open = std.mem.eql(u8, self.expanded.get(), row.id);
    var buf: [160]u8 = undefined;
    if (ui.selectableWith(label(&buf, "##row", .{}), is_open, .{ .allow_overlap = true })) {
        if (is_open) self.expanded = .{} else self.expanded.set(row.id);
    }
    ui.sameLine();
    {
        const bold = ui.bold();
        defer bold.end();
        ui.text("{s}", .{row.title()});
    }
    ui.sameLine();
    if (row.author().len > 0) ui.textDisabled("{s}  by {s}", .{ row.version(), row.author() }) else ui.textDisabled("{s}", .{row.version()});
    drawTags(row);
    // Like Dalamud's cog, right on the row
    if (row.plugin) |p| if (p.state == .loaded and shell.pluginHasSettings(row.id, row.title())) {
        ui.sameLine();
        const clicked = ui.smallButton(icons.settings ++ "##settings");
        ui.tooltip("Its settings", .{});
        if (clicked) shell.openPluginSettings(row.id, row.title());
    };
    if (row.summary().len > 0) ui.textWrapped("{s}", .{row.summary()});
    if (is_open) self.drawDetails(shell, row);
}

fn drawTags(row: Row) void {
    if (row.listed) |l| if (l.featured) tag(green, "Recommended");
    if (row.listed) |l| if (l.library) tag(blue, "Library");
    if (row.isProject()) tag(blue, "Project");
    if (row.dev) tag(blue, "Dev");
    if (row.over()) |o| {
        var buf: [64]u8 = undefined;
        tag(amber, std.fmt.bufPrint(&buf, "Over installed {s}", .{if (o.version.len > 0) o.version else "copy"}) catch "Over installed copy");
    }
    if (row.plugin) |p| switch (p.state) {
        .loaded => tag(green, "On"),
        .loading => tag(amber, "Loading"),
        .unloading => tag(amber, "Unloading"),
        .failed => tag(red, "Failed"),
        .unsupported => tag(amber, if (p.last_error != null and p.last_error.? == error.OutdatedApi) "Outdated" else "Can't run here"),
        .unloaded => tag(.{ 0.6, 0.6, 0.6, 1 }, "Off"),
    };
    if (row.listed) |l| {
        if (l.revoked) tag(red, "Pulled from the hub") else if (l.hasUpdate()) tag(amber, "Update");
        if (l.latest == null and l.installed == null) tag(amber, if (l.outdated) "Not updated for this Wraith" else "Needs a newer Wraith");
    }
}

fn tag(colour: ui.Color, text: []const u8) void {
    ui.sameLine();
    ui.textColored(colour, "[{s}]", .{text});
}

fn drawDetails(self: *ModsWindow, shell: *Shell, row: Row) void {
    ui.indent(ui.scaled(12));
    defer ui.unindent(ui.scaled(12));
    ui.textDisabled("{s}", .{row.id});
    if (row.plugin) |p| {
        if (row.dev) ui.textDisabled("Dev plugin, from {s}", .{p.source_dir.get()});
        if (row.over()) |o| ui.textColored(amber, "Loaded instead of the installed copy{s}{s}. Stop loading from here to go back to it.", .{ if (o.version.len > 0) ", " else "", o.version });
        if (p.about.games.len() > 0) ui.textDisabled("For {s}", .{p.about.games.get()});
        if (p.last_error) |err| {
            if (err == error.OutdatedApi) {
                ui.textColored(amber, "Made for an older Wraith, so it's off until its author updates it", .{});
            } else if (p.needs.len() > 0) ui.textColored(red, "{t}: needs {s}", .{ err, p.needs.get() }) else ui.textColored(red, "{t}", .{err});
        }
    }
    if (row.listed) |l| {
        if (l.why) |why| ui.textWrapped("{s}", .{why});
        if (l.installed) |have| if (l.latest) |latest| if (!std.mem.eql(u8, have, latest)) ui.textDisabled("{s} is out, this is {s}", .{ latest, have });
        if (l.outdated) ui.textColored(amber, "Its newest version isn't made for this Wraith yet", .{});
        if (l.needs_wraith) |needs| if (needs.len > 0) ui.textColored(amber, "Needs Wraith {s} or newer", .{needs}) else ui.textColored(amber, "Needs a newer Wraith", .{});
    }

    const off = ui.disabled(self.work.isBusy());
    defer off.end();
    const id = row.id;
    var buf: [96]u8 = undefined;
    // A dev one's hub buttons would go to the installed copy under it
    if (!row.dev) if (row.listed) |l| {
        if (l.installed == null and l.latest != null) {
            if (ui.button(label(&buf, icons.download ++ "  Install {s}", .{l.latest.?}))) self.startOn(shell, .install, id);
            ui.sameLine();
        }
        if (l.hasUpdate()) {
            const verb = if (l.revoked) "Replace with" else "Update to";
            if (ui.button(label(&buf, icons.download ++ "  {s} {s}", .{ verb, l.latest.? }))) self.startOn(shell, .update, id);
            ui.sameLine();
        }
    };
    if (row.plugin) |p| switch (p.state) {
        .loaded => {
            if (ui.button(icons.rotate_ccw ++ "  Reload")) self.startOn(shell, .reload, id);
            ui.sameLine();
            if (ui.button(icons.power ++ "  Turn off")) self.startOn(shell, .unload, id);
            ui.sameLine();
        },
        .unloaded, .failed => {
            if (ui.button(icons.power ++ "  Turn on")) self.startOn(shell, .load, id);
            ui.sameLine();
        },
        else => {},
    };
    if (row.dev) {
        if (row.plugin) |p| if (ui.button(icons.x ++ "  Stop loading from here")) shell.dev_plugins.remove(shell, p.source_dir.get());
        ui.sameLine();
        if (row.fromHub()) {
            if (ui.button(icons.trash_2 ++ "  Uninstall the installed copy")) self.startOn(shell, .remove, id);
            ui.sameLine();
        }
    } else if (row.fromHub()) {
        if (ui.button(icons.trash_2 ++ "  Uninstall")) self.startOn(shell, .remove, id);
        ui.sameLine();
    }
    ui.newLine();
}

fn drawFooter(self: *ModsWindow, shell: *Shell, updates: usize) void {
    ui.spacing();
    const doing = self.work.doing.message();
    if (self.work.isBusy() and doing.len > 0) {
        ui.alignTextToFramePadding();
        ui.textColored(amber, "{s}", .{doing});
    } else if (self.work.problem.message().len > 0) {
        ui.alignTextToFramePadding();
        ui.textColored(red, "{s}", .{self.work.problem.message()});
    } else {
        ui.alignTextToFramePadding();
        ui.textDisabled("In {s}", .{self.mods_dir.get()});
    }
    if (updates > 0) {
        ui.sameLine();
        const off = ui.disabled(self.work.isBusy());
        defer off.end();
        var buf: [48]u8 = undefined;
        if (ui.button(label(&buf, icons.download ++ "  Update all ({d})", .{updates}))) self.start(shell, .update_all);
    }
}

// The worker

const Work = struct {
    group: std.Io.Group = .init,
    lock: std.Io.Mutex = .init,
    busy: Atomic(bool) = .init(false),
    /// The hub was asked at least once, whether it answered or not.
    fetched: Atomic(bool) = .init(false),
    /// Under `lock`, in `arena`.
    listing: ?registry.mods.Listing = null,
    arena: ?std.heap.ArenaAllocator = null,
    /// Under `lock`.
    hub_problem: Message(160) = .{},
    /// Under `lock`. The last thing that failed.
    problem: Message(200) = .{},
    /// Under `lock`. What's going on now.
    doing: Message(96) = .{},
    /// Under `lock`, in `folders_arena`. What's in the mods folder, from the last relist.
    folders: []const Folder = &.{},
    folders_arena: ?std.heap.ArenaAllocator = null,

    fn folder(self: *const Work, id: []const u8) ?*const Folder {
        for (self.folders) |*f| if (std.mem.eql(u8, f.id, id)) return f;
        return null;
    }

    fn isBusy(self: *const Work) bool {
        return self.busy.load(.acquire);
    }
};

/// A mod in the mods folder.
pub const Folder = struct {
    id: []const u8,
    /// Its wraith.json's. Empty if it has none.
    version: []const u8,
    /// It has the hub's install receipt.
    from_hub: bool,
};

/// The mods folder's folders with their versions.
fn readFolders(a: std.mem.Allocator, io: std.Io, mods_dir: []const u8) ![]const Folder {
    var dir = std.Io.Dir.openDirAbsolute(io, mods_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(io);
    var out: std.ArrayList(Folder) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(a, &.{ mods_dir, entry.name });
        const manifest = (Manifest.read(a, io, path) catch null) orelse continue;
        const from_hub = (registry.installed(a, io, mods_dir, entry.name) catch null) != null;
        try out.append(a, .{ .id = try a.dupe(u8, entry.name), .version = manifest.value.version orelse "", .from_hub = from_hub });
    }
    return out.items;
}

const Kind = enum { refresh, install, remove, update, update_all, load, unload, reload };

const Op = struct {
    kind: Kind,
    id: Text(64) = .{},
};

fn start(self: *ModsWindow, shell: *Shell, kind: Kind) void {
    self.begin(shell, .{ .kind = kind });
}

pub fn startOn(self: *ModsWindow, shell: *Shell, kind: Kind, id: []const u8) void {
    var op: Op = .{ .kind = kind };
    op.id.set(id);
    self.begin(shell, op);
}

/// One at a time. Another while one's going is dropped.
fn begin(self: *ModsWindow, shell: *Shell, op: Op) void {
    const io = shell.options.io orelse return;
    if (self.work.busy.swap(true, .acq_rel)) return;
    self.work.group.concurrent(io, run, .{ self, shell, io, op }) catch {
        self.work.busy.store(false, .release);
    };
}

fn setDoing(self: *ModsWindow, io: std.Io, comptime fmt: []const u8, args: anytype) void {
    self.work.lock.lockUncancelable(io);
    defer self.work.lock.unlock(io);
    self.work.doing.print(fmt, args);
    self.work.problem = .{};
}

fn failed(self: *ModsWindow, io: std.Io, comptime fmt: []const u8, args: anytype) void {
    self.work.lock.lockUncancelable(io);
    defer self.work.lock.unlock(io);
    self.work.problem.print(fmt, args);
}

fn run(self: *ModsWindow, shell: *Shell, io: std.Io, op: Op) void {
    defer self.work.busy.store(false, .release);
    const loader = shell.acquireLoader() orelse return;
    defer shell.releaseLoader();
    var scratch_state: std.heap.ArenaAllocator = .init(shell.allocator);
    defer scratch_state.deinit();
    const scratch = scratch_state.allocator();
    const where = whereOf(scratch, loader) catch |err| return self.failed(io, "Couldn't find the hub: {t}", .{err});
    const id = op.id.get();

    switch (op.kind) {
        .refresh => {
            self.setDoing(io, "Checking the hub...", .{});
            rescan(loader);
        },
        .install => {
            self.setDoing(io, "Installing {s}...", .{id});
            _ = registry.mods.install(scratch, io, where, id, null) catch |err| {
                self.failed(io, "Couldn't install {s}: {t}", .{ id, err });
                return self.relist(io, loader);
            };
            rescan(loader);
            if (isState(loader, id, .unloaded)) loadNow(self, io, loader, id);
        },
        .remove => {
            self.setDoing(io, "Uninstalling {s}...", .{id});
            unloadNow(self, io, loader, id);
            registry.mods.remove(scratch, io, where.mods_dir, id) catch |err| self.failed(io, "Couldn't uninstall {s}: {t}", .{ id, err });
            rescan(loader);
        },
        .update => self.updateOne(io, loader, scratch, where, id),
        .update_all => for (self.withUpdates(io, scratch)) |each| self.updateOne(io, loader, scratch, where, each),
        .load => {
            self.setDoing(io, "Turning {s} on...", .{id});
            loadNow(self, io, loader, id);
        },
        .unload => {
            self.setDoing(io, "Turning {s} off...", .{id});
            unloadNow(self, io, loader, id);
        },
        .reload => {
            self.setDoing(io, "Reloading {s}...", .{id});
            const job = loader.reload(id) catch |err| return self.failed(io, "Couldn't reload {s}: {t}", .{ id, err });
            job.wait() catch |err| self.failed(io, "Couldn't reload {s}: {t}", .{ id, err });
        },
    }
    switch (op.kind) {
        .load, .unload, .reload => {},
        else => {
            // After, since the hub's answer may have pulled one
            self.relist(io, loader);
            shell.refreshModProjects(io, loader);
        },
    }
    self.work.lock.lockUncancelable(io);
    defer self.work.lock.unlock(io);
    self.work.doing = .{};
}

/// Off while it updates, then back on if it was.
fn updateOne(self: *ModsWindow, io: std.Io, loader: *PluginLoader, scratch: std.mem.Allocator, where: registry.mods.Where, id: []const u8) void {
    self.setDoing(io, "Updating {s}...", .{id});
    const was_on = isState(loader, id, .loaded);
    if (was_on) unloadNow(self, io, loader, id);
    const updated = registry.mods.update(scratch, io, where, id) catch |err| blk: {
        self.failed(io, "Couldn't update {s}: {t}", .{ id, err });
        break :blk &.{};
    };
    if (updated.len == 0 and self.work.problem.message().len == 0) self.failed(io, "Couldn't update {s}. The log says why", .{id});
    rescan(loader);
    if (was_on and isState(loader, id, .unloaded)) loadNow(self, io, loader, id);
}

/// Installed ones with a newer version, from the last listing.
fn withUpdates(self: *ModsWindow, io: std.Io, scratch: std.mem.Allocator) []const []const u8 {
    self.work.lock.lockUncancelable(io);
    defer self.work.lock.unlock(io);
    const listing = self.work.listing orelse return &.{};
    var ids: std.ArrayList([]const u8) = .empty;
    for (listing.mods) |m| {
        if (!m.hasUpdate()) continue;
        ids.append(scratch, scratch.dupe(u8, m.id) catch continue) catch continue;
    }
    return ids.items;
}

fn whereOf(scratch: std.mem.Allocator, loader: *PluginLoader) !registry.mods.Where {
    const cache = try std.fs.path.join(scratch, &.{ loader.cache_dir, registry.cache_folder });
    const source: registry.Source = try .of(
        cache,
        platform.process.envAlloc(scratch, "WRAITH_REGISTRY") catch null,
        platform.process.envAlloc(scratch, "WRAITH_REGISTRY_KEY") catch null,
    );
    return .{ .source = source, .mods_dir = loader.plugins_dir, .wraith = build_info.version };
}

/// What the hub has for this game and any game, with what's installed.
fn relist(self: *ModsWindow, io: std.Io, loader: *PluginLoader) void {
    var folders_arena: std.heap.ArenaAllocator = .init(loader.allocator);
    const folders = readFolders(folders_arena.allocator(), io, loader.plugins_dir) catch |err| blk: {
        log.warn("Couldn't read {s}: {t}", .{ loader.plugins_dir, err });
        break :blk &.{};
    };
    {
        self.work.lock.lockUncancelable(io);
        defer self.work.lock.unlock(io);
        if (self.work.folders_arena) |*old| old.deinit();
        self.work.folders_arena = folders_arena;
        self.work.folders = folders;
    }
    var arena: std.heap.ArenaAllocator = .init(loader.allocator);
    var problem: Message(160) = .{};
    const listing: ?registry.mods.Listing = blk: {
        const a = arena.allocator();
        const where = whereOf(a, loader) catch |err| {
            problem.print("Couldn't find the hub: {t}", .{err});
            break :blk null;
        };
        const game = a.dupe(u8, loader.game_id.get()) catch break :blk null;
        const games: []const []const u8 = if (game.len > 0) &.{game} else &.{};
        const here = loader.here();
        const engine: ?[]const u8 = if (here.game_engine) |e| a.dupe(u8, e) catch break :blk null else null;
        const variant: ?[]const u8 = if (here.game_engine_variant) |v| a.dupe(u8, v) catch break :blk null else null;
        const made_with: []const registry.mods.MadeWith = &.{.{ .game = if (game.len > 0) game else null, .here = .{ .game_engine = engine, .game_engine_variant = variant } }};
        break :blk registry.mods.list(a, io, where.source, where.mods_dir, where.wraith, games, made_with) catch |err| {
            log.warn("Couldn't get mods from the hub: {t}", .{err});
            problem.print("Couldn't get mods from the hub: {t}", .{err});
            break :blk null;
        };
    };
    self.work.lock.lockUncancelable(io);
    defer self.work.lock.unlock(io);
    self.work.fetched.store(true, .release);
    self.work.hub_problem = problem;
    // Keep the last good one if the hub didn't answer
    if (listing == null and self.work.listing != null) {
        arena.deinit();
        return;
    }
    if (self.work.arena) |*old| old.deinit();
    self.work.arena = arena;
    self.work.listing = listing;
}

fn rescan(loader: *PluginLoader) void {
    const job = loader.rescan() catch |err| return log.warn("Couldn't rescan plugins: {t}", .{err});
    job.wait() catch |err| log.warn("Couldn't rescan plugins: {t}", .{err});
}

fn isState(loader: *PluginLoader, id: []const u8, state: PluginLoader.State) bool {
    const s = loader.stateOf(id) orelse return false;
    return s.state == state;
}

fn loadNow(self: *ModsWindow, io: std.Io, loader: *PluginLoader, id: []const u8) void {
    const job = loader.load(id) catch |err| return self.failed(io, "Couldn't turn {s} on: {t}", .{ id, err });
    job.wait() catch |err| self.failed(io, "Couldn't turn {s} on: {t}", .{ id, err });
}

fn unloadNow(self: *ModsWindow, io: std.Io, loader: *PluginLoader, id: []const u8) void {
    if (!isState(loader, id, .loaded)) return;
    const job = loader.unload(id) catch |err| return self.failed(io, "Couldn't turn {s} off: {t}", .{ id, err });
    job.wait() catch |err| self.failed(io, "Couldn't turn {s} off: {t}", .{ id, err });
}
