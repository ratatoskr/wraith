//! File > Export as mod. Asks what the project is on the hub, prefilled from last time or the game
//! that's running, checks it like the hub does, then writes the project as a mod's zip where you
//! pick. That's what you send someone or upload to the hub.

const ExportMod = @This();

const std = @import("std");

const ui = @import("wraith_ui");
const tuft_window = @import("tuft_window");
const Message = @import("tuft_text").Message;

const game_engine = @import("wraith_game").game_engine;

const Workbench = @import("Workbench.zig");
const GameInfo = @import("../../GameInfo.zig");
const ProjectManifest = @import("../../ProjectManifest.zig");

const popup = "Export as mod##export_mod";
const red: ui.Color = .{ 1, 0.5, 0.5, 1 };

id: [65:0]u8 = @splat(0),
title: [81:0]u8 = @splat(0),
summary: [201:0]u8 = @splat(0),
author: [65:0]u8 = @splat(0),
version: [33:0]u8 = @splat(0),
description: [4096:0]u8 = @splat(0),
license: [65:0]u8 = @splat(0),
homepage: [257:0]u8 = @splat(0),
repo: [257:0]u8 = @splat(0),
/// Comma-separated, like these images.
tags: [257:0]u8 = @splat(0),
icon: [129:0]u8 = @splat(0),
images: [1025:0]u8 = @splat(0),
wraith: [17:0]u8 = @splat(0),
/// Who it's for: one game by `ids` and `exes`, every game made with `engine`, or any game.
target: Target = .game,
/// Comma-separated.
ids: [513:0]u8 = @splat(0),
exes: [513:0]u8 = @splat(0),
engine: game_engine.GameEngine = .unity,
/// Comma-separated, like IL2CPP.
variants: [129:0]u8 = @splat(0),
depends: [513:0]u8 = @splat(0),
problem: Message(200) = .{},
open_popup: bool = false,

pub const Target = enum { game, game_engine, any };

/// What the running game would be in `wraith.json`.
pub fn thisGame() ProjectManifest.Game {
    const g = &GameInfo.global;
    const id = g.id();
    return .{
        // A local copy's id is its folder's, which means nothing anywhere else
        .id = if (g.store == .local or std.mem.eql(u8, id, "unknown")) null else id,
        .exe = if (g.name().len > 0) g.name() else null,
    };
}

/// Prefills it and opens it on the next frame. Render thread.
pub fn start(self: *ExportMod, wb: *Workbench) void {
    const project = wb.project orelse return;
    var arena: std.heap.ArenaAllocator = .init(wb.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var why: []const u8 = "";
    self.problem = .{};
    const saved = ProjectManifest.read(a, project, &why) catch blk: {
        self.problem.print("Its wraith.json can't be read, so this starts over: {s}", .{why});
        break :blk null;
    };
    const d = saved orelse (ProjectManifest.defaults(a, project.name(), thisGame()) catch return);
    set(&self.id, d.id);
    set(&self.title, d.title);
    set(&self.summary, d.summary);
    set(&self.author, if (d.author.len > 0) d.author else lastAuthor(wb));
    set(&self.version, d.version);
    set(&self.description, d.description);
    set(&self.license, d.license);
    set(&self.homepage, d.homepage);
    set(&self.repo, d.repo);
    setList(&self.tags, d.tags);
    set(&self.icon, d.icon);
    setList(&self.images, d.images);
    set(&self.wraith, d.wraith);
    setList(&self.ids, d.ids);
    setList(&self.exes, d.exes);
    setList(&self.variants, d.game_engine_variants);
    self.engine = std.meta.stringToEnum(game_engine.GameEngine, d.game_engine) orelse GameInfo.global.game_engine orelse .unity;
    self.target = if (d.game_engine.len > 0) .game_engine else if (d.ids.len > 0 or d.exes.len > 0) .game else .any;
    setList(&self.depends, d.depends);
    self.open_popup = true;
}

fn lastAuthor(wb: *Workbench) []const u8 {
    const shell = wb.shell orelse return "";
    return shell.registry.get(shell.own.export_author).text;
}

fn set(buf: anytype, value: []const u8) void {
    const n = @min(value.len, buf.len);
    @memcpy(buf[0..n], value[0..n]);
    @memset(buf[n..], 0);
}

fn setList(buf: anytype, items: []const []const u8) void {
    var w: std.Io.Writer = .fixed(buf[0..buf.len]);
    for (items, 0..) |item, i| {
        if (i > 0) w.writeAll(", ") catch break;
        w.writeAll(item) catch break;
    }
    @memset(buf[w.end..], 0);
}

fn text(buf: anytype) []const u8 {
    return std.mem.trim(u8, std.mem.sliceTo(buf, 0), " \t\r\n");
}

/// Split at commas, spaces trimmed, empty ones dropped.
fn list(a: std.mem.Allocator, buf: anytype) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, std.mem.sliceTo(buf, 0), ',');
    while (it.next()) |part| {
        const item = std.mem.trim(u8, part, " \t\r\n");
        if (item.len > 0) try out.append(a, item);
    }
    return out.items;
}

