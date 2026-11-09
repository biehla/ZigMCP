//! Protocol tests: drive the built server as a subprocess over pipes, exactly
//! as a client would (PLAN §10.2, protocol layer).
//!
//! The client writes one request and blocks on the response, so these tests
//! also pin the "flush the response before reading the next request" rule: a
//! server that buffered its output would deadlock here.

const std = @import("std");
const options = @import("server_options");

const io = std.testing.io;

const Harness = struct {
    child: std.process.Child,
    stdin_buffer: [4096]u8,
    stdout_buffer: [256 * 1024]u8,
    stdin_writer: std.Io.File.Writer,
    stdout_reader: std.Io.File.Reader,
    /// The watchdog gives up on a silent server instead of hanging the suite.
    timed_out: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    watchdog: ?std.Thread = null,

    const watchdog_deadline_ms = 30_000;

    fn start() !*Harness {
        const harness = try std.testing.allocator.create(Harness);
        errdefer std.testing.allocator.destroy(harness);

        harness.* = .{
            .child = undefined,
            .stdin_buffer = undefined,
            .stdout_buffer = undefined,
            .stdin_writer = undefined,
            .stdout_reader = undefined,
        };

        harness.child = try std.process.spawn(io, .{
            .argv = &.{ options.server_exe, "--advice-dir", "data/advice" },
            .stdin = .pipe,
            .stdout = .pipe,
            // The server's diagnostics stay visible: a failing protocol test
            // should show why the server misbehaved.
            .stderr = .inherit,
        });

        // Streaming mode: these are pipes, not seekable files — positional I/O
        // on a pipe can silently lose bytes.
        harness.stdin_writer = harness.child.stdin.?.writerStreaming(io, &harness.stdin_buffer);
        harness.stdout_reader = harness.child.stdout.?.readerStreaming(io, &harness.stdout_buffer);

        harness.watchdog = try std.Thread.spawn(.{}, watchdogLoop, .{harness});
        return harness;
    }

    /// A server that stops answering must fail the test, not stall the suite.
    fn watchdogLoop(harness: *Harness) void {
        var waited_ms: u64 = 0;
        while (waited_ms < watchdog_deadline_ms) : (waited_ms += 100) {
            if (harness.finished.load(.acquire)) return;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch return;
        }
        if (harness.finished.load(.acquire)) return;
        harness.timed_out.store(true, .release);
        harness.child.kill(io);
    }

    fn send(self: *Harness, request: []const u8) !void {
        try self.stdin_writer.interface.writeAll(request);
        try self.stdin_writer.interface.writeByte('\n');
        try self.stdin_writer.interface.flush();
    }

    fn receive(self: *Harness) !std.json.Parsed(std.json.Value) {
        const line = (try self.stdout_reader.interface.takeDelimiter('\n')) orelse {
            if (self.timed_out.load(.acquire)) return error.ServerTimeout;
            return error.NoResponse;
        };
        return std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    }

    /// Closes stdin (EOF) and waits for a clean exit.
    fn stop(self: *Harness) !void {
        self.finished.store(true, .release);
        self.child.stdin.?.close(io);
        self.child.stdin = null;
        const term = try self.child.wait(io);
        switch (term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.UnexpectedExit,
        }
    }

    /// Stops the watchdog and releases the harness.
    fn release(self: *Harness) void {
        self.finished.store(true, .release);
        if (self.watchdog) |watchdog| {
            watchdog.join();
            self.watchdog = null;
        }
    }
};

fn metaParams(comptime version: []const u8) []const u8 {
    return "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"" ++ version ++
        "\",\"io.modelcontextprotocol/clientCapabilities\":{}}}";
}

test "server/discover returns the spec-shaped result" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"server/discover\",\"params\":" ++ comptime metaParams("2026-07-28") ++ "}");
    const response = try harness.receive();
    defer response.deinit();

    try std.testing.expectEqualStrings("2.0", response.value.object.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 1), response.value.object.get("id").?.integer);

    const result = response.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
    try std.testing.expect(result.get("supportedVersions").?.array.items.len >= 2);
    try std.testing.expect(result.get("capabilities").?.object.get("tools") != null);

    const server_info = result.get("_meta").?.object.get("io.modelcontextprotocol/serverInfo").?.object;
    try std.testing.expectEqualStrings("zigmcp", server_info.get("name").?.string);

    try std.testing.expect(result.get("ttlMs").?.integer >= 0);
    try std.testing.expectEqualStrings("public", result.get("cacheScope").?.string);
}

test "a legacy request without _meta gets legacy semantics" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{}}");
    const response = try harness.receive();
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    try std.testing.expectEqualStrings("2025-06-18", result.get("protocolVersion").?.string);
    try std.testing.expect(result.get("serverInfo") != null);
    // Legacy responses omit resultType and the cache hints.
    try std.testing.expect(result.get("resultType") == null);
    try std.testing.expect(result.get("ttlMs") == null);
    try std.testing.expect(result.get("cacheScope") == null);
    try std.testing.expect(result.get("_meta") == null);
}

