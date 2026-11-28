//! `wraith pack`: a release build of a plugin or project, zipped the way the hub takes it.

const std = @import("std");

const core = @import("wraith_core");
const platform = @import("wraith_platform");

const ops = @import("ops.zig");
const cli = @import("args.zig");
const zip = @import("zip.zig");

const log = core.log.scoped(.wraith_cli);

pub const usage =
    \\  pack [<folder>] [--out <file.zip>]   a release build of the plugin or project in <folder>
    \\                                       (default here), zipped as the hub takes it, as
    \\                                       <id>-<version>.zip unless --out says. It's built with
    \\                                       what's there: zig build, cargo (sdk rust build), CMake,
    \\                                       dotnet publish or npm run pack, else its files as they
    \\                                       are. Its wraith.json goes in without devDepends, and
    \\                                       with descriptionFile's text as description
;

/// How a package builds, by what's in its folder.
pub const Builder = enum { zig, rust, cmake, cs, js, files };

/// Never in a package of files as they are.
const dev_only = [_][]const u8{ ".git", ".github", ".gitignore", ".wraith", ".luarc.json", ".vscode", "node_modules", "zig-out", ".zig-cache", "zig-pkg", "dist", "build", "target", "bin", "obj" };

pub fn run(ctx: ops.Context, args: *cli.Args) !u8 {
    var folder: []const u8 = ".";
    var out: ?[]const u8 = null;
    var given = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--out")) {
            out = args.value("--out") orelse return 1;
        } else if (!given and !cli.isFlag(arg)) {
            folder = arg;
            given = true;
        } else return cli.unexpected(arg, usage);
    }
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const made = pack(ctx, arena, folder) catch |err| switch (err) {
        error.Said => return 1,
        else => return err,
    };
    const file = out orelse try std.fmt.allocPrint(arena, "{s}-{s}.zip", .{ made.id, made.version });
    try std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = file, .data = made.bytes });
    log.printLn("{s} {s}: {s}, {d} bytes", .{ made.id, made.version, file, made.bytes.len });
    return 0;
}

pub const Packed = struct {
    id: []const u8,
    version: []const u8,
    bytes: []const u8,
};

/// `error.Said` once it's said what's wrong.
pub fn pack(ctx: ops.Context, arena: std.mem.Allocator, folder: []const u8) !Packed {
    const io = ctx.io;
    var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch |err| return said("Can't open {s}: {t}", .{ folder, err });
    defer dir.close(io);
    const text = dir.readFileAlloc(io, core.manifest.file_name, arena, .limited(1 << 20)) catch return said("There's no {s} in {s}", .{ core.manifest.file_name, folder });
    var problem: []const u8 = "";
    const manifest = core.manifest.parse(arena, text, &problem) catch |err| return said("Its {s} isn't right: {s}", .{ core.manifest.file_name, if (problem.len > 0) problem else @errorName(err) });
    const version = manifest.version orelse return said("Its {s} needs a \"version\" like \"1.2.3\"", .{core.manifest.file_name});
    const builder = builderOf(io, dir);
    log.info("Packing {s} {s}, built with {t}", .{ manifest.id, version, builder });

    if (builder == .js) {
        try runIn(ctx, arena, folder, &.{ npm(), if (exists(io, dir, "package-lock.json")) "ci" else "install" });
        try runIn(ctx, arena, folder, &.{ npm(), "run", "pack" });
        // plugin-tools zips it the hub's way itself
        const name = try std.fmt.allocPrint(arena, "{s}-{s}.zip", .{ manifest.id, version });
        const bytes = dir.readFileAlloc(io, name, arena, .limited(512 << 20)) catch return said("npm run pack didn't make {s}", .{name});
        return .{ .id = manifest.id, .version = version, .bytes = bytes };
    }

    // Built into a folder of its own, then zipped from there
    const stage = try std.fs.path.join(arena, &.{ folder, ".wraith", "pack" });
    std.Io.Dir.cwd().deleteTree(io, stage) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, stage) catch {};
    const folder_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, folder, arena);
    const stage_full = try std.fs.path.join(arena, &.{ folder_abs, ".wraith", "pack" });
    const self = try std.process.executablePathAlloc(io, arena);
    switch (builder) {
        .js => unreachable,
        .zig => try runIn(ctx, arena, folder, &.{ try envOr(arena, "ZIG", "zig"), "build", "-Doptimize=ReleaseFast", "--prefix", stage_full }),
        .rust => try runIn(ctx, arena, folder, &.{ self, "sdk", "rust", "build", "--out", stage_full }),
        .cs => try runIn(ctx, arena, folder, &.{ "dotnet", "publish", "-c", "Release", "-o", stage_full }),
        .cmake => {
            const cmake = try envOr(arena, "CMAKE", "cmake");
            const wraith = try std.fmt.allocPrint(arena, "-DWRAITH={s}", .{self});
            const arches: []const core.arch.Arch = manifest.arches orelse &.{.x64};
            for (arches) |arch| {
                const build = try std.fmt.allocPrint(arena, "build/{t}", .{arch});
                try runIn(ctx, arena, folder, &.{ cmake, "-S", ".", "-B", build, "-A", if (arch == .x86) "Win32" else "x64", wraith });
                try runIn(ctx, arena, folder, &.{ cmake, "--build", build, "--config", "Release" });
            }
            // wraith.cmake puts each arch's DLL in dist, beside wraith.json and the schemas
            try copyTree(io, arena, dir, "dist", stage_full);
        },
        .files => try copyFiles(io, arena, dir, stage_full),
    }

    var staged = std.Io.Dir.cwd().openDir(io, stage, .{ .iterate = true }) catch |err| return said("The build left nothing in {s}: {t}", .{ stage, err });
    defer staged.close(io);
    const bytes = try zipStage(io, arena, staged, dir, manifest.id, text);
    return .{ .id = manifest.id, .version = version, .bytes = bytes };
}

