//! The console window, if the settings ask for it or the runtime fails to start.

const std = @import("std");

const core = @import("wraith_core");
const terminal = @import("tuft_sys").terminal;

const LogHistory = @import("LogHistory.zig");

/// First thing, before anything's logged. Leaves stderr alone unless there's a console already.
pub fn start() void {
    core.log.setStderr(terminal.isOpen());
}

/// Opens it if it isn't, then shows what's in the history.
pub fn show() void {
    if (terminal.isOpen()) {
        core.log.setStderr(true);
        return;
    }
    if (!terminal.open("Wraith Console")) return;
    core.log.setStderr(true);
    core.logo.print();
    replay(&LogHistory.global);
}

/// A line logged after stderr's on but before this reads it shows twice, which beats missing.
fn replay(history: *LogHistory) void {
    var buf: [32]LogHistory.Entry = undefined;
    var seq: u64 = 0;
    const end = history.count();
    while (seq < end) {
        const got = history.readSince(seq, &buf);
        if (got.len == 0) break;
        for (got) |*e| {
            if (e.seq >= end) return;
            core.log.writeStderr(&.{ .level = e.level, .subsystem = e.subsystem, .scope = @tagName(e.subsystem), .message = e.message() });
        }
        seq = got[got.len - 1].seq + 1;
    }
}
