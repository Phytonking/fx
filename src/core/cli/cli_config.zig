//! `fx config`: show the values set in fx's settings files in git's
//! `key=value` format, and set or unset the plain preferences in the profile.

const std = @import("std");
const builtin_commands = @import("../../builtins/commands.zig");
const cli_flags = @import("cli_flags.zig");
const config_runtime = @import("../config/config_runtime.zig");
const output_contracts = @import("../output/output_contracts.zig");
const settings_entries = @import("../config/settings_entries.zig");
const settings_keys = @import("../config/settings_keys.zig");
const settings_messages = @import("settings_messages.zig");
const settings_store = @import("../config/settings_store.zig");
const theme = @import("../shared/theme.zig");
const types = @import("../shared/types.zig");
const update_target = @import("../upgrade/update_target.zig");
const compactor_settings = @import("../compactor/settings.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");

const Allocator = std.mem.Allocator;

pub const profile_display = "~/.fx/settings.json";
pub const project_display = ".fx.json";

pub const Action = enum { list, get, set, unset };

pub const Options = struct {
    action: Action = .list,
    /// The key `get`, `set`, or `unset` names; null for `list`.
    key: ?[]const u8 = null,
    /// The value `set` writes, as typed.
    value: ?[]const u8 = null,
    scope: settings_entries.Scope = .all,
    show_origin: bool = false,
    format: output_contracts.OutputFormat = .text,
};

const ConfigFlag = enum { global, workspace, show_origin, json };
const config_flag_ids = cli_flags.idTable(ConfigFlag, &builtin_commands.config_options);

/// Parses `fx config [list|get <key>|set <key> <value>|unset <key>]` and its
/// flags. On a key that names no setting, sets `unknown_key` to the part that
/// isn't known. Slices borrow from `args`.
pub fn parseArgs(
    args: []const [:0]const u8,
    unknown_key: *?settings_keys.UnknownPart,
) error{ InvalidConfigArgs, UnknownConfigSetting, WorkspaceConfigWrite }!Options {
    var options: Options = .{};
    var words: [3][]const u8 = undefined;
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
    options.action = std.meta.stringToEnum(Action, words[0]) orelse return error.InvalidConfigArgs;
    const expected_words: usize = switch (options.action) {
        .list => 1,
        .get, .unset => 2,
        .set => 3,
    };
    if (word_count != expected_words) return error.InvalidConfigArgs;
    if (options.action == .list) return options;

    const key = words[1];
    if (key.len == 0) return error.InvalidConfigArgs;
    if (settings_keys.unknownPart(key)) |part| {
        unknown_key.* = part;
        return error.UnknownConfigSetting;
    }
    options.key = key;
    if (options.action == .get) return options;

    // Writes go to the profile's top level only: fx treats preferences in a
    // workspace override as legacy and removes them when it saves.
    if (options.show_origin) return error.InvalidConfigArgs;
    if (options.scope == .workspace) return error.WorkspaceConfigWrite;
    if (options.action == .set) options.value = words[2];
    return options;
}

/// The plain preferences `set` and `unset` change, named by their dotted keys.
/// Security and account keys aren't here on purpose: an agent can run
/// `fx config` through its shell tool, so it must not be able to raise its own
/// permissions or swap the model behind permission reviews.
const Writable = enum {
    auto_compact_percent,
    auto_upgrade,
    collapse_tool_calls,
    context,
    effort,
    fast_mode,
    max_agent_steps,
    max_tool_result_bytes,
    @"notifications.attention_required",
    @"notifications.max",
    @"notifications.turn_end",
    @"prompt_history.enabled",
    provider_strict,
    session_titles,
    slash_menu_categories,
    startup_scrollback,
    @"statusLine.context",
    @"statusLine.session",
    @"statusLine.workspace",
    theme,
    ultrafast_mode,
    update_channel,
};

pub const Change = struct {
    patch: settings_store.UserSettingsPatch,
    /// The value as it will be saved, or null for `unset`. Strings borrow from
    /// the arguments.
    value: ?std.json.Value,
};

