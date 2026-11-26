//! The File menu: save, export as a mod, or open, merge or start another project.

const ProjectMenu = @This();

const std = @import("std");

const devtools = @import("tuft_devtools");
const tuft_window = @import("tuft_window");
const ui = @import("wraith_ui");
const platform = @import("wraith_platform");

const Workbench = @import("Workbench.zig");
const Project = @import("../../Project.zig");
const CeImport = @import("CeImport.zig");

const red: ui.Color = .{ 1, 0.4, 0.4, 1 };
const unsaved_popup = "Unsaved changes##project";
const revert_popup = "Revert project##project";
const close_popup = "Unsaved changes##document";

pub const Action = enum { save, open, merge, new, revert, import_ce };

/// Waiting on the unsaved changes prompt.
pending: ?Action = null,
/// Runs with the popups, since dialogs block till they're done.
run_next: ?Action = null,
open_next: ?[:0]const u8 = null,
/// The document asking to be saved before it closes.
closing: ?u32 = null,
ce: CeImport = .{},

pub fn deinit(self: *ProjectMenu) void {
    self.ce.deinit();
}

/// Asks before closing document `id`, which has changes nothing else keeps.
pub fn askClose(self: *ProjectMenu, id: u32) void {
    self.closing = id;
    self.open_next = close_popup;
}

/// Asks first if it'd drop unsaved changes.
pub fn request(self: *ProjectMenu, wb: *Workbench, action: Action) void {
    const project = wb.project orelse return;
    wb.flushEditors();
    switch (action) {
        .open, .new, .import_ce => if (project.isDirty()) {
            self.pending = action;
            self.open_next = unsaved_popup;
            return;
        },
        .revert => {
            self.open_next = revert_popup;
            return;
        },
        else => {},
    }
    self.run_next = action;
}

pub fn drawMenu(self: *ProjectMenu, wb: *Workbench) void {
    const menu = ui.menu("File") orelse return;
    defer menu.end();
    newItems(wb);
    ui.separator();
    const project = wb.project orelse {
        ui.textDisabled("No project, nothing's kept", .{});
        return;
    };
    const keys = &devtools.keys;
    const dirty = project.isDirty();
    ui.textDisabled("{s}{s}", .{ project.name(), if (dirty) " (unsaved)" else "" });
    ui.tooltip("Saved in {s}", .{project.dir});
    ui.separator();
    if (ui.menuItem("New project", .{})) self.request(wb, .new);
    if (ui.menuItem("Open project...", .{ .shortcut = shortcut(keys.open) })) self.request(wb, .open);
    ui.tooltip("An .rwp, like one from Export as mod, in place of this project. Kept once you save", .{});
    if (ui.menuItem("Merge project...", .{})) self.request(wb, .merge);
    ui.tooltip("Bring another project's addresses, tweaks, scripts and schemas into this one", .{});
    const importing = self.ce.busy();
    if (ui.menuItem(if (importing) "Importing Cheat Engine table..." else "Import Cheat Engine table...", .{ .enabled = !importing })) self.request(wb, .import_ce);
    ui.tooltip("A new project from a .CT, its scripts as tweaks and its records as addresses", .{});
    ui.separator();
    if (ui.menuItem("Save", .{ .shortcut = shortcut(keys.save) })) self.request(wb, .save);
    ui.tooltip("Its files, in the workbench folder by the game's settings", .{});
    if (ui.menuItem("Revert to saved", .{ .enabled = dirty })) self.request(wb, .revert);
    ui.tooltip("Drop what's not saved", .{});
    if (ui.menuItem("Export as mod...", .{ .shortcut = shortcut(keys.save_as) })) wb.export_mod.start(wb);
    ui.tooltip("An .rwp of the project as a mod, to send someone, open in another workbench or upload to the Wraith Hub", .{});
    if (ui.menuItem("Show project folder", .{})) showFolder(wb, project);
    ui.separator();
    filesMenu(wb, project, "Schemas", "schemas", &.{Project.ext.schema});
    filesMenu(wb, project, "Scripts", "scripts", &.{ Project.ext.script, Project.ext.script_lua });
}

