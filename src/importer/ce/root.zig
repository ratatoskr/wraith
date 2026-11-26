//! Cheat Engine tables to Wraith projects: scripts become tweaks in one nested group file,
//! records go to Addresses, and `import-report.md` lists what needs review.
//! The group uses `@globals shared` since CE runs a whole table in one Lua state.

const std = @import("std");
const tweak_format = @import("wraith_api").tweak;

pub const xml = @import("xml.zig");
pub const table = @import("table.zig");
pub const numbers = @import("numbers.zig");
pub const keys = @import("keys.zig");
pub const machine = @import("machine.zig");
pub const script = @import("script.zig");
pub const convert = @import("convert.zig");
pub const render = @import("render.zig");
pub const records = @import("records.zig");
pub const report = @import("report.zig");
pub const lua = @import("lua.zig");
pub const zip = @import("zip.zig");
pub const table_files = @import("files.zig");

const Entry = table.Entry;
pub const Stats = report.Stats;

pub const Options = struct {
    /// For the report's title, like the table's file name.
    name: []const u8 = "table",
};

pub const File = struct {
    /// Relative, with `/`, like `tweaks/god_mode.rwt`.
    path: []const u8,
    text: []const u8,
};

pub const Project = struct {
    files: []const File,
    stats: Stats,
    /// Also in `files`, as `import-report.md`.
    report: []const u8,
    /// Whether its scripts are 32-bit.
    bits: machine.Bits,
    /// Why each script that's off for review is, one line each.
    reviews: []const []const u8 = &.{},
};

pub const report_file = "import-report.md";
pub const addresses_file = "addresses.rwa.zon";

/// Everything is in `arena`. `gpa` is for scratch work.
pub fn import(arena: std.mem.Allocator, gpa: std.mem.Allocator, source: []const u8, options: Options) !Project {
    var imp: Importer = .{ .arena = arena, .gpa = gpa, .table = try table.read(arena, source), .report = .{ .arena = arena } };
    return imp.run(options);
}

/// A group or tweak in the table's file. The first is the file's group.
const Node = struct {
    /// Its CE script or header. Null for the file's group.
    entry: ?*const Entry,
    title: []const u8,
    group: bool,
    parent: ?usize,
    /// `@children` when it isn't `on off`.
    children: ?[]const u8 = null,
    /// Titles under the file's group, joined by `/`, which tweaks are saved by. Empty for it.
    path: []const u8,
    /// Its names' start, like `Table.Combat.God mode`.
    dotted: []const u8,
    part: ?render.Part = null,
    kids: std.ArrayList(usize) = .empty,
};

/// A name a script registered, and what others call it.
const Owner = struct {
    name: []const u8,
    entry: *const Entry,
    node: usize,
    /// Like `"Table.Combat.Max HP.base"`.
    full: []const u8,
};

const Use = struct {
    owner: *const Owner,
    by: []const u8,
};

/// A record that's one of a tweak's `@data` fields, by its name in the game's names.
const Data = struct {
    entry: *const Entry,
    name: []const u8,
};

/// A record's id in the Addresses list, so `(its description)` and the CE layer find it.
const Id = struct {
    entry: *const Entry,
    id: []const u8,
};

