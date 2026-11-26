//! The workbench's tests, in a headless ImGui context on the test's thread.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const hook = @import("tuft_hook");
const tuft_imgui = @import("tuft_imgui");
const tuft_sys = @import("tuft_sys");

const c = @import("../imgui.zig").c;
const imgui = @import("../imgui.zig");
const Workbench = @import("Workbench.zig");
const Project = @import("../../Project.zig");
const Rig = @import("../../testing/Rig.zig");

const testing = std.testing;
const is64 = @import("builtin").cpu.arch == .x86_64;

const Frames = struct {
    context: *c.ImGuiContext,

    fn init() !Frames {
        imgui.bind();
        const context = c.ImGui_CreateContext(null) orelse return error.CreateContextFailed;
        c.ImGui_SetCurrentContext(context);
        const io = c.ImGui_GetIO();
        io.*.IniFilename = null;
        io.*.DisplaySize = .{ .x = 1400, .y = 900 };
        io.*.DeltaTime = 1.0 / 60.0;
        io.*.ConfigFlags |= c.ImGuiConfigFlags_DockingEnable;
        io.*.ConfigErrorRecoveryEnableAssert = false;
        tuft_imgui.headless.init();
        return .{ .context = context };
    }

    fn deinit(self: *Frames) void {
        c.ImGui_DestroyContext(self.context);
    }

    fn run(self: *Frames, wb: *Workbench, n: usize) void {
        for (0..n) |_| {
            c.ImGui_SetCurrentContext(self.context);
            c.ImGui_NewFrame();
            tuft_imgui.headless.textures();
            wb.draw();
            c.ImGui_Render();
        }
    }
};

test "fonts and themes" {
    const ui = @import("wraith_ui");
    const Themes = @import("../Themes.zig");
    var frames = try Frames.init();
    defer frames.deinit();
    @import("../fonts.zig").load(15);
    // Fonts are per thread and these die with the context
    defer ui.setFonts(.{});
    var themes = try Themes.load(testing.allocator, testing.io, null);
    defer themes.deinit();
    const wb = try Workbench.create(testing.allocator, .{ .theme = themes.find("Dark") });
    defer wb.destroy();
    // What its own thread's setup does, minus the window
    wb.default_style = c.ImGui_GetStyle().*;
    wb.styled = true;
    wb.setTheme(themes.find("Dark"));

    wb.openNew(.schema);
    wb.openCode(@intFromPtr(&wb));
    frames.run(wb, 3);
    const mono = ui.monospace();
    defer mono.end();
    try testing.expect(mono.pushed);
    try testing.expectEqualStrings("Dark", wb.theme.?.name);
    try testing.expectApproxEqAbs(0.118, c.ImGui_GetStyle().*.Colors[c.ImGuiCol_WindowBg].x, 0.001);
    try testing.expectEqual(c.ImGuiDir_None, c.ImGui_GetStyle().*.WindowMenuButtonPosition);
    // Every font has the icons merged in, and still its own letters
    const fonts = c.ImGui_GetIO().*.Fonts.*.Fonts;
    try testing.expectEqual(3, fonts.Size);
    const icons = @import("../icons.zig");
    for (fonts.Data[0..@intCast(fonts.Size)]) |font| {
        try testing.expect(c.ImFont_IsGlyphInFont(font, 'A'));
        // Lucide's are square. Inter's narrower letters at some of the same codepoints mustn't win
        const baked = c.ImFont_GetFontBaked(font, 15);
        try testing.expect(c.ImFontBaked_FindGlyphNoFallback(baked, codepoint(icons.puzzle)) != null);
        // And the logos
        try testing.expect(c.ImFontBaked_FindGlyphNoFallback(baked, codepoint(@import("../brands.zig").github)) != null);
        try testing.expectEqual(c.ImFontBaked_GetCharAdvance(baked, codepoint(icons.info)), c.ImFontBaked_GetCharAdvance(baked, codepoint(icons.puzzle)));
    }
}

fn codepoint(text: []const u8) c.ImWchar {
    return @intCast(std.unicode.utf8Decode(text) catch unreachable);
}

test "default layout" {
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();
    frames.run(wb, 6);

    try testing.expect(wb.dockspace != 0 and tuft_imgui.dock.exists(wb.dockspace));
    try testing.expectEqual(5, wb.documents.items.len);
    inline for (.{ .code, .memory, .schema, .script, .tweak }, 0..) |kind, i| try testing.expectEqual(kind, std.meta.activeTag(wb.documents.items[i].body));
    try testing.expect(tuft_imgui.dock.inFront(wb.documents.items[1].window().title));
    try testing.expect(tuft_imgui.dock.inFront(wb.panels.addresses.window.title));
    try testing.expect(wb.document_dock != 0);
    inline for (.{ "search", "addresses", "names", "tweaks", "log" }) |name| try testing.expect(@field(wb.panels, name).window.open);
    inline for (.{ "diagnostics", "debug", "scripts" }) |name| try testing.expect(@field(wb.groups, name).window.open);
    const p = &wb.panels;
    const search_spot = tuft_imgui.dock.of(p.search.window.title).?;
    const names_spot = tuft_imgui.dock.of(p.names.window.title).?;
    try testing.expect(search_spot != names_spot);
    try testing.expectEqual(tuft_imgui.dock.of(p.addresses.window.title).?, names_spot);
    // Seven tabs along the bottom, Names right after Addresses
    var labels: [16][]const u8 = undefined;
    var n: usize = 0;
    for (wb.system.windows()) |e| {
        labels[n] = e.window.label();
        n += 1;
    }
    try testing.expectEqual(11, n);
    try testing.expectEqualStrings("Addresses", labels[1]);
    try testing.expectEqualStrings("Names", labels[2]);
    try testing.expectEqualStrings("Schemas", labels[3]);
    try testing.expectEqualStrings("Tweaks", labels[4]);
    try testing.expectEqualStrings("Engine", labels[9]);
    try testing.expectEqualStrings("Plugins", labels[10]);
    // Open from the start, with the documents since it's as big as one
    try testing.expect(p.schemas.window.open);
    try testing.expectEqual(wb.document_dock, tuft_imgui.dock.of(p.schemas.window.title).?);
    // Most games have no C# or engine plugins, so it waits closed with the documents
    const engine = &wb.groups.engine;
    try testing.expect(!engine.window.open);
    try testing.expectEqual(wb.document_dock, tuft_imgui.dock.of(engine.window.title).?);
    try testing.expect(!wb.groups.plugins.window.open);
    try testing.expectEqual(names_spot, tuft_imgui.dock.of(wb.groups.plugins.window.title).?);

    // ImGui keeps Search's empty spot and shows it again right there
    wb.toggleSearch();
    frames.run(wb, 3);
    try testing.expect(!p.search.window.open);
    wb.toggleSearch();
    frames.run(wb, 3);
    try testing.expect(p.search.window.open);
    try testing.expectEqual(search_spot, tuft_imgui.dock.of(p.search.window.title).?);

    // A bottom panel opened again joins the others there, not floating
    wb.groups.debug.window.open = false;
    frames.run(wb, 2);
    wb.groups.debug.window.open = true;
    frames.run(wb, 3);
    try testing.expectEqual(tuft_imgui.dock.of(p.log.window.title).?, tuft_imgui.dock.of(wb.groups.debug.window.title).?);

    wb.groups.diagnostics.focus(&wb.panels.memory);
    frames.run(wb, 3);
    try testing.expect(wb.groups.diagnostics.window.open);
    try testing.expectEqual(2, wb.groups.diagnostics.shown);
}

