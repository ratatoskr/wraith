//! Cheat Engine's Lua layer, `ce`, in workbench sessions on the runtime's own areas. Tables the
//! importer made run their Lua through it as tweaks.

const std = @import("std");
const builtin = @import("builtin");

const api = @import("wraith_api");
const core = @import("wraith_core");
const ce = @import("wraith_importer").ce;
const sys = @import("tuft_sys");
const Owner = @import("tuft_event").Owner;

const host = @import("../host/root.zig");
const Libraries = @import("../Libraries.zig");
const Names = @import("../Names.zig");
const Rig = @import("testing.zig").Rig;

const protocol = api.script;
const testing = std.testing;
const io = testing.io;

const api_md = ce.lua.api_md;

/// A Lua session with the layer installed in its globals. Mustn't move.
const Fixture = struct {
    rig: Rig = undefined,
    libraries: Owner = .init("ce_tests"),
    buf: [8192]u8 = undefined,

    /// Session 1, which is `script.1`, with `records` as the manifest and a fake tweak bridge.
    fn init(f: *Fixture, records: []const u8) !void {
        f.* = .{};
        try f.rig.init();
        errdefer f.rig.deinit();
        try Libraries.global.add(.{ .owner = &f.libraries, .name = ce.lua.library_name, .language = "lua", .source = ce.lua.compat_source });
        errdefer Libraries.global.removeOwner(&f.libraries);
        const code = try std.mem.concat(testing.allocator, u8, &.{ prelude, "handle = ce.install(_G, { name = 'Test table', tweaks = bridge, records = ", records, " })" });
        defer testing.allocator.free(code);
        try f.rig.run(1, "lua", code);
        try f.expectFine();
    }

    fn deinit(f: *Fixture) void {
        f.rig.deinit();
        Libraries.global.removeOwner(&f.libraries);
    }

    fn eval(f: *Fixture, code: []const u8) ![]const u8 {
        const live = f.rig.sessions.find(1).?.live.?;
        live.script.enter();
        defer live.script.leave();
        return switch (live.script.eval(code, &f.buf)) {
            .value => |v| v,
            .thrown => |t| {
                std.debug.print("{s}\n  threw: {s}\n", .{ code, t });
                return error.Threw;
            },
        };
    }

    fn expectEval(f: *Fixture, expected: []const u8, code: []const u8) !void {
        const got = try f.eval(code);
        if (!std.mem.eql(u8, expected, got)) {
            std.debug.print("{s}\n  wanted: {s}\n  got: {s}\n", .{ code, expected, got });
            return error.TestUnexpectedResult;
        }
    }

    fn set(f: *Fixture, name: []const u8, value: usize) !void {
        var buf: [128]u8 = undefined;
        _ = try f.eval(try std.fmt.bufPrint(&buf, "{s} = {d}", .{ name, value }));
    }

    /// Fails with what was thrown or logged as an error.
    fn expectFine(f: *Fixture) !void {
        if (f.rig.heard.problem()) |l| {
            std.debug.print("{t}: {s}\n", .{ l.kind, l.text });
            return error.TestUnexpectedResult;
        }
    }

    /// Frames go round, with time passing, so timers, scans and waits get on.
    fn frames(f: *Fixture, n: usize, ms: u64) !void {
        for (0..n) |_| {
            try io.sleep(.fromMilliseconds(@intCast(ms)), .awake);
            f.rig.step();
            host.frame.run();
        }
    }

    /// Till `done` is true in the script.
    fn settle(f: *Fixture, done: []const u8) !void {
        for (0..500) |_| {
            if (std.mem.eql(u8, try f.eval(done), "true")) return;
            try f.frames(1, 1);
        }
        return error.Timeout;
    }
};

