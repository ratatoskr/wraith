//! Crash handling. A crash nothing else handled stops here. A thread of ours logs it, flushes the log and
//! writes a report, then shows the crash window. From there it can go into the workbench's
//! debugger, else it goes on to the game's own crash handling.
//! The minidump comes from crash\wraith_crashhandler_<arch>.exe, outside the game, since dumping ourselves
//! hangs if a paused thread holds a lock the dump needs. Without it we dump ourselves.
//! The crashing thread itself only copies what it needs and waits, since it may have no stack or hold a
//! lock anything else needs.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const builtin = @import("builtin");

const core = @import("wraith_core");
const sys = @import("tuft_sys");
const Debugger = @import("tuft_hook").Debugger;

const LogFile = @import("../LogFile.zig");
const LogHistory = @import("../LogHistory.zig");
pub const Report = @import("Report.zig");
const Window = @import("Window.zig");
const imgui = @import("../ui/imgui.zig");
const keep_first = switch (builtin.os.tag) {
    .windows => @import("win/keep_first.zig"),
    else => @compileError("Unsupported operating system"),
};

const Exception = sys.exceptions.Exception;
const Action = sys.exceptions.Action;

const log = core.log.scoped(.wraith_runtime);

/// How long the crash window gets to show up, in case the crash broke what it needs.
pub const window_timeout_ms = 5000;
/// How long the workbench gets to open and take the crash.
const workbench_timeout_ms = 15_000;
/// Writing the dump can take a while for a big game.
const report_timeout_ms = 30_000;
/// Less than that, so the report still gets written if the crash handler hangs.
const dump_timeout_ms = 20_000;

const State = enum(u8) {
    off,
    idle,
    /// The watcher's logging it and writing the dump and report.
    reporting,
    reported,
    /// The watcher's showing the crash window.
    showing,
};

var state: Atomic(State) = .init(.off);
var signal: ?sys.sync.Signal = null;
var watcher: ?std.Thread = null;
var stopping: Atomic(bool) = .init(false);

/// Guards `debugger` and `opener`.
var debugger_lock: sys.sync.RwLock = .{};
/// The workbench's, while it's open.
var debugger: ?*Debugger = null;
/// Opens the workbench, while there is one.
var opener: ?Opener = null;

pub const Opener = struct {
    ctx: *anyopaque,
    open: *const fn (ctx: *anyopaque) void,
};

// Set by `install`
var exe_buf: [260]u8 = undefined;
var exe_len: usize = 0;
var pid: u32 = 0;
var logs_buf: [1024]u8 = undefined;
var logs_len: usize = 0;
var report_path_buf: [1100]u8 = undefined;
var report_path_len: usize = 0;
var dump_path_buf: [1100]u8 = undefined;
var dump_path_len: usize = 0;
/// `wraith_crashhandler_<arch>.exe`, which dumps from outside. Empty means we dump ourselves.
var handler_buf: [1100]u8 = undefined;
var handler_len: usize = 0;
/// Its command line, built mid-crash.
var command_buf: [2400]u8 = undefined;

// The crash in hand
var crashed: struct { exception: Exception, thread_id: u32 } = undefined;
var report: Report = .{};
var summary_buf: [400]u8 = undefined;
var summary_len: usize = 0;
var window_up: Atomic(bool) = .init(false);
// From `panic`, for the crash it turns into
var panic_buf: [300]u8 = undefined;
var panic_len: usize = 0;
var panic_thread: Atomic(u32) = .init(0);
threadlocal var panicking: bool = false;
/// Set by the watcher once the window's done.
var choice: Atomic(Picked) = .init(.waiting);
/// Tests answer the window without it showing.
var test_choice: ?Window.Choice = null;
/// A dump of our own process can deadlock on a lock another thread holds, so tests that
/// don't need one skip it.
var test_skip_dump = false;
/// Tests check the crash handler wrote it, not us.
var dumped_outside = false;

const Picked = enum(u8) { waiting, crash, workbench };

