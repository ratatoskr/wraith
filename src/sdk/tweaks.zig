//! Tweaks with less wiring. Each is a box in the overlay's Tweaks menu, listed with the project's:
//!
//!     // A hook that's on while the tweak is
//!     try sdk.tweaks.hook(ctx, .{ .id = "free_shopping", .title = "Free shopping" }, &self.spend_mira);
//!
//!     // Runs once, with its fields as a struct
//!     const Give = struct {
//!         amount: u32 = 10000,
//!         pub const fields = .{ .amount = .{ .min = 1 } };
//!     };
//!     try sdk.tweaks.action(ctx, .{ .id = "give_mira", .title = "Give Mira" }, Give, self, giveMira);
//!
//!     // Opens a window of the plugin's
//!     try sdk.tweaks.opens(ctx, .{ .id = "party", .title = "Party" }, &self.party.window);
//!
//! A field's default is its first value. `fields` can say more about each, like `.min`, `.max`,
//! `.label`, `.hex` or `.key`. Bools are checkboxes and enums dropdowns. Callbacks can fail, and the
//! tweak stays off showing why. A definition's `section` puts it under a heading, like `Combat`.
//!
//! For anything else there's `ctx.wraith.tweaks()` itself.

const std = @import("std");

const api = @import("wraith_api");
const plugin = @import("plugin.zig");
const ui = @import("wraith_ui");

const W = api.wraith;
const Context = plugin.Context;

pub const Definition = struct {
    /// The plugin's own name for it, kept with the user's settings.
    id: []const u8,
    /// Empty shows the id.
    title: []const u8 = "",
    /// Like `Ctrl+F8`. Empty is none, and the user can pick one.
    key: []const u8 = "",
    /// A heading in the plugin's list, like `Combat`. Empty is none.
    section: []const u8 = "",
};

/// What `fields` can say about a field.
pub const FieldOptions = struct {
    label: []const u8 = "",
    min: ?f64 = null,
    max: ?f64 = null,
    hex: bool = false,
    /// Flips a bool, like `F9`.
    key: []const u8 = "",
};

/// On while the tweak is. `target` is a hook, or anything with `enable` and `disable`, and must
/// stay put.
pub fn hook(ctx: *Context, definition: Definition, target: anytype) !void {
    const Target = @TypeOf(target);
    const Handler = struct {
        fn handle(t: Target, event: W.TweakEvent) W.TweakError!void {
            switch (event.kind) {
                .on => t.enable() catch |err| return fail(err),
                .off => t.disable() catch |err| return fail(err),
                else => {},
            }
        }
    };
    try add(ctx, definition, .toggle, &.{}, W.TweakHandler.init(target, Handler.handle));
}

/// Runs `run(owner, args)` each time it's clicked or its key's pressed, with the fields as `Args`.
pub fn action(ctx: *Context, definition: Definition, comptime Args: type, owner: anytype, comptime run: anytype) !void {
    const Owner = @TypeOf(owner);
    const State = Stateful(Args, Owner, struct {
        fn on(o: Owner, args: Args) anyerror!void {
            return run(o, args);
        }
    }, .action);
    try State.add(ctx, definition, owner);
}

/// Opens `window`, a `ui.Window`, from the Tweaks list, like a plugin's own Party window. It shows
/// with an open button. `window` must stay put.
pub fn opens(ctx: *Context, definition: Definition, window: *ui.Window) !void {
    const Handler = struct {
        fn handle(w: *ui.Window, event: W.TweakEvent) W.TweakError!void {
            if (event.kind == .on) w.focus();
        }
    };
    try add(ctx, definition, .open, &.{}, W.TweakHandler.init(window, Handler.handle));
}

/// On and off, with the fields as `Args`. `callbacks` has `on(owner, args)`, `off(owner)`, and
/// optionally `changed(owner, args)` for a field changing while it's on.
pub fn toggle(ctx: *Context, definition: Definition, comptime Args: type, owner: anytype, comptime callbacks: anytype) !void {
    const State = Stateful(Args, @TypeOf(owner), callbacks, .toggle);
    try State.add(ctx, definition, owner);
}