const prelude =
    \\wraith = require("wraith")
    \\ce = require("ce")
    \\on = {}
    \\bridge = {
    \\  isOn = function(path) return on[path] == true end,
    \\  setOn = function(path, v)
    \\    if path == "broken" then error("it can't") end
    \\    on[path] = v
    \\  end,
    \\}
    \\function err(f, ...)
    \\  local ok, e = pcall(f, ...)
    \\  if ok then return "no error" end
    \\  return tostring(e)
    \\end
    \\function join(...) return table.concat({ ... }, " ") end
    \\
;

test "reads and writes like CE's" {
    var f: Fixture = undefined;
    try f.init("{}");
    defer f.deinit();
    var buf: [64]u8 align(8) = @splat(0);
    try f.set("at", @intFromPtr(&buf));

    // Unsigned unless asked
    try f.expectEval("true 4294967295 -1", "join(tostring(writeInteger(at, -1)), readInteger(at), readInteger(at, true))");
    try f.expectEval("65535 -1 255", "writeSmallInteger(at, -1) return join(readSmallInteger(at), readSmallInteger(at, true), readByte(at))");
    try f.expectEval("-2 1.5 0.25", "writeQword(at, -2) writeFloat(at + 8, 1.5) writeDouble(at + 16, 0.25) return join(readQword(at), readFloat(at + 8), readDouble(at + 16))");
    try f.expectEval("1 2 255", "writeBytes(at, 1, 2, 0x1FF) return join(readBytes(at, 3))");
    try f.expectEval("3 7 9", "writeBytes(at, { 7, 9 }) local t = readBytes(at, 3, true) return join(#t, t[1], t[2])");
    try f.expectEval("hi hi", "writeBytes(at, 0, 0, 0, 0, 0, 0) writeString(at, 'hi') writeString(at + 8, 'hi', true) return join(readString(at, 10), readString(at + 8, 10, true))");
    // No 0 after it, same as CE
    try f.expectEval("hiz", "writeString(at, 'xyz') writeString(at, 'hi') return readString(at, 10)");
    try f.expectEval("true", "writePointer(at, at) return readPointer(at) == at");
    try f.expectEval("1000 1000", "WriteInteger(at, 1000) return join(ReadInteger(at), readIntegerLocal(at))");
    try f.expectEval("nil false nil", "join(tostring(readInteger(16)), tostring(writeInteger(16, 1)), tostring(readBytes(16, 2)))");
    try f.expectEval("true", "copyMemory(at, 4, at + 32) return compareMemory(at, at + 32, 4)");
    try testing.expectEqual(0x3E8, std.mem.readInt(u32, buf[32..36], .little));
    try f.expectFine();
}

test "CE address text" {
    var f: Fixture = undefined;
    try f.init("{}");
    defer f.deinit();
    var target: u32 = 0;
    var ptr: usize = @intFromPtr(&target) - 8;
    try f.set("ptr", @intFromPtr(&ptr));

    try f.expectEval("kai.exe+0xD600A8", "ce.location('kai.exe+d600a8')");
    try f.expectEval("\"name.exe\"+0x1234", "ce.location('\"name.exe\"+1234')");
    try f.expectEval("[[GodMode]+0x10]+8", "ce.location('[[GodMode]+10]+8')");
    try f.expectEval("\"Tales of Zestiria.exe\"+0x1D3030B", "ce.location('Tales of Zestiria.exe+1D3030B')");
    try f.expectEval("0x3AA00A0 +0x297990 -8 -5 10", "join(ce.location('03AA00A0'), ce.location('+297990'), ce.location('-8'), ce.location('#-5'), ce.location('#10'))");
    try f.expectEval("7C ?? 48 8B|48 8B ?? ?? 05|0F ??", "ce.pattern('7C??488B') .. '|' .. ce.pattern('48 8b ** xx 05') .. '|' .. ce.pattern('0F 4?')");
    try f.expectEval("-16 10 nil", "join(ce.parse_number('-10'), ce.parse_number('#10'), tostring(ce.parse_number('x')))");

    // Hex unless it's `#`, against the game's own module
    try f.expectEval("true true true", "local base = getAddress(process) return join(tostring(getAddress(process .. '+10') == base + 16), tostring(getAddress(process .. '+#10') == base + 10), tostring(getAddress('10') == 16))");
    try f.expectEval("true", "registerSymbol('thing', ptr) return getAddress('[thing]+8') == readPointer(ptr) + 8");
    try f.expectEval("nil", "tostring(getAddressSafe('nothing_here'))");
    try f.expectEval("true", "err(getAddress, 'nothing_here'):find(\"CE getAddress couldn't find 'nothing_here'\", 1, true) ~= nil");
    try f.expectEval("0 true", "local was = errorOnLookupFailure(false) local v = getAddress('nothing_here') errorOnLookupFailure(was) return join(v, tostring(was))");
    try f.expectEval("true true", "join(tostring(inModule(getAddress(process) + 16)), tostring(getModuleSize(process) > 0))");
    try f.expectEval("nil", "tostring(getModuleSize('not_loaded.dll'))");
}

