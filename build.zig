const std = @import("std");
const zon = @import("build.zig.zon");
const Salamander = @import("salamander");

const Import = std.Build.Module.Import;

const proxy_info = @import("src/proxy/info.zig");
const core_deps = @import("src/core/deps.zig");
const core_manifest = @import("src/core/manifest.zig");
const Locations = @import("src/core/Locations.zig");

const wraith_build = @This();

/// `[Instance("..")] struct T` gives `T.instance`, as `api.sal_options` has it.
const instance_tag = "wraith.Instance=Sig";

/// Builds a Zig plugin's DLLs against the SDK for each arch in `.arches`, or just -Dtarget's.
pub const Plugin = struct {
    name: []const u8,
    manifest: std.Build.LazyPath,
    /// Its own `.sal` files, installed beside it.
    schemas: ?std.Build.LazyPath,
    /// The first is -Dtarget's or the native one, so tests can use it.
    arches: []const Arch,

    pub const Arch = struct {
        target: std.Build.ResolvedTarget,
        lib: *std.Build.Step.Compile,
        mod: *std.Build.Module,
        sdk: *std.Build.Module,
    };

    pub const Options = struct {
        name: []const u8,
        root_source_file: std.Build.LazyPath,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        /// Its `.sal` schema folder. Null means schemas/ next to root_source_file, or in the project root.
        schemas: ?std.Build.LazyPath = null,
        schema_import: []const u8 = "schema",
        /// Null means wraith.json in the project root.
        manifest: ?std.Build.LazyPath = null,
    };

    pub fn init(b: *std.Build, options: Options) Plugin {
        const targets = targetsOf(b, options.target);
        const depends = dependsOf(b);
        const arches = b.allocator.alloc(Arch, targets.len) catch @panic("OOM");
        for (targets, arches) |target, *arch| {
            const wraith = b.dependencyFromBuildZig(wraith_build, .{ .target = target, .optimize = options.optimize });
            // The same one the SDK uses, so there's one salamander runtime
            const salamander = wraith.builder.dependency("salamander", .{ .target = target, .optimize = options.optimize });
            var for_arch = options;
            for_arch.target = target;
            arch.* = create(b, .of(wraith), salamander, for_arch, depends);
        }
        return .{
            .name = options.name,
            .manifest = options.manifest orelse b.path("wraith.json"),
            .schemas = options.schemas orelse findSchemas(options.root_source_file),
            .arches = arches,
        };
    }

    pub const COptions = struct {
        name: []const u8,
        /// Its C files, from the project root.
        sources: []const []const u8,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        flags: []const []const u8 = &.{ "-std=c11", "-Wall", "-Wextra" },
        /// Its `.sal` files, as `schema.h`. Null means schemas/ in the project root.
        schemas: ?std.Build.LazyPath = null,
        /// Null means wraith.json in the project root.
        manifest: ?std.Build.LazyPath = null,
    };

    /// A C plugin compiled by Zig, with `wraith.h`, `wraith_plugin.h` and its generated `schema.h`.
    pub fn initC(b: *std.Build, options: COptions) Plugin {
        const targets = targetsOf(b, options.target);
        const depends = dependsOf(b);
        const schemas = options.schemas orelse findSchemas(b.path("plugin.c"));
        const arches = b.allocator.alloc(Arch, targets.len) catch @panic("OOM");
        for (targets, arches) |target, *arch| {
            const wraith = b.dependencyFromBuildZig(wraith_build, .{ .target = target, .optimize = options.optimize });
            const salamander = wraith.builder.dependency("salamander", .{ .target = target, .optimize = options.optimize });
            const module = cModule(b, salamander, .{ .api = wraith.path("src/api/schemas"), .include = wraith.path("src/sdk/c") }, .{
                .name = options.name,
                .root = b.path("."),
                .sources = options.sources,
                .flags = options.flags,
                .target = target,
                .optimize = options.optimize,
                .schemas = schemas,
                .depends = depends,
            });
            arch.* = .{
                .target = target,
                .lib = b.addLibrary(.{ .name = b.fmt("wraith_{s}_{s}", .{ options.name, archName(target) }), .linkage = .dynamic, .root_module = module }),
                .mod = module,
                .sdk = Sdk.of(wraith).sdk,
            };
        }
        return .{
            .name = options.name,
            .manifest = options.manifest orelse b.path("wraith.json"),
            .schemas = schemas,
            .arches = arches,
        };
    }

    pub const CppOptions = struct {
        name: []const u8,
        /// Its C++ files, from the project root.
        sources: []const []const u8,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        /// Designated initializers leave out padding and unset fields, so that warning's off.
        flags: []const []const u8 = &.{ "-std=c++20", "-Wall", "-Wextra", "-Wno-missing-field-initializers" },
        /// Its `.sal` files, as `schema.hpp`. Null means schemas/ in the project root.
        schemas: ?std.Build.LazyPath = null,
        /// Null means wraith.json in the project root.
        manifest: ?std.Build.LazyPath = null,
    };

    /// A C++20 plugin compiled by Zig, with `wraith.hpp`, `wraith_plugin.hpp` and its generated `schema.hpp`.
    pub fn initCpp(b: *std.Build, options: CppOptions) Plugin {
        const targets = targetsOf(b, options.target);
        const depends = dependsOf(b);
        const schemas = options.schemas orelse findSchemas(b.path("plugin.cpp"));
        const arches = b.allocator.alloc(Arch, targets.len) catch @panic("OOM");
        for (targets, arches) |target, *arch| {
            const wraith = b.dependencyFromBuildZig(wraith_build, .{ .target = target, .optimize = options.optimize });
            const salamander = wraith.builder.dependency("salamander", .{ .target = target, .optimize = options.optimize });
            const module = cppModule(b, salamander, .{ .api = wraith.path("src/api/schemas"), .include = wraith.path("src/sdk/cpp") }, .{
                .name = options.name,
                .root = b.path("."),
                .sources = options.sources,
                .flags = options.flags,
                .target = target,
                .optimize = options.optimize,
                .schemas = schemas,
                .depends = depends,
            });
            arch.* = .{
                .target = target,
                .lib = b.addLibrary(.{ .name = b.fmt("wraith_{s}_{s}", .{ options.name, archName(target) }), .linkage = .dynamic, .root_module = module }),
                .mod = module,
                .sdk = Sdk.of(wraith).sdk,
            };
        }
        return .{
            .name = options.name,
            .manifest = options.manifest orelse b.path("wraith.json"),
            .schemas = schemas,
            .arches = arches,
        };
    }

    fn archName(target: std.Build.ResolvedTarget) []const u8 {
        return if (target.result.cpu.arch == .x86) "x86" else "x64";
    }

    /// Where Wraith's own C pieces are: its schemas, and `wraith_plugin.h`'s folder.
    const CPaths = struct { api: std.Build.LazyPath, include: std.Build.LazyPath };

    const CModule = struct {
        name: []const u8,
        root: std.Build.LazyPath,
        sources: []const []const u8,
        flags: []const []const u8,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        schemas: ?std.Build.LazyPath,
        /// The plugins it depends on, whose schemas go in its `schema.h` under their namespaces.
        depends: []const Salamander.ZigOptions.With = &.{},
    };

    /// A C plugin's module, with `wraith.h`, `wraith_plugin.h` and its `schema.h` to include.
    fn cModule(b: *std.Build, salamander: *std.Build.Dependency, paths: CPaths, options: CModule) *std.Build.Module {
        const module = b.createModule(.{ .target = options.target, .optimize = options.optimize, .link_libc = true });
        module.addCSourceFiles(.{ .root = options.root, .files = options.sources, .flags = options.flags });
        const api = Salamander.bundle(salamander, paths.api);
        module.addIncludePath(Salamander.cHeaders(salamander, .{ .source = api, .target = options.target, .name = "wraith.h" }));
        module.addIncludePath(paths.include);
        // Its own and its dependencies' schemas, like a Zig plugin's. Wraith's types come from wraith.h
        const own: Salamander.ZigOptions.With = .{ .name = "wraith", .folder = paths.api };
        // Without any of its own, the first dependency's folder stands in
        const folder = options.schemas orelse if (options.depends.len > 0) options.depends[0].folder else null;
        if (folder) |dir| {
            const rest = if (options.schemas != null) options.depends else options.depends[1..];
            const global_uses = b.allocator.alloc([]const u8, options.depends.len + 1) catch @panic("OOM");
            const file_namespaces = b.allocator.alloc([]const u8, options.depends.len) catch @panic("OOM");
            global_uses[0] = "Wraith";
            for (options.depends, global_uses[1..], file_namespaces) |d, *u, *f| {
                u.* = namespaceOf(b, d.name);
                f.* = b.fmt("{s}/={s}", .{ d.name, u.* });
            }
            module.addIncludePath(Salamander.cHeaders(salamander, .{
                .folder = dir,
                .target = options.target,
                .name = "schema.h",
                .uses = &.{"wraith"},
                .global_uses = global_uses,
                .namespace = namespaceOf(b, options.name),
                .file_namespaces = file_namespaces,
                .instances = &.{instance_tag},
                .with = std.mem.concat(b.allocator, Salamander.ZigOptions.With, &.{ &.{own}, rest }) catch @panic("OOM"),
                .aliases = &.{.{ .prefix = "wraith/", .include = "wraith.h" }},
            }));
        }
        return module;
    }

    /// A C++ plugin's module, with `wraith.hpp`, `wraith_plugin.hpp` and its `schema.hpp` to include.
    fn cppModule(b: *std.Build, salamander: *std.Build.Dependency, paths: CPaths, options: CModule) *std.Build.Module {
        // Zig's libc++ doesn't build for MSVC, whose own C++ library comes with its C one
        const msvc = options.target.result.abi == .msvc;
        const module = b.createModule(.{ .target = options.target, .optimize = options.optimize, .link_libc = true, .link_libcpp = !msvc });
        if (msvc) module.linkSystemLibrary("msvcprt", .{});
        // Zig says -nostdinc++ without its libc++, which MSVC's headers make unused
        const flags = if (msvc) std.mem.concat(b.allocator, []const u8, &.{ options.flags, &.{"-Wno-unused-command-line-argument"} }) catch @panic("OOM") else options.flags;
        module.addCSourceFiles(.{ .root = options.root, .files = options.sources, .flags = flags });
        const api = Salamander.bundle(salamander, paths.api);
        module.addIncludePath(Salamander.cppHeaders(salamander, .{ .source = api, .target = options.target, .name = "wraith.hpp" }));
        module.addIncludePath(paths.include);
        // Like cModule's: its own and its dependencies' schemas, with Wraith's types from wraith.hpp
        const own: Salamander.ZigOptions.With = .{ .name = "wraith", .folder = paths.api };
        const folder = options.schemas orelse if (options.depends.len > 0) options.depends[0].folder else null;
        if (folder) |dir| {
            const rest = if (options.schemas != null) options.depends else options.depends[1..];
            const global_uses = b.allocator.alloc([]const u8, options.depends.len + 1) catch @panic("OOM");
            const file_namespaces = b.allocator.alloc([]const u8, options.depends.len) catch @panic("OOM");
            global_uses[0] = "Wraith";
            for (options.depends, global_uses[1..], file_namespaces) |d, *u, *f| {
                u.* = namespaceOf(b, d.name);
                f.* = b.fmt("{s}/={s}", .{ d.name, u.* });
            }
            module.addIncludePath(Salamander.cppHeaders(salamander, .{
                .folder = dir,
                .target = options.target,
                .name = "schema.hpp",
                .uses = &.{"wraith"},
                .global_uses = global_uses,
                .namespace = namespaceOf(b, options.name),
                .file_namespaces = file_namespaces,
                .instances = &.{instance_tag},
                .with = std.mem.concat(b.allocator, Salamander.ZigOptions.With, &.{ &.{own}, rest }) catch @panic("OOM"),
                .aliases = &.{.{ .prefix = "wraith/", .include = "wraith.hpp" }},
            }));
        }
        return module;
    }

    /// The one tests run on.
    pub fn main(self: Plugin) Arch {
        return self.arches[0];
    }

    /// `make` runs once per arch, for things like C libraries built for each.
    pub fn linkLibrary(self: Plugin, b: *std.Build, make: *const fn (*std.Build, std.Build.ResolvedTarget) *std.Build.Step.Compile) void {
        for (self.arches) |arch| arch.mod.linkLibrary(make(b, arch.target));
    }

    /// Installs the DLLs, manifest and schemas directly in the prefix.
    pub fn install(self: Plugin, b: *std.Build) void {
        for (self.arches) |arch| b.getInstallStep().dependOn(&b.addInstallArtifact(arch.lib, .{
            .dest_dir = .{ .override = .prefix },
            .implib_dir = .disabled,
        }).step);
        b.getInstallStep().dependOn(&b.addInstallFile(packaged(b, self.manifest), "wraith.json").step);
        if (self.schemas) |dir| b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = dir,
            .install_dir = .prefix,
            .install_subdir = "schemas",
            .include_extensions = &.{".sal"},
        }).step);
        for (picturesOf(b)) |path| b.getInstallStep().dependOn(&b.addInstallFile(b.path(path), path).step);
    }

    /// `manifest` as packaged: no `devDepends`, and `descriptionFile` inlined as `description`.
    fn packaged(b: *std.Build, manifest: std.Build.LazyPath) std.Build.LazyPath {
        if (manifest != .src_path) return manifest;
        const sp = manifest.src_path;
        const io = b.graph.io;
        var dir = sp.owner.root.openDir(io, std.fs.path.dirname(sp.sub_path) orelse ".", .{}) catch return manifest;
        defer dir.close(io);
        const text = dir.readFileAlloc(io, std.fs.path.basename(sp.sub_path), b.allocator, .limited(1 << 20)) catch return manifest;
        // Configure runs again when they change, as this reads them then
        sp.owner.dependOnFileContents(manifest);
        const m = core_manifest.parse(b.allocator, text, null) catch |err| std.debug.panic("invalid wraith.json: {t}", .{err});
        switch (m.apiFit()) {
            .yes => {},
            .outdated => std.debug.panic("wraith.json needs \"apiVersion\": {d}, the version of Wraith's API it's made for. Wraith won't load it without one", .{core_manifest.api_version}),
            .newer => std.debug.panic("wraith.json's apiVersion {d} is newer than this Wraith's, {d}", .{ m.apiVersion.?, core_manifest.api_version }),
        }
        if (m.descriptionFile) |file| sp.owner.dependOnFileContents(sp.owner.path(sp.owner.pathJoin(&.{ std.fs.path.dirname(sp.sub_path) orelse ".", file })));
        const stripped = (core_manifest.packaged(b.allocator, io, dir, text) catch |err| switch (err) {
            error.BothDescriptions => std.debug.panic("wraith.json has description and descriptionFile. Keep one", .{}),
            error.DescriptionFile => std.debug.panic("wraith.json's descriptionFile {s} can't be read", .{m.descriptionFile.?}),
            else => std.debug.panic("invalid wraith.json: {t}", .{err}),
        }) orelse return manifest;
        return b.addWriteFiles().add("wraith.json", stripped);
    }

    /// The icon and images its wraith.json names, beside it, so they're in the package for the hub.
    fn picturesOf(b: *std.Build) []const []const u8 {
        const io = b.graph.io;
        var root = b.root.openDir(io, ".", .{}) catch return &.{};
        defer root.close(io);
        const source = root.readFileAlloc(io, "wraith.json", b.allocator, .limited(64 << 10)) catch return &.{};
        const manifest = std.json.parseFromSliceLeaky(struct {
            icon: ?[]const u8 = null,
            images: []const []const u8 = &.{},
        }, b.allocator, source, .{ .ignore_unknown_fields = true }) catch |err| std.debug.panic("invalid wraith.json: {t}", .{err});
        var out: std.ArrayList([]const u8) = .empty;
        if (manifest.icon) |icon| out.append(b.allocator, icon) catch @panic("OOM");
        out.appendSlice(b.allocator, manifest.images) catch @panic("OOM");
        for (out.items) |path| root.access(io, path, .{}) catch std.debug.panic("wraith.json names {s}, but it's not there", .{path});
        return out.items;
    }

    /// Its dependencies, found like `wraith sdk deps` does. Their schemas go in its `schema` import.
    fn dependsOf(b: *std.Build) []const Salamander.ZigOptions.With {
        const io = b.graph.io;
        const root = b.root.joinString(b.allocator, ".") catch @panic("OOM");
        const list = core_deps.listed(b.allocator, io, root) catch |err| std.debug.panic("invalid wraith.json: {t}", .{err});
        const env = &b.graph.environ_map;
        const locations: ?Locations = Locations.init(b.allocator, .{ .root_override = env.get("WRAITH_ROOT"), .local_app_data = env.get("LOCALAPPDATA") }) catch null;
        const places: core_deps.Places = .{
            .root = root,
            .mods = if (locations) |l| l.mods else null,
            .cache = if (locations) |l| std.fs.path.join(b.allocator, &.{ l.root, "cache", "deps" }) catch @panic("OOM") else null,
        };
        var out: std.ArrayList(Salamander.ZigOptions.With) = .empty;
        for (list.depends) |dep| {
            const pinned = !list.paths.map.contains(dep.name) and for (b.available_deps) |d| {
                if (std.mem.eql(u8, d[0], dep.name)) break true;
            } else false;
            if (pinned) {
                const pkg = b.dependency(dep.name, .{});
                var dir = pkg.builder.root.openDir(io, "schemas", .{}) catch continue;
                dir.close(io);
                out.append(b.allocator, .{ .name = dep.name, .folder = pkg.path("schemas") }) catch @panic("OOM");
                continue;
            }
            const found = (core_deps.find(b.allocator, io, places, list, dep) catch @panic("OOM")) orelse std.debug.panic(
                \\wraith.json depends on {s}{s}{s}, but there's no copy that'll do. For one you're working on, point
                \\  "devDepends": {{ "{s}": "../{s}" }}
                \\at its folder. Otherwise `wraith sdk deps` downloads it from the hub.
            , .{ dep.name, if (dep.min != null) " " else "", dep.min orelse "", dep.name, dep.name });
            // Configure runs again when it changes, like a new version
            b.dependOnFileContents(.{ .cwd_relative = std.fs.path.join(b.allocator, &.{ found.dir, "wraith.json" }) catch @panic("OOM") });
            const schemas = std.fs.path.join(b.allocator, &.{ found.dir, "schemas" }) catch @panic("OOM");
            var dir = std.Io.Dir.cwd().openDir(io, schemas, .{}) catch continue;
            dir.close(io);
            out.append(b.allocator, .{ .name = dep.name, .folder = .{ .cwd_relative = schemas } }) catch @panic("OOM");
        }
        return out.items;
    }

    /// Both, unless the project's wraith.json lists its arches.
    fn targetsOf(b: *std.Build, target: std.Build.ResolvedTarget) []const std.Build.ResolvedTarget {
        if (!target.query.isNative()) return b.allocator.dupe(std.Build.ResolvedTarget, &.{target}) catch @panic("OOM");
        const manifest = "wraith.json";
        // Configure runs again when it changes
        b.dependOnFileContents(b.path(manifest));
        const io = b.graph.io;
        var root = b.root.openDir(io, ".", .{}) catch |err| std.debug.panic("failed to open the build root: {t}", .{err});
        defer root.close(io);
        const both: []const []const u8 = &.{ "x64", "x86" };
        const listed = readArches(b, root, manifest) orelse both;
        var out: std.ArrayList(std.Build.ResolvedTarget) = .empty;
        for (listed) |arch| {
            const t = b.resolveTargetQuery(.{
                .cpu_arch = if (std.mem.eql(u8, arch, "x86")) .x86 else .x86_64,
                .os_tag = .windows,
                .abi = target.result.abi,
            });
            // The native one first
            if (t.result.cpu.arch == target.result.cpu.arch) out.insert(b.allocator, 0, t) catch @panic("OOM") else out.append(b.allocator, t) catch @panic("OOM");
        }
        return out.items;
    }

    /// What plugins build against: the SDK, and Wraith's schemas with their Zig.
    pub const Sdk = struct {
        sdk: *std.Build.Module,
        api_zig: *std.Build.Module,
        schemas: std.Build.LazyPath,

        fn of(wraith: *std.Build.Dependency) Sdk {
            return .{ .sdk = wraith.module("wraith_sdk"), .api_zig = wraith.module("wraith_api_zig"), .schemas = wraith.path("src/api/schemas") };
        }
    };

    /// Its id in PascalCase, the namespace its schemas are in.
    fn namespaceOf(b: *std.Build, id: []const u8) []const u8 {
        var buf: [core_manifest.namespace_max]u8 = undefined;
        return b.dupe(core_manifest.namespaceOf(&buf, id));
    }

    fn create(b: *std.Build, wraith: Sdk, salamander: *std.Build.Dependency, options: Options, depends: []const Salamander.ZigOptions.With) Arch {
        const sdk = wraith.sdk;
        const module = b.createModule(.{
            .root_source_file = options.root_source_file,
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{.{ .name = "wraith_sdk", .module = sdk }},
        });
        // Wraith's own types are in scope like they are for scripts, and they're the SDK's
        const own: Salamander.ZigOptions.With = .{ .name = "wraith", .folder = wraith.schemas };
        const aliases: []const Salamander.ZigOptions.Alias = &.{.{ .prefix = "wraith/", .name = "wraith_api_zig", .module = wraith.api_zig }};
        const schemas = options.schemas orelse findSchemas(options.root_source_file);
        // Without any of its own, the first dependency's folder stands in
        const folder = schemas orelse if (depends.len > 0) depends[0].folder else null;
        if (folder) |dir| {
            const rest = if (schemas != null) depends else depends[1..];
            const with = std.mem.concat(b.allocator, Salamander.ZigOptions.With, &.{ &.{own}, rest }) catch @panic("OOM");
            // Its own files are in its namespace and each dependency's in theirs, as Wraith reads them
            const global_uses = b.allocator.alloc([]const u8, depends.len + 1) catch @panic("OOM");
            const file_namespaces = b.allocator.alloc([]const u8, depends.len) catch @panic("OOM");
            global_uses[0] = "Wraith";
            for (depends, global_uses[1..], file_namespaces) |d, *u, *f| {
                u.* = namespaceOf(b, d.name);
                f.* = b.fmt("{s}/={s}", .{ d.name, u.* });
            }
            module.addImport(options.schema_import, Salamander.zigModule(salamander, .{
                .folder = dir,
                .target = options.target,
                .uses = &.{"wraith"},
                .global_uses = global_uses,
                .namespace = namespaceOf(b, options.name),
                .file_namespaces = file_namespaces,
                .instances = &.{instance_tag},
                .with = with,
                .aliases = aliases,
            }));
        }
        const arch = if (options.target.result.cpu.arch == .x86) "x86" else "x64";
        return .{
            .target = options.target,
            .lib = b.addLibrary(.{ .name = b.fmt("wraith_{s}_{s}", .{ options.name, arch }), .linkage = .dynamic, .root_module = module }),
            .mod = module,
            .sdk = sdk,
        };
    }

    fn findSchemas(root: std.Build.LazyPath) ?std.Build.LazyPath {
        if (root != .src_path) return null;
        const sp = root.src_path;
        const io = sp.owner.graph.io;
        const near = if (std.fs.path.dirname(sp.sub_path)) |d| sp.owner.fmt("{s}/schemas", .{d}) else "schemas";
        // Configure runs again when a schemas folder turns up or goes
        for ([_][]const u8{ near, "schemas" }) |sub| sp.owner.dependOnDirectoryMetadata(sp.owner.path(std.fs.path.dirname(sub) orelse "."));
        for ([_][]const u8{ near, "schemas" }) |sub| {
            var dir = sp.owner.root.openDir(io, sub, .{}) catch continue;
            dir.close(io);
            return sp.owner.path(sub);
        }
        return null;
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_step = b.step("test", "Run tests");
    const build_test_step = b.step("build-test", "Build tests without running");

    // Dependents import these as wraith_<name>
    const main = Modules.init(b, target, optimize, .exported);
    main.addTests(test_step, build_test_step);

    // Only for dev. Imports every CE table under a folder and says how it went
    {
        const survey = b.addExecutable(.{
            .name = "ce-survey",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/importer/survey.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "wraith_importer", .module = main.importer },
                    .{ .name = "wraith_api", .module = main.api },
                    // To compile each Lua part the way the provider would
                    .{ .name = "lua", .module = engine(b, target, optimize, "lua") },
                },
            }),
        });
        const run_survey = b.addRunArtifact(survey);
        run_survey.addPassthruArgs();
        b.step("ce-survey", "Import every Cheat Engine table under D:\\Modding, or a folder after --").dependOn(&run_survey.step);
    }
    {
        const gen = b.addExecutable(.{
            .name = "imgui-sal",
            .root_module = b.createModule(.{ .root_source_file = b.path("src/api/imgui_sal.zig"), .target = b.graph.host }),
        });
        const run_gen = b.addRunArtifact(gen);
        const tuft = b.dependency("tuft", .{ .target = target, .optimize = optimize });
        run_gen.addFileArg(tuft.builder.dependency("dear_bindings", .{}).path("dcimgui.json"));
        run_gen.setCwd(b.path("."));
        run_gen.addArg("src/api/schemas/imgui.sal");
        b.step("imgui-sal", "Write src/api/schemas/imgui.sal from dear_bindings' dcimgui.json").dependOn(&run_gen.step);
    }
    // The API as one .sal, and as JSON with its docs, layouts and how each language writes it, for the docs
    // site and tools. Spelled like the SDKs. Releases put them beside the zip
    {
        const salamander = b.dependency("salamander", .{ .target = target, .optimize = optimize });
        const json = Salamander.jsonFile(salamander, .{
            .folder = b.path("src/api/schemas"),
            .name = "wraith.json",
            .uses = &.{"wraith"},
            .global_uses = &.{"Wraith"},
            .instances = &.{"wraith.Instance=Sig"},
            // C#'s, see cli/sdk/cs.zig. The rest have their own namespaces already
            .lang_namespace = "Wraith",
            .class = "Constants",
        });
        const step = b.step("api", "Write the API to zig-out/api, as wraith.sal and wraith.json");
        step.dependOn(&b.addInstallFile(json, "api/wraith.json").step);
        step.dependOn(&b.addInstallFile(Salamander.bundle(salamander, b.path("src/api/schemas")), "api/wraith.sal").step);
    }

    const test_options = b.addOptions();
    for ([_][]const u8{ "fixture", "failing", "drawing", "aot" }) |name| {
        const lib = addDll(b, name, b.path(b.fmt("src/runtime/testing/{s}_plugin.zig", .{name})), main);
        test_options.addOptionPath(b.fmt("{s}_plugin", .{name}), lib.getEmittedBin());
    }
    // Not a Wraith plugin, for loading one where a plugin's expected
    test_options.addOptionPath("foreign_dll", b.addLibrary(.{
        .name = "wraith_foreign",
        .linkage = .dynamic,
        .root_module = b.createModule(.{ .root_source_file = b.path("src/runtime/testing/foreign.zig"), .target = target, .optimize = optimize }),
    }).getEmittedBin());
    test_options.addOptionPath("crashhandler", addCrashHandler(b, main).getEmittedBin());
    // A C one, made like `Plugin.initC` makes them
    test_options.addOptionPath("c_plugin", b.addLibrary(.{
        .name = b.fmt("wraith_c_fixture_{s}", .{Plugin.archName(target)}),
        .linkage = .dynamic,
        .root_module = Plugin.cModule(b, b.dependency("salamander", .{ .target = target, .optimize = optimize }), .{ .api = b.path("src/api/schemas"), .include = b.path("src/sdk/c") }, .{
            .name = "c_fixture",
            .root = b.path("src/runtime/testing"),
            .sources = &.{"c_plugin.c"},
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Wpedantic", "-Werror" },
            .target = target,
            .optimize = optimize,
            .schemas = b.path("src/runtime/testing/c_schemas"),
            .depends = &.{.{ .name = "fixture", .folder = b.path("src/runtime/testing/schemas") }},
        }),
    }).getEmittedBin());
    // And a C++ one, made like `Plugin.initCpp` makes them
    test_options.addOptionPath("cpp_plugin", b.addLibrary(.{
        .name = b.fmt("wraith_cpp_fixture_{s}", .{Plugin.archName(target)}),
        .linkage = .dynamic,
        .root_module = Plugin.cppModule(b, b.dependency("salamander", .{ .target = target, .optimize = optimize }), .{ .api = b.path("src/api/schemas"), .include = b.path("src/sdk/cpp") }, .{
            .name = "cpp_fixture",
            .root = b.path("src/runtime/testing"),
            .sources = &.{"cpp_plugin.cpp"},
            .flags = &.{ "-std=c++20", "-Wall", "-Wextra", "-Wno-missing-field-initializers", "-Werror" },
            .target = target,
            .optimize = optimize,
            .schemas = b.path("src/runtime/testing/cpp_schemas"),
            .depends = &.{.{ .name = "fixture", .folder = b.path("src/runtime/testing/schemas") }},
        }),
    }).getEmittedBin());
    addCsPlugin(b, main, test_options);
    addRustPlugin(b, main, test_options);
    main.runtime.addOptions("test_options", test_options);
    {
        const tests = b.addTest(.{ .name = "wraith_crashhandler_tests", .root_module = crashHandlerModule(b, main) });
        test_step.dependOn(&b.addRunArtifact(tests).step);
        build_test_step.dependOn(&b.addInstallArtifact(tests, .{}).step);
    }

    const install_abi: std.Target.Abi = if (target.result.abi == .msvc) .msvc else .gnu;
    // In bin/ next to the exe, since that's what gets packaged
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("LICENSE"), "bin/licenses/wraith.txt").step);
    b.getInstallStep().dependOn(&b.addInstallFile(b.path("THIRD_PARTY_NOTICES.md"), "bin/licenses/THIRD_PARTY_NOTICES.md").step);
    for (installed_arches) |a| {
        const arch_target = b.resolveTargetQuery(.{ .cpu_arch = a.cpu, .os_tag = .windows, .abi = install_abi });
        const mods = Modules.init(b, arch_target, optimize, .private);

        const bootstrap = b.addLibrary(.{ .name = b.fmt("wraith_bootstrap_{s}", .{a.dir}), .linkage = .dynamic, .root_module = mods.bootstrap });
        addResources(b, bootstrap, .{ .description = "Wraith bootstrap" });
        if (a.cpu == .x86) bootstrap.root_module.addObjectFile(b.path("src/bootstrap/x86.def"));
        b.getInstallStep().dependOn(&b.addInstallArtifact(bootstrap, .{
            .dest_dir = .{ .override = .{ .custom = "bin" } },
            .implib_dir = .disabled,
        }).step);

        for (proxy_info.proxies, mods.proxies) |p, module| {
            const lib = b.addLibrary(.{ .name = b.fmt("wraith_{s}_{s}", .{ p.dll, a.dir }), .linkage = .dynamic, .root_module = module });
            // Keeps Windows' ordinals on its exports
            @import("tuft").addProxyDef(mods.tuft, lib, p.dll);
            addResources(b, lib, .{ .description = b.fmt("Wraith {s} proxy", .{p.dll}) });
            b.getInstallStep().dependOn(&b.addInstallArtifact(lib, .{
                .dest_dir = .{ .override = .{ .custom = b.fmt("bin/{s}", .{proxy_info.dir}) } },
                .implib_dir = .disabled,
            }).step);
        }

        const runtime = b.addLibrary(.{ .name = b.fmt("wraith_runtime_{s}", .{a.dir}), .linkage = .dynamic, .root_module = mods.runtime });
        addResources(b, runtime, .{ .description = "Wraith runtime" });
        b.getInstallStep().dependOn(&b.addInstallArtifact(runtime, .{
            .dest_dir = .{ .override = .{ .custom = "bin" } },
            .implib_dir = .disabled,
        }).step);

        // In crash/ beside the runtime, which runs the one for its arch when the game crashes
        const crash_handler = addCrashHandler(b, mods);
        addResources(b, crash_handler, .{ .description = "Wraith crash handler" });
        b.getInstallStep().dependOn(&b.addInstallArtifact(crash_handler, .{ .dest_dir = .{ .override = .{ .custom = "bin/crash" } } }).step);

        if (a.cpu == .x86_64) {
            const cli = b.addExecutable(.{ .name = "wraith", .root_module = mods.cli });
            addResources(b, cli, .{ .description = "Wraith launcher", .manifest = b.path("src/cli/wraith.manifest") });
            b.installArtifact(cli);

            const run_cli = b.addRunArtifact(cli);
            run_cli.step.dependOn(b.getInstallStep());
            run_cli.addPassthruArgs();
            b.step("run", "Run the wraith launcher").dependOn(&run_cli.step);
        }
    }
}

