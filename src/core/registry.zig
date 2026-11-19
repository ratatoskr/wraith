//! Lists tools show, like timing zones and heaps.

const std = @import("std");
const sync = @import("tuft_sys").sync;
const Owner = @import("tuft_event").Owner;

pub fn Registry(comptime Node: type) type {
    return struct {
        const Self = @This();

        /// Another DLL's, listed by pointer. Both sides lay it out like C.
        pub const Shared = struct {
            node: *Node,
            owner: *const Owner,
        };

        const allocator = std.heap.page_allocator;

        /// Newest first. Its lock guards `head` too.
        shared: sync.SharedList(Shared) = .{},
        head: ?*Node = null,

        /// `node` must not move until `remove`.
        pub fn add(self: *Self, node: *Node) void {
            self.shared.lock.lock();
            defer self.shared.lock.unlock();
            node.next = self.head;
            self.head = node;
        }

        /// A node in another DLL. Must not move until removed.
        pub fn addShared(self: *Self, node: *Node, owner: *const Owner) error{OutOfMemory}!void {
            self.shared.lock.lock();
            defer self.shared.lock.unlock();
            try self.shared.items.insert(allocator, 0, .{ .node = node, .owner = owner });
        }

        /// Fine if it isn't listed.
        pub fn remove(self: *Self, node: *Node) void {
            self.shared.lock.lock();
            defer self.shared.lock.unlock();
            var link = &self.head;
            while (link.*) |n| : (link = &n.next) {
                if (n == node) {
                    link.* = n.next;
                    n.next = null;
                    return;
                }
            }
        }

        /// Fine if it isn't listed.
        pub fn removeShared(self: *Self, node: *Node) void {
            self.shared.lock.lock();
            defer self.shared.lock.unlock();
            for (self.shared.items.items, 0..) |s, i| {
                if (s.node == node) {
                    _ = self.shared.items.orderedRemove(i);
                    return;
                }
            }
        }

        pub fn removeOwner(self: *Self, owner: *const Owner) void {
            self.shared.lock.lock();
            defer self.shared.lock.unlock();
            var link = &self.head;
            while (link.*) |n| {
                if (n.owner == owner) {
                    link.* = n.next;
                    n.next = null;
                } else {
                    link = &n.next;
                }
            }
            var i: usize = 0;
            while (i < self.shared.items.items.len) {
                if (self.shared.items.items[i].owner == owner) _ = self.shared.items.orderedRemove(i) else i += 1;
            }
        }

        /// Returns how many were copied.
        pub fn snapshot(self: *Self, out: []Node.Snapshot) usize {
            var n = @min(self.shared.snapshotAs(Node.Snapshot, out, copyShared), out.len);
            self.shared.lock.lockShared();
            defer self.shared.lock.unlockShared();
            var it = self.head;
            while (it) |node| : (it = node.next) {
                if (n == out.len) break;
                out[n] = .of(node, node.owner);
                n += 1;
            }
            return n;
        }

        fn copyShared(s: Shared, o: *Node.Snapshot) void {
            o.* = .of(s.node, s.owner);
        }

        pub fn forEach(self: *Self, comptime func: fn (*Node) void) void {
            self.shared.lock.lockShared();
            defer self.shared.lock.unlockShared();
            for (self.shared.items.items) |s| func(s.node);
            var it = self.head;
            while (it) |node| : (it = node.next) func(node);
        }
    };
}