test "registered symbols go in the Addresses list too" {
    var f: Fixture = undefined;
    try f.init("{}");
    defer f.deinit();
    var value: u32 = 1234;
    try f.set("at", @intFromPtr(&value));

    try f.expectEval("1234 1234 thing true", "registerSymbol('thing', at) return join(readInteger('thing'), readInteger(getAddress('THING')), getNameFromAddress(at), tostring(getNameFromAddress(getAddress(process) + 16) == process .. '+10'))");
    try f.expectEval("thing 1", "local e = enumRegisteredSymbols() return join(e[1].symbolname, #e)");
    // So tweaks' asm can use it
    try f.expectEval("true", "wraith.addresses:get('script.1.thing') == at");
    try f.expectEval("nil", "unregisterSymbol('thing') return tostring(getAddressSafe('thing'))");
    try f.expectEval("false", "tostring((pcall(wraith.addresses.get, wraith.addresses, 'script.1.thing')))");
}

/// Never runs. Its bytes are something to scan for.
fn aobTarget() callconv(.naked) void {
    asm volatile (
        \\.byte 0xB8, 0xCE, 0x51, 0xCE, 0x5A, 0x90, 0xC3
    );
}

test "AOB scans" {
    var f: Fixture = undefined;
    try f.init("{}");
    defer f.deinit();
    try f.set("target", @intFromPtr(&aobTarget));

    try f.expectEval("true true", "local list = AOBScan('B8CE51CE5A90') return join(tostring(list.Count >= 1), tostring(list.indexOf(string.format('%X', target)) >= 0))");
    try f.expectEval("true", "AOBScanUnique('B8 CE 51 CE 5A 90 C3') == target");
    try f.expectEval("nil", "tostring(AOBScan('B8 CE 51 CE 5A 91 C3 13 37'))");
    try f.expectEval("1", "AOBScan(0xB8, 0xCE, 0x51, 0xCE, 0x5A, 0x90, 0xC3).Count");
    try f.expectEval("true", "local ms = createMemScan() local fl = createFoundList(ms) local base = getAddress(process) ms.firstScan(soExactValue, vtByteArray, rtRounded, 'B8 CE 51 CE 5A 90 C3', nil, base, base + getModuleSize(process), '', fsmNotAligned, '', true, false, false, false) ms.waitTillDone() fl.initialize() return getAddress(fl[0]) == target");
}

