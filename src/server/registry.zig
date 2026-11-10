//! Capability registry: one source of truth for names, descriptions, schemas
//! and handlers (AGENTS.md D8).
//!
//! Every advertised capability lives in one comptime table. The JSON Schema of
//! a tool is derived from that table, so the advertised surface cannot drift
//! from the implemented one.

const std = @import("std");
const meta = @import("../protocol/meta.zig");
const errors = @import("../protocol/errors.zig");
const json_rpc = @import("../protocol/json_rpc.zig");
const corpus_module = @import("../advice/corpus.zig");
const rules_module = @import("../advice/rules.zig");
const docs_reload = @import("../docs/reload.zig");
const pool_module = @import("../util/arena_pool.zig");
const tools_module = @import("tools.zig");

pub const server_name = "zigmcp";
pub const server_version = "0.1.0";

/// Advice data is stable: long TTL, publicly cacheable.
pub const advice_cache = CacheHint{ .ttl_ms = 3_600_000, .scope = .public };
/// Index-derived data changes when CI republishes: short TTL, private.
pub const index_cache = CacheHint{ .ttl_ms = 60_000, .scope = .private };

pub const CacheScope = enum {
    public,
    private,
};

pub const CacheHint = struct {
    ttl_ms: u64,
    scope: CacheScope,
};

pub const Result = struct {
    value: std.json.Value,
    cache: ?CacheHint = null,
};

pub const Outcome = union(enum) {
    result: Result,
    failure: errors.Error,
};

/// Everything a handler needs.
pub const Context = struct {
    gpa: std.mem.Allocator,
    /// The I/O implementation used for file access (status sidecar).
    io: std.Io,
    /// Per-request scratch arena; reset after every message.
    pool: *pool_module.ArenaPool,
    corpus: *const corpus_module.Corpus,
    matcher: *const rules_module.Matcher,
    docs: *docs_reload.Store,
    /// Path of the index artifact, when one is configured.
    index_path: ?[]const u8,
};

pub const ToolError = error{
    InvalidParams,
    OutOfMemory,
};

pub const ToolOutcome = struct {
    /// Human-readable content of the tool result.
    text: []const u8,
    /// Machine-readable payload; must match the tool's output schema.
    structured: ?std.json.Value = null,
    /// Tool-level failure: the call succeeded, the answer is "no result".
    is_error: bool = false,
};

pub const Kind = enum {
    string,
    integer,
    boolean,
    string_array,
    array,
    object,
    any,
};

pub const Field = struct {
    name: []const u8,
    kind: Kind,
    required: bool = true,
    description: []const u8 = "",
};

pub const Schema = struct {
    fields: []const Field,
};

/// Derives the JSON Schema of a request or response object.
pub fn schemaFrom(gpa: std.mem.Allocator, schema: Schema) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "type", .{ .string = "object" });

    var properties: std.json.ObjectMap = .{};
    var required: std.json.Array = .init(gpa);
    for (schema.fields) |field| {
        var property: std.json.ObjectMap = .{};
        switch (field.kind) {
            .any => {},
            else => try property.put(gpa, "type", .{ .string = switch (field.kind) {
                .string => "string",
                .integer => "integer",
                .boolean => "boolean",
                .string_array, .array => "array",
                .object => "object",
                .any => unreachable,
            } }),
        }
        if (field.kind == .string_array) {
            var items: std.json.ObjectMap = .{};
            try items.put(gpa, "type", .{ .string = "string" });
            try property.put(gpa, "items", .{ .object = items });
        }
        if (field.description.len > 0) {
            try property.put(gpa, "description", .{ .string = field.description });
        }
        try properties.put(gpa, field.name, .{ .object = property });
        if (field.required) try required.append(.{ .string = field.name });
    }
    try object.put(gpa, "properties", .{ .object = properties });
    if (required.items.len > 0) try object.put(gpa, "required", .{ .array = required });
    return .{ .object = object };
}

/// The IEEE-754 exact-integer range (2^53): above it a float cannot represent
/// every integer, so a coerced value would be a guess rather than a reading.
const max_exact_float_integer: f64 = 9_007_199_254_740_992;

