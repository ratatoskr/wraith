//! Logging with a runtime filter and a sink. Each DLL has its own.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;
const builtin = @import("builtin");

pub const Level = std.log.Level;

pub const Subsystem = enum {
    core,
    os,
    hook,
    memory,
    graphics,
    ui,
    config,
    input,
    inject,
    bootstrap,
    runtime,
    sdk,
    plugin,
    cli,
    other,
};

pub const Levels = std.EnumSet(Level);
pub const Subsystems = std.EnumSet(Subsystem);

pub const Filter = struct {
    levels: Levels = default_levels,
    subsystems: Subsystems = .full,

    pub fn atLeast(min: Level) Levels {
        var levels: Levels = .empty;
        for (std.enums.values(Level)) |level| {
            if (@backingInt(level) <= @backingInt(min)) levels.insert(level);
        }
        return levels;
    }
};

pub const default_levels: Levels = if (builtin.mode == .debug) .full else Filter.atLeast(.info);

pub fn filter() Filter {
    const bits = mask.load(.monotonic);
    var result: Filter = .{ .levels = .empty, .subsystems = .empty };
    for (std.enums.values(Level)) |level| {
        if (bits & levelBit(level) != 0) result.levels.insert(level);
    }
    for (std.enums.values(Subsystem)) |subsystem| {
        if (bits & subsystemBit(subsystem) != 0) result.subsystems.insert(subsystem);
    }
    return result;
}

/// Thread-safe.
pub fn setFilter(new: Filter) void {
    mask.store(encode(new), .monotonic);
}

/// Returns the old filter.
pub fn mute(subsystems: []const Subsystem) Filter {
    const saved = filter();
    var muted = saved;
    for (subsystems) |s| muted.subsystems.remove(s);
    setFilter(muted);
    return saved;
}

pub fn resetFilter() void {
    setFilter(.{});
}

pub fn enabled(comptime level: Level, comptime scope: @EnumLiteral()) bool {
    return enabledAt(level, comptime subsystemOf(scope));
}

pub fn enabledAt(level: Level, subsystem: Subsystem) bool {
    const wanted = levelBit(level) | subsystemBit(subsystem);
    if (mask.load(.monotonic) & wanted != wanted) return false;
    const s = sink.load(.acquire);
    return if (s.enabled) |f| f(level, subsystem) else true;
}

pub fn subsystemOf(comptime scope: @EnumLiteral()) Subsystem {
    const name = @tagName(scope);
    const prefix = "wraith_";
    if (comptime std.mem.startsWith(u8, name, prefix)) {
        if (comptime std.meta.stringToEnum(Subsystem, name[prefix.len..])) |subsystem| return subsystem;
    }
    if (comptime std.mem.eql(u8, name, "tuft_hook")) return .hook;
    if (comptime std.mem.eql(u8, name, "tuft_mem")) return .memory;
    if (comptime std.mem.eql(u8, name, "tuft_gfx")) return .graphics;
    if (comptime std.mem.eql(u8, name, "tuft_event")) return .core;
    if (comptime std.mem.eql(u8, name, "tuft_input")) return .input;
    if (comptime std.mem.eql(u8, name, "tuft_inject")) return .inject;
    if (comptime std.mem.startsWith(u8, name, "tuft_")) return .os;
    return .other;
}

/// Longer messages get cut and end in "...".
pub const max_message_len = 1024;
const ellipsis = "...";

/// Only valid during `Sink.write`.
pub const Record = struct {
    level: Level,
    subsystem: Subsystem,
    scope: []const u8,
    message: []const u8,
};

pub const Sink = struct {
    enabled: ?*const fn (level: Level, subsystem: Subsystem) bool = null,
    write: *const fn (record: *const Record) void,
};

pub const default_sink: Sink = .{ .write = writeDefault };

/// Thread-safe. `new` has to outlive its use.
pub fn setSink(new: *const Sink) *const Sink {
    return sink.swap(new, .acq_rel);
}

pub fn write(record: Record) void {
    if (!enabledAt(record.level, record.subsystem)) return;
    sink.load(.acquire).write(&record);
}

fn emit(comptime level: Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    var buffer: [max_message_len]u8 = undefined;
    const record: Record = .{
        .level = level,
        .subsystem = comptime subsystemOf(scope),
        .scope = @tagName(scope),
        .message = formatInto(&buffer, format, args),
    };
    sink.load(.acquire).write(&record);
}

