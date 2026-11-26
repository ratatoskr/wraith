//! Leases on parts of the game only one plugin can handle at a time, like ticks or the camera, from
//! `lease.sal`. A game or engine plugin claims the parts it can do, and the best placed one holds
//! each: a game's plugin over a game engine's over the rest, then the one that loaded later. What a
//! plugin does for a part only counts while it holds it, so it can leave the part be, or unhook it,
//! till it's told it has it.
//!
//!     self.ticks = try sdk.threads.claimTicks(.onChange(self, ticksChanged));
//!     self.camera = try sdk.Lease.claimCamera(.onChange(self, cameraChanged));

const api = @import("wraith_api");
const Owner = @import("Owner.zig");

const W = api.wraith;

pub const Error = error{ OwnerGone, Failed };

pub const Lease = struct {
    object: W.Lease,

    /// Told when the plugin gets the part, with true, or loses it to a better placed one, with
    /// false. Not for its own `release`. Any thread, outside Wraith's locks, so it can call back in.
    pub const Changed = struct {
        callback: ?W.Lease.Changed,

        /// `func(target, held)` each time.
        pub fn onChange(target: anytype, comptime func: fn (@TypeOf(target), bool) void) Changed {
            return .{ .callback = W.Lease.Changed.init(target, func) };
        }

        /// Nothing's told. It can still ask `held`.
        pub const none: Changed = .{ .callback = null };
    };

    /// Whether it holds the part now. Any thread.
    pub fn held(self: Lease) bool {
        return self.object.held();
    }

    /// Gives the part up for good, to the next best. Fine to call twice. It happens anyway when the
    /// plugin goes.
    pub fn release(self: Lease) void {
        self.object.release();
    }

    pub const Part = W.Lease.Part;

    /// Who holds a part, from `holder`.
    pub const Holder = struct {
        /// The plugin's id. Good till the thread's next call into Wraith.
        plugin: []const u8,
        /// It's this plugin.
        mine: bool,
    };

    /// Who holds `part`, or null if nobody does and Wraith does what it can itself, like the
    /// clocks for the speed. For any plugin. Any thread.
    pub fn holder(part: Part) ?Holder {
        const owner = Owner.current() orelse return null;
        const h = owner.root.leases().holder(part);
        if (!h.held) return null;
        return .{ .plugin = h.plugin, .mine = h.mine };
    }

    /// The game's camera, for the free camera. Only the holder's `setWorld` and `camera` count.
    pub fn claimCamera(changed: Changed) Error!Lease {
        const owner = Owner.current() orelse return error.OwnerGone;
        return .{ .object = owner.root.camera().claim(changed.callback) catch return error.Failed };
    }

    /// Posing the game's characters. Only the holder's skeletons are posed.
    pub fn claimPosing(changed: Changed) Error!Lease {
        const owner = Owner.current() orelse return error.OwnerGone;
        return .{ .object = owner.root.posing().claim(changed.callback) catch return error.Failed };
    }

    /// The game's speed: `handler` gets it while it's held, and 1 as it's lost or let go, to put the
    /// game's own back.
    pub fn claimSpeed(handler: W.Game.SpeedHandler, changed: Changed) Error!Lease {
        const owner = Owner.current() orelse return error.OwnerGone;
        return .{ .object = owner.root.game().claimSpeed(handler, changed.callback) catch return error.Failed };
    }
};