const PanelDraws = struct {
    draws: u32 = 0,
    in_frame: bool = false,
    in_workbench: bool = false,

    fn draw(self: *PanelDraws) void {
        const host_ui = @import("../../host/ui.zig");
        self.draws += 1;
        self.in_frame = host_ui.inFrame();
        self.in_workbench = host_ui.inWorkbench();
    }
};

test "plugins' panels show in their groups, drawn in its frame" {
    const sdk = @import("wraith_sdk");
    const Loaded = @import("../../PluginLoader.zig").Loaded;
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();
    frames.run(wb, 3);
    try testing.expect(!wb.groups.plugins.window.open);

    var loaded: Loaded = undefined;
    loaded.initForTest(testing.allocator, "tools");
    sdk.Owner.attach(loaded.root());
    defer sdk.Owner.detach();
    const area = sdk.wraith.root().?.ui();
    var mine: PanelDraws = .{};
    var engines: PanelDraws = .{};
    const panel = area.addWorkbenchPanel(.{ .title = "Party", .engine = false }, .init(&mine, PanelDraws.draw));
    _ = area.addWorkbenchPanel(.{ .title = "Scene", .engine = true }, .init(&engines, PanelDraws.draw));

    // Each group opens itself once there's something in it
    frames.run(wb, 4);
    try testing.expect(wb.groups.plugins.window.open);
    try testing.expect(wb.groups.engine.window.open);
    try testing.expect(mine.draws > 0);
    try testing.expect(mine.in_frame and mine.in_workbench);
    try testing.expect(panel.isOpen());
    // The engine's group is with the documents, behind the one you were looking at
    try testing.expectEqual(wb.document_dock, tuft_imgui.dock.of(wb.groups.engine.window.title).?);
    try testing.expect(tuft_imgui.dock.inFront(wb.documents.items[1].window().title));
    try testing.expect(!tuft_imgui.dock.inFront(wb.groups.engine.window.title));

    // Without C# there's no Classes tab, so a plugin's panel is what it shows once it's focused
    const before = engines.draws;
    sdk.wraith.root().?.ui().addWorkbenchPanel(.{ .title = "Scene 2", .engine = true }, .init(&engines, PanelDraws.draw)).focus();
    frames.run(wb, 3);
    try testing.expect(engines.draws > before);
    try testing.expect(tuft_imgui.dock.inFront(wb.groups.engine.window.title));

    // Gone with the plugin
    loaded.owner.close();
    const draws = mine.draws;
    frames.run(wb, 3);
    try testing.expectEqual(draws, mine.draws);
    try testing.expect(!panel.isOpen());
    loaded.deinitForTest();
}

test "game speed on the menu bar, back to normal on a right-click" {
    const game_area = @import("../../host/game_area.zig");
    try hook.init(testing.allocator);
    defer hook.deinit();
    defer @import("../../speed/root.zig").stop();
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();
    defer game_area.setSpeedForPlayer(1) catch {};

    // It shows what it's at, whoever set it
    try game_area.setSpeedForPlayer(3);
    frames.run(wb, 3);
    try testing.expectEqual(3, game_area.currentSpeed());
    const r = wb.game_speed.rect;
    try testing.expect(r[1][0] > r[0][0]);

    const io = c.ImGui_GetIO();
    c.ImGuiIO_AddMousePosEvent(io, (r[0][0] + r[1][0]) / 2, (r[0][1] + r[1][1]) / 2);
    frames.run(wb, 2);
    c.ImGuiIO_AddMouseButtonEvent(io, 1, true);
    frames.run(wb, 2);
    c.ImGuiIO_AddMouseButtonEvent(io, 1, false);
    frames.run(wb, 2);
    try testing.expectEqual(1, game_area.currentSpeed());
    try testing.expectEqual(0, wb.failures);
}

test "script document" {
    const messages = @import("../../host/messages.zig");
    const protocol = @import("wraith_api").script;
    messages.setFrames(true);
    defer messages.setFrames(false);
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();

    // Stands in for the provider
    const Provider = struct {
        runs: u32 = 0,
        last_session: u32 = 0,
        stopped: u32 = 0,

        fn onMessage(self: *@This(), m: *const @import("wraith_api").Message) void {
            if (!std.mem.eql(u8, m.from, protocol.runtime)) return;
            var arena: std.heap.ArenaAllocator = .init(testing.allocator);
            defer arena.deinit();
            if (std.mem.eql(u8, m.topic, protocol.topics.run)) {
                const run = std.json.parseFromSliceLeaky(protocol.Run, arena.allocator(), m.payload, .{}) catch return;
                self.runs += 1;
                self.last_session = run.session;
            } else if (std.mem.eql(u8, m.topic, protocol.topics.stop)) {
                self.stopped += 1;
            }
        }
    };
    var provider: Provider = .{};
    const heard = try messages.subscribeRuntime(&provider, Provider.onMessage);
    defer heard.unsubscribe();

    frames.run(wb, 2);
    const doc = wb.documents.items[3];
    const session = doc.body.script.session;
    try testing.expectEqual(1, session);
    try testing.expectEqualStrings("New script", wb.scripts.find(session).?.label());

    wb.scripts.run(session, "1 + 1");
    messages.deliver();
    try testing.expectEqual(1, provider.runs);
    try testing.expectEqual(session, provider.last_session);

    // Answers come on the render thread and show next frame
    try messages.publishFromRuntime(protocol.topics.output, "{\"session\":1,\"kind\":\"value\",\"text\":\"2\"}");
    try messages.publishFromRuntime(protocol.topics.sessions, "{\"sessions\":[{\"session\":1,\"name\":\"Script\",\"frames\":1}]}");
    messages.deliver();
    frames.run(wb, 2);
    try testing.expectEqualStrings("2", wb.scripts.console.items[0].text);
    try testing.expectEqual(1, wb.scripts.find(session).?.running.?.frames);

    // Closing the document leaves the session
    doc.window().open = false;
    frames.run(wb, 1);
    try testing.expectEqual(null, wb.scriptDocument(session));
    try testing.expect(wb.scripts.find(session) != null);
    wb.openScript(session);
    frames.run(wb, 1);
    try testing.expectEqualStrings("1 + 1", std.mem.sliceTo(wb.scriptDocument(session).?.body.script.code.?, 0));

    // Typed at the Console, in a Lua session of its own
    const console = &wb.panels.console;
    console.target = .{ .console = .lua };
    console.enter("1 + 1");
    messages.deliver();
    try testing.expectEqual(2, provider.runs);
    const lua = console.own.get(.lua).?;
    try testing.expectEqual(lua, provider.last_session);
    try testing.expectEqual(.lua, wb.scripts.find(lua).?.language);
    // Or in a script's, which still opens with what it ran
    console.target = .{ .session = session };
    console.enter("x");
    messages.deliver();
    try testing.expectEqual(session, provider.last_session);
    try testing.expectEqualStrings("1 + 1", wb.scripts.find(session).?.code);
    frames.run(wb, 1);

    wb.closeScript(session);
    wb.scripts.stop(session);
    messages.deliver();
    frames.run(wb, 1);
    try testing.expectEqual(1, provider.stopped);
    try testing.expectEqual(null, wb.scripts.find(session));
    try testing.expectEqual(null, wb.scriptDocument(session));
}

