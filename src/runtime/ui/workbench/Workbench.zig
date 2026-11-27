//! The developer workbench, a window of its own with docked tools.

const Workbench = @This();

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const Names = @import("../../Names.zig");

const core = @import("wraith_core");
const devtools = @import("tuft_devtools");
const tuft_imgui = @import("tuft_imgui");
const tuft_window = @import("tuft_window");
const Text = @import("tuft_text").Text;
const ui = @import("wraith_ui");

const tuft_arch = @import("tuft_arch");
pub const Debugger = @import("tuft_hook").Debugger;

const c = @import("../imgui.zig").c;
const fonts = @import("../fonts.zig");
const Themes = @import("../Themes.zig");
const Overlay = @import("../Overlay.zig");
const Shell = @import("../shell/Shell.zig");
const Project = @import("../../Project.zig");
const Tweaks = @import("../../Tweaks.zig");
pub const Navigator = @import("Navigator.zig");
const Documents = @import("Documents.zig");
const DebugControl = @import("DebugControl.zig");
const DevMenus = @import("DevMenus.zig");
const Transfer = @import("Transfer.zig");
pub const keys = @import("keys.zig");
pub const Clip = @import("wraith_ui").Clip;
pub const Environment = @import("panels/Environment.zig");
pub const Disassembly = @import("documents/Disassembly.zig");
pub const MemoryViewer = @import("documents/MemoryViewer.zig");
pub const ScriptEditor = @import("documents/ScriptEditor.zig");
pub const SchemaEditor = @import("documents/SchemaEditor.zig");
pub const TweakEditor = @import("documents/TweakEditor.zig");
const TweaksPanel = @import("panels/Tweaks.zig");
const ProjectMenu = @import("ProjectMenu.zig");
const SigMaker = @import("SigMaker.zig");
const StatusBar = @import("StatusBar.zig");
pub const ExportMod = @import("ExportMod.zig");
const Shortcuts = @import("Shortcuts.zig");
pub const Scripts = @import("Scripts.zig");
const Addresses = @import("panels/Addresses.zig");
const Accesses = @import("panels/Accesses.zig");
const Search = @import("panels/Search.zig");
pub const NamesPanel = @import("panels/Names.zig");
pub const SchemasPanel = @import("panels/Schemas.zig");
pub const Classes = @import("panels/Classes.zig");
pub const Hooks = @import("panels/Hooks.zig");
pub const Claims = @import("panels/Claims.zig");
pub const FileIo = @import("panels/FileIo.zig");
pub const Log = @import("panels/Log.zig");
pub const Timings = @import("panels/Timings.zig");
pub const Frames = @import("panels/Frames.zig");
const Memory = @import("panels/Memory.zig");
const Console = @import("panels/Console.zig");
const SessionsPanel = @import("panels/Sessions.zig");
const Breakpoints = @import("panels/Breakpoints.zig");
const Stopped = @import("panels/Stopped.zig");
const Registers = @import("panels/Registers.zig");
pub const Group = @import("Group.zig");
pub const Tabs = @import("Tabs.zig");
const GameSpeed = @import("../GameSpeed.zig");
const Managed = @import("../../Managed.zig");
const plugin_panels = @import("../../host/workbench_panels.zig");
const slots = @import("../../host/slots.zig");

const AppWindow = tuft_imgui.AppWindow;
const log = core.log.scoped(.wraith_ui);

pub const Document = Documents.Document;
const Kind = Documents.Kind;
pub const FileType = Transfer.FileType;

// Documents and going places
pub const go = Documents.go;
pub const openCode = Documents.openCode;
pub const openMemory = Documents.openMemory;
pub const navigator = Documents.navigator;
pub const remote = Documents.remote;
pub const hasPending = Documents.hasPending;
pub const openNew = Documents.openNew;
pub const openNewTweak = Documents.openNewTweak;
pub const scriptDocument = Documents.scriptDocument;
pub const openScript = Documents.openScript;
pub const closeScript = Documents.closeScript;
pub const openTweak = Documents.openTweak;
pub const closeTweak = Documents.closeTweak;
pub const openSchema = Documents.openSchema;
pub const openProjectSchema = Documents.openProjectSchema;
pub const openProjectScript = Documents.openProjectScript;
pub const flushEditors = Documents.flushEditors;
pub const dropEditors = Documents.dropEditors;

// The debugger
pub const focusedStop = DebugControl.focusedStop;
pub const resumeFocused = DebugControl.resumeFocused;
pub const setNextInstruction = DebugControl.setNextInstruction;
pub const markAt = DebugControl.markAt;
pub const toggleBreakpoint = DebugControl.toggleBreakpoint;
pub const toggleHardwareBreakpoint = DebugControl.toggleHardwareBreakpoint;
pub const setBreakpointKind = DebugControl.setBreakpointKind;
pub const toggleBreakpointEnabled = DebugControl.toggleBreakpointEnabled;
pub const deleteAllBreakpoints = DebugControl.deleteAllBreakpoints;

// Project dialogs and files in and out
pub const saveProject = Transfer.saveProject;
pub const dialogOwner = Transfer.dialogOwner;
pub const dialogAlive = Transfer.dialogAlive;
pub const pickFile = Transfer.pickFile;
pub const exportText = Transfer.exportText;
pub const importFile = Transfer.importFile;
pub const importPath = Transfer.importPath;

