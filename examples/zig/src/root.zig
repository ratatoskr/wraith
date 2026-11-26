//! Four tweaks for Trails beyond the Horizon. The other folders here do the same in their language.

const std = @import("std");
const sdk = @import("wraith_sdk");
const generated = @import("schema");
// Its own types are in its namespace, its id in PascalCase
const schema = generated.ExampleZig;

pub const std_options: std.Options = .{ .logFn = sdk.logFn };
pub const panic = sdk.panic;

const W = sdk.api.wraith;
const Atomic = sdk.atomic.Value;
const GameStateManager = schema.GameStateManager;
const SpendHook = sdk.hooks.Hook(GameStateManager, .spendMira);

/// Give Mira's fields in the Tweaks window
const GiveMira = struct {
    amount: u32 = 10000,
    pub const fields = .{ .amount = .{ .min = 1 } };
};

/// Both spots patched while it's on
const Tailing = struct {
    seen: W.Patch = undefined,
    gauge: W.Patch = undefined,

    pub fn enable(self: *Tailing) !void {
        try self.seen.enable();
        try self.gauge.enable();
    }

    pub fn disable(self: *Tailing) !void {
        self.seen.disable() catch {};
        self.gauge.disable() catch {};
    }
};

/// A mid hook just before the gauge is stored, while it's on
const SlowGauge = struct {
    hook: sdk.hooks.MidHook = undefined,
    speed: Atomic(f32) = .init(0.25),

    /// Its fields in the Tweaks window. 0 never fills, 1 is the game's own pace
    const Args = struct {
        speed: f32 = 0.25,
        pub const fields = .{ .speed = .{ .min = 0, .max = 1 } };
    };

    pub fn on(self: *SlowGauge, args: Args) !void {
        self.speed.store(args.speed, .release);
        try self.hook.enable();
    }

    pub fn changed(self: *SlowGauge, args: Args) !void {
        self.speed.store(args.speed, .release);
    }

    pub fn off(self: *SlowGauge) void {
        self.hook.disable() catch {};
    }

    /// xmm7 has the new gauge and rdi what it goes in, so only part of the change is kept
    fn store(self: *SlowGauge, cpu: *sdk.hooks.CpuContext) void {
        const state: *schema.TailingState = @ptrFromInt(cpu.rdi);
        const new = cpu.xmm7.scalarF32();
        cpu.xmm7.setScalarF32(state.gauge + (new - state.gauge) * self.speed.load(.acquire));
    }
};

pub const Plugin = struct {
    spend_mira: SpendHook = undefined,
    tailing: Tailing = .{},
    slow_gauge: SlowGauge = .{},

    pub fn start(self: *Plugin, ctx: *sdk.Context) !void {
        // Shops still take your Mira, just none of it
        self.spend_mira = try sdk.hooks.hook(GameStateManager, .spendMira, spendMira, self);
        try sdk.tweaks.hook(ctx, .{ .id = "free_shopping", .title = "Free shopping", .section = "Money" }, &self.spend_mira);

        try sdk.tweaks.action(ctx, .{ .id = "give_mira", .title = "Give Mira", .section = "Money" }, GiveMira, self, giveMira);

        // Being seen needs the gauge full, so skip both. `expect` stops it patching a game that changed
        const code = ctx.wraith.code();
        self.tailing.seen = try code.patchBytes(try schema.addresses.tailing_seen(), &.{0xEB}, .{ .size = 0, .expect = "76", .disabled = true, .names = &.{} });
        self.tailing.gauge = try code.patchBytes(try schema.addresses.tailing_gauge(), &.{ 0xEB, 0x02 }, .{ .size = 0, .expect = "F3 0F 5F FE", .disabled = true, .names = &.{} });
        try sdk.tweaks.hook(ctx, .{ .id = "tailing_stealth", .title = "Tailing without being seen", .section = "Field" }, &self.tailing);

        // Or let it fill, slower. A mid hook runs with the registers right there in the game's code
        self.slow_gauge.hook = try sdk.hooks.createMidWith(try schema.addresses.tailing_gauge_store(), SlowGauge.store, &self.slow_gauge, .{ .expect = "F3 0F 11 BF D4 00 00 00" });
        try sdk.tweaks.toggle(ctx, .{ .id = "slow_tailing_gauge", .title = "Slower tailing gauge", .section = "Field" }, SlowGauge.Args, &self.slow_gauge, SlowGauge);
    }

    pub fn stop(_: *Plugin) void {}

    fn spendMira(_: *Plugin, hook: SpendHook, manager: *GameStateManager, _: u32) u32 {
        return hook.original()(manager, 0);
    }

    fn giveMira(_: *Plugin, args: GiveMira) !void {
        // Fails with "not there yet" before a save's loaded, and the overlay says so
        _ = (try GameStateManager.instanceOrFail()).giveMira(args.amount);
    }
};

comptime {
    sdk.exportPlugin(Plugin);
}
