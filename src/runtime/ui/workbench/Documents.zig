//! The workbench's documents. Making, finding, drawing and closing them, and going places in them.
//! All on its thread, or the test's, unless it says otherwise.

const std = @import("std");
const Names = @import("../../Names.zig");

const Range = @import("tuft_mem").Range;
const ui = @import("wraith_ui");

const c = @import("../imgui.zig").c;
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
    title: [48:0]u8,
    dock: c.ImGuiID = 0,
    body: union(enum) {
        code: Disassembly,
        memory: MemoryViewer,
        script: ScriptEditor,
        schema: SchemaEditor,
        tweak: TweakEditor,
    },

    pub fn window(self: *Document) *ui.Window {
        return switch (self.body) {
            inline else => |*b| &b.window,
        };
    }
};

pub const Kind = std.meta.Tag(@FieldType(Document, "body"));

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

/// Opening the workbench raises its window, and that can give the old tab focus back a frame or so
/// after this one took it. So it's focused again once the window really has focus.
fn focusOnceActive(self: *Workbench, doc: *Document) void {
    self.focus_when_active = doc;
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
    // The part after ### is the ID, so a document keeps its spot in the layout
    const label = switch (kind) {
        .code => "Disassembly",
        .memory => "Memory",
        .script => "Script",
        .schema => "Schema",
        .tweak => "Tweak",
    };
    const others = countOf(self, kind);
    if (others == 0) {
        _ = std.fmt.bufPrintSentinel(&doc.title, "{s}###{t}.{d}", .{ label, kind, id }, 0) catch {};
    } else {
        _ = std.fmt.bufPrintSentinel(&doc.title, "{s} {d}###{t}.{d}", .{ label, others + 1, kind, id }, 0) catch {};
    }
    doc.window().title = std.mem.sliceTo(&doc.title, 0);
    doc.window().open = true;
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
        const title = std.mem.sliceTo(&doc.title, 0);
        editor.session = try self.scripts.newSession(title[0 .. std.mem.indexOf(u8, title, "###") orelse title.len]);
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
        _ = std.fmt.bufPrintSentinel(&doc.title, "{s}###schema.{d}", .{ std.fs.path.basename(p), doc.id }, 0) catch {};
        doc.window().title = std.mem.sliceTo(&doc.title, 0);
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
    _ = std.fmt.bufPrintSentinel(&doc.title, "{s}###tweak.{d}", .{ doc.body.tweak.name(), doc.id }, 0) catch {};
    doc.window().title = std.mem.sliceTo(&doc.title, 0);
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
    if (kind == .group) retitle(doc, "Tweak group");
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

/// Like `x.sal###schema.3`, so it keeps its spot.
fn retitle(d: *Document, label: []const u8) void {
    _ = std.fmt.bufPrintSentinel(&d.title, "{s}###{s}.{d}", .{ label[0..@min(label.len, 30)], @tagName(d.body), d.id }, 0) catch return;
    d.window().title = std.mem.sliceTo(&d.title, 0);
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
    const made = switch (kind) {
        .script => newScriptDocument(self, null),
        .schema => newSchemaDocument(self, null),
        .tweak => newTweakDocument(self, .tweak),
        else => newDocument(self, kind),
    };
    const doc = made catch |err| {
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
        if (self.focus_when_active == d) self.focus_when_active = null;
        _ = self.documents.orderedRemove(i);
        freeDocument(self, d);
    }
}

// Drawing them

pub fn draw(self: *Workbench, d: *Document) void {
    const w = d.window();
    if (!w.open) return;
    if (w.raise) {
        w.raise = false;
        ui.setNextWindowFocus();
    }
    Workbench.withHost(self);
    if (self.document_dock != 0) c.ImGui_SetNextWindowDockID(self.document_dock, c.ImGuiCond_FirstUseEver);
    var flags = w.flags;
    if (d.body == .schema) {
        const l = &d.body.schema;
        w.unsaved = !l.saved;
        if (l.renamed) {
            l.renamed = false;
            if (l.name()) |n| retitle(d, n);
        }
    }
    if (d.body == .tweak) if (d.body.tweak.renamed) {
        d.body.tweak.renamed = false;
        retitle(d, d.body.tweak.name());
    };
    if (d.body == .script) if (d.body.script.renamed) {
        d.body.script.renamed = false;
        if (d.body.script.projectPath()) |p| retitle(d, std.fs.path.basename(p));
    };
    flags.unsaved_document = w.unsaved;
    const was_open = w.open;
    const shown = ui.window(w.title, .{ .open = &w.open, .flags = flags });
    defer if (shown) |s| s.end();
    // Closing one that isn't saved and has no backup asks first
    if (was_open and !w.open and d.body == .schema and w.unsaved) {
        w.open = true;
        self.project_menu.askClose(d.id);
    }
    _ = shown orelse return;
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