test "game gets no input" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    const wb = try Workbench.create(testing.allocator, .{ .overlay = rig.overlay });

    // What its tick does as its windows come and go
    wb.holdGameInput(true);
    wb.holdGameInput(true);
    try testing.expect(rig.overlay.taken(.keyboard));
    try testing.expectEqual(1, rig.overlay.takes.getPtrConst(.keyboard).load(.acquire));
    try testing.expectEqual(1, rig.overlay.cursor_requests.load(.acquire));
    wb.holdGameInput(false);
    try testing.expect(!rig.overlay.taken(.keyboard));
    try testing.expect(!rig.overlay.cursorRequested());

    wb.holdGameInput(true);
    wb.destroy();
    try testing.expect(!rig.overlay.taken(.keyboard));
}

/// C's convention, so its arg's in rcx on x64
noinline fn breakTarget(x: u32) callconv(.c) u32 {
    return x *% 5 +% 2;
}

test "breakpoint stops and resumes" {
    try breakpointStopsAndResumes(.hardware);
}

test "software breakpoint stops and resumes" {
    // It holds its byte like a patch does
    try @import("tuft_hook").init(testing.allocator);
    defer @import("tuft_hook").deinit();
    try breakpointStopsAndResumes(.software);
}

fn breakpointStopsAndResumes(kind: Workbench.Debugger.Kind) !void {
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();
    // The first tick makes this thread the workbench's, which never stops
    wb.tick();
    frames.run(wb, 2);

    const at = @intFromPtr(&breakTarget);
    const original = @as(*const volatile u8, @ptrFromInt(at)).*;
    switch (kind) {
        .software => try wb.toggleBreakpoint(at),
        .hardware => try wb.toggleHardwareBreakpoint(at),
    }
    try testing.expectEqual(kind, wb.debugger.get(at).?.kind);
    try testing.expectEqual(true, Workbench.markAt(wb, at).breakpoint);
    try testing.expect(wb.groups.debug.window.open);

    // Other tabs in front, both in the middle and along the bottom
    wb.panels.log.window.focus();
    for (wb.documents.items) |d| if (d.body == .script) d.window().focus();
    frames.run(wb, 3);
    try testing.expectEqual(0, wb.panels.stopped.len);

    const Caller = struct {
        result: Atomic(u32) = .init(0),
        started: Atomic(bool) = .init(false),
        go: Atomic(bool) = .init(false),
        fn run(self: *@This()) void {
            self.started.store(true, .release);
            while (!self.go.load(.acquire)) tuft_sys.thread.sleepMs(1);
            self.result.store(breakTarget(3), .release);
        }
    };
    var caller: Caller = .{};
    const thread = try std.Thread.spawn(.{}, Caller.run, .{&caller});
    while (!caller.started.load(.acquire)) tuft_sys.thread.sleepMs(1);
    // New threads get breakpoints on the next refresh
    wb.debugger.refresh();
    caller.go.store(true, .release);

    for (0..2000) |_| {
        wb.tick();
        if (wb.debugger.stopCount() != 0 and wb.seen_stops != 0) break;
        tuft_sys.thread.sleepMs(1);
    }
    frames.run(wb, 3);
    // Both came to the front. Stopped only counts what it draws, and the code only takes focus when shown
    try testing.expectEqual(1, wb.panels.stopped.len);
    try testing.expect(!wb.active_code.?.body.code.code.take_focus);
    try testing.expectEqual(null, wb.focus_when_active);
    try testing.expectEqual(at, wb.active_code.?.body.code.code.selection().?.start);
    try testing.expect(Workbench.markAt(wb, at).current);
    // The code view shows the real instruction, not our int3
    try testing.expectEqual(original, try wb.active_code.?.body.code.code.memory.load(u8, at));
    try testing.expectEqual(0, caller.result.load(.acquire));

    // Its first arg's still in rcx at the first instruction, so changing it changes the answer
    const Registers = @TypeOf(wb.panels.registers);
    const registers = &wb.panels.registers;
    const first = wb.focusedStop().?;
    registers.commit(&first, Registers.index(if (is64) "rcx" else "eax").?, "zz");
    try testing.expect(registers.problem != null);
    if (is64) {
        registers.commit(&first, Registers.index("rcx").?, "0x4");
        try testing.expectEqual(null, registers.problem);
        try testing.expectEqual(4, wb.focusedStop().?.cpu.rcx);
    }
    // Watching registers keeps them up for the next stop
    wb.groups.debug.focus(&wb.panels.registers);
    frames.run(wb, 2);
    try testing.expect(wb.groups.debug.showing(&wb.panels.registers));

    wb.resumeFocused(.step);
    for (0..2000) |_| {
        wb.tick();
        if (wb.seen_stops == 2) break;
        tuft_sys.thread.sleepMs(1);
    }
    try testing.expect(!wb.groups.debug.window.raise);
    try testing.expect(!wb.active_code.?.window().raise);
    try testing.expect(!wb.active_code.?.body.code.code.take_focus);
    frames.run(wb, 2);
    const stepped = wb.focusedStop().?;
    try testing.expect(wb.groups.debug.showing(&wb.panels.registers));
    try testing.expectEqual(.step, stepped.reason);
    try testing.expect(stepped.cpu.ip() != at);
    try testing.expectEqual(stepped.cpu.ip(), wb.active_code.?.body.code.code.selection().?.start);

    wb.resumeFocused(.run);
    thread.join();
    try testing.expectEqual(if (is64) 22 else 17, caller.result.load(.acquire));
    try testing.expectEqual(1, wb.debugger.get(at).?.hits);

    try wb.toggleBreakpoint(at);
    try testing.expectEqual(null, wb.debugger.get(at));
}

test "going places" {
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();
    frames.run(wb, 2);

    const text = try @import("tuft_mem").Module.main().text();
    wb.openCode(text.start);
    wb.openCode(text.start + 16);
    frames.run(wb, 3);
    try testing.expectEqual(5, wb.documents.items.len);
    const code = wb.active_code.?;
    try testing.expectEqual(text.start + 16, code.body.code.code.selection().?.start);

    wb.openNew(.code);
    frames.run(wb, 2);
    try testing.expectEqual(6, wb.documents.items.len);
    const added = wb.documents.items[5];
    try testing.expectEqualStrings("Disassembly 2###code.6", added.window().title);
    try testing.expect(added.dock != 0);
    try testing.expectEqual(code.dock, added.dock);

    added.window().open = false;
    code.window().open = false;
    frames.run(wb, 1);
    try testing.expectEqual(4, wb.documents.items.len);
    wb.openCode(text.start);
    try testing.expectEqual(5, wb.documents.items.len);

    // From another UI it waits for the next frame
    wb.going.put(.{ .memory = .{ .address = text.start, .len = 8, .highlight = null } });
    frames.run(wb, 2);
    try testing.expect(!wb.hasPending());
    try testing.expectEqual(text.start, wb.active_memory.?.body.memory.hex.selection().?.start);
}

