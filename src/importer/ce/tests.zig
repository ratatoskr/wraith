//! Whole tables through the importer, small and handwritten.

const std = @import("std");
const testing = std.testing;
const tweak_format = @import("wraith_api").tweak;

const ce = @import("root.zig");
const convert = @import("convert.zig");

fn tweakFrom(arena: std.mem.Allocator, source: []const u8) !convert.Tweak {
    return convert.convert(arena, testing.allocator, source, .{ .main_module = "game.exe" });
}

fn rendered(arena: std.mem.Allocator, t: convert.Tweak, original: []const u8) ![]const u8 {
    const r = try ce.render.file(arena, .{ .tweaks = &.{.{ .title = "T", .tweak = t, .original = original }} });
    var problem: tweak_format.Problem = .{};
    _ = tweak_format.parseFile(arena, r.text, &problem) catch |err| {
        std.debug.print("line {d}: {s}\n{s}\n", .{ problem.line, problem.message(), r.text });
        return err;
    };
    return r.text;
}

test "the injection template with the same code is an @inject" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[ENABLE]
        \\aobscanmodule(INJECT,game.exe,8B 83 98 00 00 00 48)
        \\alloc(newmem,$1000,INJECT)
        \\label(code)
        \\label(return)
        \\registersymbol(INJECT)
        \\newmem:
        \\  cmp [rbx+10],#0
        \\  je code
        \\  mov eax,#100
        \\code:
        \\  mov eax,[rbx+00000098]
        \\  jmp return
        \\INJECT:
        \\  jmp newmem
        \\  nop
        \\return:
        \\[DISABLE]
        \\INJECT:
        \\  db 8B 83 98 00 00 00
        \\unregistersymbol(INJECT)
        \\dealloc(newmem)
    ;
    const t = try tweakFrom(a, source);
    try testing.expectEqual(.clean, t.status);
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@sym INJECT = sig("8B 83 98 00 00 00 48")
        \\@inject INJECT
        \\  cmp dword ptr [rbx+0x10],0
        \\  je original
        \\  mov eax,100
        \\
    , try rendered(a, t, source));
}

test "the injection template with changed code is a @patch with expect" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[ENABLE]
        \\aobscanmodule(hp,$process,89 83 98 00 00 00)
        \\alloc(newmem,$1000,hp)
        \\label(code)
        \\label(return)
        \\newmem:
        \\code:
        \\  mov [rbx+98],(float)100
        \\  jmp return
        \\hp:
        \\  jmp newmem
        \\  nop
        \\return:
        \\[DISABLE]
        \\hp:
        \\  db 89 83 98 00 00 00
    ;
    const t = try tweakFrom(a, source);
    try testing.expectEqual(.clean, t.status);
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@sym hp = sig("89 83 98 00 00 00")
        \\@patch hp expect "mov dword ptr [rbx+0x98], eax"
        \\  code:
        \\  mov dword ptr [rbx+0x98],0x42C80000
        \\
    , try rendered(a, t, source));
}

test "the original code inline, then back, is an @inject" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[ENABLE]
        \\alloc(newmem,2048,game.exe+BFA4B)
        \\label(returnhere)
        \\label(iXPMultiplier)
        \\registersymbol(iXPMultiplier)
        \\game.exe+BFA4B:
        \\  jmp newmem
        \\  nop
        \\returnhere:
        \\newmem:
        \\  imul ebx,[iXPMultiplier]
        \\  mov r12d,[r14+04]
        \\  add edx,ebx
        \\  jmp returnhere
        \\iXPMultiplier:
        \\  dq #10
        \\[DISABLE]
        \\game.exe+BFA4B:
        \\  db 45 8b 66 04 03 d3
        \\unregistersymbol(iXPMultiplier)
        \\dealloc(newmem)
    ;
    const t = try tweakFrom(a, source);
    try testing.expectEqual(.clean, t.status);
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@data near game.exe+0xBFA4B
        \\  u64 iXPMultiplier = 10
        \\@inject game.exe+0xBFA4B
        \\  imul ebx,[iXPMultiplier]
        \\
    , try rendered(a, t, source));
}

