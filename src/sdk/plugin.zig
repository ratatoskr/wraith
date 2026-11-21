//! Turns a plugin struct into a native plugin DLL.

const std = @import("std");

const core = @import("wraith_core");
const ui = @import("wraith_ui");

const api = @import("wraith_api");
const Owner = @import("Owner.zig");
const sdk_log = @import("log.zig");
const overlay = @import("overlay.zig");
const frame = @import("frame.zig");
const timing = @import("timing.zig");
const signatures = @import("signatures.zig");
const tasks = @import("tasks.zig");
const salamander = @import("salamander.zig");

pub const symbol = "wraith_plugin";
/// The export's type.
pub const Entry = fn () callconv(.c) *const api.NativeEntry;

pub const Context = struct {
    /// Wraith's API, like `ctx.wraith.tweaks()`. The same as `sdk.wraith.root()`, without the null.
    wraith: Owner.Wraith,
    owner: Owner,
    allocator: std.mem.Allocator,
    /// Don't block game threads like render or hooks, they might have little stack.
    io: std.Io,
    /// Worker threads for the plugin's tasks.
    tasks: *std.Io.Group,
    scheduler: *tasks.Scheduler,
    configs: *core.Scope,
    windows: *ui.WindowSystem,
    drawing_windows: *bool,

    /// Runs `func(args...)` as a task, as the plugin. It starts on the render thread at the next frame, where
    /// it can draw, and waits like `sdk.frame.next(io)`, messages, keys and captures carry on there at the
    /// same point in a later frame. `sdk.frame.toWorker(io)` moves it to a worker for slow or blocking work,
    /// `toRender` brings it back. Never block on the render thread, the game waits for it.
    /// Before `stop`, every task is cancelled. Its waits fail with `error.Canceled` so it can wind down.
    /// `func` returns `void` or an error union, whose errors are logged.
    pub fn spawn(self: *Context, comptime func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) tasks.SpawnError!void {
        return self.scheduler.spawn(func, args);
    }

    /// Calls `func(target)` once a frame on the render thread, where it can update and draw UI.
    /// See `sdk.frame.onFrame`.
    pub fn onFrame(self: *Context, target: anytype, comptime func: fn (@TypeOf(target)) void) frame.Error!frame.FrameSubscription {
        const acting = self.owner.enter();
        defer acting.end();
        return frame.onFrame(target, func);
    }

    /// `owner` must not move.
    pub fn addWindow(self: *Context, owner: anytype) !void {
        if (!self.drawing_windows.*) {
            _ = try self.onFrame(self.windows, ui.WindowSystem.draw);
            self.drawing_windows.* = true;
        }
        try self.windows.add(owner);
    }

    /// The Mods page's Settings button for the plugin, which sets `opened`, like a window's `open`.
    /// `opened` must not move.
    pub fn settingsWindow(self: *Context, opened: *bool) void {
        const Open = struct {
            fn open(flag: *bool) void {
                flag.* = true;
            }
        };
        self.owner.root.ui().onOpenSettings(.init(opened, Open.open));
    }

    /// An entry under the plugin's own menu in the overlay's top bar that opens and closes something
    /// of the plugin's, kept in step with `opened`, like a window's `open`. Whichever side changed
    /// since last frame wins.
    pub fn menuItem(self: *Context, label: []const u8, opened: *bool) !void {
        const Item = struct {
            object: api.wraith.MenuItem,
            open: *bool,
            seen: bool = false,
            allocator: std.mem.Allocator,

            fn free(item: *@This()) void {
                item.allocator.destroy(item);
            }

            fn sync(item: *@This()) void {
                const now = item.object.isOpen();
                if (now != item.seen) {
                    item.open.* = now;
                    item.seen = now;
                } else if (item.open.* != item.seen) {
                    item.object.setOpen(item.open.*);
                    item.seen = item.open.*;
                }
            }
        };
        const object = self.owner.root.ui().addMenuItem(label, false);
        if (object.table == null) return error.OwnerGone;
        const item = try self.allocator.create(Item);
        item.* = .{ .object = object, .open = opened, .allocator = self.allocator };
        // Freed with the plugin's configs, once its frames have stopped
        self.configs.add(item, Item.free) catch |err| {
            self.allocator.destroy(item);
            return err;
        };
        _ = try self.onFrame(item, Item.sync);
    }

    /// `T` needs defaults on every field.
    pub fn config(self: *Context, comptime T: type) !*core.Config(T) {
        return self.open(T, self.owner.configDirectory());
    }

    pub fn gameConfig(self: *Context, comptime T: type) !*core.Config(T) {
        return self.open(T, self.owner.gameConfigDirectory());
    }

    fn open(self: *Context, comptime T: type, dir: []const u8) !*core.Config(T) {
        const path = try std.fs.path.join(self.allocator, &.{ dir, "config.zon" });
        defer self.allocator.free(path);

        const File = core.config.Lifecycle(T);
        const cfg = try File.open(self.allocator, self.io, path);
        self.configs.add(cfg, File.close) catch |err| {
            File.discard(cfg);
            return err;
        };
        return cfg;
    }
};

const log = sdk_log.scoped(.wraith_sdk);