const Importer = struct {
    arena: std.mem.Allocator,
    gpa: std.mem.Allocator,
    table: table.Table,
    report: report.Report,
    stats: Stats = .{},
    bits: machine.Bits = .x64,
    main_module: ?[]const u8 = null,
    nodes: std.ArrayList(Node) = .empty,
    owners: std.ArrayList(Owner) = .empty,
    uses: std.ArrayList(Use) = .empty,
    items: std.ArrayList(records.Item) = .empty,
    data: std.ArrayList(Data) = .empty,
    file_path: []const u8 = "",
    reviews: std.ArrayList([]const u8) = .empty,
    ids: std.ArrayList(Id) = .empty,
    /// Ids start with it, like `kai.GameStateManager`, so two tables' don't clash.
    id_prefix: []const u8 = "",
    /// The records manifest is written, so every entry it can point at gets an id.
    has_lua: bool = false,

    fn run(self: *Importer, options: Options) !Project {
        self.bits = self.detectBits();
        self.main_module = self.detectModule();
        if (self.bits == .x86) try self.report.note("Its scripts are 32-bit code.", .{});
        if (self.main_module) |m| try self.report.note("The game's exe looks like `{s}`. `$process` and `aobscan` now mean it.", .{m});

        const stem = std.fs.path.stem(options.name);
        const top_title = try safeTitle(self.arena, if (stem.len > 0) stem else "table");
        self.id_prefix = try render.slug(self.arena, top_title);
        self.file_path = try std.fmt.allocPrint(self.arena, "tweaks/{s}.rwt", .{self.id_prefix});
        // CE has no box for the whole table, so ticking ours leaves what's in it
        try self.nodes.append(self.arena, .{ .entry = null, .title = top_title, .group = true, .parent = null, .children = "none", .path = "", .dotted = top_title });
        try self.walk(self.table.entries, 0);
        try self.nameOwners();
        for (0..self.nodes.items.len) |i| if (self.nodes.items[i].entry) |e| if (e.isScript()) {
            self.nodes.items[i].part = try self.convertOne(i);
        };
        try self.checkUses();
        self.has_lua = self.table.lua != null or for (self.nodes.items) |n| {
            if (n.part != null and n.part.?.tweak.lua != null) break true;
        } else false;
        try self.referencedIds(self.table.entries);
        try self.symbols();
        try self.addRecords(self.table.entries, 0, null);

        var table_lua: ?[]const u8 = null;
        if (self.table.lua) |text| {
            const fixed, const loops = try lua.fixLoops(self.arena, try lua.body(self.arena, text));
            table_lua = fixed;
            if (loops > 0) try self.report.note("The table's Lua script assigned to {d} `for` loop variables, which Lua 5.5 doesn't allow, so each got a copy.", .{loops});
        }
        // Lua with nothing to hang it on gets a tweak of its own
        if (self.nodes.items.len == 1) if (table_lua) |text| {
            try self.nodes.append(self.arena, .{ .entry = null, .title = "Table Lua", .group = false, .parent = 0, .path = "Table Lua", .dotted = try std.fmt.allocPrint(self.arena, "{s}.Table Lua", .{top_title}), .part = .{ .title = "Table Lua", .tweak = .{ .status = .lua, .lua = .{ .on = text, .off = "" } } } });
            try self.nodes.items[0].kids.append(self.arena, 1);
            table_lua = null;
        };

        var files: std.ArrayList(File) = .empty;
        if (self.nodes.items.len > 1) {
            var head: std.ArrayList(u8) = .empty;
            const has_lua = self.has_lua;
            if (has_lua) {
                try head.appendSlice(self.arena, "-- ce: the table's records, for getAddressList()\n");
                try head.appendSlice(self.arena, try lua.manifest(self.arena, try self.manifest()));
                // Before the table's Lua, which may want them straight away
                try self.tableFiles(&head);
                if (table_lua) |text| {
                    try head.appendSlice(self.arena, "\n-- ce: the table's own Lua script, which CE ran when it opened the table\n");
                    try head.appendSlice(self.arena, text);
                }
            }
            try files.append(self.arena, .{ .path = self.file_path, .text = try self.finishFile(has_lua, head.items) });
            self.stats.tweak_files = 1;
        }
        self.countParts();
        for (self.items.items) |it| {
            if (it.group) self.stats.groups += 1 else self.stats.records += 1;
        }
        if (self.items.items.len > 0) try files.append(self.arena, .{ .path = addresses_file, .text = try records.zon(self.arena, self.items.items) });
        for (self.table.skipped) |s| try self.report.note("The table's `{s}` didn't come over.", .{s});
        const text = try self.report.markdown(options.name, self.stats);
        try files.append(self.arena, .{ .path = report_file, .text = text });
        return .{ .files = files.items, .stats = self.stats, .report = text, .bits = self.bits, .reviews = self.reviews.items };
    }
    // Guessing about the table

    /// Goes by which registers memory operands use more, since x86 tables can have a stray `[rsp]`.
    fn detectBits(self: *const Importer) machine.Bits {
        var votes: Votes = .{};
        for (self.table.entries) |*e| votes.count(e);
        return if (votes.x86 > votes.x64) .x86 else .x64;
    }

    const Votes = struct {
        x86: u32 = 0,
        x64: u32 = 0,

        fn count(self: *Votes, e: *const Entry) void {
            if (e.script) |s| {
                var from: usize = 0;
                while (std.mem.indexOfScalarPos(u8, s, from, '[')) |at| {
                    from = at + 1;
                    const rest = std.mem.trimStart(u8, s[at + 1 ..], " \t");
                    var n: usize = 0;
                    while (n < rest.len and n < 4 and std.ascii.isAlphanumeric(rest[n])) n += 1;
                    if (n < 2 or (n < rest.len and std.ascii.isAlphanumeric(rest[n]))) continue;
                    var buf: [4]u8 = undefined;
                    const word = std.ascii.lowerString(&buf, rest[0..n]);
                    const wide = [_][]const u8{ "rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rsp", "rbp", "rip", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15" };
                    const narrow = [_][]const u8{ "eax", "ebx", "ecx", "edx", "esi", "edi", "esp", "ebp" };
                    for (wide) |r| if (std.mem.eql(u8, word, r)) {
                        self.x64 += 1;
                    };
                    for (narrow) |r| if (std.mem.eql(u8, word, r)) {
                        self.x86 += 1;
                    };
                }
            }
            for (e.children) |*c| self.count(c);
        }
    };

    /// The exe named most, in scripts and addresses.
    fn detectModule(self: *Importer) ?[]const u8 {
        const Count = struct { name: []const u8, n: u32 };
        var counts: std.ArrayList(Count) = .empty;
        defer counts.deinit(self.gpa);
        var stack: std.ArrayList(*const Entry) = .empty;
        defer stack.deinit(self.gpa);
        for (self.table.entries) |*e| stack.append(self.gpa, e) catch return null;
        while (stack.pop()) |e| {
            for (e.children) |*c| stack.append(self.gpa, c) catch return null;
            for ([_][]const u8{ e.script orelse "", e.address orelse "" }) |text| {
                var from: usize = 0;
                while (std.ascii.findIgnoreCasePos(text, from, ".exe")) |at| {
                    from = at + 4;
                    var start = at;
                    while (start > 0 and (std.ascii.isAlphanumeric(text[start - 1]) or std.mem.indexOfScalar(u8, "_-. ", text[start - 1]) != null)) start -= 1;
                    const name = std.mem.trim(u8, text[start .. at + 4], " ");
                    if (name.len <= 4) continue;
                    for (counts.items) |*c| {
                        if (std.ascii.eqlIgnoreCase(c.name, name)) {
                            c.n += 1;
                            break;
                        }
                    } else counts.append(self.gpa, .{ .name = name, .n = 1 }) catch return null;
                }
            }
        }
        var best: ?[]const u8 = null;
        var most: u32 = 0;
        for (counts.items) |c| if (c.n > most) {
            most = c.n;
            best = c.name;
        };
        return best;
    }

    // The table's tree as groups and tweaks

    fn walk(self: *Importer, list: []const Entry, parent: usize) error{OutOfMemory}!void {
        for (list) |*e| {
            const below = anyScripts(e.children);
            if (e.isScript() or below) {
                const k = try self.addNode(e, parent, below);
                if (below) try self.walk(e.children, k);
            }
        }
    }

    fn addNode(self: *Importer, e: *const Entry, parent: usize, is_group: bool) !usize {
        const p = &self.nodes.items[parent];
        const plain = try render.title(self.arena, e.description);
        const base = try safeTitle(self.arena, e.description);
        var title = base;
        var n: usize = 2;
        while (self.siblingHas(parent, title)) : (n += 1) title = try std.fmt.allocPrint(self.arena, "{s} {d}", .{ base, n });
        if (!std.mem.eql(u8, title, plain)) {
            const why = if (!std.mem.eql(u8, base, plain)) "titles in a file with groups can't have /" else "something next to it has its name";
            try self.report.note("**{s}** is \"{s}\" now, since {s}.", .{ plain, title, why });
        }
        const k = self.nodes.items.len;
        try self.nodes.append(self.arena, .{
            .entry = e,
            .title = title,
            .group = is_group,
            .parent = parent,
            .children = if (is_group) childrenOf(e.*) else null,
            .path = if (p.path.len == 0) title else try std.fmt.allocPrint(self.arena, "{s}/{s}", .{ p.path, title }),
            .dotted = try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ p.dotted, title }),
        });
        try self.nodes.items[parent].kids.append(self.arena, k);
        return k;
    }

    fn siblingHas(self: *const Importer, parent: usize, title: []const u8) bool {
        for (self.nodes.items[parent].kids.items) |k| if (std.mem.eql(u8, self.nodes.items[k].title, title)) return true;
        return false;
    }

    fn nodeOf(self: *const Importer, e: *const Entry) ?usize {
        for (self.nodes.items, 0..) |n, i| if (n.entry == e) return i;
        return null;
    }

    /// What everyone else calls each registered name.
    fn nameOwners(self: *Importer) !void {
        for (self.nodes.items, 0..) |n, i| {
            const e = n.entry orelse continue;
            if (!e.isScript()) continue;
            for (try convert.registeredNames(self.arena, e.script orelse "")) |name| {
                try self.owners.append(self.arena, .{ .name = name, .entry = e, .node = i, .full = try quoted(self.arena, try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ n.dotted, name })) });
            }
        }
    }

    fn owner(self: *const Importer, name: []const u8, not: ?*const Entry) ?*const Owner {
        for (self.owners.items) |*o| if (o.entry != not and std.ascii.eqlIgnoreCase(o.name, name)) return o;
        return null;
    }

    fn userSymbol(self: *const Importer, name: []const u8) bool {
        for (self.table.symbols) |s| if (std.ascii.eqlIgnoreCase(s.name, name)) return true;
        return false;
    }

    /// Names as one script, or the Addresses list, sees them.
    const Scope = struct {
        imp: *Importer,
        /// Its node, whose groups' names it sees as they are.
        node: ?usize,
        what: []const u8,

        fn lookup(context: ?*const anyopaque, word: []const u8) numbers.Lookup {
            const self: *const Scope = @ptrCast(@alignCast(context.?));
            if (self.imp.userSymbol(word) or self.imp.isId(word)) return .known;
            const nodes = self.imp.nodes.items;
            const entry = if (self.node) |k| nodes[k].entry else null;
            var at = if (self.node) |k| nodes[k].parent else null;
            while (at) |g| : (at = nodes[g].parent) {
                const shared = nodes[g].entry orelse continue;
                for (self.imp.owners.items) |*o| if (o.entry == shared and std.ascii.eqlIgnoreCase(o.name, word)) {
                    self.imp.uses.append(self.imp.arena, .{ .owner = o, .by = self.what }) catch {};
                    return if (std.mem.eql(u8, o.name, word)) .known else .{ .rename = o.name };
                };
            }
            const o = self.imp.owner(word, entry) orelse return .unknown;
            self.imp.uses.append(self.imp.arena, .{ .owner = o, .by = self.what }) catch {};
            return .{ .rename = o.full };
        }

        fn names(self: *const Scope) numbers.Names {
            return .{ .context = self, .lookup = lookup };
        }
    };

    // Scripts to tweaks

    fn fileWhere(self: *const Importer) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "`{s}`", .{self.file_path});
    }

    fn convertOne(self: *Importer, k: usize) !render.Part {
        const n = self.nodes.items[k];
        const e = n.entry.?;
        const at = try self.fileWhere();
        const scope = try self.arena.create(Scope);
        scope.* = .{ .imp = self, .node = k, .what = e.description };
        const source = e.script orelse "";
        const t = try convert.convert(self.arena, self.gpa, source, .{ .bits = self.bits, .main_module = self.main_module, .names = scope.names() });
        var part: render.Part = .{ .title = n.title, .tweak = t, .original = source };
        part.key = try self.scriptKey(e, at);
        if (part.tweak.lua) |*l| l.pre = try memrecOf(self.arena, e, l.*);
        try self.validate(&part, k);
        for (part.tweak.notes) |note| try self.report.add(e.description, at, "{s}", .{note});
        for (part.tweak.ambiguous) |a| try self.report.ambiguous.append(self.arena, .{ .why = a, .what = e.description, .where = at });
        for (part.tweak.missing) |m| try self.report.addMissing(m, e.description, at);
        for (part.tweak.unshared) |u| try self.report.note("`{s}` from {s} was registered, but it's code, so other tweaks can't use it by name now.", .{ u, e.description });
        if (part.tweak.loops > 0) try self.report.note("**{s}** assigned to {d} `for` loop variables in its Lua, which Lua 5.5 doesn't allow, so each got a copy.", .{ e.description, part.tweak.loops });
        return part;
    }

    /// Its first activation hotkey as `@key`. The rest go in the report.
    fn scriptKey(self: *Importer, e: *const Entry, at: []const u8) !?[]const u8 {
        var key: ?[]const u8 = null;
        for (e.hotkeys) |h| {
            const toggles = std.ascii.startsWithIgnoreCase(h.action, "Toggle Activation") or std.ascii.eqlIgnoreCase(h.action, "Activate");
            const chord = try keys.chord(self.arena, h.keys);
            if (toggles and key == null and chord != null and tweak_format.parseChord(chord.?) != null) {
                key = chord;
                continue;
            }
            try self.report.add(e.description, at, "its hotkey {s} ({s}) didn't come over", .{ chord orelse "with keys we don't have", h.action });
        }
        return key;
    }

    /// Off for review if its asm doesn't assemble or the tweak doesn't parse.
    fn validate(self: *Importer, part: *render.Part, node: usize) !void {
        if (part.tweak.status != .clean) return;
        const names: KnownNames = .{ .imp = self, .tweak = &part.tweak, .node = node };
        for (part.tweak.code) |c| {
            if (c.kind == .bytes) continue;
            const source = try std.mem.join(self.arena, "\n", c.lines);
            if (try machine.check(self.arena, source, self.bits, .{ .context = &names, .func = KnownNames.has })) |problem| {
                return self.offForReview(part, try std.fmt.allocPrint(self.arena, "its asm for {s} doesn't assemble, {s}", .{ c.where, problem.message }));
            }
        }
        const lone = try render.file(self.arena, .{ .tweaks = &.{part.*} });
        var problem: tweak_format.Problem = .{};
        _ = tweak_format.parseFile(self.arena, lone.text, &problem) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Invalid => return self.offForReview(part, try std.fmt.allocPrint(self.arena, "the tweak didn't parse, {s}", .{problem.message()})),
        };
    }

    /// Names a tweak's asm can use in game: its own, modules, other tweaks' and the table's symbols.
    const KnownNames = struct {
        imp: *const Importer,
        tweak: *const convert.Tweak,
        /// Its groups' names are its own too.
        node: usize,

        fn has(context: ?*const anyopaque, name: []const u8) bool {
            const self: *const KnownNames = @ptrCast(@alignCast(context.?));
            if (std.mem.eql(u8, name, "original") or std.mem.eql(u8, name, "resume")) return true;
            if (self.tweak.publishes(name) or numbers.isModule(name) or self.imp.userSymbol(name) or self.imp.isId(name)) return true;
            const nodes = self.imp.nodes.items;
            var at = nodes[self.node].parent;
            while (at) |g| : (at = nodes[g].parent) {
                const part = nodes[g].part orelse continue;
                if (part.tweak.status == .clean and part.tweak.publishes(name)) return true;
            }
            // Another tweak's, as `"kai.Group.Tweak.name"`
            for (self.imp.owners.items) |o| if (std.mem.eql(u8, unquoted(o.full), name)) return true;
            return false;
        }
    };

    fn offForReview(self: *Importer, part: *render.Part, why: []const u8) !void {
        var problems: std.ArrayList([]const u8) = .empty;
        try problems.appendSlice(self.arena, part.tweak.problems);
        try problems.append(self.arena, why);
        part.tweak = .{ .status = .review, .problems = problems.items, .comments = part.tweak.comments, .ambiguous = part.tweak.ambiguous };
    }

    /// Names one script took from another that didn't come over.
    fn checkUses(self: *Importer) !void {
        for (self.uses.items, 0..) |u, k| {
            const dup = for (self.uses.items[0..k]) |before| {
                if (before.owner == u.owner and std.mem.eql(u8, before.by, u.by)) break true;
            } else false;
            if (dup) continue;
            const t = (self.nodes.items[u.owner.node].part orelse continue).tweak;
            if (t.status == .clean and t.publishes(u.owner.name)) continue;
            try self.report.add(u.by, try self.fileWhere(), "it uses {s} from {s}, which didn't come over as a name", .{ u.owner.name, u.owner.entry.description });
        }
    }
    // Records to the Addresses list

    /// The table's own symbols, as named entries.
    fn symbols(self: *Importer) !void {
        if (self.table.symbols.len == 0) return;
        try self.items.append(self.arena, .{ .name = "Symbols", .group = true, .expanded = false });
        for (self.table.symbols) |s| {
            const addr = try self.address(s.address, s.name);
            try self.items.append(self.arena, .{ .name = records.fit(s.name, records.max_name), .id = records.fit(s.name, records.max_name), .address = addr, .depth = 1 });
        }
    }

    fn address(self: *Importer, raw: []const u8, what: []const u8) ![]const u8 {
        const scope = try self.arena.create(Scope);
        scope.* = .{ .imp = self, .node = null, .what = what };
        var notes: numbers.Notes = .{};
        const text = try self.withIds(raw);
        const out = numbers.address(self.arena, text, scope.names(), &notes) catch {
            try self.report.add(what, "the Addresses list", "its address `{s}` has a number we can't read, so it's as it was", .{text});
            return text;
        };
        for (notes.unknown.items) |u| try self.report.addMissing(u, what, "the Addresses list");
        for (notes.ambiguous.items) |a| try self.report.ambiguous.append(self.arena, .{ .why = a, .what = what, .where = "the Addresses list" });
        return out;
    }

    fn addRecords(self: *Importer, list: []const Entry, depth: u8, script_parent: ?*const Entry) error{OutOfMemory}!void {
        for (list) |*e| {
            if (e.isScript()) {
                const at = self.items.items.len;
                try self.items.append(self.arena, .{ .name = records.fit(e.description, records.max_name), .group = true, .depth = depth, .expanded = !e.hide_children });
                try self.addRecords(e.children, depth + 1, e);
                if (self.items.items.len == at + 1) _ = self.items.pop();
                continue;
            }
            if (try self.absorb(e, script_parent)) {
                try self.addRecords(e.children, depth, null);
                continue;
            }
            const is_group = e.group_header or (e.address == null and e.type.len == 0);
            if (is_group) {
                const at = self.items.items.len;
                const addr = if (e.address) |a| try self.address(a, e.description) else "";
                const id = if (addr.len > 0) try self.idFor(e) else "";
                try self.items.append(self.arena, .{ .name = records.fit(e.description, records.max_name), .id = id, .address = addr, .offsets = try self.offsets(e), .group = true, .depth = depth, .expanded = !e.hide_children });
                try self.addRecords(e.children, depth + 1, null);
                if (self.items.items.len == at + 1 and addr.len == 0) _ = self.items.pop();
                continue;
            }
            var item = try self.record(e, depth);
            if (item.address.len > 0) item.id = try self.idFor(e);
            if (e.children.len > 0) {
                // Only groups have children, so it's a group with its value first
                try self.items.append(self.arena, .{ .name = item.name, .address = item.address, .offsets = item.offsets, .group = true, .depth = depth, .expanded = !e.hide_children });
                item.address = "+0";
                item.offsets = &.{};
                item.depth = depth + 1;
                try self.items.append(self.arena, item);
                try self.addRecords(e.children, depth + 1, null);
            } else try self.items.append(self.arena, item);
        }
    }

    fn offsets(self: *Importer, e: *const Entry) ![]const []const u8 {
        if (e.offsets.len > records.max_offsets) try self.report.add(e.description, "the Addresses list", "it has {d} offsets but only {d} fit", .{ e.offsets.len, records.max_offsets });
        const n = @min(e.offsets.len, records.max_offsets);
        const out = try self.arena.alloc([]const u8, n);
        for (e.offsets[0..n], out) |o, *d| {
            d.* = try self.address(o, e.description);
            if (d.len > records.max_offset) try self.report.add(e.description, "the Addresses list", "its offset `{s}` is too long for the list", .{d.*});
        }
        return out;
    }

    fn record(self: *Importer, e: *const Entry, depth: u8) !records.Item {
        const where = "the Addresses list";
        var kind = records.kindOf(e.*);
        var bits: ?records.Bits = null;
        if (kind == null) {
            if (std.ascii.eqlIgnoreCase(e.type, "Binary")) {
                const start = e.bit_start orelse 0;
                const width = @max(e.bit_length orelse 1, 1);
                const end = @as(u32, start) + width;
                kind = if (end <= 8) .byte else if (end <= 16) .two_bytes else if (end <= 32) .four_bytes else .eight_bytes;
                if (end <= 64) {
                    bits = .{ .shift = start, .width = width };
                } else try self.report.add(e.description, where, "it's {d} bits from bit {d}, more than 8 bytes, so it shows them all", .{ width, start });
            } else if (std.ascii.eqlIgnoreCase(e.type, "Custom")) {
                kind = .four_bytes;
                try self.report.add(e.description, where, "it's CE's custom type `{s}`, shown as 4 bytes", .{e.custom_type});
            } else if (e.type.len > 0) {
                kind = .four_bytes;
                try self.report.add(e.description, where, "its type `{s}` isn't one of ours, shown as 4 bytes", .{e.type});
            } else kind = .four_bytes;
        }
        const addr = if (e.address) |a| try self.address(a, e.description) else "";
        if (addr.len > records.max_address) try self.report.add(e.description, where, "its address is too long for the list", .{});
        var item: records.Item = .{
            .name = records.fit(e.description, records.max_name),
            .address = addr,
            .offsets = try self.offsets(e),
            .kind = kind.?,
            .length = records.lengthOf(e.*, kind.?),
            .depth = depth,
            .bits = bits,
        };
        if (e.dropdown) |d| try self.listChoices(e, d, &item);
        try self.recordKeys(e, where, &item);
        return item;
    }

    /// Its own choices, or a link to the record whose they are.
    fn listChoices(self: *Importer, e: *const Entry, d: table.DropDown, item: *records.Item) !void {
        item.labels_only = d.description_only;
        if (d.items.len == 0) if (d.link) |link| if (findEntry(self.table.entries, link)) |target| {
            if (!target.isScript() and target.address != null and target != e) {
                item.choices_from = try self.idFor(target);
                if (item.choices_from.len > 0) return;
            }
        };
        const items = self.dropdownItems(d);
        var out: std.ArrayList(records.Choice) = .empty;
        var skipped: usize = 0;
        for (items) |c| {
            const n = (if (e.show_hex) std.fmt.parseInt(i64, c.value, 16) else std.fmt.parseInt(i64, c.value, 10)) catch {
                skipped += 1;
                continue;
            };
            try out.append(self.arena, .{ .value = n, .label = c.label });
        }
        item.choices = out.items;
        if (skipped > 0) try self.report.add(e.description, "the Addresses list", "{d} of its dropdown's values aren't whole numbers, so they were left out", .{skipped});
    }

    /// CE's hotkeys as the list's, and its allow increase or decrease as how it's held.
    fn recordKeys(self: *Importer, e: *const Entry, where: []const u8, item: *records.Item) !void {
        var out: std.ArrayList(records.Hotkey) = .empty;
        for (e.hotkeys) |h| {
            const text = try keys.chord(self.arena, h.keys);
            const chord = if (text) |t| tweak_format.parseChord(t) else null;
            const action: ?records.Action = if (std.ascii.startsWithIgnoreCase(h.action, "Toggle Activation") or std.ascii.startsWithIgnoreCase(h.action, "Toggle Freeze"))
                .toggle_hold
            else if (std.ascii.eqlIgnoreCase(h.action, "Activate") or std.ascii.eqlIgnoreCase(h.action, "Freeze"))
                .hold
            else if (std.ascii.eqlIgnoreCase(h.action, "Deactivate") or std.ascii.eqlIgnoreCase(h.action, "Unfreeze"))
                .release
            else if (std.ascii.eqlIgnoreCase(h.action, "Set Value"))
                .set
            else if (std.ascii.eqlIgnoreCase(h.action, "Increase Value"))
                .increase
            else if (std.ascii.eqlIgnoreCase(h.action, "Decrease Value"))
                .decrease
            else
                null;
            if (std.ascii.endsWithIgnoreCase(h.action, "Allow Increase")) item.freeze = .only_increase;
            if (std.ascii.endsWithIgnoreCase(h.action, "Allow Decrease")) item.freeze = .only_decrease;
            if (chord == null or action == null or out.items.len == 8) {
                try self.report.add(e.description, where, "its hotkey {s} ({s}{s}{s}) didn't come over", .{ text orelse "with keys we don't have", h.action, if (h.value.len > 0) " " else "", h.value });
                continue;
            }
            try out.append(self.arena, .{ .chord = chord, .action = action.?, .value = if (action.? == .set or action.? == .increase or action.? == .decrease) h.value else "" });
        }
        item.hotkeys = out.items;
    }

    fn dropdownItems(self: *const Importer, d: table.DropDown) []const table.Choice {
        if (d.items.len > 0 or d.link == null) return d.items;
        const linked = findEntry(self.table.entries, d.link.?) orelse return &.{};
        const dd = linked.dropdown orelse return &.{};
        return dd.items;
    }

    /// A record of a tweak's data labels its field, and moves there if it's under that script.
    fn absorb(self: *Importer, e: *const Entry, script_parent: ?*const Entry) !bool {
        const raw = std.mem.trim(u8, e.address orelse return false, " \t");
        if (e.offsets.len > 0 or raw.len == 0) return false;
        for (raw) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
        const o = self.owner(raw, null) orelse return false;
        const part = &(self.nodes.items[o.node].part orelse return false);
        if (part.tweak.status != .clean) return false;
        const f = for (part.tweak.fields) |*f| {
            if (std.ascii.eqlIgnoreCase(f.name, o.name)) break f;
        } else return false;
        if (f.label.len == 0) f.label = try render.title(self.arena, e.description);
        if (e.dropdown) |d| if (f.attrs.len == 0) {
            if (try self.choices(self.dropdownItems(d), e.show_hex)) |attrs| {
                f.attrs = attrs;
                self.stats.choices += 1;
            }
        };
        try self.data.append(self.arena, .{ .entry = e, .name = o.full });
        if (script_parent != o.entry) return false;
        self.stats.absorbed += 1;
        try self.fieldKeys(e, f);
        return true;
    }

    /// A field record's toggle hotkey becomes `Key(...)`; others go in the report (one key per field).
    fn fieldKeys(self: *Importer, e: *const Entry, f: *convert.Field) !void {
        const at = try self.fileWhere();
        for (e.hotkeys) |h| {
            const text = try keys.chord(self.arena, h.keys);
            const toggles = std.ascii.startsWithIgnoreCase(h.action, "Toggle Activation");
            const flips = toggles and std.mem.startsWith(u8, f.attrs, "Toggle") and std.mem.indexOf(u8, f.attrs, "Key(") == null;
            if (flips) if (text) |t| if (tweak_format.parseChord(t) != null) {
                f.attrs = try std.fmt.allocPrint(self.arena, "{s}, Key({s})", .{ f.attrs, t });
                self.stats.keys += 1;
                continue;
            };
            const why = if (!toggles) "a field's key only flips it" else if (std.mem.indexOf(u8, f.attrs, "Key(") != null) "its field has a key already" else "a field's key only flips a Toggle";
            try self.report.add(e.description, at, "its hotkey {s} ({s}{s}{s}) didn't come over, {s}. It's the tweak's `{s}` field now", .{ text orelse "with keys we don't have", h.action, if (h.value.len > 0) " " else "", h.value, why, f.name });
        }
    }

    /// `Toggle` for off and on, else `Choices(...)`.
    fn choices(self: *Importer, items: []const table.Choice, hex: bool) !?[]const u8 {
        if (items.len == 0) return null;
        if (items.len == 2 and toggleLike(items)) return "Toggle";
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(self.arena, "Choices(");
        for (items, 0..) |c, k| {
            const n = (if (hex) std.fmt.parseInt(i64, c.value, 16) else std.fmt.parseInt(i64, c.value, 10)) catch return null;
            if (k > 0) try out.appendSlice(self.arena, ", ");
            try out.print(self.arena, "\"{d}:{s}\"", .{ n, try render.title(self.arena, c.label) });
        }
        try out.append(self.arena, ')');
        return out.items;
    }

    // Writing it out

    /// `ce.files { ... }`, for `findTableFile`. Ones that can't be read or are too big get a note.
    fn tableFiles(self: *Importer, head: *std.ArrayList(u8)) !void {
        var decoded: std.ArrayList(table_files.File) = .empty;
        for (self.table.files) |raw| {
            const f = table_files.decode(self.arena, raw) catch |err| {
                switch (err) {
                    error.TooBig => try self.report.note("The table file `{s}` is over 4 MB, so it didn't come over and `findTableFile` won't find it.", .{raw.name}),
                    error.InvalidFile => try self.report.note("The table file `{s}` couldn't be read, so it didn't come over.", .{raw.name}),
                    error.OutOfMemory => return error.OutOfMemory,
                }
                continue;
            };
            try decoded.append(self.arena, f);
        }
        if (decoded.items.len == 0) return;
        try head.appendSlice(self.arena, "\n-- ce: the table's files, for findTableFile\n");
        try head.appendSlice(self.arena, try lua.files(self.arena, decoded.items));
        try self.report.note("{d} table file(s) came over inside the tweak file, for `findTableFile` and `playSound`.", .{decoded.items.len});
    }

    /// The records manifest, every entry in table order, see `lua/API.md`.
    fn manifest(self: *Importer) ![]const lua.Record {
        var out: std.ArrayList(lua.Record) = .empty;
        var next_id: i64 = 1_000_000;
        try self.manifestOf(&out, self.table.entries, null, &next_id);
        return out.items;
    }

    fn manifestOf(self: *Importer, out: *std.ArrayList(lua.Record), list: []const Entry, parent: ?i64, next_id: *i64) !void {
        for (list) |*e| {
            const id = std.fmt.parseInt(i64, e.id, 10) catch blk: {
                next_id.* += 1;
                break :blk next_id.*;
            };
            var r: lua.Record = .{ .id = id, .parent = parent, .description = e.description, .type = e.type, .hex = e.show_hex, .signed = e.show_signed, .unicode = e.unicode, .bitstart = e.bit_start };
            r.length = e.length orelse e.byte_length orelse if (e.bit_length) |b| @as(u32, b) else null;
            var options: std.ArrayList(u8) = .empty;
            if (e.activate_children) try options.appendSlice(self.arena, "[moActivateChildrenAsWell]");
            if (e.deactivate_children) try options.appendSlice(self.arena, "[moDeactivateChildrenAsWell]");
            if (e.hide_children) try options.appendSlice(self.arena, "[moHideChildren]");
            r.options = options.items;
            if (e.dropdown) |d| {
                const lines = try self.arena.alloc([]const u8, d.items.len);
                for (d.items, lines) |c, *l| l.* = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ c.value, c.label });
                r.dropdown = lines;
                r.dropdown_link = d.link;
            }
            if (self.nodeOf(e)) |k| {
                if (e.isScript()) r.what = .{ .tweak = try std.fmt.allocPrint(self.arena, "./{s}", .{self.nodes.items[k].path}) };
            } else if (self.dataOf(e)) |name| {
                r.what = .{ .data = name };
            } else if (self.idOf(e)) |list_id| {
                r.what = .{ .address = list_id };
            } else if (e.address) |a| {
                const ce_offsets = try self.arena.dupe([]const u8, e.offsets);
                // CE's order, as in the .CT
                std.mem.reverse([]const u8, ce_offsets);
                r.what = .{ .location = .{ .text = a, .offsets = ce_offsets } };
            }
            try out.append(self.arena, r);
            try self.manifestOf(out, e.children, id, next_id);
        }
    }

    /// Records others use as `(description)` get ids first, since CE looks those up before symbols.
    fn referencedIds(self: *Importer, list: []const Entry) !void {
        for (list) |*e| {
            try self.referencesIn(e.address orelse "", e);
            for (e.offsets) |o| try self.referencesIn(o, e);
            try self.referencedIds(e.children);
        }
    }

    fn referencesIn(self: *Importer, text: []const u8, from: *const Entry) !void {
        var it: References = .{ .text = text };
        while (it.next()) |inner| {
            const e = self.referenced(inner, from) orelse continue;
            _ = try self.idFor(e);
        }
    }

    /// The record `(description)` means, if it's one that goes in the Addresses list.
    fn referenced(self: *const Importer, description: []const u8, from: *const Entry) ?*const Entry {
        const e = findEntry(self.table.entries, description) orelse return null;
        if (e == from or e.isScript() or e.address == null) return null;
        return e;
    }

    /// `(description)` as `(id)`, for records that have one.
    fn withIds(self: *Importer, text: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var copied: usize = 0;
        var it: References = .{ .text = text };
        while (it.next()) |inner| {
            const e = findEntry(self.table.entries, inner) orelse continue;
            const id = self.idOf(e) orelse continue;
            const start = @intFromPtr(inner.ptr) - @intFromPtr(text.ptr);
            try out.appendSlice(self.arena, text[copied..start]);
            try out.appendSlice(self.arena, id);
            copied = start + inner.len;
        }
        if (copied == 0) return text;
        try out.appendSlice(self.arena, text[copied..]);
        return out.items;
    }

    fn idOf(self: *const Importer, e: *const Entry) ?[]const u8 {
        for (self.ids.items) |i| if (i.entry == e) return i.id;
        return null;
    }

    fn isId(self: *const Importer, word: []const u8) bool {
        for (self.ids.items) |i| if (std.mem.eql(u8, i.id, word)) return true;
        return false;
    }

    /// Its id, made if it's referenced or the CE layer's manifest can use it. Empty if not.
    fn idFor(self: *Importer, e: *const Entry) ![]const u8 {
        if (self.idOf(e)) |id| return id;
        if (!self.has_lua and !self.isReferenced(e)) return "";
        const base = try idText(self.arena, self.id_prefix, e.description);
        var id = base;
        var n: usize = 2;
        while (self.isId(id) or self.userSymbol(id)) : (n += 1) id = try std.fmt.allocPrint(self.arena, "{s}_{d}", .{ base, n });
        try self.ids.append(self.arena, .{ .entry = e, .id = id });
        return id;
    }

    /// Something uses it as `(description)`. Only asked before it has an id.
    fn isReferenced(self: *const Importer, e: *const Entry) bool {
        return self.referencedBy(self.table.entries, e);
    }

    fn referencedBy(self: *const Importer, list: []const Entry, target: *const Entry) bool {
        for (list) |*e| {
            if (self.refersTo(e.address orelse "", e, target)) return true;
            for (e.offsets) |o| if (self.refersTo(o, e, target)) return true;
            // Another record's dropdown links to it by its id
            if (e.dropdown) |d| if (d.link) |link| if (e != target and d.items.len == 0 and std.mem.eql(u8, link, target.description)) return true;
            if (self.referencedBy(e.children, target)) return true;
        }
        return false;
    }

    fn refersTo(self: *const Importer, text: []const u8, from: *const Entry, target: *const Entry) bool {
        var it: References = .{ .text = text };
        while (it.next()) |inner| if (self.referenced(inner, from) == target) return true;
        return false;
    }

    fn dataOf(self: *const Importer, e: *const Entry) ?[]const u8 {
        for (self.data.items) |d| if (d.entry == e) return d.name;
        return null;
    }

    /// The file's groups and tweaks as `render` takes them, in `order` as they're written.
    fn renderNode(self: *Importer, k: usize, order: *std.ArrayList(usize), has_lua: bool, head: []const u8) !render.Node {
        try order.append(self.arena, k);
        const n = self.nodes.items[k];
        const kids = try self.arena.alloc(render.Node, n.kids.items.len);
        for (n.kids.items, kids) |c, *out| out.* = try self.renderNode(c, order, false, "");
        return .{
            .group = n.group,
            .title = n.title,
            .children = n.children,
            .uses = if (has_lua) &.{lua.library_name} else &.{},
            .shares_globals = k == 0,
            .part = n.part,
            .lua_head = head,
            .nodes = kids,
        };
    }

    /// Parsed before it's written. Whatever stops it parsing goes off for review, one at a time.
    fn finishFile(self: *Importer, has_lua: bool, head: []const u8) ![]const u8 {
        var tries: usize = 0;
        while (true) : (tries += 1) {
            var order: std.ArrayList(usize) = .empty;
            const r = try render.tree(self.arena, try self.renderNode(0, &order, has_lua, head));
            var problem: tweak_format.Problem = .{};
            _ = tweak_format.parseFile(self.arena, r.text, &problem) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => {
                    if (tries > self.nodes.items.len) return r.text;
                    // The part that line's in
                    var at: usize = 0;
                    for (r.starts, 0..) |s, i| if (s <= problem.line) {
                        at = i;
                    };
                    const why = try std.fmt.allocPrint(self.arena, "the tweak didn't parse in its group, {s}", .{problem.message()});
                    const node = &self.nodes.items[order.items[at]];
                    if (node.part) |*p| {
                        if (p.tweak.status == .review) return r.text;
                        try self.offForReview(p, why);
                    } else return r.text;
                    continue;
                },
            };
            return r.text;
        }
    }

    fn countParts(self: *Importer) void {
        for (self.nodes.items[1..]) |*n| {
            if (n.group) self.stats.tweak_groups += 1 else self.stats.tweaks += 1;
            if (n.part) |*p| self.count(p, if (n.entry) |e| e.description else n.title);
        }
    }

    fn count(self: *Importer, part: *const render.Part, what: []const u8) void {
        const t = part.tweak;
        switch (t.status) {
            .clean => self.stats.clean += 1,
            .review => self.stats.review += 1,
            .lua => self.stats.lua += 1,
        }
        if (t.status == .review) {
            const why = std.mem.join(self.arena, ", and ", t.problems) catch "";
            self.reviews.append(self.arena, why) catch {};
            self.report.add(what, self.fileWhere() catch "", "{s}", .{why}) catch {};
        }
        if (part.key != null) self.stats.keys += 1;
        if (t.status != .clean) return;
        self.stats.data_fields += @intCast(t.fields.len);
        for (t.code) |c| switch (c.kind) {
            .inject => self.stats.injects += 1,
            .patch => self.stats.patches += 1,
            .bytes => self.stats.bytes += 1,
        };
    }
};

