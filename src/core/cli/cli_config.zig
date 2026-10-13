//! `fx config list` and `fx config get`: show the values set in fx's settings
//! files, in git's `key=value` format.

const std = @import("std");
const builtin_commands = @import("../../builtins/commands.zig");
const cli_flags = @import("cli_flags.zig");
const config_runtime = @import("../config/config_runtime.zig");
const output_contracts = @import("../output/output_contracts.zig");
const settings_entries = @import("../config/settings_entries.zig");
const settings_keys = @import("../config/settings_keys.zig");
const settings_messages = @import("settings_messages.zig");

const Allocator = std.mem.Allocator;

pub const profile_display = "~/.fx/settings.json";
pub const project_display = ".fx.json";

pub const Options = struct {
    /// The key `get` prints; null for `list`.
    key: ?[]const u8 = null,
    scope: settings_entries.Scope = .all,
    show_origin: bool = false,
    format: output_contracts.OutputFormat = .text,
};

const ConfigFlag = enum { global, workspace, show_origin, json };
const config_flag_ids = cli_flags.idTable(ConfigFlag, &builtin_commands.config_options);

/// Parses `fx config [list|get <key>]` and its flags. On a `get` key that names
/// no setting, sets `unknown_key` to the part that isn't known. Slices borrow
/// from `args`.
pub fn parseArgs(
    args: []const [:0]const u8,
    unknown_key: *?settings_keys.UnknownPart,
) error{ InvalidConfigArgs, UnknownConfigSetting }!Options {
    var options: Options = .{};
    var words: [2][]const u8 = undefined;
    var word_count: usize = 0;
    var parser: cli_flags.Parser = .init(&builtin_commands.config_options, args);
    while (parser.next() catch return error.InvalidConfigArgs) |item| switch (item) {
        .positional => |word| {
            if (word_count == words.len) return error.InvalidConfigArgs;
            words[word_count] = word;
            word_count += 1;
        },
        .option => |match| switch (config_flag_ids[match.index].?) {
            .global => options.scope = .global,
            .workspace => options.scope = .workspace,
            .show_origin => options.show_origin = true,
            .json => options.format = .json,
        },
    };

    if (word_count == 0) return options;
    if (std.mem.eql(u8, words[0], "list")) {
        if (word_count != 1) return error.InvalidConfigArgs;
        return options;
    }
    if (std.mem.eql(u8, words[0], "get")) {
        if (word_count != 2 or words[1].len == 0) return error.InvalidConfigArgs;
        if (settings_keys.unknownPart(words[1])) |part| {
            unknown_key.* = part;
            return error.UnknownConfigSetting;
        }
        options.key = words[1];
        return options;
    }
    return error.InvalidConfigArgs;
}

pub const Loaded = struct {
    profile: ?std.json.Parsed(std.json.Value) = null,
    project: ?std.json.Parsed(std.json.Value) = null,
    entries: settings_entries.Entries,
    unknown: []output_contracts.ConfigUnknownSetting,

    pub fn deinit(self: *Loaded, alloc: Allocator) void {
        alloc.free(self.unknown);
        self.entries.deinit(alloc);
        if (self.project) |*parsed| parsed.deinit();
        if (self.profile) |*parsed| parsed.deinit();
        self.* = undefined;
    }
};

/// Reads the settings files in `paths` and collects the entries and unknown
/// keys for `scope`. When a file can't be read or parsed, sets `failed_file`
/// to its display name and returns the error. Caller deinits the result.
pub fn load(
    alloc: Allocator,
    paths: config_runtime.Paths,
    workspace_root: []const u8,
    scope: settings_entries.Scope,
    failed_file: *?[]const u8,
) !Loaded {
    var profile: ?std.json.Parsed(std.json.Value) = null;
    errdefer if (profile) |*parsed| parsed.deinit();
    if (paths.user_settings) |path| {
        failed_file.* = profile_display;
        profile = try config_runtime.readSettingsFileJson(alloc, path);
    }
    var project: ?std.json.Parsed(std.json.Value) = null;
    errdefer if (project) |*parsed| parsed.deinit();
    if (scope == .all) {
        failed_file.* = project_display;
        project = try config_runtime.readSettingsFileJson(alloc, paths.workspace_settings);
    }
    failed_file.* = null;

    var entries = try settings_entries.collect(alloc, .{
        .profile = if (profile) |parsed| parsed.value else null,
        .project = if (project) |parsed| parsed.value else null,
        .workspace_root = workspace_root,
    }, scope);
    errdefer entries.deinit(alloc);

    var unknown: std.ArrayList(output_contracts.ConfigUnknownSetting) = .empty;
    errdefer unknown.deinit(alloc);
    if (profile) |parsed| {
        const found = try settings_keys.findUnknown(alloc, parsed.value, .profile);
        defer alloc.free(found);
        for (found) |key| {
            const shown = if (key.workspace) |workspace|
                scope != .global and std.mem.eql(u8, workspace, workspace_root)
            else
                scope != .workspace;
            if (shown) try unknown.append(alloc, unknownSetting(key, profile_display));
        }
    }
    if (project) |parsed| {
        const found = try settings_keys.findUnknown(alloc, parsed.value, .project);
        defer alloc.free(found);
        for (found) |key| try unknown.append(alloc, unknownSetting(key, project_display));
    }

    return .{
        .profile = profile,
        .project = project,
        .entries = entries,
        .unknown = try unknown.toOwnedSlice(alloc),
    };
}

