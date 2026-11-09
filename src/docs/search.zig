//! Symbol / path / token search over the columnar doc index (PLAN §7.1).
//!
//! The query is matched against the symbol, the path and the doc text; symbol
//! hits outrank path hits, which outrank prose hits. Results are limited and
//! deterministically ordered.

const std = @import("std");
const columnar = @import("columnar.zig");
const text_util = @import("../util/text.zig");

pub const Columnar = columnar.Columnar;

pub const default_limit = 20;
pub const max_limit = 100;

pub const Match = struct {
    record_index: usize,
    score: f64,
};

pub fn clampLimit(limit: ?usize) usize {
    const value = limit orelse return default_limit;
    if (value == 0) return default_limit;
    return @min(value, max_limit);
}

fn scoreRecord(index: *const Columnar, record: usize, query: []const u8, tokens: []const []const u8) f64 {
    var score: f64 = 0;

    const symbol = index.symbolAt(record);
    const path = index.pathAt(record);
    const doc = index.docAt(record);

    if (text_util.eqlIgnoreCase(symbol, query)) {
        score += 100;
    } else if (text_util.containsIgnoreCase(symbol, query)) {
        score += 60;
    } else {
        for (tokens) |token| {
            if (text_util.containsIgnoreCase(symbol, token)) {
                score += 40;
                break;
            }
        }
    }

    if (text_util.containsIgnoreCase(path, query)) {
        score += 25;
    }

    if (text_util.containsIgnoreCase(doc, query)) {
        score += 10;
    } else {
        for (tokens) |token| {
            if (text_util.containsIgnoreCase(doc, token)) {
                score += 5;
                break;
            }
        }
    }

    return score;
}

/// Searches the index, returning at most `limit` matches ordered by score.
pub fn search(
    gpa: std.mem.Allocator,
    index: *const Columnar,
    query: []const u8,
    project: ?[]const u8,
    limit: usize,
) ![]Match {
    var matches: std.ArrayList(Match) = .empty;
    if (query.len == 0) return matches.toOwnedSlice(gpa);

    const tokens = try text_util.tokenize(gpa, query);
    const effective_limit = clampLimit(limit);

    for (0..index.count()) |record| {
        if (project) |wanted| {
            if (!text_util.eqlIgnoreCase(index.projectAt(record), wanted)) continue;
        }
        const score = scoreRecord(index, record, query, tokens);
        if (score <= 0) continue;
        try matches.append(gpa, .{ .record_index = record, .score = score });
    }

    std.mem.sort(Match, matches.items, index, lessThan);

    if (matches.items.len > effective_limit) {
        matches.shrinkRetainingCapacity(effective_limit);
    }
    return matches.toOwnedSlice(gpa);
}

fn lessThan(index: *const Columnar, a: Match, b: Match) bool {
    if (a.score != b.score) return a.score > b.score;
    const symbol_a = index.symbolAt(a.record_index);
    const symbol_b = index.symbolAt(b.record_index);
    const order = std.mem.order(u8, symbol_a, symbol_b);
    if (order != .eq) return order == .lt;
    const path_a = index.pathAt(a.record_index);
    const path_b = index.pathAt(b.record_index);
    const path_order = std.mem.order(u8, path_a, path_b);
    if (path_order != .eq) return path_order == .lt;
    return index.lines[a.record_index] < index.lines[b.record_index];
}

test "property: a pathological query never escapes the limit" {
    // The property layer from PLAN §10.2: pathological queries must neither
    // crash the matcher nor return more than the clamped limit.
    var prng = std.Random.DefaultPrng.init(0xfeed);
    const random = prng.random();

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var builder = columnar.Builder.init(gpa);
    try builder.append(.{
        .project = "p",
        .commit = "c",
        .path = "a.zig",
        .line = 1,
        .kind = .function,
        .symbol = "one",
        .container = "",
        .doc = "The first symbol.",
        .doc_hash = "h1",
    });
    try builder.append(.{
        .project = "p",
        .commit = "c",
        .path = "b.zig",
        .line = 2,
        .kind = .function,
        .symbol = "two",
        .container = "",
        .doc = "The second symbol.",
        .doc_hash = "h2",
    });
    const index = try builder.finish();

    var iteration: usize = 0;
    while (iteration < 500) : (iteration += 1) {
        var owned: ?[]u8 = null;
        defer if (owned) |buffer| gpa.free(buffer);

        const query: []const u8 = switch (random.uintLessThan(u8, 4)) {
            0 => "",
            1 => "symbol",
            2 => "\x00\x01\x02 control",
            else => blk: {
                const length = random.uintLessThan(usize, 4096);
                const buffer = try gpa.alloc(u8, length);
                owned = buffer;
                for (buffer) |*byte| byte.* = random.int(u8);
                break :blk buffer;
            },
        };

        const limit = random.uintLessThan(usize, 1000);
        const matches = try search(gpa, &index, query, null, limit);
        defer gpa.free(matches);
        try std.testing.expect(matches.len <= clampLimit(limit));
    }
}

test "an exact symbol match outranks a prose match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var builder = columnar.Builder.init(gpa);
    try builder.append(.{
        .project = "zig-std",
        .commit = "abc",
        .path = "lib/std/mem.zig",
        .line = 10,
        .kind = .function,
        .symbol = "mem.copyForwards",
        .container = "mem",
        .doc = "Copies source into dest.",
        .doc_hash = "h1",
    });
    try builder.append(.{
        .project = "zig-std",
        .commit = "abc",
        .path = "lib/std/array_list.zig",
        .line = 20,
        .kind = .function,
        .symbol = "ArrayList.append",
        .container = "ArrayList",
        .doc = "See mem.copyForwards for the details.",
        .doc_hash = "h2",
    });
    const index = try builder.finish();

    const matches = try search(gpa, &index, "mem.copyForwards", null, 20);
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqual(@as(usize, 0), matches[0].record_index);
}

test "a project filter narrows the results" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var builder = columnar.Builder.init(gpa);
    try builder.append(.{
        .project = "zig-std",
        .commit = "abc",
        .path = "a.zig",
        .line = 1,
        .kind = .function,
        .symbol = "alpha",
        .container = "",
        .doc = "alpha docs",
        .doc_hash = "h1",
    });
    try builder.append(.{
        .project = "mcp-zig",
        .commit = "def",
        .path = "b.zig",
        .line = 2,
        .kind = .function,
        .symbol = "alpha",
        .container = "",
        .doc = "alpha docs",
        .doc_hash = "h2",
    });
    const index = try builder.finish();

    const matches = try search(gpa, &index, "alpha", "mcp-zig", 20);
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqual(@as(usize, 1), matches[0].record_index);
}

test "the result count is clamped" {
    try std.testing.expectEqual(@as(usize, default_limit), clampLimit(null));
    try std.testing.expectEqual(@as(usize, default_limit), clampLimit(0));
    try std.testing.expectEqual(@as(usize, max_limit), clampLimit(1000));
    try std.testing.expectEqual(@as(usize, 5), clampLimit(5));
}