/// Things to make. Tweaks need a project, the rest don't.
fn newItems(wb: *Workbench) void {
    const has_tweaks = wb.project != null and wb.tweaks != null;
    if (ui.menuItem("New tweak", .{ .enabled = has_tweaks })) wb.openNewTweak(.tweak);
    ui.tooltip("A change to the game players switch on and off, in the project", .{});
    if (ui.menuItem("New tweak group", .{ .enabled = has_tweaks })) wb.openNewTweak(.group);
    ui.tooltip("A file of tweaks that share data and code, with a group nested in it", .{});
    if (ui.menuItem("New script", .{})) wb.openNew(.script);
    if (ui.menuItem("New schema", .{})) wb.openNew(.schema);
    ui.tooltip("Game types laid out ReClass style, and mapped to memory", .{});
    if (ui.menuItem("New disassembly", .{})) wb.openNew(.code);
    if (ui.menuItem("New memory view", .{})) wb.openNew(.memory);
}

/// The project's files in `folder`, click to open one.
fn filesMenu(wb: *Workbench, project: *Project, label: [:0]const u8, folder: []const u8, suffixes: []const []const u8) void {
    const sub = ui.menu(label) orelse return;
    defer sub.end();
    var any = false;
    for (suffixes) |suffix| {
        var paths = project.list(wb.allocator, folder, suffix) catch return;
        defer Project.freePaths(wb.allocator, &paths);
        any = any or paths.items.len > 0;
        for (paths.items) |p| {
            var buf: [128]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&buf, "{s}", .{std.fs.path.basename(p)}, 0) catch continue;
            if (!ui.menuItem(name, .{})) continue;
            if (std.mem.eql(u8, suffix, Project.ext.schema)) wb.openProjectSchema(p) else wb.openProjectScript(p);
        }
    }
    if (!any) ui.textDisabled("None yet. Change a new one and it's kept here", .{});
}

fn shortcut(chord: ?ui.Chord) ?[:0]const u8 {
    return ui.format("{f}", .{chord orelse return null});
}

/// Inside the workbench's own window, after the menu bar.
pub fn drawPopups(self: *ProjectMenu, wb: *Workbench) void {
    if (self.run_next) |action| {
        self.run_next = null;
        _ = run(wb, action);
    }
    if (self.open_next) |name| {
        self.open_next = null;
        ui.openPopup(name);
    }
    self.drawClose(wb);
    _ = self.ce.poll(wb);
    const project = wb.project orelse return;
    self.drawUnsaved(wb, project);
    drawRevert(wb, project);
}

/// False if it didn't happen, like a dialog cancelled.
fn run(wb: *Workbench, action: Action) bool {
    const project = wb.project orelse return false;
    switch (action) {
        .save => project.save() catch |err| return failed(wb, "save", err),
        .open => {
            const path = pick(wb) orelse return false;
            defer wb.allocator.free(path);
            wb.dropEditors();
            project.open(path) catch |err| return failed(wb, "open it", err);
            remember(wb, path);
        },
        .merge => {
            const path = pick(wb) orelse return false;
            defer wb.allocator.free(path);
            _ = project.mergeFrom(path) catch |err| return failed(wb, "merge it", err);
            wb.panels.addresses.reload();
        },
        .new => {
            wb.dropEditors();
            project.new();
        },
        .revert => {
            wb.dropEditors();
            project.reload() catch |err| return failed(wb, "revert", err);
        },
        .import_ce => {
            const path = pickTable(wb) orelse return false;
            defer wb.allocator.free(path);
            wb.project_menu.ce.start(wb, path);
            return true;
        },
    }
    return true;
}

fn failed(wb: *Workbench, what: []const u8, err: anyerror) bool {
    wb.fail("Couldn't {s}: {t}", .{ what, err });
    return false;
}

