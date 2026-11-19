//! One tweak, from a project file or a plugin, and where it is in its life.

const Tweak = @This();

const std = @import("std");

const api = @import("wraith_api");
const input = @import("wraith_platform").input;
const Registry = @import("../settings/Registry.zig");
const Atomic = @import("tuft_arch").atomic.Value;

const protocol = api.script;
const format = api.tweak;

/// Changed only through the functions in `running.zig`.
pub const State = enum {
    off,
    /// Wanted. Starts on a tick, once the provider's there for a file's.
    waiting,
    /// Sent to its session or plugin, which hasn't said it's up yet.
    starting,
    running,
    /// Didn't start, so it's not wanted anymore. `problem` says why.
    failed,

    /// What its box shows and what's kept on for next time.
    pub fn wanted(self: State) bool {
        return switch (self) {
            .waiting, .starting, .running => true,
            .off, .failed => false,
        };
    }

    /// Its session or plugin has it, so it has to be told when it stops.
    pub fn started(self: State) bool {
        return self == .starting or self == .running;
    }
};

pub const Field = struct {
    tweak: *Tweak,
    def: *const format.Field,
    /// Its default key, the project's, if they're used.
    key: ?input.Chord = null,
    setting: ?*Registry.Setting = null,
    /// Its key was pressed. Flipped on the next tick.
    flip_requested: Atomic(bool) = .init(false),
};

/// `tweaks/x.rwt`. Empty for a plugin's. A group's tweaks have their group's.
path: []u8,
/// `x`, or `plugin:id` for a plugin's, or `x/Title` for one of group `x`'s tweaks, and
/// `x/Combat/Title` for one in a group nested in it.
name: []u8,
/// The plugin that added it, which runs it instead of a session.
plugin: ?[]u8 = null,
/// The installed project mod its file's from, by id. Null for the project's own.
mod: ?[]u8 = null,
/// A group, the file's own or one nested in it. Its state is its shared part's.
is_group: bool = false,
/// The group it's in, the file's or a nested one.
group: ?*Tweak = null,
/// The file's own entry, for anything in a group's file. Everything in it runs in its session.
file: ?*Tweak = null,
/// Its path in its group's file, like `Combat/Title`, which is what the provider knows it by.
part: []u8 = &.{},
/// Where it is in its group's file, its line.
index: u32 = 0,
state: State = .off,
/// A group's own box. Its shared part is up while this is on or anything in it is.
own: bool = false,
/// What a group's own box does to what's in it.
children: format.Children = .{},
/// Turned off while started, so its session has to be told once it's clear whether its group
/// goes too.
stop_pending: bool = false,
session: u32,
/// Its default key, the project's, if they're used.
key: ?input.Chord = null,
/// Its key, in the registry.
setting: ?*Registry.Setting = null,
/// What it last threw or logged as an error. Can outlive a run.
problem: ?[]u8 = null,
/// Its key was pressed. Toggled on the next tick, since unbinding waits for the callback.
toggle_requested: Atomic(bool) = .init(false),
/// Its file, parsed. A group's tweaks point into their group's.
parsed: std.heap.ArenaAllocator,
def: format.Tweak = .{},
/// From its file's `@group`, for a group.
group_title: ?[]const u8 = null,
/// What's wrong with its file, in `parsed`.
invalid: ?[]const u8 = null,
source_hash: ?u64 = null,
/// In `parsed`, one for each of `def.fields`.
fields: []Field = &.{},
/// Where its session put its data, in `live_arena`. Empty while it's off.
live: []const protocol.TweakState.Field = &.{},
live_arena: std.heap.ArenaAllocator,

pub fn liveField(self: *const Tweak, name: []const u8) ?*const protocol.TweakState.Field {
    for (self.live) |*f| if (std.mem.eql(u8, f.name, name)) return f;
    return null;
}

pub fn title(self: *const Tweak) []const u8 {
    if (self.is_group) return self.group_title orelse self.name;
    return self.def.title orelse self.name;
}

/// Its file's or its own, which `start` and `stop` go to.
pub fn sessionOf(self: *const Tweak) u32 {
    return if (self.file) |f| f.session else self.session;
}

/// The file's own entry for anything in a group's file, else itself.
pub fn fileOf(self: *Tweak) *Tweak {
    return self.file orelse self;
}

/// In `g`, at any depth.
pub fn isUnder(self: *const Tweak, g: *const Tweak) bool {
    var at = self.group;
    while (at) |p| : (at = p.group) if (p == g) return true;
    return false;
}

/// How many groups it's in.
pub fn depth(self: *const Tweak) u32 {
    var n: u32 = 0;
    var at = self.group;
    while (at) |p| : (at = p.group) n += 1;
    return n;
}

/// What its box shows: a group's own, else whether it's wanted.
pub fn isOn(self: *const Tweak) bool {
    return if (self.is_group) self.own else self.state.wanted();
}
