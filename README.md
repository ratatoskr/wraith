# Wraith

[![CI](https://img.shields.io/github/actions/workflow/status/ratatoskr/wraith/main_ci.yml?branch=main&label=CI)](https://github.com/ratatoskr/wraith/actions/workflows/main_ci.yml)
[![License](https://img.shields.io/github/license/ratatoskr/wraith)](https://github.com/ratatoskr/wraith/blob/main/LICENSE)
[![Version](https://img.shields.io/github/v/tag/ratatoskr/wraith?label=version)](https://github.com/ratatoskr/wraith/tags)
[![Zig](https://img.shields.io/badge/dynamic/regex?url=https%3A%2F%2Fraw.githubusercontent.com%2Fratatoskr%2Fwraith%2Fmain%2Fbuild.zig.zon&search=minimum_zig_version%5Cs%2A%3D%5Cs%2A%22%28%5B%5E%22%2B%5D%2B%29&replace=%241&label=zig&color=f7a41d&logo=zig&logoColor=white)](https://github.com/ratatoskr/wraith/blob/main/build.zig.zon)
[![Docs](https://img.shields.io/badge/docs-docs.wraith.io-blue)](https://docs.wraith.io)

A mod loader for Windows games. It runs inside the game, draws an overlay and loads plugins.

Pre-release. Expect breaking changes.

Using it in online games can get you banned. Use it offline or in single-player.

## Want to download?

Get the Wraith app from [wraith.io](https://wraith.io). It installs Wraith, finds your games, and installs mods from the [Hub](https://hub.wraith.io). New to it? [Start here](https://docs.wraith.io/play/).

## Features

- Injects into a game, or loads as a proxy DLL.
- Finds games on Steam, GOG, Epic, Xbox and itch.io, and spots anti-cheat.
- An in-game overlay with settings and keybinds for every game or just one.
- A workbench for digging into games: memory viewer, disassembly, address list, scans, struct layouts, hooks, breakpoints, registers, file I/O and timings.
- Tweaks: small `.rwt` files with assembly, JS or Lua, turned on and off with keys.
- Projects: a game's tweaks, scripts, schemas and addresses, saved as plain files in its `workbench/` folder and exported as one `.rwp`.
- Imports Cheat Engine tables.
- Plugins in Zig, C, C++, C#, JavaScript or Lua, all with the same API.
- Installs plugins from the Wraith Hub, signed and checked.
- Keybind clashes between plugins get flagged.
- A command line for games, plugins and dev plugins.

## Building

You need the Zig version in `build.zig.zon` under `minimum_zig_version`. Then:

```
git clone https://github.com/ratatoskr/wraith
cd wraith
zig build
zig build test
```

[Tuft](https://github.com/ratatoskr/tuft) and [Salamander](https://github.com/ratatoskr/salamander) come from GitHub, pinned in `build.zig.zon`. To work on one alongside Wraith, clone it anywhere and build with `--fork`, like `zig build --fork=../tuft`.

`zig build build-test` builds the test programs into `zig-out/bin` without running them. Run those from this folder, not from `zig-out/bin`, since some read fixtures by path.

Want to help? See [CONTRIBUTING.md](https://github.com/ratatoskr/.github/blob/main/CONTRIBUTING.md). Found a security problem? See [SECURITY.md](https://github.com/ratatoskr/.github/blob/main/SECURITY.md).

## License

Copyright (c) 2026 Asgard. Wraith is under the GNU Affero General Public License v3.0, see [LICENSE](LICENSE). Plugins and scripts built on Wraith are works based on it, so if you share one, it's under the AGPL too.

Want to build something closed-source or commercial on Wraith? Ask about a commercial license at https://docs.wraith.io/commercial.

Third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).