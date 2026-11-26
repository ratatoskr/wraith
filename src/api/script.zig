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
    /// A `TweakSwitched` from the runtime.
    pub const switched = "wraith.tweak.switched";
};

pub const Run = struct {
    session: u32,
    name: []const u8 = "",
    code: []const u8,
    /// `"js"` or `"lua"`. A tweak's file says its own.
    language: []const u8 = "js",
    /// `code` is a `.rwt` tweak. The session's only run, or one per `part` for a group.
    tweak: bool = false,
    /// A tweak's data values from the UI, over its own.
    values: []const tweak.Value = &.{},
    /// For a group's file, the path to turn on, like `Combat/Max bravery`, or empty for the file's group.
    /// The shared part comes up first, and a nested group's must already be on.
    part: []const u8 = "",
    /// The file's shared part's values, for the run that brings it up.
    shared_values: []const tweak.Value = &.{},
    /// Whose schemas and names it uses: empty for the open project, else a mod id. Only the first run counts.
    project: []const u8 = "",
    /// Changing it restarts the session.
    thread: Thread = .game,
};

/// Where a session runs. With nothing driving ticks, both are the render thread.
pub const Thread = enum {
    /// Ticks, where engine objects can be used.
    game,
    /// Frames, where ImGui can be drawn.
    render,
};

/// Where a tweak's data went, so the UI can show and change it.
pub const TweakState = struct {
    session: u32,
    /// Path in a group's file, empty for its shared part or a lone tweak.
    part: []const u8 = "",
    fields: []const Field = &.{},
    /// Its `@data` and `@sym` names, added to the game's while it's on.
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
    /// Just this part of a group's file and what's in it, leaving the rest on.
    part: []const u8 = "",
};

pub const Kind = enum { code, value, thrown, info, warn, err, debug };

pub const Output = struct {
    session: u32,
    kind: Kind,
    text: []const u8,
    /// Path in a group's file, empty for its shared part.
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
