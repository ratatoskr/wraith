//! The workbench's documents: making, finding, drawing and closing them, and going places in them.
//! Its thread, or the test's, unless it says otherwise.

const std = @import("std");
const Names = @import("../../Names.zig");

const Range = @import("tuft_mem").Range;
const ui = @import("wraith_ui");

const c = @import("../imgui.zig").c;
const W = @import("wraith_api").wraith;
const sal = @import("wraith_api").salamander;
const slots = @import("../../host/slots.zig");
const Workbench = @import("Workbench.zig");
const Navigator = @import("Navigator.zig");
const Disassembly = @import("documents/Disassembly.zig");
const MemoryViewer = @import("documents/MemoryViewer.zig");
const ScriptEditor = @import("documents/ScriptEditor.zig");
const SchemaEditor = @import("documents/SchemaEditor.zig");
const TweakEditor = @import("documents/TweakEditor.zig");

const max_documents = 32;

pub const Document = struct {
    id: u32,
    /// Its tab's label, like `Memory 2` or `player.sal`.
    title: [48:0]u8,
    dock: c.ImGuiID = 0,
    body: union(enum) {
        code: Disassembly,
        memory: MemoryViewer,
        script: ScriptEditor,
        schema: SchemaEditor,
        tweak: TweakEditor,
    },

    /// Its tab's, which the Workbench's tabs keep.
    pub fn window(self: *Document) *ui.Window {
        return switch (self.body) {
            inline else => |*b| b.window,
        };
    }

    fn label(self: *const Document) []const u8 {
        return std.mem.sliceTo(&self.title, 0);
    }
};

pub const Kind = std.meta.Tag(@FieldType(Document, "body"));

// Each kind, a tab of many in the `workbench` slot

/// What View's New says, and each one's label till it has its own.
fn kindTitle(kind: Kind) []const u8 {
    return switch (kind) {
        .code => "Disassembly",
        .memory => "Memory",
        .script => "Script",
        .schema => "Schema",
        .tweak => "Tweak",
    };
}

/// Memory and Disassembly first along the top, the new ones after plugins' tabs.
fn kindOrder(kind: Kind) i32 {
    return switch (kind) {
        .memory => 50,
        .code => 60,
        .script => 20_000,
        .schema => 20_100,
        .tweak => 20_200,
    };
}

/// A kind of document as Wraith's own `WorkbenchTab`, each one by its id.
pub const KindTab = struct {
    wb: *Workbench,
    kind: Kind,
    id_buf: [12]u8 = undefined,

    pub fn describe(self: *KindTab) W.WorkbenchTab.Info {
        return .{ .title = kindTitle(self.kind), .kind = @tagName(self.kind), .place = .top, .order = kindOrder(self.kind), .multi = true };
    }

    pub fn draw(self: *KindTab, id: []const u8) void {
        const d = self.byId(id) orelse return;
        drawBody(self.wb, d);
    }

    pub fn status(self: *KindTab, id: []const u8) W.WorkbenchTab.State {
        const d = self.byId(id) orelse return .{};
        renamed(d);
        return .{ .title = d.label(), .unsaved = d.body == .schema and !d.body.schema.saved };
    }

    /// View's New.
    pub fn create(self: *KindTab) []const u8 {
        const d = make(self.wb, self.kind) catch |err| {
            self.wb.fail("Couldn't open another: {t}", .{err});
            return "";
        };
        return std.fmt.bufPrint(&self.id_buf, "{d}", .{d.id}) catch "";
    }

    /// Closing one that isn't saved and has no backup asks first.
    pub fn keepOpen(self: *KindTab, id: []const u8) bool {
        const d = self.byId(id) orelse return false;
        if (d.body != .schema or d.body.schema.saved) return false;
        self.wb.project_menu.askClose(d.id);
        return true;
    }

    fn byId(self: *KindTab, id: []const u8) ?*Document {
        const n = std.fmt.parseInt(u32, id, 10) catch return null;
        for (self.wb.documents.items) |d| if (d.id == n and d.body == self.kind) return d;
        return null;
    }
};

