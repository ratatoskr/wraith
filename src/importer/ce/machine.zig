//! Reading and checking code with tuft's assembler. What restore bytes were, whether a script's
//! copy of them is the same code, and whether what we wrote assembles.

const std = @import("std");
const tuft_asm = @import("tuft_asm");

pub const Bits = enum {
    x86,
    x64,

    pub fn native() Bits {
        return if (tuft_asm.is64) .x64 else .x86;
    }

    /// Where a module's made-up base is, for comparing code that uses its name.
    pub fn base(self: Bits) u64 {
        return if (self == .x64) 0x1_4000_0000 else 0x40_0000;
    }
};

pub const Insn = struct {
    text: []const u8,
    len: u8,
    /// Its bytes depend on where it is, like a jump or `[rip+x]`.
    relative: bool,
};

/// `bytes` as instructions, as if at `address`. Null if they don't all decode.
pub fn decode(arena: std.mem.Allocator, bytes: []const u8, bits: Bits, address: u64) !?[]const Insn {
    var out: std.ArrayList(Insn) = .empty;
    var at: usize = 0;
    while (at < bytes.len) {
        const insn = tuft_asm.disasm.decodeWith(bytes[at..], @truncate(address + at), .{ .mode = if (bits == .x64) .x64 else .x86 }) orelse return null;
        try out.append(arena, .{
            .text = try arena.dupe(u8, insn.text()),
            .len = insn.len,
            .relative = insn.branch_target != null or insn.ip_relative != null,
        });
        at += insn.len;
    }
    return out.items;
}

/// What a name is worth when comparing, like a module's made-up base.
pub const Resolve = struct {
    context: ?*const anyopaque = null,
    func: *const fn (context: ?*const anyopaque, name: []const u8) ?u64 = nothing,

    fn nothing(_: ?*const anyopaque, _: []const u8) ?u64 {
        return null;
    }
};

/// Whether each of `ours` is the same instruction as `theirs`, any spelling. Both are our asm.
pub fn same(gpa: std.mem.Allocator, ours: []const []const u8, theirs: []const []const u8, resolve: Resolve) bool {
    if (ours.len != theirs.len or ours.len == 0) return false;
    for (ours, theirs) |a, b| {
        var x: tuft_asm.Block = .init(gpa);
        defer x.deinit();
        var y: tuft_asm.Block = .init(gpa);
        defer y.deinit();
        const i = one(&x, a) orelse return false;
        const j = one(&y, b) orelse return false;
        if (!sameInsn(i, j, resolve)) return false;
    }
    return true;
}

fn one(block: *tuft_asm.Block, text: []const u8) ?tuft_asm.Instruction {
    block.parse(text, null) catch return null;
    if (block.items.items.len != 1) return null;
    return switch (block.items.items[0].kind) {
        .instruction => |i| i,
        else => null,
    };
}

fn sameInsn(a: tuft_asm.Instruction, b: tuft_asm.Instruction, resolve: Resolve) bool {
    if (a.mnemonic.id != b.mnemonic.id or a.operand_count != b.operand_count or a.far != b.far) return false;
    if (!std.meta.eql(a.prefixes, b.prefixes)) return false;
    var width: u16 = 64;
    for (a.ops()) |op| if (op == .reg) {
        width = op.reg.bits();
        break;
    };
    for (a.ops(), b.ops()) |x, y| {
        if (std.meta.activeTag(x) != std.meta.activeTag(y)) return false;
        switch (x) {
            .reg => |r| if (!r.eql(y.reg)) return false,
            .ptr => |p| if (p.segment != y.ptr.segment or p.offset != y.ptr.offset) return false,
            .imm => |v| {
                const size = if (y.imm.name == null and v.name == null) width else 64;
                if (!sameValue(v, y.imm, size, resolve)) return false;
            },
            .mem => |m| {
                const n = y.mem;
                if (m.size != 0 and n.size != 0 and m.size != n.size) return false;
                if (!sameReg(m.segment, n.segment) or !sameReg(m.base, n.base) or !sameReg(m.index, n.index)) return false;
                if (m.index != null and m.scale != n.scale) return false;
                if (!sameValue(m.disp, n.disp, 64, resolve) and !sameValue(m.disp, n.disp, 32, resolve)) return false;
            },
        }
    }
    return true;
}

fn sameReg(a: ?tuft_asm.Register, b: ?tuft_asm.Register) bool {
    if (a == null or b == null) return a == null and b == null;
    return a.?.eql(b.?);
}

fn sameValue(a: tuft_asm.Value, b: tuft_asm.Value, bits: u16, resolve: Resolve) bool {
    const x = valueOf(a, resolve) orelse return false;
    const y = valueOf(b, resolve) orelse return false;
    const mask: u64 = if (bits >= 64) std.math.maxInt(u64) else (@as(u64, 1) << @intCast(bits)) - 1;
    return x & mask == y & mask;
}

fn valueOf(v: tuft_asm.Value, resolve: Resolve) ?u64 {
    const base: u64 = if (v.name) |n| resolve.func(resolve.context, n) orelse return null else 0;
    return base +% @as(u64, @bitCast(v.offset));
}

