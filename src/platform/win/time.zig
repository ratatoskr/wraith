const api = @import("tuft_sys").win;
const LocalTime = @import("../time.zig").LocalTime;

pub fn localNow() LocalTime {
    var t: api.SYSTEMTIME = .{};
    api.GetLocalTime(&t);
    return .{
        .year = t.wYear,
        .month = @intCast(t.wMonth),
        .day = @intCast(t.wDay),
        .hour = @intCast(t.wHour),
        .minute = @intCast(t.wMinute),
        .second = @intCast(t.wSecond),
        .millisecond = t.wMilliseconds,
    };
}