fn anyScripts(list: []const Entry) bool {
    for (list) |c| if (c.hasScripts()) return true;
    return false;
}

/// CE's "activate children as well" and "deactivate" as `@children`, when they aren't both.
fn childrenOf(e: Entry) ?[]const u8 {
    if (e.activate_children and e.deactivate_children) return null;
    if (e.activate_children) return "on";
    if (e.deactivate_children) return "off";
    return "none";
}

/// A title for a file with groups, which can't have `/` since paths are joined by it.
fn safeTitle(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const t = try render.title(arena, text);
    if (std.mem.indexOfScalar(u8, t, '/') == null) return t;
    const out = try arena.dupe(u8, t);
    std.mem.replaceScalar(u8, out, '/', '-');
    return out;
}
fn containsString(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.ascii.eqlIgnoreCase(x, s)) return true;
    return false;
}

fn findEntry(list: []const Entry, description: []const u8) ?*const Entry {
    for (list) |*e| {
        if (std.mem.eql(u8, e.description, description)) return e;
        if (findEntry(e.children, description)) |found| return found;
    }
    return null;
}

/// In quotes if it has anything a bare name can't.
fn quoted(arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '.') return std.fmt.allocPrint(arena, "\"{s}\"", .{name});
    return name;
}

fn unquoted(name: []const u8) []const u8 {
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') return name[1 .. name.len - 1];
    return name;
}

