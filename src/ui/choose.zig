//! A dropdown of choices with a filter box when there are lots, and Shift+click to type a value
//! that isn't listed. Tweak fields, the struct editor and plugins share it.

const std = @import("std");

const ui = @import("root.zig");

/// More than this many choices get a filter box.
const filter_from = 12;

/// Only one list is open at a time, so they share it.
var filter: [64:0]u8 = @splat(0);

/// The dropdown being typed into instead, after a Shift+click, by its ImGui id. One at a time.
var typing: ui.c.ImGuiID = 0;
var typed: i64 = 0;
/// Frames left for the box to take the keyboard. It goes back to a dropdown if it doesn't.
var settling: u8 = 0;

/// Like `Tear Balm (1)`, or the id alone if it's not a choice.
pub fn choiceText(buf: []u8, hex: bool, value: f64, label: ?[]const u8) [:0]const u8 {
    const id: i64 = std.math.lossyCast(i64, value);
    const l = label orelse return (if (hex) std.fmt.bufPrintSentinel(buf, "0x{X}", .{id}, 0) else std.fmt.bufPrintSentinel(buf, "{d}", .{id}, 0)) catch "";
    return (if (hex) std.fmt.bufPrintSentinel(buf, "{s} (0x{X})", .{ l, id }, 0) else std.fmt.bufPrintSentinel(buf, "{s} ({d})", .{ l, id }, 0)) catch "";
}

/// The number box a Shift+clicked dropdown turns into. Enter or clicking away sets it, Escape
/// doesn't, and either way it's a dropdown again.
fn typeIn(label: [:0]const u8, hex: bool) ?f64 {
    if (settling > 0) ui.focusNext();
    const fmt: [:0]const u8 = if (hex) "%llX" else "%lld";
    _ = ui.inputNumber(label, &typed, .{ .format = fmt, .hex = hex });
    if (ui.isItemDeactivatedAfterEdit()) {
        typing = 0;
        return @floatFromInt(typed);
    }
    if (ui.isItemActive()) {
        settling = 0;
    } else if (settling > 0) {
        settling -= 1;
    } else typing = 0;
    return null;
}

/// `choices` is a slice of anything with `value: f64` and `label: []const u8`, shown like
/// `Van (1)`. The one picked if it changed.
pub fn choose(label: [:0]const u8, choices: anytype, value: f64, hex: bool) ?f64 {
    const id = ui.getId(label);
    if (typing == id) return typeIn(label, hex);
    var preview_buf: [160]u8 = undefined;
    const current = for (choices) |c| {
        if (c.value == value) break c.label;
    } else null;
    const preview = choiceText(&preview_buf, hex, value, current);
    const combo = ui.comboBegin(label, preview, .{ .large = true }) orelse return null;
    defer combo.end();
    if (ui.getIO().KeyShift and ui.isWindowAppearing()) {
        ui.closePopup();
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
        if (ui.isWindowAppearing()) {
            filter[0] = 0;
            ui.focusNext();
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
        if (selected and ui.isWindowAppearing()) ui.setItemDefaultFocus();
    }
    return picked;
}
