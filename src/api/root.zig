//! What the runtime and plugins share: `wraith.sal` as Zig, the native plugin entry, and the plain
//! types the SDK and runtime both use.

const std = @import("std");

const core = @import("wraith_core");
const input = @import("wraith_platform").input;
const tuft_text = @import("tuft_text");
/// Salamander's runtime, for traits shared between plugins in any language.
pub const salamander = @import("salamander_runtime");

/// Wraith's API as Salamander traits, from every file in `schemas`, bundled. Every plugin and
/// script sees the same.
pub const wraith_sal = @embedFile("wraith.sal");
/// Made from `schemas` as the build runs, with real methods like `root.frame().stats()`.
pub const wraith = @import("wraith_api_zig");
/// How every schema wraith reads is parsed. Plugins' write `[Sig]` and the rest without a `use`.
/// `[Instance("..")] struct Player` is `static Player* instance` with that sig, so it's found the same.
pub const sal_options: @import("salamander_schema").Options = .{
    .namespaces = &.{.{ .name = "wraith", .annotations = &.{ "Sig", "Module", "Section", "VirtualTable", "Instance", "Service", "Tweak", "Label", "Range", "ReadOnly", "Hidden", "Flatten", "Choices", "Managed", "Icall" } }},
    .uses = &.{"wraith"},
    .instances = &.{.{ .namespace = "wraith", .name = "Instance", .as = "Sig" }},
};

pub const CpuContext = @import("tuft_arch").CpuContext;
pub const script = @import("script.zig");
pub const tweak = @import("tweak.zig");

pub const Hook = opaque {};

pub const HookError = error{
    OutOfMemory,
    AlreadyHooked,
    FunctionTooSmall,
    TargetModified,
    InvalidHandle,
    HookFailed,
    /// Not what `expect` said was there.
    UnexpectedBytes,
    /// `expect` doesn't make sense.
    InvalidPattern,
    /// The size to replace ends inside an instruction.
    SplitsInstruction,
};

pub const MidOptions = struct {
    /// The callback replaces code there, so returning carries on after it. Else it goes before
    /// the instruction there, which runs after it.
    replace: bool = false,
    /// Bytes it replaces, ending between instructions. 0 is what `expect` covers, or else the
    /// instruction there.
    size: u32 = 0,
    /// What has to be there, a byte pattern like `89 83 ?? ??` or asm like `cmp ecx, eax; jl 0x1234`.
    /// Empty skips the check.
    expect: []const u8 = "",
    /// Says what was there instead, or what's wrong with `expect`.
    problem: ?*AsmProblem = null,
    /// More names asm in `expect` can use, before the address list's.
    names: []const Name = &.{},
};

pub const HookCall = struct {
    hook: *Hook,
    /// The original function, or for a slot hook the old pointer.
    trampoline: usize,
    user_data: usize,
    /// False if the hook is being destroyed. Then call the trampoline and skip `hook_leave`.
    entered: bool,
};

pub const CursorHint = enum {
    auto,
    visible,
    hidden,
};

/// What the overlay can take from the game.
pub const InputDevice = enum {
    keyboard,
    mouse,
    gamepad,
};

pub const ToastKind = enum(u8) { info, success, warning, @"error" };

/// Crosses by value, so it can never get fields. Add a new fn instead.
pub const Toast = struct {
    kind: ToastKind = .info,
    /// Empty shows the plugin's name.
    title: []const u8 = "",
    text: []const u8 = "",
    /// Not counting while hovered. 0 keeps it up until it's clicked or dismissed.
    seconds: f32 = 4,
};

/// 0 is none.
pub const ToastId = u32;

/// Frame times from one present to the next, over the window the user picked.
/// Crosses by value, so it can never get fields. Add a new fn instead.
pub const FrameStats = struct {
    /// What these cover. Less than the window early on or after a reset.
    window_seconds: f32 = 0,
    frames: u32 = 0,
    /// From the average frame time.
    fps: f32 = 0,
    avg_ms: f32 = 0,
    min_ms: f32 = 0,
    max_ms: f32 = 0,
    p50_ms: f32 = 0,
    p95_ms: f32 = 0,
    p99_ms: f32 = 0,
    /// The fps at the 99th percentile frame time.
    low_1_fps: f32 = 0,
    /// The fps at the 99.9th percentile frame time.
    low_01_fps: f32 = 0,
    /// Frames over `hitch_factor` times the median.
    hitches: u32 = 0,
    hitch_factor: f32 = 0,
    /// Since the game started or the stats were reset.
    total_frames: usize = 0,
    total_avg_ms: f32 = 0,
    total_min_ms: f32 = 0,
    total_max_ms: f32 = 0,
};

