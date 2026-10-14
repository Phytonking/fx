//! `/thread`: named threads of work that run beside the current session.
//!
//! A thread is a persistent subagent child of the root session with its own
//! saved session and context. This file parses the slash command and drives
//! the subagent host; `core/threads` holds the pure parts.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const app_permission_runtime = @import("app_permission_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const provider_runtime = @import("provider_runtime.zig");
const subagent_tool_host = @import("../subagent/tool_host.zig");
const thread_registry = @import("../threads/thread_registry.zig");
const thread_feed = @import("../threads/thread_feed.zig");
const thread_tools = @import("../threads/thread_tools.zig");

const Allocator = std.mem.Allocator;

pub const usage = "usage: /thread new NAME TASK | list | switch NAME | watch NAME [LINES] | send NAME MESSAGE | stop NAME | rename OLD NEW | delete NAME";
/// Lines a live view keeps on screen; older ones scroll out of it.
const follow_lines: usize = 12;
const follow_interval_ms: i64 = 120;

/// The one live view `/thread watch NAME` keeps up to date. It owns no
/// allocations: the text is rebuilt from the thread's feed on each refresh.
pub const WatchState = struct {
    active: bool = false,
    entry_id: u32 = 0,
    /// The subagent host the view was started on. A different host means the
    /// session changed and the view ends.
    host: usize = 0,
    child_id_buf: [64]u8 = undefined,
    child_id_len: usize = 0,
    name_buf: [thread_registry.max_name_bytes]u8 = undefined,
    name_len: usize = 0,
    started_ms: i64 = 0,
    last_refresh_ms: i64 = 0,
    last_hash: u64 = 0,

    fn childId(self: *const WatchState) []const u8 {
        return self.child_id_buf[0..self.child_id_len];
    }

    fn name(self: *const WatchState) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

pub const Action = union(enum) {
    list,
    new: struct { name: []const u8, task: []const u8 },
    /// `lines` null follows the thread live; a count prints that many once.
    watch: struct { name: []const u8, lines: ?usize },
    send: struct { name: []const u8, message: []const u8 },
    stop: []const u8,
    @"switch": []const u8,
    rename: struct { old: []const u8, new: []const u8 },
    delete: []const u8,
};

pub const ParseError = error{InvalidThreadCommand};

/// Borrows from `rest`.
pub fn parse(rest: []const u8) ParseError!Action {
    const trimmed = std.mem.trim(u8, rest, " \t");
    if (trimmed.len == 0) return .list;
    const verb, const tail = splitWord(trimmed);
    if (std.mem.eql(u8, verb, "list")) {
        if (tail.len != 0) return error.InvalidThreadCommand;
        return .list;
    }
    if (std.mem.eql(u8, verb, "new")) {
        const name, const task = splitWord(tail);
        if (name.len == 0 or task.len == 0) return error.InvalidThreadCommand;
        return .{ .new = .{ .name = name, .task = task } };
    }
    if (std.mem.eql(u8, verb, "send")) {
        const name, const message = splitWord(tail);
        if (name.len == 0 or message.len == 0) return error.InvalidThreadCommand;
        return .{ .send = .{ .name = name, .message = message } };
    }
    if (std.mem.eql(u8, verb, "watch")) {
        const name, const count = splitWord(tail);
        if (name.len == 0) return error.InvalidThreadCommand;
        if (count.len == 0) return .{ .watch = .{ .name = name, .lines = null } };
        const lines = std.fmt.parseInt(usize, count, 10) catch return error.InvalidThreadCommand;
        if (lines == 0 or lines > thread_feed.default_max_lines) return error.InvalidThreadCommand;
        return .{ .watch = .{ .name = name, .lines = lines } };
    }
    if (std.mem.eql(u8, verb, "stop") or std.mem.eql(u8, verb, "delete") or std.mem.eql(u8, verb, "switch")) {
        const name, const extra = splitWord(tail);
        if (name.len == 0 or extra.len != 0) return error.InvalidThreadCommand;
        if (std.mem.eql(u8, verb, "stop")) return .{ .stop = name };
        if (std.mem.eql(u8, verb, "delete")) return .{ .delete = name };
        return .{ .@"switch" = name };
    }
    if (std.mem.eql(u8, verb, "rename")) {
        const old, const new_tail = splitWord(tail);
        const new, const extra = splitWord(new_tail);
        if (old.len == 0 or new.len == 0 or extra.len != 0) return error.InvalidThreadCommand;
        return .{ .rename = .{ .old = old, .new = new } };
    }
    return error.InvalidThreadCommand;
}

fn splitWord(text: []const u8) struct { []const u8, []const u8 } {
    const trimmed = std.mem.trim(u8, text, " \t");
    const end = std.mem.findAny(u8, trimmed, " \t") orelse return .{ trimmed, "" };
    return .{ trimmed[0..end], std.mem.trim(u8, trimmed[end..], " \t") };
}

pub fn Runtime(comptime App: type) type {
    const SessionRuntime = app_session_runtime.Runtime(App);

    return struct {
        /// True, after telling the user, when a thread of the current session is
        /// running. Changing the session ends its host and with it every thread
        /// turn, so `what` names the action being refused.
        pub fn blocksSessionChange(app: *App, what: []const u8) !bool {
            const host = SessionRuntime.subagentHost(app) orelse return false;
            const root_id = SessionRuntime.activeSessionId(app) orelse return false;
            const home = io_mod.homeDir() orelse return false;
            var registry = thread_registry.load(app.alloc, home, root_id) catch return false;
            defer registry.deinit(app.alloc);
            const running = runningThread(host, &registry) orelse return false;
            try noticeFmt(app, .@"error", "thread", "Thread {s} is still running. Stop it with /thread stop {s} before you {s}.", .{ running, running, what });
            return true;
        }

        fn runningThread(host: *subagent_tool_host.Runtime, registry: *const thread_registry.Registry) ?[]const u8 {
            for (registry.threads.items) |t| {
                if (t.session_id.len != 0 and host.managed.hasRunningChild(t.session_id)) return t.name;
            }
            return null;
        }

        pub fn handle(app: *App, rest: []const u8) !void {
            const action = parse(rest) catch {
                try notice(app, .@"error", "", usage);
                return;
            };
            const host = SessionRuntime.subagentHost(app) orelse {
                try notice(app, .@"error", "thread", "Threads need a saved session in the default session format.");
                return;
            };
            const root_id = SessionRuntime.activeSessionId(app) orelse {
                try notice(app, .@"error", "thread", "No active session.");
                return;
            };
            const home = io_mod.homeDir() orelse {
                try notice(app, .@"error", "thread", "No home directory for thread state.");
                return;
            };
            // Inside a thread, the registry is the one of the session it stems from.
            var registry = (thread_registry.loadForThreadSession(app.alloc, home, root_id) catch null) orelse
                thread_registry.load(app.alloc, home, root_id) catch |err| {
                try noticeFmt(app, .@"error", "thread", "Thread list unreadable: {s}", .{@errorName(err)});
                return;
            };
            defer registry.deinit(app.alloc);
            const current_thread: ?[]const u8 = if (registry.findBySession(root_id)) |t| t.name else null;

            switch (action) {
                .list => try list(app, host, &registry, current_thread),
                .@"switch" => |name| try switchTo(app, host, &registry, current_thread, name),
                .rename => |a| try rename(app, &registry, home, a.old, a.new),
                else => {},
            }
            switch (action) {
                .list, .@"switch", .rename => return,
                else => {},
            }
            if (current_thread) |name| {
                try noticeFmt(app, .@"error", "thread", "You are in thread {s}. Run /thread switch main first.", .{name});
                return;
            }
            switch (action) {
                .new => |a| try create(app, host, &registry, root_id, home, a.name, a.task),
                .send => |a| try send(app, host, &registry, root_id, a.name, a.message),
                .watch => |a| try watch(app, host, &registry, a.name, a.lines),
                .stop => |name| try stop(app, host, &registry, name),
                .delete => |name| try remove(app, host, &registry, home, name),
                .list, .@"switch", .rename => unreachable,
            }
        }

        fn switchTo(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            current_thread: ?[]const u8,
            name: []const u8,
        ) !void {
            if (current_thread) |current| {
                if (std.mem.eql(u8, current, name)) {
                    try noticeFmt(app, .neutral, "thread", "You are already in {s}.", .{name});
                    return;
                }
            } else if (std.mem.eql(u8, name, thread_registry.root_thread_name)) {
                try notice(app, .neutral, "thread", "You are already in main.");
                return;
            }
            const target: []const u8 = if (std.mem.eql(u8, name, thread_registry.root_thread_name))
                registry.root_id
            else blk: {
                const t = registry.find(name) orelse return missing(app, name);
                if (t.session_id.len == 0) {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} has not started yet.", .{name});
                    return;
                }
                break :blk t.session_id;
            };
            if (current_thread == null) {
                if (runningThread(host, registry)) |running| {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} is still running and would stop. Stop it with /thread stop {s} or wait, then switch.", .{ running, running });
                    return;
                }
            }
            if (app.stream.active or !app.worker.tryHoldTurnStart()) {
                try notice(app, .@"error", "thread", "A turn is running in this session. Wait for it to finish, then switch.");
                return;
            }
            app.worker.releaseTurnStartHold();
            SessionRuntime.switchForegroundSession(app, target) catch |err| {
                const body: []const u8 = switch (err) {
                    error.UnsupportedSessionFormat => "Switching needs the default session format.",
                    error.SessionBusy => "That session is open elsewhere or still running.",
                    else => "Could not open that session.",
                };
                try noticeFmt(app, .@"error", "thread", "{s} ({s})", .{ body, @errorName(err) });
                return;
            };
            try noticeFmt(app, .success, "thread", "Switched to {s}.", .{name});
        }

        fn list(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            current_thread: ?[]const u8,
        ) !void {
            if (registry.threads.items.len == 0 and current_thread == null) {
                try notice(app, .neutral, "thread", "No threads yet. Start one with /thread new NAME TASK.");
                return;
            }
            var out: std.Io.Writer.Allocating = .init(app.alloc);
            defer out.deinit();
            const now = io_mod.milliTimestamp();
            try out.writer.print("{s} main\n", .{if (current_thread == null) ">" else " "});
            for (registry.threads.items) |t| {
                const here = if (current_thread) |c| std.mem.eql(u8, c, t.name) else false;
                try out.writer.print("{s} {s}", .{ if (here) ">" else " ", t.name });
                // Only the root's host runs threads, so state is live there alone.
                if (current_thread == null) {
                    const status = try host.threadStatus(app.alloc, t.agent);
                    defer if (status) |s| s.deinit(app.alloc);
                    try out.writer.print("  {s}", .{if (status) |s| thread_tools.phaseLabel(s.phase) else "not started"});
                    if (status) |s| if (host.feedFor(s.child_id)) |feed| {
                        const last = feed.lastActivityMs();
                        if (last > 0) try out.writer.print("  active {d}s ago", .{@divTrunc(@max(now - last, 0), 1000)});
                    };
                }
                try out.writer.writeByte('\n');
            }
            try out.writer.writeAll("\nMention one in a prompt with @thread:NAME. Follow one with /thread watch NAME.");
            try notice(app, .neutral, "threads", out.written());
        }

        fn create(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *thread_registry.Registry,
            root_id: []const u8,
            home: []const u8,
            name: []const u8,
            task: []const u8,
        ) !void {
            var id_buf: [96]u8 = undefined;
            const outcome = try thread_tools.createThread(
                app.alloc,
                host,
                registry,
                home,
                name,
                task,
                executeOptions(app, root_id, invocationId(&id_buf, "new")),
            );
            switch (outcome) {
                .started => |s| if (s.saved)
                    try noticeFmt(app, .success, "thread", "Started thread {s}.", .{name})
                else
                    try noticeFmt(app, .warning, "thread", "Started {s}, but the thread list was not saved.", .{name}),
                .invalid_name => |err| try notice(app, .@"error", "thread", nameProblem(err)),
                .duplicate => try noticeFmt(app, .@"error", "thread", "A thread named {s} already exists.", .{name}),
                .rejected => |code| try noticeFmt(app, .@"error", "thread", "Could not start {s}: {s}", .{ name, code }),
            }
        }

        fn send(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            root_id: []const u8,
            name: []const u8,
            message: []const u8,
        ) !void {
            const t = registry.find(name) orelse return missing(app, name);
            var id_buf: [96]u8 = undefined;
            const outcome = try host.sendThread(app.alloc, t.agent, message, executeOptions(app, root_id, invocationId(&id_buf, "send")));
            defer outcome.deinit(app.alloc);
            switch (outcome) {
                .started => try noticeFmt(app, .success, "thread", "Sent to {s}; it is working on it.", .{name}),
                .steered => try noticeFmt(app, .success, "thread", "Sent to {s}; it was mid-turn, so the text joins that turn.", .{name}),
                .rejected => |code| try noticeFmt(app, .@"error", "thread", "Could not send to {s}: {s}", .{ name, code }),
            }
        }

        fn watch(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            name: []const u8,
            lines: ?usize,
        ) !void {
            const t = registry.find(name) orelse return missing(app, name);
            const status = (try host.threadStatus(app.alloc, t.agent)) orelse {
                try noticeFmt(app, .@"error", "thread", "Thread {s} has not started.", .{name});
                return;
            };
            defer status.deinit(app.alloc);
            const feed = host.feedFor(status.child_id) orelse {
                try noticeFmt(app, .neutral, name, "{s}. Nothing recorded in this process yet.", .{thread_tools.phaseLabel(status.phase)});
                return;
            };
            if (lines) |count| {
                const body = try renderBody(app.alloc, feed, count, status.phase == .running or status.phase == .awaiting_approval, 0);
                defer app.alloc.free(body);
                try notice(app, .neutral, name, body);
                return;
            }
            // Following: one entry in the transcript that the tick redraws.
            // A view already running ends first, so only one entry is pinned.
            endWatch(app, "Stopped following: another thread is being watched.");
            const running = host.managed.hasRunningChild(status.child_id);
            const now = io_mod.milliTimestamp();
            const body = try renderBody(app.alloc, feed, follow_lines, running, 0);
            defer app.alloc.free(body);
            if (!running) {
                // Nothing is changing, so there is nothing to follow.
                try notice(app, .neutral, name, body);
                return;
            }
            const entry_id = try app.appendReplaceableDomainNotice(.{ .topic = name, .tone = .neutral, .body = body });
            if (status.child_id.len > app.thread_watch.child_id_buf.len) return;
            app.thread_watch = .{ .active = true, .entry_id = entry_id, .host = @intFromPtr(host), .started_ms = now, .last_refresh_ms = now };
            @memcpy(app.thread_watch.child_id_buf[0..status.child_id.len], status.child_id);
            app.thread_watch.child_id_len = status.child_id.len;
            @memcpy(app.thread_watch.name_buf[0..name.len], name);
            app.thread_watch.name_len = name.len;
            app.thread_watch.last_hash = std.hash.Wyhash.hash(0, body);
        }

        /// Redraws the live view from the thread's feed. Called every tick; it
        /// does nothing unless a view is active and the interval has passed.
        pub fn tickWatch(app: *App) void {
            const state = &app.thread_watch;
            if (!state.active) return;
            const now = io_mod.milliTimestamp();
            if (now - state.last_refresh_ms < follow_interval_ms) return;
            state.last_refresh_ms = now;
            const host = SessionRuntime.subagentHost(app);
            const feed = if (host) |h|
                if (@intFromPtr(h) == state.host) h.feedFor(state.childId()) else null
            else
                null;
            const live_feed = feed orelse {
                // The session changed under the view. Release it as history.
                endWatch(app, "Stopped following: the session changed.");
                return;
            };
            const running = host.?.managed.hasRunningChild(state.childId());
            const elapsed_s: u64 = @intCast(@divTrunc(@max(now - state.started_ms, 0), 1000));
            const body = renderBody(app.alloc, live_feed, follow_lines, running, elapsed_s) catch return;
            defer app.alloc.free(body);
            if (!running) {
                // The last view says what the thread ended with and stays in the transcript.
                endWatch(app, body);
                return;
            }
            const hash = std.hash.Wyhash.hash(0, body);
            if (hash == state.last_hash) return;
            state.last_hash = hash;
            const replaced = app.replaceDomainNoticeKeepingPin(state.entry_id, .{ .topic = state.name(), .tone = .neutral, .body = body }) catch false;
            // The entry left the transcript, so there is nothing to redraw.
            if (!replaced) state.active = false;
            app.shell.render_requests.request(.transcript);
        }

        /// Ends the live view with `body` as its last text, which releases the
        /// entry into the transcript as ordinary history.
        fn endWatch(app: *App, body: []const u8) void {
            const state = &app.thread_watch;
            if (!state.active) return;
            state.active = false;
            _ = app.replaceDomainNotice(state.entry_id, .{ .topic = state.name(), .tone = .neutral, .body = body }) catch {};
            app.shell.render_requests.request(.transcript);
        }

        /// Header plus the newest `max` lines of the feed. Caller owns the result.
        fn renderBody(alloc: Allocator, feed: *thread_feed.Feed, max: usize, running: bool, elapsed_s: u64) ![]u8 {
            const tail = try feed.tail(alloc, max);
            defer tail.deinit(alloc);
            var out: std.Io.Writer.Allocating = .init(alloc);
            errdefer out.deinit();
            try out.writer.writeAll(if (running) "running" else "idle");
            if (running and elapsed_s > 0) try out.writer.print(" · {d}s", .{elapsed_s});
            const hidden = tail.total_lines -| @as(u64, @intCast(tail.lines.len));
            if (tail.lines.len == 0) {
                try out.writer.writeAll("\n(no output yet)");
            } else {
                if (hidden > 0) try out.writer.print("\n… {d} earlier {s}", .{ hidden, if (hidden == 1) "line" else "lines" });
                for (tail.lines) |line| try out.writer.print("\n{s}", .{line});
            }
            return out.toOwnedSlice();
        }

        fn stop(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *const thread_registry.Registry,
            name: []const u8,
        ) !void {
            const t = registry.find(name) orelse return missing(app, name);
            const status = (try host.threadStatus(app.alloc, t.agent)) orelse {
                try noticeFmt(app, .neutral, "thread", "Thread {s} is not running.", .{name});
                return;
            };
            defer status.deinit(app.alloc);
            if (status.phase != .running and status.phase != .awaiting_approval) {
                try noticeFmt(app, .neutral, "thread", "Thread {s} is not running.", .{name});
                return;
            }
            host.cancelThread(status.child_id) catch |err| {
                try noticeFmt(app, .@"error", "thread", "Could not stop {s}: {s}", .{ name, @errorName(err) });
                return;
            };
            try noticeFmt(app, .success, "thread", "Stopping {s}.", .{name});
        }

        fn rename(app: *App, registry: *thread_registry.Registry, home: []const u8, old: []const u8, new: []const u8) !void {
            registry.rename(app.alloc, old, new) catch |err| switch (err) {
                error.ThreadNotFound => return missing(app, old),
                error.DuplicateThreadName => {
                    try noticeFmt(app, .@"error", "thread", "A thread named {s} already exists.", .{new});
                    return;
                },
                error.InvalidThreadName, error.ReservedThreadName => {
                    try notice(app, .@"error", "thread", nameProblem(err));
                    return;
                },
                else => return err,
            };
            try thread_registry.save(app.alloc, home, registry);
            try noticeFmt(app, .success, "thread", "Renamed {s} to {s}.", .{ old, new });
        }

        fn remove(
            app: *App,
            host: *subagent_tool_host.Runtime,
            registry: *thread_registry.Registry,
            home: []const u8,
            name: []const u8,
        ) !void {
            const t = registry.find(name) orelse return missing(app, name);
            if (try host.threadStatus(app.alloc, t.agent)) |status| {
                defer status.deinit(app.alloc);
                if (status.phase == .running or status.phase == .awaiting_approval) {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} is running. Stop it first with /thread stop {s}.", .{ name, name });
                    return;
                }
            }
            // The session and child entry go first and the name last, so a
            // crash between them leaves a name that delete can finish.
            const outcome = host.deleteThread(app.alloc, t.agent, t.session_id) catch |err| {
                try noticeFmt(app, .@"error", "thread", "Could not delete {s}: {s}", .{ name, @errorName(err) });
                return;
            };
            switch (outcome) {
                .deleted => {},
                .running => {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} is running. Stop it first with /thread stop {s}.", .{ name, name });
                    return;
                },
                .in_use => {
                    try noticeFmt(app, .@"error", "thread", "Thread {s} is open in another process. Close it there, then delete.", .{name});
                    return;
                },
                .failed => {
                    try noticeFmt(app, .@"error", "thread", "Could not delete the saved session of {s}. Run /thread delete {s} again.", .{ name, name });
                    return;
                },
            }
            try registry.remove(app.alloc, name);
            try thread_registry.save(app.alloc, home, registry);
            try noticeFmt(app, .success, "thread", "Deleted thread {s} and its saved session.", .{name});
        }

        fn missing(app: *App, name: []const u8) !void {
            try noticeFmt(app, .@"error", "thread", "No thread named {s}. List them with /thread list.", .{name});
        }

        fn executeOptions(app: *App, root_id: []const u8, invocation_id: []const u8) subagent_tool_host.ExecuteOptions {
            const settings = app.worker.effectiveAgentTurnSettings();
            return .{
                .caller_id = root_id,
                .invocation_id = invocation_id,
                .parent_permission_mode = app_permission_runtime.Runtime(App).livePermissionSnapshot(app).mode,
                .defaults = .{
                    .provider = provider_runtime.provider(app),
                    .model = provider_runtime.model(app),
                    .effort = settings.effort,
                    .fast_mode = settings.fast_mode,
                    .ultrafast_mode = settings.ultrafast_mode,
                    .conversation_language = app.session.languageSnapshot(),
                },
                .max_result_bytes = settings.max_tool_result_bytes,
                .timestamp_ms = io_mod.milliTimestamp(),
            };
        }

        /// A fresh id per command, so each send is its own operation.
        fn invocationId(buf: []u8, verb: []const u8) []const u8 {
            return std.mem.print(buf, "thread-{s}-{d}", .{ verb, io_mod.nanoTimestamp() }) catch "thread-op";
        }

        fn notice(app: *App, tone: anytype, topic: []const u8, body: []const u8) !void {
            try app.writeDomainNotice(.{ .topic = topic, .tone = tone, .body = body }, true);
        }

        fn noticeFmt(app: *App, tone: anytype, topic: []const u8, comptime fmt: []const u8, args: anytype) !void {
            const body = try app.alloc.print(fmt, args);
            defer app.alloc.free(body);
            try notice(app, tone, topic, body);
        }
    };
}

