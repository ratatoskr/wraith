//! Plugins' overlay windows, through `ui.sal`, drawn each frame they're open. Removed ones stay till
//! the plugin goes, so a handle's always safe to call.

const std = @import("std");
const core = @import("wraith_core");
const Atomic = @import("tuft_arch").atomic.Value;

const api = @import("wraith_api");
const ui = @import("wraith_ui");

const host = @import("root.zig");
const frame = @import("frame.zig");
const ui_area = @import("ui_area.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const MenuItems = @import("../ui/MenuItems.zig");

const W = api.wraith;
const gpa = core.heap.main;

pub const Window = struct {
    loaded: *Loaded,
    /// Its ImGui name, unique across plugins
    label: [:0]u8,
    menu_label: []u8,
    menu_under: []u8,
    item: MenuItems.Item = undefined,
    in_menu: bool = false,
    size: ?ui.Vec2,
    min_size: ?ui.Vec2,
    max_size: ?ui.Vec2,
    flags: ui.WindowFlags,
    closable: bool,
    close_on_escape: bool,
    draw: W.Window.Draw,
    subscription: ?frame.Subscription = null,
    /// Shared with its menu entry. Any thread, atomically.
    open: bool = false,
    raise: Atomic(bool) = .init(false),
    unsaved: Atomic(bool) = .init(false),
    stopped: Atomic(bool) = .init(false),
    /// Removed from inside its own draw, so it lets go of `draw` once that's back. Render thread.
    release_after: bool = false,
    warned: bool = false,

    pub fn isOpen(self: *Window) bool {
        return @atomicLoad(bool, &self.open, .acquire);
    }

    pub fn setOpen(self: *Window, open: bool) void {
        @atomicStore(bool, &self.open, open, .release);
    }

    pub fn focus(self: *Window) void {
        self.setOpen(true);
        self.raise.store(true, .release);
    }

    pub fn going(self: *Window) bool {
        return !self.stopped.load(.acquire);
    }

    /// No more draws. Waits for one under way on another thread, but not its own.
    pub fn stop(self: *Window) void {
        if (self.stopped.swap(true, .acq_rel)) return;
        if (self.in_menu) MenuItems.remove(&self.item);
        if (self.subscription) |s| s.unsubscribe();
        if (drawing == self) {
            self.release_after = true;
            return;
        }
        self.draw.release();
    }

    pub fn free(self: *Window) void {
        self.stop();
        gpa.free(self.label);
        gpa.free(self.menu_label);
        gpa.free(self.menu_under);
        gpa.destroy(self);
    }

    fn fire(self: *Window) void {
        if (self.stopped.load(.acquire) or !self.isOpen()) return;
        host.ui.runAs(self.loaded, &self.warned, self, call);
    }

    fn call(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(ctx.?));
        if (self.raise.swap(false, .acq_rel)) {
            ui.setNextWindowCollapsed(false, .always);
            ui.setNextWindowFocus();
        }
        var flags = self.flags;
        flags.unsaved_document = self.unsaved.load(.acquire);
        var open = true;
        const scope = ui.window(self.label, .{
            .open = if (self.closable) &open else null,
            .flags = flags,
            .size = self.size,
            .min_size = self.min_size,
            .max_size = self.max_size,
        }) orelse {
            if (!open) self.setOpen(false);
            return;
        };
        defer scope.end();
        drawing = self;
        self.draw.invoke(.{});
        drawing = null;
        if (self.release_after) {
            self.release_after = false;
            self.draw.release();
        }
        if (!open or (self.close_on_escape and escapePressed())) self.setOpen(false);
    }

    fn openFromSettings(self: *Window) void {
        if (self.going()) self.focus();
    }
};

/// The one whose draw is running on this thread.
threadlocal var drawing: ?*Window = null;

var records: host.Owned(Window) = .{};

/// Unless something inside claimed it with `ui.shortcut`, like a text box.
fn escapePressed() bool {
    if (!ui.getIO().WantCaptureKeyboard) return false;
    return ui.shortcut(.escape);
}

/// ImGui's flags as tuft's, dropping any it doesn't have.
fn flagsOf(raw: W.ImGuiWindowFlags) ui.WindowFlags {
    const bits: c_int = @backingInt(raw);
    var out: ui.WindowFlags = .{};
    inline for (@typeInfo(ui.WindowFlags).@"struct".field_names) |name| {
        const bit = @field(ui.c, "ImGuiWindowFlags_" ++ ui.pascalCase(name));
        @field(out, name) = bits & bit != 0;
    }
    return out;
}

fn sizeOf(v: W.ImVec2) ?ui.Vec2 {
    return if (v.x == 0 and v.y == 0) null else .{ v.x, v.y };
}

/// Through `ui.sal`. Null if the plugin's going or out of memory, with `draw` released.
pub fn add(loaded: *Loaded, options: W.Window.Options, draw: W.Window.Draw) ?*Window {
    const w = make(loaded, options, draw) catch {
        draw.release();
        return null;
    };
    // Before Owned has it, so its `stop` always has the subscription to cancel
    w.subscription = frame.subscribeFrames(w, Window.fire) catch {
        w.stopped.store(true, .release);
        draw.release();
        w.free();
        return null;
    };
    records.add(w) catch {
        w.stop();
        w.free();
        return null;
    };
    // Owned frees it with the plugin from here on, so failing just stops it
    if (options.menu.len > 0) {
        w.item = .{ .label = w.menu_label, .menu = w.menu_under, .open = &w.open };
        MenuItems.add(&loaded.owner, &w.item) catch {
            w.stop();
            return null;
        };
        w.in_menu = true;
    }
    if (options.settings) ui_area.UiImpl.onOpenSettings(loaded, .init(w, Window.openFromSettings));
    return w;
}

fn make(loaded: *Loaded, options: W.Window.Options, draw: W.Window.Draw) !*Window {
    const w = try gpa.create(Window);
    errdefer gpa.destroy(w);
    const name = if (options.title.len > 0) options.title else loaded.displayName();
    // Like a plugin's own `Begin` makes it, so they share a layout
    const identity = if (std.mem.lastIndexOf(u8, name, "###")) |pos| name[pos + 3 ..] else name;
    const title = name[0 .. std.mem.indexOf(u8, name, "##") orelse name.len];
    const label = try std.fmt.allocPrintSentinel(gpa, "{s}###wraith/{s}/{s}", .{ title, loaded.name, identity }, 0);
    errdefer gpa.free(label);
    const menu_label = try gpa.dupe(u8, options.menu);
    errdefer gpa.free(menu_label);
    const menu_under = try gpa.dupe(u8, loaded.displayName());
    w.* = .{
        .loaded = loaded,
        .label = label,
        .menu_label = menu_label,
        .menu_under = menu_under,
        .size = sizeOf(options.size),
        .min_size = sizeOf(options.min_size),
        .max_size = sizeOf(options.max_size),
        .flags = flagsOf(options.flags),
        .closable = !options.no_close,
        .close_on_escape = !options.keep_on_escape,
        .draw = draw,
    };
    return w;
}

pub const Impl = struct {
    pub fn isOpen(w: *Window) bool {
        return w.isOpen();
    }

    pub fn setOpen(w: *Window, open: bool) void {
        w.setOpen(open);
    }

    pub fn focus(w: *Window) void {
        w.focus();
    }

    pub fn setUnsaved(w: *Window, unsaved: bool) void {
        w.unsaved.store(unsaved, .release);
    }

    pub fn remove(w: *Window) void {
        w.stop();
    }
};
