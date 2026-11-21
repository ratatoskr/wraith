//! Assembling, patches and memory for owners.

const std = @import("std");

const core = @import("wraith_core");
const tuft_asm = @import("tuft_asm");
const arch = @import("tuft_arch");
const engine = @import("tuft_hook");
const mem = @import("tuft_mem");
const api = @import("wraith_api");

const host = @import("root.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;
const GameNames = @import("../Names.zig");
const addresses = @import("addresses.zig");

const log = core.log.scoped(.wraith_runtime);

/// Names asm can use besides labels: the caller's own, then what its owner sees through
/// `addresses.Scope`, then the game's from `Names`, modules and their exports.
pub const Names = struct {
    loaded: ?*Loaded = null,
    original: ?usize = null,
    resume_at: ?usize = null,
    /// It asked for `original` and there wasn't one.
    missing_original: bool = false,
    scope: []const api.Name = &.{},
    /// Data `place` is placing, whose names come first.
    pending: ?*const Pending = null,
    /// Where the code's going, which pending data that isn't placed yet goes right by.
    stand_in: usize = 0,

    fn resolve(context: ?*anyopaque, name: []const u8) ?usize {
        const self: *Names = @ptrCast(@alignCast(context.?));
        if (std.mem.eql(u8, name, "original")) {
            if (self.original == null) self.missing_original = true;
            return self.original;
        }
        if (self.resume_at) |at| if (std.mem.eql(u8, name, "resume")) return at;
        if (self.pending) |p| if (p.find(name, self.stand_in)) |at| return at;
        const scope: addresses.Scope = .{ .loaded = self.loaded, .names = self.scope };
        return scope.resolve(name) orelse GameNames.global.symbols().resolve(name);
    }

    pub fn resolver(self: *Names) tuft_asm.Resolver {
        return .{ .context = self, .resolve = resolve };
    }
};

pub fn assembleWith(gpa: std.mem.Allocator, source: []const u8, address: usize, out: []u8, names: *Names, problem: *api.AsmProblem) api.AsmError!usize {
    var diagnostic: tuft_asm.Diagnostic = .{};
    return tuft_asm.assembleInto(gpa, source, out, .{ .address = address, .resolver = names.resolver() }, &diagnostic) catch |err| {
        problem.set(diagnostic.line, if (diagnostic.message().len > 0) diagnostic.message() else @errorName(err));
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.TooLong => error.TooLong,
            else => error.InvalidAsm,
        };
    };
}

pub fn assemble(loaded: *Loaded, source: []const u8, address: usize, out: []u8, problem: *api.AsmProblem) api.AsmError!usize {
    var names: Names = .{ .loaded = loaded };
    return assembleWith(loaded.allocator, source, address, out, &names, problem);
}

/// The names in `scope` that are data we placed, which code using them has to reach.
pub fn reachOf(scope: []const api.Name, out: []usize) []usize {
    var n: usize = 0;
    for (scope) |name| {
        if (n == out.len) break;
        if (!mem.Placement.holds(name.address)) continue;
        out[n] = name.address;
        n += 1;
    }
    return out[0..n];
}

/// The data `place` is placing, by its names.
pub const Pending = struct {
    data: []const api.PlaceData,
    placed: []const mem.Placement,

    /// Right by `stand_in` till it's placed.
    pub fn find(self: *const Pending, name: []const u8, stand_in: usize) ?usize {
        for (self.data, self.placed) |d, p| {
            const offset = api.Name.find(d.names(), name) orelse continue;
            return (if (p.data.len > 0) @intFromPtr(p.data.ptr) else stand_in) + offset;
        }
        return null;
    }
};