/// The insides of each `(...)` in CE address text, which might be a record's description.
const References = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *References) ?[]const u8 {
        while (std.mem.indexOfScalarPos(u8, self.text, self.at, '(')) |open| {
            const close = std.mem.indexOfScalarPos(u8, self.text, open + 1, ')') orelse return null;
            self.at = close + 1;
            const inner = self.text[open + 1 .. close];
            // The innermost, like `[(Base)+8]` inside `([(Base)+8])`
            if (std.mem.indexOfScalar(u8, inner, '(') != null) {
                self.at = open + 1;
                continue;
            }
            const trimmed = std.mem.trim(u8, inner, " \t");
            if (trimmed.len > 0) return trimmed;
        }
        return null;
    }
};

/// An id like `kai.Game_State` for a record, which location text and asm take as one name.
fn idText(arena: std.mem.Allocator, prefix: []const u8, description: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, prefix);
    try out.append(arena, '.');
    const start = out.items.len;
    for (description) |ch| {
        const keep = std.ascii.isAlphanumeric(ch) or ch == '_';
        if (keep) {
            try out.append(arena, ch);
        } else if (out.items.len > start and out.items[out.items.len - 1] != '_') {
            try out.append(arena, '_');
        }
        if (out.items.len >= records.max_id - 4) break;
    }
    while (out.items.len > start and out.items[out.items.len - 1] == '_') _ = out.pop();
    if (out.items.len == start) try out.appendSlice(arena, "record");
    return out.items;
}

