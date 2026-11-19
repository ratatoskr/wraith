//! Scoped timings for the Timings window.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");

const Owner = @import("Owner.zig");

pub const Zone = core.timing.Zone;
pub const Scope = core.timing.Scope;

/// Shared clock across the runtime, plugins and threads.
pub const now = core.timing.now;

/// `zone` must not move. Unlist it before freeing early.
pub fn list(zone: *Zone) void {
    const owner = Owner.current() orelse return;
    listIn(owner, zone);
}

fn listIn(owner: Owner, zone: *Zone) void {
    owner.root.diagnostics().addZone(@intFromPtr(zone), Zone.version);
}

/// `heap` must not move.
pub fn listHeap(heap: *core.heap.Usage) void {
    const owner = Owner.current() orelse return;
    owner.root.diagnostics().addHeap(@intFromPtr(heap), core.heap.Usage.version);
}

pub fn unlist(zone: *Zone) void {
    const owner = Owner.current() orelse return;
    owner.root.diagnostics().removeZone(@intFromPtr(zone));
}

pub fn unlistHeap(heap: *core.heap.Usage) void {
    const owner = Owner.current() orelse return;
    owner.root.diagnostics().removeHeap(@intFromPtr(heap));
}

pub fn scope(comptime name: []const u8) Scope {
    const Static = struct {
        var zone: Zone = .init(name);
        var listed: Atomic(u8) = .init(0);
    };
    if (Static.listed.load(.acquire) != 2) listOnce(&Static.zone, &Static.listed);
    return Static.zone.begin();
}

fn listOnce(zone: *Zone, listed: *Atomic(u8)) void {
    if (listed.cmpxchgStrong(0, 1, .acq_rel, .acquire) != null) return;
    // Lives as long as the DLL, so it's the DLL's own owner's, not whoever timed first
    if (Owner.own()) |owner| listIn(owner, zone);
    listed.store(2, .release);
}