pub const Keybind = opaque {};

pub const KeyPhase = enum { pressed, released };

pub const KeybindError = error{
    KeybindsUnavailable,
    OutOfMemory,
    AlreadyBound,
    InvalidChord,
    KeybindFailed,
};

/// Where a setting's value is kept: for every game, or just this one.
pub const Scope = enum { global, game };

pub const Action = struct {
    id: []const u8,
    name: []const u8,
    /// The default. Whoever plays can change it in Wraith's settings, and theirs wins.
    chord: input.Chord,
    /// More that do the same by default, like a controller button.
    also: []const input.Chord = &.{},
    consume: bool = true,
    while_typing: bool = false,
    /// Held, like a key to move with: it fires with any modifiers down and can be one, like Shift.
    held: bool = false,
    /// Where the key someone picks is kept.
    scope: Scope = .global,
};

/// A setting a plugin registers. Wraith keeps its value, saves it and lists it in its Settings,
/// and the plugin can show it on its own screen too. Keys are keybinds, not settings.
pub const Setting = opaque {};

pub const SettingError = error{
    SettingsUnavailable,
    OutOfMemory,
    InvalidDefinition,
    InvalidId,
    AlreadyAdded,
    /// Not the setting's kind, or not one of a choice's options.
    InvalidValue,
    SettingFailed,
};

pub const SettingKind = enum { toggle, number, choice, text, colour };

/// What `setting_add` takes, as JSON, so it can grow. Values cross as JSON too: `true`, `1.5`,
/// `"fast"` or `[r, g, b, a]`.
pub const SettingDefinition = struct {
    /// Unique for the plugin. Letters, digits, `_`, `-` and `.`.
    id: []const u8,
    /// Defaults to the id.
    name: []const u8 = "",
    help: []const u8 = "",
    /// A heading in the plugin's part of Settings.
    section: []const u8 = "",
    /// Where its value's kept: for every game, or just this one.
    scope: Scope = .global,
    /// Only takes effect next time the game starts.
    restart: bool = false,
    kind: SettingKind,
    /// The kind's zero if left out: false, `min`, the first option, "" or white.
    default: std.json.Value = .null,
    /// For numbers.
    min: f64 = 0,
    max: f64 = 1,
    /// 1 or more makes it whole steps.
    step: f64 = 0,
    /// For choices.
    options: []const []const u8 = &.{},
};

// Subscribers get messages next frame, never inside the publish.

pub const MessageSubscription = opaque {};

pub const Message = struct {
    topic: []const u8,
    payload: []const u8,
    from: []const u8,
};

pub const MessageError = error{
    OutOfMemory,
    InvalidTopic,
    NoFrames,
    QueueFull,
    OwnerGone,
};

pub const max_topic_len = 128;

pub fn validTopic(topic: []const u8) bool {
    return topic.len != 0 and topic.len <= max_topic_len and std.mem.indexOfScalar(u8, topic, '*') == null;
}

pub fn validPattern(pattern: []const u8) bool {
    if (pattern.len == 0 or pattern.len > max_topic_len) return false;
    const star = std.mem.indexOfScalar(u8, pattern, '*') orelse return true;
    return star == pattern.len - 1;
}

pub fn topicMatches(pattern: []const u8, topic: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, "*")) return std.mem.startsWith(u8, topic, pattern[0 .. pattern.len - 1]);
    return std.mem.eql(u8, pattern, topic);
}

test "topic patterns" {
    try std.testing.expect(topicMatches("kai.gold", "kai.gold"));
    try std.testing.expect(!topicMatches("kai.gold", "kai.golden"));
    try std.testing.expect(topicMatches("kai.*", "kai.gold"));
    try std.testing.expect(!topicMatches("kai.*", "kaiser"));
    try std.testing.expect(topicMatches("*", "anything"));
    try std.testing.expect(validPattern("kai.*") and validPattern("*") and validPattern("kai"));
    try std.testing.expect(!validPattern("") and !validPattern("*.gold") and !validPattern("a**"));
    try std.testing.expect(validTopic("kai.gold") and !validTopic("kai.*") and !validTopic(""));
}

