//! The JSON-RPC response envelope (AGENTS.md §2, §6).
//!
//! `main.dispatch` produces a `registry.Result`; this module turns it into the
//! wire object: current-revision results gain `resultType`, the server `_meta`
//! and any cache hint, legacy results gain none of them. It also refuses a
//! result that is not an object instead of taking `.object` unchecked, which
//! would panic the process on the request path (SRV-2).

const std = @import("std");
const registry = @import("../server/registry.zig");
const json_rpc = @import("json_rpc.zig");
const meta = @import("meta.zig");

pub const Error = error{
    OutOfMemory,
    /// The handler broke its contract: a result must be an object, because the
    /// envelope adds members to it (`resultType`, `_meta`, `ttlMs`).
    NonObjectResult,
};

/// Builds the response envelope for one request.
pub fn build(
    gpa: std.mem.Allocator,
    id: json_rpc.Id,
    result: registry.Result,
    version: meta.Version,
) Error!std.json.Value {
    if (result.value != .object) return error.NonObjectResult;

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

/// The `id` member: a JSON-RPC id is a string, a number, or null.
pub fn idValue(id: json_rpc.Id) std.json.Value {
    return switch (id) {
        .number => |number| .{ .integer = number },
        .string => |string| .{ .string = string },
        .null => .{ .null = {} },
    };
}

test "a current-revision envelope carries resultType, serverInfo and the cache hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var payload: std.json.ObjectMap = .{};
    try payload.put(gpa, "tools", .{ .array = json_array(gpa) });

    const value = try build(gpa, .{ .number = 7 }, .{
        .value = .{ .object = payload },
        .cache = registry.advice_cache,
    }, .current);

    try std.testing.expectEqualStrings("2.0", value.object.get("jsonrpc").?.string);
    try std.testing.expectEqual(@as(i64, 7), value.object.get("id").?.integer);
    const result = value.object.get("result").?.object;
    try std.testing.expectEqualStrings("complete", result.get("resultType").?.string);
    try std.testing.expectEqualStrings(
        registry.server_version,
        result.get("_meta").?.object.get("io.modelcontextprotocol/serverInfo").?.object.get("version").?.string,
    );
    try std.testing.expectEqual(@as(i64, 3_600_000), result.get("ttlMs").?.integer);
    try std.testing.expectEqualStrings("public", result.get("cacheScope").?.string);
}

test "a legacy envelope carries none of the current-revision members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var payload: std.json.ObjectMap = .{};
    try payload.put(gpa, "tools", .{ .array = json_array(gpa) });

    const value = try build(gpa, .{ .string = "abc" }, .{
        .value = .{ .object = payload },
        .cache = registry.advice_cache,
    }, .legacy);

    try std.testing.expectEqualStrings("abc", value.object.get("id").?.string);
    const result = value.object.get("result").?.object;
    try std.testing.expect(result.get("resultType") == null);
    try std.testing.expect(result.get("_meta") == null);
    try std.testing.expect(result.get("ttlMs") == null);
}

test "a handler result that is not an object is refused, not unwrapped" {
    // SRV-2: `result.value.object` was taken unchecked, so a handler returning
    // a string panicked the process instead of answering -32603.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try std.testing.expectError(
        error.NonObjectResult,
        build(gpa, .{ .number = 1 }, .{ .value = .{ .string = "not an object" } }, .current),
    );
}

fn json_array(gpa: std.mem.Allocator) std.json.Array {
    return @import("../util/json_array.zig").init(gpa);
}
