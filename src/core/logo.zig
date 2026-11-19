const log = @import("log.zig").scoped(.wraith_core);

pub const logo_text =
    \\ __      __               .__  __  .__
    \\/  \    /  \____________  |__|/  |_|  |__
    \\\   \/\/   /\_  __ \__  \ |  \   __\  |  \
    \\ \        /  |  | \// __ \|  ||  | |   Y  \
    \\  \__/\  /   |__|  (____  /__||__| |___|  /
    \\       \/               \/              \/
;

pub fn print() void {
    const purple = "\x1b[35m";
    const reset = "\x1b[0m";
    const output = purple ++ logo_text ++ reset ++ "\n\n";
    log.print(output, .{});
}
