//! Just enough markdown for the notices Wraith ships. Headings, tables, links, code fences and
//! paragraphs. Every other line draws as it is, wrapped, so plain text like a license reads fine
//! too. Render thread.

const std = @import("std");

const ui = @import("wraith_ui");

const c = ui.c;

/// Called with a link's URL when it's clicked. The URL lives as long as the text.
pub const Open = *const fn (url: []const u8) void;

/// Unscaled.
const title_size = 22;
const max_line = 2048;

pub fn draw(text: []const u8, open: Open) void {
    ui.raw("ImGui_PushTextWrapPos")(0);
    defer ui.raw("ImGui_PopTextWrapPos")();
    var lines = std.mem.splitScalar(u8, text, '\n');
    var index: i32 = 0;
    var in_code = false;
    while (lines.next()) |raw_line| : (index += 1) {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const scope = ui.id(index);
        defer scope.end();
        if (std.mem.startsWith(u8, line, "```")) {
            in_code = !in_code;
            if (in_code) ui.indent(12) else ui.unindent(12);
            continue;
        }
        if (in_code) {
            if (line.len == 0) ui.spacing() else plain(line);
        } else if (line.len == 0) {
            ui.spacing();
        } else if (std.mem.startsWith(u8, line, "# ")) {
            title(line[2..]);
        } else if (std.mem.startsWith(u8, line, "## ")) {
            heading(line[3..]);
        } else if (line[0] == '|') {
            // The whole table, with the lines it takes
            var rows: [64][]const u8 = undefined;
            var n: usize = 0;
            rows[n] = line;
            n += 1;
            while (lines.peek()) |next| {
                const row = std.mem.trimEnd(u8, next, "\r");
                if (row.len == 0 or row[0] != '|' or n == rows.len) break;
                rows[n] = row;
                n += 1;
                _ = lines.next();
                index += 1;
            }
            table(rows[0..n], open);
        } else if (isUrl(line)) {
            link(line, line, open);
        } else {
            inlineText(line);
        }
    }
    if (in_code) ui.unindent(12);
}

fn title(text: []const u8) void {
    const bold = ui.bold();
    defer bold.end();
    ui.raw("ImGui_PushFontFloat")(null, title_size);
    defer ui.raw("ImGui_PopFont")();
    plain(text);
}

fn heading(text: []const u8) void {
    ui.spacing();
    ui.spacing();
    {
        const bold = ui.bold();
        defer bold.end();
        plain(text);
    }
    ui.separator();
}

/// Header row first, then `|---|`, then the rows.
fn table(rows: []const []const u8, open: Open) void {
    var header: [8][]const u8 = undefined;
    const columns = cells(rows[0], &header);
    if (columns == 0) return;
    const t = ui.table("##table", @intCast(columns), .{ .borders = true, .row_background = true, .sizing = .stretch_prop }) orelse return;
    defer t.end();
    for (header[0..columns]) |h| {
        var buf: [128]u8 = undefined;
        ui.tableColumnWith(std.fmt.bufPrintSentinel(&buf, "{s}", .{h}, 0) catch "", .{ .stretch = true, .width = 1 });
    }
    ui.tableHeaders();
    for (rows[1..], 0..) |row, r| {
        if (std.mem.startsWith(u8, row, "|-") or std.mem.startsWith(u8, row, "| -")) continue;
        const scope = ui.id(@as(i32, @intCast(r)));
        defer scope.end();
        var row_cells: [8][]const u8 = undefined;
        const n = cells(row, &row_cells);
        ui.tableNextRow();
        for (row_cells[0..@min(n, columns)]) |cell| {
            _ = ui.tableNextColumn();
            if (wholeLink(cell)) |l| link(l.text, l.url, open) else inlineText(cell);
        }
    }
}

/// `| a | b |` to `a` and `b`.
fn cells(row: []const u8, out: [][]const u8) usize {
    const inner = std.mem.trim(u8, row, " |");
    var it = std.mem.splitScalar(u8, inner, '|');
    var n: usize = 0;
    while (it.next()) |cell| {
        if (n == out.len) break;
        out[n] = std.mem.trim(u8, cell, " ");
        n += 1;
    }
    return n;
}

const Link = struct { text: []const u8, url: []const u8 };

/// A cell that's just `[text](url)`.
fn wholeLink(text: []const u8) ?Link {
    if (text.len < 4 or text[0] != '[' or text[text.len - 1] != ')') return null;
    const mid = std.mem.indexOf(u8, text, "](") orelse return null;
    return .{ .text = text[1..mid], .url = text[mid + 2 .. text.len - 1] };
}

fn isUrl(line: []const u8) bool {
    return (std.mem.startsWith(u8, line, "https://") or std.mem.startsWith(u8, line, "http://")) and
        std.mem.indexOfScalar(u8, line, ' ') == null;
}

fn link(text: []const u8, url: []const u8, open: Open) void {
    var buf: [256]u8 = undefined;
    const label = std.fmt.bufPrintSentinel(&buf, "{s}", .{text}, 0) catch return;
    if (ui.raw("ImGui_TextLink")(@ptrCast(label.ptr))) open(url);
    ui.tooltip("{s}", .{url});
}

/// Links show as their text, with `**` and backticks dropped.
fn inlineText(line: []const u8) void {
    var buf: [max_line]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (n == buf.len) return plain(line);
        if (line[i] == '[') if (std.mem.indexOfPos(u8, line, i, "](")) |mid| if (std.mem.indexOfScalarPos(u8, line, mid, ')')) |end| {
            const text = line[i + 1 .. mid];
            if (n + text.len > buf.len) return plain(line);
            @memcpy(buf[n..][0..text.len], text);
            n += text.len;
            i = end + 1;
            continue;
        };
        if (std.mem.startsWith(u8, line[i..], "**")) {
            i += 2;
            continue;
        }
        if (line[i] == '`') {
            i += 1;
            continue;
        }
        buf[n] = line[i];
        n += 1;
        i += 1;
    }
    plain(buf[0..n]);
}

fn plain(text: []const u8) void {
    ui.raw("ImGui_TextUnformattedEx")(@ptrCast(text.ptr), @ptrCast(text.ptr + text.len));
}

test "cells and links" {
    var out: [8][]const u8 = undefined;
    const n = cells("| [Lua](https://www.lua.org) | MIT | runs Lua plugins |", &out);
    try std.testing.expectEqual(3, n);
    const l = wholeLink(out[0]).?;
    try std.testing.expectEqualStrings("Lua", l.text);
    try std.testing.expectEqualStrings("https://www.lua.org", l.url);
    try std.testing.expectEqualStrings("runs Lua plugins", out[2]);
    try std.testing.expect(wholeLink("MIT") == null);
    try std.testing.expect(isUrl("https://github.com/ratatoskr/zshim"));
    try std.testing.expect(!isUrl("see https://x.y for more"));
}
