//! Line-start table for the doc indexer (AGENTS.md §8, IDX-9).
//!
//! `std.zig.findLineColumn` rescans from byte 0, so calling it once per record
//! made the indexer quadratic in declarations per file: 25 000 documented decls
//! took 29.65 s on a Debug build. Build the table once per file and binary
//! search it instead — O(log lines) per record.

const std = @import("std");

/// Ascending byte offset of every line start; `starts[0]` is always 0.
pub const LineTable = struct {
    starts: []const usize,

    pub fn init(gpa: std.mem.Allocator, source: []const u8) !LineTable {
        var starts: std.ArrayList(usize) = .empty;
        try starts.append(gpa, 0);
        for (source, 0..) |c, i| {
            if (c == '\n') try starts.append(gpa, i + 1);
        }
        return .{ .starts = try starts.toOwnedSlice(gpa) };
    }

    /// 1-based line containing `offset`; an offset at or past the end reports
    /// the last line.
    pub fn lineOf(self: LineTable, offset: usize) u32 {
        var lo: usize = 0;
        var hi: usize = self.starts.len;
        while (lo + 1 < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.starts[mid] <= offset) lo = mid else hi = mid;
        }
        return @intCast(lo + 1);
    }
};

test "lineOf agrees with findLineColumn at every offset" {
    // Mixed endings, blank lines and a last line without a newline.
    const source = "a\nbb\r\nccc\n\nlast";
    var table = try LineTable.init(std.testing.allocator, source);
    defer std.testing.allocator.free(table.starts);

    for (0..source.len) |off| {
        const expected = std.zig.findLineColumn(source, off).line + 1;
        try std.testing.expectEqual(@as(u32, @intCast(expected)), table.lineOf(off));
    }
    // Past the last byte is still the last line.
    try std.testing.expectEqual(table.lineOf(source.len), table.lineOf(source.len - 1));
}
