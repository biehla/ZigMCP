//! Doc index loader: JSONL artifact -> columnar in-memory index (AGENTS.md §7, D3).
//!
//! The index is a runtime artifact, never embedded in the binary. It is parsed
//! once into flat, arena-owned structures; a republished index is validated
//! fully and then swapped in wholesale, never merged into live structures.

const std = @import("std");
const columnar = @import("columnar.zig");

pub const Columnar = columnar.Columnar;
pub const Kind = columnar.Kind;
pub const Record = columnar.Record;

/// Maximum index size the server will load (candidate ceiling from AGENTS.md §9).
pub const max_index_bytes = 256 * 1024 * 1024;

/// A loaded index together with the arena that owns its strings.
pub const Index = struct {
    gpa: std.mem.Allocator,
    /// Heap-allocated: in Zig 0.17 the arena's allocator points back at the
    /// arena instance, so the arena must not be copied by value.
    arena: *std.heap.ArenaAllocator,
    columnar: Columnar,

    pub fn deinit(self: *Index) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn count(self: *const Index) usize {
        return self.columnar.count();
    }
};

pub const LoadError = error{
    OutOfMemory,
    MalformedRecord,
    /// The artifact is larger than `max_index_bytes`.
    IndexTooLarge,
};

/// Parses a JSONL artifact into a columnar index.
///
/// Every line must be a complete record; a malformed line aborts the load so a
/// partially valid artifact can never become the active index.
pub fn load(parent_gpa: std.mem.Allocator, bytes: []const u8) !Index {
    const arena = try parent_gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(parent_gpa);
    // A rejected artifact must free the pages the builder already allocated:
    // destroying the `ArenaAllocator` struct alone leaks them.
    errdefer {
        arena.deinit();
        parent_gpa.destroy(arena);
    }
    const agpa = arena.allocator();

    var builder = columnar.Builder.init(agpa);

    var line_arena = std.heap.ArenaAllocator.init(parent_gpa);
    defer line_arena.deinit();

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;

        _ = line_arena.reset(.retain_capacity);
        const parsed = std.json.parseFromSlice(std.json.Value, line_arena.allocator(), line, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.MalformedRecord,
        };
        const record = extractRecord(parsed.value) catch return error.MalformedRecord;
        try verifyDocHash(record);
        // Canonical order is part of the artifact contract (AGENTS.md §7): an
        // out-of-order artifact changes `docs://{project}/index`, the tie order
        // in search and which duplicate `doc_get` returns (REL-10).
        if (builder.last()) |previous| {
            if (keyOrder(previous, record) == .gt) return error.MalformedRecord;
        }
        try builder.append(record);
    }

    const built = try builder.finish();
    return .{ .gpa = parent_gpa, .arena = arena, .columnar = built };
}

/// Reads and loads an index artifact from disk.
pub fn loadFile(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Index {
    // Every I/O failure keeps its own name: an operator must be able to tell a
    // missing file from a corrupt one, and a size rejection from a syntax
    // error (REL-8). Only the ceiling is renamed, because `StreamTooLong` does
    // not say which limit was hit.
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(max_index_bytes),
        .of(u8),
        null,
    ) catch |err| return if (err == error.StreamTooLong) error.IndexTooLarge else err;
    defer gpa.free(bytes);
    return load(gpa, bytes);
}

