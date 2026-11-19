//! Where Show as code and Show in memory go, from the overlay or the workbench.

const Navigator = @This();

const Range = @import("tuft_mem").Range;
const tuft_sys = @import("tuft_sys");

ctx: *anyopaque,
func: *const fn (ctx: *anyopaque, request: Request) void,

/// Somewhere to go.
pub const Request = union(enum) {
    code: usize,
    memory: struct { address: usize, len: usize, highlight: ?Range },
    /// Code or memory, whichever was looked at last.
    address: usize,
};

pub fn go(self: Navigator, request: Request) void {
    self.func(self.ctx, request);
}

pub fn openCode(self: Navigator, address: usize) void {
    self.go(.{ .code = address });
}

pub fn openMemory(self: Navigator, address: usize, len: usize, highlight: ?Range) void {
    self.go(.{ .memory = .{ .address = address, .len = len, .highlight = highlight } });
}

/// Requests from other threads, picked up on the one that goes. Latest wins.
pub const Pending = struct {
    request: ?Request = null,
    lock: tuft_sys.sync.RwLock = .{},

    pub fn put(self: *Pending, request: Request) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.request = request;
    }

    pub fn take(self: *Pending) ?Request {
        self.lock.lock();
        defer self.lock.unlock();
        const r = self.request;
        self.request = null;
        return r;
    }

    pub fn has(self: *Pending) bool {
        self.lock.lockShared();
        defer self.lock.unlockShared();
        return self.request != null;
    }
};