fn Stateful(comptime Args: type, comptime Owner: type, comptime callbacks: anytype, comptime mode: W.TweakMode) type {
    return struct {
        const Self = @This();

        owner: Owner,
        args: Args = .{},
        on: bool = false,
        allocator: std.mem.Allocator,

        fn add(ctx: *Context, definition: Definition, owner: Owner) !void {
            const self = try ctx.allocator.create(Self);
            self.* = .{ .owner = owner, .allocator = ctx.allocator };
            // Freed with the plugin, once nothing can call it
            ctx.configs.add(self, free) catch |err| {
                ctx.allocator.destroy(self);
                return err;
            };
            try tweaks_add(ctx, definition, mode, &comptime fieldsOf(Args), W.TweakHandler.init(self, handle));
        }

        fn free(self: *Self) void {
            self.allocator.destroy(self);
        }

        fn handle(self: *Self, event: W.TweakEvent) W.TweakError!void {
            switch (event.kind) {
                .changed => {
                    set(Args, &self.args, event.field, event.value);
                    if (self.on and @hasDecl(callbacks, "changed")) callbacks.changed(self.owner, self.args) catch |err| return fail(err);
                },
                .on => {
                    callbacks.on(self.owner, self.args) catch |err| return fail(err);
                    self.on = mode == .toggle;
                },
                .off => {
                    self.on = false;
                    if (@hasDecl(callbacks, "off")) callbacks.off(self.owner);
                },
                else => {},
            }
        }
    };
}

const tweaks_add = add;

fn add(ctx: *Context, definition: Definition, mode: W.TweakMode, fields: []const W.TweakField, handler: W.TweakHandler) !void {
    const def: W.TweakDefinition = .{
        .id = definition.id,
        .title = definition.title,
        .key = definition.key,
        .mode = mode,
        .fields = fields,
    };
    // Plain `add` without one, so older Wraiths still list it
    if (definition.section.len == 0) return ctx.wraith.tweaks().add(def, handler);
    try ctx.wraith.tweaks().addIn(definition.section, def, handler);
}

/// Shown in the overlay as why it's off.
fn fail(err: anyerror) W.TweakError {
    if (err == error.Failed) return error.Failed;
    const why = if (err == error.NotThereYet) "not there yet, like before a save's loaded" else @errorName(err);
    return api.salamander.host().explain(error.Failed, "{s}", .{why});
}

fn fieldsOf(comptime Args: type) [@typeInfo(Args).@"struct".field_names.len]W.TweakField {
    const info = @typeInfo(Args).@"struct";
    var out: [info.field_names.len]W.TweakField = undefined;
    for (info.field_names, info.field_types, info.field_attrs, &out) |name, T, attrs, *field| {
        const o = optionsOf(Args, name);
        const default = attrs.defaultValue(T) orelse @compileError(@typeName(Args) ++ "." ++ name ++ " needs a default");
        field.* = .{
            .name = name,
            .type = fieldType(T),
            .value = toF64(default),
            .label = o.label,
            .toggle = T == bool,
            .hex = o.hex,
            .has_min = o.min != null,
            .min = o.min orelse 0,
            .has_max = o.max != null,
            .max = o.max orelse 0,
            .key = o.key,
            .choices = if (@typeInfo(T) == .@"enum") &comptime choicesOf(T) else &.{},
        };
    }
    return out;
}