test "stringlists and byte tables" {
    var f: Fixture = undefined;
    try f.init("{}");
    defer f.deinit();
    try f.expectEval("0 1 2 b", "sl = createStringlist() return join(sl.add('a'), sl:add('b'), sl.Count, sl[1])");
    try f.expectEval("a\r\nb\r\n 1 -1", "join(sl.Text, sl.indexOf('B'), sl.indexOf('c'))");
    try f.expectEval("2 x y", "sl.Text = 'x\\ny' return join(sl.Count, sl.String[0], sl.getString(1))");
    try f.expectEval("1 y", "sl.delete(0) return join(sl.Count, sl[0])");
    try f.expectEval("a b c", "join(table.unpack(('a,b,c'):split(',')))");
    try f.expectEval("TStringList", "sl.ClassName");
    try f.expectEval("true", "err(function() return sl[5] end):find('out of bounds') ~= nil");

    try f.expectEval("68 81 52 24", "join(table.unpack(dwordToByteTable(0x18345144)))");
    try f.expectEval("255 255 255 255 255 255 255 255", "join(table.unpack(qwordToByteTable(-1)))");
    try f.expectEval("305419896 4660 -1 -1", "join(byteTableToDword({ 0x78, 0x56, 0x34, 0x12 }), byteTableToWord({ 0, 0x34, 0x12 }, false, 2), byteTableToWord({ 0xFF, 0xFF }, true), byteTableToQword(qwordToByteTable(-1)))");
    try f.expectEval("1.5 -0.125 1.5", "join(byteTableToFloat(floatToByteTable(1.5)), byteTableToDouble(doubleToByteTable(-0.125)), byteTableToExtended(extendedToByteTable(1.5)))");
    try f.expectEval("hi hé", "join(byteTableToString(stringToByteTable('hi')), byteTableToWideString(wideStringToByteTable('hé')))");
    try f.expectEval("7 6 1 -1 127", "join(bOr(3, 4), bXor(3, 5), bShr(2, 1), signExtend(0xFF, 7), signExtend(0x7F, 7))");
}

test "timers and threads run on the game's frames" {
    var f: Fixture = undefined;
    try f.init("{}");
    defer f.deinit();
    _ = try f.eval(
        \\n = 0
        \\t = createTimer(getMainForm())
        \\t.Interval = 1
        \\t.OnTimer = function(sender)
        \\  n = n + 1
        \\  if n == 3 then sender.destroy() end
        \\end
        \\createTimer(1, function(a, b) once = a + b end, 2, 3)
        \\off = createTimer(nil, false)
        \\off.OnTimer = function() never = true end
        \\off.Interval = 1
        \\createThread(function(th) sleep(1) slept = getTickCount() > 0 end)
        \\queue(function(a) queued = a end, 9)
    );
    try f.frames(8, 2);
    try f.expectEval("3 5 nil true 9", "join(n, once, tostring(never), tostring(slept), queued)");
    // A gsub callback can't yield, so sleep has nothing to wait in
    try f.expectEval("true", "local r ; ('x'):gsub('x', function() r = err(sleep, 1) end) return r:find('only works in a thread') ~= nil");
    try f.expectFine();
}