/// Assembles for `engine.Patch.replace`, which tries it in place first.
pub const Build = struct {
    gpa: std.mem.Allocator,
    source: []const u8,
    problem: *api.AsmProblem,
    loaded: ?*Loaded = null,
    scope: []const api.Name = &.{},
    pending: ?*const Pending = null,
    /// A real problem, not just not fitting in place.
    failed: ?api.AsmError = null,

    pub fn run(context: ?*anyopaque, site: engine.Hook.InjectSite, out: []u8) anyerror!usize {
        const self: *Build = @ptrCast(@alignCast(context.?));
        var names: Names = .{ .loaded = self.loaded, .original = site.original, .resume_at = site.resume_at, .scope = self.scope, .pending = self.pending, .stand_in = site.code };
        return assembleWith(self.gpa, self.source, site.code, out, &names, self.problem) catch |err| {
            if (site.trial) return err;
            if (site.original == null and (names.missing_original or err == error.TooLong)) return error.NeedsCave;
            // Like `[data]` that's too far from the game's code, so it moves out to sit by it
            if (site.original == null and err == error.InvalidAsm and std.mem.startsWith(u8, self.problem.message(), "can't encode")) return error.NeedsCave;
            self.failed = err;
            return err;
        };
    }

    pub fn of(self: *Build) engine.Hook.InjectBuild {
        return .{ .context = self, .build = run };
    }
};

const PatchRecord = struct {
    engine: union(enum) {
        in_place: *engine.Patch,
        cave: *engine.Hook,
    },
    loaded: *Loaded,
    destroyed: bool = false,

    fn of(p: *api.Patch) *PatchRecord {
        return @ptrCast(@alignCast(p));
    }

    fn address(self: *const PatchRecord) usize {
        return switch (self.engine) {
            .in_place => |p| p.address,
            .cave => |h| h.target_addr,
        };
    }

    pub fn stop(self: *PatchRecord) void {
        if (self.destroyed) return;
        switch (self.engine) {
            .in_place => |p| p.destroy(),
            .cave => |h| h.destroy(),
        }
        self.destroyed = true;
    }

    pub fn free(self: *PatchRecord) void {
        self.stop();
        self.loaded.allocator.destroy(self);
    }
};

var patches: host.Owned(PatchRecord) = .{};

pub fn patch(loaded: *Loaded, address: usize, bytes: []const u8, options: api.PatchOptions) api.PatchError!*api.Patch {
    var names: Names = .{ .loaded = loaded, .scope = options.names };
    const p = engine.Patch.create(address, bytes, .{ .expect = options.expect, .resolver = names.resolver() }) catch |err| return patchError(err, address);
    return keep(loaded, .{ .in_place = p });
}

pub fn patchAsm(loaded: *Loaded, address: usize, source: []const u8, options: api.AsmPatchOptions, problem: *api.AsmProblem) api.PatchError!*api.Patch {
    var build: Build = .{ .gpa = loaded.allocator, .source = source, .problem = problem, .loaded = loaded, .scope = options.names };
    var expect_problem: engine.Patch.ExpectProblem = .{};
    var expect_names: Names = .{ .loaded = loaded, .scope = options.names };
    var reach: [16]usize = undefined;
    const replaced = engine.Patch.replace(address, build.of(), .{
        .size = options.size,
        .expect = options.expect,
        .problem = &expect_problem,
        .resolver = expect_names.resolver(),
        .reach = reachOf(options.names, &reach),
    }) catch |err| {
        if (build.failed) |failed| return failed;
        if (err == error.SplitsInstruction) describeSplit(address, options, problem);
        describeExpect(err, &expect_problem, problem);
        return patchError(err, address);
    };
    return keep(loaded, switch (replaced) {
        .patch => |p| .{ .in_place = p },
        .hook => |h| .{ .cave = h },
    });
}

fn keep(loaded: *Loaded, made: @FieldType(PatchRecord, "engine")) api.PatchError!*api.Patch {
    const record = loaded.allocator.create(PatchRecord) catch {
        var stray: PatchRecord = .{ .engine = made, .loaded = loaded };
        stray.stop();
        return error.OutOfMemory;
    };
    record.* = .{ .engine = made, .loaded = loaded };
    switch (made) {
        .in_place => |p| p.setOwner(&loaded.owner),
        .cave => |h| h.setOwner(&loaded.owner),
    }
    patches.add(record) catch {
        record.free();
        return error.PatchFailed;
    };
    return @ptrCast(record);
}

