//! ZigMCP entry point: load the corpora, then serve MCP over stdio.
//!
//! stdout carries MCP messages only; diagnostics go to stderr. Every response
//! line is flushed before the next request is read, so a client that blocks on
//! the response is never deadlocked by the buffered writer.

const std = @import("std");
const registry = @import("server/registry.zig");
const meta = @import("protocol/meta.zig");
const errors = @import("protocol/errors.zig");
const json_rpc = @import("protocol/json_rpc.zig");
const transport_module = @import("transport/stdio.zig");
const corpus_module = @import("advice/corpus.zig");
const rules_module = @import("advice/rules.zig");
const docs_index = @import("docs/index.zig");
const docs_reload = @import("docs/reload.zig");
const pool_module = @import("util/arena_pool.zig");
const discover = @import("server/discover.zig");
const tools_module = @import("server/tools.zig");
const resources_module = @import("server/resources.zig");
const prompts_module = @import("server/prompts.zig");

const default_advice_dir = "data/advice";
const default_index_path = "generated/index.jsonl";
const watcher_poll_ms: u64 = 1_000;
/// A remote index is re-fetched on this cadence (≈ the index TTL).
const remote_poll_ms: u64 = 60_000;

const Options = struct {
    advice_dir: []const u8 = default_advice_dir,
    index_path: ?[]const u8 = null,
    help: bool = false,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const options = parseOptions(init) catch |err| {
        // A bad command line is a usage error: one line, the usage block, and
        // exit 2. Returning the error instead printed a bare Zig error name, a
        // Debug stack trace and exit 1, and never offered `--help` (SRV-8).
        logStderr(init.io, "zigmcp: {s}\n", .{switch (err) {
            error.UnknownArgument => "unknown argument",
            error.MissingArgument => "missing value for an option",
            else => @errorName(err),
        }});
        printUsage(init.io) catch {};
        std.process.exit(2);
    };

    if (options.help) {
        try printUsage(init.io);
        return;
    }

    var corpus = corpus_module.load(init.io, gpa, options.advice_dir) catch |err| {
        logStderr(init.io, "zigmcp: cannot load the advice corpus from '{s}' ({s})\n", .{ options.advice_dir, @errorName(err) });
        return err;
    };
    defer corpus.deinit();

    // The matcher's condition tokens live for the whole process: the process
    // arena owns them (no leak at exit).
    var matcher = try rules_module.Matcher.init(init.arena.allocator(), &corpus);

    const initial_index = try gpa.create(docs_index.Index);
    errdefer gpa.destroy(initial_index);
    initial_index.* = docs_index.load(gpa, "") catch |err| {
        logStderr(init.io, "zigmcp: cannot create the doc index ({s})\n", .{@errorName(err)});
        return err;
    };

    var store = docs_reload.Store.init(gpa, initial_index);
    // Cleared when the watcher cannot be stopped in time: the thread may still
    // touch the store, so it is deliberately not freed.
    var store_alive = true;
    defer if (store_alive) store.deinit();

    var index_path: ?[]const u8 = null;
    var index_source: ?docs_reload.Source = null;
    var index_digest: ?docs_reload.Digest = null;
    if (options.index_path) |path| {
        index_path = path;
        const source = docs_reload.Source.fromString(path);
        index_source = source;
        const loaded = gpa.create(docs_index.Index) catch |err| return err;
        if (docs_reload.loadSource(init.io, gpa, source)) |result| {
            loaded.* = result.index;
            index_digest = result.digest;
            store.swap(loaded);
        } else |err| {
            gpa.destroy(loaded);
            // The failure is reported by `doc_import_status`, not only on
            // stderr, so a client can see that the index in use is not the
            // artifact on disk (REL-4).
            store.setStatus(.reload_failed, @errorName(err));
            // The server still serves the advice corpus; the watcher picks the
            // artifact up as soon as it appears.
            logStderr(init.io, "zigmcp: cannot load the doc index '{s}' ({s}); serving without an index\n", .{ path, @errorName(err) });
        }
    }

    var watcher: ?docs_reload.Watcher = null;
    if (index_source) |source| {
        // A remote artifact is re-fetched on a slow cadence: the index TTL is
        // ~60 s, so polling the origin every second would hammer it for no
        // benefit.
        const poll_ms = if (source.isUrl()) remote_poll_ms else watcher_poll_ms;
        watcher = docs_reload.startWatcher(gpa, init.io, &store, source, poll_ms, index_digest) catch |err| blk: {
            logStderr(init.io, "zigmcp: cannot start the index watcher ({s})\n", .{@errorName(err)});
            break :blk null;
        };
    }
    defer if (watcher) |*w| {
        if (w.stop()) {
            logStderr(init.io, "zigmcp: index watcher stopped\n", .{});
        } else {
            // The watcher is parked in a network read. The process is exiting,
            // so the store is intentionally left alive rather than freed under
            // a live thread.
            store_alive = false;
            logStderr(init.io, "zigmcp: index watcher did not stop in time; leaving it to the process exit\n", .{});
        }
    };

    var pool = try pool_module.ArenaPool.init(gpa);
    defer pool.deinit();

    var ctx = registry.Context{
        .gpa = gpa,
        .io = init.io,
        .pool = &pool,
        .corpus = &corpus,
        .matcher = &matcher,
        .docs = &store,
        .index_path = index_path,
    };

    var reader_buffer: [64 * 1024]u8 = undefined;
    var writer_buffer: [64 * 1024]u8 = undefined;
    var transport = transport_module.Transport.init(init.io, &reader_buffer, &writer_buffer);

    serve: while (true) {
        const maybe_line = transport.nextLine() catch |err| {
            if (err != error.StreamTooLong) {
                logStderr(init.io, "zigmcp: stdin read failed ({s})\n", .{@errorName(err)});
                break :serve;
            }
            // The line is larger than any message this server accepts. Answer
            // with a parse error, drop the rest of the line, and keep serving:
            // exiting without a reply left the client with nothing at all
            // (SRV-1). The 64 KiB cap also bounds JSON nesting (SRV-4).
            transport.discardRemainderOfLine() catch |discard_err| {
                logStderr(init.io, "zigmcp: stdin read failed ({s})\n", .{@errorName(discard_err)});
                break :serve;
            };
            pool.reset();
            sendError(&transport, pool.allocator(), null, .{
                .code = .parse_error,
                .message = "Parse error: the line exceeds the 64 KiB reader buffer.",
            }) catch |send_err| {
                logStderr(init.io, "zigmcp: cannot report the oversized line ({s})\n", .{@errorName(send_err)});
                break :serve;
            };
            continue :serve;
        };
        const line = maybe_line orelse break :serve;

        pool.reset();
        handleLine(&ctx, &transport, line) catch |err| {
            logStderr(init.io, "zigmcp: request handling failed ({s})\n", .{@errorName(err)});
        };
    }
}

