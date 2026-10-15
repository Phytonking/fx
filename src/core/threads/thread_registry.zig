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

    /// The thread whose name is exactly `name`, ignoring case.
    pub fn find(self: *const Registry, name: []const u8) ?*const Thread {
        for (self.threads.items) |*t| {
            if (std.ascii.eqlIgnoreCase(t.name, name)) return t;
        }
        return null;
    }

    pub const Ambiguous = struct {
        /// Up to four of the matching names.
        names: [4][]const u8 = undefined,
        /// How many threads matched in all.
        count: usize = 0,
    };

    pub const Resolution = union(enum) {
        found: *const Thread,
        none,
        ambiguous: Ambiguous,
    };

    /// Finds a thread from what a person typed. Tries the whole name, then a
    /// name that starts with the text, then a name with a word equal to it,
    /// then a name that contains it, ignoring case. The first step with a
    /// single match wins; a step with several is ambiguous rather than a guess.
    pub fn resolve(self: *const Registry, query: []const u8) Resolution {
        if (query.len == 0) return .none;
        if (self.find(query)) |t| return .{ .found = t };
        const steps = [_]MatchKind{ .prefix, .word, .contains };
        for (steps) |kind| {
            var ambiguous = Ambiguous{};
            var first: ?*const Thread = null;
            for (self.threads.items) |*t| {
                if (!nameMatches(t.name, query, kind)) continue;
                if (ambiguous.count < ambiguous.names.len) ambiguous.names[ambiguous.count] = t.name;
                ambiguous.count += 1;
                if (first == null) first = t;
            }
            if (ambiguous.count == 1) return .{ .found = first.? };
            if (ambiguous.count > 1) return .{ .ambiguous = ambiguous };
        }
        return .none;
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
            if (std.ascii.eqlIgnoreCase(t.name, name)) return i;
        }
        return null;
    }
};

const MatchKind = enum { prefix, word, contains };

fn nameMatches(name: []const u8, query: []const u8, kind: MatchKind) bool {
    switch (kind) {
        .prefix => return name.len >= query.len and std.ascii.eqlIgnoreCase(name[0..query.len], query),
        .word => {
            var words = std.mem.tokenizeAny(u8, name, "-_");
            while (words.next()) |word| {
                if (std.ascii.eqlIgnoreCase(word, query)) return true;
            }
            return false;
        },
        .contains => {
            if (query.len > name.len) return false;
            var at: usize = 0;
            while (at + query.len <= name.len) : (at += 1) {
                if (std.ascii.eqlIgnoreCase(name[at .. at + query.len], query)) return true;
            }
            return false;
        },
    }
}

/// Names are mention-safe: `@thread:NAME` must parse without quoting.
pub fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_bytes) return error.InvalidThreadName;
    if (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return error.InvalidThreadName;
    for (name[1..]) |c| {
        if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-' and c != '_') return error.InvalidThreadName;
    }
    if (std.mem.eql(u8, name, root_thread_name)) return error.ReservedThreadName;
}

const suggest_max_words: usize = 5;

/// Words that carry no meaning in a name, so `search up more about rishav`
/// is named `search-rishav` and `@thread:rishav` finds it.
fn isFillerWord(word: []const u8) bool {
    const filler = [_][]const u8{
        "a",    "an", "the",  "of",   "to", "for",  "and",    "or",   "about", "up",
        "more", "on", "in",   "with", "me", "my",   "please", "can",  "you",   "could",
        "i",    "it", "is",   "are",  "be", "this", "that",   "some", "any",   "also",
        "just", "go", "then", "so",   "at", "from", "into",   "out",  "over",  "do",
    };
    for (filler) |f| {
        if (std.mem.eql(u8, word, f)) return true;
    }
    return false;
}

/// A thread name for free-form instructions: the first few words as a slug,
/// made unique among `registry`'s threads and never `main`. Caller owns the
/// result.
pub fn suggestName(alloc: Allocator, registry: *const Registry, instructions: []const u8) Allocator.Error![]u8 {
    var base: std.ArrayList(u8) = .empty;
    defer base.deinit(alloc);
    var words: usize = 0;
    var it = std.mem.tokenizeAny(u8, instructions, " \t\r\n");
    while (it.next()) |raw| {
        if (words == suggest_max_words) break;
        var word: [max_name_bytes]u8 = undefined;
        var len: usize = 0;
        for (raw) |c| {
            if (len == word.len) break;
            if (std.ascii.isAlphanumeric(c)) {
                word[len] = std.ascii.toLower(c);
                len += 1;
            } else if (len > 0 and word[len - 1] != '-') {
                word[len] = '-';
                len += 1;
            }
        }
        while (len > 0 and word[len - 1] == '-') len -= 1;
        if (len == 0) continue;
        if (isFillerWord(word[0..len])) continue;
        const separator: usize = if (base.items.len == 0) 0 else 1;
        if (base.items.len + separator + len > max_name_bytes) break;
        if (separator == 1) try base.append(alloc, '-');
        try base.appendSlice(alloc, word[0..len]);
        words += 1;
    }
    if (base.items.len == 0) try base.appendSlice(alloc, "thread");

    // Leave room for a "-N" suffix when the plain name is taken.
    var candidate = try alloc.dupe(u8, base.items);
    errdefer alloc.free(candidate);
    var n: usize = 1;
    while (registry.find(candidate) != null or std.mem.eql(u8, candidate, root_thread_name)) {
        n += 1;
        alloc.free(candidate);
        var suffix_buf: [16]u8 = undefined;
        const suffix = std.mem.print(&suffix_buf, "-{d}", .{n}) catch unreachable;
        const keep = @min(base.items.len, max_name_bytes - suffix.len);
        candidate = try std.mem.concat(alloc, u8, &.{ std.mem.trimEnd(u8, base.items[0..keep], "-"), suffix });
    }
    return candidate;
}