pub const FrameSubscription = opaque {};

pub const FrameError = error{
    NoFrames,
    OutOfMemory,
    OwnerGone,
};

pub const PostStatus = enum {
    run,
    /// Called while it closes, on whichever thread that is.
    cancelled,
};

pub const TweakEventKind = enum(u8) {
    /// Turned on, or an action run. Each field comes as a `changed` just before.
    on,
    off,
    /// A field's value, before `on` or when it changes while on.
    changed,
};

pub const TweakEvent = struct {
    kind: TweakEventKind,
    /// For `changed`.
    field: []const u8 = "",
    value: f64 = 0,
};

/// Why turning a tweak on failed, shown with it.
pub const TweakProblem = tuft_text.Message(200);

/// A tweak a plugin lists with the project's, and runs itself. Crosses as JSON, so it can grow.
pub const TweakDefinition = struct {
    /// The plugin's own name for it, kept with your settings. Letters, digits, `_`, `-` and `.`.
    id: []const u8,
    /// Shown in the list. Empty shows the id.
    title: []const u8 = "",
    /// Like `Ctrl+F8`. Empty is none.
    key: []const u8 = "",
    mode: tweak.Mode = .toggle,
    /// Like `@data`'s. Their memory isn't touched, changes come through the callback.
    fields: []const TweakField = &.{},
};

pub const TweakField = struct {
    name: []const u8,
    type: tweak.Type = .f64,
    value: f64 = 0,
    /// Empty shows the name.
    label: []const u8 = "",
    /// A checkbox for 0 and 1.
    toggle: bool = false,
    hex: bool = false,
    min: ?f64 = null,
    max: ?f64 = null,
    /// Flips a `toggle`, like `F9`. Empty is none.
    key: []const u8 = "",
    /// A dropdown.
    choices: []const tweak.Choice = &.{},
};

pub const TweakError = error{
    OutOfMemory,
    InvalidId,
    /// Not a `TweakDefinition` as JSON, or a key that isn't one.
    InvalidDefinition,
    OwnerGone,
};

pub const TweakSwitchError = error{
    /// No tweak or group is saved by that name.
    NotFound,
    OutOfMemory,
};

/// What the runtime publishes on `script.topics.switched` when a tweak's box changes, however it
/// changed.
pub const TweakSwitched = struct {
    /// Its saved id, like `kai/Combat/Max bravery` or `plugin:speed`.
    name: []const u8,
    on: bool,
};

/// Source text scripts load by name with `require`, one for each language it has.
pub const LibraryError = error{
    OutOfMemory,
    /// Letters, digits, `_`, `-` and `.`, up to 64.
    InvalidName,
    /// There's no library by that name.
    NotFound,
    /// There is, but not for that language.
    NoSource,
    /// Someone else has one by that name and language, like the runtime's own.
    Taken,
    TooBig,
};

/// Valid library names, the same rule `@use` follows.
pub fn validLibraryName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '_' and ch != '-' and ch != '.') return false;
    return true;
}

pub const CapturePoint = enum(u8) {
    /// Just the game, before the overlay draws on it.
    before_overlay,
    /// With the overlay drawn on top, as it gets presented.
    after_overlay,
};

/// How pixels are laid out. Every format here is 4 bytes a pixel except `rgba16f`'s 8.
pub const PixelFormat = enum(u8) {
    unknown,
    rgba8,
    bgra8,
    /// Alpha is junk.
    bgrx8,
    /// Packed in 32 bits from the low bits up: 10 red, 10 green, 10 blue, 2 alpha.
    rgb10a2,
    /// Same with red and blue swapped.
    bgr10a2,
    /// Half floats, usually scRGB.
    rgba16f,
};

/// What pixel values mean. HDR ones are left as they are.
pub const ColorSpace = enum(u8) {
    /// SDR, sRGB-encoded.
    srgb,
    /// Linear, Rec.709 primaries, 1.0 is 80 nits and values can go past 0..1.
    scrgb,
    /// Rec.2020 primaries with the PQ curve, 1.0 is 10000 nits.
    hdr10,
};

