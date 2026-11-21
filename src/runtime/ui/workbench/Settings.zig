//! The workbench's command keys, the same in every view. These are their defaults. The shell
//! registers each as a setting, so they're picked in Settings like any other key.

const wraith_platform = @import("wraith_platform");

/// Debugging keys follow Visual Studio's.
pub const Keys = struct {
    const Chord = wraith_platform.input.Chord;

    copy: Chord = .{ .key = .c, .mods = .{ .ctrl = true } },
    /// Copies just the addresses.
    copy_address: Chord = .{ .key = .c, .mods = .{ .ctrl = true, .shift = true } },
    paste: Chord = .{ .key = .v, .mods = .{ .ctrl = true } },
    delete: Chord = .{ .key = .delete },
    /// Change what's picked, like a value or an instruction.
    edit: Chord = .{ .key = .f2 },
    go_to: Chord = .{ .key = .g, .mods = .{ .ctrl = true } },
    show_code: Chord = .{ .key = .d, .mods = .{ .ctrl = true } },
    show_memory: Chord = .{ .key = .b, .mods = .{ .ctrl = true } },
    add_to_list: Chord = .{ .key = .l, .mods = .{ .ctrl = true } },
    what_writes: Chord = .{ .key = .w, .mods = .{ .ctrl = true, .shift = true } },
    what_reads: Chord = .{ .key = .r, .mods = .{ .ctrl = true, .shift = true } },
    /// Hold an address list value, or let it go.
    hold: Chord = .{ .key = .space },
    new_entry: Chord = .{ .key = .n, .mods = .{ .ctrl = true } },
    new_group: Chord = .{ .key = .n, .mods = .{ .ctrl = true, .shift = true } },
    /// Run a script, or find a schema's signatures. Works while typing.
    run: Chord = .{ .key = .enter, .mods = .{ .ctrl = true } },
    /// Save the project, or a schema with a file of its own. Works while typing.
    save: Chord = .{ .key = .s, .mods = .{ .ctrl = true } },
    save_as: Chord = .{ .key = .s, .mods = .{ .ctrl = true, .shift = true } },
    open: Chord = .{ .key = .o, .mods = .{ .ctrl = true } },
    /// Write what's picked, like a script or some addresses, to a file of its own.
    export_file: Chord = .{ .key = .e, .mods = .{ .ctrl = true } },
    import_file: Chord = .{ .key = .i, .mods = .{ .ctrl = true } },
    /// A software one, an int3 in the code.
    toggle_breakpoint: Chord = .{ .key = .f9 },
    /// One of the CPU's four, which leaves the code alone.
    toggle_hardware_breakpoint: Chord = .{ .key = .f9, .mods = .{ .shift = true } },
    /// Disable a breakpoint without losing it.
    enable_breakpoint: Chord = .{ .key = .f9, .mods = .{ .ctrl = true } },
    delete_all_breakpoints: Chord = .{ .key = .f9, .mods = .{ .ctrl = true, .shift = true } },
    continue_thread: Chord = .{ .key = .f5 },
    step_into: Chord = .{ .key = .f11 },
    /// Like step into, but runs a call through to where it returns.
    step_over: Chord = .{ .key = .f10 },
    /// Moves the stopped thread to the picked instruction, without running anything.
    set_next: Chord = .{ .key = .f10, .mods = .{ .ctrl = true, .shift = true } },
    /// Open what's under a row, like a struct's fields.
    expand: Chord = .{ .key = .right },
    collapse: Chord = .{ .key = .left },
    toggle_search: Chord = .{ .key = .f, .mods = .{ .ctrl = true, .shift = true } },
    /// Move what's picked up or down a list, past the one next to it.
    move_up: Chord = .{ .key = .up, .mods = .{ .alt = true } },
    move_down: Chord = .{ .key = .down, .mods = .{ .alt = true } },
};
