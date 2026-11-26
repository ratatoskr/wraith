//! Which copy of the game's code a code or memory document shows (live or pre-hook), and a second
//! pane kept in step with the first.

const std = @import("std");

const memory = @import("tuft_mem");
const ui = @import("wraith_ui");

const AddressSource = memory.AddressSource;
const Memory = memory.Memory;

const labels: []const [:0]const u8 = &.{ "Live", "Snapshot", "Disk" };
pub const picker_width = 95;

/// What a view shows `source` through, `live` being its usual memory.
pub fn memoryOf(source: AddressSource, live: Memory) Memory {
    return memory.originals.memory(source) orelse live;
}

/// True if it changed.
pub fn picker(id: [:0]const u8, source: *AddressSource) bool {
    var which: usize = @backingInt(source.*);
    ui.setNextItemWidth(picker_width);
    const changed = ui.combo(id, &which, labels);
    ui.tooltip("Which copy of the game's code it shows: as it is now, the snapshot Wraith took as it started, or the game's exe on disk. The copies only have code, and can't be changed", .{});
    if (changed) source.* = @fromBackingInt(@intCast(which));
    return changed;
}

/// Keeps two views of the same kind where each other are, whichever was moved.
pub fn Synced(comptime View: type) type {
    return struct {
        const Self = @This();

        last: ?View.Place = null,

        /// After both drew.
        pub fn sync(self: *Self, a: *View, b: *View) void {
            const pa = a.place();
            const pb = b.place();
            const last = self.last orelse {
                b.setPlace(pa);
                self.last = pa;
                return;
            };
            if (!std.meta.eql(pa, last)) {
                b.setPlace(pa);
                self.last = pa;
            } else if (!std.meta.eql(pb, last)) {
                a.setPlace(pb);
                self.last = pb;
            }
        }

        pub fn reset(self: *Self) void {
            self.last = null;
        }
    };
}
