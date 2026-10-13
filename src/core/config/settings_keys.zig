//! The settings fx knows, like the kernel's sysctl table: every key it reads
//! from the profile `settings.json`, a workspace override inside it, or a
//! project `.fx.json`. Startup ignores keys missing from this list; `fx doctor`
//! reports them.

const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Where = enum {
    /// Profile `settings.json` and its workspace overrides. A project
    /// `.fx.json` that sets it is ignored with a warning.
    profile,
    /// Also a repo-safe default in a project `.fx.json`.
    project_safe,
    /// No longer used. Read only so it is ignored without being reported.
    retired,
};

pub const Key = struct {
    name: []const u8,
    where: Where,
    /// Fixed child keys of an object setting, such as `statusLine.context`.
    /// Empty for plain values and for maps.
    children: []const []const u8 = &.{},
    /// An object whose keys are free-form, such as `models.codex`.
    map: bool = false,

    pub fn hasChild(self: Key, name: []const u8) bool {
        for (self.children) |child| {
            if (std.mem.eql(u8, child, name)) return true;
        }
        return false;
    }
};

pub const keys = [_]Key{
    .{ .name = "additional_directories", .where = .profile },
    .{ .name = "auto_compact_percent", .where = .profile },
    .{ .name = "auto_upgrade", .where = .profile },
    .{ .name = "codex_model", .where = .profile },
    .{ .name = "collapse_tool_calls", .where = .profile },
    .{ .name = "context", .where = .project_safe },
    .{ .name = "context_limits", .where = .profile, .map = true },
    .{ .name = "credential_source", .where = .profile },
    .{ .name = "disabledMcpjsonServers", .where = .profile },
    .{ .name = "effort", .where = .profile },
    .{ .name = "enableAllProjectMcpServers", .where = .profile },
    .{ .name = "enabledMcpjsonServers", .where = .profile },
    .{ .name = "fast_mode", .where = .profile },
    .{ .name = "fast_mode_model_bound", .where = .profile },
    .{ .name = "first_call_tool_choice", .where = .profile },
    .{ .name = "grok_model", .where = .profile },
    .{ .name = "input_appearance", .where = .retired },
    .{ .name = "max_agent_steps", .where = .project_safe },
    .{ .name = "max_tool_result_bytes", .where = .project_safe },
    .{ .name = "maxxing_mode", .where = .retired },
    .{ .name = "model", .where = .profile },
    .{ .name = "models", .where = .profile, .map = true },
    .{ .name = "notifications", .where = .profile, .children = &.{ "attention_required", "max", "turn_end" } },
    .{ .name = "permission", .where = .profile, .map = true },
    .{ .name = "permission_mode", .where = .profile },
    .{ .name = "prompt_history", .where = .profile, .children = &.{"enabled"} },
    .{ .name = "provider", .where = .profile },
    .{ .name = "provider_order", .where = .project_safe },
    .{ .name = "provider_strict", .where = .project_safe },
    .{ .name = "providers", .where = .profile, .map = true },
    .{ .name = "review_model", .where = .profile },
    .{ .name = "session_titles", .where = .profile },
    // Retired, but still read so that fx can explain the migration.
    .{ .name = "skill_match_fuzzy", .where = .profile },
    .{ .name = "skill_symlink_authorities", .where = .profile },
    .{ .name = "slash_menu_categories", .where = .profile },
    .{ .name = "startup_scrollback", .where = .profile },
    .{ .name = "statusLine", .where = .profile, .children = &.{ "context", "session", "workspace" } },
    .{ .name = "theme", .where = .profile },
    .{ .name = "ultrafast_mode", .where = .profile },
    .{ .name = "update_channel", .where = .profile },
    .{ .name = "web_fetch_worker_model", .where = .retired },
    .{ .name = "workspaces", .where = .profile, .map = true },
    .{ .name = "yolo_acknowledged", .where = .profile },
};

const names = blk: {
    var list: [keys.len][]const u8 = undefined;
    for (keys, 0..) |key, index| list[index] = key.name;
    break :blk list;
};