/// Each kind's tab, Wraith's own. Once, as the Workbench starts.
pub fn addKinds(self: *Workbench) !void {
    for (std.enums.values(Kind)) |kind| {
        self.doc_tabs.set(kind, .{ .wb = self, .kind = kind });
        const tab = W.WorkbenchTab.init(self.doc_tabs.getPtr(kind), sal.implement(W.WorkbenchTab, KindTab));
        self.doc_entries.set(kind, try slots.addOwn(.{
            .slot = .workbench,
            .id = @tagName(kind),
            .title = kindTitle(kind),
            .place = .top,
            .order = kindOrder(kind),
            .multi = true,
        }, .{ .tab = tab }));
    }
}

/// A new one of `kind`, like View's New makes.
fn make(self: *Workbench, kind: Kind) !*Document {
    return switch (kind) {
        .script => newScriptDocument(self, null),
        .schema => newSchemaDocument(self, null),
        .tweak => newTweakDocument(self, .tweak),
        else => newDocument(self, kind),
    };
}

// Going places

/// Uses the active document of its kind, else a new one.
pub fn go(self: *Workbench, request: Navigator.Request) void {
    // Going somewhere wins over a stop that's still waiting to bring its code to the front
    self.focus_when_active = null;
    switch (request) {
        .code => |address| {
            const doc = self.active_code orelse (newDocument(self, .code) catch return);
            self.last_kind = .code;
            doc.body.code.open(address);
            focusOnceActive(self, doc);
        },
        .memory => |m| {
            const doc = self.active_memory orelse (newDocument(self, .memory) catch return);
            self.last_kind = .memory;
            doc.body.memory.open(m.address, m.len, m.highlight);
            focusOnceActive(self, doc);
        },
        .address => |address| switch (self.last_kind) {
            .code, .script, .schema, .tweak => go(self, .{ .code = address }),
            .memory => go(self, .{ .memory = .{ .address = address, .len = 1, .highlight = null } }),
        },
    }
}

/// Refocuses once the window really has focus, since raising it can hand focus back to the old tab.
fn focusOnceActive(self: *Workbench, doc: *Document) void {
    self.focus_when_active = .{ .tag = Workbench.tagOf(std.meta.activeTag(doc.body)), .id = doc.id };
    self.focus_applied = false;
    self.focus_for_stop = false;
}

pub fn openCode(self: *Workbench, address: usize) void {
    go(self, .{ .code = address });
}

pub fn openMemory(self: *Workbench, address: usize, len: usize, highlight: ?Range) void {
    go(self, .{ .memory = .{ .address = address, .len = len, .highlight = highlight } });
}

/// Goes places right away. Its thread.
pub fn navigator(self: *Workbench) Navigator {
    return .{ .ctx = self, .func = goNow };
}

/// Opens the workbench and goes there next frame. Render thread.
pub fn remote(self: *Workbench) Navigator {
    return .{ .ctx = self, .func = goLater };
}

fn goNow(ctx: *anyopaque, request: Navigator.Request) void {
    go(@ptrCast(@alignCast(ctx)), request);
}

fn goLater(ctx: *anyopaque, request: Navigator.Request) void {
    const self: *Workbench = @ptrCast(@alignCast(ctx));
    self.going.put(request);
    self.open();
}

pub fn hasPending(self: *Workbench) bool {
    return self.going.has();
}

pub fn goPending(self: *Workbench) void {
    if (self.going.take()) |request| go(self, request);
}

// Making and finding them

