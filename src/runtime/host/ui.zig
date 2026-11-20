//! UI service. Plugins draw into the overlay's ImGui frame.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const tuft_sys = @import("tuft_sys");
const api = @import("wraith_api");

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const Owner = @import("tuft_event").Owner;
const sync = tuft_sys.sync;
const Overlay = @import("../ui/Overlay.zig");
const imgui = @import("../ui/imgui.zig");
const ui = @import("wraith_ui");
const c = imgui.c;

const log = core.log.scoped(.wraith_ui);

var overlay: ?*Overlay = null;

pub fn setOverlay(o: ?*Overlay) void {
    overlay = o;
}

pub fn isAvailable(_: *Loaded) bool {
    return overlay != null;
}

/// Runs a plugin's frame callback in the current ImGui frame, scoped to the plugin, with what it
/// leaves open unwound after. Without an ImGui context, like in tests, it just calls it. Render thread.
pub fn runAs(loaded: *Loaded, warned: *bool, ctx: *anyopaque, func: *const fn (ctx: ?*anyopaque) callconv(.c) void) void {
    if (c.ImGui_GetCurrentContext() == null) return func(ctx);
    drawing = loaded;
    defer drawing = null;
    in_frame = true;
    defer in_frame = false;
    const name = loaded.name;
    c.ImGui_PushIDStr(@ptrCast(name.ptr), @ptrCast(name.ptr + name.len));
    const balanced = imgui.guarded(func, ctx);
    c.ImGui_PopID();
    if (!balanced and !warned.*) {
        log.warn("Plugin {s} left ImGui unbalanced (a missing End, PopID, ...?); unwound after its frame", .{name});
        warned.* = true;
    }
}
pub fn imguiVersion() u32 {
    return c.IMGUI_VERSION_NUM;
}

pub fn getProc(name: []const u8) ?*const anyopaque {
    if (by_name_window_procs.get(name)) |wrapper| return wrapper;
    return imgui.lookup(name);
}

/// Render thread only.
var drawing: ?*Loaded = null;

/// Set while a plugin draws, so ImGui calls from anywhere else do nothing.
threadlocal var in_frame: bool = false;

pub fn inFrame() bool {
    return in_frame;
}

/// What `ImGui_<name>` is for plugins: dcimgui's, or one scoping window names to the plugin.
pub fn imguiFunction(comptime name: []const u8) *const anyopaque {
    const scopes = .{
        .{ "Begin", &scoped.begin },
        .{ "SetWindowPosStr", &scoped.setPos },
        .{ "SetWindowSizeStr", &scoped.setSize },
        .{ "SetWindowCollapsedStr", &scoped.setCollapsed },
        .{ "SetWindowFocusStr", &scoped.setFocus },
    };
    inline for (scopes) |e| if (comptime std.mem.eql(u8, e[0], name)) return @ptrCast(e[1]);
    return @ptrCast(&@field(c, "ImGui_" ++ name));
}

/// ImGui finds top-level windows by name alone, so these scope them per plugin.
const by_name_window_procs = std.StaticStringMap(*const anyopaque).initComptime(.{
    .{ "ImGui_Begin", @as(*const anyopaque, @ptrCast(&scoped.begin)) },
    .{ "ImGui_SetWindowPosStr", @as(*const anyopaque, @ptrCast(&scoped.setPos)) },
    .{ "ImGui_SetWindowSizeStr", @as(*const anyopaque, @ptrCast(&scoped.setSize)) },
    .{ "ImGui_SetWindowCollapsedStr", @as(*const anyopaque, @ptrCast(&scoped.setCollapsed)) },
    .{ "ImGui_SetWindowFocusStr", @as(*const anyopaque, @ptrCast(&scoped.setFocus)) },
});

/// ImGui copies the name, so the scoped one only has to outlive the call.
const scoped = struct {
    const Name = [*c]const u8;

    fn begin(name: Name, open: [*c]bool, flags: c.ImGuiWindowFlags) callconv(.c) bool {
        var buf: [window_name_max]u8 = undefined;
        return c.ImGui_Begin(scopedWindowName(&buf, name), open, flags);
    }

    fn setPos(name: Name, pos: c.ImVec2, cond: c.ImGuiCond) callconv(.c) void {
        var buf: [window_name_max]u8 = undefined;
        c.ImGui_SetWindowPosStr(scopedWindowName(&buf, name), pos, cond);
    }

    fn setSize(name: Name, size: c.ImVec2, cond: c.ImGuiCond) callconv(.c) void {
        var buf: [window_name_max]u8 = undefined;
        c.ImGui_SetWindowSizeStr(scopedWindowName(&buf, name), size, cond);
    }

    fn setCollapsed(name: Name, collapsed: bool, cond: c.ImGuiCond) callconv(.c) void {
        var buf: [window_name_max]u8 = undefined;
        c.ImGui_SetWindowCollapsedStr(scopedWindowName(&buf, name), collapsed, cond);
    }

    fn setFocus(name: Name) callconv(.c) void {
        var buf: [window_name_max]u8 = undefined;
        c.ImGui_SetWindowFocusStr(scopedWindowName(&buf, name));
    }
};

