//! TypeScript typings for a JavaScript or TypeScript plugin: Wraith's namespaces and its own as globals of
//! the `wraith` module, with each dependency's [Service] traits as functions like `Freecam.freecam()`.

const std = @import("std");
const types = @import("salamander_types");

const Project = @import("project.zig");
const Made = @import("output.zig").Made;

pub const default_out = ".wraith/types";

/// What scripts import Wraith's and the plugins' namespaces from.
pub const module = "wraith";

pub fn generate(p: *Project) ![]const Made {
    var all = try p.all();
    defer all.deinit();
    var w: std.Io.Writer.Allocating = .init(p.arena);
    try types.ts.globals(&w.writer, all.schema, all.source, try p.services(all), module);
    try w.writer.writeAll(hooks);
    const wraith_d = w.written();
    w = .init(p.arena);
    try types.ts.builtins(&w.writer);
    return p.arena.dupe(Made, &.{
        .{ .name = "wraith.d.ts", .text = wraith_d },
        .{ .name = "salamander.d.ts", .text = w.written() },
    });
}

/// The typed hooks every script's `Wraith.Hooks` gets, see runtime/plugins/hooks.js.
const hooks =
    \\
    \\declare module "wraith" {
    \\  namespace Wraith {
    \\    /** What a typed hook's handler gets for a parameter named `hook`. */
    \\    interface TypedHook<F extends (...args: any[]) => any> {
    \\      /** The function as it was, to call on. */
    \\      original(): F;
    \\      /** What its options said. */
    \\      readonly context: number;
    \\      enable(): void;
    \\      disable(): void;
    \\      destroy(): void;
    \\    }
    \\    interface Hooks {
    \\      /**
    \\       * Hooks a function the schemas declare, like `GameStateManager.spendMira`. The handler gets its
    \\       * arguments, and a parameter named `hook` or `context` gets that instead, wherever it is. They're
    \\       * typed after the arguments, like `(self, amount, hook) => hook.original()(self, 0)`.
    \\       */
    \\      hook<F extends (...args: any[]) => any>(target: F, handler: (...args: [...Parameters<F>, hook: TypedHook<F>, context: number]) => ReturnType<F>, options?: import("salamander").Given<Wraith.Hook.Options>): Wraith.Hook;
    \\      /** The same at an address of your own, typed like `target`. */
    \\      hookAt<F extends (...args: any[]) => any>(address: number | bigint, target: F, handler: (...args: [...Parameters<F>, hook: TypedHook<F>, context: number]) => ReturnType<F>, options?: import("salamander").Given<Wraith.Hook.Options>): Wraith.Hook;
    \\    }
    \\  }
    \\}
    \\
;