/// `Args.fields.<name>`, which is a plain `.{ .min = 1 }`, as `FieldOptions`.
fn optionsOf(comptime Args: type, comptime name: []const u8) FieldOptions {
    var o: FieldOptions = .{};
    if (!@hasDecl(Args, "fields") or !@hasField(@TypeOf(Args.fields), name)) return o;
    const given = @field(Args.fields, name);
    for (@typeInfo(@TypeOf(given)).@"struct".field_names) |key| {
        if (!@hasField(FieldOptions, key)) @compileError(@typeName(Args) ++ ".fields." ++ name ++ " has " ++ key ++ ", which isn't a field option");
        @field(o, key) = @field(given, key);
    }
    return o;
}

fn choicesOf(comptime E: type) [@typeInfo(E).@"enum".field_names.len]W.TweakChoice {
    const info = @typeInfo(E).@"enum";
    var out: [info.field_names.len]W.TweakChoice = undefined;
    for (info.field_names, info.field_values, &out) |name, value, *c| c.* = .{ .value = value, .label = name };
    return out;
}

fn fieldType(comptime T: type) W.TweakFieldType {
    return switch (T) {
        f64 => .f64,
        f32 => .f32,
        i64 => .i64,
        i32 => .i32,
        i16 => .i16,
        i8 => .i8,
        u64 => .u64,
        u32 => .u32,
        u16 => .u16,
        u8 => .u8,
        bool => .bool,
        else => switch (@typeInfo(T)) {
            .@"enum" => |e| fieldType(e.tag_type),
            else => @compileError("a tweak field is a number, bool or enum, not " ++ @typeName(T)),
        },
    };
}

fn toF64(value: anytype) f64 {
    return switch (@typeInfo(@TypeOf(value))) {
        .bool => if (value) 1 else 0,
        .@"enum" => @floatFromInt(@backingInt(value)),
        .int => @floatFromInt(value),
        .float => @floatCast(value),
        else => unreachable,
    };
}

fn fromF64(comptime T: type, value: f64) T {
    return switch (@typeInfo(T)) {
        .bool => value != 0,
        .float => @floatCast(value),
        .int => blk: {
            if (std.math.isNan(value)) break :blk 0;
            const clamped = std.math.clamp(@round(value), @as(f64, @floatFromInt(std.math.minInt(T))), @as(f64, @floatFromInt(std.math.maxInt(T))));
            break :blk @intFromFloat(clamped);
        },
        .@"enum" => |e| std.enums.fromInt(T, fromF64(e.tag_type, value)) orelse @fromBackingInt(@intCast(e.field_values[0])),
        else => unreachable,
    };
}

fn set(comptime Args: type, args: *Args, name: []const u8, value: f64) void {
    const info = @typeInfo(Args).@"struct";
    inline for (info.field_names, info.field_types) |field, T| {
        if (std.mem.eql(u8, field, name)) @field(args, field) = fromF64(T, value);
    }
}

test "fields come from the struct" {
    const Mode = enum(u8) { slow, fast };
    const Args = struct {
        amount: u32 = 10000,
        on: bool = true,
        mode: Mode = .fast,
        scale: f32 = 1.5,
        pub const fields = .{ .amount = .{ .min = 1, .label = "How much" } };
    };
    const fields = comptime fieldsOf(Args);
    try std.testing.expectEqualStrings("amount", fields[0].name);
    try std.testing.expectEqual(.u32, fields[0].type);
    try std.testing.expectEqual(10000, fields[0].value);
    try std.testing.expect(fields[0].has_min and !fields[0].has_max);
    try std.testing.expectEqualStrings("How much", fields[0].label);
    try std.testing.expect(fields[1].toggle);
    try std.testing.expectEqual(2, fields[2].choices.len);
    try std.testing.expectEqualStrings("fast", fields[2].choices[1].label);

    var args: Args = .{};
    set(Args, &args, "amount", -5);
    try std.testing.expectEqual(0, args.amount);
    set(Args, &args, "amount", 1e12);
    try std.testing.expectEqual(std.math.maxInt(u32), args.amount);
    set(Args, &args, "mode", 0);
    try std.testing.expectEqual(.slow, args.mode);
    set(Args, &args, "on", 0);
    try std.testing.expect(!args.on);
}