test "schema document" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "schemas");
    try tmp.dir.writeFile(io, .{ .sub_path = "schemas/base.sal", .data = "struct Base {\n    u32 id;\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "schemas/player.sal", .data = "// Ours\nstruct Player : Base {\n    [0x8] f32 health;\n}\n" });
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fs.path.join(testing.allocator, &.{ root, "schemas", "player.sal" });
    defer testing.allocator.free(path);

    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{ .io = io });
    defer wb.destroy();
    wb.openSchema(path);
    frames.run(wb, 2);
    const doc = wb.documents.items[5];
    try testing.expectEqualStrings("player.sal###schema.6", doc.window().title);
    const editor = &doc.body.schema;
    try testing.expectEqual(null, editor.problem);
    // Base comes from the file next to it
    try testing.expect(editor.view.show("Player"));
    try testing.expect(editor.view.show("Base"));

    var player: [0xC]u8 align(4) = @splat(0);
    std.mem.writeInt(u32, player[0..4], 7, .little);
    _ = editor.view.show("Player");
    editor.view.goTo(@intFromPtr(&player));
    frames.run(wb, 2);
    try testing.expect(editor.view.rows.items.len >= 3);

    editor.apply(&.{.{ .define = .{ .owner = "Player", .offset = 0x4, .type = "u32", .name = "level" } }});
    try testing.expectEqualStrings("// Ours\nstruct Player : Base {\n    [0x4] u32 level;\n    [0x8] f32 health;\n}\n", editor.source());
    try testing.expect(!editor.saved);
    // Base isn't in this file
    editor.apply(&.{.{ .rename = .{ .owner = "Base", .field = "id", .name = "key" } }});
    try testing.expect(std.mem.indexOf(u8, editor.view.problem.?.message(), "another file") != null);
    try testing.expectEqualStrings("// Ours\nstruct Player : Base {\n    [0x4] u32 level;\n    [0x8] f32 health;\n}\n", editor.source());

    try editor.saveAs(path);
    try testing.expect(editor.saved);
    const written = try tmp.dir.readFileAlloc(io, "schemas/player.sal", testing.allocator, .limited(4096));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings(editor.source(), written);
    wb.openSchema(path);
    try testing.expectEqual(6, wb.documents.items.len);

    try testing.expectEqual(null, wb.documents.items[2].body.schema.problem);
    // The one it starts with is empty, the example only a hint
    try testing.expectEqualStrings("", wb.documents.items[2].body.schema.source());
}

test "search panel" {
    var frames = try Frames.init();
    defer frames.deinit();
    var wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();

    const marker = try testing.allocator.create(u32);
    defer testing.allocator.destroy(marker);
    marker.* = 0x5EA2_C4ED;
    const search = &wb.panels.search;
    _ = try std.fmt.bufPrintSentinel(&search.view.value, "0x5EA2C4ED", .{}, 0);
    search.view.start(.first);
    while (search.view.running.load(.acquire)) try testing.io.sleep(.fromMilliseconds(1), .awake);
    frames.run(wb, 2);
    try testing.expectEqual(null, search.view.problem);
    var found = false;
    for (0..search.view.search.?.count) |i| {
        if (search.view.search.?.address(i) == @intFromPtr(marker)) found = true;
    }
    try testing.expect(found);

    // A slow search, still running when the workbench goes
    search.view.search.?.reset();
    _ = try std.fmt.bufPrintSentinel(&search.view.value, "0", .{}, 0);
    search.view.kind = .byte;
    search.view.aligned = false;
    search.view.start(.first);
    frames.run(wb, 1);
    wb.destroy();
    wb = try Workbench.create(testing.allocator, .{});
}

test "address list" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var value: u32 align(4) = 5;
    var other: u32 align(4) = 6;
    var project = try Project.create(testing.allocator, io, root);
    var wb = try Workbench.create(testing.allocator, .{ .io = io, .project = project });
    {
        const addresses = &wb.panels.addresses;
        addresses.add(@intFromPtr(&value), .four_bytes, 4);
        addresses.changed();
        try testing.expect(project.isDirty());
        addresses.list.setHeld(0, true);
        value = 1;
        // Closed, but its tick still puts the value back
        wb.tick();
        try testing.expectEqual(5, value);
        try project.save();
        // Never saved, so it's gone next time
        addresses.add(@intFromPtr(&other), .four_bytes, 4);
        addresses.changed();
        try testing.expect(project.isDirty());
    }
    wb.destroy();
    project.destroy();

    project = try Project.create(testing.allocator, io, root);
    defer project.destroy();
    project.startUp(null);
    try testing.expect(!project.isDirty());
    wb = try Workbench.create(testing.allocator, .{ .io = io, .project = project });
    defer wb.destroy();
    const addresses = &wb.panels.addresses;
    try testing.expectEqual(1, addresses.list.nodes.items.len);
    const expected = try std.fmt.allocPrint(testing.allocator, "0x{x}", .{@intFromPtr(&value)});
    defer testing.allocator.free(expected);
    try testing.expectEqualStrings(expected, addresses.list.nodes.items[0].address.get());
    try testing.expect(!addresses.list.nodes.items[0].hold);

    const exported = try std.fs.path.join(testing.allocator, &.{ root, "shared", "list.rwa.zon" });
    defer testing.allocator.free(exported);
    try testing.expectEqual(1, try addresses.exportTo(exported));
    try testing.expectEqual(1, try addresses.importFrom(exported));
    try testing.expectEqual(2, addresses.list.nodes.items.len);
    const missing = try std.fs.path.join(testing.allocator, &.{ root, "none.rwa.zon" });
    defer testing.allocator.free(missing);
    try testing.expectError(error.FileNotFound, addresses.importFrom(missing));
}

test "address list types from the project and plugins" {
    const Names = @import("../../Names.zig");
    const SharedSchemas = @import("../../SharedSchemas.zig");
    const Owner = @import("tuft_event").Owner;
    Names.global = .init(testing.allocator);
    defer Names.global.deinit();
    SharedSchemas.global = .init(testing.allocator);
    defer SharedSchemas.global.deinit();
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const project = try Project.create(testing.allocator, io, dir);
    defer project.destroy();
    const game_sal =
        \\struct GameStateManager {
        \\    [Sig("48 8B 0D ?? ?? ?? ?? 3D", Rip)] static GameStateManager* instance;
        \\    [0x10] u32 mira;
        \\}
        \\[Sig("90 90 90")] static u32 ticks;
        \\
    ;
    try project.write("schemas/game.sal", game_sal);
    // Published like a plugin's, as `Tweaks` does for the open project
    const projects = @import("../../host/projects.zig");
    _ = projects.set(.{ .key = "", .title = "Your project", .schemas = &.{.{ .name = "schemas/game.sal", .text = game_sal }} });
    defer projects.keep(&.{});
    const wb = try Workbench.create(testing.allocator, .{ .io = io, .project = project });
    defer wb.destroy();
    const list = &wb.panels.addresses.list;
    try testing.expect(Names.global.has(.schema, "GameStateManager.instance"));
    try testing.expect(Names.global.has(.schema, "ticks"));

    // A plugin's types come after the project's, which win when names clash
    var kai: Owner = .init("kai");
    try SharedSchemas.global.add(.{ .owner = &kai, .group = "kai", .name = "kai.sal", .text = "struct GameStateManager { [0x40] u64 other; }\nstruct Thing { u32 id; [0x8] u32 count; }\n" });
    wb.tick();
    try testing.expectEqual(2, list.type_labels.items.len);
    try testing.expectEqualStrings("GameStateManager", list.type_labels.items[0]);
    try testing.expectEqualStrings("Thing (kai)", list.type_labels.items[1]);

    var thing: [0x10]u8 align(8) = @splat(0);
    var buf: [32]u8 = undefined;
    try list.load(&.{
        .{ .name = "thing", .address = try std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(&thing)}), .type = "Thing" },
        .{ .name = "game", .address = "0x1000", .type = "GameStateManager" },
    });
    try testing.expectEqual(0xC, list.targetOf(0).?.len);
    try testing.expectEqual(0x14, list.targetOf(1).?.len);
    list.build();
    // id and count, then the project's GameStateManager.mira
    try testing.expectEqual(3, list.rows.items.len);
    try testing.expectEqualStrings("count", list.rows.items[1].name);
    try testing.expectEqualStrings("mira", list.rows.items[2].name);
    try testing.expectEqual(@intFromPtr(&thing) + 8, list.rows.items[1].address.?);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const items = try list.items(arena.allocator());
    try testing.expectEqualStrings("Thing", items[0].type);

    // Gone with the plugin
    SharedSchemas.global.removeOwner(&kai);
    wb.tick();
    try testing.expectEqual(1, list.type_labels.items.len);
    try testing.expectEqual(1, list.targetOf(0).?.len);

    // The project's statics follow its schemas
    _ = projects.set(.{ .key = "", .title = "Your project", .schemas = &.{.{ .name = "schemas/game.sal", .text = "struct GameStateManager { [0x10] u32 mira; }\n" }} });
    wb.tick();
    try testing.expect(!Names.global.has(.schema, "GameStateManager.instance"));
    try testing.expect(!Names.global.has(.schema, "ticks"));
}

