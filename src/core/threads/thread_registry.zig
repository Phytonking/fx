//! Thread registry: named threads that stem from one root session.
//!
//! A thread is an ordinary saved session. The registry only records which
//! sessions belong together and what each is called, so it works with every
//! session backend and adds no field to session metadata. One file per root
//! lives at `~/.fx/threads/<root-id>.json`. The root session is the implicit
//! thread named `main`.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");

const Allocator = std.mem.Allocator;

pub const root_thread_name = "main";
pub const max_name_bytes: usize = 32;
const max_file_bytes: usize = 1024 * 1024;
const schema_version: u32 = 1;

pub const Error = error{
    InvalidThreadName,
    ReservedThreadName,
    DuplicateThreadName,
    ThreadNotFound,
    InvalidRegistry,
};

pub const Thread = struct {
    /// What the user types.
    name: []u8,
    /// The persistent child's unique agent name. Never reused, so a deleted
    /// thread's name can come back without inheriting its history.
    agent: []u8,
    /// The thread's saved session. Empty until the thread has started.
    session_id: []u8,
    created_at_ms: i64,
};

/// Owns every string it holds.
pub const Registry = struct {
    root_id: []u8,
    threads: std.ArrayList(Thread) = .empty,

    pub fn init(alloc: Allocator, root_id: []const u8) !Registry {
        return .{ .root_id = try alloc.dupe(u8, root_id) };
    }

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        for (self.threads.items) |t| {
            alloc.free(t.name);
            alloc.free(t.agent);
            alloc.free(t.session_id);
        }
        self.threads.deinit(alloc);
        alloc.free(self.root_id);
        self.* = undefined;
    }

    pub fn find(self: *const Registry, name: []const u8) ?*const Thread {
        for (self.threads.items) |*t| {
            if (std.mem.eql(u8, t.name, name)) return t;
        }
        return null;
    }

    pub fn add(self: *Registry, alloc: Allocator, name: []const u8, agent: []const u8, now_ms: i64) !void {
        try validateName(name);
        if (self.find(name) != null) return error.DuplicateThreadName;
        const owned_name = try alloc.dupe(u8, name);
        errdefer alloc.free(owned_name);
        const owned_agent = try alloc.dupe(u8, agent);
        errdefer alloc.free(owned_agent);
        const owned_session = try alloc.dupe(u8, "");
        errdefer alloc.free(owned_session);
        try self.threads.append(alloc, .{ .name = owned_name, .agent = owned_agent, .session_id = owned_session, .created_at_ms = now_ms });
    }

    pub fn setSession(self: *Registry, alloc: Allocator, name: []const u8, session_id: []const u8) !void {
        const index = self.indexOf(name) orelse return error.ThreadNotFound;
        const owned = try alloc.dupe(u8, session_id);
        alloc.free(self.threads.items[index].session_id);
        self.threads.items[index].session_id = owned;
    }

    pub fn findBySession(self: *const Registry, session_id: []const u8) ?*const Thread {
        if (session_id.len == 0) return null;
        for (self.threads.items) |*t| {
            if (std.mem.eql(u8, t.session_id, session_id)) return t;
        }
        return null;
    }

    pub fn rename(self: *Registry, alloc: Allocator, old_name: []const u8, new_name: []const u8) !void {
        try validateName(new_name);
        const index = self.indexOf(old_name) orelse return error.ThreadNotFound;
        if (self.find(new_name)) |other| {
            if (other != &self.threads.items[index]) return error.DuplicateThreadName;
        }
        const owned = try alloc.dupe(u8, new_name);
        alloc.free(self.threads.items[index].name);
        self.threads.items[index].name = owned;
    }

    /// Drops the entry. The caller deletes the session it named.
    pub fn remove(self: *Registry, alloc: Allocator, name: []const u8) !void {
        const index = self.indexOf(name) orelse return error.ThreadNotFound;
        const t = self.threads.orderedRemove(index);
        alloc.free(t.name);
        alloc.free(t.agent);
        alloc.free(t.session_id);
    }

    fn indexOf(self: *const Registry, name: []const u8) ?usize {
        for (self.threads.items, 0..) |t, i| {
            if (std.mem.eql(u8, t.name, name)) return i;
        }
        return null;
    }
};

/// Names are mention-safe: `@thread:NAME` must parse without quoting.
pub fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidThreadName;
    if (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return error.InvalidThreadName;
    for (name[1..]) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-' and c != '_') return error.InvalidThreadName;
    }
    if (std.mem.eql(u8, name, root_thread_name)) return error.ReservedThreadName;
}

/// The agent name behind a thread. `unique` is any short string unique per
/// creation, such as a timestamp in hex. Caller owns the result.
pub fn agentNameFor(alloc: Allocator, name: []const u8, unique: u64) ![]u8 {
    return alloc.print("th-{x}-{s}", .{ unique, name });
}

/// Caller owns the result.
pub fn registryPath(alloc: Allocator, home: []const u8, root_id: []const u8) ![]u8 {
    const file_name = try alloc.print("{s}.json", .{root_id});
    defer alloc.free(file_name);
    return std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, profile_paths.threads_dir_name, file_name });
}

