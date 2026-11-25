//! The built-in `cs` kind, for C# plugins made with Wraith's C# SDK. One compiled with NativeAOT is a
//! native plugin, `wraith_<id>_<arch>.dll`, and runs like one. Otherwise it's `wraith_<id>.dll`, run
//! by CoreCLR in a load context of its own that goes when it unloads. Either way its
//! `Ratatoskr.Wraith.Entry.Get` gives the same `NativeEntry`, so it starts like a native plugin.
//!
//! A process only gets one CoreCLR. This joins the game's, or starts the installed .NET if its
//! `clrMode` lets it, and then every C# plugin shares it.

const std = @import("std");

const core = @import("wraith_core");
const api = @import("wraith_api");
const sdk = @import("wraith_sdk");
const tuft_managed = @import("tuft_managed");
const sys = @import("tuft_sys");
const Atomic = @import("tuft_arch").atomic.Value;

const host = @import("../host/root.zig");
const Managed = @import("../Managed.zig");
const Loaded = @import("Loaded.zig");
const Known = @import("Known.zig");
const native = @import("native.zig");

const sal = api.salamander;
const log = core.log.scoped(.wraith_runtime);
/// The CoreCLR handle lives as long as the process does, like the runtime.
const gpa = std.heap.smp_allocator;
const CoreClr = tuft_managed.CoreClr;

pub const name = "cs";

/// Opened by the first C# plugin. Under `lock`.
var clr: ?CoreClr = null;
var lock: sys.sync.Mutex = .{};

/// Whether a CoreCLR's running that C# plugins can use.
pub fn available() bool {
    {
        lock.lock();
        defer lock.unlock();
        if (clr != null) return true;
    }
    const k = Managed.global.kind() orelse return false;
    return k == .coreclr;
}

/// Whether `known` has to wait for the game's .NET before it can load.
pub fn mustWait(known: *const Known) bool {
    const provider = known.provider orelse return false;
    return std.ascii.eqlIgnoreCase(provider, name) and known.clr_mode == .wait and !available();
}

/// The CoreCLR to run `loaded` in, joining or starting one as its `clrMode` says. Null after
/// saying why it can't.
fn open(loaded: *const Loaded) ?*const CoreClr {
    lock.lock();
    defer lock.unlock();
    if (clr) |*c| return c;
    const m = &Managed.global;
    const io = host.wraith.ioOf() orelse return null;
    const dir = m.clr_dir orelse {
        log.err("Can't run C# plugins without a folder for .NET's config", .{});
        return null;
    };
    const games = tuft_managed.coreclr.clr.running();
    if (!games) switch (loaded.manifest.value.clrMode) {
        .load => {},
        .wait => {
            log.err("Plugin {s} waits for the game's .NET, which isn't running", .{loaded.name});
            return null;
        },
        .provided => {
            log.err("Plugin {s} only runs in the game's .NET, and the game doesn't have one running", .{loaded.name});
            return null;
        },
    };
    // So Managed doesn't take it for the game's
    if (!games) m.ours.store(true, .release);
    var messages: std.Io.Writer.Allocating = .init(gpa);
    defer messages.deinit();
    clr = CoreClr.open(gpa, io, .{ .dir = dir, .start = !games, .messages = &messages.writer }) catch |err| {
        const status: u32 = @bitCast(tuft_managed.coreclr.clr.lastStatus());
        switch (err) {
            error.NoDotnet => log.err("C# plugins need .NET 10 installed (https://dot.net), unless the game has its own", .{}),
            error.NotRunning => log.err("The game's .NET hasn't started yet, so plugin {s} can't run. \"clrMode\": \"wait\" waits for it", .{loaded.name}),
            error.NotHostedByFxr => log.err("The game started .NET without hostfxr, so Wraith can't run C# plugins in it", .{}),
            error.InitFailed => log.err("Couldn't {s} .NET for C# plugins (hostfxr 0x{x}): {s}", .{ if (games) "join the game's" else "start", status, messages.written() }),
            else => log.err("Couldn't {s} .NET for C# plugins: {t}", .{ if (games) "join the game's" else "start", err }),
        }
        return null;
    };
    if (games) {
        log.info("C# plugins run in the game's .NET", .{});
    } else {
        log.info("Started .NET for C# plugins", .{});
        // Plugins waiting for one can go now, after this one
        m.tellCoreClr();
    }
    return &clr.?;
}

