//! How `wraith new` makes a plugin in each language: what it needs, the files it writes from templates/,
//! and what builds it. new.zig asks the questions and writes wraith.json; this says the rest.

const std = @import("std");

const languages = @import("../languages.zig");
const Language = languages.Language;

pub const Recipe = struct {
    /// What it needs on PATH, by how to ask its version, and what to say without it.
    needs: ?Tool = null,
    /// `zig init`, then Wraith's SDK fetched as a Zig package, for `zig build`.
    zig_package: bool = false,
    /// `npm create`'s own template instead of files.
    npm: bool = false,
    /// By path, which can have `{{placeholders}}` like its contents.
    files: []const Template = &.{},
    gitignore: []const u8 = "",
    /// `wraith sdk <it> types` once it's made, so an editor knows Wraith's API before it builds.
    types: ?languages.Sdk = null,
    /// Where what Wraith loads ends up, from its folder. Its folder itself if empty.
    built: []const u8,
    /// What to run in its folder next, with placeholders.
    next: []const u8,
};

pub const Tool = struct { argv: []const []const u8, missing: []const u8 };

pub const Template = struct { path: []const u8, text: []const u8 };

const zig_tool: Tool = .{ .argv = &.{ "zig", "version" }, .missing = "Zig isn't on your PATH. Plugins built with it need Zig {{zig_version}}: https://ziglang.org/download" };
const cmake_tool: Tool = .{ .argv = &.{ "cmake", "--version" }, .missing = "CMake isn't on your PATH: https://cmake.org/download, or Visual Studio's C++ tools have it" };
const cargo_tool: Tool = .{ .argv = &.{ "cargo", "--version" }, .missing = "cargo isn't on your PATH. Rust plugins need it: https://rustup.rs" };
const dotnet_tool: Tool = .{ .argv = &.{ "dotnet", "--version" }, .missing = "dotnet isn't on your PATH. C# plugins need the .NET 10 SDK: https://dot.net" };
const npm_tool: Tool = .{ .argv = &.{ "npm", "--version" }, .missing = "npm isn't on your PATH. Install Node from https://nodejs.org" };

// Each list's a constant, so a recipe's slices outlive the call that gives it
const zig_files = [_]Template{
    .{ .path = "build.zig", .text = @embedFile("templates/zig/build.zig.tmpl") },
    .{ .path = "src/root.zig", .text = @embedFile("templates/zig/root.zig.tmpl") },
};
const c_zig_files = [_]Template{
    .{ .path = "build.zig", .text = @embedFile("templates/native/build.zig.tmpl") },
    .{ .path = "{{source}}", .text = @embedFile("templates/native/plugin.c.tmpl") },
};
const cpp_zig_files = [_]Template{
    .{ .path = "build.zig", .text = @embedFile("templates/native/build.zig.tmpl") },
    .{ .path = "{{source}}", .text = @embedFile("templates/native/plugin.cpp.tmpl") },
};
const c_cmake_files = [_]Template{
    .{ .path = "CMakeLists.txt", .text = @embedFile("templates/cmake/CMakeLists.txt.tmpl") },
    .{ .path = "{{source}}", .text = @embedFile("templates/native/plugin.c.tmpl") },
};
const cpp_cmake_files = [_]Template{
    .{ .path = "CMakeLists.txt", .text = @embedFile("templates/cmake/CMakeLists.txt.tmpl") },
    .{ .path = "{{source}}", .text = @embedFile("templates/native/plugin.cpp.tmpl") },
};
const rust_files = [_]Template{
    .{ .path = "Cargo.toml", .text = @embedFile("templates/rust/Cargo.toml.tmpl") },
    .{ .path = "build.rs", .text = @embedFile("templates/rust/build.rs.tmpl") },
    .{ .path = "src/lib.rs", .text = @embedFile("templates/rust/lib.rs.tmpl") },
};
const cs_files = [_]Template{
    // Its runtime part's from csRuntime
    .{ .path = "{{namespace}}.csproj", .text = @embedFile("templates/cs/project.csproj.tmpl") },
    .{ .path = "Plugin.cs", .text = @embedFile("templates/cs/Plugin.cs.tmpl") },
};
const lua_files = [_]Template{.{ .path = "main.lua", .text = @embedFile("templates/lua/main.lua.tmpl") }};