test "tweaks panel and editor" {
    const Tweaks = @import("../../Tweaks.zig");
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const project = try Project.create(testing.allocator, io, dir);
    defer project.destroy();
    try project.write("tweaks/god.rwt", "first");
    try project.write("tweaks/xp.rwt",
        \\@tweak XP
        \\@data
        \\  [Toggle, Key(F9)] u8 on
        \\  [Choices("0:A", "1:B")] u8 pick
        \\  [Min(1), Max(9)] i32 times = 2
        \\  [Hex] u64 at
        \\  f32 speed = 1.5
    );
    try project.write("tweaks/zone.rwt", Workbench.TweakEditor.group_template);
    try project.save();
    const tweaks = try Tweaks.create(testing.allocator, project, null, .{}, .{});
    defer tweaks.destroy();

    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{ .io = io, .project = project });
    defer wb.destroy();
    wb.tweaks = tweaks;
    wb.panels.tweaks.window.focus();
    frames.run(wb, 3);

    // The one it starts with is new and empty, with no file till something's typed
    const fresh = for (wb.documents.items) |d| {
        if (d.body == .tweak) break d;
    } else return error.NotOpened;
    try testing.expect(fresh.body.tweak.isNew());
    try testing.expectEqual(0, fresh.body.tweak.code.?[0]);
    fresh.body.tweak.flush();
    try testing.expectEqual(null, try project.read(testing.allocator, "tweaks/tweak.rwt"));
    @memcpy(fresh.body.tweak.code.?[0..4], "@js\n");
    fresh.body.tweak.pending = true;
    fresh.body.tweak.flush();
    frames.run(wb, 2);
    try testing.expect(!fresh.body.tweak.isNew());
    try testing.expectEqualStrings("tweaks/tweak.rwt", fresh.body.tweak.filePath());
    try testing.expect(std.mem.startsWith(u8, fresh.window().title, "tweak###"));
    const made = (try project.read(testing.allocator, "tweaks/tweak.rwt")).?;
    defer testing.allocator.free(made);
    try testing.expectEqualStrings("@js\n", made);
    fresh.window().open = false;

    wb.openTweak("tweaks/god.rwt");
    frames.run(wb, 2);
    const doc = for (wb.documents.items) |d| {
        if (d.body == .tweak and d.window().open and std.mem.eql(u8, d.body.tweak.filePath(), "tweaks/god.rwt")) break d;
    } else return error.NotOpened;
    const editor = &doc.body.tweak;
    try testing.expectEqualStrings("first", std.mem.sliceTo(editor.code.?, 0));

    // Typed, then kept by the project, then saved with it
    @memcpy(editor.code.?[0..7], "changed");
    editor.pending = true;
    frames.run(wb, 2);
    try testing.expect(project.isDirty());
    wb.saveProject();
    frames.run(wb, 1);
    try testing.expect(!project.isDirty());
    const text = (try project.read(testing.allocator, "tweaks/god.rwt")).?;
    defer testing.allocator.free(text);
    try testing.expectEqualStrings("changed", text);

    tweaks.setOn("god", true);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const list = try tweaks.snapshot(arena.allocator());
    try testing.expect(list[0].on);
    try testing.expectEqualStrings("XP", list[1].title);
    try testing.expectEqual(5, list[1].fields.len);
    frames.run(wb, 2);

    // The group template, as a tree that's partly on
    tweaks.setOn("zone/Inner/Second", true);
    const tree = try tweaks.snapshot(arena.allocator());
    try testing.expectEqualStrings("zone/Inner/Second", tree[5].name);
    try testing.expect(tree[2].partial and tree[4].partial and tree[5].on and tree[2].problem == null);
    frames.run(wb, 2);
}

test "switching projects" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const b = try std.fs.path.join(testing.allocator, &.{ root, "b.rwp" });
    defer testing.allocator.free(b);
    {
        const other = try Project.create(testing.allocator, io, root);
        defer other.destroy();
        try other.write(Project.addresses_file, ".{ .items = .{ .{ .name = \"x\" }, .{ .name = \"y\" } } }");
        try other.write("wraith.json", "{ \"title\": \"b\" }");
        try other.exportTo(b);
    }
    const project = try Project.create(testing.allocator, io, root);
    defer project.destroy();
    try project.write(Project.addresses_file, ".{ .items = .{ .{ .name = \"x\" } } }");
    try project.save();

    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{ .io = io, .project = project });
    defer wb.destroy();
    frames.run(wb, 2);
    try testing.expectEqual(1, wb.panels.addresses.list.nodes.items.len);

    try project.open(b);
    frames.run(wb, 2);
    try testing.expectEqual(2, wb.panels.addresses.list.nodes.items.len);
    try testing.expectEqualStrings("b", project.name());
}

test "schemas and scripts go in the project once changed" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const project = try Project.create(testing.allocator, io, root);
    defer project.destroy();

    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{ .io = io, .project = project });
    defer wb.destroy();
    frames.run(wb, 2);
    try testing.expect(!project.isDirty());

    var schema_doc: ?*Workbench.Document = null;
    var script_doc: ?*Workbench.Document = null;
    for (wb.documents.items) |d| switch (d.body) {
        .schema => schema_doc = d,
        .script => script_doc = d,
        else => {},
    };
    const schema = &schema_doc.?.body.schema;
    const text = "struct A { u32 x; }";
    @memcpy(schema.text.?[0..text.len], text);
    schema.text.?[text.len] = 0;
    schema.pending = true;
    const script = &script_doc.?.body.script;
    @memcpy(script.code.?[0..3], "1;\x00");
    script.pending = true;
    // Only the tab showing draws
    schema_doc.?.window().focus();
    frames.run(wb, 2);
    script_doc.?.window().focus();
    frames.run(wb, 2);

    const kept = (try project.read(testing.allocator, "schemas/schema.sal")).?;
    defer testing.allocator.free(kept);
    try testing.expectEqualStrings(text, kept);
    const ran = (try project.read(testing.allocator, "scripts/script.rws.js")).?;
    defer testing.allocator.free(ran);
    try testing.expectEqualStrings("1;", ran);
    try testing.expect(std.mem.startsWith(u8, schema_doc.?.window().title, "schema.sal###"));
    try testing.expectEqualStrings("script", wb.scripts.find(script.session).?.label());

    // Another project closes them
    project.new();
    frames.run(wb, 2);
    for (wb.documents.items) |d| switch (d.body) {
        .schema => |*l| try testing.expectEqual(null, l.projectPath()),
        .script => |*s| try testing.expectEqual(null, s.projectPath()),
        else => {},
    };

    // Importing a file takes our extension and a free name
    const outside = try std.fs.path.join(testing.allocator, &.{ root, "god.js" });
    defer testing.allocator.free(outside);
    try tmp.dir.writeFile(io, .{ .sub_path = "god.js", .data = "on();" });
    const first = try wb.importPath(Workbench.FileType.tweak, "tweaks", outside);
    defer project.allocator.free(first);
    const second = try wb.importPath(Workbench.FileType.tweak, "tweaks", outside);
    defer project.allocator.free(second);
    try testing.expectEqualStrings("tweaks/god.rwt", first);
    try testing.expectEqualStrings("tweaks/god_2.rwt", second);
    const imported = (try project.read(testing.allocator, second)).?;
    defer testing.allocator.free(imported);
    try testing.expectEqualStrings("on();", imported);
}

