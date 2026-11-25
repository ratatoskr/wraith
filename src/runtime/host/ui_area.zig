//! The `Ui` area, from `ui.sal`, and the `ImDrawList` objects it gives. ImGui itself is the `ImGui`
//! area, a table that calls dcimgui's functions straight, see `wraith.zig`.

const std = @import("std");

const api = @import("wraith_api");
const sync = @import("tuft_sys").sync;
const tuft_window = @import("tuft_window");
const Atomic = @import("tuft_arch").atomic.Value;

const host = @import("root.zig");
const wraith = @import("wraith.zig");
const threads = @import("threads.zig");
const imgui = @import("../ui/imgui.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const MenuItems = @import("../ui/MenuItems.zig");
const Gizmos = @import("../ui/Gizmos.zig");
const StructEditor = @import("../ui/StructEditor.zig");
const struct_tweaks = @import("struct_tweaks.zig");

const c = imgui.c;
const sal = api.salamander;
const W = api.wraith;
pub const Ui = W.Ui;
pub const MenuItem = W.MenuItem;
pub const Window = W.Window;
pub const Gizmo = W.Gizmo;
pub const WorkbenchPanel = W.WorkbenchPanel;
pub const DrawList = W.ImDrawList;

/// Every draw list function calls dcimgui's with the list as `self`, only while the plugin's drawing.
pub const draw_list_table = sal.forwarding(DrawList, struct {
    pub fn allowed() bool {
        return host.ui.inFrame();
    }

    pub fn function(comptime name: []const u8) *const anyopaque {
        return @ptrCast(&@field(c, "ImDrawList_" ++ name));
    }
});

/// What a plugin's UI keeps between frames.
pub const State = struct {
    /// Text boxes being typed in, by label. Render thread.
    inputs: std.StringHashMapUnmanaged(*Input) = .empty,
    /// The same, for its Workbench panels. Workbench thread.
    workbench_inputs: std.StringHashMapUnmanaged(*Input) = .empty,
    lock: sync.RwLock = .{},
    menus: std.ArrayList(*Menu) = .empty,
    gizmos: std.ArrayList(*Gizmos.Gizmo) = .empty,

    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        for (self.gizmos.items) |g| Gizmos.destroy(g);
        self.gizmos.deinit(gpa);
        inline for (.{ &self.inputs, &self.workbench_inputs }) |inputs| {
            var it = inputs.iterator();
            while (it.next()) |e| {
                a.free(e.key_ptr.*);
                a.free(e.value_ptr.*.buf);
                a.destroy(e.value_ptr.*);
            }
            inputs.deinit(a);
        }
        for (self.menus.items) |m| {
            if (!m.removed) MenuItems.remove(&m.item);
            a.free(m.label);
            a.free(m.menu);
            a.destroy(m);
        }
        self.menus.deinit(a);
    }
};

const Input = struct {
    /// Zero-terminated within.
    buf: []u8,
    /// Typed in last frame, so its edit stays.
    active: bool = false,
};

pub const Menu = struct {
    loaded: *Loaded,
    label: []u8,
    menu: []u8,
    open: bool = false,
    removed: bool = false,
    item: MenuItems.Item,
};

fn stateOf(loaded: *Loaded) ?*State {
    const t = wraith.tablesOf(loaded) orelse return null;
    return &t.ui;
}

const gpa = std.heap.page_allocator;

const FilePromise = sal.Plain(Ui, "pickFile");
const FolderPromise = sal.Plain(Ui, "pickFolder");
comptime {
    // Both give a path or null, so one resolver type does for both
    std.debug.assert(FilePromise == FolderPromise);
}

