# Examples

The same plugin in every language Wraith runs: [Zig](zig), [C](c), [TypeScript](typescript), [Lua](lua) and C#, twice: [NativeAOT](csharp-aot) and [CoreCLR](csharp-clr). Each folder is a whole plugin, so compare them side by side or copy one to start your own.

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
| TypeScript | `import ... from "schema"`, typed by `npm run types` |
| Lua | `require("schema")` |
| C# | the `ExampleCsAot` or `ExampleCsClr` namespace, made into `.wraith/cs` as it builds |

## Building and loading them

Each builds into a folder for `wraith dev add`, and Wraith loads it from there next time the game starts. You'll need the tools for its language:

| Folder | Needs | Build | Then |
| --- | --- | --- | --- |
| [zig](zig) | Zig, the version Wraith's built with | `zig build` | `wraith dev add zig-out` |
| [c](c) | Zig, the version Wraith's built with, which compiles the C | `zig build` | `wraith dev add zig-out` |
| [typescript](typescript) | Node | `npm install`, `npm run build` | `wraith dev add dist` |
| [lua](lua) | nothing | nothing | `wraith dev add .` |
| [csharp-aot](csharp-aot) | the .NET 10 SDK, and C++ build tools | `dotnet publish` | `wraith dev add dist` |
| [csharp-clr](csharp-clr) | the .NET 10 SDK | `dotnet publish` | `wraith dev add dist` |

The Zig and C ones build against this checkout of Wraith. Your own would take Wraith from git, which `wraith new` sets up.

Load one at a time. They all hook the same function, and a function only takes one hook, so the second one fails with `AlreadyHooked`. The Trails Horizon plugin hooks it too.

## The two C# ones

Their code is the same. Only how they're built differs, and both say `"provider": "cs"` in `wraith.json`:

- **NativeAOT** compiles it into a native DLL, so the game doesn't need .NET. The DLL has .NET's runtime in it, which can't be unloaded, so once it's loaded it stays on till the game closes. Wraith won't turn it off or reload it, or the plugins it depends on. Restart the game to try a change.
- **CoreCLR** has .NET run it: the game's own .NET if it has one, otherwise the installed .NET 10, which Wraith starts. Players need .NET 10 installed for games without one. It unloads and reloads like a script plugin. `"clrMode"` in `wraith.json` can say to wait for the game's .NET instead, or to only run in it.

## The C one

It has no SDK on top. `wraith.h` is Wraith's API made from its schemas, so every call is one of those, like `Wraith_Hooks_detourNative(Wraith_Api_hooks(w), ...)`. Calls that can fail give `SAL_OK` or an error code, with what they make through a pointer at the end. `wraith_plugin.h` has the `wraith_plugin` export Wraith starts it through, with `WRAITH_PLUGIN(start, stop)`.

The game's code is found by name through the Schema area, `Wraith_Schema_address`, with the names `schema.h` gives, like `ExampleC_GameStateManager_spendMira_name`. Each function has a pointer type to call it through, like `ExampleC_GameStateManager_spendMira_fn`. What you hand Wraith, like a tweak's handler, is a table of function pointers you fill in with `SAL_TABLE`. Wraith stops calling them, and takes away the plugin's hooks, patches and tweaks, once it's unloading.

Its schemas can use Wraith's types, like `Vec3`, which come from `wraith.h` as `Wraith_Vec3`. A plugin it depends on has its schemas in `schema.h` too, under its namespace, and `wraith_service` in `start` gets what it offers. To offer a `[Service]` trait of its own, give `WRAITH_PLUGIN_WITH` a function for it, see `wraith_plugin.h`.
