//! Client-directed log events (PROTO-4, AGENTS.md §6).
//!
//! `_meta` may carry `io.modelcontextprotocol/logLevel`. It used to be parsed
//! and then dropped: a client that opted into logging never saw a
//! `notifications/message`. Events the server already writes to stderr are
//! queued here instead, and the request loop — the only writer of stdout —
//! turns them into notifications before it answers the next request.
//!
//! The queue is a fixed-size ring of static strings: an event never allocates,
//! so a background thread can push one while the server is serving, and the
//! minimum level is the only state a request changes.

const std = @import("std");

/// The MCP logging levels, least to most severe.
pub const Level = enum(u8) {
    debug,
    info,
    notice,
    warning,
    @"error",
    critical,
    alert,
    emergency,

    pub fn label(self: Level) []const u8 {
        return @tagName(self);
    }

    pub fn severity(self: Level) u8 {
        return switch (self) {
            .debug => 0,
            .info => 1,
            .notice => 2,
            .warning => 3,
            .@"error" => 4,
            .critical => 5,
            .alert => 6,
            .emergency => 7,
        };
    }

    /// The level a client named, or null when the name is not one of the eight.
    pub fn parse(text: []const u8) ?Level {
        const levels = [_]struct { name: []const u8, level: Level }{
            .{ .name = "debug", .level = .debug },
            .{ .name = "info", .level = .info },
            .{ .name = "notice", .level = .notice },
            .{ .name = "warning", .level = .warning },
            .{ .name = "error", .level = .@"error" },
            .{ .name = "critical", .level = .critical },
            .{ .name = "alert", .level = .alert },
            .{ .name = "emergency", .level = .emergency },
        };
        for (levels) |entry| {
            if (std.mem.eql(u8, text, entry.name)) return entry.level;
        }
        return null;
    }
};

pub const Event = struct {
    level: Level,
    /// Static text: an event outlives the call that queued it only until the
    /// next request, and nothing formats into it.
    message: []const u8,
};

/// How many events are held for the next response.
pub const capacity = 16;

pub const Queue = struct {
    lock: std.atomic.Value(bool) = .init(false),
    events: [capacity]Event = undefined,
    len: usize = 0,
    /// The level the client last asked for; null means "do not log".
    minimum: ?Level = null,
    /// Events discarded because the queue was full.
    dropped: usize = 0,

    fn acquire(self: *Queue) void {
        while (self.lock.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn release(self: *Queue) void {
        self.lock.store(false, .release);
    }

    /// Records what the current request asked for.
    pub fn setMinimum(self: *Queue, level: ?Level) void {
        self.acquire();
        defer self.release();
        self.minimum = level;
    }

    /// Queues an event when the client asked for a level at or below it.
    pub fn push(self: *Queue, level: Level, message: []const u8) void {
        self.acquire();
        defer self.release();
        const minimum = self.minimum orelse return;
        if (level.severity() < minimum.severity()) return;
        if (self.len == capacity) {
            self.dropped += 1;
            return;
        }
        self.events[self.len] = .{ .level = level, .message = message };
        self.len += 1;
    }

    /// Moves the queued events into `out`, returning how many were written.
    pub fn drain(self: *Queue, out: *[capacity]Event) usize {
        self.acquire();
        defer self.release();
        const count = self.len;
        for (self.events[0..count], 0..) |event, index| out[index] = event;
        self.len = 0;
        return count;
    }
};

/// Builds the `notifications/message` payload for one event.
///
/// The 2026-07-28 params are `level`, `logger` (optional) and `data` (any).
/// The text goes in `data` as a one-member object so a client can read it
/// without a schema.
pub fn toNotification(gpa: std.mem.Allocator, event: Event) !std.json.Value {
    var data: std.json.ObjectMap = .{};
    try data.put(gpa, "message", .{ .string = event.message });

    var params: std.json.ObjectMap = .{};
    try params.put(gpa, "level", .{ .string = event.level.label() });
    try params.put(gpa, "logger", .{ .string = "zigmcp" });
    try params.put(gpa, "data", .{ .object = data });

    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "jsonrpc", .{ .string = "2.0" });
    try object.put(gpa, "method", .{ .string = "notifications/message" });
    try object.put(gpa, "params", .{ .object = params });
    return .{ .object = object };
}

test "an event is queued only at or above the requested level" {
    var queue: Queue = .{};
    var out: [capacity]Event = undefined;

    // No level requested: nothing is held, so a client that never asked pays
    // nothing and sees nothing.
    queue.push(.warning, "index reload failed");
    try std.testing.expectEqual(@as(usize, 0), queue.drain(&out));

    queue.setMinimum(.warning);
    queue.push(.debug, "quiet");
    queue.push(.warning, "index reload failed");
    queue.push(.@"error", "index unreadable");
    const count = queue.drain(&out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("index reload failed", out[0].message);
    try std.testing.expectEqual(Level.@"error", out[1].level);

    // Draining empties the queue: a notification is emitted once.
    try std.testing.expectEqual(@as(usize, 0), queue.drain(&out));
}

test "the queue is bounded and counts what it dropped" {
    var queue: Queue = .{};
    queue.setMinimum(.debug);
    var index: usize = 0;
    while (index < capacity + 3) : (index += 1) queue.push(.info, "event");

    var out: [capacity]Event = undefined;
    try std.testing.expectEqual(capacity, queue.drain(&out));
    try std.testing.expectEqual(@as(usize, 3), queue.dropped);
}

test "a level name parses exactly, or not at all" {
    try std.testing.expectEqual(Level.warning, Level.parse("warning").?);
    try std.testing.expectEqual(Level.emergency, Level.parse("emergency").?);
    try std.testing.expect(Level.parse("WARNING") == null);
    try std.testing.expect(Level.parse("verbose") == null);
    try std.testing.expect(Level.parse("") == null);
}

test "a notification carries the level, the logger and the event text" {
    // The client sees `params.level` at the top and the text under
    // `params.data`, which is what a typed reader looks for.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try toNotification(gpa, .{ .level = .warning, .message = "index reload failed" });

    try std.testing.expectEqualStrings("2.0", value.object.get("jsonrpc").?.string);
    try std.testing.expectEqualStrings("notifications/message", value.object.get("method").?.string);
    const params = value.object.get("params").?.object;
    try std.testing.expectEqualStrings("warning", params.get("level").?.string);
    try std.testing.expectEqualStrings("zigmcp", params.get("logger").?.string);
    try std.testing.expectEqualStrings(
        "index reload failed",
        params.get("data").?.object.get("message").?.string,
    );
}

test "severity orders the levels and parses the eight names" {
    // PROTO-4: `Level.severity` decides whether an event clears the client's
    // minimum, and `parse` decides whether a `logLevel` is accepted at all.
    try std.testing.expect(Level.debug.severity() < Level.info.severity());
    try std.testing.expect(Level.warning.severity() < Level.@"error".severity());
    try std.testing.expect(Level.@"error".severity() < Level.emergency.severity());

    for ([_][]const u8{ "debug", "info", "notice", "warning", "error", "critical", "alert", "emergency" }) |name| {
        const level = Level.parse(name) orelse return error.MissingLevel;
        try std.testing.expectEqualStrings(name, level.label());
    }
}