pub const GraphicsApi = enum(u8) { unknown, d3d9, d3d10, d3d11, d3d12, vulkan, opengl };

/// A copy of a frame. `pixels` only lives for the call it's passed to.
pub const Image = struct {
    width: u32 = 0,
    height: u32 = 0,
    /// Bytes from one row to the next, top row first. Can be more than a row of pixels.
    pitch: u32 = 0,
    format: PixelFormat = .unknown,
    /// The graphics API's own format code: `DXGI_FORMAT`, `VkFormat`, `D3DFORMAT` or a GL internal format.
    native_format: u32 = 0,
    graphics_api: GraphicsApi = .unknown,
    color_space: ColorSpace = .srgb,
    /// SDR white on the game's display, in nits.
    sdr_white_nits: f32 = 200,
    pixels: []const u8 = &.{},
};

/// Lives in the owner's memory. Unlisted when the owner is released.
pub const Zone = core.timing.Zone;
pub const Heap = core.heap.Usage;

pub const ScanOutcome = enum { found, not_found, not_unique };

/// Which copy of the game's code a scan read, see `addresses.sal`.
pub const AddressSource = enum(u8) { live, snapshot, disk };

pub const Scan = struct {
    name: []const u8,
    pattern: []const u8,
    start: usize,
    len: usize,
    source: AddressSource = .live,
    first_match: bool = false,
    outcome: ScanOutcome,
    address: usize,
    ns: u64,
};

pub const Patch = opaque {};

pub const AsmError = error{
    OutOfMemory,
    InvalidAsm,
    TooLong,
};

/// Why assembling failed, for people.
pub const AsmProblem = extern struct {
    line: u32 = 0,
    text: tuft_text.Message(200) = .{},

    pub fn message(self: *const AsmProblem) []const u8 {
        return self.text.message();
    }

    pub fn set(self: *AsmProblem, line: u32, text: []const u8) void {
        self.text.set(text);
        self.line = line;
    }
};

pub const PatchOptions = struct {
    /// A signature like `89 83 ?? ??` the bytes there have to match. Empty skips the check.
    expect: []const u8 = "",
    /// More names asm in `expect` can use, before the address list's.
    names: []const Name = &.{},
};

pub const AsmPatchOptions = struct {
    /// Bytes it replaces, ending between instructions. 0 is what `expect` covers, or else the
    /// instruction there.
    size: u32 = 0,
    /// What has to be there, a byte pattern like `89 83 ?? ??` or asm like `cmp ecx, eax; jl 0x1234`.
    /// Empty skips the check.
    expect: []const u8 = "",
    /// More names the asm can use, before the address list's.
    names: []const Name = &.{},
};

pub const InjectOptions = struct {
    /// More names the asm can use, before the address list's.
    names: []const Name = &.{},
};

/// Data for `code_place`, placed with the code that reads it.
pub const PlaceData = extern struct {
    len: usize,
    alignment: u32 = 8,
    /// Names for its code, each at an offset in it.
    names_ptr: [*]const Name = &[_]Name{},
    names_len: usize = 0,

    pub fn of(len: usize, names_: []const Name) PlaceData {
        return .{ .len = len, .names_ptr = names_.ptr, .names_len = names_.len };
    }

    pub fn names(self: PlaceData) []const Name {
        return self.names_ptr[0..self.names_len];
    }
};

/// Code for `code_place`.
pub const PlaceCode = extern struct {
    address: usize,
    source_ptr: [*]const u8,
    source_len: usize,
    /// Goes before the instruction there like `code_inject`, else replaces code like
    /// `code_patch_asm`.
    inject: bool = false,
    /// Like `AsmPatchOptions`.
    size: u32 = 0,
    expect_ptr: [*]const u8 = "",
    expect_len: usize = 0,
    /// More names the asm can use, after the data's and before the address list's.
    names_ptr: [*]const Name = &[_]Name{},
    names_len: usize = 0,

    pub const Options = struct {
        inject: bool = false,
        size: u32 = 0,
        expect: []const u8 = "",
        names: []const Name = &.{},
    };

    pub fn of(address: usize, source_: []const u8, options: Options) PlaceCode {
        return .{
            .address = address,
            .source_ptr = source_.ptr,
            .source_len = source_.len,
            .inject = options.inject,
            .size = options.size,
            .expect_ptr = options.expect.ptr,
            .expect_len = options.expect.len,
            .names_ptr = options.names.ptr,
            .names_len = options.names.len,
        };
    }

    pub fn source(self: PlaceCode) []const u8 {
        return self.source_ptr[0..self.source_len];
    }

    pub fn expect(self: PlaceCode) []const u8 {
        return self.expect_ptr[0..self.expect_len];
    }

    pub fn names(self: PlaceCode) []const Name {
        return self.names_ptr[0..self.names_len];
    }
};