const installed_arches = [_]struct { dir: []const u8, cpu: std.Target.Cpu.Arch }{
    .{ .dir = "x64", .cpu = .x86_64 },
    .{ .dir = "x86", .cpu = .x86 },
};

/// The C# plugin the `cs` tests load. Only built with `-Dcs-tests` (needs dotnet); else tests skip.
fn addCsPlugin(b: *std.Build, mods: Modules, options: *std.Build.Step.Options) void {
    const wanted = b.option(bool, "cs-tests", "Build a C# plugin with the dotnet SDK for the cs kind's tests") orelse false;
    const dotnet = (if (wanted) b.findProgram(.{ .names = &.{"dotnet"} }) else null) orelse {
        if (wanted) std.debug.panic("-Dcs-tests needs the dotnet SDK on PATH", .{});
        options.addOption([]const u8, "cs_plugin", "");
        return;
    };
    const folder = "src/runtime/testing/cs_plugin";
    const cli = b.addExecutable(.{ .name = "wraith-cs-sdk", .root_module = mods.cli });
    const gen = b.addRunArtifact(cli);
    gen.setCwd(b.path(folder));
    gen.addArgs(&.{ "sdk", "cs", "types", "--out" });
    const sdk_cs = gen.addOutputDirectoryArg("cs");
    gen.addFileInput(b.path(folder ++ "/wraith.json"));
    gen.addFileInput(b.path(folder ++ "/schemas/cs.sal"));
    // It lists what it wrote on stderr, which zig would show as a failed command
    _ = gen.captureStdOut(.{});
    _ = gen.captureStdErr(.{});

    const run = b.addSystemCommand(&.{ dotnet, "build" });
    run.addFileArg(b.path(folder ++ "/CsFixture.csproj"));
    run.addArgs(&.{ "--nologo", "-v", "quiet", "-clp:ErrorsOnly;NoSummary", "-c", "Release", "-o" });
    const out = run.addOutputDirectoryArg("cs_plugin");
    // Keeps obj out of the source tree
    run.addArg("--artifacts-path");
    _ = run.addOutputDirectoryArg("artifacts");
    run.addPrefixedDirectoryArg("-p:WraithCs=", sdk_cs);
    run.addFileInput(b.path(folder ++ "/Plugin.cs"));
    run.setEnvironmentVariable("DOTNET_CLI_TELEMETRY_OPTOUT", "1");
    run.setEnvironmentVariable("DOTNET_NOLOGO", "1");
    // dotnet writes its errors to stdout
    run.stdio = .inherit;
    options.addOptionPath("cs_plugin", out.path(b, "wraith_cs_fixture.dll"));
}

