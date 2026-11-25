//! Signatures, for native plugins. Their own scans go to the runtime, which lists them, and their
//! tuft scans of other copies of the game's code read the runtime's: the snapshot from when it
//! started, and the exe from disk.
//!
//! `find` is the usual way to look one up. It goes through the runtime like a schema's `[Sig]`
//! does, so it's listed, reused, and falls through the copies the plugin allows.

const std = @import("std");

const memory = @import("tuft_mem");
const api = @import("wraith_api");

const Owner = @import("Owner.zig");

var attached = false;
var previous: ?memory.scans.Recorder = null;
var previous_snapshot: ?memory.originals.Provider = null;
var previous_disk: ?memory.originals.Provider = null;

pub fn attach() void {
    if (attached) return;
    attached = true;
    previous = memory.scans.setRecorder(forward);
    previous_snapshot = memory.originals.setProvider(.snapshot, snapshotCopy);
    previous_disk = memory.originals.setProvider(.disk, diskCopy);
}

pub fn detach() void {
    if (!attached) return;
    _ = memory.scans.setRecorder(previous);
    _ = memory.originals.setProvider(.snapshot, previous_snapshot);
    _ = memory.originals.setProvider(.disk, previous_disk);
    attached = false;
}

pub const Found = struct {
    address: usize,
    /// Not live means something hooked the code it was found in.
    source: memory.AddressSource,
};

pub const Error = error{ NotFound, Unreadable, InvalidAddress, Unavailable, Failed };

/// Where `sig` is, through the runtime. `text` is any location text, like `sig("48 8B ??", Rip)`.
pub fn findText(text: []const u8) Error!Found {
    const owner = Owner.current() orelse return error.Unavailable;
    const found = owner.root.addresses().find(text, &.{}) catch |err| return switch (err) {
        error.NotFound => error.NotFound,
        error.Unreadable => error.Unreadable,
        error.InvalidAddress => error.InvalidAddress,
        else => error.Failed,
    };
    return .{ .address = found.address, .source = switch (found.source) {
        .snapshot => .snapshot,
        .disk => .disk,
        else => .live,
    } };
}

/// Where `sig` is, through the runtime.
pub fn find(sig: memory.Sig) Error!Found {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{f}", .{sig}) catch return error.InvalidAddress;
    return findText(text);
}

/// Which copies of the game's code this plugin's lookups may use. Wraith's setting till it's called.
pub fn setSources(sources: memory.Sources) void {
    const owner = Owner.current() orelse return;
    owner.root.addresses().setSources(.{ .live = sources.live, .snapshot = sources.snapshot, .disk = sources.disk });
}

fn snapshotCopy(start: usize, len: usize) ?[*]const u8 {
    return copyOf(start, len, .snapshot);
}

fn diskCopy(start: usize, len: usize) ?[*]const u8 {
    return copyOf(start, len, .disk);
}

fn copyOf(start: usize, len: usize, source: api.wraith.AddressSource) ?[*]const u8 {
    const owner = Owner.own() orelse return null;
    return @ptrFromInt(owner.root.diagnostics().codeCopy(start, len, source));
}

fn forward(record: *const memory.scans.Record) void {
    const owner = Owner.current() orelse return;
    owner.root.diagnostics().recordScanFrom(.{
        .name = record.name,
        .pattern = record.pattern,
        .start = record.start,
        .length = record.len,
        .source = switch (record.source) {
            .live => .live,
            .snapshot => .snapshot,
            .disk => .disk,
        },
        .first_match = record.first_match,
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