fn handleLine(ctx: *registry.Context, transport: *transport_module.Transport, line: []const u8) !void {
    const gpa = ctx.pool.allocator();

    const value = json_rpc.parseLine(gpa, line) catch |err| switch (err) {
        error.ParseError => return sendError(transport, gpa, null, .{
            .code = .parse_error,
            .message = "Parse error: the line is not valid JSON.",
        }),
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidRequest => unreachable,
    };

    const request = json_rpc.parseRequest(value) catch |err| switch (err) {
        error.InvalidRequest => return sendError(transport, gpa, null, .{
            .code = .invalid_request,
            .message = "Invalid Request: the envelope is not a JSON-RPC 2.0 request.",
        }),
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseError => unreachable,
    };

    const resolution = meta.resolve(request.params) catch |err| switch (err) {
        error.InvalidParams => return sendError(transport, gpa, request.id, .{
            .code = .invalid_params,
            .message = "Invalid params: params._meta must carry io.modelcontextprotocol/protocolVersion and io.modelcontextprotocol/clientCapabilities.",
        }),
        error.UnsupportedVersion => {
            const versions = try meta.supportedVersionsValue(gpa);
            var data: std.json.ObjectMap = .{};
            try data.put(gpa, "supportedVersions", versions);
            return sendError(transport, gpa, request.id, .{
                .code = .unsupported_protocol_version,
                .message = "Unsupported protocol version.",
                .data = .{ .object = data },
            });
        },
    };

    const outcome = dispatch(ctx, request, resolution) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };

    // A notification (no id) never gets a response.
    if (request.id == null) return;

    switch (outcome) {
        .failure => |failure| return sendError(transport, gpa, request.id, failure),
        .result => |result| {
            const response = try buildResponse(ctx, request.id.?, result, resolution.version);
            try transport.writeValue(response);
        },
    }
}

