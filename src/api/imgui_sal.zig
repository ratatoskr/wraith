//! Writes `schemas/imgui.sal` from dear_bindings' `dcimgui.json`, leaving out functions that can't cross.
//! `zig build imgui-sal` runs it after an ImGui update. The output's checked in.

const std = @import("std");
const Value = std.json.Value;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(arena);
    _ = args.skip();
    const json_path = args.next() orelse return error.Usage;
    const out_path = args.next() orelse return error.Usage;
    const text = try std.Io.Dir.cwd().readFileAlloc(io, json_path, arena, .limited(64 << 20));
    const parsed = try std.json.parseFromSliceLeaky(Value, arena, text, .{});
    var out: std.Io.Writer.Allocating = .init(arena);
    try write(arena, parsed, &out.writer);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = out_path, .data = out.written() });
}

const Gen = struct {
    a: std.mem.Allocator,
    w: *std.Io.Writer,
    /// Enums by the typedef that names them, like `ImGuiWindowFlags`.
    enums: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Other typedefs, by what they are.
    typedefs: std.StringHashMapUnmanaged([]const u8) = .empty,
};

pub fn write(a: std.mem.Allocator, root: Value, w: *std.Io.Writer) !void {
    var g: Gen = .{ .a = a, .w = w };
    try w.writeAll(
        \\// Generated from dear_bindings' dcimgui.json by `zig build imgui-sal`. Don't edit it.
        \\//
        \\// Dear ImGui, for drawing in a draw callback. Each function's dcimgui's without `ImGui_`, so
        \\// `ImGui::Button` is `Button`, and its version taking every argument is `ButtonEx`. Calls outside
        \\// a draw callback do nothing.
        \\
        \\namespace Wraith;
        \\
        \\struct ImVec2 { f32 x; f32 y; }
        \\struct ImVec4 { f32 x; f32 y; f32 z; f32 w; }
        \\
    );
    for (root.object.get("typedefs").?.array.items) |t| {
        const name = t.object.get("name").?.string;
        const decl = t.object.get("type").?.object.get("declaration").?.string;
        if (builtin(decl)) |b| try g.typedefs.put(a, name, b);
    }
    for (root.object.get("enums").?.array.items) |e| try enumDef(&g, e);
    try w.writeAll("\ntrait ImGui {\n");
    var skipped: usize = 0;
    for (root.object.get("functions").?.array.items) |f| {
        if (!try function(&g, f, "ImGui_")) skipped += 1;
    }
    try w.writeAll(
        \\}
        \\
        \\// Where ImGui draws shapes and text, from the Ui area. Each function's dcimgui's without
        \\// `ImDrawList_`, so `ImDrawList::AddLine` is `AddLine`.
        \\trait ImDrawList {
        \\
    );
    for (root.object.get("functions").?.array.items) |f| {
        if (!try function(&g, f, "ImDrawList_")) skipped += 1;
    }
    try w.writeAll("}\n");
    std.log.info("left out {d} functions", .{skipped});
}

fn builtin(decl: []const u8) ?[]const u8 {
    const map = [_]struct { []const u8, []const u8 }{
        .{ "int", "i32" },              .{ "unsigned int", "u32" },  .{ "float", "f32" },          .{ "double", "f64" },
        .{ "bool", "bool" },            .{ "short", "i16" },         .{ "unsigned short", "u16" }, .{ "signed char", "i8" },
        .{ "unsigned char", "u8" },     .{ "char", "i8" },           .{ "long long", "i64" },      .{ "unsigned long long", "u64" },
        .{ "signed short", "i16" },     .{ "signed int", "i32" },    .{ "size_t", "usize" },       .{ "ImS8", "i8" },
        .{ "signed long long", "i64" }, .{ "unsigned long", "u32" }, .{ "long", "i32" },
    };
    for (map) |m| if (std.mem.eql(u8, m[0], decl)) return m[1];
    return null;
}

const keywords = [_][]const u8{ "struct", "union", "enum", "bitfield", "error", "opaque", "fn", "trait", "impl", "const", "static", "async", "keep", "inout", "use", "file", "for", "field", "true", "false", "type", "object", "string", "blob", "void" };

fn ident(a: std.mem.Allocator, name: []const u8) ![]const u8 {
    for (keywords) |k| if (std.mem.eql(u8, k, name)) return std.fmt.allocPrint(a, "{s}_", .{name});
    return name;
}