/// What its tabs draw: each of `Own` that isn't a group, and what's in `Groups`.
pub const Panels = struct {
    addresses: Addresses,
    accesses: Accesses,
    search: Search,
    names: NamesPanel,
    schemas: SchemasPanel,
    classes: Classes,
    hooks: Hooks,
    claims: Claims,
    file_io: FileIo,
    log: Log = .{},
    timings: Timings = .{},
    frames: Frames,
    memory: Memory = .{},
    environment: Environment,
    console: Console,
    sessions: SessionsPanel,
    stopped: Stopped,
    registers: Registers,
    breakpoints: Breakpoints,
    tweaks: TweaksPanel,
};

/// Wraith's own tabs, in their default order, 100 apart from 100, then the ones inside Debug and
/// Diagnostics, which plugins can add to as `wraith/debug` and `wraith/diagnostics`.
pub const Own = enum {
    search,
    addresses,
    names,
    schemas,
    tweaks,
    diagnostics,
    debug,
    scripts,
    log,
    classes,
    threads,
    registers,
    breakpoints,
    timings,
    frames,
    memory_use,
    environment,
    hooks,
    claims,
    io,
};

const OwnTab = struct {
    title: [:0]const u8,
    place: slots.Place = .bottom,
    /// The `Panels` field it draws. Empty holds the ones inside it, or for Scripts draws its split
    panel: []const u8 = "",
    /// The one it's inside
    parent: ?Own = null,
};

const own_tabs: std.EnumArray(Own, OwnTab) = .init(.{
    .search = .{ .title = "Search", .place = .left, .panel = "search" },
    .addresses = .{ .title = "Addresses", .panel = "addresses" },
    .names = .{ .title = "Names", .panel = "names" },
    // With the documents, since it's as big as one
    .schemas = .{ .title = "Schemas", .place = .top, .panel = "schemas" },
    .tweaks = .{ .title = "Tweaks", .panel = "tweaks" },
    .diagnostics = .{ .title = "Diagnostics" },
    // Comes to the front when something stops or a breakpoint's added
    .debug = .{ .title = "Debug" },
    // Comes to the front when a script runs
    .scripts = .{ .title = "Scripts" },
    .log = .{ .title = "Log", .panel = "log" },
    // Only once the game runs C#
    .classes = .{ .title = "Classes", .place = .top, .panel = "classes" },
    .threads = .{ .title = "Threads", .panel = "stopped", .parent = .debug },
    .registers = .{ .title = "Registers", .panel = "registers", .parent = .debug },
    .breakpoints = .{ .title = "Breakpoints", .panel = "breakpoints", .parent = .debug },
    .timings = .{ .title = "Timings", .panel = "timings", .parent = .diagnostics },
    .frames = .{ .title = "Frames", .panel = "frames", .parent = .diagnostics },
    .memory_use = .{ .title = "Memory", .panel = "memory", .parent = .diagnostics },
    .environment = .{ .title = "Environment", .panel = "environment", .parent = .diagnostics },
    .hooks = .{ .title = "Hooks", .panel = "hooks", .parent = .diagnostics },
    .claims = .{ .title = "Claims", .panel = "claims", .parent = .diagnostics },
    .io = .{ .title = "IO", .panel = "file_io", .parent = .diagnostics },
});

/// Tabs drawing more than one panel.
pub const Groups = struct {
    /// Console and Sessions, split.
    scripts: Group,
};

pub const Options = struct {
    /// The address list is only kept with it.
    io: ?std.Io = null,
    /// Null in tests.
    overlay: ?*Overlay = null,
    /// Null in tests.
    shell: ?*Shell = null,
    /// The open project. Its address list is shown and changed here. Must outlive it.
    project: ?*Project = null,
    ini_path: ?[]const u8 = null,
    /// Null is ImGui's dark style. Must outlive it.
    theme: ?*const Themes.Theme = null,
};

const ui_scale = 1.0;
/// Bigger than the overlay's, since it's a desktop app read up close.
const font_size = 15;
const dockspace_name = "wraith.workbench";
/// Bump when `defaultLayout` changes.
const layout_version = "20";

