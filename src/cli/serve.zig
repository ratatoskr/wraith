//! `wraith serve`: runs `ops` for the launcher, JSON lines over stdin and stdout.

const std = @import("std");
const Atomic = @import("tuft_arch").atomic.Value;

const core = @import("wraith_core");
const games = @import("wraith_game");
const proxy_info = @import("wraith_proxy_info");
const RwLock = @import("tuft_sys").sync.RwLock;
const build_info = @import("build_info");

const ops = @import("ops.zig");
const mods = @import("mods.zig");
const processes = @import("processes.zig");
const anticheat = games.anticheat;

const log = core.log.scoped(.wraith_cli);

/// Bump when a message change would break an older launcher.
pub const protocol = 3;

pub const Method = enum { processes, anticheat, inspect, identify, games, game_add, game_remove, executables, mods, mod_install, mod_remove, mod_update, install, uninstall, inject, launch, watch, play, cancel };

pub fn run(ctx: ops.Context) !void {
    var out_buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(ctx.io, &out_buf);
    var server: Server = .{ .ctx = ctx, .out = &out.interface };
    active = &server;
    // Logs go to the launcher as events
    _ = core.log.setSink(&log_sink);

    server.send(.{ .event = "ready", .protocol = protocol, .version = build_info.version });

    var in_buf: [64 * 1024]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(ctx.io, &in_buf);
    while (in.interface.takeDelimiter('\n') catch |err| {
        log.err("Couldn't read a request: {t}", .{err});
        return err;
    }) |line| server.receive(line);
}

var active: ?*Server = null;

const log_sink: core.log.Sink = .{ .write = writeLog };

fn writeLog(record: *const core.log.Record) void {
    const server = active orelse return;
    server.send(.{ .event = "log", .level = record.level, .scope = record.scope, .message = record.message });
}

const Server = struct {
    ctx: ops.Context,
    out: *std.Io.Writer,
    out_lock: RwLock = .{},
    calls: std.ArrayList(*Call) = .empty,
    calls_lock: RwLock = .{},

    fn send(self: *Server, message: anytype) void {
        self.out_lock.lock();
        defer self.out_lock.unlock();
        std.json.Stringify.value(message, .{}, self.out) catch return;
        self.out.writeByte('\n') catch return;
        self.out.flush() catch return;
    }

    fn fail(self: *Server, id: ?u64, err: anyerror) void {
        self.send(.{ .id = id, .@"error" = @errorName(err) });
    }

    fn receive(self: *Server, line: []const u8) void {
        const text = std.mem.trim(u8, line, " \t\r");
        if (text.len == 0) return;

        const call = Call.init(self, text) catch |err| {
            // The id might not be readable, so answer with what we can
            const id = if (std.json.parseFromSlice(struct { id: u64 }, self.ctx.allocator, text, .{ .ignore_unknown_fields = true })) |parsed| blk: {
                defer parsed.deinit();
                break :blk parsed.value.id;
            } else |_| null;
            return self.fail(id, err);
        };

        if (call.method == .cancel) {
            defer call.deinit();
            const params = call.params(struct { id: u64 }) catch |err| return self.fail(call.id, err);
            self.cancel(params.id);
            return self.send(.{ .id = call.id, .result = @as(struct {}, .{}) });
        }

        self.calls_lock.lock();
        defer self.calls_lock.unlock();
        self.calls.append(self.ctx.allocator, call) catch |err| {
            call.deinit();
            return self.fail(call.id, err);
        };
        const thread = std.Thread.spawn(.{}, Call.run, .{call}) catch |err| {
            _ = self.calls.pop();
            self.fail(call.id, err);
            return call.deinit();
        };
        thread.detach();
    }

    fn cancel(self: *Server, id: u64) void {
        self.calls_lock.lock();
        defer self.calls_lock.unlock();
        for (self.calls.items) |call| {
            if (call.id == id) call.cancelled.store(true, .release);
        }
    }

    fn finish(self: *Server, call: *Call) void {
        {
            self.calls_lock.lock();
            defer self.calls_lock.unlock();
            for (self.calls.items, 0..) |c, i| {
                if (c == call) {
                    _ = self.calls.swapRemove(i);
                    break;
                }
            }
        }
        call.deinit();
    }
};