test "the patch template" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[ENABLE]
        \\aobscanmodule(NoDmg,$process,29 C2 89 93 98 00 00 00)
        \\NoDmg+2:
        \\  db 90 90 90 90 90 90
        \\[DISABLE]
        \\NoDmg+2:
        \\  db 89 93 98 00 00 00
    ;
    const t = try tweakFrom(a, source);
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@sym NoDmg = sig("29 C2 89 93 98 00 00 00")
        \\@patch NoDmg+2 expect "mov dword ptr [rbx+0x98], edx"
        \\  nop
        \\
    , try rendered(a, t, source));

    // Half an instruction is raw bytes
    const jump =
        \\[ENABLE]
        \\game.exe+1234:
        \\  db EB
        \\[DISABLE]
        \\game.exe+1234:
        \\  db 74 05
    ;
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@bytes game.exe+0x1234 expect "74"
        \\  EB
        \\
    , try rendered(a, try tweakFrom(a, jump), jump));

    // Asm both ways
    const asm_both =
        \\[ENABLE]
        \\game.exe+4EFF6F:
        \\  nop 3
        \\[DISABLE]
        \\game.exe+4EFF6F:
        \\  sub r8d,edx
    ;
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@patch game.exe+0x4EFF6F expect "sub r8d,edx"
        \\  nop
        \\
    , try rendered(a, try tweakFrom(a, asm_both), asm_both));

    // CE's two-operand imul with a number is the three-operand one
    const imul =
        \\[ENABLE]
        \\game.exe+10:
        \\  imul edx,#100
        \\[DISABLE]
        \\game.exe+10:
        \\  imul edx,edx,32
    ;
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@patch game.exe+0x10 expect "imul edx,edx,0x32"
        \\  imul edx,edx,100
        \\
    , try rendered(a, try tweakFrom(a, imul), imul));

    // [DISABLE] that writes what [ENABLE] did isn't the original, so there's nothing to expect
    const same =
        \\[ENABLE]
        \\game.exe+38A878:
        \\  mov [rbx+rcx*4+470C],1
        \\[DISABLE]
        \\game.exe+38A878:
        \\  mov [rbx+rcx*4+470C],1
    ;
    const unchecked = try tweakFrom(a, same);
    try testing.expectEqual(1, unchecked.notes.len);
    try testing.expectEqualStrings(if (@import("builtin").cpu.arch == .x86_64)
        \\@tweak "T"
        \\// ce: no real restore in the table, so the original isn't checked
        \\@patch game.exe+0x38A878 (11)
        \\  mov dword ptr [rbx+rcx*4+0x470C],1
        \\
    else
        \\@tweak "T"
        \\// ce: no real restore in the table, so the original isn't checked
        \\@patch game.exe+0x38A878
        \\  mov dword ptr [rbx+rcx*4+0x470C],1
        \\
    , try rendered(a, unchecked, same));
}

test "copies of the original, a jump back by address and a label without label()" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[ENABLE]
        \\aobscanmodule(INJ,$process,8B 83 98 00 00 00 48)
        \\alloc(newmem,$100,INJ)
        \\alloc(backup,8)
        \\backup:
        \\  readmem(INJ,6)
        \\newmem:
        \\  cmp [rbx+10],0
        \\  je skip
        \\  mov eax,#5
        \\skip:
        \\  readmem(INJ,6)
        \\  jmp INJ+6
        \\INJ:
        \\  jmp newmem
        \\  nop
        \\[DISABLE]
        \\INJ:
        \\  readmem(backup,6)
    ;
    const t = try tweakFrom(a, source);
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@sym INJ = sig("8B 83 98 00 00 00 48")
        \\@inject INJ
        \\  cmp dword ptr [rbx+0x10],0
        \\  je original
        \\  mov eax,5
        \\
    , try rendered(a, t, source));
}

test "what it isn't sure of is off, with the original kept" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[ENABLE]
        \\game.exe+10:
        \\  call Recorder
        \\[DISABLE]
    ;
    const t = try tweakFrom(a, source);
    try testing.expectEqual(.review, t.status);
    const text = try rendered(a, t, source);
    try testing.expect(std.mem.indexOf(u8, text, "// ce: off for review") != null);
    try testing.expect(std.mem.indexOf(u8, text, "//   call Recorder") != null);

    const missing =
        \\[ENABLE]
        \\alloc(newmem,64)
        \\label(back)
        \\newmem:
        \\  call Recorder
        \\  jmp back
        \\game.exe+10:
        \\  jmp newmem
        \\back:
        \\[DISABLE]
        \\game.exe+10:
        \\  db 8B 83 98 00 00 00
    ;
    const m = try tweakFrom(a, missing);
    try testing.expectEqual(.review, m.status);
    try testing.expectEqualStrings("Recorder", m.missing[0]);
}

