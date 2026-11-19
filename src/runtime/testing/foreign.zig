//! A DLL that isn't a Wraith plugin, for tests that load one where a plugin's expected.

export fn foreign_marker() callconv(.c) u32 {
    return 1;
}