pub fn formatInto(buffer: []u8, comptime format: []const u8, args: anytype) []const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    writer.print(format, args) catch {
        @memcpy(buffer[buffer.len - ellipsis.len ..], ellipsis);
        return buffer;
    };
    return writer.buffered();
}

pub fn stdLogFn(comptime level: Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (enabled(level, scope)) emit(level, scope, format, args);
}

pub fn writeStderr(record: *const Record) void {
    const io = std.Options.debug_io;
    const prev = io.swapCancelProtection(.blocked);
    defer _ = io.swapCancelProtection(prev);
    var buffer: [64]u8 = undefined;
    const t = std.debug.lockStderr(&buffer).terminal();
    defer std.debug.unlockStderr();
    writeTerminal(record, t) catch {};
}

fn writeTerminal(record: *const Record, t: std.Io.Terminal) std.Io.Writer.Error!void {
    t.setColor(switch (record.level) {
        .err => .red,
        .warn => .yellow,
        .info => .green,
        .debug => .magenta,
    }) catch {};
    t.setColor(.bold) catch {};
    switch (record.level) {
        inline else => |level| try t.writer.writeAll(level.asText()),
    }
    t.setColor(.reset) catch {};
    t.setColor(.dim) catch {};
    t.setColor(.bold) catch {};
    if (!std.mem.eql(u8, record.scope, "default")) try t.writer.print("({s})", .{record.scope});
    try t.writer.writeAll(": ");
    t.setColor(.reset) catch {};
    try t.writer.print("{s}\n", .{record.message});
}

fn writeDefault(record: *const Record) void {
    if (!builtin.is_test) {
        if (stderr_on.load(.acquire)) writeStderr(record);
        return;
    }
    // The test runner fails the test on errors
    switch (record.level) {
        inline else => |level| std.options.logFn(level, .wraith, "({s}) {s}", .{ record.scope, record.message }),
    }
}

pub fn scoped(comptime scope: @EnumLiteral()) type {
    return struct {
        pub fn err(comptime format: []const u8, args: anytype) void {
            @branchHint(.cold);
            if (enabled(.err, scope)) emit(.err, scope, format, args);
        }

        pub fn warn(comptime format: []const u8, args: anytype) void {
            @branchHint(.unlikely);
            if (enabled(.warn, scope)) emit(.warn, scope, format, args);
        }

        pub fn info(comptime format: []const u8, args: anytype) void {
            if (enabled(.info, scope)) emit(.info, scope, format, args);
        }

        pub fn debug(comptime format: []const u8, args: anytype) void {
            if (enabled(.debug, scope)) emit(.debug, scope, format, args);
        }

        pub fn print(comptime format: []const u8, args: anytype) void {
            std.debug.print(format, args);
        }

        pub fn printLn(comptime format: []const u8, args: anytype) void {
            print(format ++ "\n", args);
        }
    };
}

// Bits 0..7 are levels, 8 and up are subsystems
const subsystem_shift = 8;

comptime {
    std.debug.assert(Levels.len <= subsystem_shift);
    std.debug.assert(subsystem_shift + Subsystems.len <= 32);
}

var mask: Atomic(u32) = .init(encode(.{}));
var sink: Atomic(*const Sink) = .init(&default_sink);
var stderr_on: Atomic(bool) = .init(true);

/// Keeps the default sink off stderr until a console opens, since std caches the first stderr. Per DLL.
pub fn setStderr(on: bool) void {
    stderr_on.store(on, .release);
}

fn levelBit(level: Level) u32 {
    return @as(u32, 1) << @intCast(Levels.Indexer.indexOf(level));
}

fn subsystemBit(subsystem: Subsystem) u32 {
    return @as(u32, 1) << @intCast(subsystem_shift + Subsystems.Indexer.indexOf(subsystem));
}

fn encode(f: Filter) u32 {
    @setEvalBranchQuota(10_000);
    var bits: u32 = 0;
    for (std.enums.values(Level)) |level| {
        if (f.levels.contains(level)) bits |= levelBit(level);
    }
    for (std.enums.values(Subsystem)) |subsystem| {
        if (f.subsystems.contains(subsystem)) bits |= subsystemBit(subsystem);
    }
    return bits;
}