test "lua comes in live, with [DISABLE] as off()" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\[ENABLE]
        \\{$lua}
        \\if syntaxcheck then return end
        \\getAddressList().getMemoryRecordByDescription("x").Active = true
        \\{$asm}
        \\[DISABLE]
        \\{$lua}
        \\print("off")
        \\{$asm}
    ;
    const t = try tweakFrom(a, source);
    try testing.expectEqual(.lua, t.status);
    const text = try rendered(a, t, source);
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@lua
        \\getAddressList().getMemoryRecordByDescription("x").Active = true
        \\
        \\function off()
        \\print("off")
        \\end
        \\
    , text);
}

const table_source =
    \\<?xml version="1.0" encoding="utf-8"?>
    \\<CheatTable CheatEngineTableVersion="45">
    \\  <CheatEntries>
    \\    <CheatEntry>
    \\      <ID>1</ID>
    \\      <Description>"Cheats &amp; more"</Description>
    \\      <VariableType>Auto Assembler Script</VariableType>
    \\      <AssemblerScript>[ENABLE]
    \\alloc(shared,64)
    \\label(pBase)
    \\registersymbol(pBase)
    \\shared:
    \\pBase:
    \\  dq 0
    \\[DISABLE]
    \\unregistersymbol(pBase)
    \\</AssemblerScript>
    \\      <CheatEntries>
    \\        <CheatEntry>
    \\          <ID>2</ID>
    \\          <Description>"God mode"</Description>
    \\          <VariableType>Auto Assembler Script</VariableType>
    \\          <Hotkeys>
    \\            <Hotkey><Action>Toggle Activation</Action><Keys><Key>17</Key><Key>112</Key></Keys><ID>0</ID></Hotkey>
    \\          </Hotkeys>
    \\          <AssemblerScript>[ENABLE]
    \\alloc(GodMode,8)
    \\alloc(ItemId,4)
    \\registersymbol(GodMode ItemId)
    \\GodMode:
    \\  dd 1
    \\game.exe+4EFF6F:
    \\  nop 3
    \\[DISABLE]
    \\game.exe+4EFF6F:
    \\  sub r8d,edx
    \\</AssemblerScript>
    \\          <CheatEntries>
    \\            <CheatEntry>
    \\              <ID>3</ID>
    \\              <Description>"On"</Description>
    \\              <DropDownList DescriptionOnly="1">0:Off
    \\1:On
    \\</DropDownList>
    \\              <VariableType>4 Bytes</VariableType>
    \\              <Address>GodMode</Address>
    \\            </CheatEntry>
    \\            <CheatEntry>
    \\              <ID>8</ID>
    \\              <Description>"Item"</Description>
    \\              <DropDownList DescriptionOnly="1">0:None
    \\1:Potion
    \\2:Elixir
    \\</DropDownList>
    \\              <VariableType>4 Bytes</VariableType>
    \\              <Address>ItemId</Address>
    \\            </CheatEntry>
    \\          </CheatEntries>
    \\        </CheatEntry>
    \\        <CheatEntry>
    \\          <ID>4</ID>
    \\          <Description>"Lua thing"</Description>
    \\          <VariableType>Auto Assembler Script</VariableType>
    \\          <AssemblerScript>{$lua}
    \\[ENABLE]
    \\print(1)
    \\[DISABLE]
    \\</AssemblerScript>
    \\        </CheatEntry>
    \\      </CheatEntries>
    \\    </CheatEntry>
    \\    <CheatEntry>
    \\      <ID>5</ID>
    \\      <Description>"Party"</Description>
    \\      <GroupHeader>1</GroupHeader>
    \\      <Address>[pBase]+38</Address>
    \\      <CheatEntries>
    \\        <CheatEntry>
    \\          <ID>6</ID>
    \\          <Description>"HP"</Description>
    \\          <VariableType>2 Bytes</VariableType>
    \\          <Address>+297990</Address>
    \\          <Offsets>
    \\            <Offset>10</Offset>
    \\            <Offset>8</Offset>
    \\          </Offsets>
    \\        </CheatEntry>
    \\        <CheatEntry>
    \\          <ID>7</ID>
    \\          <Description>"Item"</Description>
    \\          <DropDownList>0:None
    \\1:Potion
    \\</DropDownList>
    \\          <VariableType>Byte</VariableType>
    \\          <Address>-8</Address>
    \\        </CheatEntry>
    \\      </CheatEntries>
    \\    </CheatEntry>
    \\  </CheatEntries>
    \\  <LuaScript>print("table")</LuaScript>
    \\</CheatTable>
