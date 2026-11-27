//! `net.sal`: HTTP for plugins, a thread each request. Every host, redirects too, has to be declared.

const std = @import("std");

const api = @import("wraith_api");
const core = @import("wraith_core");
const sync = @import("tuft_sys").sync;
const Atomic = @import("tuft_arch").atomic.Value;

const wraith = @import("wraith.zig");
const threads = @import("threads.zig");
const Loaded = @import("../PluginLoader.zig").Loaded;

const sal = api.salamander;
const W = api.wraith;
const Raw = api.wraith_raw;
const log = core.log.scoped(.wraith_runtime);
const allocator = std.heap.smp_allocator;

pub const Net = W.Net;

const FetchPromise = sal.Plain(Net, "fetch");
const DownloadPromise = sal.Plain(Net, "download");
const FetchResolver = threads.Back(wraith.ResolverOf(FetchPromise));
const DownloadResolver = threads.Back(wraith.ResolverOf(DownloadPromise));

/// What `fetch` keeps when the request doesn't say.
pub const fetch_max = 64 << 20;
const max_redirects = 5;
/// How long it waits with nothing arriving when the request doesn't say.
pub const default_timeout_ms = 30_000;

const Error = error{ Failed, NotDeclared, InvalidUrl, TooBig, Status, WriteFailed, Timeout, Gone };

pub const Impl = struct {
    pub fn fetch(loaded: *Loaded, request: W.Net.Request) FetchPromise {
        const pair = FetchPromise.make() catch return .{};
        const t = wraith.tablesOf(loaded) orelse {
            pair.resolver.drop();
            return pair.promise;
        };
        if (checkUrl(loaded, request.url)) |err| {
            pair.resolver.fail(err);
            return pair.promise;
        }
        const job = Job.make(loaded, t.owner, request, null) catch {
            pair.resolver.fail(error.Failed);
            return pair.promise;
        };
        job.work = .{ .fetch = .of(pair.resolver, loaded) };
        job.start();
        return pair.promise;
    }

    pub fn download(loaded: *Loaded, request: W.Net.Request, path: []const u8) DownloadPromise {
        const pair = DownloadPromise.make() catch return .{};
        const t = wraith.tablesOf(loaded) orelse {
            pair.resolver.drop();
            return pair.promise;
        };
        if (checkUrl(loaded, request.url)) |err| {
            pair.resolver.fail(err);
            return pair.promise;
        }
        const full = target(loaded, path) catch |err| {
            pair.resolver.fail(err);
            return pair.promise;
        };
        const active = Active.add(loaded, full) catch {
            allocator.free(full);
            pair.resolver.fail(error.Failed);
            return pair.promise;
        };
        const job = Job.make(loaded, t.owner, request, active) catch {
            active.remove();
            pair.resolver.fail(error.Failed);
            return pair.promise;
        };
        job.work = .{ .download = .of(pair.resolver, loaded) };
        job.start();
        return pair.promise;
    }

    pub fn downloading(loaded: *Loaded, path: []const u8) W.Net.Progress {
        const full = target(loaded, path) catch return .{};
        defer allocator.free(full);
        return Active.find(loaded, full);
    }
};

/// Fails now, so the explanation reaches the caller.
fn checkUrl(loaded: *Loaded, url: []const u8) ?anyerror {
    const uri = parseUrl(url) catch return sal.host().explain(error.InvalidUrl, "{s} isn't an http:// or https:// URL", .{url});
    var buf: [256]u8 = undefined;
    const name = hostOf(uri, &buf) catch return error.InvalidUrl;
    if (!loaded.allowsHost(name)) return notDeclared(name);
    return null;
}

fn notDeclared(name: []const u8) anyerror {
    return sal.host().explain(error.NotDeclared, "add \"{s}\" to \"net\" in \"permissions\" in its wraith.json", .{name});
}

fn parseUrl(url: []const u8) error{InvalidUrl}!std.Uri {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.InvalidUrl;
    if (uri.host == null) return error.InvalidUrl;
    return uri;
}

