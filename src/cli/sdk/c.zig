//! C headers for a C plugin, for one pointer size: Salamander's `salamander.h` and `salamander_core.h`,
//! Wraith's API in `wraith.h`, the SDK's `wraith_plugin.h`, and `schema.h` for its schemas, with Wraith's
//! types from `wraith.h`. The same as a Zig build of one makes.

const std = @import("std");
const salamander_c = @import("salamander_c");

const Project = @import("project.zig");
const Made = @import("output.zig").Made;

pub const default_out = ".wraith/c";

pub fn generate(p: *Project) ![]const Made {
    const a = p.arena;
    var core: std.Io.Writer.Allocating = .init(a);
    try salamander_c.writeCore(a, &core.writer, p.pointer_size);
    var wraith = try p.wraith();
    defer wraith.deinit();
    var api: std.Io.Writer.Allocating = .init(a);
    salamander_c.write(a, wraith.schema, &api.writer, .{ .label = "wraith.sal" }, &p.diag) catch |err| return p.clash(err);
    var mine = try p.mine();
    defer mine.deinit();
    var schema: std.Io.Writer.Allocating = .init(a);
    salamander_c.write(a, mine.schema, &schema.writer, .{
        .label = "schema.sal",
        .source = mine.source,
        .aliases = &.{.{ .prefix = "wraith/", .include = "wraith.h" }},
    }, &p.diag) catch |err| return p.clash(err);

    return a.dupe(Made, &.{
        .{ .name = "salamander.h", .text = salamander_c.base_header },
        .{ .name = "salamander_core.h", .text = core.written() },
        .{ .name = "wraith.h", .text = api.written() },
        .{ .name = "wraith_plugin.h", .text = @embedFile("wraith_plugin.h") },
        .{ .name = "schema.h", .text = schema.written() },
    });
}
