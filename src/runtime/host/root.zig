//! The runtime's services behind `wraith.sal`'s areas, one file each.

const std = @import("std");

const api = @import("wraith_api");

const Loaded = @import("../PluginLoader.zig").Loaded;

pub const log = @import("log.zig");
pub const hooks = @import("hooks.zig");
pub const config = @import("config.zig");
pub const ui = @import("ui.zig");
pub const keybinds = @import("keybinds.zig");
pub const settings = @import("settings.zig");
pub const lists = @import("lists.zig");
pub const messages = @import("messages.zig");
pub const frame = @import("frame.zig");
pub const leases = @import("leases.zig");
pub const threads = @import("threads.zig");
pub const capture = @import("capture.zig");
pub const diagnostics = @import("diagnostics.zig");
pub const signatures = @import("signatures.zig");
pub const code = @import("code.zig");
pub const addresses = @import("addresses.zig");
pub const tweaks = @import("tweaks.zig");
pub const shared_schemas = @import("shared_schemas.zig");
pub const projects = @import("projects.zig");
pub const libraries = @import("libraries.zig");
pub const salamander = @import("salamander.zig");
pub const wraith = @import("wraith.zig");
pub const schemas = @import("schemas.zig");
pub const images = @import("images.zig");
pub const vfs = @import("vfs.zig");
pub const memory = @import("memory.zig");
pub const watches = @import("watches.zig");
pub const sound = @import("sound.zig");
pub const workbench_panels = @import("workbench_panels.zig");
pub const windows = @import("windows.zig");
pub const Owned = @import("Owned.zig").Owned;
pub const OnGone = @import("Owned.zig").OnGone;
pub const stopTagged = @import("Owned.zig").stopTagged;

test {
    _ = log;
    _ = hooks;
    _ = config;
    _ = ui;
    _ = keybinds;
    _ = messages;
    _ = frame;
    _ = capture;
    _ = diagnostics;
    _ = signatures;
    _ = code;
    _ = addresses;
    _ = tweaks;
    _ = settings;
    _ = lists;
    _ = shared_schemas;
    _ = projects;
    _ = libraries;
    _ = salamander;
    _ = images;
    _ = vfs;
    _ = memory;
    _ = watches;
    _ = sound;
    _ = workbench_panels;
    _ = windows;
    _ = @import("scans.zig");
    _ = @import("scratch.zig");
    _ = @import("memory_area.zig");
    _ = @import("code_area.zig");
    _ = @import("files_area.zig");
    _ = @import("game_area.zig");
    _ = @import("photo_area.zig");
    _ = @import("ranked.zig");
    _ = leases;
    _ = @import("managed_area.zig");
    _ = @import("sync_area.zig");
    _ = @import("hooks_area.zig");
    _ = @import("cpu.zig");
    _ = @import("../ui/MenuItems.zig");
    _ = @import("../ui/Gizmos.zig");
}