fn dispatch(
    ctx: *registry.Context,
    request: json_rpc.Request,
    resolution: meta.Resolution,
) !registry.Outcome {
    const method = request.method;

    if (std.mem.eql(u8, method, "server/discover")) {
        return .{ .result = try discover.handle(ctx) };
    }

    if (std.mem.eql(u8, method, "initialize")) {
        if (resolution.version == .legacy) {
            return .{ .result = try discover.initializeLegacy(ctx) };
        }
        return .{ .failure = .{ .code = .method_not_found, .message = "Unknown method: initialize." } };
    }

    if (std.mem.eql(u8, method, "tools/list")) {
        return .{ .result = try tools_module.list(ctx) };
    }

    if (std.mem.eql(u8, method, "tools/call")) {
        const name = registry.getString(request.params, "name") orelse {
            return .{ .failure = .{ .code = .invalid_params, .message = "Invalid params: tools/call requires a tool name." } };
        };
        const spec = registry.findTool(name) orelse {
            return .{ .failure = .{ .code = .invalid_params, .message = "Invalid params: unknown tool." } };
        };

        const arguments: ?std.json.Value = if (request.params != null and request.params.? == .object)
            (request.params.?.object.get("arguments") orelse null)
        else
            null;

        const outcome = spec.handler(ctx, arguments orelse std.json.Value{ .null = {} }) catch |err| switch (err) {
            error.InvalidParams => return .{ .failure = .{ .code = .invalid_params, .message = "Invalid params: the tool arguments do not match the input schema." } },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .result = try tools_module.result(ctx, outcome) };
    }

    if (std.mem.eql(u8, method, "resources/list")) {
        return .{ .result = try resources_module.list(ctx) };
    }

    if (std.mem.eql(u8, method, "resources/templates/list")) {
        return .{ .result = try resources_module.listTemplates(ctx) };
    }

    if (std.mem.eql(u8, method, "resources/read")) {
        const uri = registry.getString(request.params, "uri") orelse {
            return .{ .failure = .{ .code = .invalid_params, .message = "Invalid params: resources/read requires a uri." } };
        };
        const result = resources_module.read(ctx, uri) catch |err| switch (err) {
            error.UnknownResource => {
                var data: std.json.ObjectMap = .{};
                try data.put(ctx.pool.allocator(), "uri", .{ .string = uri });
                return .{ .failure = .{
                    .code = .invalid_params,
                    .message = "Invalid params: unknown resource.",
                    .data = .{ .object = data },
                } };
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .result = result };
    }

    if (std.mem.eql(u8, method, "prompts/list")) {
        return .{ .result = try prompts_module.list(ctx) };
    }

    if (std.mem.eql(u8, method, "prompts/get")) {
        const name = registry.getString(request.params, "name") orelse {
            return .{ .failure = .{ .code = .invalid_params, .message = "Invalid params: prompts/get requires a prompt name." } };
        };
        const arguments: ?std.json.Value = if (request.params != null and request.params.? == .object)
            (request.params.?.object.get("arguments") orelse null)
        else
            null;

        const result = prompts_module.get(ctx, name, arguments) catch |err| switch (err) {
            error.UnknownPrompt => return .{ .failure = .{ .code = .invalid_params, .message = "Invalid params: unknown prompt." } },
            error.InvalidArguments => return .{ .failure = .{ .code = .invalid_params, .message = "Invalid params: the prompt argument is missing." } },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .result = result };
    }

    return .{ .failure = .{ .code = .method_not_found, .message = "Unknown method." } };
}

fn buildResponse(
    ctx: *registry.Context,
    id: json_rpc.Id,
    result: registry.Result,
    version: meta.Version,
) !std.json.Value {
    const gpa = ctx.pool.allocator();

    var payload = result.value.object;

    if (version == .current) {
        try payload.put(gpa, "resultType", .{ .string = "complete" });

        var server_info: std.json.ObjectMap = .{};
        try server_info.put(gpa, "name", .{ .string = registry.server_name });
        try server_info.put(gpa, "version", .{ .string = registry.server_version });

        var meta_object: std.json.ObjectMap = .{};
        try meta_object.put(gpa, "io.modelcontextprotocol/serverInfo", .{ .object = server_info });
        try payload.put(gpa, "_meta", .{ .object = meta_object });

        if (result.cache) |cache| {
            try payload.put(gpa, "ttlMs", .{ .integer = @intCast(cache.ttl_ms) });
            try payload.put(gpa, "cacheScope", .{ .string = switch (cache.scope) {
                .public => "public",
                .private => "private",
            } });
        }
    }

    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "jsonrpc", .{ .string = "2.0" });
    try object.put(gpa, "id", idValue(id));
    try object.put(gpa, "result", .{ .object = payload });
    return .{ .object = object };
}

