//! Per-request `_meta` parsing and protocol-version resolution (PLAN D10).
//!
//! Rules, in order:
//!   * `params._meta` entirely absent  -> legacy request (protocol `2025-06-18`).
//!   * `params._meta` present but incomplete -> `-32602` (invalid params).
//!   * `_meta` present with protocolVersion `2026-07-28` -> current revision.
//!   * `_meta` present with protocolVersion `2025-06-18` -> legacy semantics.
//!   * any other protocol version -> `-32022` with the supported list.

const std = @import("std");

pub const current_version = "2026-07-28";
pub const legacy_version = "2025-06-18";
pub const supported_versions = [_][]const u8{ current_version, legacy_version };

pub const Version = enum {
    current,
    legacy,
};

pub const Resolution = struct {
    version: Version,
    client_capabilities: ?std.json.Value = null,
    client_info: ?std.json.Value = null,
    log_level: ?[]const u8 = null,
};

pub const Error = error{
    InvalidParams,
    UnsupportedVersion,
};

pub fn resolve(params: ?std.json.Value) Error!Resolution {
    const params_value = params orelse return .{ .version = .legacy };

    const params_object = switch (params_value) {
        .object => |o| o,
        else => return error.InvalidParams,
    };

    const meta_value = params_object.get("_meta") orelse return .{ .version = .legacy };

    const meta = switch (meta_value) {
        .object => |o| o,
        else => return error.InvalidParams,
    };

    const version_value = meta.get("io.modelcontextprotocol/protocolVersion") orelse
        return error.InvalidParams;
    if (version_value != .string) return error.InvalidParams;
    const version = version_value.string;

    const capabilities = meta.get("io.modelcontextprotocol/clientCapabilities") orelse
        return error.InvalidParams;
    if (capabilities != .object) return error.InvalidParams;

    const client_info = meta.get("io.modelcontextprotocol/clientInfo");
    if (client_info) |info| {
        if (info != .object) return error.InvalidParams;
    }

    var log_level: ?[]const u8 = null;
    if (meta.get("io.modelcontextprotocol/logLevel")) |level| {
        if (level != .string) return error.InvalidParams;
        log_level = level.string;
    }

    if (std.mem.eql(u8, version, current_version)) {
        return .{
            .version = .current,
            .client_capabilities = capabilities,
            .client_info = client_info,
            .log_level = log_level,
        };
    }

    if (std.mem.eql(u8, version, legacy_version)) {
        return .{
            .version = .legacy,
            .client_capabilities = capabilities,
            .client_info = client_info,
            .log_level = log_level,
        };
    }

    return error.UnsupportedVersion;
}

/// The `data` payload of an unsupported-version error: the supported list.
pub fn supportedVersionsValue(gpa: std.mem.Allocator) !std.json.Value {
    var array: std.json.Array = .init(gpa);
    for (supported_versions) |version| {
        try array.append(.{ .string = version });
    }
    return .{ .array = array };
}

test "a request without params is a legacy request" {
    const resolution = try resolve(null);
    try std.testing.expectEqual(Version.legacy, resolution.version);
}

test "a request whose params carry no _meta is a legacy request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try std.json.parseFromSlice(std.json.Value, gpa, "{\"concept\":\"P03\"}", .{});
    const resolution = try resolve(value.value);
    try std.testing.expectEqual(Version.legacy, resolution.version);
}

test "a complete _meta resolves to the current revision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}}
    , .{});
    const resolution = try resolve(value.value);
    try std.testing.expectEqual(Version.current, resolution.version);
    try std.testing.expect(resolution.client_capabilities != null);
}

test "a _meta without clientCapabilities is invalid params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}
    , .{});
    try std.testing.expectError(error.InvalidParams, resolve(value.value));
}

test "a _meta without protocolVersion is invalid params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"_meta":{"io.modelcontextprotocol/clientCapabilities":{}}}
    , .{});
    try std.testing.expectError(error.InvalidParams, resolve(value.value));
}

test "an unknown protocol version is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"_meta":{"io.modelcontextprotocol/protocolVersion":"1999-01-01","io.modelcontextprotocol/clientCapabilities":{}}}
    , .{});
    try std.testing.expectError(error.UnsupportedVersion, resolve(value.value));
}

test "an explicit legacy version keeps legacy semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"_meta":{"io.modelcontextprotocol/protocolVersion":"2025-06-18","io.modelcontextprotocol/clientCapabilities":{}}}
    , .{});
    const resolution = try resolve(value.value);
    try std.testing.expectEqual(Version.legacy, resolution.version);
}

test "a non-object params member is invalid params" {
    try std.testing.expectError(error.InvalidParams, resolve(.{ .integer = 3 }));
}

test "property: a _meta is accepted only when it is well formed" {
    // The property layer from PLAN §10.2. A deterministic generator stands in
    // for a fuzzer: the invariant is that the resolver never accepts an
    // incomplete or mistyped `_meta`, and never rejects a well-formed one
    // with invalid params.
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var iteration: usize = 0;
    while (iteration < 1000) : (iteration += 1) {
        const has_version = random.boolean();
        const has_capabilities = random.boolean();
        const capabilities_are_object = random.boolean();

        var meta: std.json.ObjectMap = .{};
        if (has_version) {
            const version = switch (random.uintLessThan(u8, 4)) {
                0 => current_version,
                1 => legacy_version,
                2 => "1999-01-01",
                else => "",
            };
            try meta.put(gpa, "io.modelcontextprotocol/protocolVersion", .{ .string = version });
        }
        if (has_capabilities) {
            if (capabilities_are_object) {
                try meta.put(gpa, "io.modelcontextprotocol/clientCapabilities", .{ .object = .{} });
            } else {
                try meta.put(gpa, "io.modelcontextprotocol/clientCapabilities", .{ .string = "not-an-object" });
            }
        }

        var params: std.json.ObjectMap = .{};
        try params.put(gpa, "_meta", .{ .object = meta });

        const outcome = resolve(.{ .object = params });
        const well_formed = has_version and has_capabilities and capabilities_are_object;
        if (well_formed) {
            if (outcome) |resolution| {
                // A well-formed `_meta` resolves to one of the two revisions.
                try std.testing.expect(resolution.version == .current or resolution.version == .legacy);
            } else |err| switch (err) {
                error.UnsupportedVersion => {},
                error.InvalidParams => try std.testing.expect(false),
            }
        } else {
            try std.testing.expectError(error.InvalidParams, outcome);
        }
    }
}

test "supported versions payload lists both revisions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const value = try supportedVersionsValue(gpa);
    try std.testing.expectEqual(@as(usize, 2), value.array.items.len);
    try std.testing.expectEqualStrings("2026-07-28", value.array.items[0].string);
    try std.testing.expectEqualStrings("2025-06-18", value.array.items[1].string);
}