pub const Problem = struct {
    line: u32,
    message: []const u8,
};

/// Which names code can use besides its own labels, like a tweak's `@data` and `original`.
pub const Known = struct {
    context: ?*const anyopaque = null,
    func: *const fn (context: ?*const anyopaque, name: []const u8) bool = any,

    fn any(_: ?*const anyopaque, _: []const u8) bool {
        return true;
    }
};

/// Whether `source` assembles, with each name `known` takes somewhere near it. Only for code of
/// our own bits, since the assembler's are fixed.
pub fn check(arena: std.mem.Allocator, source: []const u8, bits: Bits, known: Known) !?Problem {
    if (bits != Bits.native()) return null;
    var diagnostic: tuft_asm.Diagnostic = .{};
    var stub: Stub = .{ .known = known };
    var code = tuft_asm.assemble(arena, source, .{ .address = Stub.code_at, .resolver = stub.resolver() }, &diagnostic) catch |err| {
        const message = if (diagnostic.message().len > 0) diagnostic.message() else @errorName(err);
        return .{ .line = diagnostic.line, .message = try arena.dupe(u8, message) };
    };
    code.deinit(arena);
    return null;
}

/// How many bytes `source` assembles to, or null if it doesn't or isn't our bits.
pub fn length(arena: std.mem.Allocator, source: []const u8, bits: Bits) !?usize {
    if (bits != Bits.native()) return null;
    var stub: Stub = .{};
    var code = tuft_asm.assemble(arena, source, .{ .address = Stub.code_at, .resolver = stub.resolver() }, null) catch return null;
    defer code.deinit(arena);
    return code.bytes.len;
}

/// Names a little apart in the made-up module, so x64 code reaches them all.
const Stub = struct {
    known: Known = .{},
    next: usize = 0,

    const code_at: usize = @truncate(Bits.native().base() + 0x1000);

    fn resolve(context: ?*anyopaque, name: []const u8) ?usize {
        const self: *Stub = @ptrCast(@alignCast(context.?));
        if (!self.known.func(self.known.context, name)) return null;
        self.next += 0x10;
        return @truncate(Bits.native().base() + 0x8000 + self.next);
    }

    fn resolver(self: *Stub) tuft_asm.Resolver {
        return .{ .context = self, .resolve = resolve };
    }
};

const testing = std.testing;

test "decoding either bits" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const x64 = (try decode(a, &.{ 0x41, 0x80, 0x38, 0x00, 0x49, 0x8B, 0xC0 }, .x64, 0x1000)).?;
    try testing.expectEqualStrings("cmp byte ptr [r8], 0x0", x64[0].text);
    try testing.expectEqualStrings("mov rax, r8", x64[1].text);
    const x86 = (try decode(a, &.{ 0x40, 0x75, 0x02 }, .x86, 0x1000)).?;
    try testing.expectEqualStrings("inc eax", x86[0].text);
    try testing.expect(x86[1].relative);
    try testing.expectEqual(null, try decode(a, &.{0xE8}, .x64, 0));
}

test "checking code with only the names it knows" {
    if (Bits.native() != .x64) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Names = struct {
        fn known(_: ?*const anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "flag") or std.mem.eql(u8, name, "resume");
        }
    };
    const names: Known = .{ .func = Names.known };
    try testing.expectEqual(null, try check(a, "cmp dword ptr [flag],1\njne resume\nmov eax,[flag]", .x64, names));
    const problem = (try check(a, "nop\nmov eax,[nothing]", .x64, names)).?;
    try testing.expectEqual(2, problem.line);
    try testing.expectEqual(11, (try length(a, "mov dword ptr [rbx+rcx*4+0x470C],1", .x64)).?);
}

test "same code, any spelling" {
    const g = testing.allocator;
    try testing.expect(same(g, &.{"mov [rbx+0x98],eax"}, &.{"mov dword ptr [rbx+0x98], eax"}, .{}));
    try testing.expect(same(g, &.{"je 0x1010"}, &.{"jz 0x1010"}, .{}));
    try testing.expect(same(g, &.{"add eax,-8"}, &.{"add eax, 0xfffffff8"}, .{}));
    try testing.expect(same(g, &.{"mov eax,[rcx-8]"}, &.{"mov eax, dword ptr [rcx-0x8]"}, .{}));
    try testing.expect(!same(g, &.{"mov byte ptr [rbx+0x98],1"}, &.{"mov dword ptr [rbx+0x98], 0x1"}, .{}));
    try testing.expect(!same(g, &.{"mov [rbx+0x98],ecx"}, &.{"mov dword ptr [rbx+0x98], eax"}, .{}));
    try testing.expect(!same(g, &.{"call somewhere"}, &.{"call 0x1234"}, .{}));
    const Modules = struct {
        fn resolve(_: ?*const anyopaque, name: []const u8) ?u64 {
            return if (std.mem.eql(u8, name, "game.exe")) 0x1000 else null;
        }
    };
    try testing.expect(same(g, &.{"call game.exe+0x234"}, &.{"call 0x1234"}, .{ .func = Modules.resolve }));
}
