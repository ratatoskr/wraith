# Examples

The same plugin in every language Wraith runs: [Zig](zig), [C](c), [C++](cpp), [Rust](rust), [TypeScript](typescript), [Lua](lua) and C#, twice: [NativeAOT](csharp-aot) and [CoreCLR](csharp-clr). Each folder is a whole plugin, so compare them side by side or copy one to start your own.

It's for Trails beyond the Horizon (`kai.exe`), and adds four tweaks to the overlay's Tweaks window:

- **Free shopping** (Money) hooks the game's function that takes Mira away and has it take none.
- **Give Mira** (Money) runs the game's own function for getting Mira, with an amount you choose.
- **Tailing without being seen** (Field) patches two spots in the game's code while it's on.
- **Slower tailing gauge** (Field) lets the gauge fill at a pace you choose, with a mid hook that changes a register right in the game's code.

Between them they show what most plugins need: finding game code by signature in a schema, hooking a function and calling the original, calling the game's functions on one of its objects, patching code, and tweaks that turn on and off or run once.

## The schema

Every folder has the same [`schemas/horizon.sal`](zig/schemas/horizon.sal). It says where the game's `GameStateManager` is, its `giveMira` and `spendMira` functions, and the two spots for tailing, each found by a byte signature. Wraith reads it as the plugin loads, and each language gets it as its own types:

| Language | How it's used |
| --- | --- |
| Zig | `@import("schema")`, made as it builds |
| C | `#include "schema.h"`, made as it builds: its types, and each function and static's name and pointer type |
| Rust | `mod schema`, which includes `.wraith/rust/schema.rs`, made by `wraith sdk rust types`: its types, with the game's functions and statics to call, like `GameStateManager::instance()` |
| C++ | `#include "schema.hpp"`, made as it builds: its types, with the game's functions and statics to call, like `GameStateManager::instance()` |
| TypeScript | `import ... from "schema"`, typed by `npm run types` |
| Lua | `require("schema")` |
| C# | the `ExampleCsAot` or `ExampleCsClr` namespace, made into `.wraith/cs` as it builds |

## Building and loading them

Each builds into a folder for `wraith dev add`, and Wraith loads it from there next time the game starts. You'll need the tools for its language:

| Folder | Needs | Build | Then |
| --- | --- | --- | --- |
| [zig](zig) | Zig, the version Wraith's built with | `zig build` | `wraith dev add zig-out` |
| [c](c) | CMake and a C compiler like MSVC, and the `wraith` launcher. Or Zig, the version Wraith's built with | `cmake -B build`, `cmake --build build --config Release`. Or `zig build` | `wraith dev add dist`, or `zig-out` |
| [rust](rust) | Rust, and the `wraith` launcher | `wraith sdk rust build` | `wraith dev add dist` |
| [cpp](cpp) | CMake and a C++20 compiler like MSVC, and the `wraith` launcher. Or Zig, the version Wraith's built with | `cmake -B build`, `cmake --build build --config Release`. Or `zig build` | `wraith dev add dist`, or `zig-out` |
| [typescript](typescript) | Node | `npm install`, `npm run build` | `wraith dev add dist` |
| [lua](lua) | nothing | nothing | `wraith dev add .` |
| [csharp-aot](csharp-aot) | the .NET 10 SDK, and C++ build tools | `dotnet publish` | `wraith dev add dist` |
| [csharp-clr](csharp-clr) | the .NET 10 SDK | `dotnet publish` | `wraith dev add dist` |

Built with Zig, the Zig, C and C++ ones build against this checkout of Wraith. Your own would take Wraith from git, which `wraith new` sets up. Built with CMake, the C and C++ ones use the `wraith` launcher on PATH, or the one `-DWRAITH=<path>` says.

Load one at a time. They all hook the same function, and a function only takes one hook, so the second one fails with `AlreadyHooked`. The Trails Horizon plugin hooks it too.

## The two C# ones

Their code is the same. Only how they're built differs, and what their `wraith.json` says runs them:

- **NativeAOT** compiles it into a native DLL, so the game doesn't need .NET, and its provider is `"native"`. The DLL has .NET's runtime in it, which can't be unloaded, so once it's loaded it stays on till the game closes. Wraith won't turn it off or reload it, or the plugins it depends on. Restart the game to try a change.
- **CoreCLR** has .NET run it, with `"provider": "clr"`: the game's own .NET if it has one, otherwise the installed .NET 10, which Wraith starts. Players need .NET 10 installed for games without one. It unloads and reloads like a script plugin. `"clrMode"` in `wraith.json` can say to wait for the game's .NET instead, or to only run in it.

## The C one