/// The integer a JSON number holds when it is spelled as a float but is exact
/// (`20.0`), or `null` when it is fractional, infinite or too large.
///
/// Clients that serialise every number as a float are common, so rejecting
/// `20.0` where `20` is meant is a wire-compatibility bug (PROTO-9).
fn integralInteger(value: std.json.Value) ?i64 {
    if (value != .float) return null;
    const raw = value.float;
    if (!std.math.isFinite(raw)) return null;
    if (raw < -max_exact_float_integer or raw > max_exact_float_integer) return null;
    if (@trunc(raw) != raw) return null;
    return @intFromFloat(raw);
}

fn valueMatchesKind(kind: Kind, value: std.json.Value) bool {
    return switch (kind) {
        .string => value == .string,
        .integer => value == .integer or integralInteger(value) != null,
        .boolean => value == .bool,
        .string_array, .array => value == .array,
        .object => value == .object,
        .any => true,
    };
}

/// Validates request arguments against the schema.
///
/// Unknown members, missing required members and wrongly typed members are all
/// invalid params (`-32602`). An absent `arguments` member (`null` or a missing
/// `?Value`) means "no arguments": it is validated as an empty object, so a
/// schema that requires any field still rejects it (GUIDE-5). Handlers
/// therefore never have to re-check required fields.
pub fn validate(schema: Schema, args: ?std.json.Value) !void {
    const empty: std.json.ObjectMap = .{};
    const object: std.json.ObjectMap = if (args) |value| switch (value) {
        .object => |o| o,
        .null => empty,
        else => return error.InvalidParams,
    } else empty;

    for (schema.fields) |field| {
        const member = object.get(field.name);
        if (member == null) {
            if (field.required) return error.InvalidParams;
            continue;
        }
        if (!valueMatchesKind(field.kind, member.?)) return error.InvalidParams;
    }

    var it = object.iterator();
    while (it.next()) |entry| {
        var known = false;
        for (schema.fields) |field| {
            if (std.mem.eql(u8, field.name, entry.key_ptr.*)) {
                known = true;
                break;
            }
        }
        if (!known) return error.InvalidParams;
    }
}

pub fn getString(args: ?std.json.Value, name: []const u8) ?[]const u8 {
    const value = args orelse return null;
    if (value != .object) return null;
    const member = value.object.get(name) orelse return null;
    if (member != .string) return null;
    return member.string;
}

pub fn getInteger(args: ?std.json.Value, name: []const u8) ?i64 {
    const value = args orelse return null;
    if (value != .object) return null;
    const member = value.object.get(name) orelse return null;
    if (member == .integer) return member.integer;
    return integralInteger(member);
}

pub fn getStringArray(gpa: std.mem.Allocator, args: ?std.json.Value, name: []const u8) !?[]const []const u8 {
    const value = args orelse return null;
    if (value != .object) return null;
    const member = value.object.get(name) orelse return null;
    if (member != .array) return error.InvalidParams;

    var items: std.ArrayList([]const u8) = .empty;
    for (member.array.items) |item| {
        if (item != .string) return error.InvalidParams;
        try items.append(gpa, item.string);
    }
    return try items.toOwnedSlice(gpa);
}

pub const ToolSpec = struct {
    name: []const u8,
    description: []const u8,
    input: Schema,
    output: Schema,
    handler: *const fn (ctx: *Context, args: std.json.Value) ToolError!ToolOutcome,
};

/// The capability table. Sorted by name: `tools/list` is deterministic.
pub const tool_specs = [_]ToolSpec{
    .{
        .name = "advice_lookup",
        .description = "Look up a systems-programming advice record by concept id (P01..P12) or by question.",
        .input = tools_module.advice_lookup_input,
        .output = tools_module.advice_lookup_output,
        .handler = tools_module.adviceLookup,
    },
    .{
        .name = "doc_get",
        .description = "Fetch the full documentation of one symbol from the imported doc index.",
        .input = tools_module.doc_get_input,
        .output = tools_module.doc_get_output,
        .handler = tools_module.docGet,
    },
    .{
        .name = "doc_import_status",
        .description = "Report per-project index freshness, record counts and degraded files.",
        .input = tools_module.doc_import_status_input,
        .output = tools_module.doc_import_status_output,
        .handler = tools_module.docImportStatus,
    },
    .{
        .name = "doc_search",
        .description = "Search the imported doc index by symbol, path or documentation text.",
        .input = tools_module.doc_search_input,
        .output = tools_module.doc_search_output,
        .handler = tools_module.docSearch,
    },
    .{
        .name = "recommend_approach",
        .description = "Apply the conditional decision rules to a set of signals and report the matched rules.",
        .input = tools_module.recommend_approach_input,
        .output = tools_module.recommend_approach_output,
        .handler = tools_module.recommendApproach,
    },
};

