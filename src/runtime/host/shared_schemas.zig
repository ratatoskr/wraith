//! A plugin's or project's schemas, published as `.sal` text (see `SharedSchemas`), tweaks and names.

const std = @import("std");

const Owner = @import("tuft_event").Owner;
const OnGone = @import("Owned.zig").OnGone;
const core = @import("wraith_core");
const salamander_schema = @import("salamander_schema");

const Loaded = @import("../PluginLoader.zig").Loaded;
const SharedSchemas = @import("../SharedSchemas.zig");

const log = core.log.scoped(.wraith_runtime);

/// Its schemas' files, its dependencies' too, in place of what it shared before. Call when they change.
pub fn publish(loaded: *Loaded) void {
    @import("struct_tweaks.zig").publish(loaded);
    @import("addresses.zig").publishStatics(loaded);
    const lease = cleanup.lease(&loaded.owner) orelse return;
    defer lease.end();
    SharedSchemas.global.removeOwner(&loaded.owner);
    const s = loaded.schemas orelse return;
    const text = salamander_schema.bundle(SharedSchemas.global.allocator, s.files) catch return;
    defer SharedSchemas.global.allocator.free(text);
    // A project's are listed under its key, "" for the open one, like its tweaks
    const group = if (loaded.session) loaded.name else loaded.project orelse loaded.name;
    SharedSchemas.global.add(.{ .owner = &loaded.owner, .group = group, .name = "schemas", .text = text }) catch |err|
        log.warn("{s}'s schemas can't be used in the address list: {t}", .{ loaded.name, err });
}

var cleanup: OnGone(.released, released) = .{};

fn released(owner: *Owner) void {
    SharedSchemas.global.removeOwner(owner);
}

const tests = struct {
    const testing = std.testing;
    const schemas = @import("schemas.zig");

    test "kept until the plugin goes" {
        SharedSchemas.global = .init(testing.allocator);
        defer SharedSchemas.global.deinit();
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "kai");

        const before = SharedSchemas.global.generation();
        loaded.schemas = try schemas.fromFiles(&.{.{ .name = "kai/game.sal", .text = "struct Thing { u32 id; }" }});
        publish(&loaded);
        publish(&loaded);
        try testing.expect(SharedSchemas.global.generation() != before);

        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const kept = try SharedSchemas.global.copy(arena.allocator());
        try testing.expectEqual(1, kept.len);
        try testing.expectEqualStrings("kai", kept[0].group);
        try testing.expect(std.mem.indexOf(u8, kept[0].text, "struct Thing { u32 id; }") != null);

        const loaded_gen = SharedSchemas.global.generation();
        loaded.deinitForTest();
        try testing.expect(SharedSchemas.global.generation() != loaded_gen);
        try testing.expectEqual(0, (try SharedSchemas.global.copy(arena.allocator())).len);
    }
};

test {
    _ = tests;
    _ = @import("struct_tweaks.zig");
}