pub const WriteProblem = union(enum) {
    none,
    /// The key isn't changed with `fx config`; what to use instead.
    refused: []const u8,
    /// The value doesn't fit the key; what the key takes.
    invalid_value: []const u8,
};

/// The profile change `set` or `unset` makes for `options`. Sets `problem` and
/// fails for a key `fx config` doesn't change or a value the key can't take.
pub fn change(options: Options, problem: *WriteProblem) error{ RefusedConfigSetting, InvalidConfigValue }!Change {
    const key = options.key.?;
    const writable = std.meta.stringToEnum(Writable, key) orelse {
        problem.* = .{ .refused = ownerHint(key) };
        return error.RefusedConfigSetting;
    };
    if (options.action == .unset) return .{ .patch = .{ .remove = key }, .value = null };

    const raw = options.value.?;
    var patch: settings_store.UserSettingsPatch = .{};
    switch (writable) {
        .effort => {
            patch.effort = types.ReasoningEffort.parse(raw) orelse
                return invalid(problem, "auto or an effort name such as high");
            return .{ .patch = patch, .value = .{ .string = raw } };
        },
        .update_channel => {
            patch.update_channel = update_target.Channel.parse(raw) orelse return invalid(problem, "stable or dev");
            return .{ .patch = patch, .value = .{ .string = patch.update_channel.?.label() } };
        },
        .theme => {
            const saved: []const u8 = switch (theme.classifyValue(raw) orelse return invalid(problem, theme_values)) {
                .pin_light => "light",
                .pin_dark => "dark",
                .custom => |name| if (theme.validThemeName(name)) name else return invalid(problem, theme_values),
            };
            patch.theme = saved;
            return .{ .patch = patch, .value = .{ .string = saved } };
        },
        .max_agent_steps => {
            const steps = std.fmt.parseUnsigned(u32, raw, 10) catch
                return invalid(problem, "a whole number of steps; 0 means no limit");
            patch.max_agent_steps = steps;
            return .{ .patch = patch, .value = .{ .integer = steps } };
        },
        .max_tool_result_bytes => {
            const bytes = std.fmt.parseUnsigned(u32, raw, 10) catch 0;
            if (bytes < tool_result_limits.min_configured_tool_result_bytes) {
                return invalid(problem, "a whole number of bytes, at least 1024");
            }
            patch.max_tool_result_bytes = bytes;
            return .{ .patch = patch, .value = .{ .integer = bytes } };
        },
        .auto_compact_percent => {
            const percent = std.fmt.parseUnsigned(u8, raw, 10) catch 0;
            if (!compactor_settings.isValidPercent(percent)) return invalid(problem, "a whole number from 10 to 80");
            patch.auto_compact_percent = percent;
            return .{ .patch = patch, .value = .{ .integer = percent } };
        },
        else => {},
    }

    const enabled = parseSwitch(raw) orelse return invalid(problem, "true or false");
    switch (writable) {
        .auto_upgrade => patch.auto_upgrade = enabled,
        .collapse_tool_calls => patch.collapse_tool_calls = enabled,
        .context => patch.context = enabled,
        .fast_mode => patch.fast_mode = enabled,
        .@"notifications.attention_required" => patch.notification_attention_required = enabled,
        .@"notifications.max" => patch.notification_max = enabled,
        .@"notifications.turn_end" => patch.notification_turn_end = enabled,
        .@"prompt_history.enabled" => patch.prompt_history_enabled = enabled,
        .provider_strict => patch.provider_strict = enabled,
        .session_titles => patch.session_titles = enabled,
        .slash_menu_categories => patch.slash_menu_categories = enabled,
        .startup_scrollback => patch.startup_scrollback = enabled,
        .@"statusLine.context" => patch.statusline_item = .{ .item = .context, .enabled = enabled },
        .@"statusLine.session" => patch.statusline_item = .{ .item = .session, .enabled = enabled },
        .@"statusLine.workspace" => patch.statusline_item = .{ .item = .workspace, .enabled = enabled },
        .ultrafast_mode => patch.ultrafast_mode = enabled,
        .effort, .update_channel, .theme, .max_agent_steps, .max_tool_result_bytes, .auto_compact_percent => unreachable,
    }
    return .{ .patch = patch, .value = .{ .bool = enabled } };
}