const Last = sys.exceptions.Unhandled(route);

/// `logs_dir` is where the report and dump go, next to the log. `crash_handler` is the
/// `wraith_crashhandler_<arch>.exe` for our arch, to write the dump from outside the game.
pub fn install(logs_dir: []const u8, exe: []const u8, process_id: u32, crash_handler: ?[]const u8) void {
    if (state.load(.acquire) != .off) return;
    const name = std.fs.path.basename(exe);
    const stem = if (std.ascii.endsWithIgnoreCase(name, ".exe")) name[0 .. name.len - 4] else name;
    exe_len = copy(&exe_buf, name);
    pid = process_id;
    logs_len = copy(&logs_buf, logs_dir);
    handler_len = if (crash_handler) |h| copy(&handler_buf, h) else 0;
    report_path_len = (std.fmt.bufPrint(&report_path_buf, "{s}{c}{s}-{d}-crash.txt", .{ logs_dir, std.fs.path.sep, stem, pid }) catch return).len;
    dump_path_len = (std.fmt.bufPrint(&dump_path_buf, "{s}{c}{s}-{d}-crash.dmp", .{ logs_dir, std.fs.path.sep, stem, pid }) catch return).len;

    // Now, not mid-crash, since these could need locks a crash holds
    if (!sys.exceptions.prepareMinidumps()) log.warn("Crashes won't get a minidump: dbghelp.dll didn't load", .{});
    imgui.bind();
    signal = sys.sync.Signal.init() catch |err| {
        log.warn("No crash handling: {t}", .{err});
        return;
    };
    watcher = std.Thread.spawn(.{}, watch, .{}) catch |err| {
        log.warn("No crash handling: {t}", .{err});
        signal.?.deinit();
        signal = null;
        return;
    };
    state.store(.idle, .release);
    Last.install();
    keep_first.start(Last.address(), Last.setNext);
}

pub fn uninstall() void {
    if (state.load(.acquire) == .off) return;
    // In this order, since taking ours out goes through what the hook catches
    keep_first.stop();
    Last.uninstall();
    state.store(.off, .release);
    stopping.store(true, .release);
    signal.?.set();
    watcher.?.join();
    watcher = null;
    signal.?.deinit();
    signal = null;
    stopping.store(false, .release);
}

/// The workbench's, while it's open. "Open in workbench" stops a crash in it.
pub fn setDebugger(d: ?*Debugger) void {
    debugger_lock.lock();
    defer debugger_lock.unlock();
    debugger = d;
}

/// The runtime's panic handler. Zig's own loads debug info from disk to print a trace, which needs more
/// stack than game threads have. This logs it and traps instead, so it shows up as a crash like any other.
pub fn panic(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    if (!panicking) {
        panicking = true;
        panic_len = copy(&panic_buf, msg);
        panic_thread.store(std.Thread.getCurrentId(), .release);
        log.err("Wraith panicked: {s}", .{msg});
    }
    @trap();
}

/// For "Open in workbench". Null before the workbench goes.
pub fn setOpener(o: ?Opener) void {
    debugger_lock.lock();
    defer debugger_lock.unlock();
    opener = o;
}

pub fn reportPath() []const u8 {
    return report_path_buf[0..report_path_len];
}

/// On the crashing thread, with maybe very little stack.
fn route(e: *Exception) Action {
    // One at a time. A second thread crashing meanwhile waits its turn
    while (true) {
        const was = state.cmpxchgStrong(.idle, .reporting, .acq_rel, .acquire) orelse break;
        if (was == .off) return .pass;
        sys.thread.sleepMs(10);
    }
    crashed = .{ .exception = e.*, .thread_id = std.Thread.getCurrentId() };
    signal.?.set();
    // The dump reads this thread, so wait here till it's written
    _ = waitWhile(.reporting, report_timeout_ms);
    const verdict = decide(e);
    state.store(.idle, .release);
    return if (verdict == .resumed) .handled else .pass;
}