/// An unreadable or missing file yields an empty registry only for
/// `FileNotFound`; corrupt content is an error so it is never overwritten.
pub fn load(alloc: Allocator, home: []const u8, root_id: []const u8) !Registry {
    var registry = try Registry.init(alloc, root_id);
    errdefer registry.deinit(alloc);

    const path = try registryPath(alloc, home, root_id);
    defer alloc.free(path);
    var file = std.Io.Dir.openFileAbsolute(io_mod.getIo(), path, .{}) catch |err| switch (err) {
        error.FileNotFound => return registry,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = try io_mod.readFileToEnd(alloc, &file, max_file_bytes);
    defer alloc.free(bytes);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch return error.InvalidRegistry;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidRegistry,
    };
    const version = switch (obj.get("schema_version") orelse return error.InvalidRegistry) {
        .integer => |i| i,
        else => return error.InvalidRegistry,
    };
    if (version != schema_version) return error.InvalidRegistry;
    const items = switch (obj.get("threads") orelse return error.InvalidRegistry) {
        .array => |a| a.items,
        else => return error.InvalidRegistry,
    };
    for (items) |item| {
        const o = switch (item) {
            .object => |o| o,
            else => return error.InvalidRegistry,
        };
        const name = stringField(o, "name") orelse return error.InvalidRegistry;
        const agent = stringField(o, "agent") orelse return error.InvalidRegistry;
        const created: i64 = switch (o.get("created_at_ms") orelse return error.InvalidRegistry) {
            .integer => |i| i,
            else => return error.InvalidRegistry,
        };
        registry.add(alloc, name, agent, created) catch return error.InvalidRegistry;
        if (stringField(o, "session_id")) |session_id| {
            if (session_id.len > 0) registry.setSession(alloc, name, session_id) catch return error.InvalidRegistry;
        }
    }
    return registry;
}

pub fn save(alloc: Allocator, home: []const u8, registry: *const Registry) !void {
    const path = try registryPath(alloc, home, registry.root_id);
    defer alloc.free(path);
    if (std.Io.Dir.path.dirname(path)) |dir| try io_mod.makeDirRecursive(dir);

    const Row = struct { name: []const u8, agent: []const u8, session_id: []const u8, created_at_ms: i64 };
    const rows = try alloc.alloc(Row, registry.threads.items.len);
    defer alloc.free(rows);
    for (registry.threads.items, rows) |t, *row| {
        row.* = .{ .name = t.name, .agent = t.agent, .session_id = t.session_id, .created_at_ms = t.created_at_ms };
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(.{
        .schema_version = schema_version,
        .root_id = registry.root_id,
        .threads = rows,
    }, .{}, &out.writer);
    try io_mod.writeFileAtomic(alloc, path, out.written());
}

/// The registry that lists `session_id` as one of its threads, or null.
/// Caller owns the result.
pub fn loadForThreadSession(alloc: Allocator, home: []const u8, session_id: []const u8) !?Registry {
    const dir_path = try std.Io.Dir.path.join(alloc, &.{ home, profile_paths.root_dir_name, profile_paths.threads_dir_name });
    defer alloc.free(dir_path);
    var dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io_mod.getIo());
    var it = dir.iterate();
    while (try it.next(io_mod.getIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const root_id = entry.name[0 .. entry.name.len - ".json".len];
        var registry = load(alloc, home, root_id) catch continue;
        if (registry.findBySession(session_id) != null) return registry;
        registry.deinit(alloc);
    }
    return null;
}

fn stringField(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return switch (o.get(key) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

test "thread names are mention-safe and never claim main" {
    try validateName("fix-auth");
    try validateName("a_b-1");
    try std.testing.expectError(error.InvalidThreadName, validateName(""));
    try std.testing.expectError(error.InvalidThreadName, validateName("has space"));
    try std.testing.expectError(error.InvalidThreadName, validateName("Upper"));
    try std.testing.expectError(error.InvalidThreadName, validateName("-lead"));
    try std.testing.expectError(error.InvalidThreadName, validateName(&@as([33]u8, @splat('a'))));
    try std.testing.expectError(error.ReservedThreadName, validateName("main"));
}

test "registry add, rename, remove keep names unique" {
    const alloc = std.testing.allocator;
    var r = try Registry.init(alloc, "root1");
    defer r.deinit(alloc);
    try r.add(alloc, "alpha", "th-1-alpha", 1);
    try r.add(alloc, "beta", "th-2-beta", 2);
    try std.testing.expectError(error.DuplicateThreadName, r.add(alloc, "alpha", "th-3-alpha", 3));
    try std.testing.expectError(error.DuplicateThreadName, r.rename(alloc, "alpha", "beta"));
    try r.rename(alloc, "alpha", "gamma");
    try std.testing.expectEqualStrings("th-1-alpha", r.find("gamma").?.agent);
    try r.remove(alloc, "beta");
    try std.testing.expect(r.find("beta") == null);
    try std.testing.expectError(error.ThreadNotFound, r.remove(alloc, "beta"));
}

test "registry round trips through disk" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var missing = try load(alloc, home, "root1");
    defer missing.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 0), missing.threads.items.len);

    var r = try Registry.init(alloc, "root1");
    defer r.deinit(alloc);
    try r.add(alloc, "alpha", "th-1-alpha", 10);
    try save(alloc, home, &r);

    var loaded = try load(alloc, home, "root1");
    defer loaded.deinit(alloc);
    try std.testing.expectEqual(@as(i64, 10), loaded.find("alpha").?.created_at_ms);
    try std.testing.expectEqualStrings("th-1-alpha", loaded.find("alpha").?.agent);

    try loaded.setSession(alloc, "alpha", "sess-9");
    try save(alloc, home, &loaded);
    var from_thread = (try loadForThreadSession(alloc, home, "sess-9")).?;
    defer from_thread.deinit(alloc);
    try std.testing.expectEqualStrings("root1", from_thread.root_id);
    try std.testing.expect(try loadForThreadSession(alloc, home, "other") == null);
}

test "agent names are valid subagent names" {
    const alloc = std.testing.allocator;
    const agent = try agentNameFor(alloc, "fix-auth", 0xabc123);
    defer alloc.free(agent);
    try std.testing.expectEqualStrings("th-abc123-fix-auth", agent);
}
