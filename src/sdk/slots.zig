//! Parts of Wraith's own slots, like Photo mode's and Settings, from a struct the plugin keeps and a
//! function drawing it. Other slots, plugins' own too, take an object of their trait through
//! `ui().contributeTo`.
//!
//!     lens: sdk.slots.PhotoPart = .{ .info = .{ .id = "lens", .kind = "camera", .title = "Lens", .presentation = .foldout } },
//!
//!     self.lens_part = try sdk.slots.addPhotoPart("photo.inspector", &self.lens, self, drawLens);

const std = @import("std");

const api = @import("wraith_api");
const rt = @import("salamander_runtime");

const Owner = @import("Owner.zig");

const W = api.wraith;

pub const Error = error{ OwnerGone, Failed };

/// A part of Photo mode, kept by the plugin while it's in a slot.
pub const PhotoPart = struct {
    info: W.PhotoPart.Info,
    ctx: *anyopaque = undefined,
    drawFn: *const fn (ctx: *anyopaque, target: W.Slot.Target) void = undefined,

    pub fn describe(self: *PhotoPart) W.PhotoPart.Info {
        return self.info;
    }

    pub fn draw(self: *PhotoPart, target: W.Slot.Target) void {
        self.drawFn(self.ctx, target);
    }
};

/// `part` in one of Photo mode's slots, like `photo.inspector`, drawn by `draw(target, what)` on the
/// render thread. `part` and `target` have to outlive it.
pub fn addPhotoPart(slot: []const u8, part: *PhotoPart, target: anytype, comptime draw: fn (@TypeOf(target), W.Slot.Target) void) Error!W.Contribution {
    const T = @TypeOf(target);
    part.ctx = @ptrCast(@constCast(target));
    part.drawFn = struct {
        fn call(ctx: *anyopaque, what: W.Slot.Target) void {
            draw(@as(T, @ptrCast(@alignCast(ctx))), what);
        }
    }.call;
    return contribute(slot, W.PhotoPart.init(part, rt.implement(W.PhotoPart, PhotoPart)));
}

/// A part of the plugin's Settings page, kept by the plugin while it's there.
pub const SettingsSection = struct {
    info: W.SettingsSection.Info,
    ctx: *anyopaque = undefined,
    drawFn: *const fn (ctx: *anyopaque) void = undefined,

    pub fn describe(self: *SettingsSection) W.SettingsSection.Info {
        return self.info;
    }

    pub fn draw(self: *SettingsSection) void {
        self.drawFn(self.ctx);
    }
};

/// `section` on the plugin's Settings page, drawn by `draw(target)` on the render thread. `section`
/// and `target` have to outlive it.
pub fn addSettingsSection(section: *SettingsSection, target: anytype, comptime draw: fn (@TypeOf(target)) void) Error!W.Contribution {
    const T = @TypeOf(target);
    section.ctx = @ptrCast(@constCast(target));
    section.drawFn = struct {
        fn call(ctx: *anyopaque) void {
            draw(@as(T, @ptrCast(@alignCast(ctx))));
        }
    }.call;
    return contribute("settings", W.SettingsSection.init(section, rt.implement(W.SettingsSection, SettingsSection)));
}

fn contribute(slot: []const u8, obj: anytype) Error!W.Contribution {
    const owner = Owner.current() orelse return error.OwnerGone;
    return owner.root.ui().contributeTo(slot, .of(obj)) catch error.Failed;
}
