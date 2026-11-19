//! A table like kai.CT imported, then run as tweaks in a workbench session with every one on, the
//! way the game would. Its code changes go into this test's own code.

const std = @import("std");
const builtin = @import("builtin");

const ce = @import("wraith_importer").ce;
const sys = @import("tuft_sys");
const Owner = @import("tuft_event").Owner;

const host = @import("../host/root.zig");
const Libraries = @import("../Libraries.zig");
const Names = @import("../Names.zig");
const Rig = @import("testing.zig").Rig;

const testing = std.testing;
const io = testing.io;

// Code like the game's that the table changes. Never run, only patched

/// `mov ecx,[rbx+0C]; mov eax,[rbx+14]`, where hits are worked out.
fn damageSite() callconv(.naked) void {
    asm volatile (".byte 0x8B, 0x4B, 0x0C, 0x8B, 0x43, 0x14, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC");
}

/// `cmp ecx,eax; cmovl ax,cx`, which caps a stack of items.
fn stackSite() callconv(.naked) void {
    asm volatile (".byte 0x3B, 0xC8, 0x66, 0x0F, 0x4C, 0xC1, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC");
}

/// `mov dword ptr [rbx+rcx*4+0x10],2`, the enemy's sight of you.
fn sightSite() callconv(.naked) void {
    asm volatile (".byte 0xC7, 0x44, 0x8B, 0x10, 0x02, 0x00, 0x00, 0x00, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC");
}

/// `sub r8d,edx`, paying.
fn paySite() callconv(.naked) void {
    asm volatile (".byte 0x41, 0x29, 0xD0, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC");
}

/// `mov [rsp+18],rbx`, then the item given is in rdx.
fn itemSite() callconv(.naked) void {
    asm volatile (".byte 0x48, 0x89, 0x5C, 0x24, 0x18, 0xC3, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC");
}

// The game's data, behind pointers like kai's managers

