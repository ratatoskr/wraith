//! A Cheat Engine table's entries, read from its XML.

const std = @import("std");

const xml = @import("xml.zig");

pub const Choice = struct {
    value: []const u8,
    label: []const u8,
};

pub const DropDown = struct {
    items: []const Choice = &.{},
    description_only: bool = false,
    /// `<DropDownListLink>`, another entry's list by its description.
    link: ?[]const u8 = null,
};

pub const Hotkey = struct {
    /// Like `Toggle Activation` or `Set Value`.
    action: []const u8,
    /// Windows virtual key codes, held together.
    keys: []const u16,
    value: []const u8 = "",
    description: []const u8 = "",
};

pub const Entry = struct {
    id: []const u8 = "",
    description: []const u8 = "",
    /// `<VariableType>`, like `4 Bytes` or `Auto Assembler Script`.
    type: []const u8 = "",
    /// `<CustomType>` when `type` is `Custom`.
    custom_type: []const u8 = "",
    address: ?[]const u8 = null,
    /// In the order they're followed, the reverse of the XML's.
    offsets: []const []const u8 = &.{},
    script: ?[]const u8 = null,
    group_header: bool = false,
    hide_children: bool = false,
    activate_children: bool = false,
    deactivate_children: bool = false,
    length: ?u32 = null,
    byte_length: ?u32 = null,
    unicode: bool = false,
    show_hex: bool = false,
    show_signed: bool = false,
    bit_start: ?u8 = null,
    bit_length: ?u8 = null,
    dropdown: ?DropDown = null,
    hotkeys: []const Hotkey = &.{},
    children: []const Entry = &.{},

    pub fn isScript(self: Entry) bool {
        return std.mem.eql(u8, self.type, "Auto Assembler Script");
    }

    /// Scripts in it, itself included.
    pub fn hasScripts(self: Entry) bool {
        if (self.isScript()) return true;
        for (self.children) |c| if (c.hasScripts()) return true;
        return false;
    }
};

pub const Symbol = struct {
    name: []const u8,
    address: []const u8,
};

pub const Table = struct {
    entries: []const Entry = &.{},
    lua: ?[]const u8 = null,
    symbols: []const Symbol = &.{},
    /// From `<Files>`, still encoded, see `files.zig`.
    files: []const @import("files.zig").Raw = &.{},
    /// Parts of the table we don't take, like `Structures` or `Forms`.
    skipped: []const []const u8 = &.{},
};

pub fn read(arena: std.mem.Allocator, source: []const u8) !Table {
    const root = try xml.parse(arena, source);
    if (!std.mem.eql(u8, root.name, "CheatTable")) return error.NotACheatTable;
    var table: Table = .{};
    var skipped: std.ArrayList([]const u8) = .empty;
    for (root.children) |c| {
        if (std.mem.eql(u8, c.name, "CheatEntries")) {
            table.entries = try entries(arena, c);
        } else if (std.mem.eql(u8, c.name, "LuaScript")) {
            if (std.mem.trim(u8, c.text, " \t\r\n").len > 0) table.lua = c.text;
        } else if (std.mem.eql(u8, c.name, "UserdefinedSymbols")) {
            var list: std.ArrayList(Symbol) = .empty;
            for (c.children) |s| {
                const name = s.childText("Name") orelse continue;
                try list.append(arena, .{ .name = trim(name), .address = trim(s.childText("Address") orelse "") });
            }
            table.symbols = list.items;
        } else if (std.mem.eql(u8, c.name, "Files")) {
            var list: std.ArrayList(@import("files.zig").Raw) = .empty;
            // New tables call each `FileN` with a `Name`, old ones use the name itself
            for (c.children) |f| try list.append(arena, .{
                .name = f.attr("Name") orelse f.name,
                .ascii85 = std.mem.eql(u8, f.attr("Encoding") orelse "", "Ascii85"),
                .text = trim(f.text),
            });
            table.files = list.items;
        } else if (c.children.len > 0 or trim(c.text).len > 0) {
            try skipped.append(arena, c.name);
        }
    }
    table.skipped = skipped.items;
    return table;
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, " \t\r\n");
}

fn flag(node: xml.Node, name: []const u8) bool {
    const t = trim(node.childText(name) orelse return false);
    return std.mem.eql(u8, t, "1");
}

fn optionFlag(options: ?*const xml.Node, name: []const u8) bool {
    const o = options orelse return false;
    return std.mem.eql(u8, o.attr(name) orelse "", "1");
}

fn number(comptime T: type, node: xml.Node, name: []const u8) ?T {
    return std.fmt.parseInt(T, trim(node.childText(name) orelse return null), 10) catch null;
}

fn entries(arena: std.mem.Allocator, list: xml.Node) error{OutOfMemory}![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (list.children) |c| {
        if (!std.mem.eql(u8, c.name, "CheatEntry")) continue;
        try out.append(arena, try entry(arena, c));
    }
    return out.items;
}

