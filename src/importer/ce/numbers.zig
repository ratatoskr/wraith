//! CE numbers to ours (CE `10` is hex, `#10` decimal). Tokenises, since a missed number is a wrong write.

const std = @import("std");
const tuft_asm = @import("tuft_asm");

/// What a word in the script is, as far as the caller knows.
pub const Lookup = union(enum) {
    /// Not a name it knows, so a hex-looking word is a number.
    unknown,
    /// A label or symbol, kept as it is.
    known,
    /// A name that's spelled differently on our side, like one from another tweak.
    rename: []const u8,
};

pub const Names = struct {
    context: ?*const anyopaque = null,
    lookup: *const fn (context: ?*const anyopaque, name: []const u8) Lookup = nothing,

    fn nothing(_: ?*const anyopaque, _: []const u8) Lookup {
        return .unknown;
    }

    pub const none: Names = .{};

    pub fn find(self: Names, word: []const u8) Lookup {
        return self.lookup(self.context, word);
    }
};

/// What came up while rewriting, for the report.
pub const Notes = struct {
    /// Words like `add` or `FF` that could be a name or a number. Read as numbers.
    ambiguous: std.ArrayList([]const u8) = .empty,
    /// Names that aren't hex and nothing knows.
    unknown: std.ArrayList([]const u8) = .empty,

    fn addAmbiguous(self: *Notes, arena: std.mem.Allocator, word: []const u8) !void {
        for (self.ambiguous.items) |w| if (std.mem.eql(u8, w, word)) return;
        try self.ambiguous.append(arena, word);
    }

    fn addUnknown(self: *Notes, arena: std.mem.Allocator, word: []const u8) !void {
        for (self.unknown.items) |w| if (std.mem.eql(u8, w, word)) return;
        try self.unknown.append(arena, word);
    }
};

/// A CE number on its own, like an offset: hex, `#` decimal, `$` or `0x` hex, maybe signed.
pub fn parse(text: []const u8) ?i64 {
    var t = std.mem.trim(u8, text, " \t");
    var negative = false;
    if (t.len > 0 and (t[0] == '-' or t[0] == '+')) {
        negative = t[0] == '-';
        t = std.mem.trim(u8, t[1..], " \t");
    }
    if (t.len == 0) return null;
    const value: u64 = if (t[0] == '#')
        std.fmt.parseInt(u64, t[1..], 10) catch return null
    else if (t[0] == '$')
        std.fmt.parseInt(u64, t[1..], 16) catch return null
    else if (std.ascii.startsWithIgnoreCase(t, "0x"))
        std.fmt.parseInt(u64, t[2..], 16) catch return null
    else
        std.fmt.parseInt(u64, t, 16) catch return null;
    const signed: i64 = @bitCast(value);
    return if (negative) -%signed else signed;
}

/// Ours, `0x` hex past 9.
pub fn format(arena: std.mem.Allocator, value: i64) ![]const u8 {
    if (value < 0) return std.fmt.allocPrint(arena, "-{s}", .{try format(arena, -%value)});
    if (value < 10) return std.fmt.allocPrint(arena, "{d}", .{value});
    return std.fmt.allocPrint(arena, "0x{X}", .{@as(u64, @bitCast(value))});
}

fn bits(arena: std.mem.Allocator, value: u64) ![]const u8 {
    if (value < 10) return std.fmt.allocPrint(arena, "{d}", .{value});
    return std.fmt.allocPrint(arena, "0x{X}", .{value});
}

/// Hex digits as they were, without leading zeros, as ours.
fn hexText(arena: std.mem.Allocator, digits: []const u8) ![]const u8 {
    var d = std.mem.trimStart(u8, digits, "0");
    if (d.len == 0) d = "0";
    if (d.len == 1 and std.ascii.isDigit(d[0])) return arena.dupe(u8, d);
    const out = try std.fmt.allocPrint(arena, "0x{s}", .{d});
    for (out[2..]) |*ch| ch.* = std.ascii.toUpper(ch.*);
    return out;
}

