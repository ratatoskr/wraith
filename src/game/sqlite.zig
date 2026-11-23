//! Just enough SQLite to read another program's database, for stores that keep their games in one.

const std = @import("std");

const c = @import("sqlite");

pub const Db = struct {
    handle: *c.sqlite3,

    /// `path` is a copy, since the store may be writing to its own. `create` makes it if it's not there.
    pub fn open(path: [:0]const u8, options: struct { create: bool = false }) !Db {
        var handle: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(path.ptr, &handle, c.SQLITE_OPEN_READWRITE | if (options.create) c.SQLITE_OPEN_CREATE else 0, null) != c.SQLITE_OK) {
            _ = c.sqlite3_close_v2(handle);
            return error.CantOpenDatabase;
        }
        return .{ .handle = handle.? };
    }

    pub fn close(self: Db) void {
        _ = c.sqlite3_close_v2(self.handle);
    }

    pub fn prepare(self: Db, sql: [:0]const u8) !Statement {
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.handle, sql.ptr, @intCast(sql.len + 1), &stmt, null) != c.SQLITE_OK) return error.BadQuery;
        return .{ .handle = stmt orelse return error.BadQuery };
    }
};

pub const Statement = struct {
    handle: *c.sqlite3_stmt,

    pub fn deinit(self: Statement) void {
        _ = c.sqlite3_finalize(self.handle);
    }

    /// False once there are no more rows.
    pub fn step(self: Statement) !bool {
        return switch (c.sqlite3_step(self.handle)) {
            c.SQLITE_ROW => true,
            c.SQLITE_DONE => false,
            else => error.QueryFailed,
        };
    }

    pub fn int(self: Statement, column: c_int) i64 {
        return c.sqlite3_column_int64(self.handle, column);
    }

    /// Null for NULL. Copied into `arena`, since SQLite's goes with the next step.
    pub fn text(self: Statement, arena: std.mem.Allocator, column: c_int) !?[]const u8 {
        const ptr = c.sqlite3_column_text(self.handle, column) orelse return null;
        const len: usize = @intCast(c.sqlite3_column_bytes(self.handle, column));
        return try arena.dupe(u8, ptr[0..len]);
    }
};

test "reads what it wrote" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const path = try std.fs.path.joinZ(std.testing.allocator, &.{ dir, "t.db" });
    defer std.testing.allocator.free(path);

    const db = try Db.open(path, .{ .create = true });
    defer db.close();
    for ([_][:0]const u8{ "CREATE TABLE t (n INTEGER, s TEXT)", "INSERT INTO t VALUES (7, 'seven'), (8, NULL)" }) |sql| {
        const s = try db.prepare(sql);
        defer s.deinit();
        _ = try s.step();
    }
    const s = try db.prepare("SELECT n, s FROM t ORDER BY n");
    defer s.deinit();
    try std.testing.expect(try s.step());
    try std.testing.expectEqual(7, s.int(0));
    const seven = (try s.text(std.testing.allocator, 1)).?;
    defer std.testing.allocator.free(seven);
    try std.testing.expectEqualStrings("seven", seven);
    try std.testing.expect(try s.step());
    try std.testing.expectEqual(null, try s.text(std.testing.allocator, 1));
    try std.testing.expect(!try s.step());
    try std.testing.expectError(error.BadQuery, db.prepare("SELECT nope FROM nowhere"));
}