test "memory records from the manifest" {
    var f: Fixture = undefined;
    try f.init(
        \\{
        \\  { id = 0, description = "Scripts", options = "[moActivateChildrenAsWell]" },
        \\  { id = 1, parent = 0, description = "God mode", tweak = "combat/god" },
        \\  { id = 2, parent = 0, description = "Broken", tweak = "broken" },
        \\  { id = 3, description = "HP", address = "script.1.hp", type = "4 Bytes" },
        \\  { id = 4, description = "Level", address = "script.1.hp", type = "Byte", hex = true,
        \\    dropdown = { "0:Low", "1:High" } },
        \\}
    );
    defer f.deinit();
    var hp: u32 = 250;
    var buf: [128]u8 = undefined;
    _ = try f.eval(try std.fmt.bufPrint(&buf, "wraith.addresses:add({{ id = 'hp', address = '0x{x}' }})", .{@intFromPtr(&hp)}));

    try f.expectEval("5 Scripts 2 God mode", "local al = getAddressList() return join(al.Count, al[0].Description, al[0].Count, al[0].Child[0].Description)");
    try f.expectEval("false true true", "local mr = getAddressList().getMemoryRecordByDescription('God mode') local was = mr.Active mr.Active = true return join(tostring(was), tostring(mr.Active), tostring(on['combat/god']))");
    try f.expectEval("250 FA", "join(AddressList.getMemoryRecordByID(3).Value, AddressList.getMemoryRecordByID(4).Value)");
    try f.expectEval("99", "local mr = AddressList.getMemoryRecordByDescription('HP') mr.Value = '99' return mr.Value");
    try testing.expectEqual(99, hp);
    try f.expectEval("2 High 1", "local mr = AddressList.getMemoryRecordByID(4) return join(mr.DropDownList.Count, mr.DropDownDescription[1], mr.DropDownValue[1])");
    try f.expectEval("true", "AddressList.getMemoryRecordByID(3).CurrentAddress == getAddress('(script.1.hp)')");
    // OnActivate runs before and after, and before has to say yes
    try f.expectEval("true,false|false,true", "local mr = AddressList.getMemoryRecordByID(1) mr.Active = false seen = {} mr.OnActivate = function(r, before, current) seen[#seen + 1] = tostring(before) .. ',' .. tostring(current) return true end mr.Active = true return table.concat(seen, '|')");
    try f.expectEval("false", "local mr = AddressList.getMemoryRecordByID(1) mr.Active = false mr.OnActivate = function() return false end mr.Active = true return tostring(mr.Active)");
    // A failing tweak stays off with a warning, heard here rather than in the test's output
    const saved = core.log.mute(&.{.plugin});
    defer core.log.setFilter(saved);
    try f.expectEval("false", "local mr = AddressList.getMemoryRecordByID(2) mr.Active = true return tostring(mr.Active)");
    f.rig.step();
    const warned = for (f.rig.heard.lines.items) |l| {
        if (l.kind == .warn and std.mem.indexOf(u8, l.text, "couldn't turn 'Broken' on: ") != null) break true;
    } else false;
    try testing.expect(warned);
    // Freezing writes it back, till the layer stops
    _ = try f.eval("AddressList.getMemoryRecordByID(3).Active = true");
    hp = 1;
    try f.frames(3, 60);
    try testing.expectEqual(99, hp);
    _ = try f.eval("handle.stop()");
    hp = 1;
    try f.frames(3, 60);
    try testing.expectEqual(1, hp);
    try f.expectEval("1 6", "local mr = AddressList.createMemoryRecord() mr.Description = 'New' mr.appendToEntry(AddressList[0]) return join(mr.Index - AddressList[0].Index - 2, AddressList.Count)");
    try f.expectEval("CE MemoryRecord.Script isn't supported in Wraith yet", "err(function() return AddressList[0].Script end):match('CE .*')");
}

test "stubs say so, and sounds go to Wraith's" {
    var f: Fixture = undefined;
    try f.init("{}");
    defer f.deinit();
    // The stubs that can't ask warn, which isn't news here
    const saved = core.log.mute(&.{.plugin});
    defer core.log.setFilter(saved);
    try f.expectEval("CE createForm isn't supported in Wraith yet: use Wraith's ui instead", "err(createForm):match('CE .*')");
    try f.expectEval("CE debug_getContext isn't supported in Wraith yet", "err(debug_getContext, 0):match('CE .*')");
    try f.expectEval("7.5 nil -1", "join(getCEVersion(), tostring(inputQuery('a', 'b', 'c')), (showSelectionList('t', 'c', createStringlist())))");
    try f.expectEval(if (@sizeOf(usize) == 8) "true" else "false", "tostring(targetIs64Bit())");
    try f.expectEval("2 7 1", "join(messageDialog('Sure?', mtConfirmation, mbYes, mbCancel), messageDialog('Sure?', mtConfirmation, mbYes, mbNo), messageDialog('Hi'))");
    try f.expectEval("false", "tostring(syntaxcheck)");

    _ = try f.eval("beep()");
    _ = try f.eval("playSound('RIFF\\4\\0\\0\\0WAVE')");
    try f.expectEval("true", "err(playSound, {}):find('it takes a table file', 1, true) ~= nil");
    // "RIFF\x04\x00\x00\x00WAVE" in base64, split like the importer does
    _ = try f.eval("handle.files { ['Ding.wav'] = [[\nUklGRgQA\nAABXQVZF\n]] }");
    try f.expectEval("Ding.wav 12 nil", "local tf = findTableFile('ding.wav') return join(tf.Name, tf.Stream.Size, tostring(findTableFile('nope.wav')))");
    _ = try f.eval("playSound(findTableFile('ding.wav'))");
    try f.expectEval("true", "err(playSound, 'not a wav'):find('InvalidSound', 1, true) ~= nil");
    try f.expectFine();
}