fn isHex(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |ch| if (!std.ascii.isHex(ch)) return false;
    return true;
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '@' or ch == '$' or ch == '#' or ch == '?' or ch == '!';
}

const size_words = [_][]const u8{ "byte", "word", "dword", "qword", "tbyte", "fword", "xmmword", "ymmword", "zmmword", "ptr", "far", "near", "short", "st" };

/// Registers, size words and the like, never numbers.
pub fn isReserved(word: []const u8) bool {
    var buf: [16]u8 = undefined;
    if (word.len > buf.len) return false;
    const lower = std.ascii.lowerString(&buf, word);
    for (size_words) |s| if (std.mem.eql(u8, s, lower)) return true;
    return tuft_asm.Register.parse(lower) != null;
}

pub fn isMnemonic(word: []const u8) bool {
    var buf: [24]u8 = undefined;
    if (word.len > buf.len) return false;
    return tuft_asm.Mnemonic.parse(std.ascii.lowerString(&buf, word)) != null;
}

const Mode = enum {
    /// An instruction's operands.
    code,
    /// `db`, `dw`, `dd` and `dq` values.
    data,
    /// Location text, like `game.exe+10`.
    address,
};

/// One CE statement with its numbers ours. `nop 3` becomes three nops, `(float)1.5` its bits.
pub fn asmStatement(arena: std.mem.Allocator, statement: []const u8, names: Names, notes: *Notes) ![]const u8 {
    const text = std.mem.trim(u8, statement, " \t");
    var i: usize = 0;
    var out: std.ArrayList(u8) = .empty;
    // Prefixes and the mnemonic are words, never numbers
    var mnemonic: []const u8 = "";
    while (i < text.len) {
        const start = i;
        while (i < text.len and isWordChar(text[i])) i += 1;
        const word = text[start..i];
        try out.appendSlice(arena, word);
        while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
        mnemonic = word;
        if (!isPrefix(word)) break;
        try out.append(arena, ' ');
    }
    if (std.ascii.eqlIgnoreCase(mnemonic, "nop") and i < text.len) {
        const count = parse(text[i..]) orelse return error.InvalidNumber;
        if (count < 1 or count > 64) return error.InvalidNumber;
        out.clearRetainingCapacity();
        for (0..@intCast(count)) |k| try out.appendSlice(arena, if (k == 0) "nop" else "; nop");
        return out.items;
    }
    if (i < text.len) try out.append(arena, ' ');
    const mode: Mode = if (isData(mnemonic)) .data else .code;
    try rewrite(arena, &out, try quoteModules(arena, text[i..]), mode, names, notes);
    return out.items;
}

fn isPrefix(word: []const u8) bool {
    for ([_][]const u8{ "lock", "rep", "repe", "repz", "repne", "repnz" }) |p| if (std.ascii.eqlIgnoreCase(word, p)) return true;
    return false;
}

pub fn isData(word: []const u8) bool {
    for ([_][]const u8{ "db", "dw", "dd", "dq" }) |d| if (std.ascii.eqlIgnoreCase(word, d)) return true;
    return false;
}

/// Location text with its numbers ours, like `[[base]+0x10]+8`.
pub fn address(arena: std.mem.Allocator, text: []const u8, names: Names, notes: *Notes) ![]const u8 {
    const quoted = try quoteModules(arena, std.mem.trim(u8, text, " \t"));
    var out: std.ArrayList(u8) = .empty;
    try rewrite(arena, &out, quoted, .address, names, notes);
    return out.items;
}

