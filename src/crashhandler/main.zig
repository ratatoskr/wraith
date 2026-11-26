//! wraith_crashhandler_<arch>.exe: crash work from outside the game, where its locks can't hang us.
//!
//!   dump <pid> <file.dmp> [<thread id> <EXCEPTION_POINTERS address>]
//!     A minidump, stopped at that exception if given. The address is in the game's memory.
//!
//! Exits 0 when done, 1 for bad arguments, 2 when it fails.

const std = @import("std");

const sys = @import("tuft_sys");

pub const Command = union(enum) {
    dump: Dump,

    pub const Dump = struct {
        pid: u32,
        path: []const u8,
        thread_id: u32 = 0,
        /// 0 for none.
        exception: usize = 0,
    };
};

pub fn parse(args: []const []const u8) !Command {
    if (args.len == 0) return error.NoCommand;
    if (std.mem.eql(u8, args[0], "dump")) {
        if (args.len != 3 and args.len != 5) return error.BadArguments;
        var dump: Command.Dump = .{ .pid = try std.fmt.parseInt(u32, args[1], 10), .path = args[2] };
        if (args.len == 5) {
            dump.thread_id = try std.fmt.parseInt(u32, args[3], 10);
            dump.exception = try std.fmt.parseInt(usize, args[4], 0);
        }
        return .{ .dump = dump };
    }
    return error.UnknownCommand;
}

pub fn main(init: std.process.Init) u8 {
    const allocator = std.heap.smp_allocator;
    var list: std.ArrayList([]const u8) = .empty;
    var args = init.minimal.args.iterateAllocator(allocator) catch return 2;
    _ = args.skip();
    while (args.next()) |arg| list.append(allocator, arg) catch return 2;

    const command = parse(list.items) catch |err| {
        std.debug.print("{t}. Usage: dump <pid> <file.dmp> [<thread id> <EXCEPTION_POINTERS address>]\n", .{err});
        return 1;
    };
    switch (command) {
        .dump => |d| sys.exceptions.writeMinidumpOf(d.pid, d.path, d.thread_id, d.exception) catch |err| {
            std.debug.print("Couldn't dump {d}: {t}\n", .{ d.pid, err });
            return 2;
        },
    }
    return 0;
}

test parse {
    const plain = (try parse(&.{ "dump", "42", "C:\\a.dmp" })).dump;
    try std.testing.expectEqual(42, plain.pid);
    try std.testing.expectEqualStrings("C:\\a.dmp", plain.path);
    try std.testing.expectEqual(0, plain.exception);

    const crash = (try parse(&.{ "dump", "42", "a.dmp", "7", "0x1000" })).dump;
    try std.testing.expectEqual(7, crash.thread_id);
    try std.testing.expectEqual(0x1000, crash.exception);

    try std.testing.expectError(error.BadArguments, parse(&.{ "dump", "42" }));
    try std.testing.expectError(error.UnknownCommand, parse(&.{"nope"}));
}