/// The Rust plugin the loader's tests load, built by cargo over what `sdk rust types` writes, like a Rust
/// plugin is. Only for this machine, and only in a root build with cargo on PATH; else the tests skip.
fn addRustPlugin(b: *std.Build, mods: Modules, options: *std.Build.Step.Options) void {
    const host = b.graph.host.result;
    const native = mods.target.result.cpu.arch == host.cpu.arch and mods.target.result.os.tag == host.os.tag;
    const cargo = (if (b.isRoot() and native) b.findProgram(.{ .names = &.{"cargo"} }) else null) orelse {
        options.addOption([]const u8, "rust_plugin", "");
        return;
    };
    const folder = "src/runtime/testing/rust_plugin";
    const cli = b.addExecutable(.{ .name = "wraith-rust-sdk", .root_module = mods.cli });
    const gen = b.addRunArtifact(cli);
    gen.setCwd(b.path(folder));
    gen.addArgs(&.{ "sdk", "rust", "types", "--offline", "--out" });
    const sdk_rust = gen.addOutputDirectoryArg("rust");
    gen.addFileInput(b.path(folder ++ "/wraith.json"));
    gen.addFileInput(b.path(folder ++ "/schemas/rust.sal"));
    // It lists what it wrote on stderr, which zig would show as a failed command
    _ = gen.captureStdOut(.{});
    _ = gen.captureStdErr(.{});

    // The crate as a plugin's folder has it, with what sdk rust types wrote in .wraith/rust
    const files = b.addWriteFiles();
    _ = files.addCopyFile(b.path(folder ++ "/Cargo.toml"), "Cargo.toml");
    _ = files.addCopyFile(b.path(folder ++ "/src/lib.rs"), "src/lib.rs");
    _ = files.addCopyDirectory(sdk_rust, ".wraith/rust", .{});
    const run = b.addSystemCommand(&.{ cargo, "build", "--release", "--quiet", "--manifest-path" });
    run.addFileArg(files.getDirectory().path(b, "Cargo.toml"));
    run.addArg("--target-dir");
    const out = run.addOutputDirectoryArg("target");
    run.stdio = .inherit;
    options.addOptionPath("rust_plugin", out.path(b, "release/rust_fixture.dll"));
}