/// A file or folder dialog on a thread of its own, since it blocks till it's closed. It only enters
/// the plugin's owner to hand back the path, so unloading doesn't wait for someone to close it.
const Dialog = struct {
    arena: std.heap.ArenaAllocator,
    owner: *sal.Owner,
    what: union(enum) {
        file: struct { resolver: threads.Back(wraith.ResolverOf(FilePromise)), options: tuft_window.FileDialog },
        folder: struct { resolver: threads.Back(wraith.ResolverOf(FilePromise)), options: tuft_window.FolderDialog },
    },

    fn start(comptime kind: enum { file, folder }, loaded: *Loaded, options: anytype) FilePromise {
        const pair = FilePromise.make() catch return .{};
        const t = wraith.tablesOf(loaded) orelse {
            pair.resolver.drop();
            return pair.promise;
        };
        const d = gpa.create(Dialog) catch {
            pair.resolver.fail(error.Failed);
            return pair.promise;
        };
        d.* = .{ .arena = .init(gpa), .owner = t.owner, .what = undefined };
        // The plugin's strings are only borrowed for the call
        const a = d.arena.allocator();
        const window = host.ui.gameWindow();
        // Over the game, not owned by it, which would tie the dialog to the game's message loop
        const over: ?tuft_window.Handle = if (window != 0) @ptrFromInt(window) else null;
        const copied = copy: {
            const title = a.dupe(u8, options.title) catch break :copy false;
            const folder = a.dupe(u8, options.folder) catch break :copy false;
            if (kind == .file) {
                d.what = .{ .file = .{ .resolver = .of(pair.resolver), .options = .{
                    .mode = if (options.save) .save else .open,
                    .over = over,
                    .title = title,
                    .folder = folder,
                    .file_name = a.dupe(u8, options.file_name) catch break :copy false,
                    .kind = a.dupe(u8, options.kind) catch break :copy false,
                    .extension = a.dupe(u8, options.extension) catch break :copy false,
                } } };
            } else {
                d.what = .{ .folder = .{ .resolver = .of(pair.resolver), .options = .{ .over = over, .title = title, .folder = folder } } };
            }
            break :copy true;
        };
        const thread = if (copied) std.Thread.spawn(.{}, run, .{d}) catch null else null;
        if (thread) |th| th.detach() else {
            d.arena.deinit();
            gpa.destroy(d);
            pair.resolver.fail(error.Failed);
        }
        return pair.promise;
    }

    fn run(d: *Dialog) void {
        defer {
            d.arena.deinit();
            gpa.destroy(d);
        }
        switch (d.what) {
            inline else => |w, tag| {
                const picked = switch (tag) {
                    .file => tuft_window.pickFile(gpa, w.options),
                    .folder => tuft_window.pickFolder(gpa, w.options),
                };
                const path = picked catch null;
                defer if (path) |p| gpa.free(p);
                if (!d.owner.enter()) return w.resolver.drop();
                defer d.owner.leave();
                _ = picked catch return w.resolver.fail(error.Failed);
                const got = path orelse return w.resolver.settle(null);
                w.resolver.settle(w.resolver.hold(got) catch return w.resolver.fail(error.Failed));
            },
        }
    }
};