test "every global API.md lists is there" {
    var f: Fixture = undefined;
    try f.init("{}");
    defer f.deinit();
    const from = std.mem.indexOf(u8, api_md, "## Catalogue").?;
    const to = std.mem.indexOf(u8, api_md, "### Classes").?;
    var lines = std.mem.splitScalar(u8, api_md[from..to], '\n');
    var checked: usize = 0;
    var buf: [256]u8 = undefined;
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "| `")) continue;
        const name = line[3 .. 3 + std.mem.indexOfScalar(u8, line[3..], '`').?];
        // Nil in CE too, unless it's a trainer
        if (std.mem.eql(u8, name, "TrainerOrigin")) continue;
        const got = try f.eval(try std.fmt.bufPrint(&buf, "tostring(rawget(_G, '{s}') ~= nil)", .{name}));
        if (!std.mem.eql(u8, got, "true")) {
            std.debug.print("missing: {s}\n", .{name});
            return error.Missing;
        }
        checked += 1;
    }
    try testing.expect(checked > 500);
}

const code_bytes = @as([40]u8, @splat(0x90)) ++ [_]u8{ 0x31, 0xC0, 0xC3 };

var watched: u32 align(8) = 0;

noinline fn poke(to: *volatile u32, v: u32) void {
    to.* = v;
}

