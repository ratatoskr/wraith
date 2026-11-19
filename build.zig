const std = @import("std");
const zon = @import("build.zig.zon");
const Salamander = @import("salamander");

const Import = std.Build.Module.Import;

const proxy_info = @import("src/proxy/info.zig");

const wraith_build = @This();

/// Builds a Zig plugin's DLLs against the SDK, for plugins outside this repo.
/// Every arch its manifest's `.arches` lists, or both, side by side. With -Dtarget just that one.
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
        /// Its `.sal` files, as Zig with their game code's methods and statics. Null means schemas/
        /// next to root_source_file, or in the project root.
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
            arch.* = create(b, wraith.module("wraith_sdk"), salamander, for_arch, depends);
        }
        return .{
            .name = options.name,
            .manifest = options.manifest orelse b.path("wraith.json"),
            .schemas = options.schemas orelse findSchemas(options.root_source_file),
            .arches = arches,
        };
    }

    /// The one tests run on.
    pub fn main(self: Plugin) Arch {
        return self.arches[0];
    }

    /// `make` runs once per arch, for things like C libraries built for each.
    pub fn linkLibrary(self: Plugin, b: *std.Build, make: *const fn (*std.Build, std.Build.ResolvedTarget) *std.Build.Step.Compile) void {
        for (self.arches) |arch| arch.mod.linkLibrary(make(b, arch.target));
    }

    /// The DLLs, the manifest and its schemas, directly in the install prefix. Wraith reads the
    /// schemas as it loads the plugin, and plugins that depend on it build with them.
    pub fn install(self: Plugin, b: *std.Build) void {
        for (self.arches) |arch| b.getInstallStep().dependOn(&b.addInstallArtifact(arch.lib, .{
            .dest_dir = .{ .override = .prefix },
            .implib_dir = .disabled,
        }).step);
        b.getInstallStep().dependOn(&b.addInstallFile(self.manifest, "wraith.json").step);
        if (self.schemas) |dir| b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = dir,
            .install_dir = .prefix,
            .install_subdir = "schemas",
            .include_extensions = &.{".sal"},
        }).step);
    }

    /// The plugins its wraith.json depends on, each a package in build.zig.zon by the same name, like
    /// `zig fetch --save=freecam https://dist.wraith.io/hub/p/freecam/1.2.0.zip`, or a path to it.
    /// Their schemas go in its `schema` import.
    fn dependsOf(b: *std.Build) []const Salamander.ZigOptions.With {
        const io = b.graph.io;
        var root = b.root.openDir(io, ".", .{}) catch return &.{};
        defer root.close(io);
        const source = root.readFileAlloc(io, "wraith.json", b.allocator, .limited(64 << 10)) catch return &.{};
        const manifest = std.json.parseFromSliceLeaky(struct {
            depends: []const []const u8 = &.{},
        }, b.allocator, source, .{ .ignore_unknown_fields = true }) catch |err| std.debug.panic("invalid wraith.json: {t}", .{err});
        var out: std.ArrayList(Salamander.ZigOptions.With) = .empty;
        for (manifest.depends) |text| {
            const name = if (std.mem.indexOfScalar(u8, text, '@')) |at| text[0..at] else text;
            const listed = for (b.available_deps) |d| {
                if (std.mem.eql(u8, d[0], name)) break true;
            } else false;
            if (!listed) std.debug.panic(
                \\wraith.json depends on {s}, but build.zig.zon doesn't have it. Add it with
                \\  zig fetch --save={s} https://dist.wraith.io/hub/p/{s}/<version>.zip
                \\or `.{s} = .{{ .path = "../{s}" }}` for one next to this.
            , .{ name, name, name, name, name });
            const dep = b.dependency(name, .{});
            var dir = dep.builder.root.openDir(io, "schemas", .{}) catch continue;
            dir.close(io);
            out.append(b.allocator, .{ .name = name, .folder = dep.path("schemas") }) catch @panic("OOM");
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

    fn create(b: *std.Build, sdk: *std.Build.Module, salamander: *std.Build.Dependency, options: Options, depends: []const Salamander.ZigOptions.With) Arch {
        const module = b.createModule(.{
            .root_source_file = options.root_source_file,
            .target = options.target,
            .optimize = options.optimize,
            .imports = &.{.{ .name = "wraith_sdk", .module = sdk }},
        });
        if (options.schemas orelse findSchemas(options.root_source_file)) |dir| {
            module.addImport(options.schema_import, Salamander.zigModule(salamander, .{ .folder = dir, .target = options.target, .uses = &.{"wraith"}, .with = depends }));
        } else if (depends.len > 0) {
            // Nothing of its own, so the first dependency's folder stands in
            module.addImport(options.schema_import, Salamander.zigModule(salamander, .{ .folder = depends[0].folder, .target = options.target, .uses = &.{"wraith"}, .with = depends[1..] }));
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

/// Every `.sal` in `src/api/schemas`, so a check reruns when one changes.
fn schemaFiles(b: *std.Build) []const []const u8 {
    b.dependOnDirectoryMetadata(b.path("src/api/schemas"));
    const io = b.graph.io;
    var dir = b.root.openDir(io, "src/api/schemas", .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var list: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.name, ".sal")) list.append(b.allocator, b.dupe(e.name)) catch @panic("OOM");
    }
    return list.items;
}

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

    // wraith.sal as Zig with real methods, one file per pointer size. Kept in the repo so editors see
    // them, and checked by the tests.
    {
        const gen = b.dependency("salamander", .{}).artifact("salamander-gen");
        const update = b.step("api-zig", "Write src/api/wraith/x64.zig and x86.zig again from src/api/schemas");
        for ([_][2][]const u8{ .{ "x64", "8" }, .{ "x86", "4" } }) |arch| {
            const out = b.fmt("src/api/wraith/{s}.zig", .{arch[0]});
            const write = b.addRunArtifact(gen);
            write.addArgs(&.{ "zig", out, "src/api/schemas", "--pointer-size", arch[1] });
            write.setCwd(b.path("."));
            update.dependOn(&write.step);

            const check = b.addRunArtifact(gen);
            check.addArgs(&.{ "zig", out, "src/api/schemas", "--pointer-size", arch[1], "--check" });
            check.setCwd(b.path("."));
            check.addFileInput(b.path(out));
            for (schemaFiles(b)) |f| check.addFileInput(b.path(b.fmt("src/api/schemas/{s}", .{f})));
            test_step.dependOn(&check.step);
            build_test_step.dependOn(&check.step);
        }
    }

    const test_options = b.addOptions();
    for ([_][]const u8{ "fixture", "failing", "drawing" }) |name| {
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
        .root_module = Plugin.create(b, mods.sdk, b.dependency("salamander", .{ .target = mods.target, .optimize = mods.optimize }), .{
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
        }, false);

        const game = f.module("game", "src/game/root.zig", &.{
            .{ .name = "wraith_core", .module = core },
            .{ .name = "wraith_platform", .module = platform },
            .{ .name = "tuft_sys", .module = tuft.module("tuft_sys") },
            .{ .name = "tuft_inject", .module = tuft.module("tuft_inject") },
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
        }, true);
        // The fixture plugin's schema as generated Zig, so loader tests can call into it
        runtime.addImport("wraith_test_fixture", @import("salamander").zigModule(salamander_dep, .{ .source = b.path("src/runtime/testing/schemas/fixture.sal"), .target = target, .uses = &.{"wraith"} }));
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
        }, true);
        cli.addOptions("build_info", build_info);

        return .{ .b = b, .target = target, .optimize = optimize, .core = core, .platform = platform, .ui = ui, .api = api, .sdk = sdk, .runtime = runtime, .bootstrap = bootstrap, .proxies = proxies, .game = game, .registry = registry, .importer = importer, .cli = cli, .tuft = tuft };
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
