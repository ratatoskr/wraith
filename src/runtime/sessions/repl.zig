//! Top-level `await` for JS typed into a session, like in the Console. Code that awaits is wrapped
//! in an async function whose result prints once it settles. As an expression first, so
//! `await memory.scan(...)` shows what it gave, else as statements, with top-level `let`, `const`
//! and `var` put on `globalThis` so they outlast the function like they would at the top.

const std = @import("std");

pub const Form = enum { expression, statements };

/// `await` as a word of its own, not in `awaited` or `my_await`.
pub fn awaits(code: []const u8) bool {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, code, at, "await")) |i| : (at = i + 1) {
        const before = i == 0 or !isWordChar(code[i - 1]);
        const after = i + 5 >= code.len or !isWordChar(code[i + 5]);
        if (before and after) return true;
    }
    return false;
}

fn isWordChar(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$';
}

const show =
    \\(v) => { if (v !== undefined) log.info(typeof v === "string" ? v : (JSON.stringify(v) ?? String(v))); }
;
// QuickJS's stack hasn't the message in it
const fail =
    \\(e) => log.err(String(e) + (e && e.stack ? "\n" + e.stack : ""))
;

/// The caller frees it.
pub fn wrap(gpa: std.mem.Allocator, code: []const u8, form: Form) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    switch (form) {
        .expression => {
            const expr = std.mem.trimEnd(u8, code, " \t\r\n;");
            try w.print("(async () => (\n{s}\n))().then({s}, {s})", .{ expr, show, fail });
        },
        .statements => {
            try w.writeAll("(async () => {\n");
            var lines = std.mem.splitScalar(u8, code, '\n');
            while (lines.next()) |line| {
                try w.writeAll(hoisted(line));
                if (hoisted(line).ptr != line.ptr) try w.writeAll(line[declarationEnd(line)..]);
                try w.writeByte('\n');
            }
            try w.print("}})().then(() => {{}}, {s})", .{fail});
        },
    }
    return out.toOwnedSlice();
}

const keywords = [_][]const u8{ "let ", "const ", "var " };

/// `globalThis.` for a declaration at the start of a line, else the line itself.
fn hoisted(line: []const u8) []const u8 {
    return if (declarationEnd(line) > 0) "globalThis." else line;
}

/// Past its keyword, for a simple `let name = ...` at the start of a line. 0 if it isn't one.
fn declarationEnd(line: []const u8) usize {
    for (keywords) |k| {
        if (!std.mem.startsWith(u8, line, k)) continue;
        const rest = line[k.len..];
        var i: usize = 0;
        while (i < rest.len and isWordChar(rest[i])) i += 1;
        if (i == 0) return 0;
        const after = std.mem.trimStart(u8, rest[i..], " ");
        if (after.len == 0 or after[0] != '=' or (after.len > 1 and after[1] == '=')) return 0;
        return k.len;
    }
    return 0;
}

const testing = std.testing;

test "only code that awaits" {
    try testing.expect(awaits("await frame.next()"));
    try testing.expect(awaits("const x = (await f());"));
    try testing.expect(!awaits("awaited + my_await"));
    try testing.expect(!awaits("1 + 1"));
}

test "an expression, then statements with their names kept" {
    const expr = try wrap(testing.allocator, "await f();", .expression);
    defer testing.allocator.free(expr);
    try testing.expect(std.mem.startsWith(u8, expr, "(async () => (\nawait f()\n))().then("));

    const stmts = try wrap(testing.allocator, "const hp = await read();\n  let inner = 1;\nlog.info(hp)", .statements);
    defer testing.allocator.free(stmts);
    try testing.expect(std.mem.indexOf(u8, stmts, "\nglobalThis.hp = await read();\n") != null);
    // Only at the top, not inside a block
    try testing.expect(std.mem.indexOf(u8, stmts, "\n  let inner = 1;\n") != null);
}