/// The agent name behind a thread. `unique` is any short string unique per
/// creation, such as a timestamp in hex. Caller owns the result.
pub fn agentNameFor(alloc: Allocator, name: []const u8, unique: u64) ![]u8 {
    return alloc.print("th-{x}-{s}", .{ unique, name });
}

/// The user-facing name inside a thread's agent name, or null when `agent`
/// does not come from `agentNameFor`.
pub fn nameFromAgent(agent: []const u8) ?[]const u8 {
    const prefix = "th-";
    if (!std.mem.startsWith(u8, agent, prefix)) return null;
    const rest = agent[prefix.len..];
    const dash = std.mem.findScalar(u8, rest, '-') orelse return null;
    if (dash == 0 or dash + 1 >= rest.len) return null;
    return rest[dash + 1 ..];
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

test "thread names come back out of agent names" {
    try std.testing.expectEqualStrings("fix-auth", nameFromAgent("th-abc123-fix-auth").?);
    try std.testing.expect(nameFromAgent("reviewer") == null);
    try std.testing.expect(nameFromAgent("th-abc") == null);
    try std.testing.expect(nameFromAgent("th--x") == null);
}

test "agent names are valid subagent names" {
    const alloc = std.testing.allocator;
    const agent = try agentNameFor(alloc, "fix-auth", 0xabc123);
    defer alloc.free(agent);
    try std.testing.expectEqualStrings("th-abc123-fix-auth", agent);
}

test "suggested names are a slug of the first words and stay valid" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "root1");
    defer registry.deinit(alloc);

    const plain = try suggestName(alloc, &registry, "Fix the login bug after a token refresh");
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("fix-login-bug-after-token", plain);

    const filler = try suggestName(alloc, &registry, "search up more about rishav");
    defer alloc.free(filler);
    try std.testing.expectEqualStrings("search-rishav", filler);
    try validateName(plain);

    const punctuated = try suggestName(alloc, &registry, "  ...Add `foo.bar` & tests!!  ");
    defer alloc.free(punctuated);
    try std.testing.expectEqualStrings("add-foo-bar-tests", punctuated);
    try validateName(punctuated);

    const empty = try suggestName(alloc, &registry, "!!! ???");
    defer alloc.free(empty);
    try std.testing.expectEqualStrings("thread", empty);

    const long = try suggestName(alloc, &registry, "internationalization-and-localization-infrastructure-overhaul now");
    defer alloc.free(long);
    try std.testing.expect(long.len <= max_name_bytes);
    try validateName(long);
}

test "suggested names avoid taken names and main" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "root1");
    defer registry.deinit(alloc);
    try registry.add(alloc, "fix-bug", "th-1-fix-bug", 1);

    const second = try suggestName(alloc, &registry, "fix the bug");
    defer alloc.free(second);
    try std.testing.expectEqualStrings("fix-bug-2", second);
    try registry.add(alloc, second, "th-2-x", 2);

    const third = try suggestName(alloc, &registry, "fix the bug");
    defer alloc.free(third);
    try std.testing.expectEqualStrings("fix-bug-3", third);

    const main_named = try suggestName(alloc, &registry, "main");
    defer alloc.free(main_named);
    try std.testing.expectEqualStrings("main-2", main_named);
    try validateName(main_named);
}

test "threads resolve from what a person types, ignoring case, by prefix, word, or part" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "root1");
    defer registry.deinit(alloc);
    try registry.add(alloc, "search-up-more-about-rishav", "th-1-a", 1);
    try registry.add(alloc, "fix-login-bug", "th-2-b", 2);
    try registry.add(alloc, "fix-logout", "th-3-c", 3);

    try std.testing.expectEqualStrings("search-up-more-about-rishav", registry.resolve("RISHAV").found.name);
    try std.testing.expectEqualStrings("search-up-more-about-rishav", registry.resolve("rishav").found.name);
    try std.testing.expectEqualStrings("search-up-more-about-rishav", registry.resolve("SEARCH").found.name);
    try std.testing.expectEqualStrings("fix-login-bug", registry.resolve("Fix-Login-Bug").found.name);
    try std.testing.expectEqualStrings("fix-login-bug", registry.resolve("bug").found.name);
    try std.testing.expectEqualStrings("search-up-more-about-rishav", registry.resolve("ishav").found.name);

    // Several matches are reported, not guessed.
    const fix = registry.resolve("fix").ambiguous;
    try std.testing.expectEqual(@as(usize, 2), fix.count);
    try std.testing.expectEqualStrings("fix-login-bug", fix.names[0]);
    try std.testing.expect(registry.resolve("nothing") == .none);
    try std.testing.expect(registry.resolve("") == .none);
}
