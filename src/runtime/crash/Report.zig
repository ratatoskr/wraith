//! A crash report. It says what happened and where, the registers, what's on the stack and the
//! recent log. Built into a fixed buffer, since the heap might be what broke.

const Report = @This();

const std = @import("std");

const arch = @import("tuft_arch");
const sys = @import("tuft_sys");
const Symbols = @import("tuft_mem").Symbols;

const LogHistory = @import("../LogHistory.zig");

const Exception = sys.exceptions.Exception;

buf: [64 << 10]u8 = undefined,
len: usize = 0,

pub const Facts = struct {
    /// A Zig panic's message. The exception's then just the trap it turned into.
    panic: ?[]const u8 = null,
    exception: Exception,
    thread_id: u32,
    exe: []const u8,
    pid: u32,
    dump_path: []const u8,
    /// Null if the dump got written.
    dump_error: ?anyerror,
    history: ?*LogHistory = null,
};

pub fn text(self: *const Report) [:0]const u8 {
    return self.buf[0..self.len :0];
}

pub fn build(self: *Report, facts: Facts) void {
    // Room for the 0 at the end
    var w: std.Io.Writer = .fixed(self.buf[0 .. self.buf.len - 1]);
    write(&w, facts) catch {};
    self.len = w.buffered().len;
    self.buf[self.len] = 0;
}

/// One line, like `access violation reading 0x10 in game.exe+0x1234`.
pub fn summary(e: *const Exception, buf: []u8) []const u8 {
    return summaryOf(.{ .kind = e.kind, .code = e.code, .fault = e.fault }, e.cpu.ip(), buf);
}

pub const What = struct {
    kind: sys.exceptions.Kind,
    code: u32,
    fault: ?sys.exceptions.Fault = null,
};

pub fn summaryOf(what: What, ip: usize, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    writeSummary(&w, what, ip) catch {};
    return w.buffered();
}

fn writeSummary(w: *std.Io.Writer, what: What, ip: usize) !void {
    try w.writeAll(kindName(what.kind));
    if (what.fault) |f| try w.print(" {s} 0x{x}", .{ accessName(f.access), f.address });
    if (what.kind == .other) try w.print(" (0x{X:0>8})", .{what.code});
    var where: [300]u8 = undefined;
    try w.print(" in {s}", .{describe(ip, &where)});
}

fn write(w: *std.Io.Writer, f: Facts) !void {
    const e = &f.exception;
    try w.writeAll("Wraith crash report\r\n\r\n");
    try w.print("Game: {s} (pid {d})\r\n", .{ f.exe, f.pid });
    if (f.panic) |msg| try w.print("Panic: {s}\r\n", .{msg});
    try w.writeAll("What: ");
    try writeSummary(w, .{ .kind = e.kind, .code = e.code, .fault = e.fault }, e.cpu.ip());
    try w.print("\r\nCode: 0x{X:0>8}{s}\r\n", .{ e.code, if (e.continuable) "" else ", can't continue" });
    try w.print("Thread: {d}\r\n", .{f.thread_id});
    if (f.dump_error) |err| {
        try w.print("Dump: couldn't write it ({t})\r\n", .{err});
    } else try w.print("Dump: {s}\r\n", .{f.dump_path});

    try w.writeAll("\r\nRegisters\r\n");
    try w.print("  ip     0x{x:0>16}\r\n", .{e.cpu.ip()});
    const info = @typeInfo(arch.CpuContext).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        if (comptime (T == u64 or T == u32) and !std.mem.startsWith(u8, name, "_")) try w.print("  {s: <6} 0x{x:0>16}\r\n", .{ name, @field(e.cpu, name) });
    }

    try w.writeAll("\r\nOn the stack (likely return addresses, newest first)\r\n");
    try writeStack(w, stackPointer(e));

    if (f.history) |h| {
        try w.writeAll("\r\nRecent log\r\n");
        var entries: [40]LogHistory.Entry = undefined;
        for (h.readSince(h.next_seq -| entries.len, &entries)) |*entry| {
            try w.print("  {s: <5} {s}\r\n", .{ @tagName(entry.level), entry.message() });
        }
    }
}

