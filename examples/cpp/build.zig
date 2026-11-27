const std = @import("std");
const wraith = @import("wraith");

pub fn build(b: *std.Build) void {
    const plugin: wraith.Plugin = .initCpp(b, .{
        .name = "example_cpp",
        .sources = &.{"src/plugin.cpp"},
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
        .flags = &.{ "-std=c++20", "-Wall", "-Wextra", "-Wno-missing-field-initializers", "-Werror" },
    });
    plugin.install(b);
}
