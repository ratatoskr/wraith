//! `wraith publish`: a package up to the hub, with a token.

const std = @import("std");

const core = @import("wraith_core");
const platform = @import("wraith_platform");

const ops = @import("ops.zig");
const cli = @import("args.zig");
const pack = @import("pack.zig");

const log = core.log.scoped(.wraith_cli);

pub const default_hub = "https://hub.wraith.io";

pub const usage =
    \\  publish [<file.zip | folder>] [--notes <text>] [--review] [--token <token>] [--hub <url>]
    \\                                       up to the hub: a zip from pack, or the plugin or
    \\                                       project in <folder> (default here), packed first. With
    \\                                       a token from the hub's Create page, or a managed
    \\                                       account's, by --token or WRAITH_HUB_TOKEN. It's out
    \\                                       straight away if its account can publish without
    \\                                       review, unless --review; otherwise it waits for a
    \\                                       reviewer. A version the hub has already is fine.
    \\                                       --notes: what's new. --hub, or WRAITH_HUB_URL: another
    \\                                       hub than hub.wraith.io
;

pub fn run(ctx: ops.Context, args: *cli.Args) !u8 {
    var what: []const u8 = ".";
    var given = false;
    var notes: ?[]const u8 = null;
    var token_flag: ?[]const u8 = null;
    var hub_flag: ?[]const u8 = null;
    var review = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--notes")) {
            notes = args.value(arg) orelse return 1;
        } else if (std.mem.eql(u8, arg, "--token")) {
            token_flag = args.value(arg) orelse return 1;
        } else if (std.mem.eql(u8, arg, "--hub")) {
            hub_flag = args.value(arg) orelse return 1;
        } else if (std.mem.eql(u8, arg, "--review")) {
            review = true;
        } else if (!given and !cli.isFlag(arg)) {
            what = arg;
            given = true;
        } else return cli.unexpected(arg, usage);
    }
    var arena_state: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const token = token_flag orelse (try platform.process.envAlloc(arena, "WRAITH_HUB_TOKEN")) orelse {
        log.err("It needs a token: --token, or WRAITH_HUB_TOKEN. Make one on the hub's Create page", .{});
        return 1;
    };
    const hub = std.mem.trimEnd(u8, hub_flag orelse (try platform.process.envAlloc(arena, "WRAITH_HUB_URL")) orelse default_hub, "/");

    const bytes = if (std.ascii.endsWithIgnoreCase(what, ".zip"))
        std.Io.Dir.cwd().readFileAlloc(ctx.io, what, arena, .limited(512 << 20)) catch |err| {
            log.err("Can't read {s}: {t}", .{ what, err });
            return 1;
        }
    else
        (pack.pack(ctx, arena, what) catch |err| switch (err) {
            error.Said => return 1,
            else => return err,
        }).bytes;

    const url = try uploadUrl(arena, hub, !review, notes);
    log.info("Uploading {d} bytes to {s}", .{ bytes.len, hub });
    const got = upload(ctx.io, arena, url, token, bytes) catch |err| {
        log.err("Couldn't reach {s}: {t}", .{ hub, err });
        return 2;
    };
    const o = outcome(arena, got);
    if (o.code == 0) log.printLn("{s}", .{o.message}) else {
        log.err("{s}", .{o.message});
        for (o.problems) |p| log.err("  {s}", .{p});
    }
    return o.code;
}

const Reply = struct { status: std.http.Status, body: []const u8 };

fn upload(io: std.Io, arena: std.mem.Allocator, url: []const u8, token: []const u8, bytes: []const u8) !Reply {
    var client: std.http.Client = .{ .allocator = arena, .io = io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(arena);
    const auth = try std.fmt.allocPrint(arena, "Bearer {s}", .{token});
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = bytes,
        .headers = .{ .content_type = .{ .override = "application/zip" }, .authorization = .{ .override = auth } },
        .response_writer = &body.writer,
    });
    return .{ .status = result.status, .body = body.written() };
}

const Outcome = struct { code: u8, message: []const u8, problems: []const []const u8 = &.{} };

/// What the hub said, and the exit code for it.
fn outcome(arena: std.mem.Allocator, got: Reply) Outcome {
    const Body = struct {
        id: ?[]const u8 = null,
        version: ?[]const u8 = null,
        state: ?[]const u8 = null,
        @"error": ?[]const u8 = null,
        problems: ?[]const []const u8 = null,
    };
    const parsed = std.json.parseFromSliceLeaky(Body, arena, got.body, .{ .ignore_unknown_fields = true }) catch Body{};
    if (got.status == .conflict) return .{ .code = 0, .message = std.fmt.allocPrint(arena, "The hub has it already: {s}", .{parsed.@"error" orelse "that version's there"}) catch "The hub has it already" };
    if (got.status.class() == .success) return .{
        .code = 0,
        .message = std.fmt.allocPrint(arena, "{s} {s}: {s}", .{ parsed.id orelse "?", parsed.version orelse "?", describeState(parsed.state orelse "?") }) catch "Uploaded",
    };
    return .{
        .code = 2,
        .message = std.fmt.allocPrint(arena, "The hub said {d}: {s}", .{ @backingInt(got.status), parsed.@"error" orelse std.mem.trim(u8, got.body, " \r\n") }) catch "The hub turned it down",
        .problems = parsed.problems orelse &.{},
    };
}

fn describeState(state: []const u8) []const u8 {
    if (std.mem.eql(u8, state, "published")) return "out on the hub";
    if (std.mem.eql(u8, state, "pending")) return "waiting for a reviewer";
    return state;
}

pub fn uploadUrl(arena: std.mem.Allocator, hub: []const u8, publish: bool, notes: ?[]const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.print("{s}/api/v1/upload?publish={d}", .{ hub, @intFromBool(publish) });
    if (notes) |n| {
        try w.writeAll("&notes=");
        for (n) |c| {
            if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') try w.writeByte(c) else try w.print("%{X:0>2}", .{c});
        }
    }
    return out.written();
}

test "the upload's URL says whether to publish, and what's new" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("https://hub.example/api/v1/upload?publish=1", try uploadUrl(a, "https://hub.example", true, null));
    try std.testing.expectEqualStrings("https://hub.example/api/v1/upload?publish=0&notes=Fixes%20it%0A%26%20more", try uploadUrl(a, "https://hub.example", false, "Fixes it\n& more"));
}

test "what the hub says is an exit code" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = outcome(a, .{ .status = .ok, .body = "{\"id\":\"kai\",\"version\":\"1.0.0\",\"state\":\"published\"}" });
    try std.testing.expectEqual(0, out.code);
    try std.testing.expectEqualStrings("kai 1.0.0: out on the hub", out.message);
    try std.testing.expectEqual(0, outcome(a, .{ .status = .conflict, .body = "{\"error\":\"kai 1.0.0 is out already\"}" }).code);
    const bad = outcome(a, .{ .status = .bad_request, .body = "{\"error\":\"Bad\",\"problems\":[\"id\"]}" });
    try std.testing.expectEqual(2, bad.code);
    try std.testing.expectEqualStrings("The hub said 400: Bad", bad.message);
    try std.testing.expectEqual(1, bad.problems.len);
    try std.testing.expectEqualStrings("The hub said 502: not json", outcome(a, .{ .status = .bad_gateway, .body = "not json" }).message);
}