pub const PlaceRequest = struct {
    /// What the data's for when no code jumps to it, like `code_alloc`'s `near`.
    near: usize = 0,
    data: []const PlaceData = &.{},
    code: []const PlaceCode = &.{},
};

/// Why `code_place` failed, for people.
pub const PlaceProblem = extern struct {
    /// Which code failed, if `failed`. Else there wasn't room for it all in one place.
    index: u32 = 0,
    failed: bool = false,
    /// Its asm or expect's problem.
    problem: AsmProblem = .{},
    /// Bytes it all needed in one place.
    bytes: usize = 0,
};

pub const PlaceError = PatchError || error{OutOfReach};

/// A name for an address, like a tweak's own `@data`. Extern so lists of them can be shared.
pub const Name = extern struct {
    ptr: [*]const u8,
    len: usize,
    address: usize,

    pub fn of(name_: []const u8, address: usize) Name {
        return .{ .ptr = name_.ptr, .len = name_.len, .address = address };
    }

    pub fn name(self: Name) []const u8 {
        return self.ptr[0..self.len];
    }

    /// The first called `wanted`.
    pub fn find(names: []const Name, wanted: []const u8) ?usize {
        for (names) |n| if (std.mem.eql(u8, n.name(), wanted)) return n.address;
        return null;
    }
};

/// Why some location text didn't work, for people.
pub const LocationProblem = tuft_text.Message(256);

pub const PatchError = error{
    OutOfMemory,
    AlreadyHooked,
    Unreadable,
    UnexpectedBytes,
    InvalidPattern,
    TargetModified,
    TooLong,
    InvalidHandle,
    PatchFailed,
    InvalidAsm,
    /// The size ends inside an instruction.
    SplitsInstruction,
};

pub const InjectError = HookError || error{ InvalidAsm, TooLong };

pub const AllocError = error{
    OutOfMemory,
    OutOfReach,
};

/// What a page lets code do with it.
pub const Protection = enum(u8) { no_access, read, read_write, read_execute, read_write_execute };

pub const ProtectError = error{
    OutOfMemory,
    /// Not mapped, or Windows wouldn't change it.
    ProtectFailed,
};

pub const Watch = opaque {};

pub const WatchKind = enum(u8) {
    write,
    /// Reads or writes, since the CPU can't watch reads alone.
    access,
    /// About to run. The length has to be 1.
    execute,
};

pub const WatchError = error{
    /// No debug registers here, like when the game's being debugged.
    WatchesUnavailable,
    OutOfMemory,
    /// All four debug registers are taken, by anyone.
    NoFreeSlot,
    /// The address has to be a multiple of the length.
    Misaligned,
    /// 1, 2, 4 or 8 on x64, and 1 for `execute`.
    InvalidLength,
    WatchFailed,
    OwnerGone,
};

/// Crosses by value, so it can never get fields. Add a new fn instead.
pub const WatchHit = struct {
    /// What's watched.
    address: usize,
    /// Where the instruction that hit starts, if it could be told, else `ip`. For `execute`, the
    /// one about to run.
    instruction: usize,
    /// The CPU's ip, just past the instruction for `write` and `access`.
    ip: usize,
    thread: u32,
};

pub const AddressError = error{
    NotFound,
    Unreadable,
    InvalidAddress,
};

