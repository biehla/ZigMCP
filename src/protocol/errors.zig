//! JSON-RPC / MCP error codes and error-object construction.
//!
//! AGENTS.md §6 fixes the code mapping:
//!   -32700 unparseable line, -32600 malformed envelope, -32601 unknown method,
//!   -32602 invalid params, -32603 internal error, -32022 unsupported version.
//! `-32002` (legacy resource-not-found) MUST NOT be emitted, and the HTTP-only
//! `-32020` / `-32021` are deliberately not wired.

const std = @import("std");

pub const Code = enum(i32) {
    parse_error = -32700,
    invalid_request = -32600,
    method_not_found = -32601,
    invalid_params = -32602,
    internal_error = -32603,
    unsupported_protocol_version = -32022,

    pub fn toInt(self: Code) i32 {
        return @backingInt(self);
    }
};

pub const Error = struct {
    code: Code,
    message: []const u8,
    data: ?std.json.Value = null,
};

/// The error object for a request the server could not serve for lack of
/// memory.
///
/// A dropped request left the client waiting for a response that never came
/// (SRV-3); the request is answered with `-32603` instead.
pub fn outOfMemory() Error {
    return .{
        .code = .internal_error,
        .message = "Internal error: out of memory while handling the request.",
    };
}

/// Builds the `error` member of a JSON-RPC error response.
pub fn toValue(gpa: std.mem.Allocator, err: Error) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(gpa, "code", .{ .integer = err.code.toInt() });
    try obj.put(gpa, "message", .{ .string = err.message });
    if (err.data) |data| try obj.put(gpa, "data", data);
    return .{ .object = obj };
}

test "error object carries code, message and optional data" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try toValue(gpa, .{
        .code = .invalid_params,
        .message = "missing required field",
        .data = .{ .string = "concept" },
    });

    const obj = value.object;
    try std.testing.expectEqual(@as(i64, -32602), obj.get("code").?.integer);
    try std.testing.expectEqualStrings("missing required field", obj.get("message").?.string);
    try std.testing.expectEqualStrings("concept", obj.get("data").?.string);
}

test "an out-of-memory failure is an internal error, not a dropped request" {
    const failure = outOfMemory();
    try std.testing.expectEqual(Code.internal_error, failure.code);
    try std.testing.expectEqual(@as(i32, -32603), failure.code.toInt());
    try std.testing.expect(failure.message.len > 0);
}

test "error object omits data when absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try toValue(gpa, .{ .code = .method_not_found, .message = "unknown method" });
    try std.testing.expect(value.object.get("data") == null);
}
