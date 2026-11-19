//! Settings service. Tells each owner where its settings folders are.

const Loaded = @import("../PluginLoader.zig").Loaded;

pub fn directory(loaded: *Loaded) []const u8 {
    return loaded.config_dir;
}

pub fn gameDirectory(loaded: *Loaded) []const u8 {
    return loaded.game_config_dir;
}
