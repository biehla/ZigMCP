//! `std.json.Array` construction and append across the toolchain split
//! (AGENTS.md §11, D9): 0.17.1 makes it a managed list (`.init(gpa)`,
//! `append(value)`); Zig master (0.18.0-dev) makes it the unmanaged
//! `std.ArrayList(Value)` (`.empty`, `append(gpa, value)`). Every JSON array in
//! the server is built through here so one source builds on both.

const std = @import("std");

/// True when `std.json.Array` is the managed list, i.e. it carries `init`.
const managed = @hasDecl(std.json.Array, "init");

/// An empty `std.json.Array` allocated from `gpa`.
pub fn init(gpa: std.mem.Allocator) std.json.Array {
    if (comptime managed) {
        return std.json.Array.init(gpa);
    } else {
        return std.json.Array.empty;
    }
}

/// Appends `value`, allocating from `gpa` on the unmanaged representation.
pub fn append(array: *std.json.Array, gpa: std.mem.Allocator, value: std.json.Value) !void {
    if (comptime managed) {
        try array.append(value);
    } else {
        try array.append(gpa, value);
    }
}