fn hostOf(uri: std.Uri, buf: []u8) error{InvalidUrl}![]const u8 {
    return (uri.host orelse return error.InvalidUrl).toRaw(buf) catch error.InvalidUrl;
}

/// Where a download to `path` goes. Outside its folders needs "files". Owned.
fn target(loaded: *Loaded, path: []const u8) ![]u8 {
    if (path.len == 0) return error.WriteFailed;
    const joined = if (std.fs.path.isAbsolute(path))
        try allocator.dupe(u8, path)
    else
        try std.fs.path.join(allocator, &.{ loaded.game_config_dir, path });
    defer allocator.free(joined);
    const full = try std.fs.path.resolve(allocator, &.{joined});
    errdefer allocator.free(full);
    if (!loaded.allows(.files) and !loaded.ownsPath(full)) return wraith.undeclared(error.WriteFailed, "files");
    return full;
}

/// A download in flight, for `downloading`.
const Active = struct {
    loaded: *Loaded,
    path: []u8,
    received: Atomic(u64) = .init(0),
    total: Atomic(u64) = .init(0),

    var lock: sync.Mutex = .{};
    var list: std.ArrayList(*Active) = .empty;

    /// Takes `path`.
    fn add(loaded: *Loaded, path: []u8) !*Active {
        const a = try allocator.create(Active);
        errdefer allocator.destroy(a);
        a.* = .{ .loaded = loaded, .path = path };
        lock.lock();
        defer lock.unlock();
        try list.append(allocator, a);
        return a;
    }

    fn remove(a: *Active) void {
        {
            lock.lock();
            defer lock.unlock();
            for (list.items, 0..) |x, i| if (x == a) {
                _ = list.swapRemove(i);
                break;
            };
        }
        allocator.free(a.path);
        allocator.destroy(a);
    }

    fn find(loaded: *Loaded, path: []const u8) W.Net.Progress {
        lock.lock();
        defer lock.unlock();
        for (list.items) |a| if (a.loaded == loaded and std.mem.eql(u8, a.path, path)) return .{
            .received = a.received.load(.monotonic),
            .total = a.total.load(.monotonic),
            .active = true,
        };
        return .{};
    }
};