allocator: std.mem.Allocator,
io: ?std.Io,
overlay: ?*Overlay,
/// Null in tests.
shell: ?*Shell,
/// The project's tweaks, set by the shell. Null without a project.
tweaks: ?*Tweaks = null,
/// Shared with the overlay's Tweaks window. Without it the Tweaks panel keeps its own.
tweak_layout: ?*@import("../TweakLayout.zig") = null,
/// The open project. Null without files.
project: ?*Project = null,
ini_path: ?[]u8,
app: ?*AppWindow = null,
theme: ?*const Themes.Theme,
theme_request: Atomic(?*const Themes.Theme) = .init(null),
default_style: c.ImGuiStyle = undefined,
scale: f32 = 1,
/// So there's a default style to theme from.
styled: bool = false,
fronts_pending: u8 = 0,
/// More by then means something's been opened since, which stays in front.
starting_documents: usize = 0,
/// What's in the `workbench` slot, plugins' and Wraith's own, a window each.
tabs: Tabs = .{},
/// Wraith's own in the slot.
own: std.EnumArray(Own, ?*slots.Entry) = .initFill(null),
/// Each kind of document, a tab of many of Wraith's own in the slot.
doc_tabs: std.EnumArray(Kind, Documents.KindTab) = undefined,
doc_entries: std.EnumArray(Kind, ?*slots.Entry) = .initFill(null),
panels: Panels,
groups: Groups,
scripts: Scripts,
/// The workbench's thread never stops.
debugger: Debugger,
seen_stops: u32 = 0,
/// Brings the Debug group's tab to the front next frame, without taking focus from the code.
debug_to_front: bool = false,
/// Focused again once the window has OS focus, since ImGui hands focus back to the old tab a frame later.
focus_when_active: ?Target = null,
/// What `focus` asked for from any thread, packed, or 0.
focus_request: Atomic(u64) = .init(0),
/// `focus_when_active` was focused once already, after the raise.
focus_applied: bool = false,
/// `focus_when_active` is for a stop, so it's dropped once nothing's stopped.
focus_for_stop: bool = false,
/// The stop's code document had its tab in front last frame. For checking from other threads.
code_in_front: tuft_arch.atomic.Value(bool) = .init(false),
/// Same for the memory document.
memory_in_front: tuft_arch.atomic.Value(bool) = .init(false),
last_refresh_ns: u64 = 0,
ticked: bool = false,
/// Whether crashes stop in `debugger`, which they do while it's open.
catching_crashes: bool = false,
holding_game_input: bool = false,
/// From whichever thread. Its tick starts waiting for focus from it.
just_opened: Atomic(bool) = .init(false),
/// Keeps the game's input blocked till it's in front. Its thread.
awaiting_focus: bool = false,
/// So the game can't get stuck blocked. Its thread.
opening_until_ns: u64 = 0,
raise_frames: u8 = 0,
stopped_at: [Debugger.max_paused]usize = undefined,
stopped_len: usize = 0,
/// From other threads. Picked up at the start of its next frame.
going: Navigator.Pending = .{},

// Its thread only, or the test's
documents: std.ArrayList(*Document) = .empty,
next_document: u32 = 1,
/// Going somewhere uses it, else a new one.
active_code: ?*Document = null,
active_memory: ?*Document = null,
/// Where the toolbar's address goes.
last_kind: Kind = .code,
/// The node the last focused one's in.
document_dock: c.ImGuiID = 0,
dockspace: c.ImGuiID = 0,
/// Over the game if we know where that is.
start: [2]f32 = .{ 100, 100 },
reset_layout: bool = false,
/// Also puts windows back where they first were, next frame.
reset_windows: bool = false,
go_to: devtools.AddressBar = .{ .symbols = Names.global_symbols, .memory = .local },
game_speed: GameSpeed = .{},
/// How many `fail` has shown, for tests.
failures: u32 = 0,
project_menu: ProjectMenu = .{},
sig_maker: SigMaker = .{},
export_mod: ExportMod = .{},
shortcuts: Shortcuts = .{},
dev_menus: DevMenus = .{},
/// The project's epoch last seen, to start over when it becomes another.
seen_epoch: u32 = 0,
title_buf: [160:0]u8 = @splat(0),
/// Where the last export or import was.
transfer_folder: Text(260) = .{},
/// Last frame's focused document saves to a file of its own, so the project keys are its.
own_file_focused: bool = false,
plugin_schemas: std.ArrayList(SchemaEditor.Found) = .empty,
plugin_schemas_open: bool = false,

pub fn create(allocator: std.mem.Allocator, options: Options) !*Workbench {
    const self = try allocator.create(Workbench);
    errdefer allocator.destroy(self);
    const ini_path = if (options.ini_path) |p| try allocator.dupe(u8, p) else null;
    errdefer if (ini_path) |p| allocator.free(p);
    self.* = .{
        .allocator = allocator,
        .io = options.io,
        .overlay = options.overlay,
        .shell = options.shell,
        .theme = options.theme,
        .ini_path = ini_path,
        .scripts = .init(allocator, options.shell),
        .debugger = .init(allocator, .{}),
        .panels = .{
            .addresses = .{ .wb = self, .list = .{ .allocator = allocator, .memory = .local, .symbols = Names.global_symbols, .claims = .local }, .keys = .{ .allocator = allocator } },
            .accesses = .{ .wb = self },
            .search = .{ .wb = self, .view = .{ .memory = .local, .symbols = Names.global_symbols } },
            .names = .{ .nav = self.navigator(), .allocator = allocator, .wb = self },
            .schemas = .init(self, allocator),
            .classes = .{ .nav = self.navigator(), .allocator = allocator },
            .hooks = .{ .nav = self.navigator() },
            .claims = .{ .nav = self.navigator() },
            .file_io = .{ .allocator = allocator },
            .environment = .{ .shell = options.shell },
            .frames = .{ .shell = options.shell },
            .console = .{ .wb = self },
            .sessions = .{ .wb = self },
            .stopped = .{ .wb = self },
            .registers = .{ .wb = self },
            .breakpoints = .{ .wb = self },
            .tweaks = .{ .wb = self },
        },
        .groups = undefined,
    };
    const p = &self.panels;
    self.groups = .{
        .scripts = .init(.{ .ratio = 0.75 }, .{ .of("Console", &p.console), .of("Sessions", &p.sessions) }),
    };
    errdefer self.removeOwnTabs();
    inline for (comptime std.enums.values(Own)) |o| if (o != .classes) try self.addOwnTab(o);
    try Documents.addKinds(self);
    self.tabs.sync();
    if (options.project) |project| {
        self.project = project;
        self.panels.addresses.useProject(project);
    }
    // One of each to start, so the layout has them and their spots are kept
    _ = try Documents.newDocument(self, .code);
    _ = try Documents.newDocument(self, .memory);
    _ = try Documents.newSchemaDocument(self, null);
    _ = try Documents.newScriptDocument(self, null);
    _ = try Documents.newTweakDocument(self, .tweak);
    // No focus on appearing, or the last one made would keep its tab in front
    for (self.documents.items) |d| d.window().flags.no_focus_on_appearing = true;
    self.starting_documents = self.documents.items.len;
    DebugControl.hookCrashes(self);
    return self;
}