/// An address a plugin adds to the game's list. Its id gets the plugin's name in front.
pub const AddressEntry = struct {
    id: []const u8,
    /// Location text, like `0x7FF6A0001000`, `game.exe+0x1234` or `sig("48 8B ??", Rip)`.
    address: []const u8,
    /// Pointers to follow from there, each one's offset added after.
    offsets: []const i64 = &.{},
    name: []const u8 = "",
    /// What's there, like `u32` or a schema type's name. Empty if it doesn't say.
    type: []const u8 = "",
    /// Bytes, so addresses inside it are named after it. 0 is just the one.
    size: u32 = 0,
};

pub const AddressAddError = error{
    OutOfMemory,
    InvalidId,
    AlreadyAdded,
    InvalidAddress,
};

/// An image the host can draw, made by `image_create` or `image_decode`. Gone with its owner.
pub const ImageHandle = opaque {};

pub const ImageError = error{
    OutOfMemory,
    /// Not an image file we can read, or pixels that don't match the size.
    InvalidImage,
    /// Wider or taller than 16384.
    TooBig,
    OwnerGone,
};

pub const ImageSize = struct {
    width: u32 = 0,
    height: u32 = 0,
};

/// Windows' own sounds, as the user set them up.
pub const SystemSound = enum { default, info, warning, @"error", question, notification };

pub const SoundError = error{
    OutOfMemory,
    /// Not a WAV file.
    InvalidSound,
};

/// ImGui's `ImTextureRef`, for `ImGui_Image` and co. A null `tex_data` can't be drawn.
pub const TextureRef = extern struct {
    tex_data: ?*anyopaque = null,
    tex_id: u64 = 0,
};

// Files. Paths use forward slashes, like `C:/Game/data.pak`, and either slash works going in.

pub const VfsWatch = opaque {};

pub const VfsError = error{
    OutOfMemory,
    /// The game's file I/O isn't being watched, like when `file_io` is off in the settings.
    Unavailable,
    /// Not a full path, or too long.
    InvalidPath,
    /// A folder where a file should be, or the other way around.
    WrongKind,
    NotFound,
    OwnerGone,
};

pub const VfsEventKind = enum(u8) {
    /// Before an open. The reply can redirect or refuse it.
    open,
    opened,
    /// An open that failed, with its status.
    failed,
    /// After a read. Its data can be changed in place.
    read,
    /// Before a write. The reply can refuse it.
    write,
    /// The last handle to a file closed.
    closed,
};

pub const VfsKinds = bitpack struct(u8) {
    open: bool = false,
    opened: bool = false,
    failed: bool = false,
    read: bool = false,
    write: bool = false,
    closed: bool = false,
    _: u2 = 0,

    pub fn has(self: VfsKinds, kind: VfsEventKind) bool {
        return switch (kind) {
            inline else => |k| @field(self, @tagName(k)),
        };
    }
};

pub const VfsWatchOptions = struct {
    kinds: VfsKinds,
    /// Paths it's called for, like `C:/Game/data/*.pak`. `*` matches anything, slashes too, and
    /// `?` any one character. Case doesn't matter. Empty is every path.
    pattern: []const u8 = "",
    /// Also while the loader opens a DLL. It holds a lock then, so the callback mustn't wait on
    /// other threads.
    loader: bool = false,
    /// Also existence checks like `GetFileAttributes`, as `open`s with `query` set.
    queries: bool = false,
};

pub const VfsEvent = struct {
    kind: VfsEventKind,
    /// Where the file is. For `open`, where it'll be opened after any earlier redirect.
    path: []const u8,
    /// What the game asked for. The same as `path` unless it's redirected.
    requested: []const u8,
    /// The same for every handle to one open file. 0 for `open` and `failed`.
    file: u64 = 0,
    read_access: bool = false,
    write_access: bool = false,
    virtual: bool = false,
    directory: bool = false,
    /// An existence check, with no handle coming of it.
    query: bool = false,
    thread: u32 = 0,
    /// Where a read or write starts. -1 for the file's current position.
    offset: i64 = -1,
    /// What a read got, which can be changed in place, or what a write writes, which can't.
    data: []u8 = &.{},
    /// The system's status for `failed`, an NTSTATUS on Windows.
    status: u32 = 0,
};

pub const VfsDenial = enum(u8) { access_denied, not_found, sharing_violation, write_protected };