/// Quotes names like `Tales of X.exe`, since ours ends a name at spaces and dashes.
fn quoteModules(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    var copied: usize = 0;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '"' or ch == '\'') {
            i = (std.mem.indexOfScalarPos(u8, text, i + 1, ch) orelse (text.len - 1)) + 1;
            continue;
        }
        const ext = std.ascii.startsWithIgnoreCase(text[i..], ".exe") or std.ascii.startsWithIgnoreCase(text[i..], ".dll");
        if (!ext) {
            i += 1;
            continue;
        }
        var start = i;
        while (start > copied and isModuleChar(text[start - 1])) start -= 1;
        while (start < i and (text[start] == ' ' or text[start] == '-' or text[start] == '\t')) start += 1;
        var end = i + 4;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '_' or text[end] == '.')) end += 1;
        const module = text[start..end];
        const plain = for (module) |c| {
            if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '.') break false;
        } else true;
        if (!plain and (start == 0 or text[start - 1] != '"')) {
            try out.appendSlice(arena, text[copied..start]);
            try out.print(arena, "\"{s}\"", .{module});
            copied = end;
        }
        i = end;
    }
    if (copied == 0) return text;
    try out.appendSlice(arena, text[copied..]);
    return out.items;
}

fn isModuleChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '.' or ch == '-' or ch == ' ';
}

fn rewrite(arena: std.mem.Allocator, out: *std.ArrayList(u8), source: []const u8, mode: Mode, names: Names, notes: *Notes) !void {
    // `#-5` is `-#5`, the minus then a decimal
    const text = if (std.mem.indexOf(u8, source, "#-") != null) try std.mem.replaceOwned(u8, arena, source, "#-", "-#") else source;
    var i: usize = 0;
    // After `(float)`, CE reads the number as decimal
    var cast: ?enum { float, double } = null;
    var negative = false;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '"' or ch == '\'') {
            const end = std.mem.indexOfScalarPos(u8, text, i + 1, ch) orelse (text.len - 1);
            const inner = text[i + 1 .. end];
            // In code it's a number, like `'Z'` for 0x5A
            if (mode == .code and ch == '\'' and inner.len > 0 and inner.len <= 8) {
                var v: u64 = 0;
                var k = inner.len;
                while (k > 0) {
                    k -= 1;
                    v = (v << 8) | inner[k];
                }
                try out.print(arena, "0x{X}", .{v});
            } else try out.appendSlice(arena, text[i .. end + 1]);
            i = end + 1;
            continue;
        }
        if (ch == '(') {
            const casts = [_]struct { []const u8, @TypeOf(cast) }{ .{ "(float)", .float }, .{ "(double)", .double } };
            const found = for (casts) |c| {
                if (std.ascii.startsWithIgnoreCase(text[i..], c[0])) break c;
            } else null;
            if (found) |c| {
                cast = c[1];
                i += c[0].len;
                // Ours takes the casts in data, and in code it's the bits
                if (mode == .data) try out.appendSlice(arena, c[0]);
                while (i < text.len and text[i] == ' ') i += 1;
                if (i < text.len and text[i] == '-') {
                    negative = true;
                    i += 1;
                    if (mode == .data) try out.append(arena, '-');
                }
                continue;
            }
        }
        if (!isWordChar(ch)) {
            try out.append(arena, ch);
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and isWordChar(text[i])) i += 1;
        // `1.5e+3` doesn't come up, but `-1.5` does
        const word = text[start..i];
        if (cast) |c| {
            cast = null;
            var n = std.fmt.parseFloat(f64, if (word[0] == '#') word[1..] else word) catch return error.InvalidNumber;
            if (mode != .data and negative) n = -n;
            negative = false;
            if (mode == .data) {
                try out.print(arena, "{d}", .{n});
            } else if (c == .float) {
                try out.appendSlice(arena, try bits(arena, @as(u32, @bitCast(@as(f32, @floatCast(n))))));
            } else {
                try out.appendSlice(arena, try bits(arena, @bitCast(n)));
            }
            continue;
        }
        try out.appendSlice(arena, try word_(arena, word, mode, names, notes));
    }
}