const Call = struct {
    server: *Server,
    arena: std.heap.ArenaAllocator,
    id: u64,
    method: Method,
    raw_params: std.json.Value,
    cancelled: Atomic(bool) = .init(false),

    fn init(server: *Server, text: []const u8) !*Call {
        const gpa = server.ctx.allocator;
        const call = try gpa.create(Call);
        errdefer gpa.destroy(call);
        call.* = .{ .server = server, .arena = .init(gpa), .id = undefined, .method = undefined, .raw_params = undefined };
        errdefer call.arena.deinit();

        const Request = struct { id: u64, method: []const u8, params: std.json.Value = .null };
        const request = std.json.parseFromSliceLeaky(Request, call.arena.allocator(), text, .{
            .ignore_unknown_fields = true,
            // `text` is the reader's buffer and gets reused
            .allocate = .alloc_always,
        }) catch return error.BadRequest;
        call.id = request.id;
        call.method = std.meta.stringToEnum(Method, request.method) orelse return error.UnknownMethod;
        call.raw_params = request.params;
        return call;
    }

    fn deinit(self: *Call) void {
        const gpa = self.server.ctx.allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn params(self: *Call, comptime T: type) !T {
        return std.json.parseFromValueLeaky(T, self.arena.allocator(), self.raw_params, .{ .ignore_unknown_fields = true }) catch error.BadParams;
    }

    fn run(self: *Call) void {
        const server = self.server;
        defer server.finish(self);
        self.perform() catch |err| server.fail(self.id, err);
    }

    fn perform(self: *Call) !void {
        const ctx = self.server.ctx;
        switch (self.method) {
            .processes => {
                const p = try self.params(struct { all: bool = false });
                self.reply(try processes.list(self.arena.allocator(), ctx.io, .{ .all = p.all }));
            },
            .anticheat => self.reply(try anticheat.system(self.arena.allocator())),
            .inspect => {
                const p = try self.params(struct { exe: []const u8 });
                const found = try ops.inspect(ctx, p.exe);
                var taken: std.ArrayList([]const u8) = .empty;
                for (proxy_info.proxies, found.proxies) |proxy, presence| {
                    if (presence == .theirs) try taken.append(self.arena.allocator(), proxy.name);
                }
                var ac: anticheat.List = .{};
                try anticheat.ofGame(self.arena.allocator(), ctx.io, p.exe, &ac);
                const installed: ?[]const u8 = if (found.installed()) |proxy| proxy.name else null;
                const game = try ops.identify(ctx, self.arena.allocator(), p.exe);
                try ac.addTagged(self.arena.allocator(), game.anticheat);
                self.reply(.{ .arch = found.arch, .installed = installed, .taken = taken.items, .anticheat = ac.items.items, .game = game });
            },
            .identify => {
                const p = try self.params(struct { exe: []const u8 });
                self.reply(try ops.identify(ctx, self.arena.allocator(), p.exe));
            },
            .games => {
                const arena = self.arena.allocator();
                const Listed = struct {
                    id: []const u8,
                    store: games.Store,
                    name: ?[]const u8,
                    dir: []const u8,
                    launch: games.Launch,
                    known: ?games.KnownGame,
                    last_played: ?i64,
                    added: bool,
                    anticheat: []const anticheat.Found,
                };
                const found = try ops.discover(ctx, arena);
                const listed = try arena.alloc(Listed, found.len);
                for (listed, found) |*l, g| {
                    var ac: anticheat.List = .{};
                    try anticheat.ofInstall(arena, ctx.io, g.dir, &ac);
                    try ac.addTagged(arena, g.anticheat);
                    l.* = .{ .id = g.id, .store = g.store, .name = g.name, .dir = g.dir, .launch = g.launch, .known = g.known, .last_played = g.last_played, .added = g.added, .anticheat = ac.items.items };
                }
                self.reply(listed);
            },
            .game_add => {
                const p = try self.params(struct { exe: []const u8 });
                self.reply(try ops.addGame(ctx, self.arena.allocator(), p.exe));
            },
            .game_remove => {
                const p = try self.params(struct { id: []const u8 });
                self.reply(.{ .removed = try ops.removeGame(ctx, self.arena.allocator(), p.id) });
            },
            .install => {
                const p = try self.params(struct { exe: []const u8, as: ?[]const u8 = null });
                const as = if (p.as) |name| proxy_info.Proxy.find(name) orelse return error.UnknownProxy else proxy_info.proxies[0];
                const arch = try ops.install(ctx, p.exe, as);
                self.reply(.{ .arch = arch, .proxy = as.name });
            },
            .uninstall => {
                const p = try self.params(struct { exe: []const u8 });
                self.reply(.{ .removed = try ops.uninstall(ctx, p.exe) });
            },
            .inject => {
                const p = try self.params(struct { target: []const u8 });
                const injected = try ops.injectRunning(ctx, p.target);
                self.attached(injected.pid);
                self.reply(injected);
            },
            .launch => {
                const p = try self.params(struct { exe: []const u8, args: []const []const u8 = &.{} });
                const pid = try ops.launch(ctx, p.exe, p.args);
                self.attached(pid);
                self.reply(.{ .pid = pid });
            },
            .watch => {
                const p = try self.params(struct { exe: ?[]const u8 = null, dir: ?[]const u8 = null });
                const target: ops.WatchTarget = if (p.exe) |exe| .{ .name = std.fs.path.basename(exe) } else if (p.dir) |dir| .{ .folder = dir } else return error.BadParams;
                const pid = try ops.watch(ctx, target, self.watchOptions());
                self.reply(.{ .pid = pid });
            },
            .play => {
                const p = try self.params(struct { id: []const u8, exe: ?[]const u8 = null, how: ops.How = .inject });
                const pid = try ops.play(ctx, self.arena.allocator(), p.id, p.exe, p.how, self.watchOptions());
                self.reply(.{ .pid = pid });
            },
            .executables => {
                const p = try self.params(struct { dir: []const u8, exe: ?[]const u8 = null });
                self.reply(try ops.executables(ctx, self.arena.allocator(), p.dir, p.exe));
            },
            .mods => self.reply(try mods.catalog(ctx, self.arena.allocator())),
            .mod_install => {
                const p = try self.params(struct { id: []const u8, version: ?[]const u8 = null });
                self.reply(.{ .version = try mods.install(ctx, self.arena.allocator(), p.id, p.version) });
            },
            .mod_remove => {
                const p = try self.params(struct { id: []const u8 });
                try mods.remove(ctx, self.arena.allocator(), p.id);
                self.reply(@as(struct {}, .{}));
            },
            .mod_update => self.reply(.{ .updated = try mods.updateAll(ctx, self.arena.allocator()) }),
            // Handled on receive
            .cancel => unreachable,
        }
    }

    fn reply(self: *Call, result: anytype) void {
        self.server.send(.{ .id = self.id, .result = result });
    }

    fn watchOptions(self: *Call) ops.WatchOptions {
        return .{ .cancel = &self.cancelled, .on_attached = .{ .context = self, .call = onAttached } };
    }

    fn attached(self: *Call, pid: u32) void {
        self.server.send(.{ .event = "attached", .id = self.id, .pid = pid });
    }

    fn onAttached(context: ?*anyopaque, pid: u32) void {
        const self: *Call = @ptrCast(@alignCast(context.?));
        self.attached(pid);
    }
};

const tests = struct {
    const testing = std.testing;

    fn exchange(lines: []const []const u8, out: []u8) ![]const u8 {
        var writer: std.Io.Writer = .fixed(out);
        var server: Server = .{ .ctx = .{ .allocator = testing.allocator, .io = testing.io, .dir = "" }, .out = &writer };
        defer server.calls.deinit(testing.allocator);
        for (lines) |line| server.receive(line);
        return writer.buffered();
    }

    test "bad requests" {
        var out: [1024]u8 = undefined;
        try testing.expectEqualStrings(
            \\{"id":null,"error":"BadRequest"}
            \\{"id":7,"error":"UnknownMethod"}
            \\{"id":8,"error":"BadParams"}
            \\{"id":9,"result":{}}
            \\
        , try exchange(&.{
            "not json",
            \\{"id":7,"method":"fly"}
            ,
            \\{"id":8,"method":"cancel","params":{"id":"x"}}
            ,
            "",
            \\{"id":9,"method":"cancel","params":{"id":3}}
            ,
        }, &out));
    }
};

test {
    _ = tests;
}