fn entry(arena: std.mem.Allocator, node: xml.Node) !Entry {
    var e: Entry = .{
        .id = trim(node.childText("ID") orelse ""),
        .description = unquote(trim(node.childText("Description") orelse "")),
        .type = trim(node.childText("VariableType") orelse ""),
        .custom_type = trim(node.childText("CustomType") orelse ""),
        .group_header = flag(node, "GroupHeader"),
        .unicode = flag(node, "Unicode"),
        .show_hex = flag(node, "ShowAsHex"),
        .show_signed = flag(node, "ShowAsSigned"),
        .length = number(u32, node, "Length"),
        .byte_length = number(u32, node, "ByteLength"),
        .bit_start = number(u8, node, "BitStart"),
        .bit_length = number(u8, node, "BitLength"),
    };
    if (node.childText("Address")) |a| {
        if (trim(a).len > 0) e.address = trim(a);
    }
    if (node.child("AssemblerScript")) |s| e.script = s.text;
    const options = node.child("Options");
    e.hide_children = optionFlag(options, "moHideChildren") or optionFlag(options, "moAlwaysHideChildren");
    e.activate_children = optionFlag(options, "moActivateChildrenAsWell");
    e.deactivate_children = optionFlag(options, "moDeactivateChildrenAsWell");

    if (node.child("Offsets")) |o| {
        var offsets: std.ArrayList([]const u8) = .empty;
        for (o.children) |c| if (std.mem.eql(u8, c.name, "Offset")) try offsets.append(arena, trim(c.text));
        // CE lists the last one followed first
        std.mem.reverse([]const u8, offsets.items);
        e.offsets = offsets.items;
    }

    if (node.child("DropDownList")) |d| {
        var items: std.ArrayList(Choice) = .empty;
        var it = std.mem.splitScalar(u8, d.text, '\n');
        while (it.next()) |raw| {
            const l = trim(raw);
            if (l.len == 0) continue;
            const colon = std.mem.indexOfScalar(u8, l, ':') orelse continue;
            try items.append(arena, .{ .value = trim(l[0..colon]), .label = trim(l[colon + 1 ..]) });
        }
        e.dropdown = .{ .items = items.items, .description_only = std.mem.eql(u8, d.attr("DescriptionOnly") orelse "", "1") };
    }
    if (node.childText("DropDownListLink")) |link| {
        var d = e.dropdown orelse DropDown{};
        d.link = unquote(trim(link));
        e.dropdown = d;
    }

    if (node.child("Hotkeys")) |h| {
        var keys: std.ArrayList(Hotkey) = .empty;
        for (h.children) |hk| {
            if (!std.mem.eql(u8, hk.name, "Hotkey")) continue;
            var codes: std.ArrayList(u16) = .empty;
            if (hk.child("Keys")) |ks| for (ks.children) |k| {
                try codes.append(arena, std.fmt.parseInt(u16, trim(k.text), 10) catch continue);
            };
            try keys.append(arena, .{
                .action = trim(hk.childText("Action") orelse ""),
                .keys = codes.items,
                .value = trim(hk.childText("Value") orelse ""),
                .description = trim(hk.childText("Description") orelse ""),
            });
        }
        e.hotkeys = keys.items;
    }

    if (node.child("CheatEntries")) |c| e.children = try entries(arena, c.*);
    return e;
}

/// CE quotes descriptions.
fn unquote(text: []const u8) []const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') return text[1 .. text.len - 1];
    return text;
}

const testing = std.testing;

test "entries, offsets reversed, dropdowns and hotkeys" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const source =
        \\<CheatTable>
        \\  <CheatEntries>
        \\    <CheatEntry>
        \\      <ID>1</ID>
        \\      <Description>"Party"</Description>
        \\      <Options moHideChildren="1" moActivateChildrenAsWell="1"/>
        \\      <GroupHeader>1</GroupHeader>
        \\      <CheatEntries>
        \\        <CheatEntry>
        \\          <ID>2</ID>
        \\          <Description>"HP"</Description>
        \\          <VariableType>4 Bytes</VariableType>
        \\          <Address>"game.exe"+1234</Address>
        \\          <Offsets>
        \\            <Offset>10</Offset>
        \\            <Offset>8</Offset>
        \\          </Offsets>
        \\          <DropDownList DescriptionOnly="1">0:Off
        \\1:On
        \\</DropDownList>
        \\          <Hotkeys>
        \\            <Hotkey><Action>Set Value</Action><Keys><Key>17</Key><Key>112</Key></Keys><Value>99</Value><ID>0</ID></Hotkey>
        \\          </Hotkeys>
        \\        </CheatEntry>
        \\      </CheatEntries>
        \\    </CheatEntry>
        \\  </CheatEntries>
        \\  <UserdefinedSymbols><SymbolEntry><Name>base</Name><Address>game.exe+10</Address></SymbolEntry></UserdefinedSymbols>
        \\  <Structures><Structure Name="x"/></Structures>
        \\  <LuaScript>print(1)</LuaScript>
        \\  <Files><File0 Name="ding.wav" Encoding="Ascii85">abc</File0><old.wav>0A0B</old.wav></Files>
        \\</CheatTable>
    ;
    const t = try read(arena.allocator(), source);
    const party = t.entries[0];
    try testing.expectEqualStrings("Party", party.description);
    try testing.expect(party.group_header and party.hide_children and party.activate_children);
    const hp = party.children[0];
    try testing.expectEqualStrings("\"game.exe\"+1234", hp.address.?);
    try testing.expectEqualStrings("8", hp.offsets[0]);
    try testing.expectEqualStrings("10", hp.offsets[1]);
    try testing.expect(hp.dropdown.?.description_only);
    try testing.expectEqualStrings("On", hp.dropdown.?.items[1].label);
    try testing.expectEqual(112, hp.hotkeys[0].keys[1]);
    try testing.expectEqualStrings("99", hp.hotkeys[0].value);
    try testing.expectEqualStrings("base", t.symbols[0].name);
    try testing.expectEqualStrings("Structures", t.skipped[0]);
    try testing.expectEqualStrings("print(1)", t.lua.?);
    try testing.expectEqualStrings("ding.wav", t.files[0].name);
    try testing.expect(t.files[0].ascii85);
    try testing.expectEqualStrings("old.wav", t.files[1].name);
    try testing.expect(!t.files[1].ascii85);
    try testing.expectEqualStrings("0A0B", t.files[1].text);
}