fn decide(e: *Exception) Debugger.Verdict {
    window_up.store(false, .release);
    choice.store(.waiting, .release);
    state.store(.showing, .release);
    signal.?.set();
    const started = sys.thread.tickMs();
    const picked: Picked = while (true) {
        const c = choice.load(.acquire);
        if (c != .waiting) break c;
        if (!window_up.load(.acquire) and sys.thread.tickMs() -% started > window_timeout_ms) break .crash;
        sys.thread.sleepMs(10);
    };
    if (picked != .workbench) return .crash;
    return stopInWorkbench(e);
}

/// The watcher opened it. Waits for it to say it's ready, then stops till its debugger says.
fn stopInWorkbench(e: *Exception) Debugger.Verdict {
    const started = sys.thread.tickMs();
    while (sys.thread.tickMs() -% started < workbench_timeout_ms) {
        {
            // Held while stopped, so the workbench can't free its debugger under us. Closing it lets us go first
            debugger_lock.lockShared();
            defer debugger_lock.unlockShared();
            if (debugger) |d| if (d.canStopCrash()) return d.stopCrash(e);
        }
        sys.thread.sleepMs(20);
    }
    log.warn("The workbench didn't take the crash in time, so it goes on to the game", .{});
    return .crash;
}
/// False if it timed out.
fn waitWhile(s: State, timeout_ms: u64) bool {
    const started = sys.thread.tickMs();
    while (state.load(.acquire) == s) {
        if (sys.thread.tickMs() -% started > timeout_ms) return false;
        sys.thread.sleepMs(5);
    }
    return true;
}

fn watch() void {
    while (true) {
        _ = signal.?.wait(null);
        if (stopping.load(.acquire)) return;
        switch (state.load(.acquire)) {
            .reporting => {
                writeReport();
                state.store(.reported, .release);
            },
            .showing => {
                const o = currentOpener();
                const picked = test_choice orelse Window.run(&report, summary_buf[0..summary_len], logs_buf[0..logs_len], o != null, &window_up);
                // From here, since the render thread may be the one that crashed
                if (picked == .workbench) if (o) |w| w.open(w.ctx);
                choice.store(switch (picked) {
                    .crash => .crash,
                    .workbench => .workbench,
                }, .release);
            },
            else => {},
        }
    }
}

fn writeReport() void {
    const e = &crashed.exception;
    const panicked: ?[]const u8 = if (panic_thread.swap(0, .acq_rel) == crashed.thread_id) panic_buf[0..panic_len] else null;
    summary_len = if (panicked) |msg|
        (std.fmt.bufPrint(&summary_buf, "Wraith panicked: {s}", .{msg}) catch @as([]u8, &summary_buf)).len
    else
        Report.summary(e, &summary_buf).len;
    log.err("The game crashed: {s} (thread {d}). Report in {s}", .{ summary_buf[0..summary_len], crashed.thread_id, reportPath() });
    LogFile.global.flush();

    const dump_path = dump_path_buf[0..dump_path_len];
    const dump_error = writeDump(dump_path, e);
    report.build(.{
        .panic = panicked,
        .exception = e.*,
        .thread_id = crashed.thread_id,
        .exe = exe_buf[0..exe_len],
        .pid = pid,
        .dump_path = dump_path,
        .dump_error = dump_error,
        .history = &LogHistory.global,
    });
    // A second crash after continuing adds to the same file
    if (@import("wraith_platform").fs.AppendFile.open(reportPath())) |file| {
        defer file.close();
        file.write(report.text());
        file.write("\r\n");
    } else |err| log.warn("Couldn't write the crash report: {t}", .{err});
    LogFile.global.flush();
}

fn currentOpener() ?Opener {
    debugger_lock.lockShared();
    defer debugger_lock.unlockShared();
    return opener;
}