fn unknownSetting(key: settings_keys.UnknownKey, file: []const u8) output_contracts.ConfigUnknownSetting {
    return .{ .key = key, .file = file, .suggestion = settings_messages.closest(key.name, key.known) };
}

/// Why a settings file couldn't be loaded, in words.
pub fn loadFailureReason(err: anyerror) []const u8 {
    return switch (err) {
        error.StreamTooLong => "is larger than 64 KiB",
        error.SyntaxError, error.UnexpectedEndOfInput, error.InvalidNumber => "isn't valid JSON",
        else => "can't be read",
    };
}

fn parseForTest(args: []const [:0]const u8) error{ InvalidConfigArgs, UnknownConfigSetting }!Options {
    var unknown: ?settings_keys.UnknownPart = null;
    return parseArgs(args, &unknown);
}

test "config args default to list and take scope, origin, and json flags" {
    const bare = try parseForTest(&.{});
    try std.testing.expect(bare.key == null and bare.scope == .all and !bare.show_origin);

    const listed = try parseForTest(&.{ "list", "--global", "--workspace", "--show-origin", "--json" });
    try std.testing.expectEqual(settings_entries.Scope.workspace, listed.scope);
    try std.testing.expect(listed.show_origin);
    try std.testing.expectEqual(output_contracts.OutputFormat.json, listed.format);

    const got = try parseForTest(&.{ "get", "statusLine.context", "--global" });
    try std.testing.expectEqualStrings("statusLine.context", got.key.?);
    try std.testing.expectEqual(settings_entries.Scope.global, got.scope);
}

test "config args reject extra words, missing keys, and unknown flags" {
    const bad = [_][]const [:0]const u8{
        &.{"set"},
        &.{ "list", "extra" },
        &.{"get"},
        &.{ "get", "" },
        &.{ "get", "model", "extra" },
        &.{"--globl"},
    };
    for (bad) |args| try std.testing.expectError(error.InvalidConfigArgs, parseForTest(args));
}

test "config get names the part of a key that isn't a setting" {
    var unknown: ?settings_keys.UnknownPart = null;
    try std.testing.expectError(error.UnknownConfigSetting, parseArgs(&.{ "get", "statusLine.contxt" }, &unknown));
    try std.testing.expectEqualStrings("contxt", unknown.?.name);
    try std.testing.expectEqualStrings("statusLine", unknown.?.parent.?);
}

test "load reads both files and keeps unknown keys for the scope" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{
        .sub_path = "settings.json",
        .data = "{\"fast_mode\":true,\"fast_mdoe\":1,\"workspaces\":{\"/w\":{\"efort\":\"x\",\"effort\":\"high\"},\"/other\":{\"nope\":1}}}",
    });
    try tmp.dir.writeFile(io, .{ .sub_path = ".fx.json", .data = "{\"max_agent_steps\":3,\"max_agent_step\":4}" });
    const settings_path = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, "settings.json");
    const project_path = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, ".fx.json");
    var paths: config_runtime.Paths = .{
        .user_settings = settings_path,
        .workspace_settings = project_path,
        .workspace_root = try alloc.dupe(u8, "/w"),
    };
    defer paths.deinit(alloc);

    var failed: ?[]const u8 = null;
    var all = try load(alloc, paths, "/w", .all, &failed);
    defer all.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), all.entries.items.len);
    try std.testing.expectEqual(@as(usize, 3), all.unknown.len);
    try std.testing.expectEqualStrings("fast_mdoe", all.unknown[0].key.name);
    try std.testing.expectEqualStrings("fast_mode", all.unknown[0].suggestion.?);
    try std.testing.expectEqualStrings("efort", all.unknown[1].key.name);
    try std.testing.expectEqualStrings(".fx.json", all.unknown[2].file);

    var global = try load(alloc, paths, "/w", .global, &failed);
    defer global.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), global.unknown.len);
    try std.testing.expectEqualStrings("fast_mdoe", global.unknown[0].key.name);
}

test "load names the file it can't parse" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "settings.json", .data = "{\"fast_mode\":" });
    var paths: config_runtime.Paths = .{
        .user_settings = try @import("../shared/io.zig").dirRealpathAlloc(alloc, tmp.dir, "settings.json"),
        .workspace_settings = try alloc.dupe(u8, "/nonexistent/.fx.json"),
        .workspace_root = try alloc.dupe(u8, "/w"),
    };
    defer paths.deinit(alloc);

    var failed: ?[]const u8 = null;
    if (load(alloc, paths, "/w", .all, &failed)) |loaded| {
        var unexpected = loaded;
        unexpected.deinit(alloc);
        return error.TestExpectedError;
    } else |err| {
        try std.testing.expectEqualStrings(profile_display, failed.?);
        try std.testing.expectEqualStrings("isn't valid JSON", loadFailureReason(err));
    }
}