const zig_build: Recipe = .{ .needs = zig_tool, .zig_package = true, .gitignore = "zig-out/\n.zig-cache/\n", .built = "zig-out", .next = "zig build" };
const cmake_build: Recipe = .{ .needs = cmake_tool, .gitignore = "build/\ndist/\n", .built = "dist", .next = "cmake -B build{{cmake_arch}}\n  cmake --build build --config Release" };

pub fn of(language: Language, build: languages.Build) Recipe {
    return switch (language) {
        .zig => with(zig_build, &zig_files),
        .c => with(if (build == .zig) zig_build else cmake_build, if (build == .zig) &c_zig_files else &c_cmake_files),
        .cpp => with(if (build == .zig) zig_build else cmake_build, if (build == .zig) &cpp_zig_files else &cpp_cmake_files),
        .rust => .{
            .needs = cargo_tool,
            .files = &rust_files,
            .gitignore = ".wraith/\ntarget/\ndist/\n",
            // Its Cargo.toml depends on the crates this writes
            .types = .rust,
            .built = "dist",
            .next = "wraith sdk rust build",
        },
        .cs => .{
            .needs = dotnet_tool,
            .files = &cs_files,
            .gitignore = "bin/\nobj/\ndist/\n.wraith/\n",
            .types = .cs,
            .built = "dist",
            .next = "dotnet publish",
        },
        .ts, .js => .{
            .needs = npm_tool,
            .npm = true,
            .built = "dist",
            .next = "npm install\n  npm run dev",
        },
        .lua => .{
            .files = &lua_files,
            .gitignore = ".wraith/\n",
            .types = .lua,
            .built = "",
            .next = "(edit main.lua, then Reload it in the Mods window)\n  wraith sdk lua types   (after updating Wraith or changing schemas, for your editor's types)",
        },
    };
}

fn with(base: Recipe, files: []const Template) Recipe {
    var r = base;
    r.files = files;
    return r;
}

/// The C# project's runtime part, which goes in its `{{runtime}}`.
pub fn csRuntime(runtime: languages.Runtime) []const u8 {
    return switch (runtime) {
        .aot => @embedFile("templates/cs/aot.tmpl"),
        .clr => @embedFile("templates/cs/clr.tmpl"),
    };
}

/// `text` with each `{{name}}` as its value. One without a value stays as it is.
pub fn fill(arena: std.mem.Allocator, text: []const u8, values: []const [2][]const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var rest = text;
    while (std.mem.indexOf(u8, rest, "{{")) |open| {
        try out.appendSlice(arena, rest[0..open]);
        const close = std.mem.indexOfPos(u8, rest, open + 2, "}}") orelse break;
        const name = rest[open + 2 .. close];
        const value = for (values) |v| {
            if (std.mem.eql(u8, v[0], name)) break v[1];
        } else null;
        if (value) |v| try out.appendSlice(arena, v) else try out.appendSlice(arena, rest[open .. close + 2]);
        rest = rest[close + 2 ..];
    }
    try out.appendSlice(arena, rest);
    return out.items;
}

test "placeholders are filled, and others stay" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    try std.testing.expectEqualStrings("wraith_kai_x64 ${X} {{other}}", try fill(a, "wraith_{{id}}_{{arch}} ${X} {{other}}", &.{ .{ "id", "kai" }, .{ "arch", "x64" } }));
}

test "every language and build has a recipe that builds somewhere" {
    for (std.enums.values(Language)) |l| for (std.enums.values(languages.Build)) |b| {
        const r = of(l, b);
        try std.testing.expect(r.next.len > 0);
        try std.testing.expect(r.npm or r.files.len > 0);
    };
}
