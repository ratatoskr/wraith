//! Script sessions protocol over messages, between the workbench and the runtime's sessions.

const tweak = @import("tweak.zig");

pub const runtime = "wraith";

pub const topics = struct {
    pub const run = "wraith.script.run";
    pub const reset = "wraith.script.reset";
    pub const stop = "wraith.script.stop";
    pub const output = "wraith.script.output";
    pub const sessions = "wraith.script.sessions";
    /// A `TweakState`, once a tweak is on.
    pub const tweak = "wraith.script.tweak";
    /// A `TweakSwitched`, from the runtime, when a tweak's box goes on or off.
    pub const switched = "wraith.tweak.switched";
};

pub const Run = struct {
    session: u32,
    name: []const u8 = "",
    code: []const u8,
    /// What it's in, `"js"` or `"lua"`. A tweak's file says its own.
    language: []const u8 = "js",
    /// `code` is a `.rwt` tweak, not JS. The session's only run, or a group's, one for each `part`.
    tweak: bool = false,
    /// A tweak's data values from the UI, over its own.
    values: []const tweak.Value = &.{},
    /// For a group's file, the path of the `@tweak` or nested `@group` to turn on, like
    /// `Combat/Max bravery`, or empty for the file's group. Its session comes up with the file's
    /// shared part first, a nested group's has to be on already, and each part gets a scope of
    /// its own in its group's.
    part: []const u8 = "",
    /// The file's shared part's values, for the run that brings it up.
    shared_values: []const tweak.Value = &.{},
};

/// Where a tweak's data went, so the UI can show and change it.
pub const TweakState = struct {
    session: u32,
    /// The path of what in a group's file it's for, empty for its shared part or a lone tweak.
    part: []const u8 = "",
    fields: []const Field = &.{},
    /// Its `@data` and `@sym` names, for the game's names while it's on.
    names: []const Name = &.{},

    pub const Field = struct {
        name: []const u8,
        address: u64,
        /// From its `Choices(function)`.
        choices: ?[]const tweak.Choice = null,
    };

    pub const Name = struct {
        name: []const u8,
        address: u64,
        /// Like `u32` for `@data`. Empty for `@sym`.
        type: []const u8 = "",
    };
};

pub const Target = struct {
    session: u32,
    /// Just this part of a group's file by path, with everything in it, leaving the rest on.
    part: []const u8 = "",
};

pub const Kind = enum { code, value, thrown, info, warn, err, debug };

pub const Output = struct {
    session: u32,
    kind: Kind,
    text: []const u8,
    /// The path of what in a group's file it came from, empty for its shared part.
    part: []const u8 = "",
};

pub const Running = struct {
    session: u32,
    name: []const u8 = "",
    frames: u32 = 0,
    keybinds: u32 = 0,
    hooks: u32 = 0,

    pub fn total(self: Running) u32 {
        return self.frames + self.keybinds + self.hooks;
    }
};

pub const Sessions = struct {
    sessions: []const Running = &.{},
};
