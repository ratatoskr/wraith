//! A test plugin that draws and leaves ImGui unbalanced on purpose.

const std = @import("std");
const sdk = @import("wraith_sdk");

pub const std_options: std.Options = .{ .logFn = sdk.logFn };
pub const panic = sdk.panic;

var draws: sdk.atomic.Value(u32) = .init(0);

export fn wraith_drawing_draws() u32 {
    return draws.load(.monotonic);
}

var task_frames: sdk.atomic.Value(u32) = .init(0);

export fn wraith_drawing_task_frames() u32 {
    return task_frames.load(.monotonic);
}

const Panel = struct {
    window: sdk.ui.Window = .{ .title = "panel", .open = true },

    pub fn draw(_: *Panel) void {
        sdk.ui.text("managed", .{});
    }
};

pub const Plugin = struct {
    panel: Panel = .{},

    pub fn start(self: *Plugin, ctx: *sdk.Context) !void {
        try ctx.addWindow(&self.panel);
        _ = try ctx.onFrame(self, draw);
        try ctx.spawn(drawFromTask, .{ctx.io});
        const area = sdk.wraith.root().?.ui();
        area.setCursorHint(.visible);
        area.showCursor(true);
        area.showCursor(true);
        area.takeInput(.keyboard, true);
        area.takeInput(.mouse, true);
        area.takeInput(.gamepad, true);
    }

    /// Carries on each frame on the render thread, so it can draw.
    fn drawFromTask(io: std.Io) !void {
        while (true) {
            try sdk.frame.next(io);
            if (sdk.ui.window("task", .{})) |w| {
                defer w.end();
                sdk.ui.text("from a task", .{});
            }
            _ = task_frames.fetchAdd(1, .monotonic);
        }
    }

    fn draw(_: *Plugin) void {
        const n = draws.fetchAdd(1, .monotonic) + 1;
        _ = sdk.ui.id(7); // never ended
        if (sdk.ui.window("drawing", .{})) |_| {
            sdk.ui.text("drawn {d} times", .{n});
            // no end()
        }
    }
};

comptime {
    sdk.exportPlugin(Plugin);
}
