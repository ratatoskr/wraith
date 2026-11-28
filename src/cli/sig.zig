//! `wraith sig`: the shortest unique signature for addresses in an exe on disk, as plugins' schemas
//! take them, from tuft's sig maker.

const std = @import("std");

const core = @import("wraith_core");
const mem = @import("tuft_mem");

const ops = @import("ops.zig");
const cli = @import("args.zig");

const log = core.log.scoped(.wraith_cli);

pub const usage =
    \\  sig <path to exe> <address>...       the shortest unique signature for each address, like
    \\                                       Ghidra's: there, or at code that points to it (Rip)
;

pub fn run(ctx: ops.Context, args: *cli.Args) !u8 {
    const path = args.next() orelse return cli.usageError(usage);
    if (cli.isFlag(path)) return cli.unexpected(path, usage);
    const addresses = args.rest();
    if (addresses.len == 0) return cli.usageError(usage);

    var arena: std.heap.ArenaAllocator = .init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const data = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .unlimited) catch |err| {
        log.err("Couldn't read {s}: {t}", .{ path, err });
        return 1;
    };
    const code = codeOf(data) orelse {
        log.err("{s} isn't an exe or DLL with code", .{path});
        return 1;
    };

    var failed = false;
    for (addresses) |text| {
        const trimmed = if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
        const target = std.fmt.parseInt(usize, trimmed, 16) catch {
            log.err("{s} isn't an address in hex", .{text});
            failed = true;
            continue;
        };
        const made = mem.sig_maker.make(a, code.bytes, code.base, target, .{}) catch |err| {
            log.err("{x}: {t}", .{ target, err });
            failed = true;
            continue;
        };
        const found = made orelse {
            log.printLn("{x}  nothing unique", .{target});
            failed = true;
            continue;
        };
        var buf: [mem.Sig.max_len * 3]u8 = undefined;
        const rip = found.resolve.len > 0;
        log.printLn("{x}  \"{s}\"{s}", .{ target, patternText(found.pattern, &buf), if (rip) ", Rip" else "" });
        if (rip) log.printLn("{s: <10} at {x}, pointing to it", .{ "", found.at });
    }
    return if (failed) 1 else 0;
}

const Code = struct { bytes: []const u8, base: usize };

/// The `.text` section, and where it sits once loaded at its preferred base.
fn codeOf(data: []const u8) ?Code {
    if (data.len < 0x40 or !std.mem.eql(u8, data[0..2], "MZ")) return null;
    const pe = std.mem.readInt(u32, data[0x3c..][0..4], .little);
    if (pe + 24 > data.len or !std.mem.eql(u8, data[pe..][0..4], "PE\x00\x00")) return null;
    const sections = std.mem.readInt(u16, data[pe + 6 ..][0..2], .little);
    const optional_size = std.mem.readInt(u16, data[pe + 20 ..][0..2], .little);
    const optional = pe + 24;
    const magic = std.mem.readInt(u16, data[optional..][0..2], .little);
    // PE32+ has an 8-byte image base at 24, PE32 a 4-byte one at 28
    const image_base: usize = if (magic == 0x20b) @intCast(std.mem.readInt(u64, data[optional + 24 ..][0..8], .little)) else std.mem.readInt(u32, data[optional + 28 ..][0..4], .little);
    var at = optional + optional_size;
    for (0..sections) |_| {
        if (at + 40 > data.len) return null;
        if (std.mem.startsWith(u8, data[at..][0..8], ".text")) {
            const vaddr = std.mem.readInt(u32, data[at + 12 ..][0..4], .little);
            const size = std.mem.readInt(u32, data[at + 16 ..][0..4], .little);
            const raw = std.mem.readInt(u32, data[at + 20 ..][0..4], .little);
            if (raw + size > data.len) return null;
            return .{ .bytes = data[raw..][0..size], .base = image_base + vaddr };
        }
        at += 40;
    }
    return null;
}

fn patternText(p: []const ?u8, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    for (p, 0..) |b, i| {
        if (i > 0) w.writeByte(' ') catch break;
        if (b) |v| w.print("{X:0>2}", .{v}) catch break else w.writeAll("??") catch break;
    }
    return w.buffered();
}

test "patterns print as schemas take them" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("E8 ?? 4C", patternText(&.{ 0xE8, null, 0x4C }, &buf));
}

test "only exes and DLLs have code to look in" {
    try std.testing.expectEqual(null, codeOf("not an exe at all, just some text that's long enough to check"));
}