comptime {
    std.debug.assert(@TypeOf(scoped.begin) == @TypeOf(c.ImGui_Begin));
    std.debug.assert(@TypeOf(scoped.setPos) == @TypeOf(c.ImGui_SetWindowPosStr));
    std.debug.assert(@TypeOf(scoped.setSize) == @TypeOf(c.ImGui_SetWindowSizeStr));
    std.debug.assert(@TypeOf(scoped.setCollapsed) == @TypeOf(c.ImGui_SetWindowCollapsedStr));
    std.debug.assert(@TypeOf(scoped.setFocus) == @TypeOf(c.ImGui_SetWindowFocusStr));
}

const window_name_max = 256;

fn scopedWindowName(buf: *[window_name_max]u8, name: [*c]const u8) [*c]const u8 {
    const loaded = drawing orelse return name;
    if (name == null) return name;
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(name)));
    return @ptrCast(windowName(buf, loaded.name, s).ptr);
}

/// `"Stats"` becomes `"Stats###wraith/<namespace>/Stats"`, keeping the title.
fn windowName(buf: []u8, namespace: []const u8, name: []const u8) [:0]const u8 {
    const identity = if (std.mem.lastIndexOf(u8, name, "###")) |pos| name[pos + 3 ..] else name;
    const title = name[0 .. std.mem.indexOf(u8, name, "##") orelse name.len];
    if (std.fmt.bufPrintSentinel(buf, "{s}###wraith/{s}/{s}", .{ title, namespace, identity }, 0)) |full| return full else |_| {}

    var id_buf: [64]u8 = undefined;
    const hashed = std.fmt.bufPrint(&id_buf, "###wraith/{x}", .{std.hash.Wyhash.hash(0, namespace) ^ std.hash.Wyhash.hash(1, identity)}) catch unreachable;
    const shown = title[0..@min(title.len, buf.len - hashed.len - 1)];
    @memcpy(buf[0..shown.len], shown);
    @memcpy(buf[shown.len..][0..hashed.len], hashed);
    buf[shown.len + hashed.len] = 0;
    return buf[0 .. shown.len + hashed.len :0];
}

pub fn inputTaken(_: *Loaded, device: api.InputDevice) bool {
    const o = overlay orelse return false;
    return o.taken(deviceOf(device));
}

fn deviceOf(device: api.InputDevice) Overlay.Device {
    return switch (device) {
        inline else => |d| @field(Overlay.Device, @tagName(d)),
    };
}

var hint_owner: Atomic(?*Loaded) = .init(null);

pub fn setCursorHint(loaded: *Loaded, hint: api.CursorHint) void {
    const o = overlay orelse return;
    const lease = requests.lease(&loaded.owner) orelse return;
    defer lease.end();
    _ = Requests.of(loaded) orelse return;
    hint_owner.store(loaded, .release);
    o.setCursorHint(switch (hint) {
        .visible => .visible,
        .hidden => .hidden,
        .auto => .auto,
    });
}

pub fn showCursor(loaded: *Loaded, show: bool) void {
    const o = overlay orelse return;
    const lease = requests.lease(&loaded.owner) orelse return;
    defer lease.end();
    const r = Requests.of(loaded) orelse return;
    if (r.shows_cursor.swap(show, .acq_rel) != show) o.requestCursor(show);
}

pub fn takeInput(loaded: *Loaded, device: api.InputDevice, take: bool) void {
    const o = overlay orelse return;
    const lease = requests.lease(&loaded.owner) orelse return;
    defer lease.end();
    const r = Requests.of(loaded) orelse return;
    if (r.takes.getPtr(device).swap(take, .acq_rel) != take) o.take(deviceOf(device), take);
}

pub fn toast(loaded: *Loaded, t: api.Toast) api.ToastId {
    const o = overlay orelse return 0;
    return o.host.toasts.push(toTuft(loaded, t));
}