/// From outside by the crash handler if there is one, else from in here. Null when it's written.
fn writeDump(path: []const u8, e: *const Exception) ?anyerror {
    if (builtin.is_test and test_skip_dump) return error.SkippedInTest;
    if (handler_len > 0) {
        if (dumpOutside(path, e)) |_| {
            if (builtin.is_test) dumped_outside = true;
            return null;
        } else |err| {
            // Dumping from in here would likely hang the same way
            if (err == error.TimedOut) return err;
            log.warn("The crash handler couldn't write the dump ({t}), so we will", .{err});
        }
    }
    sys.exceptions.writeMinidump(path, crashed.thread_id, e.os) catch |err| return err;
    return null;
}

fn dumpOutside(path: []const u8, e: *const Exception) !void {
    const exception: usize = if (e.os) |os| @intFromPtr(os) else 0;
    const command = std.fmt.bufPrint(&command_buf, "\"{s}\" dump {d} \"{s}\" {d} 0x{x}", .{ handler_buf[0..handler_len], pid, path, crashed.thread_id, exception }) catch return error.PathTooLong;
    if (try sys.exceptions.runAndWait(command, dump_timeout_ms) != 0) return error.CrashHandlerFailed;
}

fn copy(buf: []u8, s: []const u8) usize {
    const n = @min(buf.len, s.len);
    @memcpy(buf[0..n], s[0..n]);
    return n;
}