fn addOwnTab(self: *Workbench, comptime o: Own) !void {
    if (self.own.get(o) != null) return;
    const def = comptime own_tabs.get(o);
    const Draw = struct {
        fn draw(wb: *Workbench, _: slots.Target) void {
            if (def.panel.len > 0) @field(wb.panels, def.panel).draw() else wb.groups.scripts.draw();
        }
    };
    const holds = def.panel.len == 0 and o != .scripts;
    const order: i32 = (@as(i32, @backingInt(o)) + 1) * 100;
    self.own.set(o, try slots.addOwn(.{
        .slot = .workbench,
        .id = @tagName(o),
        .title = def.title,
        .place = def.place,
        .order = order,
        .parent = if (def.parent) |p| "wraith/" ++ @tagName(p) else "",
        .parts = holds,
    }, if (holds) .none else .{ .native = .of(self, Draw.draw) }));
}

fn removeOwnTabs(self: *Workbench) void {
    for (std.enums.values(Own)) |o| if (self.own.get(o)) |e| e.remove();
    self.own = .initFill(null);
    for (std.enums.values(Kind)) |k| if (self.doc_entries.get(k)) |e| e.remove();
    self.doc_entries = .initFill(null);
}

/// Its window, once `tabs` has it.
fn ownTab(self: *Workbench, o: Own) ?*Tabs.Tab {
    const e = self.own.get(o) orelse return null;
    return self.tabs.find(e.label) orelse {
        self.tabs.sync();
        return self.tabs.find(e.label);
    };
}

/// Its window's title, which docking goes by.
pub fn tabTitle(self: *const Workbench, o: Own) [:0]const u8 {
    const e = self.own.get(o) orelse return "";
    return e.label;
}

/// Something to bring to the front: one of its tabs, one inside Debug or Diagnostics, Scripts' Console
/// or Sessions, or a kind of document, with an id for which one.
pub const Tag = enum {
    search,
    addresses,
    names,
    schemas,
    tweaks,
    diagnostics,
    debug,
    scripts,
    log,
    classes,
    threads,
    registers,
    breakpoints,
    timings,
    frames,
    memory_use,
    environment,
    hooks,
    claims,
    io,
    // In Scripts, split
    console,
    sessions,
    // Documents
    code,
    memory,
    script,
    schema,
    tweak,
};

pub const Target = struct { tag: Tag, id: ?u32 = null };

/// Its own tab, or one inside another, for a tag that isn't a document.
fn ownOf(tag: Tag) ?Own {
    return switch (tag) {
        .console, .sessions => .scripts,
        inline else => |t| if (@hasField(Own, @tagName(t))) @field(Own, @tagName(t)) else null,
    };
}

/// The one inside another, as its entry.
fn partOf(self: *Workbench, tag: Tag) ?*slots.Entry {
    const o = ownOf(tag) orelse return null;
    if (own_tabs.get(o).parent == null) return null;
    return self.own.get(o);
}

fn kindOf(tag: Tag) ?Kind {
    return switch (tag) {
        inline else => |t| if (@hasField(Kind, @tagName(t))) @field(Kind, @tagName(t)) else null,
    };
}

pub fn tagOf(kind: Kind) Tag {
    return switch (kind) {
        inline else => |k| @field(Tag, @tagName(k)),
    };
}

/// That document, or without an id, the last one used of its kind.
fn documentFor(self: *Workbench, kind: Kind, id: ?u32) ?*Document {
    if (id) |want| {
        for (self.documents.items) |d| if (d.id == want and std.meta.activeTag(d.body) == kind) return d;
        return null;
    }
    if (kind == .code) if (self.active_code) |d| return d;
    if (kind == .memory) if (self.active_memory) |d| return d;
    var i = self.documents.items.len;
    while (i > 0) {
        i -= 1;
        const d = self.documents.items[i];
        if (std.meta.activeTag(d.body) == kind) return d;
    }
    return null;
}

/// Its window: a tab's, the one a tab inside another's in, or a document's. Its thread.
pub fn windowOf(self: *Workbench, target: Target) ?*ui.Window {
    if (kindOf(target.tag)) |kind| {
        const d = self.documentFor(kind, target.id) orelse return null;
        return d.window();
    }
    const o = ownOf(target.tag) orelse return null;
    const t = self.ownTab(own_tabs.get(o).parent orelse o) orelse return null;
    return &t.window;
}

