//! C++20 headers for a C++ plugin, for one pointer size: Salamander's `salamander.hpp`,
//! `salamander_runtime.hpp` and `salamander_core.hpp`, Wraith's API in `wraith.hpp`, the SDK's
//! `wraith_plugin.hpp`, and `schema.hpp` for its schemas. The same as a Zig build of one makes.

const std = @import("std");
const salamander_cpp = @import("salamander_cpp");

const Project = @import("project.zig");
const Made = @import("output.zig").Made;

pub const default_out = ".wraith/cpp";

pub fn generate(p: *Project) ![]const Made {
    const a = p.arena;
    var core: std.Io.Writer.Allocating = .init(a);
    try salamander_cpp.writeCore(a, &core.writer, p.pointer_size);
    var wraith = try p.wraith();
    defer wraith.deinit();
    var api: std.Io.Writer.Allocating = .init(a);
    salamander_cpp.write(a, wraith.schema, &api.writer, .{ .label = "wraith.sal" }, &p.diag) catch |err| return p.clash(err);
    var mine = try p.mine();
    defer mine.deinit();
    var schema: std.Io.Writer.Allocating = .init(a);
    salamander_cpp.write(a, mine.schema, &schema.writer, .{
        .label = "schema.sal",
        .source = mine.source,
        .aliases = &.{.{ .prefix = "wraith/", .include = "wraith.hpp" }},
    }, &p.diag) catch |err| return p.clash(err);

    return a.dupe(Made, &.{
        .{ .name = "salamander.hpp", .text = salamander_cpp.base_header },
        .{ .name = "salamander_runtime.hpp", .text = salamander_cpp.runtime_header },
        .{ .name = "salamander_core.hpp", .text = core.written() },
        .{ .name = "wraith.hpp", .text = api.written() },
        .{ .name = "wraith_plugin.hpp", .text = @embedFile("wraith_plugin.hpp") },
        .{ .name = "schema.hpp", .text = schema.written() },
    });
}
