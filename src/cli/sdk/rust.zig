//! Rust for a Rust plugin: the `salamander` and `wraith` crates, for its Cargo.toml to depend on by path, and
//! `schema.rs` for its schemas. Made for 64 and 32-bit both, picked by what it's built for, so one crate
//! builds either. `build` builds it with cargo for each of its arches, with what Wraith loads put in a folder.

const std = @import("std");
const salamander_rust = @import("salamander_rust");

const core = @import("wraith_core");

const ops = @import("../ops.zig");
const Project = @import("project.zig");
const output = @import("output.zig");
const Made = output.Made;

const log = core.log.scoped(.wraith_cli);

pub const default_out = ".wraith/rust";

pub fn generate(p: *Project) ![]const Made {
    const a = p.arena;
    var list: std.ArrayList(Made) = .empty;
    for (salamander_rust.crate_files) |f| try list.append(a, .{ .name = try std.fmt.allocPrint(a, "salamander/{s}", .{f[0]}), .text = f[1] });
    try list.append(a, .{ .name = "wraith/Cargo.toml", .text = @embedFile("wraith_sdk.toml") });
    try list.append(a, .{ .name = "wraith/src/lib.rs", .text = @embedFile("wraith_sdk.rs") });
    const module = try salamander_rust.snake(a, p.namespace);
    var own_module = false;
    const size = p.pointer_size;
    defer p.pointer_size = size;
    for ([_]u8{ 8, 4 }) |s| {
        p.pointer_size = s;
        const bits: []const u8 = if (s == 4) "32" else "64";
        var wraith = try p.wraith();
        defer wraith.deinit();
        var api: std.Io.Writer.Allocating = .init(a);
        salamander_rust.write(a, wraith.schema, &api.writer, .{ .label = "wraith.sal" }, &p.diag) catch |err| return p.clash(err);
        try list.append(a, .{ .name = try std.fmt.allocPrint(a, "wraith/api_{s}.rs", .{bits}), .text = api.written() });
        var mine = try p.mine();
        defer mine.deinit();
        var schema: std.Io.Writer.Allocating = .init(a);
        salamander_rust.write(a, mine.schema, &schema.writer, .{
            .label = "its schemas",
            .source = mine.source,
            .aliases = &.{.{ .prefix = "wraith/", .path = "::wraith::api" }},
        }, &p.diag) catch |err| return p.clash(err);
        if (s == 8) own_module = std.mem.indexOf(u8, schema.written(), try std.fmt.allocPrint(a, "\npub mod {s} {{\n", .{module})) != null;
        try list.append(a, .{ .name = try std.fmt.allocPrint(a, "schema_{s}.rs", .{bits}), .text = schema.written() });
    }
    var pick: std.Io.Writer.Allocating = .init(a);
    try pick.writer.writeAll(
        \\// Made by wraith sdk rust types: its schemas for the pointer size it's built for. Don't change it, since it's made again.
        \\#[cfg(target_pointer_width = "64")]
        \\include!("schema_64.rs");
        \\#[cfg(target_pointer_width = "32")]
        \\include!("schema_32.rs");
        \\
    );
    // Its own types without their module's name in front
    if (own_module) try pick.writer.print("#[allow(unused_imports)]\npub use {s}::*;\n", .{module});
    try list.append(a, .{ .name = "schema.rs", .text = pick.written() });
    return list.items;
}

pub const build_usage =
    \\  sdk rust build [--debug] [--out <folder>]
    \\                                       sdk rust types, then cargo build for each of
    \\                                       wraith.json's arches (x64 if it has none), with
    \\                                       wraith_<id>_<arch>.dll, wraith.json and its schemas put
    \\                                       in <folder> (default dist) for dev add. Needs cargo,
    \\                                       and rustup's i686-pc-windows-msvc for x86
;

