# Examples

The same plugin in every language Wraith runs: [Zig](zig), [TypeScript](typescript), [Lua](lua) and C#, twice: [NativeAOT](csharp-aot) and [CoreCLR](csharp-clr). Each folder is a whole plugin, so compare them side by side or copy one to start your own.

It's for Trails beyond the Horizon (`kai.exe`), and adds three tweaks to the overlay's Tweaks window:

- **Free shopping** (Money) hooks the game's function that takes Mira away and has it take none.
- **Give Mira** (Money) runs the game's own function for getting Mira, with an amount you choose.
- **Tailing without being seen** (Field) patches two spots in the game's code while it's on.

Between them they show what most plugins need: finding game code by signature in a schema, hooking a function and calling the original, calling the game's functions on one of its objects, patching code, and tweaks that turn on and off or run once.

## The schema

Every folder has the same [`schemas/horizon.sal`](zig/schemas/horizon.sal). It says where the game's `GameStateManager` is, its `giveMira` and `spendMira` functions, and the two spots for tailing, each found by a byte signature. Wraith reads it as the plugin loads, and each language gets it as its own types:

| Language | How it's used |
| --- | --- |
| Zig | `@import("schema")`, made as it builds |
| TypeScript | `import ... from "schema"`, typed by `npm run types` |
| Lua | `require("schema")` |
| C# | the `ExampleCsAot` or `ExampleCsClr` namespace, made into `.wraith/cs` as it builds |

## Building and loading them

Each builds into a folder for `wraith dev add`, and Wraith loads it from there next time the game starts. You'll need the tools for its language:

| Folder | Needs | Build | Then |
| --- | --- | --- | --- |
| [zig](zig) | Zig, the version Wraith's built with | `zig build` | `wraith dev add zig-out` |
| [typescript](typescript) | Node | `npm install`, `npm run build` | `wraith dev add dist` |
| [lua](lua) | nothing | nothing | `wraith dev add .` |
| [csharp-aot](csharp-aot) | the .NET 10 SDK, and C++ build tools | `dotnet publish` | `wraith dev add dist` |
| [csharp-clr](csharp-clr) | the .NET 10 SDK | `dotnet publish` | `wraith dev add dist` |

The Zig one builds against this checkout of Wraith. Your own would take Wraith from git, which `wraith new` sets up.

Load one at a time. They all hook the same function, and a function only takes one hook, so the second one fails with `AlreadyHooked`. The Trails Horizon plugin hooks it too.

## The two C# ones

Their code is the same. Only how they're built differs, and both say `"provider": "cs"` in `wraith.json`:

- **NativeAOT** compiles it into a native DLL, so the game doesn't need .NET. The DLL has .NET's runtime in it, which can't be unloaded, so once it's loaded it stays on till the game closes. Wraith won't turn it off or reload it, or the plugins it depends on. Restart the game to try a change.
- **CoreCLR** has .NET run it: the game's own .NET if it has one, otherwise the installed .NET 10, which Wraith starts. Players need .NET 10 installed for games without one. It unloads and reloads like a script plugin. `"clrMode"` in `wraith.json` can say to wait for the game's .NET instead, or to only run in it.