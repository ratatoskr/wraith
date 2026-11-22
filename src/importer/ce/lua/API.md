# Cheat Engine Lua in Wraith

`ce.lua` is Cheat Engine's Lua API rebuilt on Wraith's. It's only for tables the CE importer brings
in, so their `{$lua}` blocks and `<LuaScript>` keep working. New code should use Wraith's API.

This file has three parts:

- how whoever runs an imported table uses the layer
- the records manifest the importer writes
- the catalogue, with every CE builtin and what it does here

## Using it

The importer embeds `ce.lua`, and the runtime registers it as the script library `ce`. An imported
table's file says `@use ce` at its top, so the Lua tweak runner calls `install` once, before any of
the table's code, and binds `ce` to the handle. It also says `@globals shared`, so a global one
script sets lands in that same top level and every other script sees it, like in CE's one Lua
state. The shared part then loads the manifest:

```rwt
@group "Tales of Arise"
@children none
@globals shared
@use ce
@lua
ce.load {
  { id = 1, description = "God mode", type = "Auto Assembler Script", tweak = "./Combat/God mode" },
}
-- the table's own Lua script
```

`@use` amounts to this, with `env` the group's shared part's own top level:

```lua
local handle = require("ce").install(env, {
  name = "Tales of Arise",       -- the group's title, shown in toasts and warnings
  path = "",                     -- the group's path in its file
  tweaks = wraith.tweaks,        -- turns tweaks on and off, below
})
```

`install(env, options)` puts CE's globals in `env` and gives back a handle. It doesn't assume it lives in
any provider and only reaches Wraith through `options.wraith`, which defaults to `require("wraith")`.

Options:

| Option | What it is |
|---|---|
| `name` | The table's name, for toasts and warnings. |
| `records` | The records manifest. Without it the address list is empty. |
| `tweaks` | The tweak bridge. Without it, `.Active` on a tweak record raises. |
| `wraith` | Wraith's API. Defaults to `require("wraith")`. |
| `publish` | `false` keeps `registerSymbol` from listing symbols with `addresses:add`. |
| `version` | What `AddressList.LoadedTableVersion` gives. |

The handle:

| Field | What it does |
|---|---|
| `load(records)` | Adds records from a manifest, after any already there. |
| `files(list)` | The table's files for `findTableFile`, by name, each one's bytes in base64. The importer writes it right after the manifest. |
| `toggled(path, on)` | Tell the layer a tweak changed some other way, like the Tweaks panel, so the records' `OnActivate` and `OnDeactivate` run. The runner calls it for every `tweaks.onSwitched`, with paths in the file as `./...`. Switches the layer made itself are skipped. |
| `stop()` | Stops the layer's timers, freezes and breakpoints. The runner calls it when the group stops. |
| `addressList` | The `AddressList` object. |
| `record(id)` | A memory record by its CE id. |
| `env` | The env it installed into. |

The module also has `location(text, swap)`, `pattern(text)` and `parse_number(text)`, which turn CE
address text, AOB strings and offsets into Wraith's.

### CE numbers

CE reads numbers in address text as hex, and `#10` as decimal. Wraith reads `10` as decimal and `0x10` as
hex. `getAddress` rewrites the text the same way the importer's `numbers.zig` does before it hands it to
`addresses:resolve`:

- `kai.exe+d600a8` becomes `kai.exe+0xD600A8`
- `[[base]+10]+8` becomes `[[base]+0x10]+8`
- `Tales of Zestiria.exe+10` becomes `"Tales of Zestiria.exe"+0x10`
- `#100` stays decimal and `$10` is hex
- registered symbols go in as their address
- a word like `dead` stays a name if Wraith knows one by it, else it's hex

## Records manifest

What the importer writes for `getAddressList()`. It's a Lua array of records in table order, each one
after its parent:

```lua
return {
  { id = 0, description = "Scripts" },
  { id = 1, parent = 0, description = "God mode", tweak = "combat/god_mode" },
  { id = 2, parent = 0, description = "XP multiplier", tweak = "xp", data = "xp.multiplier", type = "Float" },
  { id = 3, description = "HP", address = "player.hp", type = "4 Bytes", signed = true },
  { id = 4, description = "Gold", location = "[game.exe+1234]+10", offsets = { "8", "1C" }, type = "4 Bytes" },
  { id = 5, description = "Difficulty", address = "game.difficulty", type = "Byte",
    dropdown = { "0:Easy", "1:Normal", "2:Hard" } },
}
```

Each record has:

| Field | What it is |
|---|---|
| `id` | CE's record id, a number. `getMemoryRecordByID` finds it by this. |
| `parent` | The id of the record it's under, or nil at the top. It must come earlier in the list. |
| `description` | CE's description, which `getMemoryRecordByDescription` finds it by. |
| `type` | CE's variable type, like `"4 Bytes"`, `"Float"`, `"String"`, `"Array of byte"`, `"Binary"` or `"Auto Assembler Script"`. `vtDword`-style names and numbers work too. |
| `hex`, `signed` | How `.Value` shows and reads numbers. |
| `length` | Characters for strings, bytes for byte arrays, bits for binary. |
| `unicode` | Strings are UTF-16. |
| `bitstart` | First bit, for binary. |
| `options` | CE's options text, like `"[moActivateChildrenAsWell]"`. |
| `dropdown` | The dropdown list's `"value:description"` lines. |
| `dropdownLink` | The description of a record whose dropdown list this one uses, CE's DropDownLinkedMemrec. |

And what it became, one of:

| Field | It's | `.Active` | `.Value` |
|---|---|---|---|
| `tweak` | A script that became a tweak, by its path like `combat/god_mode`. | The bridge's `isOn` and `setOn`. | `<script>` |
| `data` | A `@data` field of a tweak, as location text Wraith resolves, like `xp.multiplier`. `tweak` can say whose. | Freezes it. | Read and written by `type`. |
| `address` | An entry in the Addresses list, by its id. The importer gives every record that's in the list one, and converts its address there, so the list finds it with its pointers and group. | Freezes it. | Read and written by `type`. |
| `location` | CE's own address text, with `offsets` in CE's order, last applied first, as in the `.CT`. For records the importer couldn't map, and ones a script sets. Text starting with `+` or `-` is from the record it's under, like CE. | Freezes it. | Read and written by `type`. |
| none of them | A group header. | Turns its children on too with `moActivateChildrenAsWell`. | Empty |

## Tweak bridge

The layer turns tweaks on and off through `options.tweaks`, which `@use` sets to Wraith's own
`tweaks`. Its `isOn` and `setOn` take saved ids like `kai/Combat/God mode`, or `./Combat/God mode`
in the tweak's own file, which is what the importer writes. `setOn` happens on the next frame, and
`isOn` says what was asked for until then. Anything with the same two calls works:

```lua
local bridge = {
  -- Whether the tweak at `path` is on
  isOn = function(path) return true end,
  -- Turns it on or off. Raise to say it can't, and the record stays as it was
  setOn = function(path, on) end,
}
```

`setOn` failing is logged as a warning, the same as CE leaving a script off when it fails. When the user
toggles a tweak elsewhere, the runner calls `handle.toggled(path, on)`.

## Catalogue

Every builtin global from Cheat Engine's `celua.txt`, and how far `ce.lua` takes it. Made by a script
from celua.txt, ce.lua and the 58 CE tables under `D:\Modding` (47 of them have Lua).
**Used** is how often it appears in their Lua, then in how many tables. It counts CE's capitalised
spellings too, like `ReadInteger`, and leaves out comments. Common words like `process` and `AddressList`
also count tables' own variables by that name.

Statuses:

- **implemented** works like CE's.
- **partial** works for what tables usually do with it, and raises or says so for the rest.
- **stub** raises `CE <name> isn't supported in Wraith yet`, sometimes with why.
- **stub (quiet)** gives a harmless value, for things scripts only check.
- **stub (warns)** does nothing and logs a warning once, for setup calls a main script makes before it gets going.
- **n/a** can't mean anything in Wraith. It raises like a stub.

### Totals

| | Globals | Used in the tables |
|---|---|---|
| implemented | 123 | 38 |
| partial | 40 | 20 |
| stub (quiet) | 10 | 3 |
| stub (warns) | 38 | 6 |
| stub | 204 | 13 |
| n/a | 106 | 7 |
| **all** | 521 | 87 |

CE also makes a capitalised copy of most functions, like `ReadInteger` and `ShowMessage`. The layer does
the same for every function it installs. It also adds CE's `string.split`, `startsWith` and `endsWith`,
Lua 5.1's `unpack`, and every constant from CE's `defines.lua`, like `vtDword` and `mrYes`.

### The 20 most used

| Name | Used | Status |
|---|---|---|
| `AddressList` | 1227 (5) | partial |
| `getAddress` | 595 (30) | implemented |
| `syntaxcheck` | 448 (24) | implemented |
| `AOBScan` | 345 (22) | partial |
| `readInteger` | 288 (32) | implemented |
| `getAddressSafe` | 286 (19) | implemented |
| `process` | 272 (31) | implemented |
| `writeInteger` | 211 (18) | implemented |
| `unregisterSymbol` | 195 (26) | implemented |
| `readPointer` | 187 (25) | implemented |
| `getAddressList` | 163 (33) | partial |
| `readQword` | 154 (12) | implemented |
| `qwordToByteTable` | 150 (2) | implemented |
| `registerSymbol` | 110 (26) | implemented |
| `writeBytes` | 103 (23) | implemented |
| `createTimer` | 102 (29) | implemented |
| `getModuleSize` | 88 (21) | implemented |
| `stringToByteTable` | 76 (4) | implemented |
| `dwordToByteTable` | 75 (3) | implemented |
| `readBytes` | 65 (21) | implemented |

