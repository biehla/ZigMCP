//! Small text helpers shared by the advice matcher and the doc search.

const std = @import("std");

/// Splits text into lowercase alphanumeric tokens of at least three characters.
///
/// Tokens are accumulated in a growable buffer rather than a fixed array: a
/// fixed buffer silently dropped everything past its end, so a 200-character
/// identifier matched as its first 128 (GUIDE-6).
pub fn tokenize(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var tokens: std.ArrayList([]const u8) = .empty;
    var current: std.ArrayList(u8) = .empty;
    defer current.deinit(gpa);

    for (text) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            try current.append(gpa, std.ascii.toLower(c));
            continue;
        }
        if (current.items.len >= 3) {
            try tokens.append(gpa, try gpa.dupe(u8, current.items));
        }
        current.clearRetainingCapacity();
    }
    if (current.items.len >= 3) {
        try tokens.append(gpa, try gpa.dupe(u8, current.items));
    }

    return tokens.toOwnedSlice(gpa);
}

/// Case-insensitive substring test.
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const first = std.ascii.toLower(needle[0]);
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        if (std.ascii.toLower(haystack[index]) != first) continue;
        var offset: usize = 1;
        while (offset < needle.len) : (offset += 1) {
            if (std.ascii.toLower(haystack[index + offset]) != std.ascii.toLower(needle[offset])) break;
        } else {
            return true;
        }
    }
    return false;
}

/// Case-insensitive equality.
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

test "tokenizer drops short tokens and lowercases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize(gpa, "Repeated I/O over Changing Inputs");
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqualStrings("repeated", tokens[0]);
    try std.testing.expectEqualStrings("changing", tokens[2]);
}

test "a token longer than 128 characters is kept whole" {
    // GUIDE-6: the helper used to buffer 128 bytes and drop the remainder
    // without a signal, so a 200-character identifier matched as its first 128.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var buffer: [200]u8 = undefined;
    @memset(&buffer, 'a');

    const tokens = try tokenize(gpa, &buffer);
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(@as(usize, 200), tokens[0].len);
}

test "case-insensitive helpers" {
    try std.testing.expect(containsIgnoreCase("Mem.copyForwards", "copy"));
    try std.testing.expect(!containsIgnoreCase("Mem.copyForwards", "alloc"));
    try std.testing.expect(eqlIgnoreCase("P03", "p03"));
}