fn word_(arena: std.mem.Allocator, word: []const u8, mode: Mode, names: Names, notes: *Notes) ![]const u8 {
    if (word[0] == '#') {
        const digits = word[1..];
        if (digits.len == 0) return error.InvalidNumber;
        // `#1.5` is a decimal float
        _ = std.fmt.parseFloat(f64, digits) catch return error.InvalidNumber;
        return digits;
    }
    if (word[0] == '$' and word.len > 1 and isHex(word[1..])) return hexText(arena, word[1..]);
    if (std.ascii.startsWithIgnoreCase(word, "0x") and word.len > 2 and isHex(word[2..])) return word;
    if (std.mem.indexOfScalar(u8, word, '.') != null) {
        // A float like `1.5` stays. Names like `game.exe` too
        if (std.ascii.isDigit(word[0])) {
            if (std.fmt.parseFloat(f64, word)) |_| return word else |_| {}
        }
        return name(arena, word, names, notes);
    }
    if (!isHex(word)) return name(arena, word, names, notes);
    if (isReserved(word)) return word;
    switch (names.find(word)) {
        .known => return word,
        .rename => |r| return r,
        .unknown => {},
    }
    // CE reads it as a number if no symbol matches, but a word like `dead` may have meant a name
    const letters = for (word) |ch| {
        if (std.ascii.isDigit(ch)) break false;
    } else true;
    if (letters and word.len >= 3) try notes.addAmbiguous(arena, word);
    _ = mode;
    return hexText(arena, word);
}

fn name(arena: std.mem.Allocator, word: []const u8, names: Names, notes: *Notes) ![]const u8 {
    if (isReserved(word)) return word;
    // CE's `r8l` is `r8b`
    if (word.len >= 3 and word.len <= 4 and std.ascii.toLower(word[0]) == 'r' and std.ascii.toLower(word[word.len - 1]) == 'l') {
        const n = std.fmt.parseInt(u8, word[1 .. word.len - 1], 10) catch 0;
        if (n >= 8 and n <= 15) return std.fmt.allocPrint(arena, "r{d}b", .{n});
    }
    switch (names.find(word)) {
        .known => return word,
        .rename => |r| return r,
        .unknown => {
            if (!isModule(word)) try notes.addUnknown(arena, word);
            return word;
        },
    }
}

pub fn isModule(word: []const u8) bool {
    var base = word;
    // `game.exe.text` is a section of it
    if (std.mem.indexOf(u8, base, ".exe")) |at| base = base[0 .. at + 4];
    if (std.mem.indexOf(u8, base, ".dll")) |at| base = base[0 .. at + 4];
    return std.ascii.endsWithIgnoreCase(base, ".exe") or std.ascii.endsWithIgnoreCase(base, ".dll");
}