const theme_values = "light, dark, or the name of a theme file in ~/.fx/themes";

fn invalid(problem: *WriteProblem, expected: []const u8) error{InvalidConfigValue} {
    problem.* = .{ .invalid_value = expected };
    return error.InvalidConfigValue;
}

fn parseSwitch(raw: []const u8) ?bool {
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "on")) return true;
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "off")) return false;
    return null;
}

/// What to use instead of `fx config` for a setting it doesn't change.
fn ownerHint(key: []const u8) []const u8 {
    const head = key[0 .. std.mem.findScalar(u8, key, '.') orelse key.len];
    const hints = [_]struct { keys: []const []const u8, hint: []const u8 }{
        .{ .keys = &.{ "model", "models", "codex_model", "grok_model" }, .hint = "use /model in a session" },
        .{ .keys = &.{"provider"}, .hint = "use fx provider <name>" },
        .{ .keys = &.{"permission_mode"}, .hint = "use /permissions in a session, or --permission-mode for one run" },
        .{ .keys = &.{"permission"}, .hint = "use /permissions in a session" },
        .{ .keys = &.{"credential_source"}, .hint = "use fx login" },
        .{ .keys = &.{"review_model"}, .hint = "edit ~/.fx/settings.json, or set FX_REVIEW_MODEL for one run" },
        .{ .keys = &.{ "workspaces", "additional_directories" }, .hint = "use fx workspace" },
        .{ .keys = &.{ "enabledMcpjsonServers", "disabledMcpjsonServers", "enableAllProjectMcpServers" }, .hint = "use fx mcp trust" },
        .{ .keys = &.{"context_limits"}, .hint = "use --context-limit for one run, or edit ~/.fx/settings.json" },
        .{ .keys = &.{"provider_order"}, .hint = "use --provider-order for one run, or edit ~/.fx/settings.json" },
        .{ .keys = &.{ "yolo_acknowledged", "fast_mode_model_bound", "skill_match_fuzzy" }, .hint = "fx manages it" },
        .{ .keys = &.{"statusLine"}, .hint = "set statusLine.context, statusLine.session, or statusLine.workspace" },
        .{ .keys = &.{"notifications"}, .hint = "set notifications.turn_end, notifications.attention_required, or notifications.max" },
        .{ .keys = &.{"prompt_history"}, .hint = "set prompt_history.enabled" },
    };
    for (hints) |entry| {
        for (entry.keys) |name| {
            if (std.mem.eql(u8, name, head)) return entry.hint;
        }
    }
    return "edit ~/.fx/settings.json";
}