fn enumDef(g: *Gen, e: Value) !void {
    const o = e.object;
    if (isInternal(o)) return;
    const full = o.get("name").?.string;
    // `ImGuiWindowFlags_` is what the typedef `ImGuiWindowFlags` names
    const name = if (std.mem.endsWith(u8, full, "_")) full[0 .. full.len - 1] else full;
    const prefix = try std.fmt.allocPrint(g.a, "{s}_", .{name});
    var seen: std.ArrayList(i64) = .empty;
    var lines: std.ArrayList(u8) = .empty;
    for (o.get("elements").?.array.items) |el| {
        const eo = el.object;
        if (isInternal(eo)) continue;
        if (eo.get("is_count")) |c| if (c.bool) continue;
        const value = eo.get("value").?.integer;
        // Aliases and masks repeat a value, and `.sal` enums can't
        if (std.mem.indexOfScalar(i64, seen.items, value) != null) continue;
        if (value < std.math.minInt(i32) or value > std.math.maxInt(i32)) continue;
        try seen.append(g.a, value);
        var member = eo.get("name").?.string;
        if (std.mem.startsWith(u8, member, prefix)) member = member[prefix.len..];
        if (member.len == 0) continue;
        const shown = if (std.ascii.isDigit(member[0])) try std.fmt.allocPrint(g.a, "_{s}", .{member}) else try ident(g.a, member);
        try lines.print(g.a, "    {s} = {d},\n", .{ shown, value });
    }
    if (seen.items.len == 0) return;
    try g.enums.put(g.a, name, name);
    try g.w.print("\nenum {s} : i32 {{\n{s}}}\n", .{ name, lines.items });
}

const owned_by_overlay = [_][]const u8{ "NewFrame", "EndFrame", "Render", "UpdatePlatformWindows", "RenderPlatformWindowsDefault", "DestroyPlatformWindows", "LoadIniSettings", "SaveIniSettings", "DebugCheckVersionAndDataLayout", "SetCurrentContext", "DestroyContext", "CreateContext" };

fn isInternal(o: std.json.ObjectMap) bool {
    if (o.get("is_internal")) |i| if (i.bool) return true;
    return false;
}

/// A type as `.sal`, or null if it can't cross.
fn typeOf(g: *Gen, decl: []const u8) ?[]const u8 {
    if (builtin(decl)) |b| return b;
    if (std.mem.eql(u8, decl, "const char*")) return "cstring";
    if (std.mem.eql(u8, decl, "ImVec2") or std.mem.eql(u8, decl, "ImVec4")) return decl;
    // images.sal's, laid out the same: a pointer, then an id
    if (std.mem.eql(u8, decl, "ImTextureRef")) return "TextureRef";
    if (g.enums.get(decl)) |e| return e;
    if (g.typedefs.get(decl)) |t| return t;
    return null;
}

/// Whether it went in. Ones with `prefix` that take `self` first are methods, the rest static.
fn function(g: *Gen, f: Value, prefix: []const u8) !bool {
    const o = f.object;
    const name = o.get("name").?.string;
    if (!std.mem.startsWith(u8, name, prefix)) return true;
    if (isInternal(o)) return true;
    if (o.get("is_manual_helper")) |h| if (h.bool) return true;
    const short = name[prefix.len..];
    // Like `ImDrawList__ResetForNewFrame`, which are ImGui's own
    if (short.len == 0 or short[0] == '_') return true;
    // The overlay runs ImGui's frame and settings, so plugins mustn't
    for (owned_by_overlay) |n| if (std.mem.startsWith(u8, short, n)) return true;

    const ret_decl = o.get("return_type").?.object.get("declaration").?.string;
    const ret = if (std.mem.eql(u8, ret_decl, "void")) "void" else typeOf(g, ret_decl) orelse return false;

    var params: std.ArrayList(u8) = .empty;
    var has_this = false;
    var first = true;
    for (o.get("arguments").?.array.items) |arg| {
        const ao = arg.object;
        if (ao.get("is_instance_pointer")) |ip| if (ip.bool) {
            has_this = true;
            continue;
        };
        if (ao.get("is_varargs")) |v| if (v.bool) return false;
        const decl = ao.get("type").?.object.get("declaration").?.string;
        const pname = try ident(g.a, ao.get("name").?.string);
        const nullable = if (ao.get("default_value")) |d| std.mem.eql(u8, d.string, "NULL") else false;
        const ty = blk: {
            if (typeOf(g, decl)) |t| break :blk t;
            // A scalar the callee changes, like `float* v`
            if (std.mem.endsWith(u8, decl, "*") and !std.mem.startsWith(u8, decl, "const ")) {
                const inner = typeOf(g, decl[0 .. decl.len - 1]) orelse return false;
                if (std.mem.eql(u8, inner, "cstring")) return false;
                break :blk try std.fmt.allocPrint(g.a, "inout {s}{s}", .{ if (nullable) "?" else "", inner });
            }
            // Like `float v[3]`
            if (std.mem.indexOfScalar(u8, decl, '[')) |open| {
                const inner = typeOf(g, decl[0..open]) orelse return false;
                break :blk try std.fmt.allocPrint(g.a, "inout {s}{s}", .{ inner, decl[open..] });
            }
            return false;
        };
        if (!first) try params.appendSlice(g.a, ", ");
        first = false;
        try params.print(g.a, "{s} {s}", .{ ty, pname });
    }
    if (o.get("comments")) |c| if (c.object.get("attached")) |att| {
        try g.w.print("    {s}\n", .{std.mem.trim(u8, att.string, " ")});
    };
    // A struct's function without its `self` is something else's
    if (!has_this and !std.mem.eql(u8, prefix, "ImGui_")) return true;
    try g.w.print("    {s}{s} {s}({s});\n", .{ if (has_this) "" else "static ", ret, short, params.items });
    return true;
}