test "value scans, disassembly, protection, keys and breakpoints" {
    var f: Fixture = undefined;
    try f.init("{}");
    defer f.deinit();
    const words = try testing.allocator.alloc(u32, 16);
    defer testing.allocator.free(words);
    @memset(words, 0);
    words[2] = 0x5EED1234;
    words[6] = 0x5EED1234;
    try f.set("buf", @intFromPtr(words.ptr));
    _ = try f.eval(
        \\task.spawn(function()
        \\  local ms = createMemScan()
        \\  ms.firstScan(soExactValue, vtDword, rtRounded, '1592594996', '', buf, buf + 64, '', fsmAligned, '4', false, true, false, false)
        \\  ms.waitTillDone()
        \\  local fl = createFoundList(ms)
        \\  fl.initialize()
        \\  first = join(fl.Count, fl.Value[0])
        \\  createThread(function(th) end).waitfor()
        \\  repeat sleep(1) until changed
        \\  ms.nextScan(soChanged)
        \\  ms.waitTillDone()
        \\  fl.initialize()
        \\  second = join(fl.Count, tonumber(fl[0], 16) - buf)
        \\  local ok, text = pcall(readFromClipboard)
        \\  clip = ok and type(text) or tostring(text)
        \\end)
    );
    try f.settle("first ~= nil");
    try f.expectEval("2 1592594996", "first");
    words[2] = 7;
    _ = try f.eval("changed = true");
    try f.settle("clip ~= nil");
    try f.expectEval("1 8", "second");
    // Whatever the clipboard holds, if it holds text
    try f.expectEval("true", "clip == 'string' or clip:find('Failed') ~= nil");

    const at = @intFromPtr(&code_bytes) + 40;
    try f.set("at", at);
    var buf: [128]u8 = undefined;
    try f.expectEval(try std.fmt.bufPrint(&buf, "{X} - 31 C0 - xor eax, eax 2 true", .{at}), "join(disassemble(at), getInstructionSize(at), tostring(getPreviousOpcode(at + 2) == at))");
    try f.expectEval("31 C0 xor eax, eax", "local _, opcode, bytes = splitDisassembledString(disassemble(at)) return join(bytes, opcode)");

    const page = try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(4096), 4096);
    defer std.heap.page_allocator.free(page);
    try f.set("page", @intFromPtr(page.ptr));
    _ = try f.eval("setMemoryProtection(page, 16, { R = true })");
    try f.expectEval("true 64", "fullAccess(page, 16) for _, r in ipairs(enumMemoryRegions()) do if r.BaseAddress <= page and page < r.BaseAddress + r.RegionSize then return join('true', r.Protect) end end return 'false'");

    // Every key CE names is one of Wraith's, and nothing's held without a game window
    try f.expectEval("ok", "for vk = 1, 255 do local ok, why = pcall(isKeyPressed, vk) if not ok then return why end end return 'ok'");
    try f.expectEval("ok", "for vk, name in pairs(ce.keys) do local button = name:match('^mouse_(.+)$') local ok, why if button then ok, why = pcall(wraith.input.buttonDown, wraith.input, button) elseif name ~= 'shift' and name ~= 'ctrl' and name ~= 'alt' then ok, why = pcall(wraith.input.keyDown, wraith.input, name) else ok = true end if not ok then return vk .. ' ' .. name .. ': ' .. tostring(why) end end return 'ok'");
    try f.expectEval("false false 0 0", "join(tostring(isKeyPressed(VK_F9)), tostring(isKeyPressed('f9')), getMousePos())");

    try f.set("target", @intFromPtr(&watched));
    try f.expectEval("true", "tostring(debug_setBreakpoint(target, 4, bptWrite, function() hit = EAX ~= nil end))");
    defer host.watches.shutdown();
    host.watches.hearOwnCode();
    poke(&watched, 1);
    host.watches.deliver();
    try f.expectEval("true true", "join(tostring(hit), tostring(debug_getBreakpointList()[1] == target))");
    try f.expectEval("true", "tostring(debug_removeBreakpoint(target))");
    _ = try f.eval("hit = nil");
    poke(&watched, 2);
    host.watches.deliver();
    try f.expectEval("nil", "tostring(hit)");
    try f.expectFine();
}

// Imported tables, run as tweaks the way the game would

/// The project's tweak boxes, so `tweaks:setOn` finds them. Mustn't move.
const Boxes = struct {
    switches: host.tweaks.Switches = .{},
    arena: std.heap.ArenaAllocator = .init(testing.allocator),

    fn init(b: *Boxes, names: []const []const u8) !void {
        b.* = .{};
        const a = b.arena.allocator();
        const now = try a.alloc(host.tweaks.Switches.Switch, names.len);
        for (now, names) |*s, n| s.* = .{ .name = try a.dupe(u8, n), .on = false };
        var changed: std.ArrayList(host.tweaks.Switches.Switch) = .empty;
        try b.switches.update(now, a, &changed);
        host.tweaks.useSwitches(&b.switches, null);
    }

    fn deinit(b: *Boxes) void {
        host.tweaks.useSwitches(null, &b.switches);
        b.switches.deinit();
        b.arena.deinit();
    }

    /// What's been switched since, as `name=on`, oldest first.
    fn asked(b: *Boxes, buf: []u8) ![]const u8 {
        var list = b.switches.take();
        defer host.tweaks.Switches.freeAll(&list);
        var w: std.Io.Writer = .fixed(buf);
        for (list.items, 0..) |s, i| try w.print("{s}{s}={}", .{ if (i > 0) " " else "", s.name, s.on });
        return w.buffered();
    }
};

fn importOne(a: std.mem.Allocator, table: []const u8, name: []const u8, path: []const u8) ![]const u8 {
    const project = try ce.import(a, testing.allocator, table, .{ .name = name });
    for (project.files) |file| if (std.mem.eql(u8, file.path, path)) return file.text;
    return error.TestUnexpectedResult;
}