/// Where the file dialogs start next time.
fn remember(wb: *Workbench, path: []const u8) void {
    if (wb.shell) |shell| shell.rememberProjectFolder(path);
}

/// In Explorer. There's none till the first save.
fn showFolder(wb: *Workbench, project: *Project) void {
    platform.process.openUri(wb.allocator, project.dir) catch |err| {
        _ = failed(wb, "open the folder, it's made when you first save", err);
    };
}

/// An `.rwp` to open or merge, starting where the last one was. Null if cancelled.
fn pick(wb: *Workbench) ?[]u8 {
    const gpa = wb.allocator;
    const folder = if (wb.shell) |shell| shell.projectFolder(gpa) catch null else null;
    defer if (folder) |f| gpa.free(f);
    return tuft_window.pickFile(gpa, .{
        .mode = .open,
        .owner = wb.dialogOwner(),
        .alive = wb.dialogAlive(),
        .title = "Open project",
        .folder = folder orelse "",
        .kind = "Wraith project",
        .extension = Project.ext.project,
    }) catch |err| {
        _ = failed(wb, "show the file dialog", err);
        return null;
    };
}

/// A `.CT` to import. Null if cancelled.
fn pickTable(wb: *Workbench) ?[]u8 {
    const gpa = wb.allocator;
    const folder = if (wb.shell) |shell| shell.projectFolder(gpa) catch null else null;
    defer if (folder) |f| gpa.free(f);
    return tuft_window.pickFile(gpa, .{
        .mode = .open,
        .owner = wb.dialogOwner(),
        .alive = wb.dialogAlive(),
        .title = "Import Cheat Engine table",
        .folder = folder orelse "",
        .kind = "Cheat Engine table",
        .extension = ".CT",
    }) catch |err| {
        _ = failed(wb, "show the file dialog", err);
        return null;
    };
}

fn close() void {
    ui.closePopup();
}

fn drawUnsaved(self: *ProjectMenu, wb: *Workbench, project: *Project) void {
    const modal = ui.modal(unsaved_popup, .{ .remember = true }) orelse return;
    defer modal.end();
    const action = self.pending orelse return close();
    ui.text("Save changes to {s} first?", .{project.name()});
    if (ui.button("Save")) {
        close();
        if (run(wb, .save)) self.run_next = action;
        self.pending = null;
    }
    ui.sameLine();
    if (ui.button("Don't save")) {
        close();
        self.run_next = action;
        self.pending = null;
    }
    ui.sameLine();
    if (ui.button("Cancel") or ui.isKeyPressed(.escape, false)) {
        close();
        self.pending = null;
    }
}

fn drawRevert(wb: *Workbench, project: *Project) void {
    const modal = ui.modal(revert_popup, .{ .remember = true }) orelse return;
    defer modal.end();
    ui.text("Drop the unsaved changes to {s}?", .{project.name()});
    if (ui.button("Revert")) {
        close();
        _ = run(wb, .revert);
    }
    ui.sameLine();
    if (ui.button("Cancel") or ui.isKeyPressed(.escape, false)) close();
}

fn drawClose(self: *ProjectMenu, wb: *Workbench) void {
    const modal = ui.modal(close_popup, .{ .remember = true }) orelse return;
    defer modal.end();
    const doc = for (wb.documents.items) |d| {
        if (self.closing == d.id) break d;
    } else return close();
    const w = doc.window();
    ui.text("Save {s} before closing it?", .{w.label()});
    if (ui.button("Save")) {
        switch (doc.body) {
            .schema => |*l| {
                l.save();
                if (l.saved) w.open = false;
            },
            else => {},
        }
        close();
    }
    ui.sameLine();
    if (ui.button("Close without saving")) {
        w.unsaved = false;
        w.open = false;
        close();
    }
    ui.sameLine();
    if (ui.button("Cancel") or ui.isKeyPressed(.escape, false)) close();
}