/// Brings it to the front, with the Workbench over everything else. One inside another comes to its
/// front. Any thread; done next frame, and the newest one wins.
pub fn focus(self: *Workbench, tag: Tag, id: ?u32) void {
    // The tag plus one from bit 40, whether there's an id at bit 32, and the id
    const with_id: u64 = if (id) |n| (@as(u64, 1) << 32) | n else 0;
    const packed_target: u64 = ((@as(u64, @backingInt(tag)) + 1) << 40) | with_id;
    self.focus_request.store(packed_target, .release);
    if (self.app) |app| app.show();
}

/// What `focus` asked for. Its thread, before anything draws.
fn takeFocusRequest(self: *Workbench) void {
    const r = self.focus_request.swap(0, .acq_rel);
    if (r == 0) return;
    const target: Target = .{
        .tag = @fromBackingInt(@as(std.meta.Tag(Tag), @intCast((r >> 40) - 1))),
        .id = if (r & (@as(u64, 1) << 32) != 0) @truncate(r) else null,
    };
    if (target.tag == .classes) self.addOwnTab(.classes) catch {};
    self.select(target.tag);
    const w = self.windowOf(target) orelse return;
    w.focus();
    // Again once the window really has focus, since raising it can hand focus back to the old tab
    self.focus_when_active = target;
    self.focus_applied = false;
    self.focus_for_stop = false;
}

/// Opens it without changing what's in front, so it's there to look at. One inside another comes to
/// its front only if that was closed. Its thread.
pub fn show(self: *Workbench, tag: Tag, id: ?u32) void {
    const w = self.windowOf(.{ .tag = tag, .id = id }) orelse return;
    if (!w.open) self.select(tag);
    w.show();
}

/// Brings one inside another to its front, from the next draw. Its thread.
pub fn select(self: *Workbench, tag: Tag) void {
    const part = self.partOf(tag) orelse return;
    self.tabs.select(part);
}

/// Open, and for one inside another, at its front as of the last frame. Its thread.
pub fn showing(self: *Workbench, tag: Tag, id: ?u32) bool {
    if (self.partOf(tag)) |part| return self.tabs.showingPart(part);
    const w = self.windowOf(.{ .tag = tag, .id = id }) orelse return false;
    return w.open;
}

/// Closes its tab or document. Its thread.
pub fn hide(self: *Workbench, tag: Tag, id: ?u32) void {
    if (self.windowOf(.{ .tag = tag, .id = id })) |w| w.close();
}

/// Saves the layout and the address list. Waits for its thread.
pub fn destroy(self: *Workbench) void {
    DebugControl.unhookCrashes();
    if (self.app) |app| app.destroy();
    // Before what they draw goes
    self.removeOwnTabs();
    self.holdGameInput(false);
    // After the app, so nothing's drawing with it
    DebugControl.deinit(self);
    self.app = null;
    self.panels.search.deinit();
    self.panels.accesses.deinit();
    self.panels.addresses.deinit();
    inline for (.{ "names", "schemas", "classes", "hooks", "claims", "file_io", "log", "timings", "console", "sessions", "stopped", "registers", "breakpoints", "tweaks" }) |name| @field(self.panels, name).deinit();
    for (self.documents.items) |d| Documents.freeDocument(self, d);
    self.project_menu.deinit();
    self.sig_maker.deinit();
    self.dev_menus.deinit();
    SchemaEditor.freeFound(self.allocator, &self.plugin_schemas);
    self.plugin_schemas.deinit(self.allocator);
    self.scripts.deinit();
    self.documents.deinit(self.allocator);
    self.tabs.deinit();
    if (self.ini_path) |p| self.allocator.free(p);
    self.allocator.destroy(self);
}

/// The first time makes its window and thread, without waiting for them. Render thread.
pub fn open(self: *Workbench) void {
    if (self.app == null) {
        // Its thread keeps the address list going from here
        self.panels.addresses.handOver(true);
        if (self.overlay) |o| {
            o.keepGameActive();
            // First time, it opens over the game
            if (o.window.handle()) |game| if (tuft_window.clientToScreen(game, .{ .x = 40, .y = 40 })) |at| {
                self.start = .{ @floatFromInt(at.x), @floatFromInt(at.y) };
            };
        }
        self.app = AppWindow.create(self.allocator, .{
            .title = "Wraith Workbench",
            .draw = .{ .ctx = self, .func = drawThunk },
            .tick = .{ .ctx = self, .func = tickThunk },
            .setup = .{ .ctx = self, .func = setup },
            .activated = .{ .ctx = self, .func = activated },
            .ini_path = self.ini_path,
            .floating = true,
            .icon = "WRAITH_ICON",
        }) catch |err| {
            log.err("Couldn't open the workbench: {t}", .{err});
            self.panels.addresses.handOver(false);
            return;
        };
    }
    self.just_opened.store(true, .release);
    self.app.?.show();
}