pub const UiImpl = struct {
    pub fn available(loaded: *Loaded) bool {
        return host.ui.isAvailable(loaded);
    }

    pub fn displaySize(_: *Loaded) W.ImVec2 {
        if (!host.ui.inFrame()) return .{};
        const size = c.ImGui_GetIO().*.DisplaySize;
        return .{ .x = size.x, .y = size.y };
    }

    pub fn windowDrawList(loaded: *Loaded) ?sal.Object(DrawList) {
        return drawList(loaded, c.ImGui_GetWindowDrawList);
    }

    pub fn foregroundDrawList(loaded: *Loaded) ?sal.Object(DrawList) {
        return drawList(loaded, c.ImGui_GetForegroundDrawList);
    }

    pub fn backgroundDrawList(loaded: *Loaded) ?sal.Object(DrawList) {
        return drawList(loaded, c.ImGui_GetBackgroundDrawList);
    }

    pub fn inputText(loaded: *Loaded, label: ?[*:0]const u8, text: []const u8, flags: W.ImGuiInputTextFlags) []const u8 {
        return textBox(loaded, label, text, @backingInt(flags), null);
    }

    pub fn inputMultiline(loaded: *Loaded, label: ?[*:0]const u8, text: []const u8, size: W.ImVec2, flags: W.ImGuiInputTextFlags) []const u8 {
        return textBox(loaded, label, text, @backingInt(flags), .{ .x = size.x, .y = size.y });
    }

    pub fn editStruct(loaded: *Loaded, type_name: []const u8, address: usize) bool {
        if (!host.ui.inFrame()) return false;
        const s = loaded.schemas orelse return false;
        const schema = &s.parsed.schema;
        if (schema.findType(type_name) == null) return false;
        const at = if (address != 0) address else StructEditor.instanceOf(schema, type_name) orelse return false;
        return StructEditor.draw(schema, type_name, at);
    }

    pub fn copyableText(_: *Loaded, id: ?[*:0]const u8, text: []const u8) void {
        if (!host.ui.inFrame()) return;
        const key = id orelse return;
        c.ImGui_PushID(cs(key));
        defer c.ImGui_PopID();
        c.ImGui_TextUnformattedEx(cs(text.ptr), cs(text.ptr + text.len));
        c.ImGui_SameLine();
        if (c.ImGui_SmallButton(cs("Copy"))) {
            var buf: [4096:0]u8 = undefined;
            const n = @min(text.len, buf.len);
            @memcpy(buf[0..n], text[0..n]);
            buf[n] = 0;
            c.ImGui_SetClipboardText(cs(&buf));
        }
    }

    pub fn clip(_: *Loaded, count: u32, row: W.Ui.ClipRow) void {
        if (!host.ui.inFrame()) return;
        var clipper = std.mem.zeroes(c.ImGuiListClipper);
        c.ImGuiListClipper_Begin(&clipper, @intCast(count), -1);
        defer c.ImGuiListClipper_End(&clipper);
        while (c.ImGuiListClipper_Step(&clipper)) {
            var i = clipper.DisplayStart;
            while (i < clipper.DisplayEnd) : (i += 1) row.invoke(.{@as(u32, @intCast(i))});
        }
    }

    pub fn tableSortedBy(_: *Loaded) ?W.Ui.SortSpec {
        if (!host.ui.inFrame()) return null;
        const specs = c.ImGui_TableGetSortSpecs() orelse return null;
        if (specs.*.SpecsCount == 0) return null;
        specs.*.SpecsDirty = false;
        const first = specs.*.Specs[0];
        return .{ .column = first.ColumnIndex, .descending = first.SortDirection == c.ImGuiSortDirection_Descending };
    }

    pub fn toast(loaded: *Loaded, t: W.Toast) u32 {
        return host.ui.toast(loaded, toastOf(t));
    }

    pub fn updateToast(loaded: *Loaded, id: u32, t: W.Toast) bool {
        return host.ui.toastUpdate(loaded, id, toastOf(t));
    }

    pub fn dismissToast(loaded: *Loaded, id: u32) void {
        host.ui.toastDismiss(loaded, id);
    }

    pub fn showCursor(loaded: *Loaded, show: bool) void {
        host.ui.showCursor(loaded, show);
    }

    pub fn setCursorHint(loaded: *Loaded, hint: W.Ui.CursorHint) void {
        host.ui.setCursorHint(loaded, switch (hint) {
            .visible => .visible,
            .hidden => .hidden,
            else => .auto,
        });
    }

    pub fn setMouseFree(loaded: *Loaded, free: bool) void {
        host.ui.setMouseFree(loaded, free);
    }

    pub fn takeInput(loaded: *Loaded, device: W.Ui.InputDevice, take: bool) void {
        host.ui.takeInput(loaded, deviceOf(device) orelse return, take);
    }

    pub fn inputTaken(loaded: *Loaded, device: W.Ui.InputDevice) bool {
        return host.ui.inputTaken(loaded, deviceOf(device) orelse return false);
    }

    pub fn holdMouse(loaded: *Loaded, hold: bool) void {
        host.ui.holdMouse(loaded, hold);
    }

    pub fn mouseMotion(_: *Loaded) W.Point {
        const p = host.ui.mouseMotion();
        return .{ .x = p.x, .y = p.y };
    }

    pub fn addGizmo(loaded: *Loaded) sal.Object(Gizmo) {
        const t = wraith.tablesOf(loaded) orelse return .{};
        const g = Gizmos.create() catch return .{};
        t.ui.lock.lock();
        defer t.ui.lock.unlock();
        t.ui.gizmos.append(gpa, g) catch {
            Gizmos.destroy(g);
            return .{};
        };
        return .init(g, t.gizmo);
    }

    pub fn imguiProc(_: *Loaded, name: []const u8) usize {
        return @intFromPtr(host.ui.getProc(name));
    }

    pub fn imguiVersion(_: *Loaded) u32 {
        return host.ui.imguiVersion();
    }

    pub fn pickFile(loaded: *Loaded, options: W.Ui.FileDialog) FilePromise {
        return Dialog.start(.file, loaded, options);
    }

    pub fn pickFolder(loaded: *Loaded, options: W.Ui.FolderDialog) FolderPromise {
        return Dialog.start(.folder, loaded, options);
    }

    pub fn addWindow(loaded: *Loaded, options: W.Window.Options, draw: W.Window.Draw) sal.Object(Window) {
        const t = wraith.tablesOf(loaded) orelse {
            draw.release();
            return .{};
        };
        const w = host.windows.add(loaded, options, draw) orelse return .{};
        return .init(w, t.window);
    }

    pub fn addMenuItem(loaded: *Loaded, label: []const u8) sal.Object(MenuItem) {
        const t = wraith.tablesOf(loaded) orelse return .{};
        const m = gpa.create(Menu) catch return .{};
        const copy = gpa.dupe(u8, label) catch {
            gpa.destroy(m);
            return .{};
        };
        const menu = gpa.dupe(u8, loaded.displayName()) catch {
            gpa.free(copy);
            gpa.destroy(m);
            return .{};
        };
        m.* = .{ .loaded = loaded, .label = copy, .menu = menu, .item = undefined };
        m.item = .{ .label = copy, .menu = menu, .open = &m.open };
        {
            t.ui.lock.lock();
            defer t.ui.lock.unlock();
            t.ui.menus.append(gpa, m) catch {
                gpa.free(copy);
                gpa.free(menu);
                gpa.destroy(m);
                return .{};
            };
        }
        MenuItems.add(&loaded.owner, &m.item) catch {
            m.removed = true;
            return .{};
        };
        return .init(m, t.menu_item);
    }

    pub fn onOpenSettings(loaded: *Loaded, open: W.Ui.OpenSettings) void {
        const held = settings_handlers.lease(&loaded.owner) orelse return open.release();
        defer held.end();
        // The last one wins. The old one's kept till the plugin goes, in case it's being called
        while (settings_handlers.findWhere(&loaded.owner, {}, isCurrent)) |old| old.replaced.store(true, .release);
        const h = loaded.allocator.create(SettingsHandler) catch return open.release();
        h.* = .{ .loaded = loaded, .open = open };
        settings_handlers.addLeased(h) catch {
            loaded.allocator.destroy(h);
            open.release();
        };
    }

    pub fn addWorkbenchPanel(loaded: *Loaded, options: W.WorkbenchPanel.Options, draw: W.WorkbenchPanel.Draw) sal.Object(WorkbenchPanel) {
        const t = wraith.tablesOf(loaded) orelse {
            draw.release();
            return .{};
        };
        const p = host.workbench_panels.add(loaded, options, draw) orelse return .{};
        return .init(p, t.workbench_panel);
    }

    pub fn showClass(_: *Loaded, class_name: []const u8) void {
        host.workbench_panels.showClass(class_name);
    }
};