;

fn fileText(p: ce.Project, path: []const u8) ?[]const u8 {
    for (p.files) |f| if (std.mem.eql(u8, f.path, path)) return f.text;
    return null;
}

test "table files come over for findTableFile" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // An old table's hex: a deflate stored block of "RIFF", then one that won't inflate
    const source =
        \\<?xml version="1.0" encoding="utf-8"?>
        \\<CheatTable CheatEngineTableVersion="45">
        \\  <LuaScript>playSound(findTableFile("ding.wav"))</LuaScript>
        \\  <Files><ding.wav>010400FBFF52494646</ding.wav><broken.wav>FF</broken.wav></Files>
        \\</CheatTable>
    ;
    const p = try ce.import(a, testing.allocator, source, .{ .name = "sounds.CT" });
    const file = fileText(p, "tweaks/sounds.rwt").?;
    const files_at = std.mem.indexOf(u8, file, "ce.files {\n  [\"ding.wav\"] = [[\nUklGRg==\n]],\n}\n") orelse {
        std.debug.print("{s}\n", .{file});
        return error.TestUnexpectedResult;
    };
    // Before the table's Lua, which may want them straight away
    try testing.expect(files_at < std.mem.indexOf(u8, file, "playSound(findTableFile").?);
    try testing.expect(std.mem.indexOf(u8, p.report, "`broken.wav` couldn't be read") != null);
    try testing.expect(std.mem.indexOf(u8, p.report, "1 table file(s) came over") != null);
}

test "a table becomes a project" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const p = try ce.import(a, testing.allocator, table_source, .{ .name = "test.CT" });

    // One file for the table, the parent a group with its own script shared, and the record a
    // Toggle field
    const file = fileText(p, "tweaks/test.rwt").?;
    const want = [_][]const u8{
        "@group \"test\"\n@children none\n@globals shared\n@use ce\n@lua\n-- ce: the table's records, for getAddressList()\nce.load {\n",
        "  { id = 2, parent = 1, description = \"God mode\", type = \"Auto Assembler Script\", tweak = \"./Cheats & more/God mode\" },\n",
        "data = \"\\\"test.Cheats & more.God mode.GodMode\\\"\" },\n",
        "{ id = 6, parent = 5, description = \"HP\", type = \"2 Bytes\", address = \"test.HP\" },\n",
        "-- ce: the table's own Lua script, which CE ran when it opened the table\nprint(\"table\")\n",
        "\n@group \"Cheats & more\"\n@children none\n@data near game.exe\n  u64 pBase = 0\n",
        \\
        \\@tweak "God mode"
        \\@key Ctrl+F1
        \\@data near game.exe+0x4EFF6F
        \\  [Label("Item"), Choices("0:None", "1:Potion", "2:Elixir")] u32 ItemId = 0
        \\  [Label("On"), Toggle] u32 GodMode = 1
        \\@patch game.exe+0x4EFF6F expect "sub r8d,edx"
        \\  nop
        \\
        \\@tweak "Lua thing"
        \\@lua
        \\print(1)
        \\@end
        \\
        ,
    };
    for (want) |w| if (std.mem.indexOf(u8, file, w) == null) {
        std.debug.print("wanted:\n{s}\nin:\n{s}\n", .{ w, file });
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(1, p.stats.tweak_files);
    try testing.expectEqual(1, p.stats.lua);
    // Every tweak file parses
    for (p.files) |f| if (std.mem.endsWith(u8, f.path, ".rwt")) {
        var problem: tweak_format.Problem = .{};
        _ = try tweak_format.parseFile(a, f.text, &problem);
    };

    // A group with an address, children relative to it, offsets in the order they're followed
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const saved = try std.zon.parse.fromSlice(ce.records.Saved, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, fileText(p, ce.addresses_file).?, 0), .diagnostics = &diagnostics, .ignore_unknown_fields = true });
    try testing.expectEqual(3, saved.items.len);
    try testing.expectEqualStrings("Party", saved.items[0].name);
    try testing.expect(saved.items[0].group);
    try testing.expectEqualStrings("[\"test.Cheats & more.pBase\"]+0x38", saved.items[0].address);
    try testing.expectEqualStrings("+0x297990", saved.items[1].address);
    try testing.expectEqualStrings("8", saved.items[1].offsets[0]);
    try testing.expectEqualStrings("0x10", saved.items[1].offsets[1]);
    try testing.expectEqual(.two_bytes, saved.items[1].kind);
    try testing.expectEqual(1, saved.items[1].depth);
    try testing.expectEqualStrings("-8", saved.items[2].address);
    // With Lua, each one gets an id the CE layer finds it by
    try testing.expectEqualStrings("test.Party", saved.items[0].id);
    try testing.expectEqualStrings("test.Item", saved.items[2].id);

    try testing.expectEqual(2, p.stats.clean);
    try testing.expectEqual(1, p.stats.lua);
    try testing.expectEqual(1, p.stats.keys);
    try testing.expectEqual(2, p.stats.choices);
    const r = p.report;
    try testing.expect(std.mem.indexOf(u8, r, "| Scripts converted to tweaks | 2 |") != null);
    try testing.expect(std.mem.indexOf(u8, r, "dropdown didn't come over") == null);
    try testing.expectEqual(2, saved.items[2].choices.len);
    try testing.expectEqualStrings("Potion", saved.items[2].choices[1].label);
    try testing.expect(std.mem.indexOf(u8, r, "| Lua scripts that run with the CE layer | 1 |") != null);
}