It has no SDK on top. `wraith.h` is Wraith's API made from its schemas, so every call is one of those, like `Wraith_Hooks_detourNative(Wraith_Api_hooks(w), ...)`. Calls that can fail give `SAL_OK` or an error code, with what they make through a pointer at the end. `wraith_plugin.h` has the `wraith_plugin` export Wraith starts it through, with `WRAITH_PLUGIN(start, stop)`.

The game's code is found by name through the Schema area, `Wraith_Schema_address`, with the names `schema.h` gives, like `ExampleC_GameStateManager_spendMira_name`. Each function has a pointer type to call it through, like `ExampleC_GameStateManager_spendMira_fn`. What you hand Wraith, like a tweak's handler, is a table of function pointers you fill in with `SAL_TABLE`. Wraith stops calling them, and takes away the plugin's hooks, patches and tweaks, once it's unloading.

Its schemas can use Wraith's types, like `Vec3`, which come from `wraith.h` as `Wraith_Vec3`. A plugin it depends on has its schemas in `schema.h` too, under its namespace, and `wraith_service` in `start` gets what it offers. To offer a `[Service]` trait of its own, give `WRAITH_PLUGIN_WITH` a function for it, see `wraith_plugin.h`.

## The C++ one

`wraith.hpp` is Wraith's API as C++20, made from its schemas like `wraith.h`, but with namespaces and methods: `wraith::api().tweaks().addIn("Money", definition, handler)`. Calls that can fail give a `sal::Result`, which is true when it worked, with the code otherwise. Strings, spans and optionals go in as `std::string_view`, `std::span` and `std::optional`. It needs no exceptions or RTTI.

`wraith_plugin.hpp` makes a class the plugin with `WRAITH_PLUGIN(Example)`. Wraith makes it as the plugin starts, calls `start()` and `stop()`, and destroys it after. `schema.hpp` gives the game's code to call straight, like `GameStateManager::instance()->giveMira(n)`, found by the schema's signatures through Wraith.

What you hand Wraith is any class or lambda with the right method, like a tweak's handler, made into one with `Handler::of(x)`, which has to outlive it, or `sal::keep<Handler>(x)`, a heap copy Wraith lets go of. Wraith stops calling them, and takes away the plugin's hooks, patches and tweaks, once it's unloading. Async methods give a `sal::Future`, which you can `co_await`, and an async method can be a coroutine. To offer a `[Service]` trait, give the class `sal::Object service(std::string_view trait)`, see `wraith_plugin.hpp`.

## The Rust one

It doesn't need Zig. `wraith sdk rust types` writes `.wraith/rust`: the `salamander` crate, a `wraith` crate with Wraith's API and what makes it a plugin, and `schema.rs` for its schemas, for 32 and 64-bit both. Its `Cargo.toml` depends on the two crates by path, so `cargo build` and rust-analyzer work as usual once they're there. `wraith sdk rust build` writes them again, builds it for each arch in `wraith.json`, and puts `wraith_example_rust_x64.dll`, `wraith.json` and its schemas in `dist`.

`wraith::plugin!(Example)` makes a type the plugin: Wraith calls its `start`, which gives it, and `stop`. Calls that can fail give a `Result`, strings and slices go in as `&str` and `&[T]`, and calling the game's code is `unsafe`. What you hand Wraith, like a tweak's handler, is a closure or any type implementing its `...Impl` trait, made into one with `from_static`, or `keep` for a heap copy Wraith lets go of. Async methods give a `salamander::Future` to `.await`, and `salamander::spawn` makes an async block one. To offer a `[Service]` trait, give it a `service` method, with `wraith::offer`.

## Building C and C++ with CMake

Their `CMakeLists.txt` has the `wraith` launcher write `wraith.cmake`, this Wraith's CMake module, and calls `wraith_plugin(<id> <C|CXX> <sources>...)`. That makes the headers with `wraith sdk c types` or `wraith sdk cpp types` in the build folder, for the arch it's configured for (`-A Win32` for 32-bit), builds `wraith_<id>_<arch>.dll`, and puts it in `dist` with `wraith.json` and the schemas.

## When the types are made again

Every language's types are made by `wraith sdk <language> types`, which writes only files that changed, and `inputs.txt` beside them listing what they're made from: the `wraith` launcher, whose API they are, `wraith.json`, the plugin's schemas, and those of the plugins it depends on. So they're made again whenever any of that changes:

| Language | When |
| --- | --- |
| Zig, and C and C++ built with Zig | `zig build` tracks the schemas and Wraith's package itself |
| C and C++ built with CMake | each build, when anything in `inputs.txt` changed |
| Rust | `wraith sdk rust build`, and `cargo build` through `build.rs`, which reruns when anything in `inputs.txt` changes |
| C# | each `dotnet build` |
| TypeScript and JavaScript | each `npm run build`, and while `npm run dev` runs, when anything in `inputs.txt` changes |
| Lua | `wraith sdk lua types`, run again by hand, since they're only for the editor |