fn addCrashHandler(b: *std.Build, mods: Modules) *std.Build.Step.Compile {
    const arch = if (mods.target.result.cpu.arch == .x86) "x86" else "x64";
    return b.addExecutable(.{ .name = b.fmt("wraith_crashhandler_{s}", .{arch}), .root_module = crashHandlerModule(b, mods) });
}

fn crashHandlerModule(b: *std.Build, mods: Modules) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/crashhandler/main.zig"),
        .target = mods.target,
        .optimize = mods.optimize,
        .imports = &.{.{ .name = "tuft_sys", .module = mods.tuft.module("tuft_sys") }},
    });
}

/// A plugin DLL for tests, built with the SDK like any plugin.
fn addDll(b: *std.Build, name: []const u8, root: std.Build.LazyPath, mods: Modules) *std.Build.Step.Compile {
    const arch = if (mods.target.result.cpu.arch == .x86) "x86" else "x64";
    return b.addLibrary(.{
        .name = b.fmt("wraith_{s}_{s}", .{ name, arch }),
        .linkage = .dynamic,
        .root_module = Plugin.create(b, .{ .sdk = mods.sdk, .api_zig = mods.api_zig, .schemas = b.path("src/api/schemas") }, b.dependency("salamander", .{ .target = mods.target, .optimize = mods.optimize }), .{
            .name = name,
            .root_source_file = root,
            .target = mods.target,
            .optimize = mods.optimize,
        }, &.{}).mod,
    });
}