/// Says where the instructions there end, so the size can be fixed.
fn describeSplit(address: usize, options: api.AsmPatchOptions, problem: *api.AsmProblem) void {
    var names: Names = .{ .scope = options.names };
    const size: usize = if (options.size > 0) options.size else engine.Patch.expected(address, options.expect, .{ .resolver = names.resolver() }) catch 0;
    var buf: [200]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.print("{d} bytes ends inside an instruction. The instructions there end at", .{size}) catch {};
    var at: usize = 0;
    var shown: usize = 0;
    while (shown < 6 and at < size + 16) : (shown += 1) {
        const d = arch.insn.decode(address + at) catch break;
        at += d.len;
        w.print("{s} {d}", .{ if (shown == 0) "" else ",", at }) catch {};
    }
    problem.set(0, w.buffered());
}

/// Says what `expect` found instead, or what's wrong with it.
pub fn describeExpect(err: anyerror, found: *const engine.Patch.ExpectProblem, problem: *api.AsmProblem) void {
    var buf: [200]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    switch (err) {
        error.UnexpectedBytes => {
            const m = &found.mismatch;
            // A byte pattern, which has nothing more to say
            if (m.expected().len == 0) return;
            if (m.found().len == 0) {
                w.print("expected `{s}` but the code there doesn't disassemble", .{m.expected()}) catch {};
            } else {
                w.print("expected `{s}` but found `{s}`", .{ m.expected(), m.found() }) catch {};
            }
        },
        error.InvalidExpect, error.InvalidPattern => {
            const d = found.diagnostic.message();
            w.print("bad expect: {s}", .{if (d.len > 0) d else "not a byte pattern or asm"}) catch {};
        },
        else => return,
    }
    problem.set(0, w.buffered());
}

pub fn patchEnable(_: *Loaded, p: *api.Patch) api.PatchError!void {
    const record = PatchRecord.of(p);
    if (record.destroyed) return error.InvalidHandle;
    const done = switch (record.engine) {
        .in_place => |e| e.enable(),
        .cave => |h| h.enable(),
    };
    done catch |err| return patchError(err, record.address());
}

pub fn patchDisable(_: *Loaded, p: *api.Patch) api.PatchError!void {
    const record = PatchRecord.of(p);
    if (record.destroyed) return error.InvalidHandle;
    const done = switch (record.engine) {
        .in_place => |e| e.disable(),
        .cave => |h| h.disable(),
    };
    done catch |err| return patchError(err, record.address());
}

pub fn patchDestroy(_: *Loaded, p: *api.Patch) void {
    PatchRecord.of(p).stop();
}

fn patchError(err: anyerror, address: usize) api.PatchError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AlreadyHooked => error.AlreadyHooked,
        error.Unreadable, error.DisassemblyFailed => error.Unreadable,
        error.UnexpectedBytes => error.UnexpectedBytes,
        error.InvalidPattern, error.InvalidExpect => error.InvalidPattern,
        error.TargetModified => error.TargetModified,
        error.TooLong, error.Empty => error.TooLong,
        error.SplitsInstruction => error.SplitsInstruction,
        else => {
            log.warn("Patch at 0x{x} failed: {t}", .{ address, err });
            return error.PatchFailed;
        },
    };
}

const Block = struct {
    place: mem.Placement,
    loaded: *Loaded,
    freed: bool = false,

    /// Code using it stops first, so it waits for `free`.
    pub fn stop(_: *Block) void {}

    fn address(self: *const Block) usize {
        return @intFromPtr(self.place.data.ptr);
    }

    fn release(self: *Block) void {
        if (self.freed) return;
        self.freed = true;
        mem.Claims.remove(.code, self.address());
        self.place.free();
    }

    pub fn free(self: *Block) void {
        self.release();
        self.loaded.allocator.destroy(self);
    }
};

var blocks: host.Owned(Block) = .{};