var game_state: [16]u32 = .{ 0, 0, 0, 1234, 10, 77, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
var game_state_ptr: usize = 0;
var party: [16]u32 = .{ 0, 0, 0, 0, 0, 42, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
var field: [4]usize = .{ 0, 0, 0, 0 };
var field_ptr: usize = 0;

const table_text =
    \\<CheatTable><CheatEntries>
    \\<CheatEntry><ID>2</ID><Description>"Activate"</Description><Options moDeactivateChildrenAsWell="1"/><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
    \\{$lua}
    \\if syntaxcheck then return end
    \\local function activateRecords(descriptions)
    \\  local al = getAddressList()
    \\  for _, description in ipairs(descriptions) do
    \\    local record = al.getMemoryRecordByDescription(description)
    \\    if record then record.Active = true else print("Record not found: " .. description) end
    \\  end
    \\end
    \\activateRecords({ "Invisible", "Combat Mods", "Set Max Items", "Dont Subtract Mira" })
    \\{$asm}
    \\[DISABLE]
    \\</AssemblerScript><CheatEntries>
    \\<CheatEntry><ID>0</ID><Description>"Invisible"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
    \\{EXE}+{SIGHT}:
    \\  mov [rbx+rcx*4+10],1
    \\[DISABLE]
    \\{EXE}+{SIGHT}:
    \\  mov [rbx+rcx*4+10],1
    \\</AssemblerScript></CheatEntry>
    \\<CheatEntry><ID>6</ID><Description>"Combat Mods"</Description><Options moHideChildren="1"/><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
    \\alloc(newmem,1024,{EXE}+{DAMAGE})
    \\label(return)
    \\label(code)
    \\label(iCantDie)
    \\registersymbol(iCantDie)
    \\newmem:
    \\  cmp [iCantDie],1
    \\  jne code
    \\  mov edi,0
    \\code:
    \\  mov ecx,[rbx+0C]
    \\  mov eax,[rbx+14]
    \\  jmp return
    \\iCantDie:
    \\  dq 1
    \\{EXE}+{DAMAGE}:
    \\  jmp newmem
    \\  nop
    \\return:
    \\[DISABLE]
    \\{EXE}+{DAMAGE}:
    \\  mov ecx,[rbx+0C]
    \\  mov eax,[rbx+14]
    \\unregistersymbol(iCantDie)
    \\dealloc(newmem)
    \\</AssemblerScript><CheatEntries>
    \\<CheatEntry><ID>8</ID><Description>"Player Can't Die"</Description><VariableType>4 Bytes</VariableType><Address>iCantDie</Address><DropDownList>0:False
    \\1:True
    \\</DropDownList></CheatEntry>
    \\</CheatEntries></CheatEntry>
    \\<CheatEntry><ID>50</ID><Description>"Set Max Items"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
    \\alloc(newmem,1024,{EXE}+{STACK})
    \\label(return)
    \\label(above101)
    \\newmem:
    \\  cmp eax,#101
    \\  ja above101
    \\  cmp ecx,eax
    \\  cmovl ax,cx
    \\  jmp return
    \\above101:
    \\  lea eax,[eax-15]
    \\  jmp return
    \\{EXE}+{STACK}:
    \\  jmp newmem
    \\  nop
    \\return:
    \\[DISABLE]
    \\{EXE}+{STACK}:
    \\  db 3B C8 66 0F 4C C1
    \\dealloc(newmem)
    \\</AssemblerScript></CheatEntry>
    \\<CheatEntry><ID>48</ID><Description>"Dont Subtract Mira"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
    \\{EXE}+{PAY}:
    \\  nop 3
    \\[DISABLE]
    \\{EXE}+{PAY}:
    \\  sub r8d,edx
    \\</AssemblerScript></CheatEntry>
    \\<CheatEntry><ID>37</ID><Description>"Override Item"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
    \\{$lua}
    \\if syntaxcheck then return end
    \\local tableRecord = getAddressList().getMemoryRecordByDescription("GameStateManager")
    \\local base = getAddressSafe(tableRecord.CurrentAddress)
    \\local itemRecord = memrec.Child[0]
    \\itemRecord.DropDownList.Text = "0:None\n1:Potion\n" .. readInteger(base + 0xC) .. ":Gold"
    \\_G.mixed = memrec.Description .. ":" .. itemRecord.Description .. ":" .. itemRecord.DropDownList.Count
    \\{$asm}
    \\alloc(newmem,1024,{EXE}+{ITEM})
    \\label(return)
    \\label(iOverrideItemID)
    \\registersymbol(iOverrideItemID)
    \\newmem:
    \\  mov [rsp+18],rbx
    \\  mov rdx,[iOverrideItemID]
    \\  jmp return
    \\iOverrideItemID:
    \\  dq #7
    \\{EXE}+{ITEM}:
    \\  jmp newmem
    \\return:
    \\[DISABLE]
    \\{EXE}+{ITEM}:
    \\  mov [rsp+18],rbx
    \\unregistersymbol(iOverrideItemID)
    \\dealloc(newmem)
    \\</AssemblerScript><CheatEntries>
    \\<CheatEntry><ID>38</ID><Description>"Item ID"</Description><VariableType>4 Bytes</VariableType><Address>iOverrideItemID</Address></CheatEntry>
    \\</CheatEntries></CheatEntry>
    \\<CheatEntry><ID>63</ID><Description>"Party Manager"</Description><GroupHeader>1</GroupHeader><Address>(PartyManager)</Address><CheatEntries>
    \\<CheatEntry><ID>60</ID><Description>"Van Route"</Description><GroupHeader>1</GroupHeader><Address>+8*2</Address><CheatEntries>
    \\<CheatEntry><ID>61</ID><Description>"ID"</Description><VariableType>4 Bytes</VariableType><Address>+4</Address></CheatEntry>
    \\</CheatEntries></CheatEntry>
    \\</CheatEntries></CheatEntry>
    \\<CheatEntry><ID>47</ID><Description>"GameState"</Description><GroupHeader>1</GroupHeader><Address>(GameStateManager)</Address><CheatEntries>
    \\<CheatEntry><ID>19</ID><Description>"Mira"</Description><VariableType>4 Bytes</VariableType><Address>+C</Address></CheatEntry>
    \\</CheatEntries></CheatEntry>
    \\<CheatEntry><ID>3</ID><Description>"Advanced"</Description><GroupHeader>1</GroupHeader><CheatEntries>
    \\<CheatEntry><ID>42</ID><Description>"FieldManager"</Description><GroupHeader>1</GroupHeader><Address>{EXE}+{FIELD}</Address><Offsets><Offset>0</Offset></Offsets><CheatEntries>
    \\<CheatEntry><ID>59</ID><Description>"PartyManager"</Description><GroupHeader>1</GroupHeader><Address>+8</Address><Offsets><Offset>0</Offset></Offsets></CheatEntry>
    \\</CheatEntries></CheatEntry>
    \\<CheatEntry><ID>17</ID><Description>"GameStateManager"</Description><GroupHeader>1</GroupHeader><Address>[{EXE}+{STATE}]</Address></CheatEntry>
    \\</CheatEntries></CheatEntry>
    \\</CheatEntries></CheatEntry>
    \\<CheatEntry><ID>68</ID><Description>"Restore EP/HP"</Description><VariableType>Auto Assembler Script</VariableType><Hotkeys><Hotkey><Action>Toggle Activation</Action><Keys><Key>116</Key></Keys><ID>0</ID></Hotkey></Hotkeys><AssemblerScript>[ENABLE]
    \\{$lua}
    \\local addressList = getAddressList()
    \\local baseAddress = getAddressSafe(addressList.getMemoryRecordByDescription("GameStateManager").CurrentAddress)
    \\writeInteger(baseAddress + 0x10, readInteger(baseAddress + 0x14))
    \\_G.id_at = addressList.getMemoryRecordByDescription("ID").CurrentAddress
    \\_G.mira = addressList.getMemoryRecordByDescription("Mira").Value
    \\{$asm}
    \\[DISABLE]
    \\</AssemblerScript></CheatEntry>
    \\</CheatEntries></CheatTable>
;

/// The table with this test's own exe and offsets in it.
fn fixture(a: std.mem.Allocator, exe: []const u8, base: usize) ![]const u8 {
    const swaps = [_]struct { []const u8, usize }{
        .{ "{DAMAGE}", @intFromPtr(&damageSite) },
        .{ "{STACK}", @intFromPtr(&stackSite) },
        .{ "{SIGHT}", @intFromPtr(&sightSite) },
        .{ "{PAY}", @intFromPtr(&paySite) },
        .{ "{ITEM}", @intFromPtr(&itemSite) },
        .{ "{FIELD}", @intFromPtr(&field_ptr) },
        .{ "{STATE}", @intFromPtr(&game_state_ptr) },
    };
    var text: []const u8 = try std.mem.replaceOwned(u8, a, table_text, "{EXE}", exe);
    for (swaps) |s| text = try std.mem.replaceOwned(u8, a, text, s[0], try std.fmt.allocPrint(a, "{X}", .{s[1] - base}));
    return text;
}

/// The Addresses list's own location text for item `i`, from its group and with its pointers.
fn locationOf(a: std.mem.Allocator, items: []const ce.records.Item, i: usize) ![]const u8 {
    const item = items[i];
    var text = item.address;
    if (text[0] == '+' or text[0] == '-') {
        var g = i;
        const base = while (g > 0) {
            g -= 1;
            if (items[g].depth < item.depth and items[g].group and items[g].address.len > 0) break g;
        } else return error.NotInGroup;
        text = try std.fmt.allocPrint(a, "({s}){s}", .{ try locationOf(a, items, base), text });
    }
    for (item.offsets) |o| text = try std.fmt.allocPrint(a, "[{s}]+{s}", .{ text, o });
    return text;
}

test "a table like kai's runs with every tweak on" {
    if (builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    field[1] = @intFromPtr(&party);
    field_ptr = @intFromPtr(&field);
    game_state_ptr = @intFromPtr(&game_state);
    const exe = std.fs.path.basename(try std.process.executablePathAlloc(io, a));
    const base = sys.module.mainBase();

    const project = try ce.import(a, testing.allocator, try fixture(a, exe, base), .{ .name = "Fixture.CT" });
    var file: []const u8 = "";
    var list: []const u8 = "";
    for (project.files) |f| {
        if (std.mem.eql(u8, f.path, "tweaks/fixture.rwt")) file = f.text;
        if (std.mem.eql(u8, f.path, ce.addresses_file)) list = f.text;
    }
    try testing.expectEqual(0, project.stats.review);
    // Each kind of thing came over as itself
    for ([_][]const u8{ "@inject ", "@patch ", "(8)\n", "  cmp dword ptr [iCantDie],1\n", "@data near ", "local memrec = getAddressList().getMemoryRecordByID(37)", "@key F5" }) |want| {
        if (std.mem.indexOf(u8, file, want) == null) {
            std.debug.print("no `{s}` in\n{s}\n", .{ want, file });
            return error.TestUnexpectedResult;
        }
    }

    // The project's address list, the way the Addresses panel names it
    var diagnostics: std.zon.parse.Diagnostics = undefined;
    const saved = try std.zon.parse.fromSlice(ce.records.Saved, .{ .gpa = a, .arena = a, .source = try a.dupeSentinel(u8, list, 0), .diagnostics = &diagnostics, .ignore_unknown_fields = true });
    var listed: usize = 0;
    defer Names.global.removeGroup(.user, "ce_import_tests");
    for (saved.items, 0..) |item, i| {
        if (item.id.len == 0) continue;
        try Names.global.put(.{ .source = .user, .group = "ce_import_tests", .name = item.id, .where = .{ .text = .{ .text = try locationOf(a, saved.items, i) } } });
        listed += 1;
    }
    try testing.expectEqual(8, listed);

    var boxes: host.tweaks.Switches = .{};
    defer boxes.deinit();
    {
        const names = [_][]const u8{
            "fixture/Activate",                    "fixture/Activate/Invisible",
            "fixture/Activate/Combat Mods",        "fixture/Activate/Set Max Items",
            "fixture/Activate/Dont Subtract Mira", "fixture/Activate/Override Item",
            "fixture/Restore EP-HP",
        };
        var now: [names.len]host.tweaks.Switches.Switch = undefined;
        for (&now, names) |*s, n| s.* = .{ .name = @constCast(n), .on = false };
        var changed: std.ArrayList(host.tweaks.Switches.Switch) = .empty;
        try boxes.update(&now, a, &changed);
    }
    host.tweaks.useSwitches(&boxes, null);
    defer host.tweaks.useSwitches(null, &boxes);

    var libraries: Owner = .init("ce_import_tests");
    defer Libraries.global.removeOwner(&libraries);
    var rig: Rig = undefined;
    try rig.init();
    defer rig.deinit();
    try Libraries.global.add(.{ .owner = &libraries, .name = ce.lua.library_name, .language = "lua", .source = ce.lua.compat_source });

    // Activate turns on what it names, through the CE layer, and the runtime runs each
    try rig.runPart(1, "fixture", file, "Activate");
    var asked = boxes.take();
    defer host.tweaks.Switches.freeAll(&asked);
    try testing.expectEqual(4, asked.items.len);
    for (asked.items) |s| {
        try testing.expect(s.on);
        try rig.runPart(1, "fixture", file, s.name["fixture/".len..]);
    }
    try rig.runPart(1, "fixture", file, "Activate/Override Item");
    try rig.runPart(1, "fixture", file, "Restore EP-HP");
    if (rig.heard.problem()) |l| {
        std.debug.print("{s}: {s}\n", .{ l.part, l.text });
        return error.TestUnexpectedResult;
    }

    // The code changes are in
    const code = struct {
        fn at(f: *const fn () callconv(.naked) void) [*]const u8 {
            return @ptrCast(f);
        }
    }.at;
    try testing.expectEqualSlices(u8, &.{ 0xC7, 0x44, 0x8B, 0x10, 0x01, 0x00, 0x00, 0x00 }, code(&sightSite)[0..8]);
    try testing.expectEqual(0xE9, code(&damageSite)[0]);
    try testing.expectEqual(0xE9, code(&stackSite)[0]);
    try testing.expectEqual(0xE9, code(&itemSite)[0]);
    try testing.expect(code(&paySite)[0] != 0x41);

    // The Lua parts ran, and the records found their addresses through the list
    try testing.expectEqual(77, game_state[4]);
    try testing.expectEqualStrings("Override Item:Item ID:3", rig.eval(1, "mixed"));
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings(try std.fmt.bufPrint(&buf, "{d}", .{@intFromPtr(&party) + 0x14}), rig.eval(1, "id_at"));
    try testing.expectEqualStrings("1234", rig.eval(1, "mira"));

    // Everything goes back when the session stops
    try rig.send(@import("wraith_api").script.topics.stop, @import("wraith_api").script.Target{ .session = 1 });
    rig.step();
    try testing.expectEqualSlices(u8, &.{ 0xC7, 0x44, 0x8B, 0x10, 0x02, 0x00, 0x00, 0x00 }, code(&sightSite)[0..8]);
    try testing.expectEqual(0x8B, code(&damageSite)[0]);
}