/// CE gives a script's Lua its own record as `memrec`.
fn memrecOf(arena: std.mem.Allocator, e: *const Entry, l: convert.Lua) ![]const u8 {
    const id = std.fmt.parseInt(i64, e.id, 10) catch return "";
    if (!mentions(l.on, "memrec") and !mentions(l.off, "memrec")) return "";
    return std.fmt.allocPrint(arena, "-- ce: CE's own record for this script\nlocal memrec = getAddressList().getMemoryRecordByID({d})", .{id});
}

fn mentions(code: []const u8, word: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, code, from, word)) |at| {
        from = at + word.len;
        const before = at == 0 or !(std.ascii.isAlphanumeric(code[at - 1]) or code[at - 1] == '_');
        const after = from == code.len or !(std.ascii.isAlphanumeric(code[from]) or code[from] == '_');
        if (before and after) return true;
    }
    return false;
}

fn toggleLike(items: []const table.Choice) bool {
    const offs = [_][]const u8{ "off", "disabled", "disable", "false", "no" };
    const ons = [_][]const u8{ "on", "enabled", "enable", "true", "yes" };
    var off = false;
    var on = false;
    for (items) |c| {
        const v = std.fmt.parseInt(i64, c.value, 10) catch return false;
        const l = std.mem.trim(u8, c.label, " ");
        if (v == 0 and containsString(&offs, l)) off = true;
        if (v == 1 and containsString(&ons, l)) on = true;
    }
    return off and on;
}

test {
    _ = xml;
    _ = table;
    _ = numbers;
    _ = keys;
    _ = machine;
    _ = script;
    _ = convert;
    _ = render;
    _ = records;
    _ = report;
    _ = lua;
    _ = zip;
    _ = @import("tests.zig");
}