/// One C# plugin run by CoreCLR.
const Instance = struct {
    isolated: CoreClr.Isolated,
    entry: *const api.NativeEntry,
};

const Kind = struct {
    pub fn start(_: *Kind, guest: host.wraith.Guest) sal.Plain(host.wraith.PluginKind, "start") {
        const loaded = native.loadedOf(guest) orelse return error.Failed;
        const io = host.wraith.ioOf() orelse return error.Failed;
        if (native.hasLibrary(loaded, io)) return native.startNative(guest);
        const instance = load(loaded) catch return error.Failed;
        if (!native.startEntry(loaded, guest, instance.entry)) {
            free(instance);
            return error.Failed;
        }
        return sal.Object(host.wraith.Plugin).init(instance, running_table);
    }
};

fn load(loaded: *Loaded) !*Instance {
    const cc = open(loaded) orelse return error.NoDotnet;
    const file = try std.fmt.allocPrint(gpa, "wraith_{s}.dll", .{loaded.name});
    defer gpa.free(file);
    const path = try std.fs.path.join(gpa, &.{ loaded.copy_dir, file });
    defer gpa.free(path);

    var why: []const u8 = "";
    const isolated = cc.loadIsolated(gpa, path, &why) orelse {
        defer if (why.len > 0) gpa.free(why);
        log.err("Couldn't load {s}, or a NativeAOT build of it: {s}", .{ file, why });
        return error.LoadFailed;
    };
    errdefer cc.unloadIsolated(isolated);
    const at = cc.isolatedFunction(isolated, "Ratatoskr.Wraith.Entry", "Get") orelse {
        log.err("{s} isn't a Wraith plugin (it has no Ratatoskr.Wraith.Entry, which Wraith's C# SDK makes)", .{file});
        return error.NotAPlugin;
    };
    const entry = try native.entryOf(@ptrFromInt(at), file);
    const instance = try gpa.create(Instance);
    instance.* = .{ .isolated = isolated, .entry = entry };
    return instance;
}

/// Its context goes once nothing in it's used anymore, which the GC decides.
fn free(instance: *Instance) void {
    lock.lock();
    const cc = &clr.?;
    lock.unlock();
    cc.unloadIsolated(instance.isolated);
    gpa.destroy(instance);
}

const Running = struct {
    pub fn stop(instance: *Instance) void {
        instance.entry.stop();
    }

    pub fn unload(instance: *Instance) void {
        free(instance);
    }

    pub fn module(_: *Instance) usize {
        return 0;
    }

    pub fn service(instance: *Instance, trait: []const u8) sal.AnyObject {
        return instance.entry.service(.init(trait));
    }
};

var kind: Kind = .{};
var running_table: *const sal.Table(host.wraith.Plugin) = undefined;
var provided = Atomic(bool).init(false);

/// Provides the kind, once for the process. Its owner is the runtime's, which outlives every plugin.
pub fn provide() void {
    if (provided.swap(true, .acq_rel)) return;
    const h = sal.host();
    const owner = h.owner("wraith") catch return provided.store(false, .release);
    running_table = h.adopt(host.wraith.Plugin, sal.implement(host.wraith.Plugin, Running), owner) catch return provided.store(false, .release);
    const k = sal.Object(host.wraith.PluginKind).init(&kind, sal.implement(host.wraith.PluginKind, Kind));
    h.provide("wraith.kind." ++ name, 1, h.own(k, owner) catch return provided.store(false, .release)) catch |err| {
        log.err("Couldn't provide the {s} plugin kind: {t}", .{ name, err });
    };
}