/// One request, with copies of what it was asked, on a thread of its own.
const Job = struct {
    arena: std.heap.ArenaAllocator,
    owner: *sal.Owner,
    method: std.http.Method,
    url: []const u8,
    headers: []std.http.Header,
    body: []const u8,
    max: u64,
    /// Every host it can reach, copied since the plugin can go first.
    hosts: []const []const u8,
    any_host: bool,
    active: ?*Active,
    timeout_ns: u64,
    /// When something last arrived, for the watchdog.
    heard: Atomic(u64) = .init(0),
    work: union(enum) { none, fetch: FetchResolver, download: DownloadResolver } = .none,

    fn make(loaded: *Loaded, owner: *sal.Owner, request: W.Net.Request, active: ?*Active) !*Job {
        const job = try allocator.create(Job);
        errdefer allocator.destroy(job);
        job.arena = .init(allocator);
        errdefer job.arena.deinit();
        const a = job.arena.allocator();
        const headers = try a.alloc(std.http.Header, request.headers.len);
        for (request.headers, headers) |h, *out| out.* = .{ .name = try a.dupe(u8, h.name), .value = try a.dupe(u8, h.value) };
        const own = loaded.allowsHost("*");
        const declared = loaded.manifest.value.permissions.net;
        const hosts = try a.alloc([]const u8, declared.len);
        for (declared, hosts) |h, *out| out.* = try a.dupe(u8, h);
        job.* = .{
            .arena = job.arena,
            .owner = owner,
            .method = switch (request.method) {
                .get => .GET,
                .head => .HEAD,
                .post => .POST,
                .put => .PUT,
                .patch => .PATCH,
                .delete => .DELETE,
                else => .GET,
            },
            .url = try a.dupe(u8, request.url),
            .headers = headers,
            .body = try a.dupe(u8, request.body),
            .max = request.max_bytes,
            .hosts = hosts,
            .any_host = own,
            .active = active,
            .timeout_ns = @as(u64, if (request.timeout_ms == 0) default_timeout_ms else request.timeout_ms) * std.time.ns_per_ms,
        };
        return job;
    }

    fn start(job: *Job) void {
        const thread = std.Thread.spawn(.{}, run, .{job}) catch {
            switch (job.work) {
                .none => {},
                inline else => |r| r.fail(error.Failed),
            }
            return job.free();
        };
        thread.detach();
    }

    fn allows(job: *const Job, name: []const u8) bool {
        if (job.any_host) return true;
        for (job.hosts) |h| if (std.ascii.eqlIgnoreCase(h, name)) return true;
        return false;
    }

    /// Whether to stop: the plugin's going or the waiter gave up.
    fn stopping(job: *const Job) bool {
        if (!job.owner.isOpen()) return true;
        return switch (job.work) {
            .none => true,
            inline else => |r| r.cancelled(),
        };
    }

    fn run(job: *Job) void {
        defer job.free();
        switch (job.work) {
            .none => {},
            .fetch => |r| settle(job, r, job.send(r, Raw.Wraith_Net_Response, fetchBody)),
            .download => |r| settle(job, r, job.send(r, u64, downloadBody)),
        }
    }

    /// Races the request against a watchdog, which cancels it once it's stalled or should stop.
    fn send(job: *Job, r: anytype, comptime T: type, comptime consume: anytype) Error!T {
        const io = wraith.ioOf() orelse return error.Failed;
        const Outcome = union(enum) { done: Error!T, stalled: Error!void };
        var buf: [2]Outcome = undefined;
        var select: std.Io.Select(Outcome) = .init(io, &buf);
        job.hear();
        select.concurrent(.done, Talk(@TypeOf(r), T, consume).run, .{ job, io, r }) catch return error.Failed;
        select.concurrent(.stalled, watch, .{ job, io }) catch {
            _ = select.cancel();
            return error.Failed;
        };
        const first = select.await() catch {
            _ = select.cancel();
            return error.Failed;
        };
        switch (first) {
            .done => |got| {
                _ = select.cancel();
                return got;
            },
            .stalled => |why| {
                // It may have finished as the watchdog fired
                if (select.cancel()) |late| switch (late) {
                    .done => |got| if (got) |v| return v else |_| {},
                    .stalled => {},
                };
                return if (why) |_| error.Timeout else |err| err;
            },
        }
    }

    fn Talk(comptime R: type, comptime T: type, comptime consume: anytype) type {
        return struct {
            fn run(job: *Job, io: std.Io, r: R) Error!T {
                var client: std.http.Client = .{ .allocator = allocator, .io = io };
                defer client.deinit();
                return job.exchange(&client, io, T, r, consume);
            }
        };
    }

    /// Settles once nothing's arrived for its timeout, with `Gone` if it should stop instead.
    fn watch(job: *Job, io: std.Io) Error!void {
        while (true) {
            io.sleep(.fromMilliseconds(50), .awake) catch return error.Gone;
            if (job.stopping()) return error.Gone;
            if (core.timing.now() -| job.heard.load(.monotonic) >= job.timeout_ns) return;
        }
    }

    fn hear(job: *Job) void {
        job.heard.store(core.timing.now(), .monotonic);
    }

    /// In the plugin's owner, so unloading waits for it, or dropped if it's gone.
    fn settle(job: *Job, r: anytype, got: anytype) void {
        if (!job.owner.enter()) return r.drop();
        defer job.owner.leave();
        const v = got catch |err| return if (err == error.Gone) r.drop() else r.fail(err);
        r.settle(v);
    }

    fn free(job: *Job) void {
        if (job.active) |a| a.remove();
        job.arena.deinit();
        allocator.destroy(job);
    }

    /// Sends it, following redirects to declared hosts, and hands the response to `consume`.
    fn exchange(
        job: *Job,
        client: *std.http.Client,
        io: std.Io,
        comptime T: type,
        r: anytype,
        comptime consume: fn (*Job, std.Io, *std.http.Client.Response, @TypeOf(r)) Error!T,
    ) Error!T {
        const a = job.arena.allocator();
        var url = job.url;
        var method = job.method;
        var hops: u32 = 0;
        while (true) : (hops += 1) {
            if (job.stopping()) return error.Gone;
            const uri = try parseUrl(url);
            var buf: [256]u8 = undefined;
            const name = try hostOf(uri, &buf);
            if (!job.allows(name)) {
                log.warn("A plugin's request was sent on to {s}, which its wraith.json's \"net\" doesn't list", .{name});
                return error.NotDeclared;
            }
            var req = client.request(method, uri, .{
                .redirect_behavior = .unhandled,
                .keep_alive = false,
                // Downloads take the bytes as they are, so progress matches their length
                .headers = if (job.active != null) .{ .accept_encoding = .omit } else .{},
                .extra_headers = job.headers,
            }) catch return error.Failed;
            defer req.deinit();
            const has_body = method == .POST or method == .PUT or method == .PATCH;
            if (has_body) {
                req.transfer_encoding = .{ .content_length = job.body.len };
                var body = req.sendBodyUnflushed(&.{}) catch return error.Failed;
                body.writer.writeAll(job.body) catch return error.Failed;
                body.end() catch return error.Failed;
                req.connection.?.flush() catch return error.Failed;
            } else req.sendBodiless() catch return error.Failed;
            var response = req.receiveHead(&.{}) catch return error.Failed;
            job.hear();

            const status = response.head.status;
            if (status.class() == .redirect) if (response.head.location) |location| {
                if (hops >= max_redirects) return error.Failed;
                url = try resolveLocation(a, uri, location);
                // Like browsers: a 303, or a 301 or 302 after a post, asks again with a get
                if (status == .see_other or ((status == .moved_permanently or status == .found) and method == .POST)) method = .GET;
                continue;
            };
            return consume(job, io, &response, r);
        }
    }

    fn fetchBody(job: *Job, io: std.Io, response: *std.http.Client.Response, r: FetchResolver) Error!Raw.Wraith_Net_Response {
        _ = io;
        // Kept with the value, read before the body since reading it reuses their memory
        const keep = r.allocator();
        var headers: std.ArrayList(Raw.Wraith_Net_Header) = .empty;
        var it = response.head.iterateHeaders();
        while (it.next()) |h| headers.append(keep, .{
            .name = .init(keep.dupe(u8, h.name) catch return error.Failed),
            .value = .init(keep.dupe(u8, h.value) catch return error.Failed),
        }) catch return error.Failed;
        const status: u16 = @backingInt(response.head.status);

        const max = if (job.max == 0) fetch_max else job.max;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(allocator);
        var reading: Reading = .{};
        const reader = reading.open(response);
        var chunk: [16 << 10]u8 = undefined;
        while (true) {
            if (job.stopping()) return error.Gone;
            const n = reader.readSliceShort(&chunk) catch return error.Failed;
            if (n == 0) break;
            job.hear();
            if (body.items.len + n > max) return error.TooBig;
            body.appendSlice(allocator, chunk[0..n]) catch return error.Failed;
        }
        return .{
            .status = status,
            .headers = .init(headers.items),
            .body = sal.blobs.copy(body.items) catch return error.Failed,
        };
    }

    fn downloadBody(job: *Job, io: std.Io, response: *std.http.Client.Response, r: DownloadResolver) Error!u64 {
        _ = r;
        if (response.head.status.class() != .success) {
            log.debug("Download of {s}: HTTP {d}", .{ job.url, @backingInt(response.head.status) });
            return error.Status;
        }
        const active = job.active.?;
        if (response.head.content_length) |len| {
            if (job.max != 0 and len > job.max) return error.TooBig;
            active.total.store(len, .monotonic);
        }
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(active.path)) |dir| cwd.createDirPath(io, dir) catch return error.WriteFailed;
        const partial = std.fmt.allocPrint(job.arena.allocator(), "{s}.partial", .{active.path}) catch return error.Failed;
        const file = cwd.createFile(io, partial, .{}) catch return error.WriteFailed;
        var done = false;
        defer if (!done) cwd.deleteFile(io, partial) catch {};
        {
            defer file.close(io);
            var out_buf: [64 << 10]u8 = undefined;
            var out = file.writer(io, &out_buf);
            var reading: Reading = .{};
            const reader = reading.open(response);
            var chunk: [64 << 10]u8 = undefined;
            var size: u64 = 0;
            while (true) {
                if (job.stopping()) return error.Gone;
                const n = reader.readSliceShort(&chunk) catch return error.Failed;
                if (n == 0) break;
                job.hear();
                size += n;
                if (job.max != 0 and size > job.max) return error.TooBig;
                out.interface.writeAll(chunk[0..n]) catch return error.WriteFailed;
                active.received.store(size, .monotonic);
            }
            out.interface.flush() catch return error.WriteFailed;
        }
        cwd.rename(partial, cwd, active.path, io) catch return error.WriteFailed;
        done = true;
        return active.received.load(.monotonic);
    }
};

