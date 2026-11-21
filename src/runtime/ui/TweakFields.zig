//! A tweak's data fields as controls, for the Tweaks window and the workbench. Its list of choices
//! is the struct editor's too.

const std = @import("std");

const ui = @import("wraith_ui");

const Tweaks = @import("../Tweaks.zig");
pub const Choice = @import("wraith_api").tweak.Choice;

/// More than this many choices get a filter box.
const filter_from = 12;

/// Only one list is open at a time, so they share it.
var filter: [64:0]u8 = @splat(0);

/// The dropdown being typed into instead, after a Shift+click, by its ImGui id. One at a time.
var typing: ui.c.ImGuiID = 0;
var typed: i64 = 0;
/// Frames left for the box to take the keyboard. It goes back to a dropdown if it doesn't.
var settling: u8 = 0;

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
    const data_type = if (T == i64) ui.c.ImGuiDataType_S64 else ui.c.ImGuiDataType_U64;
    const fmt: [:0]const u8 = if (limits.hex) "%llX" else if (T == i64) "%lld" else "%llu";
    var v = value;
    var lo: T = if (limits.min) |m| std.math.lossyCast(T, m) else std.math.minInt(T);
    var hi: T = if (limits.max) |m| std.math.lossyCast(T, m) else std.math.maxInt(T);
    if (limits.min != null and limits.max != null and hi -| lo <= max_slider) {
        if (!ui.raw("ImGui_SliderScalarEx")(ui.str(label), data_type, @ptrCast(&v), @ptrCast(&lo), @ptrCast(&hi), ui.str(fmt), ui.c.ImGuiSliderFlags_AlwaysClamp)) return null;
        return v;
    }
    var step: T = 1;
    var fast: T = 100;
    const flags: ui.c.ImGuiInputTextFlags = if (limits.hex) ui.c.ImGuiInputTextFlags_CharsHexadecimal else 0;
    if (!ui.raw("ImGui_InputScalarEx")(ui.str(label), data_type, @ptrCast(&v), @ptrCast(&step), @ptrCast(&fast), ui.str(fmt), flags)) return null;
    return std.math.clamp(v, lo, hi);
}

pub fn floatInput(label: [:0]const u8, value: f64, limits: Limits) ?f64 {
    var v = value;
    if (limits.min != null and limits.max != null) {
        var lo = limits.min.?;
        var hi = limits.max.?;
        if (!ui.raw("ImGui_SliderScalarEx")(ui.str(label), ui.c.ImGuiDataType_Double, @ptrCast(&v), @ptrCast(&lo), @ptrCast(&hi), ui.str("%.3f"), ui.c.ImGuiSliderFlags_AlwaysClamp)) return null;
        return v;
    }
    if (!ui.raw("ImGui_InputDoubleEx")(ui.str(label), &v, 0, 0, ui.str("%.3f"), 0)) return null;
    return std.math.clamp(v, limits.min orelse -std.math.inf(f64), limits.max orelse std.math.inf(f64));
}

/// Like `Tear Balm (1)`, or the id alone if it's not a choice.
fn choiceText(buf: []u8, hex: bool, value: f64, label: ?[]const u8) [:0]const u8 {
    const id: i64 = std.math.lossyCast(i64, value);
    const l = label orelse return (if (hex) std.fmt.bufPrintSentinel(buf, "0x{X}", .{id}, 0) else std.fmt.bufPrintSentinel(buf, "{d}", .{id}, 0)) catch "";
    return (if (hex) std.fmt.bufPrintSentinel(buf, "{s} (0x{X})", .{ l, id }, 0) else std.fmt.bufPrintSentinel(buf, "{s} ({d})", .{ l, id }, 0)) catch "";
}

/// The number box a Shift+clicked dropdown turns into. Enter or clicking away sets it, Escape
/// doesn't, and either way it's a dropdown again.
fn typeIn(label: [:0]const u8, hex: bool) ?f64 {
    if (settling > 0) ui.raw("ImGui_SetKeyboardFocusHere")();
    const fmt: [:0]const u8 = if (hex) "%llX" else "%lld";
    const flags: ui.c.ImGuiInputTextFlags = if (hex) ui.c.ImGuiInputTextFlags_CharsHexadecimal else 0;
    _ = ui.raw("ImGui_InputScalarEx")(ui.str(label), ui.c.ImGuiDataType_S64, @ptrCast(&typed), null, null, ui.str(fmt), flags);
    if (ui.raw("ImGui_IsItemDeactivatedAfterEdit")()) {
        typing = 0;
        return @floatFromInt(typed);
    }
    if (ui.raw("ImGui_IsItemActive")()) {
        settling = 0;
    } else if (settling > 0) {
        settling -= 1;
    } else typing = 0;
    return null;
}

/// A dropdown of `choices`, with a filter box when there are lots. Shift+click types a value in
/// instead, for one that isn't listed. The one picked if it changed.
pub fn choose(label: [:0]const u8, choices: []const Choice, value: f64, hex: bool) ?f64 {
    const id = ui.raw("ImGui_GetID")(ui.str(label));
    if (typing == id) return typeIn(label, hex);
    var preview_buf: [160]u8 = undefined;
    const current = for (choices) |c| {
        if (c.value == value) break c.label;
    } else null;
    const preview = choiceText(&preview_buf, hex, value, current);
    if (!ui.raw("ImGui_BeginCombo")(ui.str(label), ui.str(preview), ui.c.ImGuiComboFlags_HeightLarge)) return null;
    defer ui.raw("ImGui_EndCombo")();
    if (ui.getIO().KeyShift and ui.raw("ImGui_IsWindowAppearing")()) {
        ui.raw("ImGui_CloseCurrentPopup")();
        typing = id;
        typed = std.math.lossyCast(i64, value);
        settling = 2;
        return null;
    }
    if (choices.len == 0) {
        ui.textDisabled("Nothing to pick yet", .{});
        return null;
    }
    const searching = choices.len > filter_from;
    if (searching) {
        if (ui.raw("ImGui_IsWindowAppearing")()) {
            filter[0] = 0;
            ui.raw("ImGui_SetKeyboardFocusHere")();
        }
        ui.setNextItemWidth(ui.fill);
        _ = ui.inputTextHint("##filter", "Search names or ids", &filter);
    }
    const needle = std.mem.trim(u8, std.mem.sliceTo(&filter, 0), " ");
    var picked: ?f64 = null;
    for (choices, 0..) |c, i| {
        var buf: [192]u8 = undefined;
        const text = choiceText(&buf, hex, c.value, c.label);
        if (searching and needle.len > 0 and std.ascii.findIgnoreCase(text, needle) == null) continue;
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        const selected = c.value == value;
        if (ui.selectable(text, selected)) picked = c.value;
        if (selected and ui.raw("ImGui_IsWindowAppearing")()) ui.raw("ImGui_SetItemDefaultFocus")();
    }
    return picked;
}
