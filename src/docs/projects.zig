//! Project-key resolution for tool arguments (AGENTS.md §5, PROTO-14).
//!
//! A tool argument may spell a project key loosely — `zig-std`, `zig_std`,
//! `ZIG_STD` — because that is what a caller types. Resolution is exact first,
//! so two keys that really differ only in case (`Fixture` and `fixture`) are
//! never merged (PROTO-13); a loose match is used only when it names exactly
//! one project in the index.

const std = @import("std");
const columnar = @import("columnar.zig");

/// How many project keys a "known projects" message lists before eliding.
pub const max_listed: usize = 16;

pub const Resolution = union(enum) {
    /// The key as it is stored in the index.
    found: []const u8,
    /// More than one stored key matches the caller's spelling; never merged.
    ambiguous: []const []const u8,
    /// Nothing matches, not even loosely.
    missing: void,
};

/// ASCII-lowercase, with `_` folded to `-`; no other mapping, so `zig.std` is
/// not a spelling of `zig_std`.
pub fn normalize(gpa: std.mem.Allocator, key: []const u8) ![]const u8 {
    const folded = try gpa.alloc(u8, key.len);
    for (key, 0..) |byte, index| folded[index] = foldByte(byte);
    return folded;
}

fn foldByte(byte: u8) u8 {
    return switch (byte) {
        'A'...'Z' => std.ascii.toLower(byte),
        '_' => '-',
        else => byte,
    };
}

fn eqlFolded(stored: []const u8, folded: []const u8) bool {
    if (stored.len != folded.len) return false;
    for (stored, folded) |stored_byte, folded_byte| {
        if (foldByte(stored_byte) != folded_byte) return false;
    }
    return true;
}

fn contains(keys: []const []const u8, key: []const u8) bool {
    for (keys) |existing| {
        if (std.mem.eql(u8, existing, key)) return true;
    }
    return false;
}

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return std.mem.order(u8, left, right) == .lt;
}

/// Resolves a caller-supplied project key against the loaded index. Exact
/// spelling wins even when a looser one would also match.
pub fn resolve(
    gpa: std.mem.Allocator,
    index: *const columnar.Columnar,
    wanted: []const u8,
) !Resolution {
    for (0..index.count()) |record| {
        const key = index.projectAt(record);
        if (std.mem.eql(u8, key, wanted)) return .{ .found = key };
    }

    const folded = try normalize(gpa, wanted);
    const matches = try distinctMatches(gpa, index, folded, max_listed * 4);
    return switch (matches.len) {
        0 => .missing,
        1 => .{ .found = matches[0] },
        else => .{ .ambiguous = matches },
    };
}

/// The distinct project keys in the index, ascending, at most `limit` of them.
pub fn known(
    gpa: std.mem.Allocator,
    index: *const columnar.Columnar,
    limit: usize,
) ![]const []const u8 {
    var keys: std.ArrayList([]const u8) = .empty;
    defer keys.deinit(gpa);
    for (0..index.count()) |record| {
        const key = index.projectAt(record);
        if (contains(keys.items, key)) continue;
        try keys.append(gpa, key);
    }
    std.mem.sort([]const u8, keys.items, {}, lessThan);
    const length = @min(keys.items.len, limit);
    return gpa.dupe([]const u8, keys.items[0..length]);
}

fn distinctMatches(
    gpa: std.mem.Allocator,
    index: *const columnar.Columnar,
    folded: []const u8,
    limit: usize,
) ![]const []const u8 {
    var matches: std.ArrayList([]const u8) = .empty;
    defer matches.deinit(gpa);
    for (0..index.count()) |record| {
        const key = index.projectAt(record);
        if (!eqlFolded(key, folded)) continue;
        if (contains(matches.items, key)) continue;
        try matches.append(gpa, key);
        if (matches.items.len == limit) break;
    }
    std.mem.sort([]const u8, matches.items, {}, lessThan);
    return gpa.dupe([]const u8, matches.items);
}

// Tests below are pulled into the suite by src/root.zig.

fn indexFromProjects(gpa: std.mem.Allocator, names: []const []const u8) !columnar.Columnar {
    var builder = columnar.Builder.init(gpa);
    for (names, 0..) |name, position| {
        try builder.append(.{
            .project = name,
            .commit = "commit",
            .path = "a.zig",
            .line = @intCast(position + 1),
            .kind = .function,
            .symbol = "s",
            .container = "",
            .doc = "d",
            .doc_hash = "hash",
        });
    }
    return builder.finish();
}

test "normalize folds case and underscores only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try std.testing.expectEqualStrings("zig-std", try normalize(gpa, "Zig_Std"));
    try std.testing.expectEqualStrings("zig-std", try normalize(gpa, "zig-std"));
    try std.testing.expectEqualStrings("zig.std", try normalize(gpa, "zig.std"));
}

test "a separator spelling resolves to the single stored key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const index = try indexFromProjects(gpa, &.{"zig_std"});
    const resolution = try resolve(gpa, &index, "zig-std");
    try std.testing.expectEqualStrings("zig_std", resolution.found);

    const upper = try resolve(gpa, &index, "ZIG_STD");
    try std.testing.expectEqualStrings("zig_std", upper.found);
}

test "an exact key wins over a looser spelling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const index = try indexFromProjects(gpa, &.{ "Fixture", "fixture" });
    try std.testing.expectEqualStrings("fixture", (try resolve(gpa, &index, "fixture")).found);
    try std.testing.expectEqualStrings("Fixture", (try resolve(gpa, &index, "Fixture")).found);
}

test "two keys matching one spelling stay separate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const index = try indexFromProjects(gpa, &.{ "Fixture", "fixture" });
    const resolution = try resolve(gpa, &index, "FIXTURE");
    try std.testing.expectEqual(@as(usize, 2), resolution.ambiguous.len);
    try std.testing.expectEqualStrings("Fixture", resolution.ambiguous[0]);
    try std.testing.expectEqualStrings("fixture", resolution.ambiguous[1]);
}

test "an unknown key is missing, not empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const index = try indexFromProjects(gpa, &.{ "zig_std", "mcp_zig" });
    try std.testing.expect((try resolve(gpa, &index, "nope")) == .missing);
}

test "known lists distinct keys ascending and stops at the limit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var names: [20][]const u8 = undefined;
    var text: [20][3]u8 = undefined;
    for (&names, 0..) |*name, position| {
        text[position] = .{ 'p', '0' + @as(u8, @intCast(position / 10)), '0' + @as(u8, @intCast(position % 10)) };
        name.* = &text[position];
    }
    const index = try indexFromProjects(gpa, &names);

    const keys = try known(gpa, &index, max_listed);
    try std.testing.expectEqual(max_listed, keys.len);
    try std.testing.expectEqualStrings("p00", keys[0]);
    try std.testing.expectEqualStrings("p15", keys[max_listed - 1]);
    try std.testing.expectEqual(@as(usize, 20), (try known(gpa, &index, 64)).len);
}