pub const Dll = struct {
    gpa: core.allocator.Default = undefined,
    tracked: core.heap.TrackedAllocator = undefined,
    threaded: std.Io.Threaded = undefined,
    tasks: std.Io.Group = .init,
    scheduler: tasks.Scheduler = undefined,
    configs: core.Scope = undefined,
    windows: ui.WindowSystem = undefined,
    drawing_windows: bool = false,
    ready: bool = false,

    pub fn init(self: *Dll, host: api.salamander.Host, guest: api.NativeGuest) Context {
        salamander.attach(host, guest.owner, guest.render_queue, guest.services.get());
        const owner: Owner = .{ .root = guest.wraith.as(Owner.Wraith) };
        Owner.attach(owner.root);
        sdk_log.attach();
        overlay.attach();
        signatures.attach();

        self.gpa = .init();
        self.tracked.init(self.gpa.allocator(), "heap");
        // The runtime unlists it when the owner goes, after we've torn down
        timing.listHeap(&self.tracked.usage);
        const allocator = self.tracked.allocator();
        self.threaded = .init(allocator, .{});
        self.tasks = .init;
        self.scheduler = .init(allocator, self.threaded.io(), owner, &self.tasks);
        self.configs = .init(allocator);
        self.windows = .init(allocator);
        self.drawing_windows = false;
        self.ready = true;
        return .{
            .wraith = owner.root,
            .owner = owner,
            .allocator = allocator,
            .io = self.threaded.io(),
            .tasks = &self.tasks,
            .scheduler = &self.scheduler,
            .configs = &self.configs,
            .windows = &self.windows,
            .drawing_windows = &self.drawing_windows,
        };
    }

    /// Cancels the plugin's tasks and waits for them. Its posts are already cancelled by now, so frame waits end.
    pub fn cancelTasks(self: *Dll) void {
        if (!self.ready) return;
        self.scheduler.cancel();
        self.tasks.cancel(self.threaded.io());
    }

    pub fn deinit(self: *Dll) void {
        if (!self.ready) return;
        self.cancelTasks();
        self.scheduler.deinit();
        self.ready = false;
        overlay.detach();
        signatures.detach();
        self.windows.deinit();
        self.configs.deinit();
        self.threaded.deinit();
        if (self.gpa.deinit() != 0) log.warn("Leaked memory (listed above)", .{});
        sdk_log.detach();
        Owner.detach();
        salamander.detach();
    }
};

/// A Salamander object type, like a generated trait's.
fn isObject(comptime R: ?type) bool {
    const T = R orelse return false;
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "salamander") and @hasField(T, "table");
}

pub fn exportPlugin(comptime P: type) void {
    validate(P, "Plugin");

    const Exports = struct {
        var instance: P = undefined;
        var context: Context = undefined;
        var dll: Dll = .{};
        var started: bool = false;

        const native: api.NativeEntry = .{ .start = start, .stop = stop, .service = service };

        fn entry() callconv(.c) *const api.NativeEntry {
            return &native;
        }

        /// One of `P.services`, the one whose object is that trait's, owned by the plugin.
        fn service(trait: api.salamander.String) callconv(.c) api.salamander.AnyObject {
            if (!started or !@hasDecl(P, "services")) return .{};
            const name = trait.get();
            inline for (P.services) |f| {
                const T = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
                if (std.mem.eql(u8, T.salamander.name, name)) {
                    const obj = salamander.own(f(&instance)) catch return .{};
                    return .of(obj);
                }
            }
            return .{};
        }

        fn start(host: api.salamander.Host, guest: api.NativeGuest) callconv(.c) bool {
            context = dll.init(host, guest);
            instance = .{};
            instance.start(&context) catch |err| {
                // Cleaned up in `stop`, after the runtime stops whatever `start` got going
                log.err("Plugin failed to start: {t}", .{err});
                return false;
            };
            started = true;
            return true;
        }

        fn stop() callconv(.c) void {
            // Before the plugin's `stop`, so it can free what its tasks use
            dll.cancelTasks();
            if (started and @hasDecl(P, "stop")) instance.stop();
            started = false;
            dll.deinit();
        }
    };

    @export(&Exports.entry, .{ .name = symbol });
}

pub fn validate(comptime P: type, comptime what: []const u8) void {
    if (@typeInfo(P) != .@"struct") @compileError(what ++ " must be a struct, found " ++ @typeName(P));

    if (@hasDecl(P, "services")) {
        for (P.services) |f| {
            const F = @TypeOf(f);
            const ok = switch (@typeInfo(F)) {
                .@"fn" => |info| info.param_types.len == 1 and info.param_types[0] == *P and isObject(info.return_type),
                else => false,
            };
            if (!ok) @compileError("`services` lists functions like `fn freecam(self: *" ++ @typeName(P) ++ ") schema.Freecam`, found " ++ @typeName(F));
        }
    }

    if (!@hasDecl(P, "start")) {
        @compileError(what ++ " must declare `pub fn start(self: *" ++ @typeName(P) ++ ", ctx: *sdk.Context) !void`");
    }
    const start = @typeInfo(@TypeOf(P.start)).@"fn";
    if (start.param_types.len != 2 or start.param_types[0].? != *P or start.param_types[1].? != *Context) {
        @compileError("`start` must take `(self: *" ++ @typeName(P) ++ ", ctx: *sdk.Context)`");
    }
    if (@typeInfo(start.return_type.?) != .error_union) {
        @compileError("`start` must return an error union (`!void`)");
    }

    if (@hasDecl(P, "stop")) {
        const stop = @typeInfo(@TypeOf(P.stop)).@"fn";
        if (stop.param_types.len != 1 or stop.param_types[0].? != *P or stop.return_type.? != void) {
            @compileError("`stop` must be `pub fn stop(self: *" ++ @typeName(P) ++ ") void`");
        }
    }
}