### Memory

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `fullAccess` | `fullAccess(address,size)` | 0 (0) | implemented | `memory:protect(address, size, "read_write_execute")`, put back when the script stops |
| `setMemoryProtection` | `setMemoryProtection(address, size, {R:boolean; W: Boolean; X: Boolean})` | 0 (0) | implemented | `memory:protect`, from R, W and X |
| `copyMemory` | `copyMemory(sourceAddress: integer, size: integer, destinationAddress:integer SEMIOPTIONAL, Method:integer OPTIONAL)` | 0 (0) | partial | `memory:readBytes` and `writeBytes`, `code:alloc` without a destination. The method's ignored, it's all one process |
| `compareMemory` | `compareMemory(address1: integer; address2: integer; size: integer;  method: integer)` | 0 (0) | implemented | `memory:readBytes` |
| `readBytes` | `readBytes(address,bytecount, ReturnAsTable )` | 65 (21) | implemented | `memory:readBytes`. Several values, or a table when the third argument's true |
| `writeBytes` | `writeBytes(address, x,x,x,x,...)` | 103 (23) | implemented | `memory:writeBytes`, from a table or values |
| `readShortInteger` | `readShortInteger(address)` | 0 (0) | implemented | `memory:readU8` |
| `readByte` | `readByte(address)` | 9 (3) | implemented | `memory:readU8` |
| `readSmallInteger` | `readSmallInteger(address)` | 34 (7) | implemented | `memory:readU16`, or `readI16` when signed is true |
| `readInteger` | `readInteger(address)` | 288 (32) | implemented | `memory:readU32`, or `readI32` when signed is true |
| `readQword` | `readQword(address)` | 154 (12) | implemented | `memory:readI64` |
| `readPointer` | `readPointer(address)` | 187 (25) | implemented | `memory:readPointer` |
| `readFloat` | `readFloat(address)` | 28 (4) | implemented | `memory:readF32` |
| `readDouble` | `readDouble(address)` | 0 (0) | implemented | `memory:readF64` |
| `readString` | `readString(address, maxlength, widechar OPTIONAL)` | 11 (5) | implemented | `memory:readString`, or `readUtf16` when wide. Max 6000 if not given |
| `writeShortInteger` | `writeShortInteger(address,value)` | 0 (0) | implemented | `memory:writeU8` |
| `writeByte` | `writeByte(address, value)` | 8 (2) | implemented | `memory:writeU8` |
| `writeSmallInteger` | `writeSmallInteger(address,value)` | 43 (10) | implemented | `memory:writeU16` |
| `writeInteger` | `writeInteger(address,value)` | 211 (18) | implemented | `memory:writeU32`, negatives wrap |
| `writeQword` | `writeQword(address, value)` | 43 (11) | implemented | `memory:writeI64` |
| `writePointer` | `writePointer(address,value)` | 31 (9) | implemented | `memory:writeI64`, or `writeU32` in 32-bit games |
| `writeFloat` | `writeFloat(address,value)` | 35 (6) | implemented | `memory:writeF32` |
| `writeDouble` | `writeDouble(address,value)` | 0 (0) | implemented | `memory:writeF64` |
| `writeString` | `writeString(address,text, widechar OPTIONAL)` | 0 (0) | implemented | `memory:writeBytes`, UTF-16 when wide. No 0 after it, same as CE |
| `readBytesLocal` | `readBytesLocal(address,bytecount, ReturnAsTable)` | 0 (0) | implemented | Same as readBytes, since Wraith runs in the game |
| `readSmallIntegerLocal` | `readSmallIntegerLocal(address)` | 0 (0) | implemented | Same as readSmallInteger, since Wraith runs in the game |
| `readIntegerLocal` | `readIntegerLocal(address)` | 0 (0) | implemented | Same as readInteger, since Wraith runs in the game |
| `readQwordLocal` | `readQwordLocal(address)` | 0 (0) | implemented | Same as readQword, since Wraith runs in the game |
| `readPointerLocal` | `readPointerLocal(address)` | 0 (0) | implemented | Same as readPointer, since Wraith runs in the game |
| `readFloatLocal` | `readFloatLocal(address)` | 0 (0) | implemented | Same as readFloat, since Wraith runs in the game |
| `readDoubleLocal` | `readDoubleLocal(address)` | 0 (0) | implemented | Same as readDouble, since Wraith runs in the game |
| `readStringLocal` | `readStringLocal(address, maxlength, widechar OPTIONAL)` | 2 (2) | implemented | Same as readString, since Wraith runs in the game |
| `writeSmallIntegerLocal` | `writeSmallIntegerLocal(address,value)` | 0 (0) | implemented | Same as writeSmallInteger, since Wraith runs in the game |
| `writeIntegerLocal` | `writeIntegerLocal(address,value)` | 0 (0) | implemented | Same as writeInteger, since Wraith runs in the game |
| `writeQwordLocal` | `writeQwordLocal(address,value)` | 0 (0) | implemented | Same as writeQword, since Wraith runs in the game |
| `writePointerLocal` | `writePointerLocal(address,value)` | 0 (0) | implemented | Same as writePointer, since Wraith runs in the game |
| `writeFloatLocal` | `writeFloatLocal(address,value)` | 0 (0) | implemented | Same as writeFloat, since Wraith runs in the game |
| `writeDoubleLocal` | `writeDoubleLocal(address,value)` | 0 (0) | implemented | Same as writeDouble, since Wraith runs in the game |
| `writeStringLocal` | `writeStringLocal(address,string, widechar OPTIONAL)` | 0 (0) | implemented | Same as writeString, since Wraith runs in the game |
| `writeBytesLocal` | `writeBytesLocal(address, x,x,x,x,...)` | 0 (0) | implemented | Same as writeBytes, since Wraith runs in the game |
| `enumMemoryRegions` | `enumMemoryRegions()` | 0 (0) | partial | `memory:regions("", true)`. Only committed memory, and AllocationBase is each region's own start |
| `writeRegionToFile` | `writeRegionToFile(filename, sourceaddress,size)` | 0 (0) | stub | No Wraith API for this yet |
| `readRegionFromFile` | `readRegionFromFile(filename, destinationaddress)` | 0 (0) | stub | No Wraith API for this yet |
| `md5memory` | `md5memory(address, size)` | 0 (0) | stub | No Wraith API for this yet |
| `integerToUserData` | `integerToUserData(int)` | 0 (0) | stub | No Wraith API for this yet |
| `userDataToInteger` | `userDataToInteger(UserDataVar)` | 0 (0) | stub | No Wraith API for this yet |
| `allocateMemory` | `allocateMemory(size, BaseAddress OPTIONAL, Protection OPTIONAL)` | 3 (3) | partial | `code:alloc(size, near)`. Protection's ignored, it's always read, write and execute |
| `deAlloc` | `deAlloc(address, size OPTIONAL)` | 0 (0) | implemented | `code:free` |
| `allocateSharedMemory` | `allocateSharedMemory(name, size)` | 0 (0) | stub | No Wraith API for this yet |
| `allocateSharedMemoryLocal` | `allocateSharedMemoryLocal(name, size)` | 0 (0) | stub | No Wraith API for this yet |
| `createSection` | `createSection(size)` | 0 (0) | stub | No Wraith API for this yet |
| `mapViewOfSection` | `mapViewOfSection(section, preferedBaseAddress OPTIONAL)` | 0 (0) | stub | No Wraith API for this yet |
| `unMapViewOfSection` | `unMapViewOfSection(baseaddress)` | 0 (0) | stub | No Wraith API for this yet |
| `createMemoryStream` | `createMemoryStream()` | 0 (0) | stub | No Wraith API for this yet |

