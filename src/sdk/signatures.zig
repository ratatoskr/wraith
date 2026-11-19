//! Sends signature scans to the runtime.

const std = @import("std");

const memory = @import("tuft_mem");

const Owner = @import("Owner.zig");

var attached = false;
var previous: ?memory.scans.Recorder = null;
var previous_provider: ?memory.originals.Provider = null;

pub fn attach() void {
    if (attached) return;
    attached = true;
    previous = memory.scans.setRecorder(forward);
    previous_provider = memory.originals.setProvider(original);
}

pub fn detach() void {
    if (!attached) return;
    _ = memory.scans.setRecorder(previous);
    _ = memory.originals.setProvider(previous_provider);
    attached = false;
}

fn original(start: usize, len: usize) ?[*]const u8 {
    const owner = Owner.own() orelse return null;
    return @ptrFromInt(owner.root.diagnostics().original(start, len));
}

fn forward(record: *const memory.scans.Record) void {
    const owner = Owner.current() orelse return;
    owner.root.diagnostics().recordScan(.{
        .name = record.name,
        .pattern = record.pattern,
        .start = record.start,
        .length = record.len,
        .original = record.original,
        .outcome = switch (record.outcome) {
            .found => .found,
            .not_found => .not_found,
            .not_unique => .not_unique,
        },
        .address = record.address,
        .ns = record.ns,
    });
}

test "scans reach runtime" {
    const Fake = @import("testing.zig").Fake;
    // tuft logs through `std.log`, and tests send that to the test runner
    const saved = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = saved;

    var fake: Fake = .{};
    fake.attach();
    defer fake.detach();
    attach();
    const mem = [_]u8{ 0x90, 0xC3 };
    _ = memory.Range.fromSlice(&mem).scan("missing", "CC CC");
    try std.testing.expectEqual(1, fake.scans);
    try std.testing.expectEqual(.not_found, fake.last_outcome);

    detach();
    _ = memory.Range.fromSlice(&mem).scan("missing", "CC CC");
    try std.testing.expectEqual(1, fake.scans);
}
