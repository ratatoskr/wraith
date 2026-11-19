//! A tweak's data fields as controls, for the Tweaks menu and the workbench.

const std = @import("std");

const ui = @import("wraith_ui");

const Tweaks = @import("../Tweaks.zig");

/// More than this many choices get a filter box.
const filter_from = 12;

/// Only one list is open at a time, so they share it.
var filter: [64:0]u8 = @splat(0);

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
    if (f.choices.len > 0) return choose(f, label);
    if (f.type.isFloat()) return float(f, label);
    return if (f.type.isSigned()) int(i64, f, label) else int(u64, f, label);
}

fn float(f: *const Tweaks.FieldInfo, label: [:0]const u8) ?f64 {
    var v = f.value;
    const changed = if (f.min != null and f.max != null) blk: {
        var lo = f.min.?;
        var hi = f.max.?;
        break :blk ui.raw("ImGui_SliderScalarEx")(ui.str(label), ui.c.ImGuiDataType_Double, @ptrCast(&v), @ptrCast(&lo), @ptrCast(&hi), ui.str("%.3f"), 0);
    } else ui.raw("ImGui_InputDoubleEx")(ui.str(label), &v, 0, 0, ui.str("%.3f"), 0);
    return if (changed) v else null;
}

fn int(comptime T: type, f: *const Tweaks.FieldInfo, label: [:0]const u8) ?f64 {
    const data_type = if (T == i64) ui.c.ImGuiDataType_S64 else ui.c.ImGuiDataType_U64;
    var v: T = std.math.lossyCast(T, f.value);
    const fmt: [:0]const u8 = if (f.hex) "%llX" else if (T == i64) "%lld" else "%llu";
    const changed = if (f.min != null and f.max != null) blk: {
        var lo: T = std.math.lossyCast(T, f.min.?);
        var hi: T = std.math.lossyCast(T, f.max.?);
        break :blk ui.raw("ImGui_SliderScalarEx")(ui.str(label), data_type, @ptrCast(&v), @ptrCast(&lo), @ptrCast(&hi), ui.str(fmt), 0);
    } else blk: {
        var step: T = 1;
        const flags: ui.c.ImGuiInputTextFlags = if (f.hex) ui.c.ImGuiInputTextFlags_CharsHexadecimal else 0;
        break :blk ui.raw("ImGui_InputScalarEx")(ui.str(label), data_type, @ptrCast(&v), @ptrCast(&step), null, ui.str(fmt), flags);
    };
    return if (changed) @floatFromInt(v) else null;
}

/// Like `Tear Balm (1)`, or the id alone if it's not a choice.
fn choiceText(buf: []u8, f: *const Tweaks.FieldInfo, value: f64, label: ?[]const u8) [:0]const u8 {
    const id: i64 = std.math.lossyCast(i64, value);
    const l = label orelse return (if (f.hex) std.fmt.bufPrintSentinel(buf, "0x{X}", .{id}, 0) else std.fmt.bufPrintSentinel(buf, "{d}", .{id}, 0)) catch "";
    return (if (f.hex) std.fmt.bufPrintSentinel(buf, "{s} (0x{X})", .{ l, id }, 0) else std.fmt.bufPrintSentinel(buf, "{s} ({d})", .{ l, id }, 0)) catch "";
}

fn choose(f: *const Tweaks.FieldInfo, label: [:0]const u8) ?f64 {
    var preview_buf: [160]u8 = undefined;
    const current = for (f.choices) |c| {
        if (c.value == f.value) break c.label;
    } else null;
    const preview = choiceText(&preview_buf, f, f.value, current);
    if (!ui.raw("ImGui_BeginCombo")(ui.str(label), ui.str(preview), ui.c.ImGuiComboFlags_HeightLarge)) return null;
    defer ui.raw("ImGui_EndCombo")();
    const searching = f.choices.len > filter_from;
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
    for (f.choices, 0..) |c, i| {
        var buf: [192]u8 = undefined;
        const text = choiceText(&buf, f, c.value, c.label);
        if (searching and needle.len > 0 and std.ascii.findIgnoreCase(text, needle) == null) continue;
        const scope = ui.id(@as(i32, @intCast(i)));
        defer scope.end();
        const selected = c.value == f.value;
        if (ui.selectable(text, selected)) picked = c.value;
        if (selected and ui.raw("ImGui_IsWindowAppearing")()) ui.raw("ImGui_SetItemDefaultFocus")();
    }
    return picked;
}