/// A response's body, decompressed if the server compressed it.
const Reading = struct {
    transfer: [64]u8 = undefined,
    decompress: std.http.Decompress = undefined,
    window: [std.compress.flate.max_window_len]u8 = undefined,

    fn open(self: *Reading, response: *std.http.Client.Response) *std.Io.Reader {
        return response.readerDecompressing(&self.transfer, &self.decompress, &self.window);
    }
};

/// A redirect's `location`, which can be relative to where it came from.
fn resolveLocation(a: std.mem.Allocator, from: std.Uri, location: []const u8) Error![]const u8 {
    if (std.mem.indexOf(u8, location, "://") != null) return a.dupe(u8, location) catch error.Failed;
    if (!std.mem.startsWith(u8, location, "/")) return error.Failed;
    var buf: [256]u8 = undefined;
    const name = try hostOf(from, &buf);
    return (if (from.port) |port|
        std.fmt.allocPrint(a, "{s}://{s}:{d}{s}", .{ from.scheme, name, port, location })
    else
        std.fmt.allocPrint(a, "{s}://{s}{s}", .{ from.scheme, name, location })) catch error.Failed;
}

const tests = struct {
    const testing = std.testing;
    const sdk = @import("wraith_sdk");
    const Manifest = @import("../Manifest.zig");

    const Server = @import("../testing/HttpServer.zig");

    fn get(u: []const u8) Raw.Wraith_Net_Request {
        return .{ .url = .init(u), .method = .get };
    }

    /// A plugin that declares 127.0.0.1, with `dir` as its folder for the game.
    fn start(loaded: *Loaded, dir: []const u8) !sal.Object(Net) {
        loaded.initForTest(testing.allocator, "kai");
        loaded.game_config_dir = dir;
        loaded.manifest = try Manifest.parse(testing.allocator, "{ \"id\": \"kai\", \"provider\": \"native\", \"permissions\": { \"net\": [\"127.0.0.1\"] } }", "wraith.json");
        sdk.Owner.attach(loaded.root());
        return sdk.wraith.root().?.net();
    }

    fn stop(loaded: *Loaded) void {
        loaded.manifest.deinit();
        loaded.manifest = .{};
        loaded.deinitForTest();
        wraith.forget(loaded);
        sdk.Owner.detach();
    }

    test "fetch gets the status, headers and body, following redirects to hosts it declares" {
        wraith.setIo(testing.io);
        defer wraith.setIo(null);
        var server: Server = undefined;
        try server.start();
        defer server.end();
        var loaded: Loaded = undefined;
        const net = try start(&loaded, "");
        defer stop(&loaded);
        var buf: [96]u8 = undefined;

        const hello = try net.fetch(get(server.url(&buf, "/hello"))).wait();
        defer hello.body.release();
        try testing.expectEqual(200, hello.status);
        try testing.expectEqualStrings("hi", hello.body.bytes());
        var tagged = false;
        for (hello.headers.get()) |h| if (std.ascii.eqlIgnoreCase(h.name.get(), "x-test")) {
            tagged = std.mem.eql(u8, h.value.get(), "1");
        };
        try testing.expect(tagged);

        const moved = try net.fetch(get(server.url(&buf, "/redirect"))).wait();
        defer moved.body.release();
        try testing.expectEqualStrings("hi", moved.body.bytes());

        // Any status settles
        const missing = try net.fetch(get(server.url(&buf, "/nothing"))).wait();
        defer missing.body.release();
        try testing.expectEqual(404, missing.status);

        var post = get(server.url(&buf, "/echo"));
        post.method = .post;
        post.body = .init("sent");
        const echoed = try net.fetch(post).wait();
        defer echoed.body.release();
        try testing.expectEqualStrings("sent", echoed.body.bytes());

        var small = get(server.url(&buf, "/file"));
        small.max_bytes = 10;
        try testing.expectError(error.TooBig, net.fetch(small).wait());
    }

    test "a request that hears nothing for its timeout fails" {
        wraith.setIo(testing.io);
        defer wraith.setIo(null);
        var server: Server = undefined;
        try server.start();
        defer server.end();
        var loaded: Loaded = undefined;
        const net = try start(&loaded, "");
        defer stop(&loaded);
        var buf: [96]u8 = undefined;

        var slow = get(server.url(&buf, "/slow"));
        slow.timeout_ms = 200;
        const began = core.timing.now();
        try testing.expectError(error.Timeout, net.fetch(slow).wait());
        try testing.expect(core.timing.now() - began < 900 * std.time.ns_per_ms);
    }

    test "hosts it doesn't declare are refused, redirects too" {
        wraith.setIo(testing.io);
        defer wraith.setIo(null);
        var server: Server = undefined;
        try server.start();
        defer server.end();
        var loaded: Loaded = undefined;
        const net = try start(&loaded, "");
        defer stop(&loaded);
        var buf: [96]u8 = undefined;

        const elsewhere = try std.fmt.bufPrint(&buf, "http://localhost:{d}/hello", .{server.port});
        try testing.expectError(error.NotDeclared, net.fetch(get(elsewhere)).wait());
        try testing.expectError(error.NotDeclared, net.fetch(get(server.url(&buf, "/away"))).wait());
        try testing.expectError(error.InvalidUrl, net.fetch(get("ftp://127.0.0.1/hello")).wait());
    }

    test "downloads stream to a file in its folder, and say how they're going" {
        wraith.setIo(testing.io);
        defer wraith.setIo(null);
        var server: Server = undefined;
        try server.start();
        defer server.end();
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
        defer testing.allocator.free(dir);
        var loaded: Loaded = undefined;
        const net = try start(&loaded, dir);
        defer stop(&loaded);
        var buf: [96]u8 = undefined;

        try testing.expect(!net.downloading("lists/paths.txt").active);
        try testing.expectEqual(1000, try net.download(get(server.url(&buf, "/file")), "lists/paths.txt").wait());
        const got = try tmp.dir.readFileAlloc(testing.io, "lists/paths.txt", testing.allocator, .limited(4096));
        defer testing.allocator.free(got);
        try testing.expectEqual(1000, got.len);
        // Done, so not in flight, and no partial file left
        try testing.expect(!net.downloading("lists/paths.txt").active);
        try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "lists/paths.txt.partial", .{}));

        try testing.expectError(error.Status, net.download(get(server.url(&buf, "/nothing")), "none.txt").wait());
        // Outside its folders needs "files"
        try testing.expectError(error.WriteFailed, net.download(get(server.url(&buf, "/file")), "../elsewhere.txt").wait());
    }
};

test {
    _ = tests;
}