fn nameProblem(err: anyerror) []const u8 {
    return switch (err) {
        error.ReservedThreadName => "main is the current session and cannot be a thread name.",
        else => "Thread names use lowercase letters, digits, - and _, start with a letter or digit, and stay within 32 characters.",
    };
}

test "thread command parses each verb" {
    try std.testing.expect((try parse("")) == .list);
    try std.testing.expect((try parse("list")) == .list);
    const new = (try parse("new fix-auth fix the login bug")).new;
    try std.testing.expectEqualStrings("fix-auth", new.name);
    try std.testing.expectEqualStrings("fix the login bug", new.task);
    const send = (try parse("send fix-auth  also check logout")).send;
    try std.testing.expectEqualStrings("also check logout", send.message);
    try std.testing.expect((try parse("watch a")).watch.lines == null);
    try std.testing.expectEqual(@as(usize, 5), (try parse("watch a 5")).watch.lines.?);
    try std.testing.expectEqualStrings("a", (try parse("stop a")).stop);
    try std.testing.expectEqualStrings("b", (try parse("rename a b")).rename.new);
    try std.testing.expectEqualStrings("a", (try parse("delete a")).delete);
    try std.testing.expectEqualStrings("a", (try parse("switch a")).@"switch");
}

test "thread command rejects malformed input" {
    for ([_][]const u8{ "new", "new a", "send a", "watch", "watch a 0", "watch a x", "stop", "stop a b", "rename a", "frob", "list x" }) |bad| {
        try std.testing.expectError(error.InvalidThreadCommand, parse(bad));
    }
}