pub const WorkbenchPanelImpl = struct {
    const Panel = host.workbench_panels.Panel;

    pub fn isOpen(p: *Panel) bool {
        return p.shown.load(.acquire);
    }

    pub fn focus(p: *Panel) void {
        p.focus_wanted.store(true, .release);
    }

    pub fn remove(p: *Panel) void {
        p.stop();
    }
};

/// A plugin's Settings button in the Mods window and under its button on the bar.
const SettingsHandler = struct {
    loaded: *Loaded,
    open: W.Ui.OpenSettings,
    replaced: Atomic(bool) = .init(false),
    released: bool = false,

    pub fn going(self: *SettingsHandler) bool {
        return !self.replaced.load(.acquire);
    }

    pub fn stop(self: *SettingsHandler) void {
        if (self.released) return;
        self.released = true;
        self.open.release();
    }

    pub fn free(self: *SettingsHandler) void {
        self.stop();
        self.loaded.allocator.destroy(self);
    }

    fn call(self: *SettingsHandler) void {
        self.open.invoke(.{});
    }
};

var settings_handlers: host.Owned(SettingsHandler) = .{};

fn isCurrent(h: *SettingsHandler, _: void) bool {
    return h.going();
}

fn isPlugin(h: *SettingsHandler, name: []const u8) bool {
    return std.mem.eql(u8, h.loaded.name, name);
}

/// Whether the plugin called `name` has a Settings button.
pub fn hasSettings(name: []const u8) bool {
    return settings_handlers.findAny(name, struct {
        fn match(h: *SettingsHandler, n: []const u8) bool {
            return isPlugin(h, n) and h.going();
        }
    }.match) != null;
}