pub fn findTool(name: []const u8) ?*const ToolSpec {
    for (&tool_specs) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

test "the tool table is sorted by name" {
    var index: usize = 1;
    while (index < tool_specs.len) : (index += 1) {
        try std.testing.expect(
            std.mem.lessThan(u8, tool_specs[index - 1].name, tool_specs[index].name),
        );
    }
}

test "schemas are derived from the field table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const schema = Schema{ .fields = &.{
        .{ .name = "concept", .kind = .string },
        .{ .name = "limit", .kind = .integer, .required = false },
        .{ .name = "tags", .kind = .string_array, .required = false },
    } };
    const value = try schemaFrom(gpa, schema);

    try std.testing.expectEqualStrings("object", value.object.get("type").?.string);
    const properties = value.object.get("properties").?.object;
    try std.testing.expectEqualStrings("string", properties.get("concept").?.object.get("type").?.string);
    try std.testing.expectEqualStrings(
        "array",
        properties.get("tags").?.object.get("type").?.string,
    );
    const required = value.object.get("required").?.array;
    try std.testing.expectEqual(@as(usize, 1), required.items.len);
    try std.testing.expectEqualStrings("concept", required.items[0].string);
}

test "validation rejects missing, unknown and mistyped members" {
    const schema = Schema{ .fields = &.{
        .{ .name = "concept", .kind = .string },
        .{ .name = "limit", .kind = .integer, .required = false },
    } };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const valid = try std.json.parseFromSlice(std.json.Value, gpa, "{\"concept\":\"P03\"}", .{});
    try validate(schema, valid.value);

    const missing = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    try std.testing.expectError(error.InvalidParams, validate(schema, missing.value));

    const unknown = try std.json.parseFromSlice(std.json.Value, gpa, "{\"concept\":\"P03\",\"x\":1}", .{});
    try std.testing.expectError(error.InvalidParams, validate(schema, unknown.value));

    const mistyped = try std.json.parseFromSlice(std.json.Value, gpa, "{\"concept\":3}", .{});
    try std.testing.expectError(error.InvalidParams, validate(schema, mistyped.value));
}

test "absent arguments still enforce required fields" {
    // GUIDE-5: `tools/call` passes .null when `arguments` is missing, so a
    // required field must still be rejected here — handlers never re-check.
    const required = Schema{ .fields = &.{.{ .name = "query", .kind = .string }} };
    try std.testing.expectError(error.InvalidParams, validate(required, null));
    try std.testing.expectError(error.InvalidParams, validate(required, .{ .null = {} }));

    // The same absent arguments are accepted when nothing is required.
    const optional = Schema{ .fields = &.{.{ .name = "query", .kind = .string, .required = false }} };
    try validate(optional, null);
    try validate(optional, .{ .null = {} });
}

test "a non-object arguments value is rejected" {
    const schema = Schema{ .fields = &.{} };
    try std.testing.expectError(error.InvalidParams, validate(schema, .{ .string = "x" }));
    try std.testing.expectError(error.InvalidParams, validate(schema, .{ .integer = 1 }));
}

test "an integral float satisfies an integer field" {
    // PROTO-9: a client may serialise every number as a float. `20.0` is the
    // integer 20; `20.5` and an out-of-range float are not.
    const schema = Schema{ .fields = &.{.{ .name = "limit", .kind = .integer, .required = false }} };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const integral = try std.json.parseFromSlice(std.json.Value, gpa, "{\"limit\":20.0}", .{});
    try validate(schema, integral.value);
    try std.testing.expectEqual(@as(?i64, 20), getInteger(integral.value, "limit"));

    const fractional = try std.json.parseFromSlice(std.json.Value, gpa, "{\"limit\":20.5}", .{});
    try std.testing.expectError(error.InvalidParams, validate(schema, fractional.value));
    try std.testing.expectEqual(@as(?i64, null), getInteger(fractional.value, "limit"));

    const huge = try std.json.parseFromSlice(std.json.Value, gpa, "{\"limit\":1e300}", .{});
    try std.testing.expectError(error.InvalidParams, validate(schema, huge.value));
}