pub fn toastUpdate(loaded: *Loaded, id: api.ToastId, t: api.Toast) bool {
    const o = overlay orelse return false;
    return o.host.toasts.update(id, toTuft(loaded, t));
}

pub fn toastDismiss(_: *Loaded, id: api.ToastId) void {
    const o = overlay orelse return;
    o.host.toasts.dismiss(id);
}

pub fn frameStats(_: *Loaded) api.FrameStats {
    const o = overlay orelse return .{};
    return o.frames.stats();
}

pub fn frameTimes(_: *Loaded, out: []f32) usize {
    const o = overlay orelse return 0;
    return o.frames.times(out).len;
}

fn toTuft(loaded: *Loaded, t: api.Toast) ui.Toasts.Toast {
    return .{
        .kind = switch (t.kind) {
            inline else => |k| @field(ui.Toasts.Kind, @tagName(k)),
        },
        .title = if (t.title.len > 0) t.title else loaded.name,
        .text = t.text,
        .seconds = t.seconds,
    };
}

/// No handle, so it's dropped when the plugin closes.
const Requests = struct {
    loaded: *Loaded,
    shows_cursor: Atomic(bool) = .init(false),
    takes: std.EnumArray(api.InputDevice, Atomic(bool)) = .initFill(.init(false)),

    fn of(loaded: *Loaded) ?*Requests {
        creating.lock();
        defer creating.unlock();
        if (requests.first(&loaded.owner)) |r| return r;
        const r = loaded.allocator.create(Requests) catch return null;
        r.* = .{ .loaded = loaded };
        requests.addLeased(r) catch {
            loaded.allocator.destroy(r);
            return null;
        };
        return r;
    }

    pub fn stop(self: *Requests) void {
        if (hint_owner.cmpxchgStrong(self.loaded, null, .acq_rel, .acquire) == null) {
            if (overlay) |o| o.setCursorHint(.auto);
        }
        if (self.shows_cursor.swap(false, .acq_rel)) {
            if (overlay) |o| o.requestCursor(false);
        }
        for (std.enums.values(api.InputDevice)) |device| {
            if (self.takes.getPtr(device).swap(false, .acq_rel)) {
                if (overlay) |o| o.take(deviceOf(device), false);
            }
        }
    }

    pub fn free(self: *Requests) void {
        self.loaded.allocator.destroy(self);
    }
};

var requests: host.Owned(Requests) = .{};
var creating: sync.RwLock = .{};

