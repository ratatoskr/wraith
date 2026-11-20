//! Project keys and file dialogs, and files going in and out of the project.

const std = @import("std");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const tuft_window = @import("tuft_window");

const c = @import("../imgui.zig").c;
const Project = @import("../../Project.zig");
const Workbench = @import("Workbench.zig");
const Debugger = Workbench.Debugger;
const pressed = @import("keys.zig").pressed;

/// Ctrl+S and friends, anywhere in the workbench. A document with a file of its own keeps them.
pub fn projectKeys(self: *Workbench) void {
    if (self.project == null or self.own_file_focused) return;
    const chords = &devtools.keys;
    if (pressed(chords.save_as)) {
        self.project_menu.request(self, .save_as);
    } else if (pressed(chords.save)) {
        self.project_menu.request(self, .save);
    } else if (pressed(chords.open)) {
        self.project_menu.request(self, .open);
    }
}

/// Saves the project, asking where if it's never been saved.
pub fn saveProject(self: *Workbench) void {
    self.project_menu.request(self, .save);
}

/// For native dialogs. Inside one of its windows.
pub fn dialogOwner(_: *Workbench) ?tuft_window.Handle {
    const viewport = c.ImGui_GetWindowViewport();
    return @ptrCast(viewport.*.PlatformHandleRaw orelse return null);
}

/// Keeps a stop from being let go while a file dialog's up, as long as this thread still answers.
pub fn dialogAlive(self: *Workbench) tuft_window.FileDialog.Alive {
    return .{ .ctx = &self.debugger, .func = struct {
        fn beat(ctx: *anyopaque) void {
            const d: *Debugger = @ptrCast(@alignCast(ctx));
            d.beat();
        }
    }.beat };
}

pub const FileType = struct {
    /// Like "Tweak".
    kind: []const u8,
    /// Like ".rwt".
    extension: []const u8,

    pub const tweak: FileType = .{ .kind = "Tweak", .extension = Project.ext.tweak };
    pub const script: FileType = .{ .kind = "Script", .extension = Project.ext.script };
    pub const script_lua: FileType = .{ .kind = "Lua script", .extension = Project.ext.script_lua };
    pub const schema: FileType = .{ .kind = "Schema", .extension = Project.ext.schema };
    pub const addresses: FileType = .{ .kind = "Address list", .extension = Project.ext.addresses };
};

/// A file dialog starting where the last export or import was. Null if cancelled. The caller frees it.
pub fn pickFile(self: *Workbench, mode: tuft_window.FileDialog.Mode, file_type: FileType, file_name: []const u8) ?[]u8 {
    const gpa = self.allocator;
    if (self.transfer_folder.len() == 0) if (self.shell) |shell| if (shell.projectFolder(gpa) catch null) |f| {
        defer gpa.free(f);
        self.transfer_folder.set(f);
    };
    var title_text: [64]u8 = undefined;
    const result = tuft_window.pickFile(gpa, .{
        .mode = mode,
        .owner = dialogOwner(self),
        .alive = dialogAlive(self),
        .title = std.fmt.bufPrint(&title_text, "{s} {s}", .{ if (mode == .save) "Export" else "Import", file_type.kind }) catch "",
        .folder = self.transfer_folder.get(),
        .file_name = file_name,
        .kind = file_type.kind,
        .extension = file_type.extension,
    }) catch |err| {
        self.fail("Couldn't show the file dialog: {t}", .{err});
        return null;
    };
    const picked = result orelse return null;
    if (std.fs.path.dirname(picked)) |folder| self.transfer_folder.set(folder);
    return picked;
}

/// Asks where, then writes `text` there.
pub fn exportText(self: *Workbench, file_type: FileType, file_name: []const u8, text: []const u8) void {
    const io = self.io orelse return;
    const path = pickFile(self, .save, file_type, file_name) orelse return;
    defer self.allocator.free(path);
    core.files.write(io, path, text, .{ .make_dir = true }) catch |err| return failedTransfer(self, "export", err);
}

/// Asks for a file and copies it into the project's `folder`, under a free name. Returns where
/// it went, which the caller frees, or null if cancelled.
pub fn importFile(self: *Workbench, file_type: FileType, folder: []const u8) ?[]u8 {
    const path = pickFile(self, .open, file_type, "") orelse return null;
    defer self.allocator.free(path);
    return importPath(self, file_type, folder, path) catch |err| failedImport(self, err);
}

/// Copies `path` into the project's `folder`. Returns where it went, which the caller frees.
pub fn importPath(self: *Workbench, file_type: FileType, folder: []const u8, path: []const u8) ![]u8 {
    const io = self.io orelse return error.NoFiles;
    const project = self.project orelse return error.NoProject;
    const gpa = self.allocator;
    var reading = try io.concurrent(readFile, .{ io, gpa, path });
    const text = try reading.await(io);
    defer gpa.free(text);
    // `god.js` or `god.rwt` both become `god.rwt`
    const base = std.fs.path.basename(path);
    const stem = base[0 .. std.mem.indexOfScalar(u8, base, '.') orelse base.len];
    var buf: [160]u8 = undefined;
    const want = try std.fmt.bufPrint(&buf, "{s}/{s}{s}", .{ folder, stem, file_type.extension });
    const at = try project.freeName(want);
    errdefer project.allocator.free(at);
    try project.write(at, text);
    return at;
}

fn failedTransfer(self: *Workbench, what: []const u8, err: anyerror) void {
    self.fail("Couldn't {s} it: {t}", .{ what, err });
}

fn failedImport(self: *Workbench, err: anyerror) ?[]u8 {
    failedTransfer(self, "import", err);
    return null;
}

fn readFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(16 << 20));
}
