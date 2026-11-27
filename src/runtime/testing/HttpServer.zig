//! A local HTTP server for tests: answers on 127.0.0.1 till `end`, one request a connection.

const Server = @This();

const std = @import("std");
const testing = std.testing;
const Atomic = std.atomic.Value;

listener: std.Io.net.Server,
port: u16,
stop: Atomic(bool) = .init(false),
thread: std.Thread = undefined,

pub fn start(self: *Server) !void {
    const at = try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    self.* = .{ .listener = try at.listen(testing.io, .{ .reuse_address = true }), .port = 0 };
    self.port = self.listener.socket.address.getPort();
    self.thread = try std.Thread.spawn(.{}, serve, .{self});
}

pub fn end(self: *Server) void {
    self.stop.store(true, .release);
    // Wakes its accept
    const at = std.Io.net.IpAddress.parseIp4("127.0.0.1", self.port) catch unreachable;
    if (at.connect(testing.io, .{ .mode = .stream })) |s| s.close(testing.io) else |_| {}
    self.thread.join();
    self.listener.deinit(testing.io);
}

fn serve(self: *Server) void {
    const io = testing.io;
    while (true) {
        const stream = self.listener.accept(io) catch return;
        defer stream.close(io);
        if (self.stop.load(.acquire)) return;
        var in_buf: [4096]u8 = undefined;
        var out_buf: [4096]u8 = undefined;
        var in = stream.reader(io, &in_buf);
        var out = stream.writer(io, &out_buf);
        var http: std.http.Server = .init(&in.interface, &out.interface);
        var req = http.receiveHead() catch continue;
        self.answer(&req) catch {};
    }
}

fn answer(self: *Server, req: *std.http.Server.Request) !void {
    const close: std.http.Server.Request.RespondOptions = .{ .keep_alive = false };
    const path = req.head.target;
    if (std.mem.eql(u8, path, "/hello")) return req.respond("hi", .{ .keep_alive = false, .extra_headers = &.{.{ .name = "x-test", .value = "1" }} });
    if (std.mem.eql(u8, path, "/redirect")) return req.respond("", .{ .keep_alive = false, .status = .found, .extra_headers = &.{.{ .name = "location", .value = "/hello" }} });
    if (std.mem.eql(u8, path, "/away")) {
        var buf: [64]u8 = undefined;
        const to = try std.fmt.bufPrint(&buf, "http://localhost:{d}/hello", .{self.port});
        return req.respond("", .{ .keep_alive = false, .status = .found, .extra_headers = &.{.{ .name = "location", .value = to }} });
    }
    // Answers after a second, for timeouts
    if (std.mem.eql(u8, path, "/slow")) {
        testing.io.sleep(.fromMilliseconds(1000), .awake) catch {};
        return req.respond("late", close);
    }
    if (std.mem.eql(u8, path, "/file")) {
        const body: [1000]u8 = @splat('x');
        return req.respond(&body, close);
    }
    if (std.mem.eql(u8, path, "/echo")) {
        var buf: [256]u8 = undefined;
        const body = try req.readerExpectNone(&buf).allocRemaining(testing.allocator, .limited(256));
        defer testing.allocator.free(body);
        return req.respond(body, close);
    }
    return req.respond("", .{ .keep_alive = false, .status = .not_found });
}

pub fn url(self: *const Server, buf: []u8, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
}
