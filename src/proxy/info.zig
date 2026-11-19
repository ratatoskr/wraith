//! Shared by the proxy DLLs and `wraith install`.

const std = @import("std");

pub const marker = "wraith proxy dll v1";
pub const init_file = "wraith_init.zon";

/// Unknown fields are ignored so old proxies can read newer files.
pub const Init = struct {
    wraith_dir: []const u8,
};
pub const dir = "proxies";

pub const proxies = [_]Proxy{
    .of("version"),
    .of("winmm"),
    .of("dinput8"),
    .of("dsound"),
    .of("winhttp"),
};

pub const Proxy = struct {
    dll: []const u8,
    name: []const u8,

    fn of(comptime dll: []const u8) Proxy {
        return .{ .dll = dll, .name = dll ++ ".dll" };
    }

    pub fn file(self: Proxy, buf: []u8, arch: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "wraith_{s}_{s}.dll", .{ self.dll, arch });
    }

    pub fn find(name: []const u8) ?Proxy {
        for (proxies) |p| {
            if (std.ascii.eqlIgnoreCase(name, p.name) or std.ascii.eqlIgnoreCase(name, p.dll)) return p;
        }
        return null;
    }
};
