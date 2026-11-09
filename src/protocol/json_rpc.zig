//! JSON-RPC 2.0 envelope parsing for the stdio transport.
//!
//! One message per line, no embedded newlines (PLAN §7.4). A line that is not
//! JSON at all is a parse error (-32700); a JSON document that is not a
//! well-formed JSON-RPC request is an invalid request (-32600).

const std = @import("std");

pub const Error = error{
    ParseError,
    InvalidRequest,
    OutOfMemory,
};

pub const Id = union(enum) {
    number: i64,
    string: []const u8,
    null,
};

pub const Request = struct {
    /// `null` for a notification (no `id` member): the server must not reply.
    id: ?Id,
    method: []const u8,
    params: ?std.json.Value,
};

/// Parses one input line into a JSON value.
///
/// The caller owns the returned value's memory through `gpa`; the server uses a
/// per-request arena, so the value dies with the request.
pub fn parseLine(gpa: std.mem.Allocator, line: []const u8) Error!std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.ParseError,
    };
    return parsed.value;
}

/// Validates the JSON-RPC envelope of an already parsed document.
pub fn parseRequest(value: std.json.Value) Error!Request {
    const obj = switch (value) {
        .object => |o| o,
        else => return error.InvalidRequest,
    };

    const jsonrpc = obj.get("jsonrpc") orelse return error.InvalidRequest;
    if (jsonrpc != .string or !std.mem.eql(u8, jsonrpc.string, "2.0")) {
        return error.InvalidRequest;
    }

    const method = obj.get("method") orelse return error.InvalidRequest;
    if (method != .string) return error.InvalidRequest;

    var id: ?Id = null;
    if (obj.get("id")) |id_value| {
        id = switch (id_value) {
            .integer => |i| Id{ .number = i },
            .string => |s| Id{ .string = s },
            .null => Id.null,
            else => return error.InvalidRequest,
        };
    }

    return .{
        .id = id,
        .method = method.string,
        .params = obj.get("params"),
    };
}

test "parses a well-formed request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try parseLine(gpa,
        \\{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{"_meta":{}}}
    );
    const request = try parseRequest(value);

    try std.testing.expectEqualStrings("server/discover", request.method);
    try std.testing.expectEqual(@as(?Id, Id{ .number = 1 }), request.id);
    try std.testing.expect(request.params != null);
}

test "rejects malformed JSON with a parse error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try std.testing.expectError(error.ParseError, parseLine(gpa, "{not json"));
}

test "rejects a non-object envelope" {
    try std.testing.expectError(error.InvalidRequest, parseRequest(.{ .integer = 7 }));
}

test "rejects an envelope without a 2.0 jsonrpc member" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try parseLine(gpa, "{\"jsonrpc\":\"1.0\",\"id\":1,\"method\":\"tools/list\"}");
    try std.testing.expectError(error.InvalidRequest, parseRequest(value));
}

test "rejects an envelope without a method" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try parseLine(gpa, "{\"jsonrpc\":\"2.0\",\"id\":1}");
    try std.testing.expectError(error.InvalidRequest, parseRequest(value));
}

test "a request without an id is a notification" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try parseLine(gpa, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\"}");
    const request = try parseRequest(value);

    try std.testing.expect(request.id == null);
    try std.testing.expectEqualStrings("notifications/cancelled", request.method);
}

test "an id may be a string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try parseLine(gpa, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"tools/list\"}");
    const request = try parseRequest(value);

    try std.testing.expect(request.id != null);
    try std.testing.expectEqualStrings("abc", request.id.?.string);
}