/// What's in the boxes, in `a`.
pub fn details(self: *const ExportMod, a: std.mem.Allocator) !ProjectManifest.Details {
    return .{
        .id = text(&self.id),
        .title = text(&self.title),
        .summary = text(&self.summary),
        .author = text(&self.author),
        .version = text(&self.version),
        .description = text(&self.description),
        .license = text(&self.license),
        .homepage = text(&self.homepage),
        .repo = text(&self.repo),
        .tags = try list(a, &self.tags),
        .icon = text(&self.icon),
        .images = try list(a, &self.images),
        .wraith = text(&self.wraith),
        .ids = if (self.target == .game) try list(a, &self.ids) else &.{},
        .exes = if (self.target == .game) try list(a, &self.exes) else &.{},
        .game_engine = if (self.target == .game_engine) @tagName(self.engine) else "",
        .game_engine_variants = if (self.target == .game_engine) try list(a, &self.variants) else &.{},
        .depends = try list(a, &self.depends),
    };
}

/// Inside the workbench's own window, after the menu bar.
pub fn draw(self: *ExportMod, wb: *Workbench) void {
    if (self.open_popup) {
        self.open_popup = false;
        _ = ui.raw("ImGui_OpenPopup")(ui.str(popup), 0);
    }
    ui.raw("ImGui_SetNextWindowSize")(.{ .x = ui.scaled(620), .y = 0 }, ui.c.ImGuiCond_Appearing);
    if (!ui.raw("ImGui_BeginPopupModal")(ui.str(popup), null, 0)) return;
    defer ui.raw("ImGui_EndPopup")();

    ui.textWrapped("A zip of this project as a mod, to send someone or upload to the Wraith Hub. What's here is kept in the project as its wraith.json, for next time.", .{});
    ui.spacing();
    field("Title", &self.title, "Shown in lists, like Kai Tables");
    field("Id", &self.id, "Its name on the hub, like kai_tables. Lowercase letters, digits, _ and -");
    field("Summary", &self.summary, "One line, shown in lists");
    field("Author", &self.author, "Who made it");
    field("Version", &self.version, "Like 1.2.0. The hub needs a new one for each upload");
    self.drawTarget();
    if (ui.collapsingHeader("More", false)) {
        ui.setNextItemWidth(ui.fill);
        _ = ui.inputTextMultiline("##description", &self.description, .{ ui.fill, ui.scaled(90) }, .{});
        ui.tooltip("Markdown, shown on its page on the hub", .{});
        field("License", &self.license, "An SPDX id, like MIT");
        field("Homepage", &self.homepage, "https://...");
        field("Repo", &self.repo, "Where its source is, https://...");
        field("Tags", &self.tags, "Comma-separated words for finding it on the hub, like ui, camera");
        field("Icon", &self.icon, "A picture in the project, like icon.png. Square works best");
        field("Images", &self.images, "Comma-separated screenshots in the project, like images/menu.png");
        field("Oldest Wraith", &self.wraith, "Like 0.4. Empty means any");
        field("Depends on", &self.depends, "Comma-separated mod ids, like unity or unity@1.2");
    }

    if (self.problem.message().len > 0) ui.textColored(red, "{s}", .{self.problem.message()});
    ui.spacing();
    if (ui.button("Export...")) {
        if (self.exportTo(wb)) ui.raw("ImGui_CloseCurrentPopup")();
    }
    ui.sameLine();
    if (ui.button("Cancel") or ui.isKeyPressed(.escape, false)) ui.raw("ImGui_CloseCurrentPopup")();
}

const target_labels = [_][:0]const u8{ "One game", "Every game made with a game engine", "Any game" };