fn idValue(id: json_rpc.Id) std.json.Value {
    return switch (id) {
        .number => |number| .{ .integer = number },
        .string => |string| .{ .string = string },
        .null => .{ .null = {} },
    };
}

fn sendError(
    transport: *transport_module.Transport,
    gpa: std.mem.Allocator,
    id: ?json_rpc.Id,
    failure: errors.Error,
) !void {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "jsonrpc", .{ .string = "2.0" });
    try object.put(gpa, "id", if (id) |value| idValue(value) else .{ .null = {} });
    try object.put(gpa, "error", try errors.toValue(gpa, failure));
    try transport.writeValue(.{ .object = object });
}

fn parseOptions(init: std.process.Init) !Options {
    var options = Options{};

    // Environment strings live for the whole process ✓.
    if (init.environ_map.get("ZIGMCP_ADVICE_DIR")) |dir| {
        options.advice_dir = dir;
    }
    if (init.environ_map.get("ZIGMCP_INDEX")) |path| {
        options.index_path = path;
    }

    // The arguments are copied into the process arena so they outlive this
    // function without a separate allocation to free.
    const args = try std.process.Args.toSlice(init.minimal.args, init.arena.allocator());

    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            options.help = true;
        } else if (std.mem.eql(u8, argument, "--advice-dir")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.advice_dir = args[index];
        } else if (std.mem.eql(u8, argument, "--index")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            options.index_path = args[index];
        } else if (index == 0) {
            // argv[0] is the program name.
            continue;
        } else {
            return error.UnknownArgument;
        }
    }

    if (options.index_path == null) {
        // Fall back to the conventional artifact location when it exists.
        if (fileExists(init.io, default_index_path)) {
            options.index_path = default_index_path;
        }
    }

    return options;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

fn printUsage(io: std.Io) !void {
    var buffer: [2048]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    try stderr.interface.writeAll(
        \\zigmcp — an MCP server for systems-programming advice and imported Zig docs
        \\
        \\Usage: zigmcp [--index <path-or-url>] [--advice-dir <path>]
        \\
        \\  --index <path>      JSONL doc index to load and watch: a local path or an
        \\                      HTTP(S) URL (default: generated/index.jsonl when it
        \\                      exists; also settable through ZIGMCP_INDEX)
        \\  --advice-dir <path> Advice corpus directory (default: data/advice; also settable
        \\                      through ZIGMCP_ADVICE_DIR)
        \\  --help              Show this message
        \\
    );
    try stderr.interface.flush();
}

fn logStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    stderr.interface.print(fmt, args) catch {};
    stderr.interface.flush() catch {};
}
