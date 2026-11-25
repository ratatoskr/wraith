//! Three tweaks for Trails beyond the Horizon. The other folders here do the same in their language.

const std = @import("std");
const sdk = @import("wraith_sdk");
const schema = @import("schema");

pub const std_options: std.Options = .{ .logFn = sdk.logFn };
pub const panic = sdk.panic;

const W = sdk.api.wraith;
const GameStateManager = schema.GameStateManager;
const SpendMira = GameStateManager.Fns.spendMira;
const SpendHook = sdk.hooks.FnHook(SpendMira);

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

pub const Plugin = struct {
    spend_mira: SpendHook = undefined,
    tailing: Tailing = .{},

    pub fn start(self: *Plugin, ctx: *sdk.Context) !void {
        // Shops still take your Mira, just none of it
        self.spend_mira = try sdk.hooks.createFn(SpendMira, try GameStateManager.addresses.spendMira(), spendMira, self);
        try sdk.tweaks.hook(ctx, .{ .id = "free_shopping", .title = "Free shopping", .section = "Money" }, &self.spend_mira);

        try sdk.tweaks.action(ctx, .{ .id = "give_mira", .title = "Give Mira", .section = "Money" }, GiveMira, self, giveMira);

        // Being seen needs the gauge full, so skip both. `expect` stops it patching a game that changed
        const code = ctx.wraith.code();
        self.tailing.seen = try code.patchBytes(try schema.addresses.tailing_seen(), &.{0xEB}, .{ .size = 0, .expect = "76", .disabled = true, .names = &.{} });
        self.tailing.gauge = try code.patchBytes(try schema.addresses.tailing_gauge(), &.{ 0xEB, 0x02 }, .{ .size = 0, .expect = "F3 0F 5F FE", .disabled = true, .names = &.{} });
        try sdk.tweaks.hook(ctx, .{ .id = "tailing_stealth", .title = "Tailing without being seen", .section = "Field" }, &self.tailing);
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
