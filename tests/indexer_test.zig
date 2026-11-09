//! Golden test for the doc indexer (PLAN §10.2).
//!
//! The indexer is run over the checked-in fixture tree and its output must be
//! byte-identical to `tests/golden/index.jsonl`. This pins the doc-attachment
//! rule, the record schema, the sorting and the degrade-don't-skip policy
//! (the fixture tree contains a file with a syntax error and a warning-only
//! file; both must still contribute records).

const std = @import("std");
const options = @import("indexer_options");

const io = std.testing.io;

test "the indexer reproduces the golden index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // The indexer resolves its output path against the current directory; the
    // temporary directory lives under `.zig-cache/tmp/<random>`.
    const output = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/index.jsonl",
        .{&tmp.sub_path},
    );
    defer std.testing.allocator.free(output);

    var child = try std.process.spawn(io, .{
        .argv = &.{
            options.indexer_exe,
            "--out",
            output,
            "--source",
            "fixture=0000000=tests/fixtures/indexer_src",
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    switch (term) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedExit,
    }

    const produced = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        output,
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer std.testing.allocator.free(produced);

    const golden = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        "tests/golden/index.jsonl",
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer std.testing.allocator.free(golden);

    try std.testing.expectEqualStrings(golden, produced);
}

test "the golden index contains the records of the degraded files" {
    const golden = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        "tests/golden/index.jsonl",
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer std.testing.allocator.free(golden);

    // The syntax-error file still contributes its usable records ...
    try std.testing.expect(std.mem.indexOf(u8, golden, "\"lib/std/broken.zig\"") != null);
    // ... and the trailing unattached doc comment is not indexed.
    try std.testing.expect(std.mem.indexOf(u8, golden, "unattached") == null);
}