const tests = struct {
    const testing = std.testing;

    test "scoped window names" {
        var a: [256]u8 = undefined;
        var b: [256]u8 = undefined;
        const first = windowName(&a, "first", "Stats");
        try std.testing.expectEqualStrings("Stats###wraith/first/Stats", first);
        try std.testing.expect(!std.mem.eql(u8, first, windowName(&b, "second", "Stats")));
        try std.testing.expectEqualStrings("Stats###wraith/first/Stats##details", windowName(&a, "first", "Stats##details"));
        try std.testing.expectEqualStrings("FPS 60###wraith/first/stats", windowName(&a, "first", "FPS 60###stats"));

        // Too long, still scoped by hash
        const long: [300]u8 = @splat('W');
        var small: [64]u8 = undefined;
        const cut = windowName(&small, "first", &long);
        try std.testing.expect(std.mem.indexOf(u8, cut, "###wraith/") != null);
        try std.testing.expect(cut.len < small.len);
        const cut_first = try std.testing.allocator.dupe(u8, cut);
        defer std.testing.allocator.free(cut_first);
        try std.testing.expect(!std.mem.eql(u8, cut_first, windowName(&small, "second", &long)));
    }

    /// A different ID means the ID or window stack wasn't reset for a fresh draw.
    const Probe = struct {
        id: c.ImGuiID = 0,

        fn draw(self: *Probe) void {
            self.id = c.ImGui_GetID(ui.str("probe"));
        }
    };

    fn heapAllocs(owner: []const u8) ?u64 {
        var out: [64]core.heap.Stats = undefined;
        for (out[0..core.heap.registry.snapshot(&out)]) |s| {
            if (std.mem.eql(u8, s.ownerName(), owner) and std.mem.eql(u8, s.name(), "heap")) return s.allocs;
        }
        return null;
    }

    fn drawsOf(loaded: *const Loaded) !u32 {
        return counterOf(loaded, "wraith_drawing_draws");
    }

    fn counterOf(loaded: *const Loaded, name: []const u8) !u32 {
        const addr = tuft_sys.module.findExport(loaded.library(), name) orelse return error.ExportNotFound;
        const f: *const fn () callconv(.c) u32 = @ptrFromInt(addr);
        return f();
    }

    test "toasts show in the overlay under the plugin's name" {
        var loaded: Loaded = undefined;
        loaded.name = "kai";
        try testing.expectEqualStrings("kai", toTuft(&loaded, .{}).title);
        try testing.expectEqualStrings("Gold", toTuft(&loaded, .{ .title = "Gold" }).title);
        try testing.expectEqual(.@"error", toTuft(&loaded, .{ .kind = .@"error" }).kind);
        try testing.expectEqual(0, toast(&loaded, .{}));

        var rig: @import("../testing/Rig.zig") = undefined;
        try rig.init(.{});
        defer rig.deinit();
        setOverlay(rig.overlay);
        defer setOverlay(null);
        const id = toast(&loaded, .{ .kind = .warning, .text = "Low gold", .seconds = 0 });
        try testing.expect(id != 0);
        for (0..3) |_| rig.present();
        try testing.expectEqual(1, rig.overlay.host.toasts.count());
        try testing.expect(toastUpdate(&loaded, id, .{ .text = "Gold's fine" }));
        toastDismiss(&loaded, id);
        try testing.expect(!toastUpdate(&loaded, id + 1, .{}));
    }

    test "script plugins draw with ImGui in their frames, and nowhere else" {
        var rig: @import("../testing/Rig.zig") = undefined;
        try rig.init(.{});
        defer rig.deinit();
        setOverlay(rig.overlay);
        defer setOverlay(null);
        try rig.runPluginFrames();
        host.wraith.setIo(testing.io);
        defer host.wraith.setIo(null);

        var install: @import("../testing/Install.zig") = undefined;
        try install.init(.{});
        defer install.deinit();
        const io = testing.io;
        const files = [_]struct { []const u8, []const u8, []const u8, []const u8 }{
            .{
                "imgui_js", "js", "main.js",
                \\import { frame, imgui, ui, log } from "wraith";
                \\// Outside a frame it does nothing
                \\if (imgui.Begin("Early", null, 0) !== false) throw new Error("drew outside a frame");
                \\if (ui.windowDrawList() !== null) throw new Error("a draw list outside a frame");
                \\const item = ui.addMenuItem("Stats", false);
                \\item.setOpen(true);
                \\const settings = ui.addMenuItem("Settings", true);
                \\ui.onOpenSettings(() => settings.setOpen(true));
                \\const open = { value: true };
                \\const speed = { value: 1.5 };
                \\let name = "bob";
                \\let toasted = false;
                \\frame.onFrame(() => {
                \\    if (!item.isOpen()) return;
                \\    if (imgui.Begin("Stats", open, 0)) {
                \\        imgui.TextUnformatted("hello");
                \\        imgui.SliderFloat("speed", speed, 0, 10);
                \\        if (imgui.ButtonEx("Go", { x: 50, y: 20 })) log.info("go");
                \\        name = ui.inputText("name", name, 0);
                \\        ui.windowDrawList().AddLine({ x: 0, y: 0 }, { x: 10, y: 10 }, 0xffffffff);
                \\        if (!toasted) toasted = ui.toast({ kind: "info", title: "", text: name, seconds: 0 }) !== 0;
                \\    }
                \\    imgui.End();
                \\});
            },
            .{
                "imgui_lua", "lua", "main.lua",
                \\local wraith = require("wraith")
                \\local imgui = wraith.imgui
                \\local on = { value = false }
                \\wraith.ui:onOpenSettings(function() on.value = true end)
                \\wraith.frame:onFrame(function()
                \\    if imgui:Begin("Panel", nil, 0) then
                \\        imgui:Checkbox("on", on)
                \\        imgui:TextUnformatted("hi")
                \\        wraith.ui:foregroundDrawList():AddCircle({ x = 5, y = 5 }, 3, 0xff00ff00)
                \\    end
                \\    imgui:End()
                \\end)
            },
        };
        for (files) |f| {
            try install.addScript(f[0], f[1]);
            const path = try std.fmt.allocPrint(testing.allocator, "plugins/{s}/{s}", .{ f[0], f[2] });
            defer testing.allocator.free(path);
            try install.tmp.dir.writeFile(io, .{ .sub_path = path, .data = f[3] });
        }
        _ = core.log.mute(&.{ .ui, .plugin, .runtime });
        const loader = &install.loader;
        try loader.start(&.{});
        try testing.expectEqual(.loaded, install.info("imgui_js").?.state);
        try testing.expectEqual(.loaded, install.info("imgui_lua").?.state);
        for (0..3) |_| rig.present();
        const layout = std.mem.span(@as([*:0]const u8, @ptrCast(c.ImGui_SaveIniSettingsToMemory(null))));
        // Scoped to each plugin, like a native plugin's
        try testing.expect(std.mem.indexOf(u8, layout, "[Window][wraith/imgui_js/Stats]") != null);
        try testing.expect(std.mem.indexOf(u8, layout, "[Window][wraith/imgui_lua/Panel]") != null);
        try testing.expect(std.mem.indexOf(u8, layout, "Early") == null);
        try testing.expectEqual(1, rig.overlay.host.toasts.count());

        // The Mods page's Settings button, and items under the plugin's own menu
        const ui_area = @import("ui_area.zig");
        const MenuItems = @import("../ui/MenuItems.zig");
        try testing.expect(ui_area.hasSettings("imgui_js") and ui_area.hasSettings("imgui_lua"));
        try testing.expect(!ui_area.hasSettings("nobody"));
        try testing.expect(ui_area.openSettings("imgui_js"));
        try testing.expect(ui_area.openSettings("imgui_lua"));
        {
            const items = MenuItems.read();
            defer items.end();
            const found = for (items.entries) |e| {
                if (std.mem.eql(u8, e.item.label, "Settings")) break e.item;
            } else return error.TestUnexpectedResult;
            try testing.expect(found.open.*);
            try testing.expect(found.dev);
            try testing.expectEqualStrings("imgui_js", found.menu);
        }
        try (try loader.unload("imgui_js")).wait();
        try testing.expect(!ui_area.hasSettings("imgui_js"));
        try testing.expect(!ui_area.openSettings("imgui_js"));
    }

    test "plugin frames draw into the overlay" {
        const options = @import("test_options");

        var rig: @import("../testing/Rig.zig") = undefined;
        try rig.init(.{});
        defer rig.deinit();
        // The plugin's imbalance is on purpose and gets logged
        _ = core.log.mute(&.{ .ui, .plugin, .runtime });

        // Runs after every plugin's frame
        var probe: Probe = .{};
        try rig.overlay.update.subscribeOpts(&rig.scope, &probe, Probe.draw, .{ .priority = -1 });
        rig.present();
        const clean_id = probe.id;

        setOverlay(rig.overlay);
        defer setOverlay(null);
        try rig.runPluginFrames();

        var install: @import("../testing/Install.zig") = undefined;
        try install.init(.{ .plugins = &.{.{ "drawing", options.drawing_plugin }} });
        defer install.deinit();
        const loader = &install.loader;
        try (try loader.load("drawing")).wait();
        try testing.expect(heapAllocs("drawing").? > 0);
        const loaded = loader.find("drawing").?;
        try testing.expectEqual(.visible, rig.overlay.cursor_hint.load(.acquire));
        try testing.expectEqual(1, rig.overlay.cursor_requests.load(.acquire)); // per plugin
        for (std.enums.values(Overlay.Device)) |device| try testing.expectEqual(1, rig.overlay.takes.getPtrConst(device).load(.acquire));

        for (0..3) |_| rig.present();
        try testing.expectEqual(3, try drawsOf(loaded));
        // Its task started on the first frame and drew on the next two
        try testing.expectEqual(2, try counterOf(loaded, "wraith_drawing_task_frames"));
        try testing.expectEqual(clean_id, probe.id);
        const layout = std.mem.span(@as([*:0]const u8, @ptrCast(c.ImGui_SaveIniSettingsToMemory(null))));
        try testing.expect(std.mem.indexOf(u8, layout, "[Window][wraith/drawing/drawing]") != null);
        try testing.expect(std.mem.indexOf(u8, layout, "[Window][wraith/drawing/panel]") != null);
        try testing.expect(std.mem.indexOf(u8, layout, "[Window][wraith/drawing/task]") != null);

        try (try loader.unload("drawing")).wait();
        try testing.expectEqual(null, heapAllocs("drawing"));
        rig.present();
        try testing.expectEqual(clean_id, probe.id);
        try testing.expectEqual(.auto, rig.overlay.cursor_hint.load(.acquire));
        try testing.expectEqual(0, rig.overlay.cursor_requests.load(.acquire));
        for (std.enums.values(Overlay.Device)) |device| try testing.expectEqual(0, rig.overlay.takes.getPtrConst(device).load(.acquire));
    }
};

test {
    _ = tests;
}