test "record hotkeys, dropdowns, bits and freeze modes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\<CheatTable><CheatEntries>
        \\<CheatEntry><ID>1</ID><Description>"Mode"</Description><VariableType>4 Bytes</VariableType><Address>game.exe+10</Address>
        \\  <DropDownList DisplayValueAsItem="1">0:Easy
        \\1:Hard
        \\</DropDownList>
        \\  <Hotkeys>
        \\    <Hotkey><Action>Set Value</Action><Keys><Key>17</Key><Key>112</Key></Keys><Value>1</Value><ID>0</ID></Hotkey>
        \\    <Hotkey><Action>Toggle Activation Allow Increase</Action><Keys><Key>113</Key></Keys><ID>1</ID></Hotkey>
        \\    <Hotkey><Action>Increase Value</Action><Keys><Key>114</Key></Keys><Value>5</Value><ID>2</ID></Hotkey>
        \\    <Hotkey><Action>Deactivate</Action><Keys><Key>115</Key></Keys><ID>3</ID></Hotkey>
        \\  </Hotkeys>
        \\</CheatEntry>
        \\<CheatEntry><ID>2</ID><Description>"Mode 2"</Description><VariableType>4 Bytes</VariableType><Address>game.exe+14</Address>
        \\  <DropDownList DescriptionOnly="1"></DropDownList><DropDownListLink>Mode</DropDownListLink>
        \\</CheatEntry>
        \\<CheatEntry><ID>3</ID><Description>"Flags"</Description><VariableType>Binary</VariableType><BitStart>6</BitStart><BitLength>3</BitLength><Address>game.exe+18</Address>
        \\  <DropDownList DescriptionOnly="1">0:Off
        \\1:On
        \\</DropDownList>
        \\  <Hotkeys><Hotkey><Action>Activate</Action><Keys><Key>116</Key></Keys><ID>0</ID></Hotkey></Hotkeys>
        \\</CheatEntry>
        \\</CheatEntries></CheatTable>
    ;
    const p = try ce.import(a, testing.allocator, source, .{ .name = "test.CT" });
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const saved = try std.zon.parse.fromSlice(ce.records.Saved, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, fileText(p, ce.addresses_file).?, 0), .diagnostics = &diagnostics, .ignore_unknown_fields = true });
    try testing.expectEqual(3, saved.items.len);
    const mode = saved.items[0];
    try testing.expectEqual(2, mode.choices.len);
    try testing.expectEqualStrings("Hard", mode.choices[1].label);
    try testing.expect(!mode.labels_only);
    try testing.expectEqual(.only_increase, mode.freeze);
    try testing.expectEqual(4, mode.hotkeys.len);
    try testing.expectEqual(.set, mode.hotkeys[0].action);
    try testing.expectEqualStrings("1", mode.hotkeys[0].value);
    try testing.expect(mode.hotkeys[0].chord.?.mods.ctrl);
    try testing.expectEqual(.f1, mode.hotkeys[0].chord.?.key);
    try testing.expectEqual(.toggle_hold, mode.hotkeys[1].action);
    try testing.expectEqual(.increase, mode.hotkeys[2].action);
    try testing.expectEqual(.release, mode.hotkeys[3].action);
    // Linked by the id it got for that
    try testing.expect(mode.id.len > 0);
    try testing.expectEqualStrings(mode.id, saved.items[1].choices_from);
    try testing.expect(saved.items[1].labels_only);
    try testing.expectEqual(0, saved.items[1].choices.len);
    const flags = saved.items[2];
    try testing.expectEqual(.two_bytes, flags.kind);
    try testing.expectEqual(6, flags.bits.?.shift);
    try testing.expectEqual(3, flags.bits.?.width);
    try testing.expect(flags.labels_only);
    try testing.expectEqual(.hold, flags.hotkeys[0].action);
    const r = p.report;
    try testing.expect(std.mem.indexOf(u8, r, "didn't come over") == null);
    try testing.expect(std.mem.indexOf(u8, r, "bits from bit") == null);
}