const tests = struct {
    const testing = std.testing;

    noinline fn crashHere(done: *Atomic(bool)) void {
        // Nothing handles a stray int3, so it's a crash
        asm volatile ("int3");
        done.store(true, .release);
    }

    /// A minidump's MINIDUMP_EXCEPTION_STREAM: its thread and exception code.
    fn exceptionStream(dump: []const u8) ?struct { thread_id: u32, code: u32 } {
        if (dump.len < 16 or !std.mem.eql(u8, dump[0..4], "MDMP")) return null;
        const count = std.mem.readInt(u32, dump[8..12], .little);
        const directory = std.mem.readInt(u32, dump[12..16], .little);
        for (0..count) |i| {
            const at = directory + i * 12;
            if (at + 12 > dump.len) return null;
            if (std.mem.readInt(u32, dump[at..][0..4], .little) != 6) continue;
            const rva = std.mem.readInt(u32, dump[at + 8 ..][0..4], .little);
            if (rva + 12 > dump.len) return null;
            return .{ .thread_id = std.mem.readInt(u32, dump[rva..][0..4], .little), .code = std.mem.readInt(u32, dump[rva + 8 ..][0..4], .little) };
        }
        return null;
    }

    /// Opening the workbench registers its debugger, like the real one does once it's up.
    const FakeWorkbench = struct {
        debugger: *Debugger,
        opened: bool = false,

        fn open(ctx: *anyopaque) void {
            const self: *FakeWorkbench = @ptrCast(@alignCast(ctx));
            self.opened = true;
            setDebugger(self.debugger);
        }
    };

    const Rig = struct {
        tmp: testing.TmpDir,
        logs: [:0]u8,
        pid: u32,
        name_buf: [64]u8 = undefined,
        saved_log: core.log.Filter,

        fn init(self: *Rig) !void {
            try @import("tuft_hook").init(testing.allocator);
            // It logs the crash as an error, which a test would count as failing
            self.saved_log = core.log.mute(&.{.runtime});
            self.tmp = testing.tmpDir(.{});
            self.logs = try self.tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
            // The real one, so dumps are written from outside like in a game
            self.pid = @import("wraith_platform").process.currentId();
            dumped_outside = false;
            install(self.logs, "C:\\Games\\Kai.exe", self.pid, @import("test_options").crashhandler);
        }

        /// Like `Kai-<pid>-crash.txt`.
        fn file(self: *Rig, comptime ext: []const u8) []const u8 {
            return std.fmt.bufPrint(&self.name_buf, "Kai-{d}-crash." ++ ext, .{self.pid}) catch unreachable;
        }

        fn deinit(self: *Rig) void {
            uninstall();
            test_choice = null;
            test_skip_dump = false;
            testing.allocator.free(self.logs);
            self.tmp.cleanup();
            core.log.setFilter(self.saved_log);
            @import("tuft_hook").deinit();
        }
    };

    test "open in workbench stops it in the debugger, with its report written" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();

        var d: Debugger = .init(testing.allocator, .{});
        defer d.deinit();
        d.ignoreThread(std.Thread.getCurrentId());
        try d.prepare();
        var workbench: FakeWorkbench = .{ .debugger = &d };
        setOpener(.{ .ctx = &workbench, .open = FakeWorkbench.open });
        defer setOpener(null);
        defer setDebugger(null);
        test_choice = .workbench;

        var done: Atomic(bool) = .init(false);
        const thread = try std.Thread.spawn(.{}, crashHere, .{&done});
        var out: [Debugger.max_paused]Debugger.Paused = undefined;
        const stop = for (0..10_000) |_| {
            d.beat();
            if (d.paused(&out) > 0) break out[0];
            sys.thread.sleepMs(1);
        } else return error.TimedOut;
        try testing.expectEqual(.crash, stop.reason);
        // So a failed check below fails the test, not the process
        errdefer {
            _ = d.resumeThread(stop.id, .skip);
            thread.join();
        }
        try testing.expect(workbench.opened);
        try testing.expectEqual(.breakpoint, stop.crash.?.kind);

        const text = try rig.tmp.dir.readFileAlloc(testing.io, rig.file("txt"), testing.allocator, .limited(64 << 10));
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "What: breakpoint nobody handled in ") != null);
        const dump = try rig.tmp.dir.readFileAlloc(testing.io, rig.file("dmp"), testing.allocator, .limited(512 << 20));
        defer testing.allocator.free(dump);
        // The crash handler read our exception from outside, with the layout for our arch
        const exception = exceptionStream(dump) orelse return error.NoExceptionStream;
        try testing.expectEqual(stop.thread_id, exception.thread_id);
        try testing.expectEqual(0x80000003, exception.code);
        try testing.expect(dumped_outside);

        try testing.expect(d.resumeThread(stop.id, .skip));
        thread.join();
        try testing.expect(done.load(.acquire));
    }

    /// Up to 30 s by the clock. Loaded CI machines can be slow to open and draw a real window.
    fn waitFor(what: []const u8, ctx: anytype, comptime check: fn (@TypeOf(ctx)) bool) !void {
        const start = core.timing.now();
        while (core.timing.now() - start < 30 * std.time.ns_per_s) {
            if (check(ctx)) return;
            sys.thread.sleepMs(1);
        }
        if (check(ctx)) return;
        std.debug.print("timed out waiting until {s}\n", .{what});
        return error.TimedOut;
    }

    test "crashes stop in the real workbench with their code in front, open or closed" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        test_skip_dump = true;
        // The real window, so it takes focus and closes like in a game
        Window.test_pick = .workbench;
        defer Window.test_pick = null;
        const Workbench = @import("../ui/workbench/Workbench.zig");
        const wb = try Workbench.create(testing.allocator, .{});
        defer wb.destroy();
        wb.debugger.ignoreThread(std.Thread.getCurrentId());

        const Checks = struct {
            fn catching(w: *Workbench) bool {
                return w.isOpen() and w.app.?.frameCount() >= 5 and w.catching_crashes;
            }
            fn memoryInFront(w: *Workbench) bool {
                return w.memory_in_front.load(.acquire);
            }
            fn closed(w: *Workbench) bool {
                return !w.isOpen() and !w.catching_crashes;
            }
            fn stopShown(s: *const Since) bool {
                var out: [Debugger.max_paused]Debugger.Paused = undefined;
                // New frames, since it keeps the last one's answer while it's hidden
                return s.wb.debugger.paused(&out) == 1 and s.wb.isOpen() and s.wb.app.?.frameCount() >= s.frames + 2 and s.wb.code_in_front.load(.acquire);
            }
            const Since = struct { wb: *Workbench, frames: u32 };
        };
        wb.open();
        _ = wb.app orelse return error.SkipZigTest;
        try waitFor("it's open and catching", wb, Checks.catching);

        var at_memory: u8 = 0;
        for (0..3) |round| {
            wb.remote().openMemory(@intFromPtr(&at_memory), 1, null);
            waitFor("the memory view's in front", wb, Checks.memoryInFront) catch |err| {
                std.debug.print("round {d}: open {}, frames {d}, memory in front {}, code in front {}\n", .{ round, wb.isOpen(), wb.app.?.frameCount(), wb.memory_in_front.load(.acquire), wb.code_in_front.load(.acquire) });
                return err;
            };
            if (round > 0) {
                wb.close();
                try waitFor("it's closed", wb, Checks.closed);
            }

            var done: Atomic(bool) = .init(false);
            const since: Checks.Since = .{ .wb = wb, .frames = wb.app.?.frameCount() };
            const thread = try std.Thread.spawn(.{}, crashHere, .{&done});
            waitFor(if (round == 0) "the crash's code is in front" else "it's back with the crash's code in front", &since, Checks.stopShown) catch |err| {
                var out: [Debugger.max_paused]Debugger.Paused = undefined;
                if (wb.debugger.paused(&out) == 1) {
                    _ = wb.debugger.resumeThread(out[0].id, .skip);
                    thread.join();
                } else thread.detach();
                return err;
            };
            var out: [Debugger.max_paused]Debugger.Paused = undefined;
            _ = wb.debugger.paused(&out);
            try testing.expectEqual(.crash, out[0].reason);
            try testing.expect(wb.debugger.resumeThread(out[0].id, .skip));
            thread.join();
            try testing.expect(done.load(.acquire));
        }
    }

    test "a panic's message goes in the report" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        // It's about the message, and the workbench test covers the dump
        test_skip_dump = true;
        // What `panic` leaves before it traps, and what the trap would bring
        panic_len = copy(&panic_buf, "index out of bounds");
        panic_thread.store(std.Thread.getCurrentId(), .release);
        var cpu = std.mem.zeroes(@import("tuft_arch").CpuContext);
        cpu.setIp(@returnAddress());
        crashed = .{ .exception = .{ .kind = .illegal_instruction, .code = 0xC000001D, .cpu = cpu }, .thread_id = std.Thread.getCurrentId() };
        writeReport();

        try testing.expectEqualStrings("Wraith panicked: index out of bounds", summary_buf[0..summary_len]);
        const text = try rig.tmp.dir.readFileAlloc(testing.io, rig.file("txt"), testing.allocator, .limited(64 << 10));
        defer testing.allocator.free(text);
        try testing.expect(std.mem.indexOf(u8, text, "Panic: index out of bounds\r\n") != null);
        try testing.expectEqual(0, panic_thread.load(.acquire));
    }

    test "close the game hands it on to the game's own handler" {
        var rig: Rig = undefined;
        try rig.init();
        defer rig.deinit();
        test_choice = .crash;

        // Stands in for the game's, skipping the int3 so the test lives
        const Game = struct {
            var calls: Atomic(u32) = .init(0);
            fn filter(info: *sys.win.EXCEPTION_POINTERS) callconv(.winapi) c_long {
                _ = calls.fetchAdd(1, .acq_rel);
                if (comptime @import("tuft_arch").bits == 64) info.ContextRecord.Rip += 1 else info.ContextRecord.Eip += 1;
                return sys.win.EXCEPTION_CONTINUE_EXECUTION;
            }
        };
        // Through the real call, which the hook turns into ours passing on to it
        _ = sys.win.SetUnhandledExceptionFilter(Game.filter);

        var done: Atomic(bool) = .init(false);
        const thread = try std.Thread.spawn(.{}, crashHere, .{&done});
        thread.join();
        try testing.expect(done.load(.acquire));
        try testing.expectEqual(1, Game.calls.load(.acquire));
        try testing.expect((try rig.tmp.dir.statFile(testing.io, rig.file("txt"), .{})).size > 0);
    }
};
test {
    _ = Report;
    _ = tests;
}
