#!/usr/bin/env node
// Packs Wraith's source as a Zig package anyone can fetch, for building Zig plugins:
//
//   node scripts/sdk.mjs <version> [--base <url>] [--out <folder>]
//
// It writes, in --out (default sdk-out):
//   wraith-<version>.tar.gz   this repo as committed, with the working copy's build.zig.zon, which
//                             has the version set. Its dependencies, tuft included, come from their
//                             own URLs in there
//   latest.json               {version, url, hash}, for `zig fetch --save=wraith <url>`
//
// --base is where they'll be, default https://dist.wraith.io/sdk. Plugins fetch from there, so the
// hash is checked against what got written here. Needs git, tar and zig.

import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";

const args = process.argv.slice(2);
const version = args[0];
if (!version || version.startsWith("--")) {
    console.error("usage: node scripts/sdk.mjs <version> [--base <url>] [--out <folder>]");
    process.exit(1);
}
const option = (name, fallback) => {
    const i = args.indexOf(name);
    return i >= 0 ? args[i + 1] : fallback;
};
const base = option("--base", "https://dist.wraith.io/sdk").replace(/\/+$/, "");
const out = resolve(option("--out", "sdk-out"));
const root = resolve(import.meta.dirname, "..");

const run = (cmd, cmdArgs, cwd = root) => execFileSync(cmd, cmdArgs, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] }).trim();

const globalCache = /\.global_cache_dir = "((?:[^"\\]|\\.)*)"/.exec(run("zig", ["env"]))[1].replaceAll("\\\\", "\\");

/** What `zig fetch` says a package's hash is. What it cached from a local file doesn't unpack right
 * when a build wants it later, so that's dropped and builds fetch it for real. */
function hashOf(file) {
    const hash = run("zig", ["fetch", file]);
    for (const name of [hash, `${hash}.tar.gz`]) rmSync(join(globalCache, "p", name), { recursive: true, force: true });
    return hash;
}

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });
const stage = join(out, "stage");

/** A repo's committed files in `stage/<name>`. Repacked after, since git's own tarballs start with
 * a header that Zig unpacks differently once it's fetching over HTTP. */
function staged(name, dir) {
    const to = join(stage, name);
    mkdirSync(to, { recursive: true });
    const tar = join(out, `${name}.tar`);
    run("git", ["archive", "--format=tar", "-o", tar, "HEAD"], dir);
    run("tar", ["-xf", tar, "-C", to]);
    rmSync(tar);
    return to;
}

function pack(name, file) {
    run("tar", ["-czf", join(out, file), "-C", stage, name]);
    rmSync(join(stage, name), { recursive: true, force: true });
    const hash = hashOf(join(out, file));
    console.log(`${file} ${hash}`);
    return hash;
}

// Plugins can't fetch a dependency that's only a folder on this machine
const zon = readFileSync(join(root, "build.zig.zon"), "utf8");
if (/\.path = "/.test(zon)) throw new Error("build.zig.zon has a .path dependency. Give it a URL so plugins can fetch it");

const wraithStage = staged("wraith", root);
copyFileSync(join(root, "build.zig.zon"), join(wraithStage, "build.zig.zon"));
const wraithFile = `wraith-${version}.tar.gz`;
const wraithHash = pack("wraith", wraithFile);
rmSync(stage, { recursive: true, force: true });

const latest = { version, url: `${base}/${wraithFile}`, hash: wraithHash };
writeFileSync(join(out, "latest.json"), JSON.stringify(latest, null, 2) + "\n");
console.log(`Plugins get it with: zig fetch --save=wraith ${latest.url}`);
