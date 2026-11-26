const std = @import("std");
const wraith = @import("wraith");

pub fn build(b: *std.Build) void {
    const plugin: wraith.Plugin = .initC(b, .{
        .name = "example_c",
        .sources = &.{"src/plugin.c"},
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    plugin.install(b);
}
