//! The console, only if the launcher asks for it or loading fails. Players never see one otherwise.
//! Till then lines wait in a ring, so a failure shows how it got there.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const terminal = @import("tuft_sys").terminal;

const capacity = 64;
const max_text = 240;

const Line = struct {
    level: std.log.Level,
    subsystem: core.log.Subsystem,
    /// Scopes are comptime names, so they last.
    scope: []const u8,
    len: usize,
    text: [max_text]u8,
};

var lines: [capacity]Line = undefined;
var next: usize = 0;
var lock: Atomic(bool) = .init(false);
var shown: Atomic(bool) = .init(false);

const sink: core.log.Sink = .{ .write = write };

/// Before anything's logged.
pub fn hold() void {
    core.log.setStderr(false);
    _ = core.log.setSink(&sink);
}

/// Opens it and writes what's been logged so far. Only the first call does anything.
pub fn show() void {
    if (shown.swap(true, .acq_rel)) return;
    // The runtime opens it itself if it fails to start
    const existed = terminal.isOpen();
    if (!terminal.open("Wraith Console")) return;
    core.log.setStderr(true);
    if (!existed) core.logo.print();
    replay();
}

fn write(record: *const core.log.Record) void {
    keep(record);
    core.log.default_sink.write(record);
}

fn keep(record: *const core.log.Record) void {
    acquire();
    defer release();
    const line = &lines[next % capacity];
    const len = @min(record.message.len, max_text);
    line.* = .{ .level = record.level, .subsystem = record.subsystem, .scope = record.scope, .len = len, .text = undefined };
    @memcpy(line.text[0..len], record.message[0..len]);
    next += 1;
}

/// A line written after stderr's on but before this reads it shows twice, which beats missing.
fn replay() void {
    acquire();
    const end = next;
    release();
    var i = end -| capacity;
    while (i < end) : (i += 1) {
        acquire();
        const line = lines[i % capacity];
        release();
        core.log.writeStderr(&.{ .level = line.level, .subsystem = line.subsystem, .scope = line.scope, .message = line.text[0..line.len] });
    }
}

fn acquire() void {
    while (lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn release() void {
    lock.store(false, .release);
}
