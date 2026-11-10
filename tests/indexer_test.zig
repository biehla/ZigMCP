//! Golden test for the doc indexer (AGENTS.md §9).
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

fn writeFixture(dir: std.Io.Dir, sub_path: []const u8, data: []const u8) !void {
    const file = try dir.createFile(io, sub_path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.interface.flush();
}

test "an oversized file is recorded as degraded instead of aborting the run" {
    // IDX-1: `readFileAlloc` was `try`-ed, so one 64 MiB+ file killed the whole
    // run — no records, no status sidecar, every project lost.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    try writeFixture(tmp.dir, "small.zig", "/// the docs\npub fn ok() void {}\n");
    {
        // One byte over the 64 MiB per-file ceiling.
        const file = try tmp.dir.createFile(io, "big.zig", .{});
        defer file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var chunk: [64 * 1024]u8 = undefined;
        @memset(&chunk, 'x');
        var writer = file.writer(io, &buffer);
        var written: usize = 0;
        while (written < 65 * 1024 * 1024) : (written += chunk.len) {
            try writer.interface.writeAll(&chunk);
        }
        try writer.interface.flush();
    }

    const output = try std.fmt.allocPrint(std.testing.allocator, "{s}/index.jsonl", .{root});
    defer std.testing.allocator.free(output);

    const source = try std.fmt.allocPrint(std.testing.allocator, "p=c={s}", .{root});
    defer std.testing.allocator.free(source);

    var child = try std.process.spawn(io, .{
        .argv = &.{ options.indexer_exe, "--out", output, "--source", source },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try child.wait(io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedExit,
    }

    // The run produced the readable file's record ...
    const produced = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        output,
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer std.testing.allocator.free(produced);
    try std.testing.expect(std.mem.indexOf(u8, produced, "\"symbol\":\"small.ok\"") != null);

    // ... and reported the oversized one instead of dying.
    const status_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/index.status.json", .{root});
    defer std.testing.allocator.free(status_path);
    const status = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        status_path,
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer std.testing.allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"big.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"reason\":\"file exceeds the per-file size limit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"files_degraded\":1") != null);
}