/// A rig with `ce` among the libraries, for tweaks' `@use ce`.
fn startTweaks(rig: *Rig, libraries: *Owner) !void {
    try rig.init();
    errdefer rig.deinit();
    try Libraries.global.add(.{ .owner = libraries, .name = ce.lua.library_name, .language = "lua", .source = ce.lua.compat_source });
}

fn expectNoProblems(rig: *Rig) !void {
    if (rig.heard.problem()) |l| {
        std.debug.print("{s}: {s}\n", .{ l.part, l.text });
        return error.TestUnexpectedResult;
    }
}

test "an imported table's Lua tweak turns another on through the layer" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const file = try importOne(arena.allocator(),
        \\<CheatTable><CheatEntries>
        \\<CheatEntry><ID>1</ID><Description>"Turn on God"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
        \\{$lua}
        \\if syntaxcheck then return end
        \\getAddressList().getMemoryRecordByDescription("God").Active = true
        \\{$asm}
        \\[DISABLE]
        \\</AssemblerScript></CheatEntry>
        \\<CheatEntry><ID>2</ID><Description>"God"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
        \\{$lua}
        \\_G.god = getAddressList().getMemoryRecordByID(2).Description
        \\{$asm}
        \\[DISABLE]
        \\</AssemblerScript></CheatEntry>
        \\</CheatEntries></CheatTable>
    , "Small.CT", "tweaks/small.rwt");

    var boxes: Boxes = undefined;
    try boxes.init(&.{ "small/Turn on God", "small/God" });
    defer boxes.deinit();
    var libraries: Owner = .init("ce_tests");
    defer Libraries.global.removeOwner(&libraries);
    var rig: Rig = undefined;
    try startTweaks(&rig, &libraries);
    defer rig.deinit();

    // On the runtime's word, like a click
    try rig.runPart(1, "small", file, "Turn on God");
    try expectNoProblems(&rig);
    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings("small/God=true", try boxes.asked(&buf));

    // The runtime turns it on in turn
    try rig.runPart(1, "small", file, "God");
    try expectNoProblems(&rig);
    try testing.expectEqualStrings("God", rig.eval(1, "god"));
}

test "an imported table's scripts share their globals like in one CE state" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const file = try importOne(arena.allocator(),
        \\<CheatTable><CheatEntries>
        \\<CheatEntry><ID>1</ID><Description>"Setup"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
        \\{$lua}
        \\if syntaxcheck then return end
        \\playerBase = 0x1000
        \\function playerOffset(n) return playerBase + n end
        \\{$asm}
        \\[DISABLE]
        \\</AssemblerScript></CheatEntry>
        \\<CheatEntry><ID>2</ID><Description>"Use it"</Description><VariableType>Auto Assembler Script</VariableType><AssemblerScript>[ENABLE]
        \\{$lua}
        \\_G.seen = playerOffset(0x10)
        \\{$asm}
        \\[DISABLE]
        \\</AssemblerScript></CheatEntry>
        \\</CheatEntries></CheatTable>
    , "Shared.CT", "tweaks/shared.rwt");
    try testing.expect(std.mem.indexOf(u8, file, "@globals shared\n") != null);

    var boxes: Boxes = undefined;
    try boxes.init(&.{ "shared/Setup", "shared/Use it" });
    defer boxes.deinit();
    var libraries: Owner = .init("ce_tests");
    defer Libraries.global.removeOwner(&libraries);
    var rig: Rig = undefined;
    try startTweaks(&rig, &libraries);
    defer rig.deinit();

    for ([_][]const u8{ "Setup", "Use it" }) |part| try rig.runPart(1, "shared", file, part);
    try expectNoProblems(&rig);
    try testing.expectEqualStrings("4112", rig.eval(1, "seen"));
}

test {
    _ = @import("ce_import_tests.zig");
}
