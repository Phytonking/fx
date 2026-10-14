//! Live feed of one thread: a bounded ring of terminal-safe text lines that
//! the thread's agent thread appends to and the UI thread tails.
//!
//! The agent thread owns appending; any thread may read. Every byte stored is
//! copied, so callers keep ownership of what they pass in.

const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const worker_runtime = @import("../agent/worker_runtime.zig");

const Allocator = std.mem.Allocator;

pub const default_max_lines: usize = 400;
pub const max_line_bytes: usize = 2048;

pub const Feed = struct {
    alloc: Allocator,
    mutex: std.Io.Mutex = .init,
    lines: std.ArrayList([]u8) = .empty,
    /// Text of a line the producer has not finished with a newline yet.
    partial: std.ArrayList(u8) = .empty,
    /// Sequence number of `lines.items[0]`.
    first_seq: u64 = 0,
    max_lines: usize = default_max_lines,
    last_activity_ms: std.atomic.Value(i64) = .init(0),

    pub fn init(alloc: Allocator) Feed {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Feed) void {
        for (self.lines.items) |line| self.alloc.free(line);
        self.lines.deinit(self.alloc);
        self.partial.deinit(self.alloc);
        self.* = undefined;
    }

    /// Appends streamed text. Complete lines enter the ring; the tail waits
    /// for its newline.
    pub fn appendText(self: *Feed, text: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (text) |byte| {
            if (byte == '\n') {
                self.flushPartialLocked();
                continue;
            }
            if (self.partial.items.len >= max_line_bytes) {
                self.flushPartialLocked();
            }
            self.partial.append(self.alloc, safeByte(byte)) catch return;
        }
        self.touch();
    }

    /// Appends one whole line, finishing any pending partial line first.
    pub fn appendLine(self: *Feed, line: []const u8) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        self.flushPartialLocked();
        self.pushLineLocked(line);
        self.touch();
    }

    /// Records the events that matter to someone watching. Anything else is
    /// ignored; the event stays owned by the caller.
    pub fn appendEvent(self: *Feed, event: worker_runtime.WorkerEvent) void {
        switch (event) {
            .tool_lifecycle => |lifecycle| switch (lifecycle) {
                .authoritative_started => |started| {
                    var buf: [160]u8 = undefined;
                    const line = std.mem.print(&buf, "tool {s}", .{started.tool_name}) catch return;
                    self.appendLine(line);
                },
                .terminal => |terminal| {
                    var buf: [64]u8 = undefined;
                    const line = std.mem.print(&buf, "tool finished: {s}", .{@tagName(terminal.outcome.kind)}) catch return;
                    self.appendLine(line);
                },
                else => {},
            },
            .semantic_notice, .error_text => |notice| {
                var buf: [max_line_bytes]u8 = undefined;
                const line = std.mem.print(&buf, "{s}: {s}", .{ notice.topic, notice.body }) catch return;
                self.appendLine(line);
            },
            else => {},
        }
    }

    pub const Read = struct {
        /// Owned by the caller; free each line and the slice.
        lines: [][]u8,
        /// Pass this as `since` on the next read.
        next_seq: u64,
        /// Lines the caller missed because the ring dropped them.
        dropped: u64,

        pub fn deinit(self: Read, alloc: Allocator) void {
            for (self.lines) |line| alloc.free(line);
            alloc.free(self.lines);
        }
    };

    /// Complete lines with sequence number >= `since`, copied for the caller.
    pub fn readSince(self: *Feed, alloc: Allocator, since: u64) Allocator.Error!Read {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        const end = self.first_seq + self.lines.items.len;
        const start = @max(since, self.first_seq);
        const dropped = start -| since;
        const from: usize = @intCast(@min(start, end) - self.first_seq);
        const out = try alloc.alloc([]u8, self.lines.items.len - from);
        var made: usize = 0;
        errdefer {
            for (out[0..made]) |line| alloc.free(line);
            alloc.free(out);
        }
        for (self.lines.items[from..]) |line| {
            out[made] = try alloc.dupe(u8, line);
            made += 1;
        }
        return .{ .lines = out, .next_seq = end, .dropped = dropped };
    }

    /// Wall-clock milliseconds of the last append, or 0 before the first.
    pub fn lastActivityMs(self: *const Feed) i64 {
        return self.last_activity_ms.load(.monotonic);
    }

    fn touch(self: *Feed) void {
        self.last_activity_ms.store(io_mod.milliTimestamp(), .monotonic);
    }

    fn flushPartialLocked(self: *Feed) void {
        if (self.partial.items.len == 0) return;
        self.pushLineLocked(self.partial.items);
        self.partial.clearRetainingCapacity();
    }

    fn pushLineLocked(self: *Feed, line: []const u8) void {
        const bounded = line[0..@min(line.len, max_line_bytes)];
        const copy = self.alloc.alloc(u8, bounded.len) catch return;
        for (bounded, copy) |byte, *slot| slot.* = safeByte(byte);
        if (self.lines.items.len >= self.max_lines) {
            self.alloc.free(self.lines.orderedRemove(0));
            self.first_seq += 1;
        }
        self.lines.append(self.alloc, copy) catch {
            self.alloc.free(copy);
        };
    }
};

/// Control bytes, including ESC, never reach a terminal through the feed.
fn safeByte(byte: u8) u8 {
    return if (byte < 0x20 and byte != '\t' or byte == 0x7f) '?' else byte;
}

test "feed splits streamed text into lines and keeps the unfinished tail back" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.appendText("hello wor");
    feed.appendText("ld\nsecond");
    const first = try feed.readSince(alloc, 0);
    defer first.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), first.lines.len);
    try std.testing.expectEqualStrings("hello world", first.lines[0]);
    try std.testing.expectEqual(@as(u64, 1), first.next_seq);
    feed.appendText("\n");
    const second = try feed.readSince(alloc, first.next_seq);
    defer second.deinit(alloc);
    try std.testing.expectEqualStrings("second", second.lines[0]);
}

test "feed drops the oldest lines past its bound and reports the gap" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.max_lines = 3;
    for ([_][]const u8{ "a", "b", "c", "d", "e" }) |line| feed.appendLine(line);
    const read = try feed.readSince(alloc, 0);
    defer read.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), read.lines.len);
    try std.testing.expectEqualStrings("c", read.lines[0]);
    try std.testing.expectEqual(@as(u64, 2), read.dropped);
    try std.testing.expectEqual(@as(u64, 5), read.next_seq);
}

test "feed replaces terminal control bytes" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.appendLine("a\x1b[31mred\x07");
    const read = try feed.readSince(alloc, 0);
    defer read.deinit(alloc);
    try std.testing.expectEqualStrings("a?[31mred?", read.lines[0]);
}

test "feed records tool lifecycle and notices from worker events" {
    const alloc = std.testing.allocator;
    var feed = Feed.init(alloc);
    defer feed.deinit();
    feed.appendEvent(.{ .error_text = .{ .topic = "model", .tone = .warning, .body = "slow" } });
    const read = try feed.readSince(alloc, 0);
    defer read.deinit(alloc);
    try std.testing.expectEqualStrings("model: slow", read.lines[0]);
    try std.testing.expect(feed.lastActivityMs() > 0);
}