### Byte tables and bits

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `signExtend` | `signExtend(value,mostSignificantBit)` | 0 (0) | implemented | Lua's integer operators |
| `wordToByteTable` | `wordToByteTable(number)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `dwordToByteTable` | `dwordToByteTable(number)` | 75 (3) | implemented | `string.pack` and `string.unpack` |
| `qwordToByteTable` | `qwordToByteTable(number)` | 150 (2) | implemented | `string.pack` and `string.unpack` |
| `floatToByteTable` | `floatToByteTable(number)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `doubleToByteTable` | `doubleToByteTable(number)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `extendedToByteTable` | `extendedToByteTable(number)` | 0 (0) | implemented | Lua, by hand, since `string.pack` has no 80-bit floats |
| `stringToByteTable` | `stringToByteTable(string)` | 76 (4) | implemented | `string.pack` and `string.unpack` |
| `wideStringToByteTable` | `wideStringToByteTable(string)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `byteTableToWord` | `byteTableToWord(table, OPTIONAL signed:boolean, OPTIONAL tableindex=1)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `byteTableToDword` | `byteTableToDword(table, OPTIONAL signed:boolean, OPTIONAL tableindex=1)` | 1 (1) | implemented | `string.pack` and `string.unpack` |
| `byteTableToQword` | `byteTableToQword(table, OPTIONAL tableindex=1)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `byteTableToFloat` | `byteTableToFloat(table, OPTIONAL tableindex=1)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `byteTableToDouble` | `byteTableToDouble(table, OPTIONAL tableindex=1)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `byteTableToExtended` | `byteTableToExtended(table, OPTIONAL tableindex=1)` | 0 (0) | implemented | Lua, by hand, to the nearest double |
| `byteTableToString` | `byteTableToString(table, OPTIONAL tableindex=1)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `byteTableToWideString` | `byteTableToWideString(table, OPTIONAL tableindex=1)` | 0 (0) | implemented | `string.pack` and `string.unpack` |
| `bOr` | `bOr(int1, int2)` | 21 (3) | implemented | Lua's integer operators |
| `bXor` | `bXor(int1, int2)` | 0 (0) | implemented | Lua's integer operators |
| `bAnd` | `bAnd(int1, int2)` | 0 (0) | implemented | Lua's integer operators |
| `bShl` | `bShl(int, int2)` | 0 (0) | implemented | Lua's integer operators |
| `bShr` | `bShr(int, int2)` | 0 (0) | implemented | Lua's integer operators |
| `bNot` | `bNot(int)` | 0 (0) | implemented | Lua's integer operators |

### Symbols and addresses

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `enumModules` | `enumModules(processid OPTIONAL)` | 2 (2) | stub | No Wraith API for this yet |
| `enableWindowsSymbols` | `enableWindowsSymbols()` | 0 (0) | implemented | Does nothing |
| `getAddress` | `getAddress(string, local OPTIONAL)` | 595 (30) | implemented | `addresses:resolve`, after turning CE's hex numbers into Wraith's and registered symbols into their addresses |
| `enableKernelSymbols` | `enableKernelSymbols()` | 0 (0) | implemented | Does nothing |
| `getAddressSafe` | `getAddressSafe(string, local OPTIONAL, shallow OPTIONAL)` | 286 (19) | implemented | Same as getAddress, nil when it's not found |
| `getSymbolInfo` | `getSymbolInfo(symbolname)` | 0 (0) | partial | Registered symbols and modules only |
| `getModuleSize` | `getModuleSize(modulename)` | 88 (21) | implemented | `memory:module(name).size`, nil when it's not loaded |
| `reinitializeSymbolhandler` | `reinitializeSymbolhandler(waittilldone: BOOLEAN OPTIONAL, default=TRUE)` | 0 (0) | implemented | Does nothing, Wraith's names are always current |
| `reinitializeDotNetSymbolhandler` | `reinitializeDotNetSymbolhandler(modulename OPTIONAL)` | 0 (0) | implemented | Does nothing |
| `reinitializeSelfSymbolhandler` | `reinitializeSelfSymbolhandler(waittilldone: BOOLEAN OPTIONAL, default=TRUE)` | 0 (0) | implemented | Does nothing |
| `waitForSections` | `waitForSections()` | 2 (2) | implemented | Does nothing, nothing to wait for |
| `waitForExports` | `waitForExports()` | 0 (0) | implemented | Does nothing |
| `waitForDotNet` | `waitForDotNet()` | 0 (0) | implemented | Does nothing |
| `waitForPDB` | `waitForPDB()` | 1 (1) | implemented | Does nothing |
| `errorOnLookupFailure` | `errorOnLookupFailure(state)` | 9 (2) | implemented | Makes getAddress give 0 instead of raising |
| `waitforsymbols` | `waitforsymbols(state)` | 0 (0) | implemented | Does nothing |
| `registerSymbolLookupCallback` | `registerSymbolLookupCallback(function(string)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterSymbolLookupCallback` | `unregisterSymbolLookupCallback(ID)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `registerAddressLookupCallback` | `registerAddressLookupCallback(function(integer)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterAddressLookupCallback` | `unregisterAddressLookupCallback(ID)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `registerSymbol` | `registerSymbol(symbolname, address, OPTIONAL donotsave)` | 110 (26) | implemented | Kept by the layer for its lookups, and listed with `addresses:add` so tweaks' asm can use it |
| `unregisterSymbol` | `unregisterSymbol(symbolname)` | 195 (26) | implemented | Drops it, and `addresses:remove` |
| `enumRegisteredSymbols` | `enumRegisteredSymbols()` | 0 (0) | implemented | The layer's own list |
| `deleteAllRegisteredSymbols` | `deleteAllRegisteredSymbols()` | 0 (0) | implemented | The layer's own list |
| `getNameFromAddress` | `getNameFromAddress(address,ModuleNames OPTIONAL=true, Symbols OPTIONAL=true, Sections OPTIONAL=false)` | 26 (14) | partial | Registered symbols, then `memory:containing` for module+offset, else hex. No debug symbols |
| `inModule` | `inModule(address)` | 0 (0) | implemented | `memory:containing` |
| `inSystemModule` | `inSystemModule(address)` | 0 (0) | partial | `memory:containing`, checked against a list of usual Windows DLLs |
| `getCommonModuleList` | `getCommonModuleList()` | 0 (0) | stub | No Wraith API for this yet |

### Scanning

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `getUniqueAOB` | `getUniqueAOB(address)` | 0 (0) | stub | Not mapped yet. `memory:scan` does value scans |
| `AOBScan` | `AOBScan(x,x,x,x,...)` | 345 (22) | partial | `Module:scanAll` on the game's module only, not all memory. Protection flags are ignored. Gives a stringlist of hex addresses or nil |
| `AOBScanUnique` | `AOBScanUnique(aobstring, OPTIONAL protectionflags, OPTIONAL alignmenttype, OPTIONAL alignmentparam)` | 0 (0) | partial | `Module:scanAll` on the game's module only |
| `AOBScanModuleUnique` | `AOBScanModuleUnique(modulename, aobstring, OPTIONAL protectionflags, OPTIONAL alignmenttype, OPTIONAL alignmentparam)` | 0 (0) | implemented | `memory:findAll(name, ...)`. Protection flags are ignored |
| `getCurrentMemscan` | `getCurrentMemscan()` | 0 (0) | stub | Not mapped yet. `memory:scan` does value scans |
| `createMemScan` | `createMemScan(progressbar OPTIONAL)` | 46 (22) | partial | `memory:scan` for exact first scans of numbers and strings, then `next` for exact, between, bigger, smaller, increased, decreased, changed and unchanged. Array of byte scans use `Module:scanAll` in one module. Unknown first scans and compares by an amount raise |
| `createFoundList` | `createFoundList(memscan)` | 46 (22) | partial | Count, Address[i], Value[i] and [i] over a MemScan's results |

### Process and target

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `process` | `process` | 272 (31) | implemented | `memory:main().name` |
| `getProcesslist` | `getProcesslist(Strings)` | 1 (1) | n/a | Wraith runs inside the game, there's no other process |
| `getHandleList` | `getHandleList(filter OPTIONAL)` | 0 (0) | n/a | Wraith runs inside the game, there's no other process |
| `closeRemoteHandle` | `closeRemoteHandle(handle, processid OPTIONAL)` | 0 (0) | n/a | Wraith runs inside the game, there's no other process |
| `duplicateHandle` | `duplicateHandle(handle)` | 0 (0) | n/a | Wraith runs inside the game, there's no other process |
| `getOpenedProcessID` | `getOpenedProcessID()` | 4 (4) | partial | Always 1, Wraith's API has no process id. Never 0, so scripts see a process |
| `getOpenedProcessHandle` | `getOpenedProcessHandle()` | 0 (0) | n/a | Wraith runs inside the game, there's no other process |
| `getProcessIDFromProcessName` | `getProcessIDFromProcessName(name)` | 15 (15) | partial | 1 for the game's name, nil for others |
| `openProcess` | `openProcess(processid)` | 26 (22) | partial | True for the game's own name or any pid, raises for anything else |
| `openFileAsProcess` | `openFileAsProcess(filename,is64bit OPTIONAL,startaddress OPTIONAL)` | 0 (0) | n/a | Wraith runs inside the game, there's no other process |
| `getOpenedFileSize` | `getOpenedFileSize()` | 0 (0) | n/a | Wraith runs inside the game, there's no other process |
| `saveOpenedFile` | `saveOpenedFile(filename OPTIONAL)` | 0 (0) | n/a | Wraith runs inside the game, there's no other process |
| `setPointerSize` | `setPointerSize(size)` | 0 (0) | n/a | Wraith runs inside the game, there's no other process |
| `getPointerSize` | `getPointerSize()` | 0 (0) | implemented | 8 or 4 |
| `pause` | `pause()` | 12 (12) | n/a | Wraith runs inside the game and can't pause it |
| `unpause` | `unpause()` | 12 (12) | n/a | Wraith runs inside the game and can't pause it |
| `getAutoAttachList` | `getAutoAttachList()` | 0 (0) | stub (quiet) | An empty stringlist |
| `cheatEngineIs64Bit` | `cheatEngineIs64Bit()` | 0 (0) | implemented | Same as targetIs64Bit |
| `targetIs64Bit` | `targetIs64Bit()` | 0 (0) | implemented | The pointer size, since Wraith runs inside the game |
| `targetIsX86` | `targetIsX86()` | 0 (0) | implemented | Always true |
| `targetIsArm` | `targetIsArm()` | 0 (0) | implemented | Always false |
| `targetIsAndroid` | `targetIsAndroid()` | 0 (0) | implemented | Always false |
| `targetIsRosetta` | `targetIsRosetta()` | 0 (0) | implemented | Always false |
| `getABI` | `getABI()` | 0 (0) | implemented | Always 0, Windows |
| `getCheatEngineProcessID` | `getCheatEngineProcessID()` | 0 (0) | n/a | Wraith runs inside the game, there's no other process |

### Assembler and code

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `generateAPIHookScript` | `generateAPIHookScript(address:string, addresstojumpto:string, addresstogetnewcalladdress:string OPT, ext:string OPT, targetself:boolean OPT)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `assemble` | `assemble(line, address OPTIONAL, assemblePreference OPTIONAL, skipRangeCheck OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `autoAssemble` | `autoAssemble(text, targetself OPTIONAL, disableInfo OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `autoAssembleCheck` | `autoAssembleCheck(text, enable, targetself)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `compile` | `compile(text, address OPTIONAL, targetself OPTIONAL, kernelmode OPTIONAL, nodebug OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `compileFiles` | `compileFiles({filelist}, address OPTIONAL, targetself OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `compileTCCLib` | `compileTCCLib()` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `addCIncludePath` | `addCIncludePath(path)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `removeCIncludePath` | `removeCIncludePath(path)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `compileCS` | `compileCS(text, {references}, coreAssembly OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `dotNetExecuteClassMethod` | `dotNetExecuteClassMethod(pathtodll, namespace, classname, methodname, parameters: string)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `registerAutoAssemblerCommand` | `registerAutoAssemblerCommand(command, function(parameters, syntaxcheckonly)` | 2 (2) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterAutoAssemblerCommand` | `unregisterAutoAssemblerCommand(command)` | 2 (2) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `registerAssembler` | `registerAssembler(function(address, instruction)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterAssembler` | `unregisterAssembler(ID)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `registerAutoAssemblerPrologue` | `registerAutoAssemblerPrologue(function(script, syntaxcheck)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterAutoAssemblerPrologue` | `unregisterAutoAssemblerPrologue(ID)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `registerAutoAssemblerTemplate` | `registerAutoAssemblerTemplate(name, function(script: TStrings; sender: TFrmAutoInject)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterAutoAssemblerTemplate` | `unregisterAutoAssemblerTemplate(ID)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `generateCodeInjectionScript` | `generateCodeInjectionScript(script: Tstrings, address: string, farjmp: boolean)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `generateAOBInjectionScript` | `generateAOBInjectionScript(script: Tstrings, symbolname: string, address: string, commentradius(default 10)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `generateFullInjectionScript` | `generateFullInjectionScript(script: Tstrings, address: string, commentradius(default 10)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `getNextAllocNumber` | `getNextAllocNumber(script: TStrings)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `addSnapshotAsComment` | `addSnapshotAsComment(script: TStrings, address: integer, radius(Default 10)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `setAssemblerMode` | `setAssemblerMode(int)` | 0 (0) | n/a | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `injectDLL` | `injectDLL(filename, skipsymbolreloadwait OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `injectLibrary` | `injectLibrary(filepath, skipsymbolreloadwait OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `injectDotNetDLL` | `injectDotNetDLL(dllpath, FullClassName, MethodName,parameterstring, timeout optional)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `executeCode` | `executeCode(address, parameter OPTIONAL, timeout OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `executeCodeLocal` | `executeCodeLocal(addres, parameter OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `executeCodeEx` | `executeCodeEx(callmethod, timeout, address, {type=x,value=param1} or param1,{type=x,value=param2} or param2,...)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `executeMethod` | `executeMethod(callmethod, timeout, address, {regnr=0..15,classinstance=xxxxxxxx} or classinstance, {type=x,value=param1} or param1, {type=x,value=param2} or param2,...)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `executeCodeLocalEx` | `executeCodeLocalEx(address, {type=x,value=param1} or param1,{type=x,value=param2} or param2,...)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `disassemble` | `disassemble(address)` | 0 (0) | partial | `code:disassemble`, as `address - bytes - code`. The code's in Wraith's Intel spelling, like `mov eax, dword ptr [rbp-0x4]` |
| `splitDisassembledString` | `splitDisassembledString(disassembledstring)` | 0 (0) | implemented | Splits what disassemble gives |
| `getPreviousOpcode` | `getPreviousOpcode(address)` | 0 (0) | partial | `code:disassemble` from up to 32 bytes back, keeping the start most of them agree on |
| `disassembleBytes` | `disassembleBytes(hexadecimalbytestring or {bytetable},address OPTIONAL)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `createAutoAssemblerForm` | `createAutoAssemblerForm(script: string OPTIONAL)` | 0 (0) | n/a | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `createDisassembler` | `createDisassembler()` | 2 (2) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `getDefaultDisassembler` | `getDefaultDisassembler()` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `getVisibleDisassembler` | `getVisibleDisassembler()` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `registerGlobalDisassembleOverride` | `registerGlobalDisassembleOverride(function(sender: Disassembler, address: integer, LastDisassembleData: Table)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterGlobalDisassembleOverride` | `unregisterGlobalDisassembleOverride(id)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `createExecuteMethodStub` | `createExecuteMethodStub(callmethod, address, classregisternr, {type=typenr},typenr,{type=5, size=y, isOutputOnly=true/false, isInputOnly=true/false }, ....)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `createExecuteCodeExStub` | `createExecuteCodeExStub(callmethod, address, {type=typenr},typenr,{type=5, size=y, isOutputOnly=true/false, isInputOnly=true/false }, ....)` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |
| `createRemoteExecutor` | `createRemoteExecutor()` | 0 (0) | stub | CE's assembler and its directives, the importer converts AA scripts ahead of time instead. Use `code:patch`, `code:inject` and `salamander.native` |

### Memory records and the address list

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `AddressList` | `AddressList` | 1227 (5) | partial | Same as getAddressList() |
| `getAddressList` | `getAddressList()` | 163 (33) | partial | The records manifest, see below |
| `getFreezeTimer` | `getFreezeTimer()` | 0 (0) | partial | A timer that does nothing, CE's own isn't there |
| `getUpdateTimer` | `getUpdateTimer()` | 2 (2) | partial | A timer that does nothing, CE's own isn't there |

### Timers and threads

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `sleep` | `sleep(milliseconds)` | 25 (12) | partial | `frame:next():await()` till `frame:now()` passes it. Only in a thread, timer or main script, since it can't stop the game |
| `getThreadlist` | `getThreadlist(List)` | 0 (0) | stub | Everything runs on the game's frame, there's one thread |
| `getTickCount` | `getTickCount()` | 0 (0) | partial | `frame:now()`, so it counts from the script's start, not Windows' |
| `processMessages` | `processMessages()` | 0 (0) | implemented | Does nothing |
| `inMainThread` | `inMainThread()` | 0 (0) | implemented | Always true, everything runs on the game's frame |
| `synchronize` | `synchronize(function(...)` | 40 (2) | implemented | Calls it right away, it's already on the main thread |
| `queue` | `queue(function(...)` | 0 (0) | implemented | `frame:onFrame` |
| `checkSynchronize` | `checkSynchronize(timeout OPTIONAL)` | 0 (0) | implemented | Does nothing |
| `createTimer` | `createTimer(delay, function(...)` | 102 (29) | implemented | Checked each frame with `frame:onFrame` and `frame:now()`, re-armed when Interval, Enabled or OnTimer change. Each tick runs in a task, so it can sleep |
| `createThread` | `createThread(function(Thread,...)` | 1 (1) | partial | `task.spawn`. Runs on the game's frame, so it has to sleep to let the game go on |
| `createThreadSuspended` | `createThreadSuspended(function(Thread,...)` | 0 (0) | partial | Same as createThread, started by resume() |
| `createThreadNewState` | `createThreadNewState(scripttext)` | 0 (0) | stub | Everything runs on the game's frame, there's one thread |
| `createCriticalSection` | `createCriticalSection()` | 0 (0) | implemented | Locks that do nothing, there's one thread |
| `createEvent` | `createEvent(ManualReset, InitialState)` | 0 (0) | stub | Everything runs on the game's frame, there's one thread |
| `createSemaphore` | `createSemaphore(count)` | 0 (0) | stub | Everything runs on the game's frame, there's one thread |
| `createMultiReadExclusiveWriteSynchronizer` | `createMultiReadExclusiveWriteSynchronizer()` | 0 (0) | stub | Everything runs on the game's frame, there's one thread |
| `getHotkeyHandlerThread` | `getHotkeyHandlerThread()` | 2 (1) | stub | Everything runs on the game's frame, there's one thread |
| `createRemoteThread` | `createRemoteThread(address, parameter)` | 0 (0) | stub | Everything runs on the game's frame, there's one thread |

### Messages and dialogs

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `showMessage` | `showMessage(text)` | 26 (19) | partial | `log:info` and `ui:toast`, doesn't wait |
| `inputQuery` | `inputQuery(caption, prompt, initialstring)` | 36 (13) | partial | Acts as if cancelled and gives nil, with a warning |
| `showSelectionList` | `showSelectionList(title, caption, stringlist, allowCustomInput OPTIONAL, formname OPTIONAL)` | 38 (14) | partial | Acts as if cancelled and gives -1, with a warning |
| `messageDialog` | `messageDialog(text, type, buttons...)` | 20 (9) | partial | `log:info` and `ui:toast`. Answers cancel, then no, then OK, whichever it offers, since nobody can click |
| `outputDebugString` | `outputDebugString(text)` | 0 (0) | implemented | `log:debug` |
| `beep` | `beep()` | 24 (2) | implemented | `sound:playSystem("default")`, Windows' default sound, if the user has Sounds on |
| `playSound` | `playSound(stream, waittilldone OPTIONAL)` | 0 (0) | partial | `sound:play`, for a table file, its stream or a WAV file's bytes in a string. Doesn't wait |
| `speak` | `speak(text, waittilldone OPTIONAL)` | 0 (0) | stub | No speech API |
| `speakEnglish` | `speakEnglish(text, waittilldone OPTIONAL)` | 0 (0) | stub | No speech API |
| `printf` | `printf(...)` | 3 (2) | implemented | `log:info(string.format(...))` |

### Strings, files and translation

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `getTranslationFolder` | `getTranslationFolder()` | 0 (0) | implemented | Always empty |
| `loadPOFile` | `loadPOFile(path)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `translate` | `translate(string)` | 0 (0) | implemented | Gives it back, there's no translation |
| `translateID` | `translateID(translationid: string, originalstring: string OPTIONAL)` | 0 (0) | implemented | Gives the original back |
| `convertToUTF8` | `convertToUTF8(string/bytetable, originalcodepagenumber)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `ansiToUTF8` | `ansiToUTF8(string)` | 0 (0) | partial | Gives it back, Wraith's strings are UTF-8 |
| `UTF8ToAnsi` | `UTF8ToAnsi(string)` | 0 (0) | partial | Gives it back |
| `md5file` | `md5file(pathtofile)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `getFileVersion` | `getFileVersion(pathtofile)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `getFileList` | `getFileList(Path:string, searchMask:string OPTIONAL, SearchSubDirs: boolean OPTIONAL, DirAttrib: integer OPTIONAL)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `getDirectoryList` | `getDirectoryList(Path:string, SearchSubDirs: boolean OPTIONAL)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `extractFileName` | `extractFileName(filepath)` | 0 (0) | implemented | Lua |
| `extractFileExt` | `extractFileExt(filepath)` | 0 (0) | implemented | Lua |
| `extractFileNameWithoutExt` | `extractFileNameWithoutExt(filepath)` | 0 (0) | implemented | Lua |
| `extractFilePath` | `extractFilePath(filepath)` | 0 (0) | implemented | Lua |
| `getTempFolder` | `getTempFolder()` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `fileExists` | `fileExists(pathtofile)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `deleteFile` | `deleteFile(pathtofile)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `stringToMD5String` | `stringToMD5String(string)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `createStringlist` | `createStringlist()` | 61 (18) | implemented | Lua |
| `createStringList` | `createStringList()` | 41 (16) | implemented | Lua, CE's other spelling |
| `createFileStream` | `createFileStream(filename, mode)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `createStringStream` | `createStringStream(string)` | 2 (2) | stub | Scripts have no file access, use `vfs` or `config` |
| `findTableFile` | `findTableFile(filename)` | 8 (4) | implemented | The importer puts the table's files in its tweak file, up to 4 MB each. Gives a `TableFile`, or nil |
| `createTableFile` | `createTableFile(filename, filepath OPTIONAL)` | 2 (2) | stub | Scripts have no file access, use `vfs` or `config` |
| `createXMLDocument` | `createXMLDocument()` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `createXMLDocumentFromFile` | `createXMLDocumentFromFile(filename)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |
| `createXMLDocumentFromStream` | `createXMLDocumentFromStream(stream)` | 0 (0) | stub | Scripts have no file access, use `vfs` or `config` |

### Lua engine and CE itself

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `TrainerOrigin` | `TrainerOrigin` | 0 (0) | stub (quiet) | nil |
| `syntaxcheck` | `syntaxcheck` | 448 (24) | implemented | false, scripts only run for real |
| `getCEVersion` | `getCEVersion()` | 11 (9) | stub (quiet) | 7.5 |
| `getCheatEngineFileVersion` | `getCheatEngineFileVersion()` | 0 (0) | stub (quiet) | 7.5.0.0 |
| `getOperatingSystem` | `getOperatingSystem()` | 0 (0) | implemented | Always 0, Windows |
| `activateProtection` | `activateProtection()` | 0 (0) | stub (quiet) | Does nothing |
| `enableDRM` | `enableDRM(altitude OPTIONAL, secondaryprocessid OPTIONAL )` | 0 (0) | stub (quiet) | Does nothing |
| `loadTable` | `loadTable(filename, merge OPTIONAL)` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `saveTable` | `saveTable(filename, protect OPTIONAL, dontDeactivateDesignerForms OPTIONAL)` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `signTable` | `signTable(filename)` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `resetLuaState` | `resetLuaState()` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `getGlobalVariable` | `getGlobalVariable(string)` | 0 (0) | partial | Reads the same env, there's one state |
| `setGlobalVariable` | `setGlobalVariable(string, something)` | 0 (0) | partial | Sets the same env |
| `createRef` | `createRef(...)` | 0 (0) | implemented | Lua |
| `getRef` | `getRef(integer)` | 0 (0) | implemented | Lua |
| `destroyRef` | `destroyRef(integer)` | 0 (0) | implemented | Lua |
| `encodeFunction` | `encodeFunction(function)` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `decodeFunction` | `decodeFunction(string)` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `encodeFunctionEx` | `encodeFunctionEx(string,pathtodll OPTIONAL)` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `registerEXETrainerFeature` | `registerEXETrainerFeature(FeatureName:String, function()` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterEXETrainerFeature` | `unregisterEXETrainerFeature(id)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `gc_setPassive` | `gc_setPassive(state: boolean)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `gc_setActive` | `gc_setActive(state: boolean, interval: integer, minsize: integer)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `loadPlugin` | `loadPlugin(dllnameorpath)` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `onAutoGuess` | `onAutoGuess(function)` | 0 (0) | stub (quiet) | Does nothing |
| `closeCE` | `closeCE()` | 4 (2) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `getCheatEngineDir` | `getCheatEngineDir()` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `getAutorunPath` | `getAutorunPath()` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `registerBinUtil` | `registerBinUtil(config)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `getLuaEngine` | `getLuaEngine()` | 5 (4) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `createLuaEngine` | `createLuaEngine()` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `supportCheatEngine` | `supportCheatEngine(attachwindow, hasclosebutton, width, height, position ,yoururl OPTIONAL, extraparameters OPTIONAL, percentageshown OPTIONAL)` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `fuckCheatEngine` | `fuckCheatEngine()` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |
| `openLuaServer` | `openLuaServer(Name)` | 0 (0) | n/a | CE's own state, tables and files, which Wraith doesn't have |

### Forms and GUI

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `MainForm` | `MainForm` | 17 (4) | partial | Same as getMainForm() |
| `darkMode` | `darkMode()` | 0 (0) | stub (quiet) | false |
| `registerLuaFunctionHighlight` | `registerLuaFunctionHighlight(functionname)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterLuaFunctionHighlight` | `unregisterLuaFunctionHighlight(functionname)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `getScreenCanvas` | `getScreenCanvas()` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `loadFontFromStream` | `loadFontFromStream(memorystream)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `unloadLoadedFont` | `unloadLoadedFont(id)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `hideAllCEWindows` | `hideAllCEWindows()` | 0 (0) | n/a | No CE windows. Use Wraith's `ui` |
| `unhideMainCEwindow` | `unhideMainCEwindow()` | 0 (0) | n/a | No CE windows. Use Wraith's `ui` |
| `setProgressState` | `setProgressState(state)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `setProgressValue` | `setProgressValue(current, max)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `getFormCount` | `getFormCount()` | 2 (2) | stub (quiet) | 0 |
| `getForm` | `getForm(index)` | 2 (2) | n/a | No CE windows. Use Wraith's `ui` |
| `registerFormAddNotification` | `registerFormAddNotification(function(form)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterFormAddNotification` | `unregisterFormAddNotification(Object)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `getSettingsForm` | `getSettingsForm()` | 0 (0) | n/a | No CE windows. Use Wraith's `ui` |
| `getMemoryViewForm` | `getMemoryViewForm()` | 12 (12) | n/a | No CE windows. Use Wraith's `ui` |
| `getMainForm` | `getMainForm()` | 58 (22) | partial | A stand-in to pass as a timer's owner. Anything on it raises |
| `getApplication` | `getApplication()` | 0 (0) | n/a | No CE windows. Use Wraith's `ui` |
| `getPropertyList` | `getPropertyList(class)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `setProperty` | `setProperty(class, propertyname, propertyvalue)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `getProperty` | `getProperty(class, propertyname)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `setMethodProperty` | `setMethodProperty(class, propertyname, function)` | 1 (1) | stub | No CE windows. Use Wraith's `ui` |
| `getMethodProperty` | `getMethodProperty(Class, propertyname)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `inheritsFromObject` | `inheritsFromObject(object)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `inheritsFromComponent` | `inheritsFromComponent(object)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `inheritsFromControl` | `inheritsFromControl(object)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `inheritsFromWinControl` | `inheritsFromWinControl(object)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createClass` | `createClass(classname)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createComponentClass` | `createComponentClass(classname, owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createRegion` | `createRegion()` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createMenuItem` | `createMenuItem(ownermenu)` | 14 (8) | stub | No CE windows. Use Wraith's `ui` |
| `createMainMenu` | `createMainMenu(form)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createPopupMenu` | `createPopupMenu(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createImageList` | `createImageList(owner OPTIONAL)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createForm` | `createForm(visible OPT)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createFormFromFile` | `createFormFromFile(filename)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createFormFromStream` | `createFormFromStream(stream)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createPaintBox` | `createPaintBox(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createLabel` | `createLabel(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createSplitter` | `createSplitter(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createPanel` | `createPanel(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createImage` | `createImage(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createEdit` | `createEdit(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createMemo` | `createMemo(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createSynEdit` | `createSynEdit(owner,mode OPTIONAL)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createButton` | `createButton(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createCheckBox` | `createCheckBox(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createToggleBox` | `createToggleBox(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createGroupBox` | `createGroupBox(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createRadioGroup` | `createRadioGroup(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createListBox` | `createListBox(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createCalendar` | `createCalendar(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createComboBox` | `createComboBox(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createProgressBar` | `createProgressBar(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createTrackBar` | `createTrackBar(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createListView` | `createListView(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createTreeView` | `createTreeView(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createFont` | `createFont()` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createBitmap` | `createBitmap(width, height)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createPNG` | `createPNG(width, height)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createJpeg` | `createJpeg(width, height)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createIcon` | `createIcon(width, height)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createPicture` | `createPicture()` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createHotkey` | `createHotkey(function, keys, ...)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createColorDialog` | `createColorDialog(owner OPTIONAL)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createColorBox` | `createColorBox(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createFindDialog` | `createFindDialog(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createOpenDialog` | `createOpenDialog(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createSaveDialog` | `createSaveDialog(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createSelectDirectoryDialog` | `createSelectDirectoryDialog(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createMemoryView` | `createMemoryView()` | 0 (0) | n/a | No CE windows. Use Wraith's `ui` |
| `createDiagram` | `createDiagram(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createCECustomButton` | `createCECustomButton(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |
| `createVirtualStringTree` | `createVirtualStringTree(owner)` | 0 (0) | stub | No CE windows. Use Wraith's `ui` |

### Keys, mouse, windows and system

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `getWindowlist` | `getWindowlist(Strings)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getCPUCount` | `getCPUCount()` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `cpuid` | `cpuid(EAX,ECX)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getSystemMetrics` | `getSystemMetrics(index)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getScreenDPI` | `getScreenDPI()` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getScreenHeight` | `getScreenHeight()` | 0 (0) | partial | `ui:displaySize`, the game window's size. 0 outside a frame |
| `getScreenWidth` | `getScreenWidth()` | 0 (0) | partial | `ui:displaySize`, the game window's size. 0 outside a frame |
| `getWorkAreaHeight` | `getWorkAreaHeight()` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getWorkAreaWidth` | `getWorkAreaWidth()` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `invertColor` | `invertColor(color)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getPixel` | `getPixel(x,y)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `setMousePos` | `setMousePos(x,y)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getMousePos` | `getMousePos()` | 0 (0) | partial | `input:mousePos`, in the game window's client pixels, not the screen's |
| `isKeyPressed` | `isKeyPressed(key)` | 0 (0) | partial | `input:keyDown` and `input:buttonDown`, from the game window's messages, so it's false while another window has focus |
| `keyDown` | `keyDown(key)` | 12 (12) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `keyUp` | `keyUp(key)` | 12 (12) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `doKeyPress` | `doKeyPress(key)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `mouse_event` | `mouse_event(flags, x OPTIONAL, y OPTIONAL, data OPTIONAL, extra OPTIONAL)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `shortCutToText` | `shortCutToText(shortcut)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `textToShortCut` | `textToShortCut(shortcutstring)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `convertKeyComboToString` | `convertKeyComboToString(key1,...)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `shellExecute` | `shellExecute(command, parameters OPTIONAL, folder OPTIONAL, showcommand OPTIONAL)` | 9 (5) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `runCommand` | `runCommand(exepath, parameters or {parameter1, parameter2}, pathtoexecutein OPTIONAL)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `writeToClipboard` | `writeToClipboard(text)` | 2 (2) | implemented | `clipboard:setText`, off the game's threads |
| `readFromClipboard` | `readFromClipboard()` | 0 (0) | partial | `clipboard:text():await()`, so it waits a frame, and only in a thread, timer or the main script |
| `getForegroundProcess` | `getForegroundProcess()` | 0 (0) | n/a | No API for this yet. Keys go through `keybinds` and `input` |
| `findWindow` | `findWindow(classname OPTIONAL, caption OPTIONAL)` | 2 (2) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getWindow` | `getWindow(windowhandle, command)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getWindowCaption` | `getWindowCaption(windowhandle)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getWindowClassName` | `getWindowClassName(windowhandle)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getWindowProcessID` | `getWindowProcessID(windowhandle)` | 2 (2) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getForegroundWindow` | `getForegroundWindow()` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `sendMessage` | `sendMessage(hwnd, msg, wparam, lparam)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `hookWndProc` | `hookWndProc(hwnd, function(hwnd, msg, wparam, lparam)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `unhookWndProc` | `unhookWndProc(hwnd)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `getUserRegistryEnvironmentVariable` | `getUserRegistryEnvironmentVariable(name)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `setUserRegistryEnvironmentVariable` | `setUserRegistryEnvironmentVariable(name, string)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `setGlobalKeyPollInterval` | `setGlobalKeyPollInterval(integer)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `setGlobalDelayBetweenHotkeyActivation` | `setGlobalDelayBetweenHotkeyActivation(integer)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `getXBox360ControllerState` | `getXBox360ControllerState(ControllerID OPTIONAL)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |
| `setXBox360ControllerVibration` | `setXBox360ControllerVibration(ControllerID, leftMotor, rightMotor)` | 0 (0) | stub | No API for this yet. Keys go through `keybinds` and `input` |

### Debugger

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `createProcess` | `createProcess(path, parameters OPTIONAL, debug OPTIONAL, breakonentrypoint OPTIONAL)` | 0 (0) | n/a | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debugProcess` | `debugProcess(interface OPT)` | 0 (0) | n/a | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_isDebugging` | `debug_isDebugging()` | 2 (2) | partial | True while a breakpoint's set |
| `debug_getCurrentDebuggerInterface` | `debug_getCurrentDebuggerInterface()` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_canBreak` | `debug_canBreak()` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_isBroken` | `debug_isBroken()` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_isStepping` | `debug_isStepping()` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_getBreakpointList` | `debug_getBreakpointList()` | 0 (0) | implemented | The layer's own list |
| `debug_breakThread` | `debug_breakThread(threadid)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_addThreadToNoBreakList` | `debug_addThreadToNoBreakList(threadid)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_removeThreadFromNoBreakList` | `debug_removeThreadFromNoBreakList(threadid)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_setBreakpointForThread` | `debug_setBreakpointForThread(threadid, address, size OPTIONAL, trigger OPTIONAL, breakpointmethod OPTIONAL, functiontocall()` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_setBreakpoint` | `debug_setBreakpoint(address, size OPTIONAL, trigger OPTIONAL, breakpointmethod OPTIONAL, functiontocall()` | 0 (0) | partial | `watches:add(address, 1, "execute", ...)` or `watches:add` on a debug register. The game doesn't stop, so the function runs a frame later with a copy of the registers in RAX, EAX and co |
| `debug_removeBreakpoint` | `debug_removeBreakpoint(address)` | 0 (0) | implemented | Stops its watch |
| `debug_continueFromBreakpoint` | `debug_continueFromBreakpoint(continueMethod)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_getXMMPointer` | `debug_getXMMPointer(xmmregnr)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_setLastBranchRecording` | `debug_setLastBranchRecording(boolean)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_getMaxLastBranchRecord` | `debug_getMaxLastBranchRecord()` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_getLastBranchRecord` | `debug_getLastBranchRecord(index)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_getContext` | `debug_getContext(BOOL extraregs)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_setContext` | `debug_setContext(BOOL extraregs)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `debug_updateGUI` | `debug_updateGUI()` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `detachIfPossible` | `detachIfPossible()` | 0 (0) | n/a | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `getComment` | `getComment(address)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `setComment` | `setComment(address, text)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `getHeader` | `getHeader(address)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |
| `setHeader` | `setHeader(address)` | 0 (0) | stub | No debugger that stops the game. Use Wraith's hooks, `watches:add` or `watches:add(address, 1, "execute", ...)` |

### Speedhack

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `speedhack_setSpeed` | `speedhack_setSpeed(speed)` | 10 (2) | implemented | `game:setSpeed`, through the engine's plugin where there is one, like Unity's time scale, else the clocks. Wraith and its scripts keep real time |
| `speedhack_getSpeed` | `speedhack_getSpeed()` | 0 (0) | implemented | `game:speed()` |
| `registerSpeedhackCallbacks` | `registerSpeedhackCallbacks()` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterSpeedhackCallbacks` | `unregisterSpeedhackCallbacks(CallbackID)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `dbvm_speedhack_setSpeed` | `dbvm_speedhack_setSpeed(speed)` | 0 (0) | stub | There's no DBVM, use `speedhack_setSpeed` |

### Structures and dissecting

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `getRTTIClassName` | `getRTTIClassName(address)` | 0 (0) | stub | Use Wraith's schemas |
| `registerGlobalStructureListUpdateNotification` | `registerGlobalStructureListUpdateNotification(function(sender)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterGlobalStructureListUpdateNotification` | `unregisterGlobalStructureListUpdateNotification(id)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `registerStructureAndElementListCallback` | `registerStructureAndElementListCallback(function StructureListCallback()` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterStructureAndElementListCallback` | `unregisterStructureAndElementListCallback(ID)` | 0 (0) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `registerStructureDissectOverride` | `registerStructureDissectOverride(function(structure, baseaddress)` | 1 (1) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterStructureDissectOverride` | `unregisterStructureDissectOverride(ID)` | 1 (1) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `registerStructureNameLookup` | `registerStructureNameLookup(function(address)` | 1 (1) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `unregisterStructureNameLookup` | `unregisterStructureNameLookup(ID)` | 1 (1) | stub (warns) | Does nothing and warns once, so the main script carries on |
| `getInstructionSize` | `getInstructionSize(address)` | 0 (0) | implemented | `code:instructionLength`, nil when it's unreadable |
| `createStructureForm` | `createStructureForm(address, groupname OPTIONAL, structurename OPTIONAL)` | 0 (0) | stub | Use Wraith's schemas |
| `enumStructureForms` | `enumStructureForms()` | 0 (0) | stub | Use Wraith's schemas |
| `getStructureCount` | `getStructureCount()` | 0 (0) | stub | Use Wraith's schemas |
| `getStructure` | `getStructure(index)` | 0 (0) | stub | Use Wraith's schemas |
| `createStructure` | `createStructure(name)` | 0 (0) | stub | Use Wraith's schemas |
| `createStructureFromName` | `createStructureFromName(string)` | 0 (0) | stub | Use Wraith's schemas |
| `getDissectCode` | `getDissectCode()` | 0 (0) | stub | Use Wraith's schemas |

### Kernel, DBVM and physical memory

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `dbk_initialize` | `dbk_initialize()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_useKernelmodeOpenProcess` | `dbk_useKernelmodeOpenProcess()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_useKernelmodeProcessMemoryAccess` | `dbk_useKernelmodeProcessMemoryAccess()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_useKernelmodeQueryMemoryRegions` | `dbk_useKernelmodeQueryMemoryRegions()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_usePhysicalMemoryAccess` | `dbk_usePhysicalMemoryAccess()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_setSaferPhysicalMemoryScanning` | `dbk_setSaferPhysicalMemoryScanning(state: BOOLEAN)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_readPhysicalMemory` | `dbk_readPhysicalMemory(address, size)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_writePhysicalMemory` | `dbk_writePhysicalMemory(address, size)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_getPEProcess` | `dbk_getPEProcess(processid)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_getPEThread` | `dbk_getPEThread(threadid)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_readMSR` | `dbk_readMSR(msr)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_writeMSR` | `dbk_writeMSR(msr, msrvalue)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_executeKernelMemory` | `dbk_executeKernelMemory(address, parameter)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_initialize` | `dbvm_initialize(offloados:Boolean OPTIONAL, reason:String OPTIONAL)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_setKeys` | `dbvm_setKeys(key1,key2,key3)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_getMemory` | `dbvm_getMemory()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_addMemory` | `dbvm_addMemory(pagecount)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_readMSR` | `dbvm_readMSR(msr)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_writeMSR` | `dbvm_writeMSR(msr, value)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_getCR4` | `dbvm_getCR4()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_readPhysicalMemory` | `dbvm_readPhysicalMemory(address, size)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_writePhysicalMemory` | `dbvm_writePhysicalMemory(address, bytetable)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_watch_writes` | `dbvm_watch_writes(PhysicalAddress, bytesize OPTIONAL, OPTIONS OPTIONAL,  internalentrycount OPTIONAL, Optional1, Optional2)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_watch_reads` | `dbvm_watch_reads(PhysicalAddress, bytesize OPTIONAL, OPTIONS OPTIONAL,  internalentrycount OPTIONAL, Optional1, Optional2)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_watch_executes` | `dbvm_watch_executes(PhysicalAddress, bytesize OPTIONAL, OPTIONS OPTIONAL,  internalentrycount OPTIONAL, Optional1, Optional2)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_watch_retrievelog` | `dbvm_watch_retrievelog(ID)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_watch_disable` | `dbvm_watch_disable(ID)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_cloak_activate` | `dbvm_cloak_activate(physicalbase, virtualbase OPTIONAL)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_cloak_deactivate` | `dbvm_cloak_deactivate(physicalbase)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_cloak_readOriginal` | `dbvm_cloak_readOriginal(physicalbase)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_cloak_writeOriginal` | `dbvm_cloak_writeOriginal(physicalbase, bytetable[4096])` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_changeregonbp` | `dbvm_changeregonbp(physicaladdress, changereginfo, virtualaddress OPTIONAL)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_removechangeregonbp` | `dbvm_removechangeregonbp(physicaladdress)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_traceonbp` | `dbvm_traceonbp(PhysicalAddress, stepcount, VirtualAddress, {secondaryoptions})` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_traceonbp_getstatus` | `dbvm_traceonbp_getstatus()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_traceonbp_stoptrace` | `dbvm_traceonbp_stoptrace()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_traceonbp_remove` | `dbvm_traceonbp_remove(pa,force: boolean)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_traceonbp_retrievelog` | `dbvm_traceonbp_retrievelog()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_bp_getBrokenThreadListSize` | `dbvm_bp_getBrokenThreadListSize()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_bp_getBrokenThreadEventShort` | `dbvm_bp_getBrokenThreadEventShort(id)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_bp_getBrokenThreadEventFull` | `dbvm_bp_getBrokenThreadEventFull(id)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_bp_setBrokenThreadEventFull` | `dbvm_bp_setBrokenThreadEventFull(id,state)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_bp_resumeBrokenThread` | `dbvm_bp_resumeBrokenThread(id, continueMethod)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_bp_getProcessAndThreadIDFromEvent` | `dbvm_bp_getProcessAndThreadIDFromEvent(ThreadEvent)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_log_cr3_start` | `dbvm_log_cr3_start()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_log_cr3_stop` | `dbvm_log_cr3_stop()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbvm_setTSCAdjust` | `dbvm_setTSCAdjust(enabled, timeout)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_getCR0` | `dbk_getCR0()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_getCR3` | `dbk_getCR3()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_getCR4` | `dbk_getCR4()` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_getPhysicalAddress` | `dbk_getPhysicalAddress(address)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `dbk_writesIgnoreWriteProtection` | `dbk_writesIgnoreWriteProtection(state)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `getPhysicalAddressCR3` | `getPhysicalAddressCR3(CR3, address)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `readProcessMemoryCR3` | `readProcessMemoryCR3(CR3, address, size)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `writeProcessMemoryCR3` | `writeProcessMemoryCR3(CR3, address, bytetable)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `allocateKernelMemory` | `allocateKernelMemory(size)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `freeKernelMemory` | `freeKernelMemory(address)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `mapMemory` | `mapMemory(address, size,  frompid OPTIONAL, topid OPTIONAL)` | 0 (0) | n/a | Needs CE's driver or DBVM |
| `unmapMemory` | `unmapMemory(address, mdl)` | 0 (0) | n/a | Needs CE's driver or DBVM |

### Network, SQL, .NET, D3D and the rest

| Name | CE signature | Used | Status | Wraith, or why not |
|---|---|---|---|---|
| `searchPDBWhileLoading` | `searchPDBWhileLoading(state: boolean)` | 0 (0) | implemented | Does nothing |
| `onAPIPointerChange` | `onAPIPointerChange(function)` | 0 (0) | stub | No Wraith API for this yet |
| `setAPIPointer` | `setAPIPointer(functionid, address)` | 0 (0) | stub | No Wraith API for this yet |
| `createD3DHook` | `createD3DHook(textureandcommandlistsize OPTIONAL, hookmessages OPTIONAL)` | 0 (0) | stub | No Wraith API for this yet |
| `createRipRelativeScanner` | `createRipRelativeScanner(startaddress, stopaddress, includejumpsandcalls OPTIONAL)` | 0 (0) | stub | No Wraith API for this yet |
| `connectToPipe` | `connectToPipe(pipename,timeout OPTIONAL)` | 0 (0) | stub | No Wraith API for this yet |
| `createPipe` | `createPipe(pipename, inputsize OPTIONAL, outputsize OPTIONAL)` | 0 (0) | stub | No Wraith API for this yet |
| `getUltimap2` | `getUltimap2()` | 0 (0) | n/a | No Wraith API for this yet |
| `getCodeFilter` | `getCodeFilter()` | 0 (0) | n/a | No Wraith API for this yet |
| `createSQLite3Connection` | `createSQLite3Connection(owner)` | 0 (0) | stub | No Wraith API for this yet |
| `setSQLiteLibraryName` | `setSQLiteLibraryName(pathwithdllname)` | 0 (0) | stub | No Wraith API for this yet |
| `createODBCConnection` | `createODBCConnection(owner)` | 0 (0) | stub | No Wraith API for this yet |
| `createSQLTransaction` | `createSQLTransaction(owner)` | 0 (0) | stub | No Wraith API for this yet |
| `createSQLQuery` | `createSQLQuery(owner)` | 0 (0) | stub | No Wraith API for this yet |
| `loadModule` | `loadModule(pathtodll, executeEntryPoint OPTIONAL default=true, timeout OPTIONAL default=nil=infinite)` | 0 (0) | stub | No Wraith API for this yet |
| `getDotNetDataCollector` | `getDotNetDataCollector()` | 0 (0) | stub | No Wraith API for this yet |
| `connectToCEServer` | `connectToCEServer(hostname,port)` | 0 (0) | n/a | No Wraith API for this yet |
| `isConnectedToCEServer` | `isConnectedToCEServer()` | 0 (0) | n/a | No Wraith API for this yet |
| `getCEServerPath` | `getCEServerPath()` | 0 (0) | n/a | No Wraith API for this yet |
| `getCEServerInterface` | `getCEServerInterface()` | 0 (0) | n/a | No Wraith API for this yet |

### Classes

The layer makes the ones marked partial, with their members listed after. Member counts are by name,
so `.Count` counts every class that has one.

| Class | Members | Most used members | Status | Notes |
|---|---|---|---|---|
| `Object` | 6 | destroy, methodName, ClassName | partial | Made by the layer, members below |
| `Component` | 14 | Name, ComponentCount, Component[int] | partial | Made by the layer, members below |
| `Control` | 55 | Color, Enabled, Visible | stub | Its constructors raise |
| `Region` | 2 | addRectangle, addPolygon | stub | Its constructors raise |
| `WinControl` | 18 | Handle, DoubleBuffered, ControlCount | stub | Its constructors raise |
| `MenuItem` | 24 | Count, add, insert | stub | Its constructors raise |
| `Menu` | 2 | Items, getItems | stub | Its constructors raise |
| `MainMenu` | 0 |  | stub | Its constructors raise |
| `PopupMenu` | 0 |  | stub | Its constructors raise |
| `Strings` | 23 | Count, Text, add | partial | Made by the layer, members below |
| `ImageList` | 10 | Count, add, draw | stub | Its constructors raise |
| `Stringlist` | 9 | Sorted, Duplicates, CaseSensitive | partial | Made by the layer, members below |
| `Application` | 6 | Title, Icon, bringToFront | stub | Its constructors raise |
| `ControlScrollBar` | 0 |  | stub | Its constructors raise |
| `ScrollingWinControl` | 2 | HorzScrollBar, VertScrollBar | stub | Its constructors raise |
| `Form` | 31 | close, hide, Menu | stub | Its constructors raise |
| `CEForm` | 6 | DoNotSaveInTable, saveToFile, saveToStream | stub | Its constructors raise |
| `TfrmLuaEngine` | 2 | mOutput, mScript | stub | Its constructors raise |
| `TfrmAutoInject` | 5 | Assemblescreen, TabCount, TabScript[index] | stub | Its constructors raise |
| `GraphicControl` | 2 | Canvas, getCanvas | stub | Its constructors raise |
| `PaintBox` | 0 |  | stub | Its constructors raise |
| `Label` | 0 |  | stub | Its constructors raise |
| `Splitter` | 0 |  | stub | Its constructors raise |
| `Panel` | 15 | Alignment, BevelInner, BevelOuter | stub | Its constructors raise |
| `Image` | 12 | Canvas, Transparent, Stretch | stub | Its constructors raise |
| `Edit` | 29 | Text, clear, select | stub | Its constructors raise |
| `Memo` | 15 | Lines, WordWrap, WantTabs | stub | Its constructors raise |
| `SynEdit` | 20 | Lines, Gutter, ReadOnly | stub | Its constructors raise |
| `ButtonControl` | 0 |  | stub | Its constructors raise |
| `Button` | 3 | ModalResult, getModalResult, setModalResult | stub | Its constructors raise |
| `CheckBox` | 9 | State, Checked, AllowGrayed | stub | Its constructors raise |
| `ToggleBox` | 0 |  | stub | Its constructors raise |
| `GroupBox` | 0 |  | stub | Its constructors raise |
| `RadioGroup` | 12 | Items, OnClick, getItemIndex | stub | Its constructors raise |
| `ListBox` | 12 | Items, clear, Canvas | stub | Its constructors raise |
| `Calendar` | 2 | Date, DateTime | stub | Its constructors raise |
| `ComboBox` | 11 | Items, clear, Canvas | stub | Its constructors raise |
| `ProgressBar` | 13 | Min, Position, Step | stub | Its constructors raise |
| `TrackBar` | 12 | Min, Position, Max | stub | Its constructors raise |
| `CollectionItem` | 0 |  | stub | Its constructors raise |
| `Base` | 8 | Index, ID, DisplayName | stub | Its constructors raise |
| `ListColumn` | 16 | Visible, Caption, AutoSize | stub | Its constructors raise |
| `Collection` | 5 | Count, delete, getCount | stub | Its constructors raise |
| `ListColumns` | 4 | add, Columns[], getColumn | stub | Its constructors raise |
| `ListItem` | 18 | Index, delete, Caption | stub | Its constructors raise |
| `ListItems` | 6 | Count, add, getCount | stub | Its constructors raise |
| `Listview` | 27 | Items, clear, Canvas | stub | Its constructors raise |
| `HeaderSection` | 8 | Text, Visible, Alignment | stub | Its constructors raise |
| `HeaderSections` | 3 | add, insert, delete | stub | Its constructors raise |
| `TreeNode` | 21 | Index, Count, Text | stub | Its constructors raise |
| `TreeNodes` | 8 | Count, add, insert | stub | Its constructors raise |
| `Treeview` | 11 | Items, Selected, beginUpdate | stub | Its constructors raise |
| `Timer` | 9 | Interval, OnTimer, Enabled | partial | Made by the layer, members below |
| `CustomControl` | 3 | Canvas, OnPaint, getCanvas | stub | Its constructors raise |
| `Canvas` | 34 | clear, line, draw | stub | Its constructors raise |
| `Pen` | 6 | Color, Width, getColor | stub | Its constructors raise |
| `Brush` | 3 | Color, getColor, setColor | stub | Its constructors raise |
| `Font` | 16 | Color, Size, Name | stub | Its constructors raise |
| `Graphic` | 9 | Transparent, Width, Height | stub | Its constructors raise |
| `RasterImage` | 9 | Canvas, PixelFormat, TransparentColor | stub | Its constructors raise |
| `Bitmap` | 0 |  | stub | Its constructors raise |
| `PortableNetworkGraphic` | 0 |  | stub | Its constructors raise |
| `JpegImage` | 0 |  | stub | Its constructors raise |
| `Icon` | 0 |  | stub | Its constructors raise |
| `Picture` | 4 | loadFromFile, saveToFile, loadFromStream | stub | Its constructors raise |
| `GenericHotkey` | 5 | DelayBetweenActivate, onHotkey, getKeys | stub | Its constructors raise |
| `CommonDialog` | 4 | Execute, OnClose, OnShow | stub | Its constructors raise |
| `ColorDialog` | 0 |  | stub | Its constructors raise |
| `ColorBox` | 0 |  | stub | Its constructors raise |
| `FindDialog` | 4 | Options, FindText, OnFind | stub | Its constructors raise |
| `FileDialog` | 6 | FileName, DefaultExt, Files | stub | Its constructors raise |
| `OpenDialog` | 1 | Options | stub | Its constructors raise |
| `SaveDialog` | 0 |  | stub | Its constructors raise |
| `SelectDirectoryDialog` | 0 |  | stub | Its constructors raise |
| `Stream` | 17 | write, Size, Position | stub | Its constructors raise |
| `MemoryStream` | 6 | clear, Memory, loadFromFile | partial | Only a table file's, with `Size` and `Position` for `playSound`. Its constructors and the rest raise |
| `FileStream` | 0 |  | stub | Its constructors raise |
| `StringStream` | 0 |  | stub | Its constructors raise |
| `TableFile` | 6 | delete, Name, Stream | partial | From `findTableFile`, with `Name`, `Stream` and `getData`. `saveToFile` and `delete` raise, and so do its constructors |
| `xmplayer` | 7 | stop, IsPlaying, Initialized | stub | Its constructors raise |
| `CheatComponent` | 15 | Description, Color, Hotkey | stub | Its constructors raise |
| `MemoryRecordHotkey` | 12 | Description, Active, action | stub | Its constructors raise |
| `MemoryRecord` | 69 | Description, Type, appendToEntry | partial | Made by the layer, members below |
| `Addresslist` | 34 | createMemoryRecord, getMemoryRecordByDescription, Count | partial | Made by the layer, members below |
| `MemScan` | 45 | firstScan, waitTillDone, CodePage | partial | Made by the layer, members below |
| `FoundList` | 9 | Address[index], Count, getCount | partial | Made by the layer, members below |
| `Memoryview` | 2 | DisassemblerView, HexadecimalView | stub | Its constructors raise |
| `DisassemblerviewLine` | 3 | Address, Owner, OnDisassemblerViewOverride | stub | Its constructors raise |
| `Disassemblerview` | 11 | SelectedAddress, SelectedAddress2, SelectionSize | stub | Its constructors raise |
| `Hexadecimal` | 7 | Address, HasSelection, SelectionStart | stub | Its constructors raise |
| `Thread` | 10 | Name, Finished, Terminated | partial | Made by the layer, members below |
| `CriticalSection` | 3 | enter, leave, tryEnter | partial | Made by the layer, members below |
| `Event` | 3 | resetEvent, setEvent, waitFor | stub | Its constructors raise |
| `Semaphore` | 2 | acquire, release | stub | Its constructors raise |
| `MultiReadExclusiveWriteSynchronizer` | 4 | beginWrite, endWrite, beginRead | stub | Its constructors raise |
| `StructureFrm` | 0 |  | stub | Its constructors raise |
| `structColumn` | 0 |  | stub | Its constructors raise |
| `structGroup` | 0 |  | stub | Its constructors raise |
| `Structure` | 0 |  | stub | Its constructors raise |
| `structure` | 15 | Count, Size, Name | stub | Its constructors raise |
| `StructureElement` | 25 | Name, Offset, setOffset | stub | Its constructors raise |
| `D3DHOOK` | 15 | OnClick, Width, Height | stub | Its constructors raise |
| `D3DHook_Texture` | 0 |  | stub | Its constructors raise |
| `This` | 3 | Height, Width, loadTextureByPicture | stub | Its constructors raise |
| `D3DHook_FontMap` | 2 | changeFont, getTextWidth | stub | Its constructors raise |
| `D3DHook_RenderObject` | 8 | Visible, X, Alphablend | stub | Its constructors raise |
| `D3DHook_Sprite` | 3 | Width, Height, Texture | stub | Its constructors raise |
| `D3Dhook_TextContainer` | 2 | Text, FontMap | stub | Its constructors raise |
| `Disassembler` | 7 | disassemble, getLastDisassembleData, LastDisassembleData | stub | Its constructors raise |
| `DissectCode` | 9 | clear, dissect, addReference | stub | Its constructors raise |
| `RIPRelativeScanner` | 2 | Address[], Count | stub | Its constructors raise |
| `LuaPipe` | 26 | readQword, Connected, lock | stub | Its constructors raise |
| `LuaPipeClient` | 0 |  | stub | Its constructors raise |
| `LuaPipeServer` | 4 | valid, handle, acceptConnection | stub | Its constructors raise |
| `Settings` | 4 | Value[], Path, getBinaryValue | stub | Its constructors raise |
| `SymbolList` | 13 | Name, clear, PID | stub | Its constructors raise |
| `Pagecontrol` | 7 | ShowTabs, TabIndex, ActivePage | stub | Its constructors raise |
| `TabSheet` | 1 | TabIndex | stub | Its constructors raise |
| `Internet` | 3 | Header, getURL, postURL | stub | Its constructors raise |
| `CustomType` | 7 | name, script, functiontypename | stub | Its constructors raise |
| `TFrmTracer` | 4 | Count, SelectionCount, Entry[index] | stub | Its constructors raise |
| `TfrmUltimap2` | 2 | Count, isInList | stub | Its constructors raise |
| `TfrmCodeFilter` | 1 | isInList | stub | Its constructors raise |
| `CustomConnection` | 8 | open, close, Connected | stub | Its constructors raise |
| `Database` | 5 | Connected, DatabaseName, KeepConnection | stub | Its constructors raise |
| `SQLConnection` | 10 | Options, Password, UserName | stub | Its constructors raise |
| `SQLite3Connection` | 3 | createDB, dropDB, getInsertID | stub | Its constructors raise |
| `ODBCConnection` | 3 | DatabaseName, Driver, FileDSN | stub | Its constructors raise |
| `DBTransaction` | 3 | Active, DataBase, closeDataSets | stub | Its constructors raise |
| `SQLTransaction` | 10 | Options, Action, SQLConnection | stub | Its constructors raise |
| `Param` | 4 | Name, Value, DataType | stub | Its constructors raise |
| `Params` | 2 | Items[index], AddParam | stub | Its constructors raise |
| `Field` | 5 | Index, Value, FieldName | stub | Its constructors raise |
| `Fields` | 7 | Count, add, clear | stub | Its constructors raise |
| `Dataset` | 45 | Active, insert, open | stub | Its constructors raise |
| `DBDataset` | 2 | DataBase, Transaction | stub | Its constructors raise |
| `CustomBufDataset` | 14 | FileName, PacketRecords, UniDirectional | stub | Its constructors raise |
| `CustomSQLQuery` | 8 | prepared, SQLConnection, SQLTransaction | stub | Its constructors raise |
| `SQLQuery` | 16 | Options, state, Database | stub | Its constructors raise |
| `RemoteThread` | 5 | Result, waitForThread, loaded | stub | Its constructors raise |
| `WriteLog` | 3 | status, logsize, getLog | stub | Its constructors raise |
| `DotNetDataCollector` | 0 |  | stub | Its constructors raise |
| `Diagram` | 27 | LineThickness, LineColor, PlotPointColor | stub | Its constructors raise |
| `DiagramBlock` | 26 | Caption, Name, X | stub | Its constructors raise |
| `DiagramLink` | 18 | Name, OriginBlock, DestinationBlock | stub | Its constructors raise |
| `RemoteExecutor` | 1 | executeStub | stub | Its constructors raise |
| `CECustomButton` | 18 | ShowPrefix, BorderColor, BorderSize | stub | Its constructors raise |
| `DOMNode` | 2 | writeToFile, writeToStream | stub | Its constructors raise |
| `DOMDocument` | 0 |  | stub | Its constructors raise |
| `XMLDocument` | 0 |  | stub | Its constructors raise |
| `VirtualTreeColumn` | 4 | Index, Text, Options | stub | Its constructors raise |
| `VirtualTreeColunmns` | 1 | add | stub | Its constructors raise |
| `Header` | 5 | Options, AutoSizeIndex, AutoResize | stub | Its constructors raise |
| `StringTreeOptions` | 6 | AnimationOptions, AutoOptions, MiscOptions | stub | Its constructors raise |
| `VirtualStringTree` | 50 | clear, Expanded[node], NodeDataSize | stub | Its constructors raise |
| `CEServerInterface` | 12 | connected, path, Option[optionname] | stub | Its constructors raise |

#### Object

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `ClassName` | `ClassName` | 0 (0) | implemented |  |
| `getClassName` | `getClassName()` | 0 (0) | implemented |  |
| `fieldAddress` | `fieldAddress(fieldname: string)` | 0 (0) | stub | Missing, reads give nil |
| `methodAddress` | `methodAddress(methodname: string)` | 0 (0) | stub | Missing, reads give nil |
| `methodName` | `methodName(address: integer)` | 12 (12) | stub | Missing, reads give nil |
| `destroy` | `destroy()` | 336 (34) | implemented |  |

#### Component

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `ComponentCount` | `ComponentCount` | 0 (0) | stub | Missing, reads give nil |
| `Component[int]` | `Component[int]` | 0 (0) | stub | Missing, reads give nil |
| `ComponentByName[string]` | `ComponentByName[string]` | 0 (0) | stub | Missing, reads give nil |
| `Name` | `Name` | 39 (16) | implemented |  |
| `Tag` | `Tag` | 0 (0) | implemented |  |
| `Owner` | `Owner` | 0 (0) | implemented |  |
| `getComponentCount` | `getComponentCount()` | 0 (0) | stub | Missing, reads give nil |
| `getComponent` | `getComponent(index)` | 0 (0) | stub | Missing, reads give nil |
| `findComponentByName` | `findComponentByName(name)` | 0 (0) | stub | Missing, reads give nil |
| `getName` | `getName()` | 0 (0) | stub | Missing, reads give nil |
| `setName` | `setName(newname)` | 0 (0) | stub | Missing, reads give nil |
| `getTag` | `getTag()` | 0 (0) | stub | Missing, reads give nil |
| `setTag` | `setTag(tagvalue)` | 0 (0) | stub | Missing, reads give nil |
| `getOwner` | `getOwner()` | 0 (0) | stub | Missing, reads give nil |

#### Strings

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `LineBreak` | `LineBreak` | 0 (0) | implemented |  |
| `Text` | `Text` | 166 (27) | implemented |  |
| `Count` | `Count` | 261 (32) | implemented |  |
| `String[]` | `String[]` | 48 (8) | implemented |  |
| `Data[]` | `Data[]` | 0 (0) | implemented |  |
| `clear` | `clear()` | 18 (8) | implemented |  |
| `add` | `add(string, data:integer OPTIONAL)` | 129 (30) | implemented |  |
| `addText` | `addText([[strings]])` | 0 (0) | implemented |  |
| `delete` | `delete(index)` | 102 (4) | implemented |  |
| `getText` | `getText()` | 0 (0) | implemented |  |
| `setText` | `setText(string)` | 0 (0) | implemented |  |
| `indexOf` | `indexOf(string)` | 0 (0) | implemented |  |
| `insert` | `insert(index, string)` | 104 (13) | implemented |  |
| `getCount` | `getCount()` | 81 (4) | implemented |  |
| `remove` | `remove(string)` | 71 (12) | implemented |  |
| `loadFromFile` | `loadFromFile(filename, ignoreencoding OPTIONAL default true)` | 0 (0) | stub | Scripts have no file access |
| `saveToFile` | `saveToFile(filename)` | 0 (0) | stub | Scripts have no file access |
| `getString` | `getString(index)` | 0 (0) | implemented |  |
| `setString` | `setString(index, string)` | 0 (0) | implemented |  |
| `getData` | `getData(index)` | 0 (0) | implemented |  |
| `setData` | `setData(index, integer)` | 0 (0) | implemented |  |
| `beginUpdate` | `beginUpdate()` | 0 (0) | implemented |  |
| `endUpdate` | `endUpdate()` | 0 (0) | implemented |  |

#### Stringlist

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `Sorted` | `Sorted` | 0 (0) | implemented |  |
| `Duplicates` | `Duplicates` | 0 (0) | implemented |  |
| `CaseSensitive` | `CaseSensitive` | 0 (0) | implemented |  |
| `getDuplicates` | `getDuplicates()` | 0 (0) | implemented |  |
| `setDuplicates` | `setDuplicates(Duplicates)` | 0 (0) | implemented |  |
| `getSorted` | `getSorted()` | 0 (0) | implemented |  |
| `setSorted` | `setSorted(boolean)` | 0 (0) | implemented |  |
| `getCaseSensitive` | `getCaseSensitive()` | 0 (0) | implemented |  |
| `setCaseSensitive` | `setCaseSensitive(boolean)` | 0 (0) | implemented |  |

#### Timer

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `Interval` | `Interval` | 100 (29) | implemented |  |
| `Enabled` | `Enabled` | 70 (23) | implemented |  |
| `OnTimer` | `OnTimer` | 100 (29) | implemented | Errors are logged and it keeps going |
| `getInterval` | `getInterval()` | 0 (0) | implemented |  |
| `setInterval` | `setInterval(interval)` | 2 (2) | implemented |  |
| `getOnTimer` | `getOnTimer()` | 0 (0) | implemented |  |
| `setOnTimer` | `setOnTimer(function(timer)` | 0 (0) | implemented |  |
| `getEnabled` | `getEnabled()` | 0 (0) | implemented |  |
| `setEnabled` | `setEnabled(boolean)` | 0 (0) | implemented |  |

#### Thread

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `Name` | `Name` | 39 (16) | implemented |  |
| `Finished` | `Finished` | 0 (0) | implemented |  |
| `Terminated` | `Terminated` | 0 (0) | implemented |  |
| `Result` | `Result` | 0 (0) | implemented |  |
| `freeOnTerminate` | `freeOnTerminate(state)` | 0 (0) | implemented |  |
| `synchronize` | `synchronize(function(thread, ...)` | 0 (0) | implemented |  |
| `waitfor` | `waitfor()` | 0 (0) | partial | `frame:next():await()`, only in a task |
| `suspend` | `suspend()` | 0 (0) | stub | Raises |
| `resume` | `resume()` | 0 (0) | implemented |  |
| `terminate` | `terminate()` | 0 (0) | implemented |  |

#### CriticalSection

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `enter` | `enter()` | 0 (0) | implemented |  |
| `leave` | `leave()` | 0 (0) | implemented |  |
| `tryEnter` | `tryEnter()` | 0 (0) | implemented |  |

#### MemScan

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `LastScanWasRegionScan` | `LastScanWasRegionScan` | 0 (0) | stub | Missing, reads give nil |
| `LastScanValue` | `LastScanValue` | 0 (0) | stub | Missing, reads give nil |
| `LastScanType` | `LastScanType` | 0 (0) | stub | Missing, reads give nil |
| `ScanresultFolder` | `ScanresultFolder` | 0 (0) | stub | Missing, reads give nil |
| `OnScanDone` | `OnScanDone` | 0 (0) | stub | Missing, reads give nil |
| `OnGuiUpdate` | `OnGuiUpdate` | 0 (0) | stub | Missing, reads give nil |
| `FoundList` | `FoundList` | 0 (0) | stub | Missing, reads give nil |
| `OnlyOneResult` | `OnlyOneResult` | 0 (0) | implemented |  |
| `IsUnique` | `IsUnique` | 0 (0) | stub | Missing, reads give nil |
| `Result` | `Result` | 0 (0) | implemented |  |
| `CodePage` | `CodePage` | 8 (4) | stub | Missing, reads give nil |
| `ScanOption` | `ScanOption` | 0 (0) | stub | Missing, reads give nil |
| `VariableType` | `VariableType` | 0 (0) | stub | Missing, reads give nil |
| `VarType` | `VarType` | 0 (0) | stub | Missing, reads give nil |
| `Roundingtype` | `Roundingtype` | 0 (0) | stub | Missing, reads give nil |
| `Scanvalue` | `Scanvalue` | 0 (0) | stub | Missing, reads give nil |
| `Scanvalue1` | `Scanvalue1` | 0 (0) | stub | Missing, reads give nil |
| `Scanvalue2` | `Scanvalue2` | 0 (0) | stub | Missing, reads give nil |
| `Startaddress` | `Startaddress` | 0 (0) | stub | Missing, reads give nil |
| `Stopaddress` | `Stopaddress` | 0 (0) | stub | Missing, reads give nil |
| `Hexadecimal` | `Hexadecimal` | 0 (0) | stub | Missing, reads give nil |
| `BinaryStringAsDecimal` | `BinaryStringAsDecimal` | 0 (0) | stub | Missing, reads give nil |
| `UTF16` | `UTF16` | 0 (0) | stub | Missing, reads give nil |
| `Casesensitive` | `Casesensitive` | 0 (0) | stub | Missing, reads give nil |
| `Fastscanmethod` | `Fastscanmethod` | 0 (0) | stub | Missing, reads give nil |
| `Fastscanparameter` | `Fastscanparameter` | 0 (0) | stub | Missing, reads give nil |
| `Customtype` | `Customtype` | 0 (0) | stub | Missing, reads give nil |
| `ScanWritable` | `ScanWritable` | 0 (0) | stub | Missing, reads give nil |
| `ScanExecutable` | `ScanExecutable` | 0 (0) | stub | Missing, reads give nil |
| `ScanCopyOnWrite` | `ScanCopyOnWrite` | 0 (0) | stub | Missing, reads give nil |
| `Percentage` | `Percentage` | 0 (0) | stub | Missing, reads give nil |
| `CompareToSavedScan` | `CompareToSavedScan` | 0 (0) | stub | Missing, reads give nil |
| `SavedScanName` | `SavedScanName` | 0 (0) | stub | Missing, reads give nil |
| `scan` | `scan()` | 0 (0) | stub | Raises |
| `firstScan` | `firstScan()` | 45 (21) | partial | Exact scans of numbers and strings through `memory:scan`, and arrays of bytes inside one module |
| `nextScan` | `nextScan()` | 0 (0) | partial | `MemoryScan:next`, but not by an amount |
| `newScan` | `newScan()` | 0 (0) | implemented |  |
| `waitTillDone` | `waitTillDone()` | 45 (21) | partial | Waits for the scan, so only in a thread, timer or the main script |
| `saveCurrentResults` | `saveCurrentResults(name)` | 0 (0) | stub | Raises |
| `getSavedResultList` | `getSavedResultList()` | 0 (0) | stub | Missing, reads give nil |
| `getSavedResultHandler` | `getSavedResultHandler(name)` | 0 (0) | stub | Missing, reads give nil |
| `getAttachedFoundlist` | `getAttachedFoundlist()` | 0 (0) | stub | Raises |
| `setOnlyOneResult` | `setOnlyOneResult(state)` | 0 (0) | implemented |  |
| `getOnlyResult` | `getOnlyResult()` | 0 (0) | implemented |  |
| `getProgress` | `getProgress()` | 0 (0) | stub | Raises |

#### FoundList

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `Count` | `Count` | 261 (32) | implemented |  |
| `Address[index]` | `Address[index]` | 723 (29) | implemented |  |
| `Value[index]` | `Value[index]` | 27 (7) | implemented | Read now, as the scan's type |
| `initialize` | `initialize()` | 45 (21) | implemented |  |
| `deinitialize` | `deinitialize()` | 0 (0) | implemented |  |
| `getCount` | `getCount()` | 81 (4) | implemented |  |
| `getAddress` | `getAddress(index)` | 39 (3) | implemented |  |
| `getValue` | `getValue(index)` | 0 (0) | implemented |  |
| `getStringFromAddress` | `getStringFromAddress(address, hexadecimal:boolean OPTIONAL, signed: boolean OPTIONAL)` | 0 (0) | stub | Missing, reads give nil |

#### MemoryRecord

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `ID` | `ID` | 22 (6) | implemented | The manifest's id |
| `Index` | `Index` | 276 (17) | implemented | Its place in the whole list, from 0 |
| `Description` | `Description` | 826 (21) | implemented |  |
| `Address` | `Address` | 723 (29) | partial | CE location text for location records, `(id)` for address list ones. Setting it makes it a location record |
| `AddressString` | `AddressString` | 0 (0) | implemented |  |
| `OffsetCount` | `OffsetCount` | 21 (4) | implemented |  |
| `Offset[]` | `Offset[]` | 38 (17) | implemented |  |
| `OffsetText[]` | `OffsetText[]` | 0 (0) | implemented |  |
| `CurrentAddress` | `CurrentAddress` | 20 (2) | implemented |  |
| `VarType` | `VarType` | 0 (0) | implemented |  |
| `Type` | `Type` | 785 (12) | implemented |  |
| `CustomTypeName` | `CustomTypeName` | 10 (4) | stub | Raises |
| `Script` | `Script` | 11 (5) | stub | Raises |
| `Value` | `Value` | 27 (7) | partial | Reads and writes address, data and location records by type. Tweaks give `<script>`, headers an empty string |
| `NumericalValue` | `NumericalValue` | 0 (0) | implemented |  |
| `Selected` | `Selected` | 0 (0) | implemented |  |
| `Active` | `Active` | 191 (24) | partial | Tweak records go through the bridge's `setOn`, address records freeze by writing every 100ms. AllowIncrease and AllowDecrease are ignored |
| `Color` | `Color` | 74 (8) | partial | Kept, but nothing in Wraith shows it or calls it |
| `ShowAsHex` | `ShowAsHex` | 176 (6) | implemented |  |
| `ShowAsSigned` | `ShowAsSigned` | 16 (4) | implemented |  |
| `AllowIncrease` | `AllowIncrease` | 0 (0) | partial | Kept, but nothing in Wraith shows it or calls it |
| `AllowDecrease` | `AllowDecrease` | 0 (0) | partial | Kept, but nothing in Wraith shows it or calls it |
| `Collapsed` | `Collapsed` | 0 (0) | partial | Kept, but nothing in Wraith shows it or calls it |
| `IsGroupHeader` | `IsGroupHeader` | 20 (6) | implemented |  |
| `IsAddressGroupHeader` | `IsAddressGroupHeader` | 20 (6) | partial | Kept, but nothing in Wraith shows it or calls it |
| `IsReadable` | `IsReadable` | 0 (0) | implemented |  |
| `Options` | `Options` | 113 (6) | implemented |  |
| `DropDownLinked` | `DropDownLinked` | 124 (7) | implemented | True when DropDownLinkedMemrec names another record |
| `DropDownLinkedMemrec` | `DropDownLinkedMemrec` | 124 (7) | implemented | Uses that record's dropdown list. The manifest's `dropdownLink` sets it |
| `DropDownList` | `DropDownList` | 106 (24) | implemented | A stringlist of the manifest's `dropdown` lines |
| `DropDownReadOnly` | `DropDownReadOnly` | 71 (17) | partial | Kept, but nothing in Wraith shows it or calls it |
| `DropDownDescriptionOnly` | `DropDownDescriptionOnly` | 71 (17) | partial | Kept, but nothing in Wraith shows it or calls it |
| `DisplayAsDropDownListItem` | `DisplayAsDropDownListItem` | 184 (23) | partial | Kept, but nothing in Wraith shows it or calls it |
| `DropDownCount` | `DropDownCount` | 5 (2) | implemented |  |
| `DropDownValue[index]` | `DropDownValue[index]` | 2 (1) | implemented |  |
| `DropDownDescription[index]` | `DropDownDescription[index]` | 2 (1) | implemented |  |
| `Count` | `Count` | 261 (32) | implemented |  |
| `Child[index]` | `Child[index]` | 298 (11) | implemented |  |
| `Parent` | `Parent` | 0 (0) | implemented |  |
| `HotkeyCount` | `HotkeyCount` | 32 (14) | partial | Always 0, hotkeys stay with the tweaks |
| `Hotkey[]` | `Hotkey[]` | 52 (14) | stub | Raises |
| `Async` | `Async` | 0 (0) | partial | Kept, but nothing in Wraith shows it or calls it |
| `AsyncProcessing` | `AsyncProcessing` | 0 (0) | stub | Raises |
| `AsyncProcessingTime` | `AsyncProcessingTime` | 0 (0) | stub | Raises |
| `HasMouseOver` | `HasMouseOver` | 0 (0) | stub | Raises |
| `OnActivate` | `OnActivate` | 0 (0) | partial | Called when the layer turns it on, and through `handle.toggled` when something else does |
| `OnDeactivate` | `OnDeactivate` | 0 (0) | partial | Same as OnActivate |
| `OnDestroy` | `OnDestroy` | 0 (0) | partial | Kept, but nothing in Wraith shows it or calls it |
| `OnGetDisplayValue` | `OnGetDisplayValue` | 0 (0) | partial | Kept, but nothing in Wraith shows it or calls it |
| `OnValueChanged` | `OnValueChanged` | 1 (1) | partial | Kept, but nothing in Wraith shows it or calls it |
| `OnValueChangedByUser` | `OnValueChangedByUser` | 0 (0) | partial | Kept, but nothing in Wraith shows it or calls it |
| `DontSave` | `DontSave` | 12 (4) | partial | Kept, but nothing in Wraith shows it or calls it |
| `getDescription` | `getDescription()` | 0 (0) | implemented |  |
| `setDescription` | `setDescription()` | 7 (5) | implemented |  |
| `getAddress` | `getAddress()` | 39 (3) | implemented |  |
| `setAddress` | `setAddress(string)` | 7 (5) | implemented |  |
| `getOffsetCount` | `getOffsetCount()` | 0 (0) | implemented |  |
| `setOffsetCount` | `setOffsetCount(integer)` | 2 (2) | implemented |  |
| `getOffset` | `getOffset(index)` | 0 (0) | implemented |  |
| `setOffset` | `setOffset(index, value)` | 2 (2) | implemented |  |
| `getCurrentAddress` | `getCurrentAddress()` | 0 (0) | implemented |  |
| `appendToEntry` | `appendToEntry(memrec)` | 735 (9) | implemented |  |
| `getHotkey` | `getHotkey(index)` | 0 (0) | stub | Raises |
| `getHotkeyByID` | `getHotkeyByID(integer)` | 0 (0) | stub | Raises |
| `reinterpret` | `reinterpret()` | 0 (0) | implemented |  |
| `createHotkey` | `createHotkey({keys}, action, value OPTIONAL, description OPTIONAL)` | 0 (0) | stub | Raises |
| `disableWithoutExecute` | `disableWithoutExecute()` | 2 (1) | implemented |  |
| `beginEdit` | `beginEdit()` | 0 (0) | implemented |  |
| `endEdit` | `endEdit()` | 0 (0) | implemented |  |

#### Addresslist

| Member | CE signature | Used | Status | Notes |
|---|---|---|---|---|
| `LoadedTableVersion` | `LoadedTableVersion` | 0 (0) | implemented |  |
| `Count` | `Count` | 261 (32) | implemented |  |
| `SelCount` | `SelCount` | 0 (0) | implemented |  |
| `SelectedRecord` | `SelectedRecord` | 0 (0) | partial | Always nil, nothing's selected |
| `MemoryRecord[]` | `MemoryRecord[]` | 48 (12) | implemented |  |
| `List` | `List` | 0 (0) | stub | Raises |
| `CheckboxActiveSelectedColor` | `CheckboxActiveSelectedColor` | 0 (0) | stub | Missing, reads give nil |
| `CheckboxActiveColor` | `CheckboxActiveColor` | 0 (0) | stub | Missing, reads give nil |
| `CheckboxSelectedColor` | `CheckboxSelectedColor` | 0 (0) | stub | Missing, reads give nil |
| `CheckboxColor` | `CheckboxColor` | 0 (0) | stub | Missing, reads give nil |
| `SelectedBackgroundColor` | `SelectedBackgroundColor` | 0 (0) | stub | Missing, reads give nil |
| `SelectedSecondaryBackgroundColor` | `SelectedSecondaryBackgroundColor` | 0 (0) | stub | Missing, reads give nil |
| `ExpandSignColor` | `ExpandSignColor` | 0 (0) | stub | Missing, reads give nil |
| `IncreaseArrowColor` | `IncreaseArrowColor` | 0 (0) | stub | Missing, reads give nil |
| `DecreaseArrowColor` | `DecreaseArrowColor` | 0 (0) | stub | Missing, reads give nil |
| `OnDescriptionChange` | `OnDescriptionChange` | 0 (0) | stub | Raises |
| `OnAddressChange` | `OnAddressChange` | 0 (0) | stub | Raises |
| `OnTypeChange` | `OnTypeChange` | 0 (0) | stub | Raises |
| `OnValueChange` | `OnValueChange` | 0 (0) | stub | Raises |
| `OnAutoAssemblerEdit` | `OnAutoAssemblerEdit` | 0 (0) | stub | Raises |
| `getCount` | `getCount()` | 81 (4) | implemented |  |
| `getMemoryRecord` | `getMemoryRecord(index)` | 0 (0) | implemented |  |
| `getMemoryRecordByDescription` | `getMemoryRecordByDescription(description)` | 460 (25) | implemented |  |
| `getMemoryRecordByID` | `getMemoryRecordByID(ID)` | 56 (7) | implemented |  |
| `createMemoryRecord` | `createMemoryRecord()` | 735 (9) | partial | A location record only the layer knows. It isn't in the Addresses window |
| `getSelectedRecords` | `getSelectedRecords()` | 0 (0) | partial | Always empty |
| `doDescriptionChange` | `doDescriptionChange()` | 0 (0) | stub | Raises |
| `doAddressChange` | `doAddressChange()` | 0 (0) | stub | Raises |
| `doTypeChange` | `doTypeChange()` | 0 (0) | stub | Raises |
| `doValueChange` | `doValueChange()` | 0 (0) | stub | Raises |
| `getSelectedRecord` | `getSelectedRecord()` | 0 (0) | implemented |  |
| `setSelectedRecord` | `setSelectedRecord(memrec)` | 0 (0) | implemented |  |
| `disableAllWithoutExecute` | `disableAllWithoutExecute()` | 0 (0) | implemented |  |
| `rebuildDescriptionCache` | `rebuildDescriptionCache()` | 0 (0) | implemented |  |


## Lua differences

CE runs Lua 5.3. Wraith runs Lua 5.5 in a sandbox, so a few things differ:

- `io`, `os.execute`, `os.getenv`, `dofile`, `package` and `debug.getinfo` aren't there. 12 of the tables
  use `io` to save settings, and that raises. `config` and `vfs` are the Wraith way.
- Lua 5.5 makes `for` loop variables read-only, so a table that assigns to one won't compile. The
  importer gives such loops a copy, like `for i = 1, 3 do local i = i`.
- A `return` at the top of a block can't have code after it, so the importer wraps a block like that
  in a function, the way CE ran it.
- `unpack` is put back. `loadstring`, `setfenv`, `table.getn` and `math.pow` aren't, since no table uses them.
- `string.split`, `startsWith` and `endsWith` are added to the shared string table, as CE does.
- Everything runs on the game's frame. `createThread` and timers share that one thread, so a loop in a
  thread has to `sleep` to let the game go on.

## Future work

- `autoAssemble` could run a small subset, like scripts that are just `[ENABLE]` writes and `define`s, by
  sending them through the importer's converter when the table loads. For now the importer converts AA
  scripts to tweaks ahead of time, and the call raises.
- `createMemoryRecord` could show its records in the Addresses window with `addresses:add`.
- AOBScan could scan all of the game's memory with `memory:scan`, but that's async and AOBScan isn't.
- `io.open` for a table's own folder through `vfs`.
- Hotkeys on memory records, through `keybinds`.
