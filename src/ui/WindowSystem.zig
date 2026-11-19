//! Windows that open and close, for the runtime and plugins.

const WindowSystem = @This();

const std = @import("std");

const ui = @import("root.zig");
const c = ui.c;

pub const Window = struct {
    /// Also the ID, so keep it unique in the system.
    title: [:0]const u8,
    flags: ui.WindowFlags = .{},
    /// Size on first show. Unscaled.
    size: ?ui.Vec2 = null,
    min_size: ?ui.Vec2 = null,
    /// 0 means no limit in that direction.
    max_size: ?ui.Vec2 = null,
    closable: bool = true,
    close_on_escape: bool = true,
    open: bool = false,
    was_open: bool = false,
    /// Uncollapses it and selects its tab if docked.
    raise: bool = false,
    /// Shows a dot in its title or tab.
    unsaved: bool = false,

    pub fn show(self: *Window) void {
        self.open = true;
    }

    pub fn focus(self: *Window) void {
        self.open = true;
        self.raise = true;
    }

    pub fn close(self: *Window) void {
        self.open = false;
    }

    pub fn toggle(self: *Window) void {
        self.open = !self.open;
    }

    pub fn label(self: *const Window) []const u8 {
        return self.title[0 .. std.mem.indexOf(u8, self.title, "##") orelse self.title.len];
    }
};

pub const Entry = struct {
    window: *Window,
    owner: *anyopaque,
    draw: *const fn (owner: *anyopaque) void,
    on_open: *const fn (owner: *anyopaque) void,
    on_close: *const fn (owner: *anyopaque) void,
};

allocator: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,
before_each: ?Hook = null,

pub const Hook = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque) void,
};

pub fn init(allocator: std.mem.Allocator) WindowSystem {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *WindowSystem) void {
    self.entries.deinit(self.allocator);
    self.* = undefined;
}

/// `owner` can't move until removed. Don't call from `draw`.
pub fn add(self: *WindowSystem, owner: anytype) !void {
    const P = @TypeOf(owner);
    if (@typeInfo(P) != .pointer) @compileError("WindowSystem.add expects a pointer, found " ++ @typeName(P));
    const T = @typeInfo(P).pointer.child;
    if (!@hasField(T, "window") or @FieldType(T, "window") != Window) @compileError(@typeName(T) ++ " needs a `window: ui.Window` field");
    if (!@hasDecl(T, "draw")) @compileError(@typeName(T) ++ " needs `pub fn draw(self: *" ++ @typeName(T) ++ ") void`");

    const Thunks = struct {
        fn cast(raw: *anyopaque) *T {
            return @ptrCast(@alignCast(raw));
        }
        fn draw(raw: *anyopaque) void {
            T.draw(cast(raw));
        }
        fn onOpen(raw: *anyopaque) void {
            if (@hasDecl(T, "onOpen")) T.onOpen(cast(raw));
        }
        fn onClose(raw: *anyopaque) void {
            if (@hasDecl(T, "onClose")) T.onClose(cast(raw));
        }
    };
    try self.entries.append(self.allocator, .{
        .window = &owner.window,
        .owner = owner,
        .draw = Thunks.draw,
        .on_open = Thunks.onOpen,
        .on_close = Thunks.onClose,
    });
}

/// Don't call from `draw`.
pub fn remove(self: *WindowSystem, owner: anytype) void {
    for (self.entries.items, 0..) |e, i| {
        if (e.window == &owner.window) {
            _ = self.entries.orderedRemove(i);
            return;
        }
    }
}

pub fn windows(self: *const WindowSystem) []const Entry {
    return self.entries.items;
}

pub fn closeAll(self: *WindowSystem) void {
    for (self.entries.items) |e| e.window.close();
}

pub fn draw(self: *WindowSystem) void {
    for (self.entries.items) |e| self.drawOne(e);
}

fn drawOne(self: *WindowSystem, e: Entry) void {
    const w = e.window;
    sync(e);
    if (!w.open) return;

    if (w.raise) {
        w.raise = false;
        ui.setNextWindowCollapsed(false, .always);
        ui.setNextWindowFocus();
    }
    if (self.before_each) |h| h.func(h.ctx);
    var flags = w.flags;
    flags.unsaved_document = w.unsaved;
    if (ui.window(w.title, .{
        .open = if (w.closable) &w.open else null,
        .flags = flags,
        .size = w.size,
        .min_size = w.min_size,
        .max_size = w.max_size,
    })) |scope| {
        defer scope.end();
        e.draw(e.owner);
        if (w.close_on_escape and escapePressed()) w.open = false;
    }
    sync(e); // catches closes from this frame
}

fn sync(e: Entry) void {
    const w = e.window;
    if (w.open == w.was_open) return;
    w.was_open = w.open;
    if (w.open) e.on_open(e.owner) else e.on_close(e.owner);
}

/// Unless something inside claimed it with `ui.shortcut`, like a text field.
fn escapePressed() bool {
    if (!ui.getIO().WantCaptureKeyboard) return false;
    return ui.shortcut(.escape);
}

test "label drops ID" {
    const w: Window = .{ .title = "Settings##kai" };
    try std.testing.expectEqualStrings("Settings", w.label());
    const plain: Window = .{ .title = "Stats" };
    try std.testing.expectEqualStrings("Stats", plain.label());
}