test "importing a Cheat Engine table becomes the project" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "game.CT", .data =
        \\<CheatTable><CheatEntries>
        \\<CheatEntry><Description>"God"</Description><VariableType>Auto Assembler Script</VariableType>
        \\<AssemblerScript>[ENABLE]
        \\game.exe+10:
        \\  nop 3
        \\[DISABLE]
        \\game.exe+10:
        \\  sub r8d,edx
        \\</AssemblerScript></CheatEntry>
        \\<CheatEntry><Description>"Gold"</Description><VariableType>4 Bytes</VariableType><Address>game.exe+20</Address></CheatEntry>
        \\</CheatEntries></CheatTable>
    });
    const table = try std.fs.path.join(testing.allocator, &.{ root, "game.CT" });
    defer testing.allocator.free(table);
    const project = try Project.create(testing.allocator, io, root);
    defer project.destroy();

    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{ .io = io, .project = project });
    defer wb.destroy();
    frames.run(wb, 2);
    wb.project_menu.ce.start(wb, table);
    while (wb.project_menu.ce.busy()) try io.sleep(.fromMilliseconds(1), .awake);
    frames.run(wb, 3);

    try testing.expectEqual(0, wb.failures);
    try testing.expect(project.isDirty());
    const tweak = (try project.read(testing.allocator, "tweaks/game.rwt")).?;
    defer testing.allocator.free(tweak);
    try testing.expect(std.mem.indexOf(u8, tweak, "@patch game.exe+0x10 expect \"sub r8d,edx\"") != null);
    try testing.expectEqual(1, wb.panels.addresses.list.nodes.items.len);
}
test "make signature" {
    const Location = @import("tuft_mem").Location;
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();
    const target = @intFromPtr(&signedCode);
    wb.sig_maker.start(wb, target);
    while (wb.sig_maker.busy()) try testing.io.sleep(.fromMilliseconds(1), .awake);

    // Read before a frame, which would copy it to the real clipboard
    const made = wb.sig_maker.finished.?;
    try testing.expectEqual(null, made.err);
    try testing.expectEqual(target, try Location.eval(made.location, .{ .memory = .local, .symbols = .local }, null));
}

/// Never called, only signed.
fn signedCode() callconv(.naked) void {
    asm volatile (
        \\.intel_syntax noprefix
        \\xor eax, eax
        \\mov ecx, 0x5167C0DE
        \\imul ecx, ecx, 0x2B
        \\xchg eax, ecx
        \\ret
        \\.att_syntax prefix
    );
}

test "export as mod prefills from the project, or from the game" {
    const ProjectManifest = @import("../../ProjectManifest.zig");
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(dir);
    const project = try Project.create(testing.allocator, io, dir);
    defer project.destroy();
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{ .io = io, .project = project });
    defer wb.destroy();
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Nothing yet, so named after the project
    wb.export_mod.start(wb);
    frames.run(wb, 2);
    var d = try wb.export_mod.details(arena.allocator());
    try testing.expectEqualStrings("untitled", d.id);
    try testing.expectEqualStrings("0.1.0", d.version);
    try testing.expectEqual(null, ProjectManifest.check(d));

    // What was kept last time
    d.title = "Kai Tables";
    d.author = "Asgard";
    d.ids = &.{ "steam-1", "gog-2" };
    try ProjectManifest.write(project, testing.allocator, d);
    wb.export_mod.start(wb);
    frames.run(wb, 2);
    const again = try wb.export_mod.details(arena.allocator());
    try testing.expectEqualStrings("Kai Tables", again.title);
    try testing.expectEqualStrings("Asgard", again.author);
    try testing.expectEqual(2, again.ids.len);
    try testing.expectEqualStrings("gog-2", again.ids[1]);

    // Exported, then opened into another project: prefilled the same
    const rwp = try std.fs.path.join(testing.allocator, &.{ dir, "kai_tables-0.1.0.rwp" });
    defer testing.allocator.free(rwp);
    try project.exportMod(rwp);
    project.new();
    wb.export_mod.start(wb);
    frames.run(wb, 2);
    try testing.expectEqualStrings("untitled", (try wb.export_mod.details(arena.allocator())).id);
    try project.open(rwp);
    wb.export_mod.start(wb);
    frames.run(wb, 2);
    const opened = try wb.export_mod.details(arena.allocator());
    try testing.expectEqualStrings("Kai Tables", opened.title);
    try testing.expectEqualStrings("Asgard", opened.author);
    try testing.expectEqualStrings("gog-2", opened.ids[1]);
}

test "names panel" {
    const Names = @import("../../Names.zig");
    const salamander_schema = @import("salamander_schema");
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();
    Names.global = .init(testing.allocator);
    defer Names.global.deinit();

    const text = try @import("tuft_mem").Module.main().text();
    var first: [8]u8 = undefined;
    @memcpy(&first, @as([*]const u8, @ptrFromInt(text.start))[0..8]);
    var hex: [32]u8 = undefined;
    const pattern = try std.fmt.bufPrint(&hex, "{x}", .{&first});
    _ = try Names.global.scanManual("start", "", ".text", pattern, .live_only);
    _ = try Names.global.scanManual("nowhere", "", ".text", "DE AD BE EF DE AD BE EF DE AD BE EF 00 11 22 33", .live_only);
    Names.global.rescanAll(.live_only);
    var value: u32 = 7;
    try Names.global.put(.{ .origin = .plugin, .group = "kai", .name = "kai.hp", .where = .{ .at = @intFromPtr(&value) }, .type = "u32", .size = 4 });
    try Names.global.put(.{ .origin = .schema, .group = "schemas", .name = "Game.instance", .where = .{ .text = .{ .text = "[nowhere]" } }, .type = "Player*" });
    try testing.expectError(error.NotFound, Names.global.get("Game.instance"));

    frames.run(wb, 2);
    const panel = &wb.panels.names;
    panel.window.focus();
    frames.run(wb, 4);
    try testing.expectEqual(4, panel.shown.items.len);
    const scanned = &panel.infos.items[0];
    try testing.expectEqualStrings("start", scanned.name.get());
    try testing.expectEqual(text.start, scanned.scan.?.rescanned.?.address);
    try testing.expectEqual(.not_found, panel.infos.items[1].scan.?.scanned.outcome);
    const instance = &panel.infos.items[3];
    try testing.expectEqualStrings("Game.instance", instance.name.get());
    try testing.expectEqualStrings("nowhere: sig(\"DE AD BE EF DE AD BE EF DE AD BE EF 00 11 22 33\") wasn't found", instance.failed.?.message.message());
    try testing.expectEqual(@intFromPtr(&value), panel.infos.items[2].address.?);

    panel.filter = .scans;
    panel.refresh();
    try testing.expectEqual(2, panel.shown.items.len);
    panel.filter = .all;
    @memcpy(panel.search[0..4], "GAME");
    panel.refresh();
    try testing.expectEqual(1, panel.shown.items.len);
    panel.search = @splat(0);
    // Typed ones are data, and each group can be picked
    panel.kind = .data;
    panel.refresh();
    try testing.expectEqual(2, panel.shown.items.len);
    try testing.expect(panel.groups.items.len >= 3);
    @memcpy(panel.group[0..3], "kai");
    panel.refresh();
    try testing.expectEqual(1, panel.shown.items.len);
    try testing.expectEqualStrings("kai.hp", panel.shown.items[0].name.get());
    panel.kind = .any;
    panel.group = @splat(0);

    // Pointers to structs are read through, the rest are where the name is
    var parsed = try salamander_schema.parse(testing.allocator, "[Size(0x10)] struct Player { u32 hp; }", .{}, null);
    defer parsed.deinit();
    const player = &parsed.schema;
    var buf: [256]u8 = undefined;
    const through = Workbench.NamesPanel.itemFor(instance, &.{player}, &buf).?;
    try testing.expectEqualStrings("[Game.instance]", through.address);
    try testing.expectEqualStrings("Player", through.type);
    const plain = Workbench.NamesPanel.itemFor(&panel.infos.items[2], &.{player}, &buf).?;
    try testing.expectEqualStrings("(kai.hp)", plain.address);
    try testing.expectEqual(.four_bytes, plain.kind);
    wb.panels.addresses.addItem(plain);
    try testing.expectEqual(@intFromPtr(&value), wb.panels.addresses.list.targetOf(0).?.address);

    wb.openMemory(text.start, 8, .{ .start = text.start, .len = 8 });
    frames.run(wb, 4);
    const view = &wb.active_memory.?.body.memory.hex;
    try testing.expectEqual(text.start, view.selection().?.start);
    try testing.expectEqual(8, view.selection().?.len);
    try testing.expect(view.shown.contains(text.start));

    wb.openCode(text.start);
    frames.run(wb, 4);
    const code = &wb.active_code.?.body.code;
    try testing.expectEqual(text.start, code.code.selection().?.start);
    try testing.expectEqual(text.start, code.bar.current());
}