/// What an `open` or `write` callback wants done. Left alone, it goes ahead.
pub const VfsReply = extern struct {
    /// 0 to go ahead, or a `VfsDenial` plus one.
    deny: u8 = 0,
    redirect_len: u16 = 0,
    /// For `open`, where to open instead, which can be a virtual file.
    redirect: [1024]u8 = undefined,

    pub fn refuse(self: *VfsReply, why: VfsDenial) void {
        self.deny = @backingInt(why) + 1;
    }

    pub fn redirectTo(self: *VfsReply, path: []const u8) error{InvalidPath}!void {
        if (path.len > self.redirect.len) return error.InvalidPath;
        @memcpy(self.redirect[0..path.len], path);
        self.redirect_len = @intCast(path.len);
    }

    pub fn denial(self: *const VfsReply) ?VfsDenial {
        if (self.deny == 0 or self.deny > 4) return null;
        return @fromBackingInt(self.deny - 1);
    }

    pub fn redirected(self: *const VfsReply) ?[]const u8 {
        return if (self.redirect_len == 0) null else self.redirect[0..@min(self.redirect_len, self.redirect.len)];
    }
};

/// `C:/Game/*.pak` style matching, ignoring case and which slash.
pub fn vfsMatches(pattern: []const u8, path: []const u8) bool {
    var p: usize = 0;
    var s: usize = 0;
    var star: ?usize = null;
    var resume_at: usize = 0;
    while (s < path.len) {
        if (p < pattern.len and pattern[p] == '*') {
            star = p;
            p += 1;
            resume_at = s;
        } else if (p < pattern.len and (pattern[p] == '?' or sameChar(pattern[p], path[s]))) {
            p += 1;
            s += 1;
        } else if (star) |st| {
            p = st + 1;
            resume_at += 1;
            s = resume_at;
        } else return false;
    }
    while (p < pattern.len and pattern[p] == '*') p += 1;
    return p == pattern.len;
}

fn sameChar(a: u8, b: u8) bool {
    const slash_a = a == '/' or a == '\\';
    const slash_b = b == '/' or b == '\\';
    if (slash_a or slash_b) return slash_a and slash_b;
    return std.ascii.toLower(a) == std.ascii.toLower(b);
}

test "vfs patterns" {
    try std.testing.expect(vfsMatches("C:/Game/*.pak", "c:/game/data/a.PAK"));
    try std.testing.expect(vfsMatches("c:\\game\\a?.txt", "C:/Game/ab.txt"));
    try std.testing.expect(!vfsMatches("C:/Game/*.pak", "C:/Game/a.pak.bak"));
    try std.testing.expect(vfsMatches("*", "anything"));
    try std.testing.expect(vfsMatches("", ""));
    try std.testing.expect(!vfsMatches("C:/a", "C:/ab"));
}

/// What a native plugin's `start` gets with Salamander's host: its `Wraith` root, its Salamander
/// owner, and the queue the render thread polls.
pub const NativeGuest = extern struct {
    wraith: salamander.AnyObject,
    owner: ?*salamander.Owner,
    render_queue: salamander.Queue,
    /// What the plugins it depends on offer.
    services: salamander.Slice(wraith.raw.Service),
};

/// What a native plugin's `wraith_plugin` export gives. Everything else goes through `wraith.sal`, so
/// this only changes when `version` does.
pub const NativeEntry = extern struct {
    version: u32 = native_version,
    /// False if it didn't start. `stop` gets called either way.
    start: *const fn (host: salamander.Host, guest: NativeGuest) callconv(.c) bool,
    stop: *const fn () callconv(.c) void,
    /// What it offers for a [Service] trait, owned by it, or no table.
    service: *const fn (trait: salamander.String) callconv(.c) salamander.AnyObject,
};

pub const native_version: u32 = 2;

/// The kind that runs a plugin when its manifest doesn't say.
pub const default_provider = "native";

test "the maths types are tuft's, with its methods" {
    const a: wraith.Vec3 = .init(1, 0, 0);
    try std.testing.expect(a.cross(.unit_y).approxEql(.unit_z, 0));
    try std.testing.expectEqual(64, @sizeOf(wraith.Mat4));
    try std.testing.expect(wraith.Quat.identity.rotate(a).approxEql(a, 0));
}

test {
    std.testing.refAllDecls(@This());
}
