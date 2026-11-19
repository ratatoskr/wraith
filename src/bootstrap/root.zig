const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");

const RunOnceOrFollowup = core.once.RunOnceOrFollowup;

const Loader = @import("Loader.zig");
const console = @import("console.zig");

const log = core.log.scoped(.wraith_bootstrap);

/// Never torn down since bootstrap stays loaded until the game exits.
var gpa: core.allocator.Default = undefined;
var allocator: std.mem.Allocator = undefined;

var io: std.Io.Threaded = undefined;

var bootstrap_branch: RunOnceOrFollowup = .{};
var runtime_status: Atomic(RuntimeState) = .init(.uninitialized);
var mutex: std.Io.Mutex = .init;

var loader: ?*Loader = null;
var started_with_game: bool = false;
var wait_until_ready: bool = false;
var console_asked: bool = false;

const RuntimeState = enum(u8) {
    uninitialized,
    loading_initial,
    ready,
};

export fn wraith_bootstrap_init(flags: u32) callconv(.winapi) u32 {
    if (runtime_status.load(.seq_cst) == .uninitialized) {
        started_with_game = flags & core.runtime_abi.BootstrapFlags.started_with_game != 0;
        wait_until_ready = flags & core.runtime_abi.BootstrapFlags.wait_until_ready != 0;
        console_asked = flags & core.runtime_abi.BootstrapFlags.console != 0;
    }
    bootstrap_branch.run(loadRuntime, restartRuntime) catch |err| {
        log.err("Bootstrap failed: {any}", .{err});
        console.show();
        return 1;
    };

    return 0;
}

fn loadRuntime() !void {
    if (runtime_status.load(.seq_cst) != .uninitialized) {
        @panic("Runtime is already initialized");
    }

    console.hold();
    if (console_asked) console.show();

    gpa = .init();
    allocator = gpa.allocator();
    io = .init(allocator, .{});

    log.info("Initializing Wraith runtime ({s})...", .{if (started_with_game) "started with the game" else "attaching to a running game"});

    const thread = try std.Thread.spawn(.{ .stack_size = 8 << 20, .allocator = allocator }, loadRuntimeThread, .{});
    if (wait_until_ready) {
        // Whoever loaded us holds the game until we're done
        thread.join();
        if (runtime_status.load(.seq_cst) != .ready) return error.RuntimeLoadFailed;
    } else thread.detach();
}

fn loadRuntimeThread() void {
    loadRuntimeOnThread() catch |err| {
        log.err("Failed to perform initial load: {any}", .{err});
        console.show();
    };
}

fn loadRuntimeOnThread() !void {
    const io_handle = io.io();

    mutex.lockUncancelable(io_handle);
    defer mutex.unlock(io_handle);

    runtime_status.store(.loading_initial, .seq_cst);
    errdefer runtime_status.store(.uninitialized, .seq_cst);

    loader = try Loader.init(allocator, io.io());
    loader.?.before_rendering = started_with_game;

    if (loader) |ld| {
        try ld.load();
    } else {
        @panic("Loader was not initialized by loadRuntime!");
    }

    runtime_status.store(.ready, .seq_cst);
    log.info("Wraith runtime is ready.", .{});
}

fn restartRuntime() !void {
    if (runtime_status.load(.seq_cst) != .ready) {
        log.warn("Ignored restart request: Runtime is still performing initial load.", .{});
    }

    log.info("Triggering Wraith runtime restart...", .{});

    const thread = try std.Thread.spawn(.{ .stack_size = 8 << 20, .allocator = allocator }, restartRuntimeThread, .{});
    thread.detach();
}

fn restartRuntimeThread() void {
    restartRuntimeOnThread() catch console.show();
}

fn restartRuntimeOnThread() !void {
    const io_handle = io.io();

    mutex.lockUncancelable(io_handle);
    defer mutex.unlock(io_handle);

    if (loader) |ld| {
        ld.reload() catch |err| {
            log.err("Failed to restart: {any}", .{err});
            return err;
        };
    } else {
        log.err("Cannot restart: Loader is null", .{});
    }

    log.info("Wraith runtime restart completed.", .{});
}