/// What its Settings button does. Render thread, in a frame. False if it has none.
pub fn openSettings(name: []const u8) bool {
    return settings_handlers.callAny(name, isPlugin, SettingsHandler.call);
}

pub const MenuItemImpl = struct {
    pub fn isOpen(m: *Menu) bool {
        return @atomicLoad(bool, &m.open, .acquire);
    }

    pub fn setOpen(m: *Menu, open: bool) void {
        @atomicStore(bool, &m.open, open, .release);
    }

    pub fn remove(m: *Menu) void {
        if (@atomicRmw(bool, &m.removed, .Xchg, true, .acq_rel)) return;
        MenuItems.remove(&m.item);
    }
};

/// Freed with the plugin, so a removed one's still safe to call.
pub const GizmoImpl = struct {
    const G = Gizmos.Gizmo;

    pub fn show(g: *G) void {
        g.show();
    }

    pub fn hide(g: *G) void {
        g.hide();
    }

    pub fn place(g: *G, world: W.Mat4) void {
        g.place(world);
    }

    pub fn setTool(g: *G, tool: W.Gizmo.Tool) void {
        g.setTool(switch (tool) {
            .rotate => .rotate,
            .scale => .scale,
            else => .move,
        });
    }

    pub fn setWorldAxes(g: *G, on: bool) void {
        g.setWorldAxes(on);
    }

    pub fn moved(g: *G) ?W.Mat4 {
        return g.takeMoved();
    }

    pub fn dragging(g: *G) bool {
        return g.isDragging();
    }

    pub fn hovered(g: *G) bool {
        return g.isHovered();
    }

    pub fn remove(g: *G) void {
        g.remove();
    }
};

fn cs(p: [*]const u8) [*c]const u8 {
    return @ptrCast(p);
}

fn drawList(loaded: *Loaded, comptime get: anytype) ?sal.Object(DrawList) {
    if (!host.ui.inFrame()) return null;
    const t = wraith.tablesOf(loaded) orelse return null;
    const list = get() orelse return null;
    return .init(list, t.draw_list);
}

fn deviceOf(d: W.Ui.InputDevice) ?api.InputDevice {
    return switch (d) {
        .keyboard => .keyboard,
        .mouse => .mouse,
        .gamepad => .gamepad,
        else => null,
    };
}

fn toastOf(t: W.Toast) api.Toast {
    return .{
        .kind = switch (t.style) {
            .success => .success,
            .warning => .warning,
            .failure => .@"error",
            else => .info,
        },
        .title = t.title,
        .text = t.text,
        .seconds = t.seconds,
    };
}

/// Edited in place while it's typed in, so the box keeps the edit until it's left.
fn textBox(loaded: *Loaded, label: ?[*:0]const u8, text: []const u8, flags: i32, size: ?c.ImVec2) []const u8 {
    if (!host.ui.inFrame()) return text;
    const state = stateOf(loaded) orelse return text;
    const z = label orelse return text;
    const key = std.mem.span(z);
    // The Workbench's thread has its own, so a panel and the overlay never share one
    const inputs = if (host.ui.inWorkbench()) &state.workbench_inputs else &state.inputs;
    const entry = inputs.getOrPut(gpa, key) catch return text;
    if (!entry.found_existing) {
        entry.key_ptr.* = gpa.dupe(u8, key) catch {
            _ = inputs.remove(key);
            return text;
        };
        const made = gpa.create(Input) catch {
            const owned = entry.key_ptr.*;
            _ = inputs.remove(key);
            gpa.free(owned);
            return text;
        };
        made.* = .{ .buf = &.{} };
        entry.value_ptr.* = made;
    }
    const input = entry.value_ptr.*;
    if (!input.active) {
        const want = @max(256, text.len + 256);
        if (input.buf.len < want) {
            const grown = gpa.alloc(u8, want) catch return text;
            gpa.free(input.buf);
            input.buf = grown;
        }
        @memcpy(input.buf[0..text.len], text);
        input.buf[text.len] = 0;
    }
    const buf: [*c]u8 = @ptrCast(input.buf.ptr);
    _ = if (size) |s|
        c.ImGui_InputTextMultilineEx(cs(z), buf, input.buf.len, s, flags, null, null)
    else
        c.ImGui_InputTextEx(cs(z), buf, input.buf.len, flags, null, null);
    input.active = c.ImGui_IsItemActive();
    return std.mem.sliceTo(input.buf, 0);
}