test "property: a mutated JSONL record loads whole or is rejected" {
    // The property layer from AGENTS.md §9: a malformed artifact must never
    // become a partially loaded index, and a truncated UTF-8 sequence in the
    // doc text must never crash the loader.
    var prng = std.Random.DefaultPrng.init(0xc0ffee);
    const random = prng.random();

    const valid =
        \\{"project":"p","commit":"c","path":"a.zig","line":1,"kind":"fn","symbol":"s","doc":"d","doc_hash":"18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4"}
    ;
    // The last byte of the two-byte "ó" is missing.
    const truncated_utf8 =
        "{\"project\":\"p\",\"commit\":\"c\",\"path\":\"a.zig\",\"line\":1,\"kind\":\"fn\",\"symbol\":\"s\",\"doc\":\"d\xC3\",\"doc_hash\":\"h\"}";

    var iteration: usize = 0;
    while (iteration < 1000) : (iteration += 1) {
        var owned = try std.testing.allocator.dupe(u8, valid);
        defer std.testing.allocator.free(owned);
        var bytes = owned;
        var truncated = false;
        var flipped = false;
        switch (random.uintLessThan(u8, 4)) {
            0 => {
                bytes = bytes[0..random.uintLessThan(usize, bytes.len)];
                truncated = true;
            },
            1 => {
                bytes[random.uintLessThan(usize, bytes.len)] = random.int(u8);
                flipped = true;
            },
            2 => {
                const replacement = try std.testing.allocator.dupe(u8, truncated_utf8);
                std.testing.allocator.free(owned);
                owned = replacement;
                bytes = owned;
            },
            else => {},
        }

        if (load(std.testing.allocator, bytes)) |loaded| {
            var index = loaded;
            defer index.deinit();
            // A record that loads is loaded whole: never a fragment of one.
            try std.testing.expect(index.count() <= 1);
            if (truncated) {
                // A truncated object is never a valid record: the loader must
                // reject it rather than keep a half-record.
                try std.testing.expectEqual(@as(usize, 0), index.count());
            } else if (!flipped) {
                try std.testing.expectEqual(@as(usize, 1), index.count());
                try std.testing.expectEqualStrings("p", index.columnar.projectAt(0));
            }
        } else |err| {
            try std.testing.expectEqual(error.MalformedRecord, err);
        }
    }
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.MalformedRecord;
    if (value != .string) return error.MalformedRecord;
    return value.string;
}

fn optionalString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return "";
    if (value != .string) return error.MalformedRecord;
    return value.string;
}

/// The canonical record order of AGENTS.md §7: `(project, symbol)`, ties by
/// `(path, line)`.
fn keyOrder(a: Record, b: Record) std.math.Order {
    switch (std.mem.order(u8, a.project, b.project)) {
        .lt => return .lt,
        .gt => return .gt,
        .eq => {},
    }
    switch (std.mem.order(u8, a.symbol, b.symbol)) {
        .lt => return .lt,
        .gt => return .gt,
        .eq => {},
    }
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return .lt,
        .gt => return .gt,
        .eq => {},
    }
    return std.math.order(a.line, b.line);
}

/// Recomputes the record's `doc_hash`, which must be the lowercase-hex SHA-256
/// of `doc`.
///
/// The field exists for provenance. Accepting any string meant a hand-edited or
/// partially corrupted artifact served changed documentation under a
/// plausible-looking hash — the one thing the field is there to prevent
/// (REL-9).
fn verifyDocHash(record: Record) !void {
    if (record.doc_hash.len != 64) return error.MalformedRecord;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(record.doc, &digest, .{});
    const expected = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, record.doc_hash, &expected)) return error.MalformedRecord;
}

fn extractRecord(value: std.json.Value) !Record {
    const object = switch (value) {
        .object => |o| o,
        else => return error.MalformedRecord,
    };

    const line_value = object.get("line") orelse return error.MalformedRecord;
    if (line_value != .integer) return error.MalformedRecord;
    if (line_value.integer < 0 or line_value.integer > std.math.maxInt(u32)) {
        return error.MalformedRecord;
    }

    const kind_text = try requiredString(object, "kind");
    const kind = Kind.parse(kind_text) orelse return error.MalformedRecord;

    return .{
        .project = try requiredString(object, "project"),
        .commit = try requiredString(object, "commit"),
        .path = try requiredString(object, "path"),
        .line = @intCast(line_value.integer),
        .kind = kind,
        .symbol = try requiredString(object, "symbol"),
        .container = try optionalString(object, "container"),
        .doc = try requiredString(object, "doc"),
        .doc_hash = try requiredString(object, "doc_hash"),
    };
}