pub fn newDocument(self: *Workbench, kind: Kind) !*Document {
    if (self.documents.items.len == max_documents) return error.TooManyDocuments;
    const doc = try self.allocator.create(Document);
    errdefer self.allocator.destroy(doc);
    const id = self.next_document;
    doc.* = .{
        .id = id,
        .title = @splat(0),
        .body = switch (kind) {
            // Through the debugger, so its int3s show as the code they replaced
            .code => .{ .code = .{ .wb = self, .code = .{ .memory = self.debugger.memory(), .symbols = Names.global_symbols, .claims = .local } } },
            .memory => .{ .memory = .{
                .wb = self,
                .hex = .{ .memory = self.debugger.memory(), .claims = .local },
                .inspector = .{ .memory = self.debugger.memory(), .symbols = Names.global_symbols, .claims = .local },
            } },
            .script => .{ .script = .{ .wb = self } },
            .schema => .{ .schema = .{ .wb = self, .view = .{ .allocator = self.allocator, .symbols = Names.global_symbols, .claims = .local } } },
            .tweak => .{ .tweak = .{ .wb = self } },
        },
    };
    // Its tab's ID is its kind and id, so it keeps its spot. Empty ones are new till saved somewhere
    const label = switch (kind) {
        .code => "Disassembly",
        .memory => "Memory",
        .script => "New script",
        .schema => "New schema",
        .tweak => "New tweak",
    };
    const others = countOf(self, kind);
    if (others == 0) {
        _ = std.fmt.bufPrintSentinel(&doc.title, "{s}", .{label}, 0) catch {};
    } else {
        _ = std.fmt.bufPrintSentinel(&doc.title, "{s} {d}", .{ label, others + 1 }, 0) catch {};
    }
    // Its tab, now, so it can be focused straight away
    const entry = self.doc_entries.get(kind) orelse return error.NoTab;
    var id_buf: [12]u8 = undefined;
    const tab = try self.tabs.open(entry, std.fmt.bufPrint(&id_buf, "{d}", .{id}) catch unreachable);
    errdefer tab.window.close();
    switch (doc.body) {
        inline else => |*b| b.window = &tab.window,
    }
    try self.documents.append(self.allocator, doc);
    self.next_document += 1;
    switch (kind) {
        .code => self.active_code = doc,
        .memory => self.active_memory = doc,
        .script, .schema, .tweak => {},
    }
    return doc;
}

/// With what it last ran, or a new session with the example.
pub fn newScriptDocument(self: *Workbench, session: ?u32) !*Document {
    const doc = try newDocument(self, .script);
    errdefer {
        _ = self.documents.pop();
        freeDocument(self, doc);
    }
    const editor = &doc.body.script;
    if (session) |id| {
        const s = self.scripts.find(id) orelse return error.NoSuchSession;
        try editor.init(if (s.code.len > 0) s.code else null);
        editor.session = id;
        // A project script shows what's in the project, which may not have run yet
        if (s.filePath()) |f| if (self.project) |p| if (p.read(self.allocator, f) catch null) |text| {
            defer self.allocator.free(text);
            editor.setProjectFile(f, text);
        };
    } else {
        try editor.init(null);
        editor.session = try self.scripts.newSession(doc.label());
    }
    return doc;
}

pub fn scriptDocument(self: *Workbench, session: u32) ?*Document {
    for (self.documents.items) |d| switch (d.body) {
        .script => |*s| if (s.session == session and d.window().open) return d,
        else => {},
    };
    return null;
}

pub fn openScript(self: *Workbench, session: u32) void {
    const doc = scriptDocument(self, session) orelse (newScriptDocument(self, session) catch |err| {
        self.fail("Couldn't open it: {t}", .{err});
        return;
    });
    doc.window().focus();
}

/// At the end of the frame.
pub fn closeScript(self: *Workbench, session: u32) void {
    if (scriptDocument(self, session)) |d| d.window().open = false;
}

pub fn freeDocument(self: *Workbench, d: *Document) void {
    switch (d.body) {
        .script => |*s| s.deinit(),
        .schema => |*l| l.deinit(),
        .tweak => |*t| t.deinit(),
        else => {},
    }
    self.allocator.destroy(d);
}

pub fn newSchemaDocument(self: *Workbench, path: ?[]const u8) !*Document {
    const doc = try newDocument(self, .schema);
    errdefer {
        _ = self.documents.pop();
        freeDocument(self, doc);
    }
    const editor = &doc.body.schema;
    if (path) |p| {
        try editor.open(p);
        retitle(doc, std.fs.path.basename(p));
    } else {
        try editor.init(null);
    }
    return doc;
}