fn stackPointer(e: *const Exception) usize {
    return if (comptime arch.bits == 64) @intCast(e.cpu.rsp) else @intCast(e.cpu.esp);
}

/// Words on the stack that point into a module's code. A guess, but it needs no symbols or unwinding.
fn writeStack(w: *std.Io.Writer, sp: usize) !void {
    var found: usize = 0;
    var i: usize = 0;
    while (i < 4096 and found < 32) : (i += 1) {
        var word: usize = 0;
        if (!sys.memory.readSafe(sp + i * @sizeOf(usize), std.mem.asBytes(&word))) break;
        if (!inCode(word)) continue;
        var buf: [300]u8 = undefined;
        try w.print("  {s}\r\n", .{describe(word, &buf)});
        found += 1;
    }
    if (found == 0) try w.writeAll("  (nothing that looks like code)\r\n");
}

fn inCode(address: usize) bool {
    const base = sys.module.containingBase(address) orelse return false;
    var it = sys.module.sections(base) catch return false;
    while (it.next()) |s| {
        if (s.executable and address >= s.start and address - s.start < s.len) return true;
    }
    return false;
}

fn describe(address: usize, buf: []u8) []const u8 {
    if (Symbols.local.describe(address, buf)) |name| return name;
    return std.fmt.bufPrint(buf, "0x{x}", .{address}) catch "?";
}

fn kindName(kind: sys.exceptions.Kind) []const u8 {
    return switch (kind) {
        .access_violation => "access violation",
        .guard_page => "guard page hit",
        .in_page_error => "page couldn't be read in",
        .breakpoint => "breakpoint nobody handled",
        .single_step => "single step nobody handled",
        .illegal_instruction => "illegal instruction",
        .privileged_instruction => "privileged instruction",
        .misaligned_data => "misaligned data",
        .int_divide_by_zero => "integer divide by zero",
        .int_overflow => "integer overflow",
        .float => "floating point exception",
        .other => "exception",
    };
}

fn accessName(access: sys.exceptions.Fault.Access) []const u8 {
    return switch (access) {
        .read => "reading",
        .write => "writing",
        .execute => "executing",
    };
}

const tests = struct {
    const testing = std.testing;

    noinline fn here() usize {
        return @returnAddress();
    }

    test "says what, where and what's on the stack" {
        // On the stack, so the scan finds it
        var stack: [8]usize = .{ 0, 0x10, here(), 0, 0, 0, 0, 0 };
        var e: Exception = .{
            .kind = .access_violation,
            .code = 0xC0000005,
            .fault = .{ .access = .write, .address = 0x10 },
            .cpu = std.mem.zeroes(arch.CpuContext),
        };
        e.cpu.setIp(here());
        if (comptime arch.bits == 64) e.cpu.rsp = @intFromPtr(&stack) else e.cpu.esp = @intCast(@intFromPtr(&stack));
        // Too big for the stack
        const S = struct {
            var history: LogHistory = .{};
            var report: Report = .{};
        };
        S.history.add(.info, .runtime, "before the crash");

        S.report.build(.{ .exception = e, .thread_id = 7, .exe = "kai.exe", .pid = 42, .dump_path = "kai-42-crash.dmp", .dump_error = null, .history = &S.history });
        const t = S.report.text();
        try testing.expect(std.mem.indexOf(u8, t, "What: access violation writing 0x10 in ") != null);
        try testing.expect(std.mem.indexOf(u8, t, "Game: kai.exe (pid 42)") != null);
        try testing.expect(std.mem.indexOf(u8, t, "Dump: kai-42-crash.dmp") != null);
        try testing.expect(std.mem.indexOf(u8, t, "before the crash") != null);
        try testing.expect(std.mem.indexOf(u8, t, "(nothing that looks like code)") == null);

        var buf: [200]u8 = undefined;
        try testing.expect(std.mem.startsWith(u8, summary(&e, &buf), "access violation writing 0x10 in "));
    }
};

test {
    _ = tests;
}
