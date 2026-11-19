//! `cpu.sal`'s `Cpu`, which is laid out like tuft's `CpuContext` on each kind of code, so hooks and
//! watches hand theirs over as is.

const std = @import("std");

const api = @import("wraith_api");
const arch = @import("tuft_arch");

pub const Cpu = api.wraith.Cpu;
const Context = arch.CpuContext;

comptime {
    if (@sizeOf(Cpu) != @sizeOf(Context)) @compileError(std.fmt.comptimePrint("cpu.sal's Cpu is {d} bytes, and tuft's CpuContext {d}", .{ @sizeOf(Cpu), @sizeOf(Context) }));
    for (std.meta.fieldNames(Cpu)) |name| {
        if (name[0] == '_') continue;
        if (!@hasField(Context, name) or @offsetOf(Cpu, name) != @offsetOf(Context, name))
            @compileError("cpu.sal's Cpu." ++ name ++ " isn't where tuft's CpuContext has it");
    }
}

/// The same registers, which a handler can change in place.
pub fn of(ctx: *Context) *Cpu {
    return @ptrCast(ctx);
}

pub fn copy(ctx: *const Context) Cpu {
    return @as(*const Cpu, @ptrCast(ctx)).*;
}

/// Where it runs next, whichever kind of code.
pub fn ip(cpu: *const Cpu) usize {
    return if (@hasField(Cpu, "rip")) cpu.rip else cpu.eip;
}

test "the same memory both ways" {
    var ctx = std.mem.zeroes(Context);
    ctx.xmm1.f32x4 = .{ 1, 2, 3, 4 };
    ctx.setIp(0x1234);
    const cpu = of(&ctx);
    try std.testing.expectEqual(2, cpu.xmm1.f32x4[1]);
    try std.testing.expectEqual(0x1234, ip(&copy(&ctx)));
    cpu.xmm1.f64x2[0] = 0.5;
    try std.testing.expectEqual(0.5, ctx.xmm1.f64x2[0]);
}
