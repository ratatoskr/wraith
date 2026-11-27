//! The languages plugins are written in, which `wraith new` makes and `wraith sdk` makes types for.

pub const Language = enum {
    zig,
    c,
    cpp,
    rust,
    cs,
    ts,
    js,
    lua,

    pub fn title(self: Language) []const u8 {
        return switch (self) {
            .zig => "Zig",
            .c => "C",
            .cpp => "C++",
            .rust => "Rust",
            .cs => "C#",
            .ts => "TypeScript",
            .js => "JavaScript",
            .lua => "Lua",
        };
    }

    /// Its wraith.json `provider`. Native DLLs have none.
    /// Run from source, so not built per arch.
    pub fn script(self: Language) bool {
        return self == .ts or self == .js or self == .lua;
    }

    /// C# compiled with NativeAOT is a native DLL, else .NET runs it.
    pub fn provider(self: Language, runtime: Runtime) []const u8 {
        return switch (self) {
            .zig, .c, .cpp, .rust => "native",
            .cs => if (runtime == .aot) "native" else "clr",
            .ts, .js => "js",
            .lua => "lua",
        };
    }

    /// What `wraith sdk <it> types` makes its types as. Zig's come from its build.
    pub fn sdk(self: Language) ?Sdk {
        return switch (self) {
            .zig => null,
            .c => .c,
            .cpp => .cpp,
            .rust => .rust,
            .cs => .cs,
            .ts, .js => .js,
            .lua => .lua,
        };
    }
};

/// For `--language`, and saying what it can be.
pub const names = "zig, c, cpp, rust, cs, ts, js or lua";

/// What `wraith sdk` makes types for.
pub const Sdk = enum { js, lua, cs, rust, c, cpp };

/// What builds a C or C++ plugin.
pub const Build = enum {
    /// CMake, with the compiler it finds, like MSVC
    cmake,
    /// `zig build`, with Wraith's SDK as a Zig package
    zig,
};

/// How a C# plugin runs.
pub const Runtime = enum {
    /// Compiled with NativeAOT into a native DLL
    aot,
    /// Run by .NET, the game's or the installed one
    clr,
};