fn tweakDocument(self: *Workbench, path: []const u8) ?*Document {
    for (self.documents.items) |d| switch (d.body) {
        .tweak => |*t| if (d.window().open and !t.isNew() and std.mem.eql(u8, t.filePath(), path)) return d,
        else => {},
    };
    return null;
}

/// A project's tweak, `tweaks/x.rwt`.
pub fn openTweak(self: *Workbench, path: []const u8) void {
    if (tweakDocument(self, path)) |d| return d.window().focus();
    const doc = newDocument(self, .tweak) catch |err| {
        self.fail("Couldn't open it: {t}", .{err});
        return;
    };
    doc.body.tweak.init(path, .tweak) catch |err| {
        _ = self.documents.pop();
        freeDocument(self, doc);
        self.fail("Couldn't open it: {t}", .{err});
        return;
    };
    retitle(doc, doc.body.tweak.name());
    doc.window().focus();
}

/// A new tweak or group with no file yet, its template as a hint. It gets one once something's typed.
pub fn newTweakDocument(self: *Workbench, kind: TweakEditor.Kind) !*Document {
    const doc = try newDocument(self, .tweak);
    errdefer {
        _ = self.documents.pop();
        freeDocument(self, doc);
    }
    try doc.body.tweak.init(null, kind);
    if (kind == .group) retitle(doc, "New tweak group");
    return doc;
}

pub fn openNewTweak(self: *Workbench, kind: TweakEditor.Kind) void {
    const doc = newTweakDocument(self, kind) catch |err| {
        self.fail("Couldn't open another: {t}", .{err});
        return;
    };
    doc.window().focus();
}

/// At the end of the frame. What's typed and not in the project yet is dropped.
pub fn closeTweak(self: *Workbench, path: []const u8) void {
    const d = tweakDocument(self, path) orelse return;
    d.body.tweak.pending = false;
    d.window().open = false;
}

/// What's typed in editors goes to the project, so saving gets it.
pub fn flushEditors(self: *Workbench) void {
    for (self.documents.items) |d| switch (d.body) {
        .tweak => |*t| t.flush(),
        .schema => |*l| l.flush(),
        .script => |*s| s.flush(),
        else => {},
    };
}

/// Closes the project's editors without keeping what's typed, for when it's dropped.
pub fn dropEditors(self: *Workbench) void {
    for (self.documents.items) |d| switch (d.body) {
        // A new one stays, empty
        .tweak => |*t| if (t.isNew()) t.clear() else {
            t.pending = false;
            d.window().open = false;
        },
        .schema => |*l| if (!l.ownFile()) {
            l.pending = false;
            if (l.projectPath() != null) d.window().open = false;
        },
        .script => |*s| {
            s.pending = false;
            if (s.projectPath() != null) d.window().open = false;
        },
        else => {},
    };
    for (self.scripts.sessions.items) |s| self.scripts.bindFile(s.id, "");
}

/// Its tab's label, like `x.sal`. Its ID stays its kind and id, so it keeps its spot.
fn retitle(d: *Document, label: []const u8) void {
    // It can be what's there already
    const n = @min(label.len, d.title.len);
    @memmove(d.title[0..n], label[0..n]);
    d.title[n] = 0;
}

/// A new label for one renamed, like by being saved.
fn renamed(d: *Document) void {
    switch (d.body) {
        .schema => |*l| if (l.renamed) {
            l.renamed = false;
            if (l.name()) |n| retitle(d, n);
        },
        .tweak => |*t| if (t.renamed) {
            t.renamed = false;
            retitle(d, t.name());
        },
        .script => |*s| if (s.renamed) {
            s.renamed = false;
            if (s.projectPath()) |path| retitle(d, std.fs.path.basename(path));
        },
        else => {},
    }
}