test "nested CE parents become nested groups with their @children" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const script = "[ENABLE]\n{$lua}\nprint(1)\n{$asm}\n[DISABLE]\n";
    const source = std.fmt.comptimePrint(
        \\<CheatTable><CheatEntries>
        \\<CheatEntry><ID>1</ID><Description>"HP/MP"</Description><Options moActivateChildrenAsWell="1"/><GroupHeader>1</GroupHeader><CheatEntries>
        \\  <CheatEntry><ID>2</ID><Description>"Main"</Description><Options moDeactivateChildrenAsWell="1"/><VariableType>Auto Assembler Script</VariableType><AssemblerScript>{0s}</AssemblerScript><CheatEntries>
        \\    <CheatEntry><ID>3</ID><Description>"One"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>{0s}</AssemblerScript></CheatEntry>
        \\    <CheatEntry><ID>4</ID><Description>"One"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>{0s}</AssemblerScript></CheatEntry>
        \\  </CheatEntries></CheatEntry>
        \\  <CheatEntry><ID>5</ID><Description>"Both"</Description><Options moActivateChildrenAsWell="1" moDeactivateChildrenAsWell="1"/><GroupHeader>1</GroupHeader><CheatEntries>
        \\    <CheatEntry><ID>6</ID><Description>"Loop"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
        \\{{$lua}}
        \\for i = 1, 3 do i = i * 2 print(i) end
        \\{{$asm}}
        \\[DISABLE]
        \\</AssemblerScript></CheatEntry>
        \\  </CheatEntries></CheatEntry>
        \\</CheatEntries></CheatEntry>
        \\</CheatEntries></CheatTable>
    , .{script});
    const p = try ce.import(a, testing.allocator, source, .{ .name = "Kai.CT" });
    const file = fileText(p, "tweaks/kai.rwt").?;
    const want =
        \\@group "HP-MP"
        \\@children on
        \\
        \\@group "Main"
        \\@children off
        \\@lua
        \\print(1)
        \\
        \\@tweak "One"
        \\@lua
        \\print(1)
        \\
        \\@tweak "One 2"
        \\@lua
        \\print(1)
        \\@end
        \\
        \\@group "Both"
        \\
        \\@tweak "Loop"
        \\@lua
        \\for i = 1, 3 do local i = i i = i * 2 print(i) end
        \\@end
        \\@end
        \\
    ;
    if (std.mem.indexOf(u8, file, want) == null) {
        std.debug.print("wanted:\n{s}\nin:\n{s}\n", .{ want, file });
        return error.TestUnexpectedResult;
    }
    try testing.expect(std.mem.startsWith(u8, file, "@group \"Kai\"\n@children none\n@globals shared\n@use ce\n@lua\n"));
    try testing.expect(std.mem.indexOf(u8, file, "tweak = \"./HP-MP/Main/One 2\"") != null);
    try testing.expect(std.mem.indexOf(u8, p.report, "\"HP-MP\" now, since titles in a file with groups can't have /") != null);
    try testing.expect(std.mem.indexOf(u8, p.report, "\"One 2\" now, since something next to it has its name") != null);
    try testing.expectEqual(4, p.stats.lua);
    try testing.expectEqual(3, p.stats.tweak_groups);

    var problem: tweak_format.Problem = .{};
    const f = try tweak_format.parseFile(a, file, &problem);
    const both = f.resolve("HP-MP/Both").?;
    try testing.expect(f.groups[both.group].children.on and f.groups[both.group].children.off);
    try testing.expect(!f.groups[f.resolve("HP-MP/Main").?.group].children.on);
    try testing.expect(f.resolve("HP-MP/Main/One 2") != null);
}

