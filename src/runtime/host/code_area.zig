//! The `Addresses` and `Code` areas. Patches and injects are host objects, so they go with the plugin.

const std = @import("std");

const api = @import("wraith_api");
const disasm = @import("tuft_asm").disasm;
const mem = @import("tuft_mem");

const host = @import("root.zig");
const scratch = @import("scratch.zig");
const wraith = @import("wraith.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;
pub const Addresses = W.Addresses;
pub const Code = W.Code;
pub const Patch = W.Patch;
const SalName = W.Addresses.Name;

const allocator = std.heap.page_allocator;
const local = mem.Memory.local;
const max_asm = 4096;

/// Patch and inject functions take a `Loaded` they never look at.
const nobody: *Loaded = undefined;

fn explain(err: anytype, comptime fmt: []const u8, args: anytype) @TypeOf(err) {
    return sal.host().explain(err, fmt, args);
}

/// `names` as the API's, pointing into them, in `a`.
fn namesOf(a: std.mem.Allocator, names: []const SalName) error{OutOfMemory}![]api.Name {
    const out = try a.alloc(api.Name, names.len);
    for (names, out) |n, *o| o.* = .of(n.name, n.address);
    return out;
}

// Addresses

fn addressError(err: anyerror) error{ NotFound, Unreadable, InvalidAddress, InvalidId, AlreadyAdded, Failed } {
    return switch (err) {
        error.NotFound => error.NotFound,
        error.Unreadable => error.Unreadable,
        error.InvalidAddress => error.InvalidAddress,
        error.InvalidId => error.InvalidId,
        error.AlreadyAdded => error.AlreadyAdded,
        else => error.Failed,
    };
}

pub const AddressesImpl = struct {
    pub fn get(loaded: *Loaded, id: []const u8) sal.Plain(Addresses, "get") {
        return host.addresses.get(loaded, id) catch |err| addressError(err);
    }

    pub fn resolve(loaded: *Loaded, text: []const u8, names: []const SalName) sal.Plain(Addresses, "resolve") {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const scope = namesOf(arena.allocator(), names) catch return error.Failed;
        var problem: api.LocationProblem = .{};
        return host.addresses.resolve(loaded, text, scope, &problem) catch |err| {
            const e = addressError(err);
            if (problem.message().len == 0) return e;
            return explain(e, "{s}", .{problem.message()});
        };
    }

    pub fn add(loaded: *Loaded, entry: W.Addresses.Entry) sal.Plain(Addresses, "add") {
        host.addresses.add(loaded, .{
            .id = entry.id,
            .address = entry.address,
            .offsets = entry.offsets,
            .name = entry.name,
            .type = entry.type,
            .size = entry.size,
        }) catch |err| return addressError(err);
    }

    pub fn remove(loaded: *Loaded, id: []const u8) void {
        host.addresses.remove(loaded, id);
    }

    pub fn find(loaded: *Loaded, text: []const u8, names: []const SalName) sal.Plain(Addresses, "find") {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const scope = namesOf(arena.allocator(), names) catch return error.Failed;
        var problem: api.LocationProblem = .{};
        const found = host.addresses.find(loaded, text, scope, &problem) catch |err| {
            const e = addressError(err);
            if (problem.message().len == 0) return e;
            return explain(e, "{s}", .{problem.message()});
        };
        return .{ .address = found.address, .source = switch (found.source) {
            .live => .live,
            .snapshot => .snapshot,
            .disk => .disk,
        } };
    }

    pub fn setSources(loaded: *Loaded, allowed: W.Addresses.Sources) void {
        host.addresses.setSources(loaded, .{ .live = allowed.live, .snapshot = allowed.snapshot, .disk = allowed.disk });
    }

    pub fn activeSources(loaded: *Loaded) W.Addresses.Sources {
        const s = host.addresses.sourcesOf(loaded) orelse @import("../Names.zig").defaultSources();
        return .{ .live = s.live, .snapshot = s.snapshot, .disk = s.disk };
    }
};

// Code

const CodeError = error{ InvalidAsm, TooLong, Unreadable, UnexpectedBytes, InvalidPattern, AlreadyHooked, TargetModified, SplitsInstruction, OutOfReach, InvalidInstruction, Failed };

fn codeError(err: anyerror) CodeError {
    return switch (err) {
        error.InvalidAsm => error.InvalidAsm,
        error.TooLong => error.TooLong,
        error.Unreadable => error.Unreadable,
        error.UnexpectedBytes => error.UnexpectedBytes,
        error.InvalidPattern => error.InvalidPattern,
        error.AlreadyHooked => error.AlreadyHooked,
        error.TargetModified => error.TargetModified,
        error.SplitsInstruction => error.SplitsInstruction,
        error.OutOfReach => error.OutOfReach,
        error.InvalidInstruction => error.InvalidInstruction,
        else => error.Failed,
    };
}

/// `err`, with what the asm or expect said, by line when it has one.
fn asmFailed(err: anyerror, problem: *const api.AsmProblem) CodeError {
    const e = codeError(err);
    const message = problem.message();
    if (message.len == 0) return e;
    if (problem.line > 0) return explain(e, "line {d}: {s}", .{ problem.line, message });
    return explain(e, "{s}", .{message});
}

/// On unless asked not to. Gone again if turning it on fails.
fn patchMade(loaded: *Loaded, p: *api.Patch, disabled: bool) sal.Plain(Code, "patch") {
    const t = wraith.tablesOf(loaded) orelse {
        host.code.patchDestroy(nobody, p);
        return error.Failed;
    };
    if (!disabled) host.code.patchEnable(nobody, p) catch |err| {
        host.code.patchDestroy(nobody, p);
        return codeError(err);
    };
    return .init(p, t.patch);
}

pub const CodeImpl = struct {
    pub fn assemble(loaded: *Loaded, source: []const u8, address: usize) sal.Plain(Code, "assemble") {
        const buf = scratch.begin().alloc(u8, max_asm) catch return error.Failed;
        var problem: api.AsmProblem = .{};
        const n = host.code.assemble(loaded, source, address, buf, &problem) catch |err| return asmFailed(err, &problem);
        return buf[0..n];
    }

    pub fn patch(loaded: *Loaded, target: usize, source: []const u8, options: W.Patch.Options) sal.Plain(Code, "patch") {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const names = namesOf(arena.allocator(), options.names) catch return error.Failed;
        var problem: api.AsmProblem = .{};
        const p = host.code.patchAsm(loaded, target, source, .{ .size = options.size, .expect = options.expect, .names = names }, &problem) catch |err| return asmFailed(err, &problem);
        return patchMade(loaded, p, options.disabled);
    }

    pub fn patchBytes(loaded: *Loaded, target: usize, bytes: []const u8, options: W.Patch.Options) sal.Plain(Code, "patchBytes") {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const names = namesOf(arena.allocator(), options.names) catch return error.Failed;
        const p = host.code.patch(loaded, target, bytes, .{ .expect = options.expect, .names = names }) catch |err| return codeError(err);
        return patchMade(loaded, p, options.disabled);
    }

    pub fn inject(loaded: *Loaded, target: usize, source: []const u8, options: W.Patch.Options) sal.Plain(Code, "inject") {
        const t = wraith.tablesOf(loaded) orelse return error.Failed;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const names = namesOf(arena.allocator(), options.names) catch return error.Failed;
        var problem: api.AsmProblem = .{};
        const h = host.hooks.createInject(loaded, target, source, .{ .names = names }, &problem) catch |err| return asmFailed(err, &problem);
        if (!options.disabled) host.hooks.enable(nobody, h) catch |err| {
            host.hooks.destroy(nobody, h);
            return codeError(err);
        };
        return .init(h, t.inject);
    }

    pub fn alloc(loaded: *Loaded, size: u32, near: usize) sal.Plain(Code, "alloc") {
        return host.code.alloc(loaded, size, near) catch |err| codeError(err);
    }

    pub fn free(loaded: *Loaded, address: usize) void {
        host.code.free(loaded, address);
    }

    pub fn place(loaded: *Loaded, request: W.Code.PlaceRequest) sal.Plain(Code, "place") {
        const t = wraith.tablesOf(loaded) orelse return error.Failed;
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const data_in = request.data;
        const code_in = request.code;
        const data = a.alloc(api.PlaceData, data_in.len) catch return error.Failed;
        for (data_in, data) |d, *out| {
            const names = a.alloc(api.Name, d.names.len) catch return error.Failed;
            for (d.names, names) |n, *o| o.* = .of(n.name, n.offset);
            out.* = .of(d.size, names);
            if (d.alignment > 0) out.alignment = d.alignment;
        }
        const code = a.alloc(api.PlaceCode, code_in.len) catch return error.Failed;
        for (code_in, code) |c, *out| out.* = .of(c.target, c.source, .{
            .inject = c.inject,
            .size = c.size,
            .expect = c.expect,
            .names = namesOf(a, c.names) catch return error.Failed,
        });

        const out = scratch.begin();
        const data_out = out.alloc(usize, data.len) catch return error.Failed;
        const made = a.alloc(*api.Patch, code.len) catch return error.Failed;
        const patches = out.alloc(sal.Object(Patch), code.len) catch return error.Failed;
        var problem: api.PlaceProblem = .{};
        host.code.place(loaded, .{ .near = request.near, .data = data, .code = code }, data_out, made, &problem) catch |err| {
            if (!problem.failed) {
                if (err == error.OutOfReach) return explain(error.OutOfReach, "no room for {d} bytes of code and data together", .{problem.bytes});
                return codeError(err);
            }
            const e = codeError(err);
            const p = &problem.problem;
            if (p.message().len == 0) return explain(e, "code {d}", .{problem.index + 1});
            if (p.line > 0) return explain(e, "code {d}, line {d}: {s}", .{ problem.index + 1, p.line, p.message() });
            return explain(e, "code {d}: {s}", .{ problem.index + 1, p.message() });
        };
        for (made, patches) |p, *o| o.* = .init(p, t.patch);
        return .{ .data = data_out, .code = patches };
    }

    pub fn disassemble(_: *Loaded, address: usize, count: u32) sal.Plain(Code, "disassemble") {
        const a = scratch.begin();
        const out = a.alloc(W.Code.Instruction, @min(@max(count, 1), 4096)) catch return error.Failed;
        var at = address;
        for (out, 0..) |*o, i| {
            var buf: [disasm.max_len]u8 = undefined;
            const n = readUpTo(at, &buf);
            const insn = (if (n == 0) null else disasm.decode(buf[0..n], at)) orelse {
                if (i > 0) return out[0..i];
                return if (n == 0 or n < buf.len) error.Unreadable else error.InvalidInstruction;
            };
            const bytes = a.dupe(u8, buf[0..insn.len]) catch return error.Failed;
            const text = a.dupe(u8, insn.text()) catch return error.Failed;
            o.* = .{ .address = at, .length = insn.len, .bytes = bytes, .text = text };
            at +%= insn.len;
        }
        return out;
    }

    pub fn instructionLength(_: *Loaded, address: usize) sal.Plain(Code, "instructionLength") {
        var buf: [disasm.max_len]u8 = undefined;
        const n = readUpTo(address, &buf);
        if (n == 0) return error.Unreadable;
        return disasm.length(buf[0..n]) orelse if (n < buf.len) error.Unreadable else error.InvalidInstruction;
    }
};

/// As much as is readable, which stops at a page that isn't.
fn readUpTo(at: usize, out: []u8) usize {
    if (local.read(at, out)) |_| return out.len else |_| {}
    const to_page = @min(out.len, std.heap.page_size_min - at % std.heap.page_size_min);
    local.read(at, out[0..to_page]) catch return 0;
    return to_page;
}

/// Patches made by `patch`, `patchBytes` and `place`.
pub const PatchImpl = struct {
    pub fn enable(p: *api.Patch) sal.Plain(Patch, "enable") {
        host.code.patchEnable(nobody, p) catch |err| return codeError(err);
    }

    pub fn disable(p: *api.Patch) sal.Plain(Patch, "disable") {
        host.code.patchDisable(nobody, p) catch |err| return codeError(err);
    }

    pub fn destroy(p: *api.Patch) void {
        host.code.patchDestroy(nobody, p);
    }
};

/// Injects, which are hooks underneath.
pub const InjectImpl = struct {
    pub fn enable(h: *api.Hook) sal.Plain(Patch, "enable") {
        host.hooks.enable(nobody, h) catch |err| return codeError(err);
    }

    pub fn disable(h: *api.Hook) sal.Plain(Patch, "disable") {
        host.hooks.disable(nobody, h) catch |err| return codeError(err);
    }

    pub fn destroy(h: *api.Hook) void {
        host.hooks.destroy(nobody, h);
    }
};

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const engine = @import("tuft_hook");
    const Names = @import("../Names.zig");

    noinline fn seven() callconv(.c) u32 {
        var x: u32 = 7;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x;
    }

    noinline fn eight() callconv(.c) u32 {
        var x: u32 = 8;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x;
    }

    fn start(loaded: *Loaded) void {
        loaded.initForTest(testing.allocator, "kai");
        sdk.Owner.attach(loaded.root());
    }

    fn stop(loaded: *Loaded) void {
        loaded.deinitForTest();
        wraith.forget(loaded);
        sdk.Owner.detach();
    }

    test "addresses, with why they don't resolve" {
        Names.global = .init(testing.allocator);
        defer Names.global.deinit();
        var loaded: Loaded = undefined;
        start(&loaded);
        defer stop(&loaded);
        const list = sdk.wraith.root().?.addresses();

        var value: u32 = 5;
        var buf: [32]u8 = undefined;
        try list.add(.{ .id = "hp", .address = try std.fmt.bufPrint(&buf, "0x{x}", .{@intFromPtr(&value)}), .type = "u32" });
        try testing.expectError(error.AlreadyAdded, list.add(.{ .id = "hp", .address = "0x1" }));
        try testing.expectError(error.InvalidId, list.add(.{ .id = "h p", .address = "0x1" }));
        try testing.expectEqual(@intFromPtr(&value), try list.get("kai.hp"));

        const names = [_]SalName{.{ .name = "mine", .address = 0x40 }};
        try testing.expectEqual(0x48, try list.resolve("mine + 8", &names));
        try testing.expectError(error.InvalidAddress, list.resolve("nobody", &.{}));
        try testing.expectEqualStrings("there's no nobody", sal.host().explanation("InvalidAddress"));
        list.remove("hp");
        try testing.expectError(error.NotFound, list.get("kai.hp"));
    }

    test "code: asm, patches, injects and memory, all put back" {
        try engine.init(testing.allocator);
        defer engine.deinit();
        var loaded: Loaded = undefined;
        start(&loaded);
        const code = sdk.wraith.root().?.code();

        // Copied, since the next call that gives something back reuses it
        var bytes_buf: [6]u8 = undefined;
        const bytes = &bytes_buf;
        @memcpy(bytes, try code.assemble("mov eax, 1\nret", 0x1000));
        try testing.expectEqualSlices(u8, &.{ 0xB8, 1, 0, 0, 0, 0xC3 }, bytes);
        try testing.expectError(error.InvalidAsm, code.assemble("nop\nmvo eax, 1", 0x1000));
        try testing.expect(std.mem.startsWith(u8, sal.host().explanation("InvalidAsm"), "line 2: "));

        const listed = try code.disassemble(@intFromPtr(bytes.ptr), 2);
        try testing.expectEqual(2, listed.len);
        try testing.expectEqualStrings("mov eax, 0x1", listed[0].text);
        try testing.expectEqual(5, listed[0].length);
        try testing.expectEqualStrings("ret", listed[1].text);
        try testing.expectEqual(1, try code.instructionLength(@intFromPtr(bytes.ptr) + 5));
        try testing.expectError(error.Unreadable, code.disassemble(0x10, 1));

        const p = try code.patch(@intFromPtr(&seven), "mov eax, 42\nret", .{});
        try testing.expectEqual(42, seven());
        try p.disable();
        try testing.expectEqual(7, seven());
        try p.enable();
        try testing.expectEqual(42, seven());

        const inj = try code.inject(@intFromPtr(&eight), "mov eax, 99\nret", .{ .disabled = true });
        try testing.expectEqual(8, eight());
        try inj.enable();
        try testing.expectEqual(99, eight());

        const block = try code.alloc(64, @intFromPtr(&seven));
        try testing.expect(block != 0);

        // Everything goes back with the plugin, and the objects stop working
        stop(&loaded);
        try testing.expectEqual(7, seven());
        try testing.expectEqual(8, eight());
        try testing.expectError(error.Gone, p.enable());
    }

    test "place puts data by the code that reads it" {
        try engine.init(testing.allocator);
        defer engine.deinit();
        var loaded: Loaded = undefined;
        start(&loaded);
        defer stop(&loaded);
        const code = sdk.wraith.root().?.code();

        const names = [_]W.Code.PlaceName{.{ .name = "value", .offset = 0 }};
        const data = [_]W.Code.PlaceData{.{ .size = 4, .names = &names }};
        const patches = [_]W.Code.PlaceCode{.{ .target = @intFromPtr(&seven), .source = "mov eax, [value]\nret" }};
        const placed = try code.place(.{ .data = &data, .code = &patches });
        try testing.expectEqual(1, placed.data.len);
        try testing.expectEqual(1, placed.code.len);
        const at: *u32 = @ptrFromInt(placed.data[0]);
        at.* = 1234;
        try placed.code[0].enable();
        try testing.expectEqual(1234, seven());

        const bad = [_]W.Code.PlaceCode{.{ .target = @intFromPtr(&eight), .source = "nop\nbogus" }};
        try testing.expectError(error.InvalidAsm, code.place(.{ .code = &bad }));
        try testing.expect(std.mem.startsWith(u8, sal.host().explanation("InvalidAsm"), "code 1, line 2: "));
    }
};

test {
    _ = tests;
}