pub fn find(name: []const u8) ?Key {
    for (keys) |key| {
        if (std.mem.eql(u8, key.name, name)) return key;
    }
    return null;
}

/// True when a project `.fx.json` that sets `name` is ignored and the user
/// should be told: a known setting that only the profile may set.
pub fn ignoredInProject(name: []const u8) bool {
    const key = find(name) orelse return false;
    return key.where == .profile;
}

pub const File = enum { profile, project };

pub const UnknownKey = struct {
    /// The key, borrowed from the parsed settings.
    name: []const u8,
    /// The object setting holding the key, such as `statusLine`, or null at
    /// the top level.
    parent: ?[]const u8 = null,
    /// The workspace override holding the key, borrowed from the parsed
    /// settings, or null outside `workspaces`.
    workspace: ?[]const u8 = null,
    /// The known keys at the same level, for a "did you mean" suggestion.
    known: []const []const u8,
};

/// Lists the keys in `root` that fx doesn't know. A profile `settings.json`
/// is also checked inside each `workspaces` override. Values of the wrong
/// type are left to the settings parser. Caller owns the returned slice;
/// its strings borrow from `root`.
pub fn findUnknown(alloc: Allocator, root: std.json.Value, file: File) ![]UnknownKey {
    var found: std.ArrayList(UnknownKey) = .empty;
    errdefer found.deinit(alloc);
    if (root != .object) return found.toOwnedSlice(alloc);

    try appendUnknown(alloc, &found, root.object, null);
    if (file == .profile) {
        if (root.object.get("workspaces")) |workspaces| {
            if (workspaces == .object) {
                var iterator = workspaces.object.iterator();
                while (iterator.next()) |entry| {
                    if (entry.value_ptr.* != .object) continue;
                    try appendUnknown(alloc, &found, entry.value_ptr.object, entry.key_ptr.*);
                }
            }
        }
    }
    return found.toOwnedSlice(alloc);
}

fn appendUnknown(
    alloc: Allocator,
    found: *std.ArrayList(UnknownKey),
    object: std.json.ObjectMap,
    workspace: ?[]const u8,
) !void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const name = entry.key_ptr.*;
        const key = find(name) orelse {
            try found.append(alloc, .{ .name = name, .workspace = workspace, .known = &names });
            continue;
        };
        if (key.children.len == 0 or entry.value_ptr.* != .object) continue;
        var children = entry.value_ptr.object.iterator();
        while (children.next()) |child| {
            if (key.hasChild(child.key_ptr.*)) continue;
            try found.append(alloc, .{
                .name = child.key_ptr.*,
                .parent = key.name,
                .workspace = workspace,
                .known = key.children,
            });
        }
    }
}

pub const UnknownPart = struct {
    /// The part of the path that names no setting.
    name: []const u8,
    /// The setting holding it, such as `statusLine`, or null at the top level.
    parent: ?[]const u8 = null,
    /// The known keys at the same level, for a "did you mean" suggestion.
    known: []const []const u8,
};

/// Null when a dotted `path` names a setting: a listed key, a fixed child
/// such as `statusLine.context`, or any path into a map such as
/// `models.codex`. Otherwise the part that isn't known. Retired keys aren't
/// settings. Slices borrow from `path` and the list.
pub fn unknownPart(path: []const u8) ?UnknownPart {
    const dot = std.mem.findScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    const key = find(head) orelse return .{ .name = head, .known = &names };
    if (key.where == .retired) return .{ .name = head, .known = &names };
    const at = dot orelse return null;
    if (key.map) return null;
    const rest = path[at + 1 ..];
    if (key.children.len == 0) return .{ .name = rest, .parent = key.name, .known = &.{} };
    if (std.mem.findScalar(u8, rest, '.') == null and key.hasChild(rest)) return null;
    return .{ .name = rest, .parent = key.name, .known = key.children };
}

test "keys are unique and sorted so the list stays easy to scan" {
    for (keys[1..], 1..) |key, index| {
        try std.testing.expect(std.mem.order(u8, keys[index - 1].name, key.name) == .lt);
    }
}