/// QuickJS and Lua come from salamander, so there's only ever one of each. `name` is `quickjs` or `lua`.
fn engine(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, comptime name: []const u8) *std.Build.Module {
    return b.dependency("salamander", .{ .target = target, .optimize = optimize }).module(name);
}

/// Null if it's not there or lists none.
fn readArches(b: *std.Build, dir: std.Io.Dir, path: []const u8) ?[]const []const u8 {
    const io = b.graph.io;
    const source = dir.readFileAlloc(io, path, b.allocator, .limited(64 << 10)) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => std.debug.panic("failed to read {s}: {t}", .{ path, err }),
    };
    const Arch = enum { x86, x64 };
    const manifest = std.json.parseFromSliceLeaky(struct {
        arches: ?[]const Arch = null,
    }, b.allocator, source, .{ .ignore_unknown_fields = true }) catch |err| std.debug.panic("invalid {s}: {t}", .{ path, err });
    const arches = manifest.arches orelse return null;
    const names = b.allocator.alloc([]const u8, arches.len) catch @panic("OOM");
    for (arches, names) |a, *n| n.* = @tagName(a);
    return names;
}

const Modules = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    platform: *std.Build.Module,
    ui: *std.Build.Module,
    api: *std.Build.Module,
    /// Wraith's schemas as Zig, which plugins' schemas take Wraith's types from.
    api_zig: *std.Build.Module,
    sdk: *std.Build.Module,
    runtime: *std.Build.Module,
    bootstrap: *std.Build.Module,
    proxies: [proxy_info.proxies.len]*std.Build.Module,
    game: *std.Build.Module,
    registry: *std.Build.Module,
    importer: *std.Build.Module,
    cli: *std.Build.Module,
    tuft: *std.Build.Dependency,

    const Visibility = enum {
        exported,
        private,
    };

    fn init(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, visibility: Visibility) Modules {
        const f: Factory = .{ .b = b, .target = target, .optimize = optimize, .visibility = visibility };

        const tuft = b.dependency("tuft", .{ .target = target, .optimize = optimize });
        const salamander_dep = b.dependency("salamander", .{ .target = target, .optimize = optimize });
        const salamander = salamander_dep.module("salamander_runtime");

        const core = f.module("core", "src/core/root.zig", &.{
            .{ .name = "tuft_arch", .module = tuft.module("tuft_arch") },
            .{ .name = "tuft_sys", .module = tuft.module("tuft_sys") },
            .{ .name = "tuft_event", .module = tuft.module("tuft_event") },
            .{ .name = "tuft_text", .module = tuft.module("tuft_text") },
        }, false);

        const platform = f.module("platform", "src/platform/root.zig", &.{
            .{ .name = "wraith_core", .module = core },
            .{ .name = "tuft_arch", .module = tuft.module("tuft_arch") },
            .{ .name = "tuft_input", .module = tuft.module("tuft_input") },
            .{ .name = "tuft_sys", .module = tuft.module("tuft_sys") },
        }, false);

        // Doesn't link ImGui. The runtime binds it, everyone else uses function pointers.
        const ui = f.module("ui", "src/ui/root.zig", &.{
            .{ .name = "tuft_ui", .module = tuft.module("tuft_ui") },
        }, false);

        const api = f.module("api", "src/api/root.zig", &.{
            .{ .name = "salamander_runtime", .module = salamander },
            .{ .name = "salamander_schema", .module = salamander_dep.module("salamander_schema") },
            .{ .name = "wraith_core", .module = core },
            .{ .name = "wraith_platform", .module = platform },
            .{ .name = "tuft_arch", .module = tuft.module("tuft_arch") },
            .{ .name = "tuft_text", .module = tuft.module("tuft_text") },
        }, false);

        // Wraith's API, every file in `src/api/schemas` as one schema
        api.addAnonymousImport("wraith.sal", .{ .root_source_file = @import("salamander").bundle(salamander_dep, b.path("src/api/schemas")) });
        // And as Zig with real methods, per target pointer size. Maths types are tuft's
        const math_alias = b.createModule(.{ .root_source_file = b.path("src/api/math_alias.zig"), .imports = &.{.{ .name = "tuft_math", .module = tuft.module("tuft_math") }} });
        const api_zig = @import("salamander").zigModule(salamander_dep, .{
            .folder = b.path("src/api/schemas"),
            .target = target,
            .aliases = &.{.{ .prefix = "math.sal", .name = "wraith_math", .module = math_alias }},
        });
        api.addImport("wraith_api_zig", api_zig);
        // Plugins' schemas take Wraith's types from it, so they're the SDK's own
        if (visibility == .exported) b.modules.put(b.graph.arena, "wraith_api_zig", api_zig) catch @panic("OOM");

        const sdk = f.module("sdk", "src/sdk/root.zig", &.{
            .{ .name = "salamander_runtime", .module = salamander },
            .{ .name = "wraith_api", .module = api },
            .{ .name = "wraith_core", .module = core },
            .{ .name = "wraith_platform", .module = platform },
            .{ .name = "wraith_ui", .module = ui },
            .{ .name = "tuft_arch", .module = tuft.module("tuft_arch") },
            .{ .name = "tuft_mem", .module = tuft.module("tuft_mem") },
            .{ .name = "tuft_hook", .module = tuft.module("tuft_hook") },
            .{ .name = "tuft_asm", .module = tuft.module("tuft_asm") },
            .{ .name = "tuft_sys", .module = tuft.module("tuft_sys") },
            .{ .name = "tuft_image", .module = tuft.module("tuft_image") },
            .{ .name = "tuft_math", .module = tuft.module("tuft_math") },
        }, false);

        const game = f.module("game", "src/game/root.zig", &.{
            .{ .name = "wraith_core", .module = core },
            .{ .name = "wraith_platform", .module = platform },
            .{ .name = "tuft_sys", .module = tuft.module("tuft_sys") },
            .{ .name = "tuft_inject", .module = tuft.module("tuft_inject") },
            // Only listing games uses it, so it's left out of the runtime, which only identifies one
            .{ .name = "sqlite", .module = sqlite.cApi(b, target, optimize) },
        }, false);

        const registry = f.module("registry", "src/registry/root.zig", &.{
            .{ .name = "wraith_core", .module = core },
        }, false);

        // Other tools' files to projects, for the CLI and the Workbench
        const importer = f.module("importer", "src/importer/root.zig", &.{
            .{ .name = "wraith_api", .module = api },
            .{ .name = "tuft_asm", .module = tuft.module("tuft_asm") },
        }, false);

        const runtime = f.module("runtime", "src/runtime/root.zig", &.{
            .{ .name = "wraith_importer", .module = importer },
            .{ .name = "wraith_core", .module = core },
            .{ .name = "wraith_platform", .module = platform },
            .{ .name = "wraith_game", .module = game },
            .{ .name = "wraith_registry", .module = registry },
            .{ .name = "wraith_ui", .module = ui },
            .{ .name = "wraith_api", .module = api },
            .{ .name = "wraith_sdk", .module = sdk },
            .{ .name = "salamander_runtime", .module = salamander },
            .{ .name = "salamander_hosts", .module = salamander_dep.module("salamander_hosts") },
            .{ .name = "salamander_schema", .module = salamander_dep.module("salamander_schema") },
            .{ .name = "salamander_bind", .module = salamander_dep.module("salamander_bind") },
            .{ .name = "tuft_arch", .module = tuft.module("tuft_arch") },
            .{ .name = "tuft_sys", .module = tuft.module("tuft_sys") },
            .{ .name = "tuft_mem", .module = tuft.module("tuft_mem") },
            .{ .name = "tuft_hook", .module = tuft.module("tuft_hook") },
            .{ .name = "tuft_window", .module = tuft.module("tuft_window") },
            .{ .name = "tuft_gfx", .module = tuft.module("tuft_gfx") },
            .{ .name = "tuft_imgui", .module = tuft.module("tuft_imgui") },
            .{ .name = "tuft_devtools", .module = tuft.module("tuft_devtools") },
            .{ .name = "tuft_schema", .module = tuft.module("tuft_schema") },
            .{ .name = "tuft_asm", .module = tuft.module("tuft_asm") },
            .{ .name = "tuft_input", .module = tuft.module("tuft_input") },
            .{ .name = "tuft_event", .module = tuft.module("tuft_event") },
            .{ .name = "tuft_text", .module = tuft.module("tuft_text") },
            .{ .name = "tuft_image", .module = tuft.module("tuft_image") },
            .{ .name = "tuft_vfs", .module = tuft.module("tuft_vfs") },
            .{ .name = "tuft_managed", .module = tuft.module("tuft_managed") },
            .{ .name = "tuft_math", .module = tuft.module("tuft_math") },
        }, true);
        // The fixture plugin's schema as generated Zig, so loader tests can call into it
        runtime.addImport("wraith_test_fixture", @import("salamander").zigModule(salamander_dep, .{ .source = b.path("src/runtime/testing/schemas/fixture.sal"), .target = target, .uses = &.{"wraith"}, .instances = &.{instance_tag} }));
        const build_info = b.addOptions();
        build_info.addOption([]const u8, "version", zon.version);
        runtime.addOptions("build_info", build_info);
        // For the overlay's About page
        runtime.addAnonymousImport("LICENSE", .{ .root_source_file = b.path("LICENSE") });
        runtime.addAnonymousImport("THIRD_PARTY_NOTICES.md", .{ .root_source_file = b.path("THIRD_PARTY_NOTICES.md") });

        const bootstrap = f.module("bootstrap", "src/bootstrap/root.zig", &.{
            .{ .name = "wraith_core", .module = core },
            .{ .name = "wraith_platform", .module = platform },
            .{ .name = "tuft_arch", .module = tuft.module("tuft_arch") },
            .{ .name = "tuft_sys", .module = tuft.module("tuft_sys") },
        }, true);

        const proxy_info_mod = b.createModule(.{ .root_source_file = b.path("src/proxy/info.zig"), .target = target, .optimize = optimize });

        var proxies: [proxy_info.proxies.len]*std.Build.Module = undefined;
        for (proxy_info.proxies, &proxies) |p, *module| {
            const options = b.addOptions();
            options.addOption([]const u8, "dll", p.dll);
            module.* = b.createModule(.{
                .root_source_file = b.path("src/proxy/dll.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "wraith_proxy_info", .module = proxy_info_mod },
                    .{ .name = "wraith_proxy_options", .module = options.createModule() },
                    .{ .name = "tuft_proxy", .module = tuft.module("tuft_proxy") },
                    .{ .name = "tuft_sys", .module = tuft.module("tuft_sys") },
                },
            });
        }
        const cli = f.module("cli", "src/cli/main.zig", &.{
            .{ .name = "wraith_importer", .module = importer },
            .{ .name = "wraith_core", .module = core },
            .{ .name = "wraith_game", .module = game },
            .{ .name = "wraith_platform", .module = platform },
            .{ .name = "wraith_registry", .module = registry },
            .{ .name = "wraith_proxy_info", .module = proxy_info_mod },
            .{ .name = "tuft_inject", .module = tuft.module("tuft_inject") },
            .{ .name = "tuft_arch", .module = tuft.module("tuft_arch") },
            .{ .name = "tuft_sys", .module = tuft.module("tuft_sys") },
            .{ .name = "wraith_api", .module = api },
            .{ .name = "salamander_schema", .module = salamander_dep.module("salamander_schema") },
            .{ .name = "salamander_types", .module = salamander_dep.module("salamander_types") },
            .{ .name = "salamander_cs", .module = salamander_dep.module("salamander_cs") },
            .{ .name = "salamander_rust", .module = salamander_dep.module("salamander_rust") },
            .{ .name = "salamander_c", .module = salamander_dep.module("salamander_c") },
            .{ .name = "salamander_cpp", .module = salamander_dep.module("salamander_cpp") },
        }, true);
        cli.addOptions("build_info", build_info);
        // The C# SDK's own code, which `sdk cs types` writes next to the generated API
        cli.addAnonymousImport("WraithPlugin.cs", .{ .root_source_file = b.path("src/sdk/cs/WraithPlugin.cs") });
        // And the Rust SDK's crate, which `sdk rust types` writes next to Wraith's API
        cli.addAnonymousImport("wraith_sdk.rs", .{ .root_source_file = b.path("src/sdk/rust/src/lib.rs") });
        cli.addAnonymousImport("wraith_sdk.toml", .{ .root_source_file = b.path("src/sdk/rust/Cargo.toml") });
        // And the C and C++ SDKs' headers, and the CMake module for building them
        cli.addAnonymousImport("wraith_plugin.h", .{ .root_source_file = b.path("src/sdk/c/wraith_plugin.h") });
        cli.addAnonymousImport("wraith_plugin.hpp", .{ .root_source_file = b.path("src/sdk/cpp/wraith_plugin.hpp") });
        cli.addAnonymousImport("wraith.cmake", .{ .root_source_file = b.path("src/sdk/cmake/wraith.cmake") });

        return .{ .b = b, .target = target, .optimize = optimize, .core = core, .platform = platform, .ui = ui, .api = api, .api_zig = api_zig, .sdk = sdk, .runtime = runtime, .bootstrap = bootstrap, .proxies = proxies, .game = game, .registry = registry, .importer = importer, .cli = cli, .tuft = tuft };
    }

    fn addTests(self: Modules, test_step: *std.Build.Step, build_test_step: *std.Build.Step) void {
        inline for (.{ "core", "platform", "ui", "api", "sdk", "runtime", "bootstrap", "game", "registry", "importer", "cli" }) |name| {
            const tests = self.b.addTest(.{ .name = "wraith_" ++ name ++ "_tests", .root_module = @field(self, name) });
            const run_artifact = self.b.addRunArtifact(tests);
            run_artifact.has_side_effects = true;
            test_step.dependOn(&run_artifact.step);
            build_test_step.dependOn(&self.b.addInstallArtifact(tests, .{}).step);
        }
    }

    const Factory = struct {
        b: *std.Build,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        visibility: Visibility,

        fn module(self: Factory, comptime name: []const u8, root: []const u8, imports: []const Import, link_libc: bool) *std.Build.Module {
            const options: std.Build.Module.CreateOptions = .{
                .root_source_file = self.b.path(root),
                .target = self.target,
                .optimize = self.optimize,
                .link_libc = if (link_libc) true else null,
                .imports = imports,
            };
            return switch (self.visibility) {
                .exported => self.b.addModule("wraith_" ++ name, options),
                .private => self.b.createModule(options),
            };
        }
    };
};

