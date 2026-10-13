//! Messages about settings keys fx doesn't know, shared by `fx doctor` and
//! `fx config`.

const std = @import("std");
const cli_flags = @import("cli_flags.zig");
const settings_keys = @import("../config/settings_keys.zig");

const Allocator = std.mem.Allocator;

/// The known key closest to `name` within two edits, if any.
pub fn closest(name: []const u8, known: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = 3;
    for (known) |candidate| {
        const distance = cli_flags.editDistance(name, candidate) orelse continue;
        if (distance < best_distance) {
            best = candidate;
            best_distance = distance;
        }
    }
    return best;
}

/// `unknown setting statusLine.contxt in ~/.fx/settings.json (did you mean
/// statusLine.context?)`, for a key found in a settings file. Caller owns the
/// result.
pub fn formatUnknownSetting(alloc: Allocator, key: settings_keys.UnknownKey, display_path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("unknown setting ");
    try writeDotted(writer, key.parent, key.name);
    try writer.print(" in {s}", .{display_path});
    if (key.workspace) |workspace| try writer.print(" for workspace {s}", .{workspace});
    try writeSuggestion(writer, key.parent, closest(key.name, key.known));
    return out.toOwnedSlice();
}

/// `unknown setting fast_mdoe (did you mean fast_mode?)`, for a key typed on
/// the command line. Caller owns the result.
pub fn formatUnknownPath(alloc: Allocator, part: settings_keys.UnknownPart) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("unknown setting ");
    try writeDotted(&out.writer, part.parent, part.name);
    try writeSuggestion(&out.writer, part.parent, closest(part.name, part.known));
    return out.toOwnedSlice();
}

fn writeDotted(writer: *std.Io.Writer, parent: ?[]const u8, name: []const u8) !void {
    if (parent) |value| try writer.print("{s}.", .{value});
    try writer.writeAll(name);
}

fn writeSuggestion(writer: *std.Io.Writer, parent: ?[]const u8, suggestion: ?[]const u8) !void {
    const name = suggestion orelse return;
    try writer.writeAll(" (did you mean ");
    try writeDotted(writer, parent, name);
    try writer.writeAll("?)");
}

test "unknown settings name the file, the workspace, and the closest key" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { key: settings_keys.UnknownKey, file: []const u8, expected: []const u8 }{
        .{
            .key = .{ .name = "fast_mdoe", .known = &.{ "fast_mode", "model" } },
            .file = "~/.fx/settings.json",
            .expected = "unknown setting fast_mdoe in ~/.fx/settings.json (did you mean fast_mode?)",
        },
        .{
            .key = .{ .name = "contxt", .parent = "statusLine", .workspace = "/w", .known = &.{ "context", "session" } },
            .file = "~/.fx/settings.json",
            .expected = "unknown setting statusLine.contxt in ~/.fx/settings.json for workspace /w (did you mean statusLine.context?)",
        },
        .{
            .key = .{ .name = "colour", .known = &.{ "model", "theme" } },
            .file = ".fx.json",
            .expected = "unknown setting colour in .fx.json",
        },
    };
    for (cases) |case| {
        const detail = try formatUnknownSetting(alloc, case.key, case.file);
        defer alloc.free(detail);
        try std.testing.expectEqualStrings(case.expected, detail);
    }
}

test "a mistyped key on the command line gets the closest known key" {
    const alloc = std.testing.allocator;
    const cases = [_]struct { path: []const u8, expected: []const u8 }{
        .{ .path = "fast_mdoe", .expected = "unknown setting fast_mdoe (did you mean fast_mode?)" },
        .{ .path = "statusLine.sesion", .expected = "unknown setting statusLine.sesion (did you mean statusLine.session?)" },
        .{ .path = "fast_mode.on", .expected = "unknown setting fast_mode.on" },
    };
    for (cases) |case| {
        const message = try formatUnknownPath(alloc, settings_keys.unknownPart(case.path).?);
        defer alloc.free(message);
        try std.testing.expectEqualStrings(case.expected, message);
    }
}
