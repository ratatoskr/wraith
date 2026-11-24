//! A tweak's data fields as controls, for the Tweaks window and the workbench. Its list of choices
//! is the struct editor's too.

const std = @import("std");

const ui = @import("wraith_ui");

const Tweaks = @import("../Tweaks.zig");
pub const Choice = @import("wraith_api").tweak.Choice;

/// The shared searchable dropdown, Shift+click types a value in.
pub const choose = ui.choose;

/// Each labeled, for a menu. `width` is unscaled.
pub fn draw(tweaks: *Tweaks, t: *const Tweaks.Info, width: f32) void {
    for (t.fields, 0..) |*f, i| {
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        var buf: [128]u8 = undefined;
        const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{f.label}, 0) catch continue;
        ui.setNextItemWidth(width);
        if (control(f, label)) |v| tweaks.setValue(t.name, f.name, v);
        tip(f);
    }
}

/// What it says over the last control.
pub fn tip(f: *const Tweaks.FieldInfo) void {
    var key_buf: [64]u8 = undefined;
    const key = if (f.key) |k| std.fmt.bufPrint(&key_buf, ". {f} flips it", .{k}) catch "" else "";
    ui.tooltip("{s}{s}{s}", .{ f.name, if (f.live) ", in the game now" else ", for when it's on", key });
}

/// The new value if it changed.
pub fn control(f: *const Tweaks.FieldInfo, label: [:0]const u8) ?f64 {
    if (f.toggle) {
        var on = f.value != 0;
        return if (ui.checkbox(label, &on)) @as(f64, if (on) 1 else 0) else null;
    }
    if (f.choices.len > 0) return choose(label, f.choices, f.value, f.hex);
    const limits: Limits = .{ .min = f.min, .max = f.max, .hex = f.hex };
    if (f.type.isFloat()) return floatInput(label, f.value, limits);
    if (f.type.isSigned()) return if (intInput(i64, label, std.math.lossyCast(i64, f.value), limits)) |v| @floatFromInt(v) else null;
    return if (intInput(u64, label, std.math.lossyCast(u64, f.value), limits)) |v| @floatFromInt(v) else null;
}

/// What a number can be. Both ends make a slider, if they're near enough for one to pick from.
pub const Limits = struct {
    min: ?f64 = null,
    max: ?f64 = null,
    hex: bool = false,
};

/// Ranges wider than this get a number box, not a slider, since a slider's no good for picking one
/// of millions.
const max_slider = 1000;

/// The new value if it changed, kept inside its limits. Tweak fields and the struct editor's.
pub fn intInput(comptime T: type, label: [:0]const u8, value: T, limits: Limits) ?T {
    const fmt: [:0]const u8 = if (limits.hex) "%llX" else if (T == i64) "%lld" else "%llu";
    var v = value;
    const lo: T = if (limits.min) |m| std.math.lossyCast(T, m) else std.math.minInt(T);
    const hi: T = if (limits.max) |m| std.math.lossyCast(T, m) else std.math.maxInt(T);
    if (limits.min != null and limits.max != null and hi -| lo <= max_slider) {
        if (!ui.sliderWith(label, &v, lo, hi, .{ .format = fmt, .clamp = true })) return null;
        return v;
    }
    if (!ui.inputNumber(label, &v, .{ .format = fmt, .step = 1, .step_fast = 100, .hex = limits.hex })) return null;
    return std.math.clamp(v, lo, hi);
}

pub fn floatInput(label: [:0]const u8, value: f64, limits: Limits) ?f64 {
    var v = value;
    if (limits.min != null and limits.max != null) {
        if (!ui.sliderWith(label, &v, limits.min.?, limits.max.?, .{ .format = "%.3f", .clamp = true })) return null;
        return v;
    }
    if (!ui.inputNumber(label, &v, .{ .format = "%.3f" })) return null;
    return std.math.clamp(v, limits.min orelse -std.math.inf(f64), limits.max orelse std.math.inf(f64));
}