test "a JSONL artifact loads into a columnar index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const bytes =
        \\{"project":"zig-std","commit":"abc","path":"lib/std/mem.zig","line":812,"kind":"fn","symbol":"mem.copyForwards","container":"mem","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
        \\{"project":"zig-std","commit":"abc","path":"lib/std/mem.zig","line":900,"kind":"param","symbol":"mem.copyForwards.dest","container":"mem","doc":"The destination.","doc_hash":"07d1be738c49af36bb07dc76657ec5cedec4cd91cc2cfc58db2a5e9b1a3217a4"}
    ;

    var index = try load(gpa, bytes);
    defer index.deinit();

    try std.testing.expectEqual(@as(usize, 2), index.count());
    try std.testing.expectEqualStrings("mem.copyForwards", index.columnar.symbolAt(0));
    try std.testing.expectEqualStrings("The destination.", index.columnar.docAt(1));
    try std.testing.expectEqual(Kind.parameter, index.columnar.kinds[1]);
}

test "a malformed line aborts the load" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const bytes =
        \\{"project":"zig-std","commit":"abc","path":"a.zig","line":1,"kind":"fn","symbol":"a","doc":"d","doc_hash":"18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4"}
        \\not json
    ;

    try std.testing.expectError(error.MalformedRecord, load(gpa, bytes));
}

test "a record whose hash does not match its doc is rejected" {
    // REL-9: `doc_hash` is the provenance of `doc`; it used to be accepted as
    // any string, so a hand-edited artifact served changed documentation under
    // a plausible-looking hash.
    const tampered =
        \\{"project":"p","commit":"c","path":"a.zig","line":1,"kind":"fn","symbol":"s","doc":"changed","doc_hash":"18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4"}
    ;
    try std.testing.expectError(error.MalformedRecord, load(std.testing.allocator, tampered));

    // A hash that is not 64 lowercase hex characters is rejected before it is
    // compared.
    const short =
        \\{"project":"p","commit":"c","path":"a.zig","line":1,"kind":"fn","symbol":"s","doc":"d","doc_hash":"h"}
    ;
    try std.testing.expectError(error.MalformedRecord, load(std.testing.allocator, short));
}

test "an artifact out of canonical order is rejected" {
    // REL-10: the loader accepted any order, so a reordered artifact silently
    // changed `docs://{project}/index`, the tie order in search and which
    // duplicate `doc_get` returned.
    const reversed =
        \\{"project":"p","commit":"c","path":"a.zig","line":2,"kind":"fn","symbol":"b","doc":"d","doc_hash":"18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4"}
        \\{"project":"p","commit":"c","path":"a.zig","line":1,"kind":"fn","symbol":"a","doc":"d","doc_hash":"18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4"}
    ;
    try std.testing.expectError(error.MalformedRecord, load(std.testing.allocator, reversed));

    // The canonical order still loads.
    const ordered =
        \\{"project":"p","commit":"c","path":"a.zig","line":1,"kind":"fn","symbol":"a","doc":"d","doc_hash":"18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4"}
        \\{"project":"p","commit":"c","path":"a.zig","line":2,"kind":"fn","symbol":"b","doc":"d","doc_hash":"18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4"}
    ;
    var index = try load(std.testing.allocator, ordered);
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), index.count());
}

test "a missing index keeps its own error" {
    // REL-8: every I/O failure used to collapse onto `MalformedRecord`, so an
    // operator could not tell a missing file from a corrupt one.
    try std.testing.expectError(
        error.FileNotFound,
        loadFile(std.testing.io, std.testing.allocator, "tests/no-such-index.jsonl"),
    );
}

test "a directory is not reported as a malformed index" {
    if (loadFile(std.testing.io, std.testing.allocator, "tests")) |index| {
        var loaded = index;
        loaded.deinit();
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err != error.MalformedRecord);
    }
}

test "a record with an unknown kind is rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const bytes =
        \\{"project":"zig-std","commit":"abc","path":"a.zig","line":1,"kind":"weird","symbol":"a","doc":"d","doc_hash":"18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4"}
    ;

    try std.testing.expectError(error.MalformedRecord, load(gpa, bytes));
}