test "schemas panel" {
    const Names = @import("../../Names.zig");
    const SharedSchemas = @import("../../SharedSchemas.zig");
    const Owner = @import("tuft_event").Owner;
    const salamander_schema = @import("salamander_schema");
    Names.global = .init(testing.allocator);
    defer Names.global.deinit();
    SharedSchemas.global = .init(testing.allocator);
    defer SharedSchemas.global.deinit();
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();

    const bundle = try salamander_schema.bundle(testing.allocator, &.{.{ .name = "kai/game.sal", .text =
        \\struct Root { Game.World.Actor actor; }
        \\namespace Game.World;
        \\enum Mode : u8 { A, B }
        \\[Size(0x10)]
        \\struct Actor {
        \\    u32 hp;
        \\    [0x8] Actor* target;
        \\}
        \\struct Party { Actor* leader; Vec3 pos; }
        \\
    }});
    defer testing.allocator.free(bundle);
    var kai: Owner = .init("kai");
    try SharedSchemas.global.add(.{ .owner = &kai, .group = "kai", .name = "schemas", .text = bundle });
    defer SharedSchemas.global.removeOwner(&kai);
    wb.tick();
    const panel = &wb.panels.schemas;
    panel.window.focus();
    frames.run(wb, 3);
    // Wraith's own types, like Vec3, are read before it as they are for the plugin, under a folder of their own
    var kais: usize = 0;
    for (panel.types.items) |t| kais += @intFromBool(std.mem.eql(u8, t.plugin, "kai"));
    try testing.expectEqual(4, kais);
    try testing.expectEqual(0, wb.panels.addresses.parse_problem.message().len);
    // The plugin's open, its namespace and Wraith's aren't
    try testing.expectEqual(4, panel.rows.items.len);
    try testing.expectEqualStrings("Root", panel.rows.items[1].label);
    try testing.expectEqualStrings("Game", panel.rows.items[2].label);
    try testing.expectEqualStrings("wraith", panel.rows.items[3].label);

    // Picking one opens its folders and shows what uses it
    try testing.expect(panel.show("Game.World.Actor"));
    // It shares a dock with the documents, which came to the front
    panel.window.focus();
    frames.run(wb, 3);
    try testing.expectEqual(8, panel.rows.items.len);
    try testing.expectEqual(2, panel.used_by.items.len);
    const picked = for (panel.types.items) |*t| {
        if (std.mem.eql(u8, t.name, "Game.World.Actor")) break t;
    } else unreachable;
    const text = salamander_schema.Schema.fileText(picked.source, picked.type.at);
    try testing.expect(std.mem.startsWith(u8, std.mem.trimStart(u8, text[panel.lines.items[panel.type_lines[0]]..], " "), "[Size(0x10)]"));
    try testing.expectEqual(panel.type_lines[0] + 4, panel.type_lines[1]);

    // Laid over memory from the memory view
    const Actor = extern struct { hp: u32, pad: u32 = 0, target: usize };
    var actor: Actor = .{ .hp = 7, .target = 0 };
    panel.viewAt(@intFromPtr(&actor));
    frames.run(wb, 3);
    try testing.expectEqual(@intFromPtr(&actor), panel.view.address.?);
    try testing.expectEqualStrings("Game.World.Actor", panel.view.shownName().?);

    // A filter lists matches flat
    @memcpy(panel.search[0..5], "party");
    panel.rows_stale = true;
    panel.window.focus();
    frames.run(wb, 2);
    try testing.expectEqual(1, panel.rows.items.len);
    try testing.expectEqualStrings("Game.World.Party", panel.rows.items[0].label);
}

test "code and memory show copies of the code, side by side" {
    const memory = @import("tuft_mem");
    const Copy = struct {
        var live: [256]u8 align(16) = @splat(0x90);
        var disk: [256]u8 align(16) = @splat(0xCC);
        fn provide(start: usize, len: usize) ?[*]const u8 {
            const at = @intFromPtr(&live);
            if (start < at or start + len > at + live.len) return null;
            return disk[start - at ..].ptr;
        }
    };
    const previous = memory.originals.setProvider(.disk, Copy.provide);
    defer _ = memory.originals.setProvider(.disk, previous);
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();
    const at = @intFromPtr(&Copy.live);

    wb.openMemory(at, 4, null);
    frames.run(wb, 3);
    const viewer = &wb.active_memory.?.body.memory;
    viewer.other_source = .disk;
    viewer.toggleSplit();
    frames.run(wb, 3);
    try testing.expectEqual(0xCC, try viewer.other.memory.load(u8, at));
    try testing.expectEqual(0x90, try viewer.hex.memory.load(u8, at));
    // Either one moves the other
    viewer.hex.goTo(at + 32, 2);
    frames.run(wb, 3);
    try testing.expectEqual(at + 32, viewer.other.anchor.?);
    viewer.other.setPlace(.{ .start = viewer.other.shown.start, .len = viewer.other.shown.len, .top = null, .anchor = at + 64, .cursor = at + 64 });
    frames.run(wb, 3);
    try testing.expectEqual(at + 64, viewer.hex.anchor.?);

    wb.openCode(at);
    frames.run(wb, 3);
    const code = &wb.active_code.?.body.code;
    code.other_source = .disk;
    code.toggleSplit();
    frames.run(wb, 3);
    code.code.goTo(at + 16);
    frames.run(wb, 3);
    // It keeps a few rows above where it went, the same in both
    try testing.expectEqual(code.code.top, code.other.top);
    try testing.expect(code.other.top < at + 16);
    try testing.expectEqual(at + 16, code.other.cursor.address);
    // What the copy doesn't have can't be read
    try testing.expectError(error.Unreadable, code.other.memory.load(u8, at - 1));
}

