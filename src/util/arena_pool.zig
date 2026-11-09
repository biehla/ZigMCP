//! Reusable arena for per-request scratch memory.
//!
//! The server allocates its response objects per request, but it must not hand
//! that work to the general purpose allocator on every message. `ArenaPool`
//! owns one arena that is reset (keeping its capacity) between requests, so a
//! steady-state server performs no allocator traffic per request.
//!
//! The arena lives on the heap: in Zig 0.17 `ArenaAllocator.allocator()`
//! returns an allocator that points back at the arena instance, so the arena
//! must not be copied by value.

const std = @import("std");

pub const ArenaPool = struct {
    gpa: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,

    pub fn init(gpa: std.mem.Allocator) !ArenaPool {
        const arena = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(gpa);
        return .{ .gpa = gpa, .arena = arena };
    }

    pub fn deinit(self: *ArenaPool) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    /// Releases all per-request allocations while keeping the arena capacity.
    pub fn reset(self: *ArenaPool) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn allocator(self: *ArenaPool) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn alloc(self: *ArenaPool, comptime T: type, n: usize) ![]T {
        return self.allocator().alloc(T, n);
    }

    pub fn dupe(self: *ArenaPool, bytes: []const u8) ![]u8 {
        return self.allocator().dupe(u8, bytes);
    }
};

test "arena pool reuses capacity across resets" {
    var pool = try ArenaPool.init(std.testing.allocator);
    defer pool.deinit();

    const first = try pool.alloc(u8, 128);
    @memset(first, 0xAA);
    const cap_after_first = pool.arena.queryCapacity();

    pool.reset();

    const second = try pool.alloc(u8, 128);
    try std.testing.expectEqual(cap_after_first, pool.arena.queryCapacity());
    try std.testing.expectEqual(@as(usize, 128), second.len);
}
