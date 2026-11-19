//! The runtime DLL. Bootstrap loads it and it hosts the plugins.

const std = @import("std");

const core = @import("wraith_core");

const RuntimeInfo = core.runtime_abi.RuntimeInfo;

const Runtime = @import("Runtime.zig");
const LogHistory = @import("LogHistory.zig");
const LogFile = @import("LogFile.zig");
const Console = @import("Console.zig");

pub const std_options: std.Options = .{ .logFn = core.log.stdLogFn };

/// Std's prints a trace, which can overflow a game thread's stack. Ours makes it a crash.
pub const panic = std.debug.FullPanic(@import("crash/root.zig").panic);

const log = core.log.scoped(.wraith_runtime);

var runtime: ?*Runtime = null;
var previous_sink: *const core.log.Sink = &core.log.default_sink;

const sink: core.log.Sink = .{ .write = writeLog };

fn writeLog(record: *const core.log.Record) void {
    LogHistory.global.add(record.level, record.subsystem, record.message);
    LogFile.global.write(record);
    core.log.default_sink.write(record);
}

var gpa: core.allocator.Default = undefined;
var tracked: core.heap.TrackedAllocator = undefined;

comptime {
    @export(&init, .{ .name = core.runtime_abi.init_symbol });
    @export(&shutdown, .{ .name = core.runtime_abi.shutdown_symbol });
}

fn init(info: *const RuntimeInfo) callconv(.c) u32 {
    Console.start();
    previous_sink = core.log.setSink(&sink);
    gpa = .init();
    tracked.init(gpa.allocator(), "heap");
    core.heap.registry.add(&tracked.usage);
    runtime = Runtime.create(tracked.allocator(), info) catch |err| {
        log.err("Runtime failed to start: {t}", .{err});
        // So it isn't silent for players
        Console.show();
        releaseAllocator();
        _ = core.log.setSink(previous_sink);
        LogFile.global.close();
        return 1;
    };
    return 0;
}

fn shutdown() callconv(.c) void {
    const r = runtime orelse return;
    r.destroy();
    runtime = null;
    releaseAllocator();
    log.info("Runtime stopped", .{});
    _ = core.log.setSink(previous_sink);
    // Last, so leaks reported above go in it too
    LogFile.global.close();
}

fn releaseAllocator() void {
    core.heap.registry.remove(&tracked.usage);
    const leaks = gpa.deinit();
    if (leaks != 0) log.warn("The runtime leaked {d} allocation(s), listed above", .{leaks});
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("host/root.zig");
    _ = @import("PluginLoader.zig");
    _ = @import("Manifest.zig");
    _ = @import("GameInfo.zig");
    _ = @import("Names.zig");
    _ = @import("Libraries.zig");
    _ = @import("OriginalCode.zig");
    _ = @import("graphics/Graphics.zig");
    _ = @import("Settings.zig");
    _ = @import("settings/Registry.zig");
    _ = @import("GameSettings.zig");
    _ = @import("Project.zig");
    _ = @import("Tweaks.zig");
    _ = @import("FrameStats.zig");
    _ = LogHistory;
    _ = LogFile;
    _ = Console;
    _ = @import("Files.zig");
    _ = @import("ui/imgui.zig");
    _ = @import("ui/Overlay.zig");
    _ = @import("ui/Themes.zig");
    _ = @import("ui/markdown.zig");
    _ = @import("ui/workbench/Workbench.zig");
    _ = @import("ui/shell/Shell.zig");
    _ = @import("sessions/Sessions.zig");
    _ = @import("sessions/ce_tests.zig");
    _ = Runtime;
    _ = @import("Game.zig");
    _ = @import("crash/root.zig");
}
