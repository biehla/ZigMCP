//! Protocol tests: drive the built server as a subprocess over pipes, exactly
//! as a client would (AGENTS.md §9, protocol layer).
//!
//! The client writes one request and blocks on the response, so these tests
//! also pin the "flush the response before reading the next request" rule: a
//! server that buffered its output would deadlock here.

const std = @import("std");
const options = @import("server_options");
const sleep_util = @import("sleep_util");

const io = std.testing.io;

const Harness = struct {
    child: std.process.Child,
    stdin_buffer: [4096]u8,
    stdout_buffer: [256 * 1024]u8,
    stdin_writer: std.Io.File.Writer,
    stdout_reader: std.Io.File.Reader,
    /// The watchdog gives up on a silent server instead of hanging the suite.
    timed_out: std.atomic.Value(bool) = .init(false),
    /// Set while the test waits for the server to exit on stdin EOF.
    awaiting_exit: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    watchdog: ?std.Thread = null,

    const watchdog_deadline_ms = 30_000;
    const exit_deadline_ms = 10_000;

    fn start() !*Harness {
        return startWithIndex("tests/golden/index.jsonl");
    }

    /// Starts the server against an arbitrary `--index` argument.
    fn startWithIndex(index_path: []const u8) !*Harness {
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
            // The golden index is checked in, so the doc tools are exercised
            // against real records on every machine (the generated index is
            // gitignored and may not exist).
            .argv = &.{ options.server_exe, "--advice-dir", "data/advice", "--index", index_path },
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

    /// A server that stops answering — or that ignores stdin EOF — must fail
    /// the test, not stall the suite.
    fn watchdogLoop(harness: *Harness) void {
        var waited_ms: u64 = 0;
        var exit_wait_ms: u64 = 0;
        while (waited_ms < watchdog_deadline_ms) : (waited_ms += 100) {
            if (harness.finished.load(.acquire)) return;
            sleep_util.sleepMilliseconds(io, 100);
            if (harness.awaiting_exit.load(.acquire)) {
                exit_wait_ms += 100;
                if (exit_wait_ms >= exit_deadline_ms) {
                    harness.timed_out.store(true, .release);
                    harness.child.kill(io);
                    return;
                }
            } else {
                exit_wait_ms = 0;
            }
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
    ///
    /// The watchdog stays armed while we wait: a server that ignores EOF is
    /// killed and the test fails instead of hanging the suite.
    fn stop(self: *Harness) !void {
        self.awaiting_exit.store(true, .release);
        self.child.stdin.?.close(io);
        self.child.stdin = null;
        const term = try self.child.wait(io);
        switch (term) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.UnexpectedExit,
        }
    }

    /// Terminates the server without waiting for stdin EOF.
    ///
    /// The per-test teardown uses this: waiting for EOF on every server makes
    /// the suite sensitive to pipe-handle lifetime on Windows. The clean-exit
    /// behaviour is pinned by the dedicated EOF test instead.
    fn kill(self: *Harness) void {
        self.finished.store(true, .release);
        // `Child.kill` terminates the process and reaps it.
        self.child.kill(io);
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

/// The `_meta` object itself.
fn metaObject(comptime version: []const u8) []const u8 {
    return "{\"io.modelcontextprotocol/protocolVersion\":\"" ++ version ++
        "\",\"io.modelcontextprotocol/clientCapabilities\":{}}";
}

/// A whole `params` object that carries nothing but `_meta`.
fn metaParams(comptime version: []const u8) []const u8 {
    return "{\"_meta\":" ++ comptime metaObject(version) ++ "}";
}

test "server/discover returns the spec-shaped result" {
    const harness = try Harness.start();
    defer {
        harness.kill();
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
        harness.kill();
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
        harness.kill();
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
        harness.kill();
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
        harness.kill();
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send("{not json");
    const response = try harness.receive();
    defer response.deinit();

    try std.testing.expectEqual(@as(i64, -32700), response.value.object.get("error").?.object.get("code").?.integer);
}

test "an oversized line is a parse error and the server keeps serving" {
    // SRV-1: a line longer than the 64 KiB reader buffer used to end the
    // server with no reply at all, so the client saw a closed pipe.
    const harness = try Harness.start();
    defer {
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    const oversized = try std.testing.allocator.alloc(u8, 70_000);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, ' ');
    try harness.send(oversized);

    const refusal = try harness.receive();
    defer refusal.deinit();
    const error_object = refusal.value.object.get("error").?.object;
    try std.testing.expectEqual(@as(i64, -32700), error_object.get("code").?.integer);

    // The next message is answered, and EOF still exits cleanly.
    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/list\"}");
    const response = try harness.receive();
    defer response.deinit();
    try std.testing.expect(response.value.object.get("result") != null);

    try harness.stop();
}

test "a malformed envelope is an invalid request" {
    const harness = try Harness.start();
    defer {
        harness.kill();
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
        harness.kill();
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
        harness.kill();
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
        harness.kill();
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
        harness.kill();
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

test "a tool with no match still answers with structuredContent" {
    const harness = try Harness.start();
    defer {
        harness.kill();
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    // PROTO-12: these tools declare an output schema, so "nothing matched" has
    // to be shaped like one — a typed client cannot otherwise tell an empty
    // result from a malformed response.
    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"doc_search\",\"arguments\":{\"query\":\"zzzznotpresent\"}}}",
    );
    const search = try harness.receive();
    defer search.deinit();
    const search_result = search.value.object.get("result").?.object;
    try std.testing.expect(search_result.get("isError").?.bool);
    const search_structured = search_result.get("structuredContent").?.object;
    try std.testing.expectEqual(@as(i64, 0), search_structured.get("count").?.integer);
    try std.testing.expectEqual(@as(usize, 0), search_structured.get("results").?.array.items.len);

    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"doc_get\",\"arguments\":{\"project\":\"zig_std\",\"symbol\":\"no.such.symbol\"}}}",
    );
    const get = try harness.receive();
    defer get.deinit();
    const get_result = get.value.object.get("result").?.object;
    try std.testing.expect(get_result.get("isError").?.bool);
    const get_structured = get_result.get("structuredContent").?.object;
    try std.testing.expect(!get_structured.get("found").?.bool);
    try std.testing.expectEqualStrings("zig_std", get_structured.get("project").?.string);

    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"advice_lookup\",\"arguments\":{\"question\":\"zzzznotpresent\"}}}",
    );
    const advice = try harness.receive();
    defer advice.deinit();
    const advice_structured = advice.value.object.get("result").?.object.get("structuredContent").?.object;
    try std.testing.expectEqual(@as(usize, 0), advice_structured.get("matches").?.array.items.len);
}

test "doc_import_status reports a failed index load" {
    // REL-4: a rejected artifact only produced a stderr line, so a client could
    // not see that the served index was not the one on disk.
    const harness = try Harness.startWithIndex("tests/no-such-index.jsonl");
    defer {
        harness.kill();
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send(
        "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"doc_import_status\",\"arguments\":{}}}",
    );
    const response = try harness.receive();
    defer response.deinit();

    const structured = response.value.object.get("result").?.object.get("structuredContent").?.object;
    try std.testing.expectEqualStrings("reload_failed", structured.get("index_state").?.string);
    try std.testing.expectEqualStrings("FileNotFound", structured.get("index_error").?.string);
    try std.testing.expectEqual(@as(i64, 0), structured.get("index_records").?.integer);
}

test "a missing resource is invalid params with the uri" {
    const harness = try Harness.start();
    defer {
        harness.kill();
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
        harness.kill();
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

test "a scripted client session walks the whole surface" {
    // The end-to-end layer from AGENTS.md §9: discover → list tools → call
    // every tool → read a resource → get a prompt, in one session.
    const harness = try Harness.start();
    defer {
        harness.kill();
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"server/discover\",\"params\":" ++ comptime metaParams("2026-07-28") ++ "}");
    {
        const response = try harness.receive();
        defer response.deinit();
        const result = response.value.object.get("result").?.object;
        try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
        try std.testing.expect(result.get("capabilities").?.object.get("tools") != null);
    }

    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/list\",\"params\":" ++ comptime metaParams("2026-07-28") ++ "}");
    {
        const response = try harness.receive();
        defer response.deinit();
        const tools = response.value.object.get("result").?.object.get("tools").?.array;
        try std.testing.expectEqual(@as(usize, 5), tools.items.len);
    }

    // Every advertised tool must answer with a well-formed tool result. The
    // harness points the server at the checked-in golden index, so the doc
    // tools are exercised against real records.
    const calls = [_]struct { name: []const u8, arguments: []const u8 }{
        .{ .name = "advice_lookup", .arguments = "{\"concept\":\"P01\"}" },
        .{ .name = "recommend_approach", .arguments = "{\"signals\":[\"repeated recomputation over changing inputs\"]}" },
        .{ .name = "doc_search", .arguments = "{\"query\":\"sample\"}" },
        .{ .name = "doc_get", .arguments = "{\"project\":\"fixture\",\"symbol\":\"lib.std.sample.single\"}" },
        .{ .name = "doc_import_status", .arguments = "{}" },
    };

    var id: i64 = 22;
    for (calls) |call| {
        id += 1;
        const request = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s},\"_meta\":{{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{{}}}}}}}}",
            .{ id, call.name, call.arguments },
        );
        defer std.testing.allocator.free(request);

        try harness.send(request);
        const response = try harness.receive();
        defer response.deinit();

        if (response.value.object.get("result") == null) {
            const error_object = response.value.object.get("error").?.object;
            std.debug.print("tool call {s} failed: {s}\n", .{ call.name, error_object.get("message").?.string });
            return error.ToolCallFailed;
        }
        const result = response.value.object.get("result").?.object;
        try std.testing.expect(result.get("content").?.array.items.len > 0);
        // Every tool answers successfully against the checked-in index.
        try std.testing.expect(!result.get("isError").?.bool);
    }

    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"resources/read\",\"params\":{\"uri\":\"advice://overview\",\"_meta\":" ++ comptime metaObject("2026-07-28") ++ "}}");
    {
        const response = try harness.receive();
        defer response.deinit();
        const result = response.value.object.get("result").?.object;
        try std.testing.expect(result.get("contents").?.array.items.len > 0);
    }

    try harness.send("{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"prompts/get\",\"params\":{\"name\":\"approach_selection\",\"arguments\":{\"situation\":\"a hot loop over changing inputs\"},\"_meta\":" ++ comptime metaObject("2026-07-28") ++ "}}");
    {
        const response = try harness.receive();
        defer response.deinit();
        const result = response.value.object.get("result").?.object;
        const messages = result.get("messages").?.array;
        try std.testing.expectEqual(@as(usize, 1), messages.items.len);
    }
}

test "every cacheable method carries the cache hints" {
    // SEP-2549 makes ttlMs + cacheScope mandatory on the six cacheable
    // methods. server/discover and resources/read are asserted by their own
    // tests; this covers the remaining four.
    const harness = try Harness.start();
    defer {
        harness.kill();
        harness.release();
        std.testing.allocator.destroy(harness);
    }

    const methods = [_][]const u8{ "tools/list", "prompts/list", "resources/list", "resources/templates/list" };
    for (methods, 0..) |method, index| {
        const request = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ @as(i64, 40 + @as(i64, @intCast(index))), method, comptime metaParams("2026-07-28") },
        );
        defer std.testing.allocator.free(request);

        try harness.send(request);
        const response = try harness.receive();
        defer response.deinit();

        const result = response.value.object.get("result").?.object;
        try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
        try std.testing.expect(result.get("ttlMs").?.integer >= 0);
        const scope = result.get("cacheScope").?.string;
        try std.testing.expect(std.mem.eql(u8, scope, "public") or std.mem.eql(u8, scope, "private"));
    }
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
