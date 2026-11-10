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
    if (std.fs.path.dirname(sub_path)) |parent| {
        dir.createDirPath(io, parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
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

test "a truncated --previous index is not reused" {
    // IDX-3: any single matching record marked the project "already indexed",
    // so a partial previous artifact was republished as if it were complete.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    try writeFixture(tmp.dir, "small.zig", "/// the docs\npub fn ok() void {}\n");

    const hash = "18ac3e7343f016890c510e93f935261169d9e3f565436429830faf0934f4f8e4";
    var previous: std.ArrayList(u8) = .empty;
    defer previous.deinit(std.testing.allocator);
    for ([_][]const u8{ "old.one", "old.two" }, 0..) |symbol, index| {
        const line = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"project\":\"p\",\"commit\":\"c\",\"path\":\"old.zig\",\"line\":{d},\"kind\":\"fn\",\"symbol\":\"{s}\",\"container\":\"\",\"doc\":\"d\",\"doc_hash\":\"{s}\"}}\n",
            .{ index + 1, symbol, hash },
        );
        defer std.testing.allocator.free(line);
        try previous.appendSlice(std.testing.allocator, line);
    }
    try writeFixture(tmp.dir, "previous.jsonl", previous.items);

    const output = try std.fmt.allocPrint(std.testing.allocator, "{s}/index.jsonl", .{root});
    defer std.testing.allocator.free(output);
    const source = try std.fmt.allocPrint(std.testing.allocator, "p=c={s}", .{root});
    defer std.testing.allocator.free(source);
    const previous_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/previous.jsonl", .{root});
    defer std.testing.allocator.free(previous_path);
    const status_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/index.status.json", .{root});
    defer std.testing.allocator.free(status_path);

    // The sidecar says five records; the JSONL holds two — the run was
    // truncated. The project must be re-indexed, not carried over.
    try writeFixture(tmp.dir, "previous.status.json", "{\"projects\":{\"p\":{\"commit\":\"c\",\"records\":5}}}");

    var child = try std.process.spawn(io, .{
        .argv = &.{ options.indexer_exe, "--out", output, "--source", source, "--previous", previous_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try child.wait(io)) {
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
    try std.testing.expect(std.mem.indexOf(u8, produced, "small.ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, produced, "old.one") == null);

    const status = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        status_path,
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer std.testing.allocator.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"skipped\":false") != null);

    // With a sidecar that agrees, the same project is carried over.
    try writeFixture(tmp.dir, "previous.status.json", "{\"projects\":{\"p\":{\"commit\":\"c\",\"records\":2}}}");
    var second = try std.process.spawn(io, .{
        .argv = &.{ options.indexer_exe, "--out", output, "--source", source, "--previous", previous_path },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try second.wait(io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedExit,
    }
    const carried = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        output,
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer std.testing.allocator.free(carried);
    try std.testing.expect(std.mem.indexOf(u8, carried, "old.one") != null);
    try std.testing.expect(std.mem.indexOf(u8, carried, "small.ok") == null);
}

test "a pathologically nested file is degraded instead of overflowing the stack" {
    // IDX-8: `Ast.parse` recurses once per nesting level, so 2 000 nested
    // parens killed a Debug indexer — and with it every project in the run,
    // writing neither records nor a status sidecar.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try std.fmt.allocPrint(std.testing.allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer std.testing.allocator.free(root);

    try writeFixture(tmp.dir, "small.zig", "/// the docs\npub fn ok() void {}\n");

    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(std.testing.allocator);
    try deep.appendSlice(std.testing.allocator, "pub const v = ");
    var level: usize = 0;
    while (level < 2000) : (level += 1) try deep.append(std.testing.allocator, '(');
    try deep.append(std.testing.allocator, '1');
    level = 0;
    while (level < 2000) : (level += 1) try deep.append(std.testing.allocator, ')');
    try deep.appendSlice(std.testing.allocator, ";\n");
    try writeFixture(tmp.dir, "deep.zig", deep.items);

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
    try std.testing.expect(std.mem.indexOf(
        u8,
        status,
        "\"path\":\"deep.zig\",\"reason\":\"nesting exceeds the depth limit\"",
    ) != null);

    // The run still produced the readable file's record.
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
}

test "an --include glob selects the same files as its directory prefix" {
    // IDX-2: `--include 'lib/std/**'` — the form `data/sources.zon` uses — was
    // compared as a literal prefix, so it selected nothing and the project was
    // published as an empty index.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = std.testing.allocator;
    const plain_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/plain.jsonl", .{&tmp.sub_path});
    defer gpa.free(plain_out);
    const glob_out = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/glob.jsonl", .{&tmp.sub_path});
    defer gpa.free(glob_out);

    for ([_][2][]const u8{
        .{ "lib/std", plain_out },
        .{ "lib/std/**", glob_out },
    }) |run| {
        var child = try std.process.spawn(io, .{
            .argv = &.{
                options.indexer_exe,
                "--out",
                run[1],
                "--source",
                "fixture=0000000=tests/fixtures/indexer_src",
                "--include",
                run[0],
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        switch (try child.wait(io)) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.UnexpectedExit,
        }
    }

    const plain = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        plain_out,
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer gpa.free(plain);
    const glob = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        glob_out,
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer gpa.free(glob);

    // A non-empty result first: two empty files would also be byte-equal.
    try std.testing.expect(std.mem.indexOf(u8, plain, "\"lib.std.sample") != null);
    try std.testing.expectEqualStrings(plain, glob);
}

test "an --exclude pattern removes matching files from the index" {
    // CI-4: `data/sources.zon` declares `lib/std/**/testdata/**`, but the
    // indexer ignored exclusions and published the testdata files anyway.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;

    try writeFixture(tmp.dir, "src/a.zig", "/// keep me\npub fn a() void {}\n");
    try writeFixture(tmp.dir, "src/testdata/b.zig", "/// drop me\npub fn b() void {}\n");
    try writeFixture(tmp.dir, "src/foo/testdata/c.zig", "/// drop me too\npub fn c() void {}\n");

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const source = try std.fmt.allocPrint(gpa, "p=c={s}", .{root});
    defer gpa.free(source);

    const Run = struct {
        name: []const u8,
        exclude: []const u8,
        want_b: bool,
        want_c: bool,
    };
    // A bare directory prefix drops only its own subtree; the `**` form also
    // matches a `testdata` directory at any depth, including zero segments
    // (the top-level `src/testdata`). One run per form pins both.
    const runs = [_]Run{
        .{ .name = "prefix", .exclude = "src/testdata", .want_b = false, .want_c = true },
        .{ .name = "glob", .exclude = "src/**/testdata/**", .want_b = false, .want_c = false },
    };
    for (runs) |run| {
        const output = try std.fmt.allocPrint(gpa, "{s}/{s}.jsonl", .{ root, run.name });
        defer gpa.free(output);

        var child = try std.process.spawn(io, .{
            .argv = &.{
                options.indexer_exe,
                "--out",
                output,
                "--source",
                source,
                "--include",
                "src",
                "--exclude",
                run.exclude,
            },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        switch (try child.wait(io)) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.UnexpectedExit,
        }

        const produced = try std.Io.Dir.cwd().readFileAllocOptions(
            io,
            output,
            gpa,
            .limited(16 * 1024 * 1024),
            .of(u8),
            null,
        );
        defer gpa.free(produced);

        // The kept file is always indexed ...
        try std.testing.expect(std.mem.indexOf(u8, produced, "\"src/a.zig\"") != null);
        // ... and each excluded tree is absent exactly when the pattern matches it.
        const got_b = std.mem.indexOf(u8, produced, "\"src/testdata/b.zig\"") != null;
        const got_c = std.mem.indexOf(u8, produced, "\"src/foo/testdata/c.zig\"") != null;
        try std.testing.expectEqual(run.want_b, got_b);
        try std.testing.expectEqual(run.want_c, got_c);
    }
}

test "invalid UTF-8 in a doc comment is replaced, not emitted as a byte array" {
    // IDX-5: the JSON writer falls back to a byte array for invalid UTF-8, so
    // the record's `doc` stops being a string and the loader rejects the whole
    // index. Replace the bad byte with U+FFFD and hash the sanitized text.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;

    try writeFixture(tmp.dir, "bad.zig", "/// bad \xff byte\npub const x = 1;\n");

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const output = try std.fmt.allocPrint(gpa, "{s}/index.jsonl", .{root});
    defer gpa.free(output);
    const source = try std.fmt.allocPrint(gpa, "p=c={s}", .{root});
    defer gpa.free(source);

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

    const produced = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        output,
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer gpa.free(produced);

    try std.testing.expect(std.unicode.utf8ValidateSlice(produced));
    // A string, not the byte array the JSON writer falls back to.
    try std.testing.expect(std.mem.indexOf(u8, produced, "\"doc\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, produced, "\"doc\":[") == null);
    try std.testing.expect(std.mem.indexOf(u8, produced, " bad \u{fffd} byte") != null);

    // The hash the loader will recompute is over the sanitized text.
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(" bad \u{fffd} byte", &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expect(std.mem.indexOf(u8, produced, &hex) != null);
}

test "a nested declaration in an error set degrades the file instead of inventing a member" {
    // IDX-7: error sets are flat by grammar, so a nested declaration is
    // invalid Zig. The parser recovers it (here, as a root declaration) and
    // the file is degraded; the error-set scan never sees the nested token, so
    // no `error` record is invented for it.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;

    try writeFixture(tmp.dir, "bad.zig", "/// Errors.\n" ++
        "pub const E = error{\n" ++
        "    /// A real member.\n" ++
        "    A,\n" ++
        "    /// A nested function the grammar does not allow.\n" ++
        "    fn nested() void {},\n" ++
        "};\n");

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const output = try std.fmt.allocPrint(gpa, "{s}/index.jsonl", .{root});
    defer gpa.free(output);
    const source = try std.fmt.allocPrint(gpa, "p=c={s}", .{root});
    defer gpa.free(source);

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

    const produced = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        output,
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer gpa.free(produced);
    try std.testing.expect(std.mem.indexOf(u8, produced, "\"kind\":\"error\"") == null);

    const status_path = try std.fmt.allocPrint(gpa, "{s}/index.status.json", .{root});
    defer gpa.free(status_path);
    const status = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        status_path,
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer gpa.free(status);
    try std.testing.expect(std.mem.indexOf(u8, status, "\"path\":\"bad.zig\"") != null);
}