test "project files ignore profile keys but not project-safe or retired ones" {
    try std.testing.expect(ignoredInProject("model"));
    try std.testing.expect(ignoredInProject("workspaces"));
    try std.testing.expect(ignoredInProject("enabledMcpjsonServers"));
    try std.testing.expect(!ignoredInProject("max_agent_steps"));
    try std.testing.expect(!ignoredInProject("provider_order"));
    try std.testing.expect(!ignoredInProject("maxxing_mode"));
    try std.testing.expect(!ignoredInProject("not_a_setting"));
}

test "unknown keys are found at the top level, in fixed objects, and in workspace overrides" {
    const alloc = std.testing.allocator;
    const text =
        \\{"fast_mdoe":true,"model":"m","maxxing_mode":1,
        \\ "statusLine":{"context":true,"contxt":false},
        \\ "notifications":"off",
        \\ "models":{"anything":"m"},
        \\ "workspaces":{"/w":{"effort":"high","efort":"low","statusLine":{"sesion":true}},"/bad":3}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, text, .{});
    defer parsed.deinit();

    const unknown = try findUnknown(alloc, parsed.value, .profile);
    defer alloc.free(unknown);
    try std.testing.expectEqual(@as(usize, 4), unknown.len);

    try std.testing.expectEqualStrings("fast_mdoe", unknown[0].name);
    try std.testing.expect(unknown[0].parent == null and unknown[0].workspace == null);
    try std.testing.expectEqual(@as(usize, keys.len), unknown[0].known.len);

    try std.testing.expectEqualStrings("contxt", unknown[1].name);
    try std.testing.expectEqualStrings("statusLine", unknown[1].parent.?);
    try std.testing.expectEqual(@as(usize, 3), unknown[1].known.len);

    try std.testing.expectEqualStrings("efort", unknown[2].name);
    try std.testing.expectEqualStrings("/w", unknown[2].workspace.?);

    try std.testing.expectEqualStrings("sesion", unknown[3].name);
    try std.testing.expectEqualStrings("statusLine", unknown[3].parent.?);
    try std.testing.expectEqualStrings("/w", unknown[3].workspace.?);
}

test "a project file is checked at its top level only" {
    const alloc = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        alloc,
        \\{"max_agent_step":5,"model":"m","workspaces":{"/w":{"efort":"low"}}}
    ,
        .{},
    );
    defer parsed.deinit();

    const unknown = try findUnknown(alloc, parsed.value, .project);
    defer alloc.free(unknown);
    try std.testing.expectEqual(@as(usize, 1), unknown.len);
    try std.testing.expectEqualStrings("max_agent_step", unknown[0].name);
}

test "dotted paths name listed keys, fixed children, and paths into maps" {
    for ([_][]const u8{ "fast_mode", "statusLine", "statusLine.context", "models", "models.codex", "providers.local.base_url" }) |path| {
        try std.testing.expect(unknownPart(path) == null);
    }

    const top = unknownPart("fast_mdoe").?;
    try std.testing.expectEqualStrings("fast_mdoe", top.name);
    try std.testing.expect(top.parent == null and top.known.len == keys.len);

    const child = unknownPart("statusLine.contxt").?;
    try std.testing.expectEqualStrings("contxt", child.name);
    try std.testing.expectEqualStrings("statusLine", child.parent.?);
    try std.testing.expectEqual(@as(usize, 3), child.known.len);

    const under_value = unknownPart("fast_mode.on").?;
    try std.testing.expectEqualStrings("on", under_value.name);
    try std.testing.expectEqual(@as(usize, 0), under_value.known.len);

    try std.testing.expect(unknownPart("statusLine.context.x") != null);
    try std.testing.expect(unknownPart("maxxing_mode") != null);
}

test "a non-object file has no unknown keys" {
    const unknown = try findUnknown(std.testing.allocator, .{ .integer = 3 }, .profile);
    defer std.testing.allocator.free(unknown);
    try std.testing.expectEqual(@as(usize, 0), unknown.len);
}