/// `can't change permission_mode with fx config; use /permissions ...` or
/// `invalid value for fast_mode: maybe (use true or false)`. Caller owns the
/// result.
pub fn formatWriteProblem(alloc: Allocator, options: Options, problem: WriteProblem) ![]u8 {
    const key = options.key.?;
    return switch (problem) {
        .none => alloc.dupe(u8, key),
        .refused => |hint| alloc.print("can't change {s} with fx config; {s}", .{ key, hint }),
        .invalid_value => |expected| alloc.print("invalid value for {s}: {s} (use {s})", .{ key, options.value orelse "", expected }),
    };
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

fn parseForTest(args: []const [:0]const u8) error{ InvalidConfigArgs, UnknownConfigSetting, WorkspaceConfigWrite }!Options {
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

test "config set and unset take a key, and set takes a value" {
    const set = try parseForTest(&.{ "set", "fast_mode", "on", "--global" });
    try std.testing.expectEqual(Action.set, set.action);
    try std.testing.expectEqualStrings("fast_mode", set.key.?);
    try std.testing.expectEqualStrings("on", set.value.?);

    const unset = try parseForTest(&.{ "unset", "statusLine.context", "--json" });
    try std.testing.expectEqual(Action.unset, unset.action);
    try std.testing.expect(unset.value == null);

    for ([_][]const [:0]const u8{ &.{ "set", "fast_mode" }, &.{ "unset", "fast_mode", "x" }, &.{ "set", "fast_mode", "on", "--show-origin" } }) |args| {
        try std.testing.expectError(error.InvalidConfigArgs, parseForTest(args));
    }
    try std.testing.expectError(error.WorkspaceConfigWrite, parseForTest(&.{ "set", "fast_mode", "on", "--workspace" }));
    try std.testing.expectError(error.WorkspaceConfigWrite, parseForTest(&.{ "unset", "fast_mode", "--workspace" }));
}

fn changeForTest(args: []const [:0]const u8, problem: *WriteProblem) !Change {
    return change(try parseForTest(args), problem);
}

test "config set turns each value into the patch the save path writes" {
    var problem: WriteProblem = .none;
    const fast = try changeForTest(&.{ "set", "fast_mode", "off" }, &problem);
    try std.testing.expectEqual(false, fast.patch.fast_mode.?);
    try std.testing.expect(!fast.value.?.bool);

    const status = try changeForTest(&.{ "set", "statusLine.workspace", "true" }, &problem);
    try std.testing.expectEqual(settings_store.StatuslineItem.workspace, status.patch.statusline_item.?.item);

    const steps = try changeForTest(&.{ "set", "max_agent_steps", "0" }, &problem);
    try std.testing.expectEqual(@as(u32, 0), steps.patch.max_agent_steps.?);

    const pinned = try changeForTest(&.{ "set", "theme", "LIGHT" }, &problem);
    try std.testing.expectEqualStrings("light", pinned.patch.theme.?);

    const channel = try changeForTest(&.{ "set", "update_channel", "dev" }, &problem);
    try std.testing.expectEqualStrings("dev", channel.value.?.string);

    const removed = try changeForTest(&.{ "unset", "notifications.max" }, &problem);
    try std.testing.expectEqualStrings("notifications.max", removed.patch.remove.?);
    try std.testing.expect(removed.value == null);
}

test "config set explains a bad value or a key it doesn't change" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { args: []const [:0]const u8, err: anyerror, message: []const u8 }{
        .{ .args = &.{ "set", "fast_mode", "maybe" }, .err = error.InvalidConfigValue, .message = "invalid value for fast_mode: maybe (use true or false)" },
        .{ .args = &.{ "set", "max_tool_result_bytes", "12" }, .err = error.InvalidConfigValue, .message = "invalid value for max_tool_result_bytes: 12 (use a whole number of bytes, at least 1024)" },
        .{ .args = &.{ "set", "permission_mode", "full-access" }, .err = error.RefusedConfigSetting, .message = "can't change permission_mode with fx config; use /permissions in a session, or --permission-mode for one run" },
        .{ .args = &.{ "unset", "review_model" }, .err = error.RefusedConfigSetting, .message = "can't change review_model with fx config; edit ~/.fx/settings.json, or set FX_REVIEW_MODEL for one run" },
        .{ .args = &.{ "set", "models.codex", "gpt" }, .err = error.RefusedConfigSetting, .message = "can't change models.codex with fx config; use /model in a session" },
        .{ .args = &.{ "set", "yolo_acknowledged", "true" }, .err = error.RefusedConfigSetting, .message = "can't change yolo_acknowledged with fx config; fx manages it" },
    };
    for (cases) |case| {
        const options = try parseForTest(case.args);
        var problem: WriteProblem = .none;
        try std.testing.expectError(case.err, change(options, &problem));
        const message = try formatWriteProblem(alloc, options, problem);
        defer alloc.free(message);
        try std.testing.expectEqualStrings(case.message, message);
    }
}

test "every key config set writes is a plain setting in the list" {
    inline for (@typeInfo(Writable).@"enum".field_names) |name| {
        try std.testing.expect(settings_keys.unknownPart(name) == null);
        const dot = comptime std.mem.findScalar(u8, name, '.');
        const key = settings_keys.find(name[0 .. dot orelse name.len]).?;
        try std.testing.expect(!key.map and key.where != .retired);
    }
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