const tests = struct {
    test "scope subsystems" {
        try std.testing.expectEqual(.hook, subsystemOf(.wraith_hook));
        try std.testing.expectEqual(.os, subsystemOf(.wraith_os));
        try std.testing.expectEqual(.other, subsystemOf(.wraith_unknown));
        try std.testing.expectEqual(.hook, subsystemOf(.tuft_hook));
        try std.testing.expectEqual(.memory, subsystemOf(.tuft_mem));
        try std.testing.expectEqual(.graphics, subsystemOf(.tuft_gfx));
        try std.testing.expectEqual(.os, subsystemOf(.tuft_sys));
        try std.testing.expectEqual(.inject, subsystemOf(.tuft_inject));
        try std.testing.expectEqual(.other, subsystemOf(.kai));
    }

    test "filter gating" {
        const saved = filter();
        defer setFilter(saved);

        setFilter(.{ .levels = Filter.atLeast(.warn), .subsystems = .initMany(&.{ .hook, .other }) });
        try std.testing.expect(enabled(.err, .wraith_hook));
        try std.testing.expect(enabled(.warn, .kai));
        try std.testing.expect(!enabled(.info, .wraith_hook));
        try std.testing.expect(!enabled(.err, .wraith_os));

        const read = filter();
        try std.testing.expect(read.levels.eql(Filter.atLeast(.warn)));
        try std.testing.expect(read.subsystems.eql(.initMany(&.{ .hook, .other })));
    }

    test "default filter" {
        const saved = filter();
        defer setFilter(saved);

        resetFilter();
        try std.testing.expect(enabled(.info, .wraith_runtime));
        try std.testing.expectEqual(builtin.mode == .debug, enabled(.debug, .wraith_core));
    }

    const Capture = struct {
        var count: u32 = 0;
        var level: Level = .err;
        var subsystem: Subsystem = .other;
        var scope_buf: [64]u8 = undefined;
        var scope_len: usize = 0;
        var message_buf: [max_message_len]u8 = undefined;
        var message_len: usize = 0;
        var allow_debug = true;

        fn capture(r: *const Record) void {
            count += 1;
            level = r.level;
            subsystem = r.subsystem;
            @memcpy(scope_buf[0..r.scope.len], r.scope);
            scope_len = r.scope.len;
            @memcpy(message_buf[0..r.message.len], r.message);
            message_len = r.message.len;
        }

        fn allows(l: Level, _: Subsystem) bool {
            return l != .debug or allow_debug;
        }

        const as_sink: Sink = .{ .enabled = allows, .write = capture };
    };

    test "sink formatting" {
        const saved = filter();
        defer setFilter(saved);
        const previous = setSink(&Capture.as_sink);
        defer _ = setSink(previous);
        Capture.count = 0;
        Capture.allow_debug = true;

        setFilter(.{ .levels = .full });
        scoped(.wraith_hook).debug("hello {d}", .{42});
        try std.testing.expectEqual(1, Capture.count);
        try std.testing.expectEqual(.debug, Capture.level);
        try std.testing.expectEqual(.hook, Capture.subsystem);
        try std.testing.expectEqualStrings("wraith_hook", Capture.scope_buf[0..Capture.scope_len]);
        try std.testing.expectEqualStrings("hello 42", Capture.message_buf[0..Capture.message_len]);

        // The sink can say no too
        Capture.allow_debug = false;
        scoped(.wraith_hook).debug("hidden", .{});
        stdLogFn(.debug, .kai, "hidden", .{});
        try std.testing.expectEqual(1, Capture.count);

        // The mask can too, even for pre-formatted messages
        setFilter(.{ .levels = Filter.atLeast(.info) });
        write(.{ .level = .debug, .subsystem = .plugin, .scope = "x", .message = "hidden" });
        write(.{ .level = .info, .subsystem = .plugin, .scope = "x", .message = "shown" });
        try std.testing.expectEqual(2, Capture.count);
        try std.testing.expectEqual(.plugin, Capture.subsystem);
    }

    test "long messages cut" {
        var buffer: [8]u8 = undefined;
        try std.testing.expectEqualStrings("abcde...", formatInto(&buffer, "{s}", .{"abcdefghijk"}));
    }
};

test {
    _ = tests;
}