/// Which games it's for, and what says so.
fn drawTarget(self: *ExportMod) void {
    ui.alignTextToFramePadding();
    ui.text("For", .{});
    ui.sameLineWith(ui.scaled(130), -1);
    ui.setNextItemWidth(ui.scaled(380));
    var which: usize = @backingInt(self.target);
    if (ui.combo("##for", &which, &target_labels)) self.target = @fromBackingInt(@intCast(which));
    switch (self.target) {
        .game => {
            field("Game ids", &self.ids, "Comma-separated, like steam-1245620. The hub needs at least one. Filled in from the game that's running");
            ui.sameLine();
            const game = thisGame();
            if (ui.smallButton("This game")) {
                if (game.id) |id| set(&self.ids, id);
                if (game.exe) |exe| set(&self.exes, exe);
            }
            ui.tooltip("{s}{s}{s}", .{ game.id orelse "Wraith has no id for this copy", if (game.exe != null) ", " else "", game.exe orelse "" });
            field("Exes", &self.exes, "Comma-separated, like kai.exe. Matches copies Wraith has no id for");
        },
        .game_engine => {
            ui.alignTextToFramePadding();
            ui.text("Game engine", .{});
            ui.sameLineWith(ui.scaled(130), -1);
            ui.setNextItemWidth(ui.scaled(380));
            const labels = comptime engineLabels();
            var engine: usize = @backingInt(self.engine);
            if (ui.combo("##game_engine", &engine, &labels)) self.engine = @fromBackingInt(@intCast(engine));
            ui.tooltip("Wraith works it out from the files beside each game's exe", .{});
            field("Variants", &self.variants, "Comma-separated, like IL2CPP or Mono for Unity, or MV for RPG Maker. Empty means any");
            ui.sameLine();
            const g = &GameInfo.global;
            if (g.game_engine) |e| {
                if (ui.smallButton("This game's")) {
                    self.engine = e;
                    set(&self.variants, g.engineVariant());
                }
                ui.tooltip("{f}", .{g.gameEngine()});
            }
        },
        .any => ui.textDisabled("It works in any game", .{}),
    }
}

fn engineLabels() [std.enums.values(game_engine.GameEngine).len][:0]const u8 {
    var out: [std.enums.values(game_engine.GameEngine).len][:0]const u8 = undefined;
    for (std.enums.values(game_engine.GameEngine), 0..) |e, i| out[i] = std.fmt.comptimePrint("{s}", .{e.label()});
    return out;
}

fn field(comptime label: [:0]const u8, buf: anytype, comptime help: []const u8) void {
    ui.alignTextToFramePadding();
    ui.text(label, .{});
    ui.sameLineWith(ui.scaled(130), -1);
    ui.setNextItemWidth(ui.scaled(380));
    _ = ui.inputText("##" ++ label, buf[0..buf.len]);
    ui.tooltip(help, .{});
}

/// True once it's written.
fn exportTo(self: *ExportMod, wb: *Workbench) bool {
    const project = wb.project orelse return false;
    var arena: std.heap.ArenaAllocator = .init(wb.allocator);
    defer arena.deinit();
    const d = self.details(arena.allocator()) catch return false;
    if (ProjectManifest.check(d)) |why| {
        self.problem.set(why);
        return false;
    }
    if (self.target == .game and d.ids.len == 0) {
        self.problem.set("The hub needs at least one game id. \"This game\" fills it in if Wraith knows this one");
        return false;
    }
    wb.flushEditors();
    ProjectManifest.write(project, wb.allocator, d) catch |err| {
        self.problem.print("Couldn't keep its details: {t}", .{err});
        return false;
    };
    if (wb.shell) |shell| shell.registry.set(shell.own.export_author, .{ .text = d.author }) catch {};
    var name_buf: [128]u8 = undefined;
    const file_name = std.fmt.bufPrint(&name_buf, "{s}-{s}.zip", .{ d.id, d.version }) catch d.id;
    const picked = tuft_window.pickFile(wb.allocator, .{
        .mode = .save,
        .owner = wb.dialogOwner(),
        .alive = wb.dialogAlive(),
        .title = "Export as mod",
        .file_name = file_name,
        .kind = "Wraith mod",
        .extension = ".zip",
    }) catch |err| {
        self.problem.print("Couldn't show the file dialog: {t}", .{err});
        return false;
    };
    const path = picked orelse return false;
    defer wb.allocator.free(path);
    project.exportMod(path) catch |err| {
        self.problem.print("Couldn't write it: {t}", .{err});
        return false;
    };
    self.problem = .{};
    return true;
}
