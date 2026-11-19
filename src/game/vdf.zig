//! Valve's KeyValues text format, VDF.

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    object: Object,
};

pub const Field = struct {
    key: []const u8,
    value: Value,
};

pub const Object = struct {
    fields: []const Field = &.{},

    pub fn get(self: Object, key: []const u8) ?Value {
        for (self.fields) |field| {
            if (std.ascii.eqlIgnoreCase(field.key, key)) return field.value;
        }
        return null;
    }

    pub fn string(self: Object, key: []const u8) ?[]const u8 {
        return switch (self.get(key) orelse return null) {
            .string => |s| s,
            .object => null,
        };
    }

    pub fn object(self: Object, key: []const u8) ?Object {
        return switch (self.get(key) orelse return null) {
            .object => |o| o,
            .string => null,
        };
    }
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) !Object {
    var parser: Parser = .{ .arena = arena, .text = text };
    return parser.object(false);
}

const Parser = struct {
    arena: std.mem.Allocator,
    text: []const u8,
    pos: usize = 0,

    const Token = union(enum) { open, close, string: []const u8 };

    fn object(self: *Parser, nested: bool) error{ OutOfMemory, InvalidVdf }!Object {
        var fields: std.ArrayList(Field) = .empty;
        while (true) {
            const key = switch (try self.token() orelse if (nested) return error.InvalidVdf else break) {
                .close => if (nested) break else return error.InvalidVdf,
                .open => return error.InvalidVdf,
                .string => |s| s,
            };
            const value: Value = switch (try self.token() orelse return error.InvalidVdf) {
                .open => .{ .object = try self.object(true) },
                .close => return error.InvalidVdf,
                .string => |s| .{ .string = s },
            };
            try fields.append(self.arena, .{ .key = key, .value = value });
        }
        return .{ .fields = fields.items };
    }

    fn token(self: *Parser) !?Token {
        const t = self.text;
        while (self.pos < t.len) {
            const c = t[self.pos];
            if (std.ascii.isWhitespace(c)) {
                self.pos += 1;
            } else if (std.mem.startsWith(u8, t[self.pos..], "//")) {
                self.pos = std.mem.indexOfScalarPos(u8, t, self.pos, '\n') orelse t.len;
            } else if (c == '[') {
                self.pos = (std.mem.indexOfScalarPos(u8, t, self.pos, ']') orelse return error.InvalidVdf) + 1;
            } else break;
        } else return null;

        switch (t[self.pos]) {
            '{' => {
                self.pos += 1;
                return .open;
            },
            '}' => {
                self.pos += 1;
                return .close;
            },
            '"' => return .{ .string = try self.quoted() },
            else => {
                const start = self.pos;
                while (self.pos < t.len and !std.ascii.isWhitespace(t[self.pos]) and std.mem.indexOfScalar(u8, "{}\"", t[self.pos]) == null) self.pos += 1;
                return .{ .string = t[start..self.pos] };
            },
        }
    }

    fn quoted(self: *Parser) ![]const u8 {
        const t = self.text;
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.pos < t.len) : (self.pos += 1) {
            switch (t[self.pos]) {
                '"' => {
                    self.pos += 1;
                    return out.items;
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos == t.len) break;
                    try out.append(self.arena, switch (t[self.pos]) {
                        'n' => '\n',
                        't' => '\t',
                        else => |e| e,
                    });
                },
                else => |c| try out.append(self.arena, c),
            }
        }
        return error.InvalidVdf;
    }
};

test parse {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try parse(arena.allocator(),
        \\// Steam's library folders
        \\"libraryfolders"
        \\{
        \\    "0"
        \\    {
        \\        "path"        "C:\\Program Files (x86)\\Steam"
        \\        "label"        "say \"hi\""
        \\        "apps" { "228980" "1234" } [$WIN32]
        \\    }
        \\    bare word
        \\}
    );
    const library = root.object("LibraryFolders").?.object("0").?;
    try std.testing.expectEqualStrings("C:\\Program Files (x86)\\Steam", library.string("path").?);
    try std.testing.expectEqualStrings("say \"hi\"", library.string("label").?);
    try std.testing.expectEqualStrings("1234", library.object("apps").?.string("228980").?);
    try std.testing.expectEqualStrings("word", root.object("libraryfolders").?.string("bare").?);
    try std.testing.expectError(error.InvalidVdf, parse(arena.allocator(), "\"unclosed\" { \"a\" \"b\""));
}