/// CE aob text like `48 8B ** xx 05` as our pattern. Half bytes like `4?` widen to `??`.
pub fn pattern(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var digits: std.ArrayList(u8) = .empty;
    var out: std.ArrayList(u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t,");
    while (it.next()) |token| {
        // Space-separated tokens are a byte each, and without spaces it's two per byte
        if (token.len == 1) try digits.append(arena, '0');
        try digits.appendSlice(arena, token);
        if (digits.items.len % 2 != 0) return error.InvalidPattern;
    }
    var k: usize = 0;
    while (k < digits.items.len) : (k += 2) {
        const pair = digits.items[k .. k + 2];
        if (k > 0) try out.append(arena, ' ');
        const wild = for (pair) |ch| {
            if (ch == '?' or ch == '*' or ch == 'x' or ch == 'X') break true;
        } else false;
        if (wild) {
            try out.appendSlice(arena, "??");
        } else {
            if (!std.ascii.isHex(pair[0]) or !std.ascii.isHex(pair[1])) return error.InvalidPattern;
            try out.append(arena, std.ascii.toUpper(pair[0]));
            try out.append(arena, std.ascii.toUpper(pair[1]));
        }
    }
    if (out.items.len == 0) return error.InvalidPattern;
    return out.items;
}

const testing = std.testing;

const Fixture = struct {
    fn lookup(_: ?*const anyopaque, word: []const u8) Lookup {
        for ([_][]const u8{ "newmem", "bad", "GodMode", "code" }) |n| if (std.mem.eql(u8, n, word)) return .known;
        if (std.mem.eql(u8, word, "pBase")) return .{ .rename = "\"Cheats.pBase\"" };
        return .unknown;
    }
    const names: Names = .{ .lookup = lookup };
};

fn expectAsm(want: []const u8, ce: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var notes: Notes = .{};
    try testing.expectEqualStrings(want, try asmStatement(arena.allocator(), ce, Fixture.names, &notes));
}

test "asm numbers" {
    try expectAsm("mov eax, [rdi+0x290]", "mov eax, [rdi+00000290]");
    try expectAsm("mov eax,0x10", "mov eax,10");
    try expectAsm("mov eax,5", "mov eax,#5");
    try expectAsm("mov eax,12", "mov eax,#12");
    try expectAsm("mov r11d,-9999999", "mov r11d,#-9999999");
    try expectAsm("mov eax,9", "mov eax,9");
    try expectAsm("mov eax,0x7FFFFFFF", "mov eax,7FFFFFFF");
    try expectAsm("sub rsp,0x28", "sub rsp,$28");
    try expectAsm("mov [rbx-8],ecx", "mov [rbx-08],ecx");
    try expectAsm("mov rax,[rcx+rdx*8+0x10]", "mov rax,[rcx+rdx*8+10]");
    try expectAsm("cmp byte ptr [rax+0xA8],0", "cmp byte ptr [rax+A8],0");
    try expectAsm("lea rcx,[kai.exe+0x1234]", "lea rcx,[kai.exe+1234]");
    try expectAsm("jmp \"Tales of Arise.exe\"+0x4C43A30", "jmp \"Tales of Arise.exe\"+04C43A30");
    try expectAsm("mov [GodMode],1", "mov [GodMode],1");
    try expectAsm("mov rax,[\"Cheats.pBase\"]", "mov rax,[pBase]");
    try expectAsm("rep movsb", "rep movsb");
    try expectAsm("lock xadd [rcx],eax", "lock xadd [rcx],eax");
    try expectAsm("nop; nop; nop", "nop 3");
    try expectAsm("nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop; nop", "nop 10");
    try expectAsm("mov dword ptr [rax+0x10],0x42C80000", "mov dword ptr [rax+10],(float)100");
    try expectAsm("mov rax,0x3FF0000000000000", "mov rax,(double)1");
    try expectAsm("mov [rax],0xBF800000", "mov [rax],(float)-1");
    try expectAsm("mov rax,0xBFF0000000000000", "mov rax,(double)-1");
    try expectAsm("cmp [rax],0", "cmp [rax],(float)0.0");
    try expectAsm("dd (float)-1.5", "dd (float)-1.5");
    try expectAsm("cmp byte ptr [eax+0x91],0x5A", "cmp byte ptr [eax+91],'Z'");
    try expectAsm("dd (float)1.5", "dd (float)1.5");
    try expectAsm("dd (float)100", "dd (float)100");
    try expectAsm("db 0x90 0x90 0xEB", "db 90 90 EB");
    try expectAsm("db 0x48,0x8B,5", "db 48,8B,05");
    try expectAsm("dq 0", "dq 0");
    try expectAsm("db 'hi',0", "db 'hi',0");
    try expectAsm("movss xmm0,[rax+0x1C]", "movss xmm0,[rax+1C]");
    try expectAsm("fld st(1)", "fld st(1)");
    try expectAsm("mov [rsp+0x20],r14b", "mov [rsp+20],r14l");
}

test "words that look like hex" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var notes: Notes = .{};
    // Labels and registers stay, unknown hex words become numbers and get noted
    try testing.expectEqualStrings("jmp bad", try asmStatement(a, "jmp bad", Fixture.names, &notes));
    try testing.expectEqualStrings("add eax,0xADD", try asmStatement(a, "add eax,add", Fixture.names, &notes));
    try testing.expectEqualStrings("mov ah,0xFF", try asmStatement(a, "mov ah,FF", Fixture.names, &notes));
    try testing.expectEqualStrings("mov cl,dl", try asmStatement(a, "mov cl,dl", Fixture.names, &notes));
    try testing.expectEqualStrings("jmp code", try asmStatement(a, "jmp code", Fixture.names, &notes));
    try testing.expectEqualStrings("mov eax,0xBEEF", try asmStatement(a, "mov eax,BEEF", Fixture.names, &notes));
    try testing.expectEqualStrings("call somefunc", try asmStatement(a, "call somefunc", Fixture.names, &notes));
    try testing.expectEqualStrings("cmp eax,0xDEC", try asmStatement(a, "cmp eax,dec", Fixture.names, &notes));
    try testing.expectEqualStrings("mov al,0xC8", try asmStatement(a, "mov al,C8", Fixture.names, &notes));
    try testing.expectEqualStrings("mov eax,0xACE1", try asmStatement(a, "mov eax,ace1", Fixture.names, &notes));
    // Two letters is a byte, three or more with no digits could be a name
    try testing.expectEqual(3, notes.ambiguous.items.len);
    try testing.expectEqualStrings("add", notes.ambiguous.items[0]);
    try testing.expectEqualStrings("BEEF", notes.ambiguous.items[1]);
    try testing.expectEqualStrings("dec", notes.ambiguous.items[2]);
    try testing.expectEqualStrings("somefunc", notes.unknown.items[0]);
    try testing.expectError(error.InvalidNumber, asmStatement(a, "mov eax,#", Fixture.names, &notes));
}