/// What has to keep going before its thread does, like holds and hotkeys. Render thread.
pub fn tickUnopened(self: *Workbench) void {
    if (self.app) |app| if (app.failed()) |err| {
        // Its window couldn't be made, so the address list comes back here, and opening tries again
        log.err("Couldn't open the workbench: {t}", .{err});
        app.destroy();
        self.app = null;
        self.panels.addresses.handOver(false);
    };
    self.panels.addresses.tickUnopened();
}

pub fn close(self: *Workbench) void {
    if (self.app) |app| app.hide();
}

pub fn toggle(self: *Workbench) void {
    if (self.isOpen()) self.close() else self.open();
}

pub fn isOpen(self: *const Workbench) bool {
    const app = self.app orelse return false;
    return app.isOpen();
}

// Its thread

fn setup(ctx: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(ctx));
    const io = c.ImGui_GetIO();
    io.*.ConfigErrorRecoveryEnableAssert = false;
    io.*.ConfigFlags |= c.ImGuiConfigFlags_NavEnableKeyboard;
    // Only from the title bar, so dragging inside a view doesn't undock it
    io.*.ConfigWindowsMoveFromTitleBarOnly = true;
    self.scale = c.cImGui_ImplWin32_GetDpiScaleForHwnd(c.ImGui_GetMainViewport().*.PlatformHandleRaw) * ui_scale;
    self.default_style = c.ImGui_GetStyle().*;
    self.styled = true;
    fonts.load(font_size);
    self.applyTheme(self.theme);
}

/// Plus the workbench's own touches. Its thread, between frames.
fn applyTheme(self: *Workbench, theme: ?*const Themes.Theme) void {
    const style = c.ImGui_GetStyle();
    if (theme) |t| t.apply(style, &self.default_style) else style.* = self.default_style;
    // No menu button on docked tabs, and close buttons only on hover
    style.*.WindowMenuButtonPosition = c.ImGuiDir_None;
    style.*.TabCloseButtonMinWidthUnselected = 0;
    style.*.TabCloseButtonMinWidthSelected = 0;
    c.ImGuiStyle_ScaleAllSizes(style, self.scale);
    style.*.FontScaleDpi = self.scale;
    style.*.FontSizeBase = font_size;
    self.theme = theme;
}

/// From its next frame. `theme` must outlive it. Any thread.
pub fn setTheme(self: *Workbench, theme: *const Themes.Theme) void {
    self.theme_request.store(theme, .release);
}

fn activated(ctx: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(ctx));
    if (self.overlay) |o| o.ourWindowActivated();
}

fn tickThunk(ctx: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(ctx));
    self.tick();
}

fn drawThunk(ctx: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(ctx));
    self.draw();
}

/// Work that keeps going while it's closed.
pub fn tick(self: *Workbench) void {
    self.panels.addresses.tick();
    self.panels.accesses.tick();
    DebugControl.tick(self);
    const now = core.timing.now();
    if (self.just_opened.swap(false, .acq_rel)) {
        self.awaiting_focus = true;
        self.opening_until_ns = now + opening_timeout_ns;
    }
    const app = self.app orelse return self.holdGameInput(false);
    // A closed Workbench draws nothing, so its plugins' panels would still say they're open
    if (!app.isOpen()) {
        slots.hide(.workbench);
    }
    const active = app.isActive();
    // Held from opening till it's been in front and you've clicked back into the game
    if (active or !app.isOpen() or now >= self.opening_until_ns) self.awaiting_focus = false;
    self.holdGameInput(app.isOpen() and (active or self.awaiting_focus));
}

/// Then the game gets its input back anyway.
const opening_timeout_ns = 10 * std.time.ns_per_s;

/// The game still thinks it's active, so it'd read input typed here otherwise. Its thread.
pub fn holdGameInput(self: *Workbench, on: bool) void {
    if (on == self.holding_game_input) return;
    const o = self.overlay orelse return;
    self.holding_game_input = on;
    o.take(.keyboard, on);
    o.take(.mouse, on);
    o.requestCursor(on);
}

