//! C# for a C# plugin's project to compile: Wraith's API in `Wraith`, the SDK's `WraithPlugin`, Salamander's
//! runtime, and `Schema.cs` for its schemas in its namespace and those of the plugins it depends on in theirs.

const std = @import("std");
const salamander_cs = @import("salamander_cs");

const Project = @import("project.zig");
const Made = @import("output.zig").Made;

pub const default_out = ".wraith/cs";

/// Wraith's API, `Raw` and constants live in `Wraith`. Constants can't be `Api` or `Schema` (traits).
const namespace = "Wraith";
const class = "Constants";

pub fn generate(p: *Project) ![]const Made {
    const a = p.arena;
    var wraith = try p.wraith();
    defer wraith.deinit();
    var core: std.Io.Writer.Allocating = .init(a);
    try salamander_cs.writeCore(a, &core.writer, p.pointer_size);
    var api: std.Io.Writer.Allocating = .init(a);
    try salamander_cs.write(a, wraith.schema, &api.writer, .{ .label = "wraith.sal", .namespace = namespace, .class = class }, &p.diag);

    var mine = try p.mine();
    defer mine.deinit();
    var schema: std.Io.Writer.Allocating = .init(a);
    salamander_cs.write(a, mine.schema, &schema.writer, .{
        .label = "its schemas",
        .namespace = p.namespace,
        .class = "Schema",
        .source = mine.source,
        .aliases = &.{.{ .prefix = "wraith/", .namespace = namespace }},
        .singletons = try p.services(mine),
    }, &p.diag) catch |err| return p.clash(err);

    return a.dupe(Made, &.{
        .{ .name = "Salamander.cs", .text = salamander_cs.base_file },
        .{ .name = "WraithPlugin.cs", .text = @embedFile("WraithPlugin.cs") },
        .{ .name = "SalamanderCore.cs", .text = core.written() },
        .{ .name = "Wraith.cs", .text = api.written() },
        .{ .name = "Schema.cs", .text = schema.written() },
    });
}