const Resources = struct {
    description: []const u8,
    /// Resource 1 for an exe, 2 for a DLL.
    manifest: ?std.Build.LazyPath = null,
};

/// Uses Zig's resinator. If Zig drops it, switch to the rc package.
fn addResources(b: *std.Build, artifact: *std.Build.Step.Compile, res: Resources) void {
    const ver = std.SemanticVersion.parse(zon.version) catch @panic("build.zig.zon: invalid .version");
    const is_dll = artifact.isDynamicLibrary();

    artifact.root_module.addWin32ResourceFile(.{
        .file = b.path("src/resources/version.rc"),
        .flags = &.{
            b.fmt("/DWRAITH_VER_NUM={d},{d},{d},0", .{ ver.major, ver.minor, ver.patch }),
            b.fmt("/DWRAITH_VER_STR=\"{d}.{d}.{d}.0\"", .{ ver.major, ver.minor, ver.patch }),
            b.fmt("/DWRAITH_FILE_TYPE={s}", .{if (is_dll) "VFT_DLL" else "VFT_APP"}),
            b.fmt("/DWRAITH_DESCRIPTION=\"{s}\"", .{res.description}),
            b.fmt("/DWRAITH_FILE_NAME=\"{s}\"", .{artifact.out_filename}),
        },
    });
    artifact.win32_manifest = res.manifest;
}

/// SQLite from its amalgamation, read-only use, for stores that keep their games in a database.
const sqlite = struct {
    const flags: []const []const u8 = &.{
        "-DSQLITE_DQS=0",
        "-DSQLITE_DEFAULT_MEMSTATUS=0",
        "-DSQLITE_OMIT_DEPRECATED",
        "-DSQLITE_OMIT_LOAD_EXTENSION",
        "-DSQLITE_OMIT_SHARED_CACHE",
        "-DSQLITE_OMIT_PROGRESS_CALLBACK",
        "-DSQLITE_USE_ALLOCA",
    };

    fn cApi(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
        const dep = b.dependency("sqlite", .{});
        const t = b.addTranslateC(.{ .root_source_file = dep.path("sqlite3.h"), .target = target, .optimize = optimize });
        const mod = t.createModule();
        const lib = b.addLibrary(.{
            .name = "sqlite",
            .linkage = .static,
            .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
        });
        lib.root_module.addCSourceFile(.{ .file = dep.path("sqlite3.c"), .flags = flags });
        mod.linkLibrary(lib);
        return mod;
    }
};