/// Inside an ImGui frame with docking on.
pub fn draw(self: *Workbench) void {
    if (self.theme_request.swap(null, .acq_rel)) |theme| {
        if (self.styled) self.applyTheme(theme) else self.theme = theme;
    }
    if (devtools.keys.toggle_search) |chord| if (chord.pressed()) self.toggleSearch();
    DebugControl.debugKeys(self);
    Transfer.projectKeys(self);
    // Between windows, so it's before the frame's first one
    if (self.reset_windows) {
        self.reset_windows = false;
        tuft_imgui.resetLayout();
    }
    // So the layout has them
    self.tabs.sync();
    self.takeFocusRequest();
    Documents.goPending(self);
    Documents.followProject(self);
    self.scripts.pump();
    DebugControl.readStops(self);
    var host = windowClass();
    // A top level window of its own, with a taskbar button
    host.ParentViewportId = 0;
    host.ViewportFlagsOverrideClear = c.ImGuiViewportFlags_NoTaskBarIcon;
    if (self.topmost()) host.ViewportFlagsOverrideSet = c.ImGuiViewportFlags_TopMost;
    c.ImGui_SetNextWindowClass(&host);
    c.ImGui_SetNextWindowPos(.{ .x = self.start[0], .y = self.start[1] }, c.ImGuiCond_FirstUseEver);
    c.ImGui_SetNextWindowSize(.{ .x = ui.scaled(1400), .y = ui.scaled(900) }, c.ImGuiCond_FirstUseEver);
    if (self.app) |app| if (app.takeRaise()) {
        c.ImGui_SetNextWindowFocus();
        self.raise_frames = raise_tries;
    };

    var keep_open = true;
    var on_screen = false;
    const flags = c.ImGuiWindowFlags_MenuBar | c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoDocking |
        c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse;
    // Edge to edge, so the dock space and status bar meet the window's sides
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
    const shown = c.ImGui_Begin(@ptrCast(self.windowTitle()), &keep_open, flags);
    c.ImGui_PopStyleVar();
    if (shown) {
        // Its own OS window, not the app's hidden one. Making it can fail
        const viewport = c.ImGui_GetWindowViewport();
        on_screen = viewport != c.ImGui_GetMainViewport() and viewport.*.PlatformHandle != null;
        self.bringWindowToFront();
        self.drawMenuBar();
        self.project_menu.drawPopups(self);
        self.export_mod.draw(self);
        self.shortcuts.draw(self);
        self.sig_maker.poll(self);
        const id = c.ImGui_GetID(@ptrCast(dockspace_name ++ ".v" ++ layout_version));
        self.dockspace = id;
        if (self.reset_layout or !tuft_imgui.dock.exists(id)) {
            self.reset_layout = false;
            self.defaultLayout(id);
        } else {
            self.bringStartingTabsToFront();
        }
        if (self.debug_to_front) {
            self.debug_to_front = false;
            tuft_imgui.dock.bringToFront(self.tabTitle(.debug));
        }
        DebugControl.applyPendingFocus(self);
        _ = c.ImGui_DockSpaceEx(id, .{ .x = 0, .y = -StatusBar.height() }, 0, null);
        self.drawStatusBar();
    }
    c.ImGui_End();
    if (!keep_open) self.close();

    self.pollPluginPanels();
    self.tabs.draw(.{ .ctx = self, .func = placeNode }, .{ .ctx = self, .func = withHost });
    self.dev_menus.drawWindows();
    self.own_file_focused = false;
    Documents.dropClosed(self);
    const memory_front = if (self.active_memory) |m| tuft_imgui.dock.inFront(m.window().title) else false;
    self.memory_in_front.store(on_screen and memory_front, .release);
    const code = self.active_code orelse return self.code_in_front.store(false, .release);
    self.code_in_front.store(on_screen and tuft_imgui.dock.inFront(code.window().title), .release);
}

/// What's going on, along the bottom.
fn drawStatusBar(self: *Workbench) void {
    var bar = StatusBar.begin();
    self.sig_maker.status(&bar);
    self.project_menu.ce.status(&bar);
}

/// Adds Classes once there's C#, and shows the classes plugins asked for.
fn pollPluginPanels(self: *Workbench) void {
    if (Managed.global.running()) self.addOwnTab(.classes) catch {};
    var buf: [256]u8 = undefined;
    if (plugin_panels.takeClass(&buf)) |name| {
        self.panels.classes.show(name);
        self.focus(.classes, null);
    }
}

/// Where a tab goes that has nowhere: at the top with the documents, else with others of its place,
/// else a new spot where the last one of them was.
fn placeNode(ctx: *anyopaque, place: slots.Place) ?c.ImGuiID {
    const self: *Workbench = @ptrCast(@alignCast(ctx));
    if (place != .left and place != .bottom) {
        if (self.document_dock != 0 and tuft_imgui.dock.exists(self.document_dock)) return self.document_dock;
        return tuft_imgui.dock.central(self.dockspace);
    }
    if (self.tabs.nodeOf(place)) |n| return n;
    var rest = tuft_imgui.dock.central(self.dockspace) orelse return null;
    const node = if (place == .left) tuft_imgui.dock.split(&rest, .left, 0.22) else tuft_imgui.dock.split(&rest, .down, 0.35);
    tuft_imgui.dock.finish(self.dockspace);
    return node;
}

/// The project's name, with a star if it's not saved. The part after ### keeps it the same window.
fn windowTitle(self: *Workbench) [*:0]const u8 {
    const fallback = "Wraith Workbench###" ++ dockspace_name;
    const project = self.project orelse return fallback;
    const star = if (project.isDirty()) "*" else "";
    return std.fmt.bufPrintSentinel(&self.title_buf, "{s}{s} - " ++ fallback, .{ project.name(), star }, 0) catch fallback;
}

fn topmost(self: *const Workbench) bool {
    const app = self.app orelse return false;
    return app.isTopmost();
}

/// Its OS window is made after the frame it first shows in, so the first try can be too early.
const raise_tries = 30;

/// ImGui only focuses inside itself, so a new window would stay behind the game. Windows can refuse, so it retries.
fn bringWindowToFront(self: *Workbench) void {
    if (self.raise_frames == 0) return;
    const viewport = c.ImGui_GetWindowViewport();
    // That's the app's hidden window. Ours is one ImGui made, a frame or so later
    if (viewport == c.ImGui_GetMainViewport()) return;
    const hwnd: tuft_window.Handle = @ptrCast(viewport.*.PlatformHandleRaw orelse return);
    self.raise_frames -= 1;
    if (tuft_window.bringToFront(hwnd)) self.raise_frames = 0;
}