/// Placed like code, see `mem.Placement`. Near `near`'s whole module if there's room, else in
/// padding in its code, else its far zone, else anywhere. Code that reads it later goes in reach
/// of it, beside it if there's room.
pub fn alloc(loaded: *Loaded, len: usize, near: usize) api.AllocError!usize {
    if (len == 0) return error.OutOfMemory;
    var place_ = mem.Placement.place(.{ .target = near, .data = len }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.OutOfReach,
    };
    const block = loaded.allocator.create(Block) catch {
        place_.free();
        return error.OutOfMemory;
    };
    return keepBlock(block, loaded, place_, len);
}

/// Frees it all if it fails.
fn keepBlock(block: *Block, loaded: *Loaded, placed: mem.Placement, len: usize) error{OutOfMemory}!usize {
    block.* = .{ .place = placed, .loaded = loaded };
    blocks.add(block) catch {
        block.free();
        return error.OutOfMemory;
    };
    const at = block.address();
    var claim: mem.Claims.Claim = .{ .start = at, .len = len, .kind = .code, .id = at };
    claim.setOwner(&loaded.owner);
    mem.Claims.add(claim) catch {};
    return at;
}

pub fn free(loaded: *Loaded, address: usize) void {
    const block = blocks.findWhere(&loaded.owner, address, struct {
        fn match(b: *Block, at: usize) bool {
            return !b.freed and b.address() == at;
        }
    }.match) orelse return;
    block.release();
}