/// A project's schema, `schemas/x.sal`.
pub fn openProjectSchema(self: *Workbench, path: []const u8) void {
    const project = self.project orelse return;
    for (self.documents.items) |d| switch (d.body) {
        .schema => |*l| if (d.window().open) if (l.projectPath()) |p| if (std.mem.eql(u8, p, path)) {
            d.window().focus();
            return;
        },
        else => {},
    };
    const doc = newDocument(self, .schema) catch |err| {
        self.fail("Couldn't open it: {t}", .{err});
        return;
    };
    doc.body.schema.openInProject(project, path) catch |err| {
        _ = self.documents.pop();
        freeDocument(self, doc);
        self.fail("Couldn't open {s}: {t}", .{ path, err });
        return;
    };
    retitle(doc, std.fs.path.basename(path));
    doc.window().focus();
}

/// A project's script, `scripts/x.rws.js`, in a session of its own.
pub fn openProjectScript(self: *Workbench, path: []const u8) void {
    if (self.scripts.findFile(path)) |s| return openScript(self, s.id);
    const project = self.project orelse return;
    const text = (project.read(self.allocator, path) catch null) orelse return;
    defer self.allocator.free(text);
    const doc = newScriptDocument(self, null) catch |err| {
        self.fail("Couldn't open it: {t}", .{err});
        return;
    };
    doc.body.script.setProjectFile(path, text);
    doc.window().focus();
}

/// When the project becomes another, its editors close and the address list starts over.
pub fn followProject(self: *Workbench) void {
    const project = self.project orelse return;
    const now = project.epoch();
    if (now == self.seen_epoch) return;
    const first = self.seen_epoch == 0;
    self.seen_epoch = now;
    if (first) return;
    dropEditors(self);
    self.panels.addresses.reload();
}

pub fn openSchema(self: *Workbench, path: []const u8) void {
    for (self.documents.items) |d| switch (d.body) {
        .schema => |*l| if (d.window().open) if (l.savedPath()) |p| if (std.mem.eql(u8, p, path)) {
            d.window().focus();
            return;
        },
        else => {},
    };
    const doc = newSchemaDocument(self, path) catch |err| {
        self.fail("Couldn't open {s}: {t}", .{ std.fs.path.basename(path), err });
        return;
    };
    doc.window().focus();
}

pub fn openNew(self: *Workbench, kind: Kind) void {
    const doc = make(self, kind) catch |err| {
        self.fail("Couldn't open another: {t}", .{err});
        return;
    };
    doc.window().focus();
}

fn countOf(self: *const Workbench, kind: Kind) usize {
    var n: usize = 0;
    for (self.documents.items) |d| n += @intFromBool(d.body == kind);
    return n;
}

pub fn dropClosed(self: *Workbench) void {
    var i: usize = 0;
    while (i < self.documents.items.len) {
        const d = self.documents.items[i];
        if (d.window().open) {
            i += 1;
            continue;
        }
        if (self.active_code == d) self.active_code = null;
        if (self.active_memory == d) self.active_memory = null;
        _ = self.documents.orderedRemove(i);
        freeDocument(self, d);
    }
}

// Drawing them

/// Inside its tab's window, which the Workbench's tabs begin.
fn drawBody(self: *Workbench, d: *Document) void {
    // New ones go where this is, and going somewhere uses this one
    const dock = c.ImGui_GetWindowDockID();
    d.dock = dock;
    if (dock != 0) self.document_dock = dock;
    if (c.ImGui_IsWindowFocused(c.ImGuiFocusedFlags_RootAndChildWindows)) {
        switch (d.body) {
            .code => self.active_code = d,
            .memory => self.active_memory = d,
            .script, .schema, .tweak => {},
        }
        if (d.body == .code or d.body == .memory) self.last_kind = d.body;
        if (d.body == .schema and d.body.schema.ownFile()) self.own_file_focused = true;
    }
    switch (d.body) {
        inline else => |*b| b.draw(),
    }
}

pub fn drawPluginSchemas(self: *Workbench) void {
    if (!self.plugin_schemas_open) SchemaEditor.findPluginSchemas(self, &self.plugin_schemas);
    if (self.plugin_schemas.items.len == 0) {
        ui.textDisabled("No plugin has a schema folder", .{});
        return;
    }
    for (self.plugin_schemas.items) |found| {
        if (ui.menuItem(found.label, .{})) openSchema(self, found.path);
    }
}
