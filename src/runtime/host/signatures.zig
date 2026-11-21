//! Signatures service. Plugin scans go into `Names` under the plugin's owner.

const std = @import("std");

const memory = @import("tuft_mem");
const Owner = @import("tuft_event").Owner;
const OnGone = @import("Owned.zig").OnGone;
const api = @import("wraith_api");

const Loaded = @import("../PluginLoader.zig").Loaded;
const Names = @import("../Names.zig");
const OriginalCode = @import("../OriginalCode.zig");

pub fn record(loaded: *Loaded, scan: api.Scan) void {
    const lease = cleanup.lease(&loaded.owner) orelse return;
    defer lease.end();
    Names.global.recordScan(&loaded.owner, &.{
        .name = scan.name,
        .pattern = scan.pattern,
        .start = scan.start,
        .len = scan.len,
        .original = scan.original,
        .outcome = switch (scan.outcome) {
            .found => .found,
            .not_unique => .not_unique,
            .not_found => .not_found,
        },
        .address = scan.address,
        .ns = scan.ns,
    }) catch {};
}

var cleanup: OnGone(.released, released) = .{};

fn released(owner: *Owner) void {
    Names.global.removeOwner(owner);
}

pub fn original(start: usize, len: usize) ?[*]const u8 {
    return OriginalCode.global.find(start, len);
}

test "scans listed until release" {
    const sdk = @import("wraith_sdk");
    const core = @import("wraith_core");
    const saved = core.log.mute(&.{.memory});
    defer core.log.setFilter(saved);
    Names.global = .init(std.testing.allocator);
    defer Names.global.deinit();

    var loaded: Loaded = undefined;
    loaded.initForTest(std.testing.allocator, "kai");
    sdk.Owner.attach(loaded.root());
    defer sdk.Owner.detach();
    sdk.signatures.attach();
    defer sdk.signatures.detach();

    const mem = [_]u8{ 0x90, 0xC3 };
    _ = memory.Range.fromSlice(&mem).scan("ret", "C3");
    var out: [2]Names.ScanInfo = undefined;
    try std.testing.expectEqual(1, Names.global.scanList(&out));
    try std.testing.expectEqual(&loaded.owner, out[0].owner.?);
    try std.testing.expectEqualStrings("kai", out[0].owner_name.get());
    try std.testing.expectEqualStrings("ret", out[0].name.get());
    try std.testing.expectEqual(@intFromPtr(&mem) + 1, out[0].scanned.address);
    try std.testing.expectEqual(@intFromPtr(&mem) + 1, try Names.global.get("kai.ret"));

    loaded.owner.release();
    try std.testing.expectEqual(0, Names.global.scanCount());
}