fn said(comptime fmt: []const u8, args: anytype) error{Said} {
    log.err(fmt, args);
    return error.Said;
}

pub fn builderOf(io: std.Io, dir: std.Io.Dir) Builder {
    if (exists(io, dir, "build.zig")) return .zig;
    if (exists(io, dir, "package.json")) return .js;
    if (exists(io, dir, "Cargo.toml")) return .rust;
    if (exists(io, dir, "CMakeLists.txt")) return .cmake;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| if (e.kind == .file and std.mem.endsWith(u8, e.name, ".csproj")) return .cs;
    return .files;
}

fn exists(io: std.Io, dir: std.Io.Dir, name: []const u8) bool {
    dir.access(io, name, .{}) catch return false;
    return true;
}

fn npm() []const u8 {
    return if (@import("builtin").os.tag == .windows) "npm.cmd" else "npm";
}

fn envOr(arena: std.mem.Allocator, name: []const u8, default: []const u8) ![]const u8 {
    return (try platform.process.envAlloc(arena, name)) orelse default;
}

/// Runs `argv` in `folder`, its output going to ours. `error.Said` if it fails.
fn runIn(ctx: ops.Context, arena: std.mem.Allocator, folder: []const u8, argv: []const []const u8) !void {
    const line = try std.mem.join(arena, " ", argv);
    log.info("> {s}", .{line});
    var child = std.process.spawn(ctx.io, .{ .argv = argv, .cwd = .{ .path = folder } }) catch |err| return said("Couldn't run {s}: {t}", .{ argv[0], err });
    const term = child.wait(ctx.io) catch |err| return said("{s} didn't finish: {t}", .{ argv[0], err });
    if (term != .exited or term.exited != 0) return said("{s} failed", .{line});
}

/// Every file in `dir`, but for what's only for working on it.
fn copyFiles(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, to: []const u8) !void {
    var walker = try dir.walk(arena);
    defer walker.deinit(io);
    while (try walker.next(io)) |entry| {
        if (devOnly(entry.path)) {
            if (entry.kind == .directory) walker.leave(io);
            continue;
        }
        if (entry.kind != .file or std.mem.endsWith(u8, entry.basename, ".zip")) continue;
        try copyOne(io, arena, dir, entry.path, to);
    }
}

fn devOnly(path: []const u8) bool {
    var parts = std.mem.splitAny(u8, path, "/\\");
    const first = parts.first();
    for (dev_only) |d| if (std.mem.eql(u8, first, d)) return true;
    return false;
}

fn copyTree(io: std.Io, arena: std.mem.Allocator, dir: std.Io.Dir, sub: []const u8, to: []const u8) !void {
    var from = dir.openDir(io, sub, .{ .iterate = true }) catch |err| return said("The build left nothing in {s}: {t}", .{ sub, err });
    defer from.close(io);
    var walker = try from.walk(arena);
    defer walker.deinit(io);
    while (try walker.next(io)) |entry| if (entry.kind == .file) try copyOne(io, arena, from, entry.path, to);
}

