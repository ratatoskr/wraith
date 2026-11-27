//! LuaLS annotations for a Lua plugin, like the JavaScript typings, with a `.luarc.json` pointing at them.

const std = @import("std");
const types = @import("salamander_types");

const core = @import("wraith_core");

const ops = @import("../ops.zig");
const Project = @import("project.zig");
const Made = @import("output.zig").Made;

const log = core.log.scoped(.wraith_cli);

pub const default_out = ".wraith/types";

pub fn generate(p: *Project) ![]const Made {
    var all = try p.all();
    defer all.deinit();
    var w: std.Io.Writer.Allocating = .init(p.arena);
    try types.luals.globals(&w.writer, all.schema, all.source, try p.services(all), @import("js.zig").module);
    const wraith_lua = w.written();
    w = .init(p.arena);
    try types.luals.builtins(&w.writer);
    return p.arena.dupe(Made, &.{
        .{ .name = "wraith.lua", .text = wraith_lua },
        .{ .name = "wraith_hooks.lua", .text = hooks },
        .{ .name = "salamander.lua", .text = w.written() },
    });
}

/// A `.luarc.json` so LuaLS finds them, unless it has one.
pub fn after(ctx: ops.Context, arena: std.mem.Allocator, out: []const u8) !void {
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, ".luarc.json", .{})) |_| return else |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    }
    try cwd.writeFile(io, .{ .sub_path = ".luarc.json", .data = try luarc(arena, out) });
    log.printLn(".luarc.json", .{});
}

/// LuaLS settings for wraith's Lua: the annotations, and none of the libraries it leaves out.
fn luarc(arena: std.mem.Allocator, out: []const u8) ![]const u8 {
    var text: std.Io.Writer.Allocating = .init(arena);
    const w = &text.writer;
    try w.writeAll("{\n  \"$schema\": \"https://raw.githubusercontent.com/LuaLS/vscode-lua/master/setting/schema.json\",\n");
    try w.writeAll("  \"runtime.version\": \"Lua 5.5\",\n  \"runtime.builtin\": { \"io\": \"disable\" },\n");
    try w.writeAll("  \"workspace.library\": [");
    try std.json.Stringify.value(out, .{}, w);
    // Just a library, not more files to check
    try w.writeAll("],\n  \"workspace.ignoreDir\": [");
    try std.json.Stringify.value(out, .{}, w);
    try w.writeAll("]\n}\n");
    return text.written();
}

const hooks =
    \\---@meta
    \\-- Made by wraith sdk lua types. Don't change it, since it's made again. Run that again after
    \\-- updating Wraith or when schemas change, so your editor's types match.
    \\
    \\---What a typed hook's handler gets for a parameter named `hook`.
    \\---@class Wraith.TypedHook
    \\---@field context integer What its options said
    \\local typed = {}
    \\
    \\---The function as it was, to call on.
    \\---@return function
    \\function typed.original() end
    \\
    \\function typed.enable() end
    \\
    \\function typed.disable() end
    \\
    \\function typed.destroy() end
    \\
    \\---@class Wraith.Hooks
    \\local hooks = {}
    \\
    \\---Hooks a function the schemas declare, like `GameStateManager.spendMira`. The handler gets its
    \\---arguments, and a parameter named `hook` or `context` gets that instead.
    \\---@param target function
    \\---@param handler function
    \\---@param options? Wraith.Hook.Options
    \\---@return Wraith.Hook
    \\function hooks:hook(target, handler, options) end
    \\
    \\---The same at an address of your own, typed like `target`.
    \\---@param address integer
    \\---@param target function
    \\---@param handler function
    \\---@param options? Wraith.Hook.Options
    \\---@return Wraith.Hook
    \\function hooks:hookAt(address, target, handler, options) end
    \\
;