test "addresses" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var notes: Notes = .{};
    try testing.expectEqualStrings("kai.exe+0xD600A8", try address(a, "kai.exe+d600a8", Fixture.names, &notes));
    try testing.expectEqualStrings("\"name.exe\"+0x1234", try address(a, "\"name.exe\"+1234", Fixture.names, &notes));
    try testing.expectEqualStrings("[[GodMode]+0x10]+8", try address(a, "[[GodMode]+10]+8", Fixture.names, &notes));
    try testing.expectEqualStrings("+0x297990", try address(a, "+297990", Fixture.names, &notes));
    try testing.expectEqualStrings("-8", try address(a, "-8", Fixture.names, &notes));
    try testing.expectEqualStrings("\"Tales of Zestiria.exe\"+0x1D3030B", try address(a, "Tales of Zestiria.exe+1D3030B", Fixture.names, &notes));
    try testing.expectEqualStrings("[\"Cheats.pBase\"]+0x3C", try address(a, "[pBase]+3C", Fixture.names, &notes));
    try testing.expectEqualStrings("0x3AA00A0", try address(a, "03AA00A0", Fixture.names, &notes));
    try testing.expectEqualStrings("\"Game-Win64-Shipping.exe\"+0x50A6725", try address(a, "Game-Win64-Shipping.exe+50A6725", Fixture.names, &notes));
    try testing.expectEqualStrings("[\"My Game.exe\"+0x10]+8", try address(a, "[My Game.exe+10]+8", Fixture.names, &notes));
    try testing.expectEqual(0, notes.unknown.items.len);
    try testing.expectEqual(-0x10, parse("-10").?);
    try testing.expectEqual(10, parse("#10").?);
    try testing.expectEqual(null, parse("x"));
}

test "aob patterns" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("7C ?? 48 8B", try pattern(a, "7C??488B"));
    try testing.expectEqualStrings("48 8B ?? ?? 05", try pattern(a, "48 8b ** xx 05"));
    try testing.expectEqualStrings("0F ??", try pattern(a, "0F 4?"));
    try testing.expectEqualStrings("0F 04", try pattern(a, "0F 4"));
    try testing.expectError(error.InvalidPattern, pattern(a, "0F4"));
}