fn copyOne(io: std.Io, arena: std.mem.Allocator, from: std.Io.Dir, path: []const u8, to: []const u8) !void {
    const bytes = try from.readFileAlloc(io, path, arena, .limited(512 << 20));
    const dest = try std.fs.path.join(arena, &.{ to, path });
    if (std.fs.path.dirname(dest)) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dest, .data = bytes });
}

/// Everything in `staged`, under `id/`, with wraith.json as it goes on the hub. Debug symbols stay out.
fn zipStage(io: std.Io, arena: std.mem.Allocator, staged: std.Io.Dir, source: std.Io.Dir, id: []const u8, source_manifest: []const u8) ![]u8 {
    var entries: std.ArrayList(zip.Entry) = .empty;
    var has_manifest = false;
    var walker = try staged.walk(arena);
    defer walker.deinit(io);
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or std.mem.endsWith(u8, entry.basename, ".pdb")) continue;
        const rel = try arena.dupe(u8, entry.path);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        var data: []const u8 = try staged.readFileAlloc(io, entry.path, arena, .limited(512 << 20));
        if (std.mem.eql(u8, rel, core.manifest.file_name)) {
            has_manifest = true;
            data = try packagedManifest(io, arena, source, data);
        }
        try entries.append(arena, .{ .name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ id, rel }), .data = data });
    }
    // The hub takes the id and version from it, so it's always there
    if (!has_manifest) try entries.append(arena, .{
        .name = try std.fmt.allocPrint(arena, "{s}/{s}", .{ id, core.manifest.file_name }),
        .data = try packagedManifest(io, arena, source, source_manifest),
    });
    std.mem.sort(zip.Entry, entries.items, {}, struct {
        fn lessThan(_: void, a: zip.Entry, b: zip.Entry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return zip.write(arena, entries.items);
}

fn packagedManifest(io: std.Io, arena: std.mem.Allocator, source: std.Io.Dir, text: []const u8) ![]const u8 {
    return (core.manifest.packaged(arena, io, source, text) catch |err| switch (err) {
        error.BothDescriptions => return said("Its wraith.json has description and descriptionFile. Keep one", .{}),
        error.DescriptionFile => return said("Its wraith.json's descriptionFile can't be read", .{}),
        else => return said("Its wraith.json isn't right: {t}", .{err}),
    }) orelse text;
}

test "a package of files has what it ships, under its id, with its wraith.json as the hub takes it" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const io = t.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "wraith.json", .data = "{ \"id\": \"kai\", \"kind\": \"project\", \"version\": \"1.0.0\", \"descriptionFile\": \"about.md\" }" });
    try tmp.dir.writeFile(io, .{ .sub_path = "about.md", .data = "# Kai\n" });
    try tmp.dir.createDirPath(io, "tweaks");
    try tmp.dir.writeFile(io, .{ .sub_path = "tweaks/a.lua", .data = "-- a" });
    try tmp.dir.createDirPath(io, ".git");
    try tmp.dir.writeFile(io, .{ .sub_path = ".git/HEAD", .data = "x" });
    const folder = try tmp.dir.realPathFileAlloc(io, ".", t.allocator);
    defer t.allocator.free(folder);

    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const ctx: ops.Context = .{ .allocator = t.allocator, .io = io, .dir = folder, .console = false };
    const made = try pack(ctx, arena.allocator(), folder);
    try t.expectEqualStrings("kai", made.id);
    try t.expectEqualStrings("1.0.0", made.version);

    try tmp.dir.writeFile(io, .{ .sub_path = "out.zip", .data = made.bytes });
    try tmp.dir.createDirPath(io, "out");
    var out = try tmp.dir.openDir(io, "out", .{});
    defer out.close(io);
    const file = try tmp.dir.openFile(io, "out.zip", .{});
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);
    try std.zip.extract(out, &reader, .{});
    const manifest = try out.readFileAlloc(io, "kai/wraith.json", t.allocator, .limited(1 << 16));
    defer t.allocator.free(manifest);
    try t.expect(std.mem.indexOf(u8, manifest, "\"description\": \"# Kai\"") != null);
    try t.expect(std.mem.indexOf(u8, manifest, "descriptionFile") == null);
    try out.access(io, "kai/tweaks/a.lua", .{});
    try t.expectError(error.FileNotFound, out.access(io, "kai/.git/HEAD", .{}));
    // Nothing's left behind
    try t.expectError(error.FileNotFound, tmp.dir.access(io, ".wraith/pack", .{}));
}