/// What `ImGuiWindowClass`'s constructor gives, which C doesn't run.
fn windowClass() c.ImGuiWindowClass {
    var class = std.mem.zeroes(c.ImGuiWindowClass);
    class.ParentViewportId = std.math.maxInt(c.ImGuiID);
    class.DockingAllowUnclassed = true;
    return class;
}

/// Pulled-out panels and documents get a taskbar button and a spot in Alt+Tab.
pub fn withHost(ctx: *anyopaque) void {
    const self: *Workbench = @ptrCast(@alignCast(ctx));
    var class = windowClass();
    class.ParentViewportId = 0;
    class.ViewportFlagsOverrideClear = c.ImGuiViewportFlags_NoTaskBarIcon;
    if (self.topmost()) class.ViewportFlagsOverrideSet = c.ImGuiViewportFlags_TopMost;
    c.ImGui_SetNextWindowClass(&class);
}

fn defaultLayout(self: *Workbench, id: c.ImGuiID) void {
    const avail = c.ImGui_GetContentRegionAvail();
    tuft_imgui.dock.reset(id, .{ avail.x, avail.y });
    var center = id;
    const left = tuft_imgui.dock.split(&center, .left, 0.22);
    const bottom = tuft_imgui.dock.split(&center, .down, 0.35);
    // In their order, which puts Memory and Disassembly first along the top, and new documents after plugins'
    for (self.tabs.list.items) |t| tuft_imgui.dock.window(t.window.title, if (t.place == .left) left else if (t.place == .bottom) bottom else center);
    tuft_imgui.dock.finish(id);
    self.document_dock = center;
    self.fronts_pending = 1;
}

/// Each tab added comes to the front, so otherwise the last one docked would be.
fn bringStartingTabsToFront(self: *Workbench) void {
    if (self.fronts_pending == 0) return;
    self.fronts_pending -= 1;
    tuft_imgui.dock.bringToFront(self.tabTitle(.addresses));
    if (self.documents.items.len != self.starting_documents) return;
    // Focused too, since a dock keeps the focused window's tab in front
    if (self.active_memory) |m| m.window().focus();
}

pub fn toggleSearch(self: *Workbench) void {
    if (self.showing(.search, null)) self.hide(.search, null) else self.focus(.search, null);
}

fn drawMenuBar(self: *Workbench) void {
    if (!c.ImGui_BeginMenuBar()) return;
    defer c.ImGui_EndMenuBar();

    // What the last view used can do, same as its right-click menu
    self.project_menu.drawMenu(self);
    if (ui.menu("Edit")) |menu| {
        defer menu.end();
        if (!ui.Commands.menuItems()) ui.textDisabled("Click in a view first", .{});
    }
    if (ui.menu("Debug")) |menu| {
        defer menu.end();
        DebugControl.drawMenu(self);
    }

    var schemas_open = false;
    if (ui.menu("View")) |menu| {
        defer menu.end();
        for (self.tabs.list.items) |t| {
            // One of many isn't listed, but its kind has New below
            if (t.id != null) continue;
            var buf: [64]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{t.window.label()}, 0) catch continue;
            var ticked = t.window.open;
            if (ui.menuItem(label, .{ .checked = &ticked })) {
                if (ticked) t.window.focus() else t.window.close();
            }
        }
        if (self.tabs.kinds.items.len > 0) ui.separator();
        for (self.tabs.kinds.items) |k| {
            var buf: [80]u8 = undefined;
            const label = std.fmt.bufPrintSentinel(&buf, "New {s}", .{k.title}, 0) catch continue;
            if (ui.menuItem(label, .{})) self.tabs.newOne(k.key);
        }
        ui.separator();
        if (ui.menu("Plugin schemas")) |sub| {
            defer sub.end();
            schemas_open = true;
            Documents.drawPluginSchemas(self);
        }
        ui.separator();
        if (ui.menuItem("Reset layout", .{})) {
            self.reset_layout = true;
            self.reset_windows = true;
        }
    }
    self.plugin_schemas_open = schemas_open;
    if (ui.menu("Window")) |menu| {
        defer menu.end();
        if (ui.menuItem("Keyboard shortcuts...", .{})) self.shortcuts.open();
        if (self.app) |app| {
            var on_top = app.isTopmost();
            if (ui.menuItem("Always on top", .{ .checked = &on_top })) app.setTopmost(on_top);
            ui.tooltip("Keep it and anything pulled out of it above other windows, the game's too", .{});
            if (ui.menuItem("Close", .{})) app.hide();
        }
    }
    self.dev_menus.drawMenus();

    self.game_speed.draw(.{});
    ui.sameLine();
    if (self.go_to.draw()) |address| self.go(.{ .address = address });
}

/// Says what went wrong, in a toast and the log. Its thread.
pub fn fail(self: *Workbench, comptime fmt: []const u8, args: anytype) void {
    self.failures += 1;
    log.warn(fmt, args);
    const app = self.app orelse return;
    var buf: [ui.Toasts.max_text]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch &buf;
    _ = app.toasts.push(.{ .kind = .@"error", .text = text, .seconds = 8 });
}

test {
    _ = @import("tests.zig");
    _ = @import("panels/AddressKeys.zig");
}