/// Data and the code that reads it, placed as one by `engine.Batch`. Data's kept like `alloc`'s,
/// and each code like `patchAsm`'s.
pub fn place(loaded: *Loaded, request: api.PlaceRequest, data_out: []usize, code_out: []*api.Patch, problem: *api.PlaceProblem) api.PlaceError!void {
    if (data_out.len != request.data.len or code_out.len != request.code.len) return error.PatchFailed;
    const gpa = loaded.allocator;
    const data_n = request.data.len;
    const code_n = request.code.len;

    const placed = try gpa.alloc(mem.Placement, data_n);
    defer gpa.free(placed);
    const data = try gpa.alloc(engine.Batch.Data, data_n);
    defer gpa.free(data);
    for (request.data, data) |d, *out| out.* = .{ .len = @max(d.len, 1), .alignment = @max(d.alignment, 1) };
    var pending: Pending = .{ .data = request.data, .placed = placed };

    const builds = try gpa.alloc(Build, code_n);
    defer gpa.free(builds);
    const expect_names = try gpa.alloc(Names, code_n);
    defer gpa.free(expect_names);
    const code = try gpa.alloc(engine.Batch.Code, code_n);
    defer gpa.free(code);
    const made = try gpa.alloc(engine.Batch.Made, code_n);
    defer gpa.free(made);
    var expect_problem: engine.Patch.ExpectProblem = .{};
    var reach: [16]usize = undefined;
    var reach_n: usize = 0;
    for (request.code, builds, expect_names, code) |c, *b, *e, *out| {
        b.* = .{ .gpa = gpa, .source = c.source(), .problem = &problem.problem, .loaded = loaded, .scope = c.names(), .pending = &pending };
        e.* = .{ .loaded = loaded, .scope = c.names() };
        out.* = .{ .address = c.address, .build = b.of() };
        if (!c.inject) out.replace = .{ .size = c.size, .expect = c.expect(), .problem = &expect_problem, .resolver = e.resolver() };
        reach_n += reachOf(c.names(), reach[reach_n..]).len;
    }

    // Made first, so nothing but keeping them can fail once it's placed
    const records = try gpa.alloc(*PatchRecord, code_n);
    defer gpa.free(records);
    const kept_blocks = try gpa.alloc(*Block, data_n);
    defer gpa.free(kept_blocks);
    var records_n: usize = 0;
    var blocks_n: usize = 0;
    errdefer {
        for (records[0..records_n]) |r| loaded.allocator.destroy(r);
        for (kept_blocks[0..blocks_n]) |b| loaded.allocator.destroy(b);
    }
    while (records_n < code_n) : (records_n += 1) records[records_n] = try loaded.allocator.create(PatchRecord);
    while (blocks_n < data_n) : (blocks_n += 1) kept_blocks[blocks_n] = try loaded.allocator.create(Block);

    var failure: engine.Batch.Failure = .{};
    engine.Batch.place(data, code, .{ .near = request.near, .reach = reach[0..reach_n] }, placed, made, &failure) catch |err| {
        problem.bytes = failure.bytes;
        const i = failure.index orelse return if (err == error.OutOfMemory) error.OutOfMemory else error.OutOfReach;
        problem.failed = true;
        problem.index = @intCast(i);
        if (builds[i].failed) |failed| return failed;
        problem.problem = .{};
        const c = request.code[i];
        if (err == error.SplitsInstruction) describeSplit(c.address, .{ .size = c.size, .expect = c.expect(), .names = c.names() }, &problem.problem);
        describeExpect(err, &expect_problem, &problem.problem);
        return patchError(err, c.address);
    };

    var ok = true;
    var kept_records: usize = 0;
    for (made, records, code_out) |m, record, *out| {
        record.* = .{ .engine = switch (m) {
            .patch => |p| .{ .in_place = p },
            .hook => |h| .{ .cave = h },
        }, .loaded = loaded };
        switch (m) {
            .patch => |p| p.setOwner(&loaded.owner),
            .hook => |h| h.setOwner(&loaded.owner),
        }
        patches.add(record) catch {
            record.free();
            ok = false;
            continue;
        };
        records[kept_records] = record;
        kept_records += 1;
        out.* = @ptrCast(record);
    }
    var kept_data: usize = 0;
    for (placed, kept_blocks, request.data, data_out) |p, block, d, *out| {
        out.* = keepBlock(block, loaded, p, d.len) catch {
            ok = false;
            continue;
        };
        kept_blocks[kept_data] = block;
        kept_data += 1;
    }
    records_n = 0;
    blocks_n = 0;
    if (ok) return;
    // Code before the data it reads
    for (records[0..kept_records]) |r| r.stop();
    for (kept_blocks[0..kept_data]) |b| b.release();
    return error.OutOfMemory;
}

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");

    noinline fn seven() callconv(.c) u32 {
        var x: u32 = 7;
        asm volatile (""
            : [x] "+r" (x),
        );
        return x;
    }

    test "patches go back on unload" {
        try engine.init(testing.allocator);
        defer engine.deinit();
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "test");
        sdk.Owner.attach(loaded.root());
        defer sdk.Owner.detach();

        const p = try sdk.wraith.root().?.code().patch(@intFromPtr(&seven), "mov eax, 42\nret", .{});
        try testing.expectEqual(42, seven());
        try p.disable();
        try testing.expectEqual(7, seven());
        try p.enable();
        loaded.deinitForTest();
        try testing.expectEqual(7, seven());
    }

    test "a size inside an instruction says where they end" {
        try engine.init(testing.allocator);
        defer engine.deinit();
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "test");
        defer loaded.deinitForTest();
        const at = @intFromPtr(&seven);
        const size = for (1..16) |n| {
            if (try engine.Patch.instructionEnd(at, n) != n) break n;
        } else return error.SkipZigTest;
        var problem: api.AsmProblem = .{};
        try testing.expectError(error.SplitsInstruction, patchAsm(&loaded, at, "nop", .{ .size = @intCast(size) }, &problem));
        var buf: [128]u8 = undefined;
        const start = try std.fmt.bufPrint(&buf, "{d} bytes ends inside an instruction. The instructions there end at ", .{size});
        try testing.expect(std.mem.startsWith(u8, problem.message(), start));
    }

    test "expect says what it found" {
        try engine.init(testing.allocator);
        defer engine.deinit();
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "test");
        defer loaded.deinitForTest();
        const at = @intFromPtr(&seven);
        var problem: api.AsmProblem = .{};
        try testing.expectError(error.UnexpectedBytes, patchAsm(&loaded, at, "nop", .{ .expect = "int3" }, &problem));
        try testing.expect(std.mem.startsWith(u8, problem.message(), "expected `int3` but found `"));
        try testing.expectError(error.InvalidPattern, patchAsm(&loaded, at, "nop", .{ .expect = "frobnicate eax" }, &problem));
        try testing.expect(std.mem.startsWith(u8, problem.message(), "bad expect: "));
    }

    test "asm problems" {
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "test");
        defer loaded.deinitForTest();
        var problem: api.AsmProblem = .{};
        var out: [16]u8 = undefined;
        try testing.expectError(error.InvalidAsm, assemble(&loaded, "nop\nfrobnicate eax", 0x1000, &out, &problem));
        try testing.expectEqual(2, problem.line);
        try testing.expectEqual(1, try assemble(&loaded, "nop", 0x1000, &out, &problem));
    }

    test "allocations go with the owner" {
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "test");
        const at = try alloc(&loaded, 64, @intFromPtr(&seven));
        const p: *u32 = @ptrFromInt(at);
        p.* = 5;
        free(&loaded, at);
        free(&loaded, at);
        _ = try alloc(&loaded, 64, 0);
        loaded.deinitForTest();
    }

    test "data in a code cave is writable, and put back when freed" {
        mem.Claims.enable(testing.allocator);
        defer mem.Claims.disable();
        mem.Placement.tiers = .initOne(.cave);
        defer mem.Placement.tiers = .full;
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "test");
        defer loaded.deinitForTest();
        const near = @intFromPtr(&seven);
        const at = alloc(&loaded, 16, near) catch return error.SkipZigTest;
        const bytes: *[16]u8 = @ptrFromInt(at);
        const before = bytes.*;
        @memset(bytes, 0x5A);
        try testing.expect(mem.Claims.local.first(at, 16) != null);
        // Claimed, so the next one goes elsewhere
        if (mem.findCodeCave(near, 16)) |other| try testing.expect(other + 16 <= at or other >= at + 16);
        free(&loaded, at);
        try testing.expectEqualSlices(u8, &before, bytes);
        try testing.expect(mem.Claims.local.first(at, 16) == null);
    }

    // a + b + 100 + 3, as 2, 2, 3, 3, 3 and 3 byte instructions
    comptime {
        if (@import("builtin").cpu.arch == .x86_64) asm (
            \\.text
            \\.globl wraith_far_data_target
            \\wraith_far_data_target:
            \\  movl %ecx, %eax
            \\  addl %edx, %eax
            \\  addl $100, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  addl $1, %eax
            \\  retq
        );
    }
    extern fn wraith_far_data_target(a: u32, b: u32) callconv(.c) u32;

    test "a patch moves out to sit with data that can't go near" {
        if (@import("builtin").cpu.arch != .x86_64) return error.SkipZigTest;
        try engine.init(testing.allocator);
        defer engine.deinit();
        var loaded: Loaded = undefined;
        loaded.initForTest(testing.allocator, "test");
        defer loaded.deinitForTest();
        defer mem.Placement.tiers = .full;
        const at = @intFromPtr(&wraith_far_data_target);
        // Nothing like `mov eax, [moffs64]` for add, so far data can't be read in place
        const source = "xor eax, eax\nadd eax, [d]";

        for ([_]bool{ true, false }) |near| {
            mem.Placement.tiers = if (near) .initOne(.near) else .initMany(&.{ .far, .anywhere });
            const d = try alloc(&loaded, 4, at);
            defer free(&loaded, d);
            @as(*u32, @ptrFromInt(d)).* = 40;
            const reaches = std.math.cast(i32, @as(isize, @bitCast(d -% at))) != null;
            if (!near and (reaches or d < 0x8000_0000)) return error.SkipZigTest;

            var problem: api.AsmProblem = .{};
            const names = [_]api.Name{.of("d", d)};
            const p = try patchAsm(&loaded, at, source, .{ .size = 10, .names = &names }, &problem);
            defer patchDestroy(&loaded, p);
            const record = PatchRecord.of(p);
            try testing.expectEqual(near, record.engine == .in_place);
            try patchEnable(&loaded, p);
            // 40, then the two + 1s after what it replaced
            try testing.expectEqual(42, wraith_far_data_target(1, 10));
        }
        try testing.expectEqual(114, wraith_far_data_target(1, 10));
    }
};

test {
    _ = tests;
}