test "Lua next to asm is one tweak, unless the Lua makes the asm" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mixed =
        \\[ENABLE]
        \\{$lua}
        \\if syntaxcheck then return end
        \\memrec.Child[0].DropDownList.Text = "0:None"
        \\{$asm}
        \\alloc(newmem,64,game.exe+10)
        \\label(return)
        \\label(item)
        \\registersymbol(item)
        \\newmem:
        \\  mov [rsp+18],rbx
        \\  mov rdx,[item]
        \\  jmp return
        \\item:
        \\  dq 0
        \\game.exe+10:
        \\  jmp newmem
        \\return:
        \\[DISABLE]
        \\{$lua}
        \\print("off")
        \\{$asm}
        \\game.exe+10:
        \\  mov [rsp+18],rbx
    ;
    const t = try tweakFrom(a, mixed);
    try testing.expectEqual(.clean, t.status);
    try testing.expectEqualStrings(
        \\@tweak "T"
        \\@data near game.exe+0x10
        \\  u64 item = 0
        \\@patch game.exe+0x10 expect "mov [rsp+0x18],rbx"
        \\  mov [rsp+0x18],rbx
        \\  mov rdx,[item]
        \\@lua
        \\memrec.Child[0].DropDownList.Text = "0:None"
        \\
        \\function off()
        \\print("off")
        \\end
        \\
    , try rendered(a, t, mixed));

    const makes_asm = "[ENABLE]\n{$lua}\nreturn 'game.exe+10:\\n  nop'\n{$asm}\ngame.exe+20:\n  nop\n[DISABLE]\ngame.exe+20:\n  db 90\n";
    try testing.expectEqual(.review, (try tweakFrom(a, makes_asm)).status);
}

test "records named by description get ids, and math stays math" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source =
        \\<CheatTable><CheatEntries>
        \\<CheatEntry><ID>1</ID><Description>"Party Manager"</Description><GroupHeader>1</GroupHeader><Address>(PartyManager)</Address><CheatEntries>
        \\  <CheatEntry><ID>2</ID><Description>"Van Route"</Description><VariableType>4 Bytes</VariableType><Address>+218*0</Address></CheatEntry>
        \\  <CheatEntry><ID>3</ID><Description>"SP"</Description><VariableType>2 Bytes</VariableType><Address>+4*1A</Address></CheatEntry>
        \\</CheatEntries></CheatEntry>
        \\<CheatEntry><ID>4</ID><Description>"Field"</Description><GroupHeader>1</GroupHeader><Address>game.exe+D600B8</Address><Offsets><Offset>0</Offset></Offsets><CheatEntries>
        \\  <CheatEntry><ID>5</ID><Description>"PartyManager"</Description><GroupHeader>1</GroupHeader><Address>+600</Address><Offsets><Offset>0</Offset></Offsets></CheatEntry>
        \\</CheatEntries></CheatEntry>
        \\<CheatEntry><ID>6</ID><Description>"Gold"</Description><VariableType>4 Bytes</VariableType><Address>(Field)+10</Address></CheatEntry>
        \\</CheatEntries></CheatTable>
    ;
    const p = try ce.import(a, testing.allocator, source, .{ .name = "kai.CT" });
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const saved = try std.zon.parse.fromSlice(ce.records.Saved, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, fileText(p, ce.addresses_file).?, 0), .diagnostics = &diagnostics, .ignore_unknown_fields = true });
    const want = [_]struct { []const u8, []const u8 }{
        .{ "", "(kai.PartyManager)" },
        .{ "", "+0x218*0" },
        .{ "", "+4*0x1A" },
        .{ "kai.Field", "game.exe+0xD600B8" },
        .{ "kai.PartyManager", "+0x600" },
        .{ "", "(kai.Field)+0x10" },
    };
    try testing.expectEqual(want.len, saved.items.len);
    for (want, saved.items) |w, item| {
        try testing.expectEqualStrings(w[0], item.id);
        try testing.expectEqualStrings(w[1], item.address);
    }
    // Nothing's missing, since those names are records
    try testing.expect(std.mem.indexOf(u8, p.report, "## Missing names") == null);
}