test "an incomplete _meta is invalid params" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\"}}}",
    );
    const response = try harness.receive();
    defer response.deinit();

    const error_object = response.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32602), error_object.get("code").?.integer);
}

test "an unsupported protocol version is rejected with the supported list" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"server/discover\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"1999-01-01\",\"io.modelcontextprotocol/clientCapabilities\":{}}}}",
    );
    const response = try harness.receive();
    defer response.deinit();

    const error_object = response.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32022), error_object.get("code").?.integer);
    const supported = error_object.get("data").?.object.get("supportedVersions").?.array;
    try std.testing.expectEqual(@as(usize, 2), supported.items.len);
    try std.testing.expectEqualStrings("2026-07-28", supported.items[0].string);
}

test "an unparseable line is a parse error" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send("{not json");
    const response = try harness.receive();
    defer response.deinit();

    try std.testing.expectEqual(@as(i64, -32700), response.value.object.get("error").?.object.get("code").?.integer);
}

test "a malformed envelope is an invalid request" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send("{\"jsonrpc\":\"1.0\",\"id\":6,\"method\":\"tools/list\"}");
    const response = try harness.receive();
    defer response.deinit();

    try std.testing.expectEqual(@as(i64, -32600), response.value.object.get("error").?.object.get("code").?.integer);
}

test "an unknown method is a method-not-found error" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"nope/nope\",\"params\":" ++ comptime metaParams("2026-07-28") ++ "}");
    const response = try harness.receive();
    defer response.deinit();

    try std.testing.expectEqual(@as(i64, -32601), response.value.object.get("error").?.object.get("code").?.integer);
}

test "tools/list advertises the tools sorted by name" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/list\",\"params\":" ++ comptime metaParams("2026-07-28") ++ "}");
    const response = try harness.receive();
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    const tools = result.get("tools").?.array;
    try std.testing.expectEqual(@as(usize, 5), tools.items.len);

    var previous: []const u8 = "";
    for (tools.items) |tool| {
        const name = tool.object.get("name").?.string;
        if (previous.len > 0) {
            try std.testing.expect(std.mem.lessThan(u8, previous, name));
        }
        previous = name;
        try std.testing.expect(tool.object.get("inputSchema") != null);
        try std.testing.expect(tool.object.get("outputSchema") != null);
        const annotations = tool.object.get("annotations").?.object;
        try std.testing.expect(annotations.get("readOnlyHint").?.bool);
    }

    try std.testing.expect(result.get("ttlMs") != null);
    try std.testing.expect(result.get("cacheScope") != null);
}

test "an unknown tool is invalid params" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"nope\",\"arguments\":{}}}",
    );
    const response = try harness.receive();
    defer response.deinit();

    try std.testing.expectEqual(@as(i64, -32602), response.value.object.get("error").?.object.get("code").?.integer);
}

test "advice_lookup returns the record with its evidence label" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"advice_lookup\",\"arguments\":{\"concept\":\"P03\"}}}",
    );
    const response = try harness.receive();
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    try std.testing.expect(!result.get("isError").?.bool);
    const structured = result.get("structuredContent").?.object;
    const matches = structured.get("matches").?.array;
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    const record = matches.items[0].object;
    try std.testing.expectEqualStrings("P03", record.get("id").?.string);
    try std.testing.expectEqualStrings("SYNTHESIS", record.get("evidence").?.string);
    try std.testing.expect(record.get("sources").?.array.items.len > 0);
}

test "a missing resource is invalid params with the uri" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"resources/read\",\"params\":{\"uri\":\"advice://nope\"}}",
    );
    const response = try harness.receive();
    defer response.deinit();

    const error_object = response.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32602), error_object.get("code").?.integer);
    try std.testing.expectEqualStrings("advice://nope", error_object.get("data").?.object.get("uri").?.string);
}

test "a prompt is returned with its messages" {
    const harness = try Harness.start();
    defer {
        harness.stop() catch {};
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"prompts/get\",\"params\":{\"name\":\"systems_review\",\"arguments\":{\"design\":\"a queue with many pending requests\"}}}",
    );
    const response = try harness.receive();
    defer response.deinit();

    const result = response.value.object.get("result").?.object;
    const messages = result.get("messages").?.array;
    try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    const text = messages.items[0].object.get("content").?.object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "GUIDANCE") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "checks") != null);
}

test "the server exits cleanly on stdin EOF" {
    const harness = try Harness.start();
    defer {
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"server/discover\",\"params\":" ++ comptime metaParams("2026-07-28") ++ "}");
    const response = try harness.receive();
    response.deinit();

    try harness.stop();
}
