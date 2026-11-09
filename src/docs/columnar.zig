//! Columnar layout for the doc index (PLAN §9, P03).
//!
//! The index is held as parallel arrays over one shared string table instead
//! of per-record heap objects: the common query — "list the symbols of a
//! project" and "scan for a token" — walks contiguous memory, and a reload
//! swaps one pointer instead of mutating live structures.

const std = @import("std");

pub const Kind = enum {
    function,
    variable,
    field,
    container,
    err_set,
    parameter,

    pub fn parse(text: []const u8) ?Kind {
        if (std.mem.eql(u8, text, "fn")) return .function;
        if (std.mem.eql(u8, text, "var")) return .variable;
        if (std.mem.eql(u8, text, "field")) return .field;
        if (std.mem.eql(u8, text, "container")) return .container;
        if (std.mem.eql(u8, text, "error")) return .err_set;
        if (std.mem.eql(u8, text, "param")) return .parameter;
        return null;
    }

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .function => "fn",
            .variable => "var",
            .field => "field",
            .container => "container",
            .err_set => "error",
            .parameter => "param",
        };
    }
};

/// A view into the shared string table.
pub const Span = struct {
    offset: u32,
    len: u32,
};

/// The record shape of the JSONL index (PLAN §6.2).
pub const Record = struct {
    project: []const u8,
    commit: []const u8,
    path: []const u8,
    line: u32,
    kind: Kind,
    symbol: []const u8,
    container: []const u8,
    doc: []const u8,
    doc_hash: []const u8,
};

pub const Columnar = struct {
    strings: []const u8,
    project: []const Span,
    commit: []const Span,
    path: []const Span,
    symbol: []const Span,
    container: []const Span,
    doc: []const Span,
    doc_hash: []const Span,
    kinds: []const Kind,
    lines: []const u32,

    pub fn count(self: *const Columnar) usize {
        return self.kinds.len;
    }

    pub fn slice(self: *const Columnar, spans: []const Span, index: usize) []const u8 {
        const span = spans[index];
        return self.strings[span.offset .. span.offset + span.len];
    }

    pub fn projectAt(self: *const Columnar, index: usize) []const u8 {
        return self.slice(self.project, index);
    }

    pub fn commitAt(self: *const Columnar, index: usize) []const u8 {
        return self.slice(self.commit, index);
    }

    pub fn pathAt(self: *const Columnar, index: usize) []const u8 {
        return self.slice(self.path, index);
    }

    pub fn symbolAt(self: *const Columnar, index: usize) []const u8 {
        return self.slice(self.symbol, index);
    }

    pub fn containerAt(self: *const Columnar, index: usize) []const u8 {
        return self.slice(self.container, index);
    }

    pub fn docAt(self: *const Columnar, index: usize) []const u8 {
        return self.slice(self.doc, index);
    }

    pub fn docHashAt(self: *const Columnar, index: usize) []const u8 {
        return self.slice(self.doc_hash, index);
    }
};

/// Builds a columnar index record by record.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    strings: std.ArrayList(u8) = .empty,
    project: std.ArrayList(Span) = .empty,
    commit: std.ArrayList(Span) = .empty,
    path: std.ArrayList(Span) = .empty,
    symbol: std.ArrayList(Span) = .empty,
    container: std.ArrayList(Span) = .empty,
    doc: std.ArrayList(Span) = .empty,
    doc_hash: std.ArrayList(Span) = .empty,
    kinds: std.ArrayList(Kind) = .empty,
    lines: std.ArrayList(u32) = .empty,

    pub fn init(gpa: std.mem.Allocator) Builder {
        return .{ .gpa = gpa };
    }

    fn addString(self: *Builder, text: []const u8) !Span {
        const offset: u32 = @intCast(self.strings.items.len);
        try self.strings.appendSlice(self.gpa, text);
        return .{ .offset = offset, .len = @intCast(text.len) };
    }

    pub fn append(self: *Builder, record: Record) !void {
        try self.project.append(self.gpa, try self.addString(record.project));
        try self.commit.append(self.gpa, try self.addString(record.commit));
        try self.path.append(self.gpa, try self.addString(record.path));
        try self.symbol.append(self.gpa, try self.addString(record.symbol));
        try self.container.append(self.gpa, try self.addString(record.container));
        try self.doc.append(self.gpa, try self.addString(record.doc));
        try self.doc_hash.append(self.gpa, try self.addString(record.doc_hash));
        try self.kinds.append(self.gpa, record.kind);
        try self.lines.append(self.gpa, record.line);
    }

    pub fn finish(self: *Builder) !Columnar {
        return .{
            .strings = try self.strings.toOwnedSlice(self.gpa),
            .project = try self.project.toOwnedSlice(self.gpa),
            .commit = try self.commit.toOwnedSlice(self.gpa),
            .path = try self.path.toOwnedSlice(self.gpa),
            .symbol = try self.symbol.toOwnedSlice(self.gpa),
            .container = try self.container.toOwnedSlice(self.gpa),
            .doc = try self.doc.toOwnedSlice(self.gpa),
            .doc_hash = try self.doc_hash.toOwnedSlice(self.gpa),
            .kinds = try self.kinds.toOwnedSlice(self.gpa),
            .lines = try self.lines.toOwnedSlice(self.gpa),
        };
    }
};

test "columnar layout keeps every field addressable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var builder = Builder.init(gpa);
    try builder.append(.{
        .project = "zig-std",
        .commit = "abc123",
        .path = "lib/std/mem.zig",
        .line = 812,
        .kind = .function,
        .symbol = "mem.copyForwards",
        .container = "mem",
        .doc = "Copies source into dest.",
        .doc_hash = "deadbeef",
    });
    const columnar = try builder.finish();

    try std.testing.expectEqual(@as(usize, 1), columnar.count());
    try std.testing.expectEqualStrings("zig-std", columnar.projectAt(0));
    try std.testing.expectEqualStrings("mem.copyForwards", columnar.symbolAt(0));
    try std.testing.expectEqualStrings("Copies source into dest.", columnar.docAt(0));
    try std.testing.expectEqual(@as(u32, 812), columnar.lines[0]);
    try std.testing.expectEqual(Kind.function, columnar.kinds[0]);
}

test "kind labels round-trip" {
    try std.testing.expectEqual(Kind.container, Kind.parse("container").?);
    try std.testing.expect(Kind.parse("nope") == null);
    try std.testing.expectEqualStrings("param", Kind.parameter.label());
}