/// `types` first, then cargo for each arch, with what Wraith loads put in `out`.
pub fn build(ctx: ops.Context, arena: std.mem.Allocator, args: anytype, types: *const fn (ops.Context, std.mem.Allocator) anyerror!u8) !u8 {
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();
    var release = true;
    var out: []const u8 = "dist";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--debug")) {
            release = false;
        } else if (std.mem.eql(u8, arg, "--out")) {
            out = args.next() orelse return error.Usage;
        } else return error.Usage;
    }
    const text = cwd.readFileAlloc(io, core.manifest.file_name, arena, .limited(1 << 20)) catch {
        log.err("There's no {s} here. Run it in the plugin's folder", .{core.manifest.file_name});
        return 1;
    };
    const manifest = core.manifest.parse(arena, text, null) catch |err| {
        log.err("{s}: {t}", .{ core.manifest.file_name, err });
        return 1;
    };
    const cargo_toml = cwd.readFileAlloc(io, "Cargo.toml", arena, .limited(1 << 20)) catch {
        log.err("There's no Cargo.toml here", .{});
        return 1;
    };
    const lib = libName(arena, cargo_toml) orelse {
        log.err("Cargo.toml has no [lib] or [package] name", .{});
        return 1;
    };
    if (try types(ctx, arena) != 0) return 1;

    const profile: []const u8 = if (release) "release" else "debug";
    const arches: []const core.arch.Arch = manifest.arches orelse &.{.x64};
    for (arches) |arch| {
        const triple: []const u8 = switch (arch) {
            .x64 => "x86_64-pc-windows-msvc",
            .x86 => "i686-pc-windows-msvc",
        };
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(arena, &.{ "cargo", "build", "--target", triple });
        if (release) try argv.append(arena, "--release");
        var child = std.process.spawn(io, .{ .argv = argv.items }) catch |err| {
            log.err("Couldn't run cargo: {t}. Rust plugins need it, from https://rustup.rs", .{err});
            return 1;
        };
        const term = child.wait(io) catch |err| {
            log.err("cargo didn't finish: {t}", .{err});
            return 1;
        };
        if (term != .exited or term.exited != 0) {
            if (arch == .x86) log.err("cargo build for x86 failed. Without its target, rustup target add {s} adds it", .{triple});
            return 1;
        }
        const built = try std.fmt.allocPrint(arena, "target/{s}/{s}/{s}.dll", .{ triple, profile, lib });
        const bytes = cwd.readFileAlloc(io, built, arena, .limited(512 << 20)) catch |err| {
            log.err("{s}: {t}. Its Cargo.toml needs crate-type = [\"cdylib\"]", .{ built, err });
            return 1;
        };
        const name = try arch.dllNameAlloc(arena, manifest.id);
        if (try output.writeIfChanged(ctx, arena, out, name, bytes)) log.printLn("{s}/{s}", .{ out, name });
    }
    try copyLoaded(ctx, arena, out, text);
    log.printLn("Built it in {s}, which wraith dev add {s} loads", .{ out, out });
    return 0;
}

/// Its wraith.json and schemas, which Wraith reads beside its DLL.
fn copyLoaded(ctx: ops.Context, arena: std.mem.Allocator, out: []const u8, manifest: []const u8) !void {
    _ = try output.writeIfChanged(ctx, arena, out, core.manifest.file_name, manifest);
    const io = ctx.io;
    var dir = std.Io.Dir.cwd().openDir(io, "schemas", .{ .iterate = true }) catch return;
    defer dir.close(io);
    var walker = try dir.walk(arena);
    defer walker.deinit(io);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".sal")) continue;
        const text = try dir.readFileAlloc(io, entry.path, arena, .limited(16 << 20));
        _ = try output.writeIfChanged(ctx, arena, out, try std.fs.path.join(arena, &.{ "schemas", entry.path }), text);
    }
}

/// A crate's library name: its [lib] name, else its package's with `-` as `_`, like cargo names the DLL.
pub fn libName(arena: std.mem.Allocator, toml: []const u8) ?[]const u8 {
    var section: []const u8 = "";
    var package: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, toml, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0 and line[0] == '[') {
            section = line;
            continue;
        }
        if (!std.mem.startsWith(u8, line, "name")) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.trim(u8, line[4..eq], " \t").len != 0) continue;
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t\"'");
        if (std.mem.eql(u8, section, "[lib]")) return value;
        if (std.mem.eql(u8, section, "[package]")) package = value;
    }
    const p = package orelse return null;
    const lib = arena.dupe(u8, p) catch return null;
    std.mem.replaceScalar(u8, lib, '-', '_');
    return lib;
}

test "a crate's library name, as cargo names its DLL" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("my_mod", libName(arena, "[package]\nname = \"my-mod\"\n").?);
    try std.testing.expectEqualStrings("lib_one", libName(arena, "[package]\nname = \"pkg\"\n\n[lib]\nname = \"lib_one\"\ncrate-type = [\"cdylib\"]\n").?);
    try std.testing.expectEqual(null, libName(arena, "[dependencies]\nname = \"x\"\n"));
}