// Off unless `WRAITH_MANAGED_GAME` names a Unity game's folder. See testing/managed_game.zig.
test "classes panel on a real game's C#" {
    const Managed = @import("../../Managed.zig");
    _ = try @import("../../testing/managed_game.zig").start();
    defer Managed.global.stop();
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();
    const panel = &wb.panels.classes;
    wb.groups.engine.focusOwn(panel);
    frames.run(wb, 3);
    try testing.expect(panel.all.len > 1000);
    try testing.expect(panel.images > 10);
    try testing.expectEqual(panel.all.len, panel.shown.items.len);

    @memcpy(panel.search[0..13], "System.String");
    panel.refresh();
    const string = for (panel.shown.items) |e| {
        if (std.mem.eql(u8, e.name, "System.String")) break e;
    } else return error.NoString;
    try testing.expect(panel.shown.items.len < panel.all.len);
    panel.picked.only(@intFromPtr(string.class));
    // Addresses comes to the front as the workbench starts
    wb.groups.engine.focusOwn(panel);
    frames.run(wb, 3);
    try testing.expectEqual(string.class, panel.members_of.?);
    const empty = for (panel.fields) |f| {
        if (std.mem.eql(u8, f.name, "Empty")) break f;
    } else return error.NoEmpty;
    try testing.expect(empty.is_static);
    const concat = for (panel.methods) |m| {
        if (std.mem.eql(u8, m.name, "Concat") and std.mem.startsWith(u8, m.signature, "(System.String, System.String) ")) break m;
    } else return error.NoConcat;
    try testing.expectEqualStrings("(System.String, System.String) System.String", concat.signature);
    try testing.expect(panel.codeOf(concat.method) != null);
}

test "log clear from its menu" {
    const ui = @import("wraith_ui");
    var frames = try Frames.init();
    defer frames.deinit();
    @import("../../LogHistory.zig").global.add(.warn, .runtime, "clear me");
    var log: Workbench.Log = .{};
    defer log.deinit();
    const io = c.ImGui_GetIO();
    var popped = false;
    for (0..24) |frame| {
        switch (frame) {
            3 => c.ImGuiIO_AddMousePosEvent(io, 100, 120),
            5 => c.ImGuiIO_AddMouseButtonEvent(io, 1, true),
            6 => c.ImGuiIO_AddMouseButtonEvent(io, 1, false),
            // The menu opens at the mouse, and Clear is under Copy and a separator
            9 => c.ImGuiIO_AddMousePosEvent(io, 115, 152),
            11 => c.ImGuiIO_AddMouseButtonEvent(io, 0, true),
            13 => c.ImGuiIO_AddMouseButtonEvent(io, 0, false),
            else => {},
        }
        c.ImGui_NewFrame();
        tuft_imgui.headless.textures();
        c.ImGui_SetNextWindowPos(.{ .x = 0, .y = 0 }, c.ImGuiCond_Always);
        if (ui.window("Log", .{ .size = .{ 600, 400 } })) |win| {
            defer win.end();
            log.draw();
        }
        if (c.ImGui_IsPopupOpen(@ptrCast(""), c.ImGuiPopupFlags_AnyPopupId)) popped = true;
        c.ImGui_Render();
    }
    try testing.expect(popped);
    try testing.expectEqual(0, log.len);
}

test "debug panels" {
    var rig: Rig = undefined;
    try rig.init(.{});
    defer rig.deinit();
    for (0..3) |_| rig.present();
    var frames = try Frames.init();
    defer frames.deinit();
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();

    @import("../../LogHistory.zig").global.add(.warn, .runtime, "debug panels test");
    frames.run(wb, 3);
    const panels = &wb.panels;

    // Only the tab showing draws
    wb.groups.diagnostics.focus(&panels.memory);
    frames.run(wb, 3);
    var found_pages = false;
    for (panels.memory.stats[0..panels.memory.len]) |s| {
        if (std.mem.eql(u8, s.name(), "pages")) found_pages = s.live_bytes > 0;
    }
    try testing.expect(found_pages);

    try testing.expect(hook.registry.snapshot(&panels.hooks.infos) >= 2);
    for (panels.hooks.infos[0..2]) |info| try testing.expect(info.patch_len >= 5 or info.patch_len == @sizeOf(usize));
    wb.groups.diagnostics.focus(&panels.claims);
    frames.run(wb, 3);
    try testing.expect(panels.claims.total >= 4);
    try testing.expectEqual(.hook, panels.claims.claims[0].kind);
    var found_zone = false;
    for (panels.timings.stats[0..core.timing.registry.snapshot(&panels.timings.stats)]) |s| {
        if (std.mem.eql(u8, s.name(), "overlay")) found_zone = s.calls >= 3;
    }
    try testing.expect(found_zone);
    var found_line = false;
    for (0..panels.log.len) |i| {
        if (std.mem.eql(u8, panels.log.at(i).message(), "debug panels test")) found_line = true;
    }
    try testing.expect(found_line);
}

var watched_value: u32 align(8) = 0;

test "what writes and reads" {
    const wb = try Workbench.create(testing.allocator, .{});
    defer wb.destroy();

    // The game's code, not ours, since ours gets skipped. Padded with int3
    const page = try tuft_sys.memory.allocAny(128);
    defer tuft_sys.memory.free(page);
    @memset(page, 0xCC);
    const store_code: []const u8 = if (is64) &.{ 0x89, 0x11, 0xC3 } else &.{ 0x8B, 0x44, 0x24, 0x04, 0x8B, 0x4C, 0x24, 0x08, 0x89, 0x08, 0xC3 };
    const load_code: []const u8 = if (is64) &.{ 0x8B, 0x01, 0xC3 } else &.{ 0x8B, 0x44, 0x24, 0x04, 0x8B, 0x00, 0xC3 };
    @memcpy(page[32..][0..store_code.len], store_code);
    @memcpy(page[80..][0..load_code.len], load_code);
    const store: *const fn (*u32, u32) callconv(.c) void = @ptrCast(page.ptr + 32);
    const load: *const fn (*u32) callconv(.c) u32 = @ptrCast(page.ptr + 80);

    const list = &wb.panels.addresses.list;
    try list.addAddress(@intFromPtr(&watched_value), .four_bytes, 0);
    const target = list.selectedTarget().?;
    const accesses = &wb.panels.accesses;
    accesses.start(target.address, target.len, .writes, "hp");
    accesses.start(target.address, target.len, .reads, "hp");
    try testing.expectEqual(null, accesses.problem);

    store(&watched_value, 5);
    store(&watched_value, 6);
    _ = load(&watched_value);
    @as(*volatile u32, &watched_value).* = 7;
    // Hits get counted on the workbench's tick, open or not
    wb.tick();

    const writes = &accesses.watches.items[0];
    try testing.expectEqual(1, writes.shown());
    try testing.expectEqual(2, writes.rows.items[0].count);
    try testing.expectEqual(@intFromPtr(page.ptr) + 32 + store_code.len - 3, writes.rows.items[0].at);
    try testing.expect(std.mem.startsWith(u8, writes.rows.items[0].text.get(), "mov dword ptr ["));
    // The stores touch it too, but only the load reads it
    const reads = &accesses.watches.items[1];
    try testing.expectEqual(1, reads.shown());
    for (reads.rows.items) |*row| {
        if (!row.hidden) try testing.expectEqual(@intFromPtr(page.ptr) + 80 + load_code.len - 3, row.at);
    }

    accesses.stop(0);
    store(&watched_value, 8);
    wb.tick();
    try testing.expectEqual(2, writes.rows.items[0].count);

    var frames = try Frames.init();
    defer frames.deinit();
    frames.run(wb, 5);
    try testing.expectEqual(reads.key, accesses.shown_key);
}
