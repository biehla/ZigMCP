//! Golden test for the doc indexer (AGENTS.md §9).
//!
//! The indexer is run over the checked-in fixture tree and its output must be
//! byte-identical to `tests/golden/index.jsonl`. This pins the doc-attachment
//! rule, the record schema, the sorting and the degrade-don't-skip policy
//! (the fixture tree contains a file with a syntax error and a warning-only
//! file; both must still contribute records).

const std = @import("std");
const options = @import("indexer_options");
const docs_index = @import("docs_index");
const sleep_util = @import("sleep_util");

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

test "the golden index carries the plain-comment fallback" {
    const golden = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        "tests/golden/index.jsonl",
        std.testing.allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer std.testing.allocator.free(golden);

    // One record per line, so the record a symbol names is the line holding it.
    const lineWith = struct {
        fn get(haystack: []const u8, needle: []const u8) ?[]const u8 {
            var lines = std.mem.splitScalar(u8, haystack, '\n');
            while (lines.next()) |line| {
                if (std.mem.indexOf(u8, line, needle) != null) return line;
            }
            return null;
        }
    }.get;

    // A declaration with no `///` run is documented by its `//` run ...
    for ([_][2][]const u8{
        .{ "\"symbol\":\"lib.std.comments.plain\"", " Plain line comment for plain." },
        .{ "\"symbol\":\"lib.std.comments.twoLines\"", " First fallback line." },
        .{ "\"symbol\":\"lib.std.comments.twoLines\"", " Second fallback line." },
        .{ "\"symbol\":\"lib.std.comments.withParams.name\"", " The fallback parameter doc." },
        .{ "\"symbol\":\"lib.std.comments.Holder.inner\"", " The fallback field doc." },
        .{ "\"symbol\":\"lib.std.comments.PlainErrors.Fallback\"", " The fallback error doc." },
        // ... and a `///` run still wins where both are present.
        .{ "\"symbol\":\"lib.std.comments.documented\"", " Doc comment for documented." },
        .{ "\"symbol\":\"lib.std.comments.withParams.size\"", " The doc parameter doc." },
        .{ "\"symbol\":\"lib.std.comments.PlainErrors.Documented\"", " The doc error doc." },
    }) |want| {
        const line = lineWith(golden, want[0]) orelse return error.MissingRecord;
        try std.testing.expect(std.mem.indexOf(u8, line, want[1]) != null);
    }

    // Absent: the shadowed comment, a run separated by a blank line, a trailing
    // comment after code, a bare `//` run, and a declaration with no comment.
    for ([_][]const u8{
        "Shadowed plain comment",
        "Separated from its declaration",
        "not documentation for afterTrailing",
        "\"symbol\":\"lib.std.comments.bare\"",
        "\"symbol\":\"lib.std.comments.separated\"",
        "\"symbol\":\"lib.std.comments.afterTrailing\"",
        "\"symbol\":\"lib.std.comments.noDocsAtAll\"",
    }) |absent| {
        try std.testing.expect(std.mem.indexOf(u8, golden, absent) == null);
    }
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

/// The member `"declarations":N` from a status sidecar, as text, or null.
fn declarationsMember(status: []const u8) ?[]const u8 {
    const marker = "\"declarations\":";
    const start = (std.mem.indexOf(u8, status, marker) orelse return null) + marker.len;
    var end = start;
    while (end < status.len and std.ascii.isDigit(status[end])) end += 1;
    if (end == start) return null;
    return status[start..end];
}

test "an incremental run keeps the declaration count it did not walk" {
    // IDX-10: `--previous` marks a project skipped and carries its records over,
    // so a fresh counter published `declarations: 0` beside a full record count
    // — an impossible yield in the sidecar CI republishes.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const first = try std.fmt.allocPrint(gpa, "{s}/first.jsonl", .{root});
    defer gpa.free(first);
    const second = try std.fmt.allocPrint(gpa, "{s}/second.jsonl", .{root});
    defer gpa.free(second);

    var whole = try std.process.spawn(io, .{
        .argv = &.{ options.indexer_exe, "--out", first, "--source", "fixture=0000000=tests/fixtures/indexer_src" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try whole.wait(io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedExit,
    }

    var incremental = try std.process.spawn(io, .{
        .argv = &.{
            options.indexer_exe,
            "--out",
            second,
            "--source",
            "fixture=0000000=tests/fixtures/indexer_src",
            "--previous",
            first,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try incremental.wait(io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedExit,
    }

    const first_status_path = try std.fmt.allocPrint(gpa, "{s}/first.status.json", .{root});
    defer gpa.free(first_status_path);
    const first_status = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        first_status_path,
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer gpa.free(first_status);

    const second_status_path = try std.fmt.allocPrint(gpa, "{s}/second.status.json", .{root});
    defer gpa.free(second_status_path);
    const second_status = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        second_status_path,
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer gpa.free(second_status);

    // The walked run knows the count; the carried-over run reports that same
    // number, not a zero.
    const carried = declarationsMember(first_status) orelse return error.MissingDeclarations;
    try std.testing.expect(!std.mem.eql(u8, carried, "0"));
    const expected = try std.fmt.allocPrint(gpa, "\"declarations\":{s}", .{carried});
    defer gpa.free(expected);
    try std.testing.expect(std.mem.indexOf(u8, second_status, "\"skipped\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_status, expected) != null);
}

test "a carried-over project with no known site count omits the member" {
    // A sidecar from before the field existed has no count to carry. Reporting
    // zero would claim the documentation rule filled nothing (IDX-10).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = std.testing.allocator;

    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);

    try writeFixture(
        tmp.dir,
        "prev/index.jsonl",
        "{\"project\":\"p\",\"commit\":\"c\",\"path\":\"a.zig\",\"line\":1,\"kind\":\"fn\",\"symbol\":\"a\",\"container\":\"\",\"doc\":\"d\",\"doc_hash\":\"h\"}\n",
    );
    try writeFixture(
        tmp.dir,
        "prev/index.status.json",
        "{\"projects\":{\"p\":{\"commit\":\"c\",\"records\":1,\"files_total\":1,\"files_degraded\":0,\"degraded\":[]}}}",
    );

    const previous = try std.fmt.allocPrint(gpa, "{s}/prev/index.jsonl", .{root});
    defer gpa.free(previous);
    const output = try std.fmt.allocPrint(gpa, "{s}/out.jsonl", .{root});
    defer gpa.free(output);

    var child = try std.process.spawn(io, .{
        .argv = &.{
            options.indexer_exe,
            "--out",
            output,
            "--source",
            "p=c=tests/fixtures/indexer_src",
            "--previous",
            previous,
        },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    switch (try child.wait(io)) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.UnexpectedExit,
    }

    const status_path = try std.fmt.allocPrint(gpa, "{s}/out.status.json", .{root});
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

    try std.testing.expect(std.mem.indexOf(u8, status, "\"skipped\":true") != null);
    try std.testing.expect(declarationsMember(status) == null);
}

test "the golden sidecar counts at least as many sites as records" {
    // IDX-10: `records` counts emitted records, `declarations` every site that
    // can carry one, so the second can never be the smaller number. A record
    // kind that is emitted without counting its site would break the ratio's
    // meaning silently; this is where it shows.
    const gpa = std.testing.allocator;
    const status = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        "tests/golden/index.status.json",
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    );
    defer gpa.free(status);

    const record_count = try countMember(status, "records");
    const site_count = try countMember(status, "declarations");
    try std.testing.expect(record_count > 0);
    try std.testing.expect(site_count >= record_count);
}

/// The integer that follows `"<key>":` in a status sidecar.
fn countMember(status: []const u8, key: []const u8) !usize {
    var marker_buf: [64]u8 = undefined;
    const marker = try std.fmt.bufPrint(&marker_buf, "\"{s}\":", .{key});
    const pos = std.mem.indexOf(u8, status, marker) orelse return error.MissingMember;
    var end = pos + marker.len;
    const start = end;
    while (end < status.len and std.ascii.isDigit(status[end])) end += 1;
    if (end == start) return error.MissingMember;
    return std.fmt.parseInt(usize, status[start..end], 10);
}

// ---------------------------------------------------------------------------
// Watch mode (`indexer --watch`, AGENTS.md §8). Each test spawns the built
// indexer as a live watcher over a temporary tree and bounds every wait with
// a deadline plus kill-on-teardown — AGENTS.md §9's bounded-waits rule: a watcher that
// fails to publish must fail the test, not park the suite.
// ---------------------------------------------------------------------------

const watch_deadline_ms: i128 = 20_000;

fn spawnWatch(root: []const u8, out: []const u8, sources: []const u8, extra: []const []const u8) !std.process.Child {
    const gpa = std.testing.allocator;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    try argv.append(gpa, options.indexer_exe);
    try argv.appendSlice(gpa, &.{ "--watch", "--root", root, "--out", out, "--sources", sources, "--poll-ms", "100" });
    try argv.appendSlice(gpa, extra);
    // `Child` does not retain `argv`: the command line is consumed by `spawn`.
    return std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn terminate(child: *std.process.Child) void {
    // `Child.kill` terminates the process and reaps it (see the protocol
    // harness); a following `wait` would assert on the nulled id.
    child.kill(io);
}

fn readOr(path: []const u8) ?[]const u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(io, path, std.testing.allocator, .limited(16 * 1024 * 1024), .of(u8), null) catch null;
}

/// Polls `path` until every needle in `present` appears and no needle in
/// `absent` does. A missing file is "not yet", never a pass: the artifact
/// appears with its first publish.
fn waitArtifact(path: []const u8, present: []const []const u8, absent: []const []const u8) !void {
    const gpa = std.testing.allocator;
    const start = std.Io.Clock.now(.awake, io).nanoseconds;
    while (true) {
        if (readOr(path)) |bytes| {
            defer gpa.free(bytes);
            var ok = true;
            for (present) |needle| {
                if (std.mem.indexOf(u8, bytes, needle) == null) {
                    ok = false;
                    break;
                }
            }
            if (ok) {
                for (absent) |needle| {
                    if (std.mem.indexOf(u8, bytes, needle) != null) {
                        ok = false;
                        break;
                    }
                }
            }
            if (ok) return;
        }
        if (std.Io.Clock.now(.awake, io).nanoseconds - start > watch_deadline_ms * std.time.ns_per_ms) {
            return error.WatchDeadline;
        }
        sleep_util.sleepMilliseconds(io, 100);
    }
}

test "watch mode publishes a live edit the server's loader accepts, then a rewrite" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const out = try std.fmt.allocPrint(gpa, "{s}/tg/index.jsonl", .{root});
    defer gpa.free(out);
    // A missing registry file is the documented warn-and-discover-only path.
    const sources = try std.fmt.allocPrint(gpa, "{s}/absent.zon", .{root});
    defer gpa.free(sources);

    try writeFixture(tmp.dir, "proj/a.zig", "/// doc v1\npub fn one() void {}\n");
    var child = try spawnWatch(root, out, sources, &.{});
    defer terminate(&child);

    try waitArtifact(out, &.{ "\"project\":\"proj\"", "\"commit\":\"live\"", "doc v1" }, &.{});

    // The artifact must satisfy the consumer contract: `doc_hash` re-verified
    // and canonical order enforced by the very loader the server swaps in.
    if (readOr(out)) |bytes| {
        defer gpa.free(bytes);
        var index = try docs_index.load(gpa, bytes);
        index.deinit();
    } else {
        return error.MissingArtifact;
    }

    try writeFixture(tmp.dir, "proj/a.zig", "/// doc v2\npub fn one() void {}\n");
    try waitArtifact(out, &.{"doc v2"}, &.{"doc v1"});
}

test "watch mode keeps .git and testdata out of the artifact" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const out = try std.fmt.allocPrint(gpa, "{s}/tg/index.jsonl", .{root});
    defer gpa.free(out);
    const sources = try std.fmt.allocPrint(gpa, "{s}/absent.zon", .{root});
    defer gpa.free(sources);

    try writeFixture(tmp.dir, "proj/keep.zig", "/// keep record\npub fn keep() void {}\n");
    try writeFixture(tmp.dir, "proj/.git/hook.zig", "/// git secret\npub fn g() void {}\n");
    try writeFixture(tmp.dir, "proj/testdata/deep/y.zig", "/// testdata secret\npub fn t() void {}\n");

    var child = try spawnWatch(root, out, sources, &.{});
    defer terminate(&child);

    try waitArtifact(out, &.{"keep record"}, &.{ "git secret", "testdata secret", ".git", "testdata" });
}

test "watch mode adopts a new library directory and drops it when it vanishes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const out = try std.fmt.allocPrint(gpa, "{s}/tg/index.jsonl", .{root});
    defer gpa.free(out);
    const status = try std.fmt.allocPrint(gpa, "{s}/tg/index.status.json", .{root});
    defer gpa.free(status);
    const sources = try std.fmt.allocPrint(gpa, "{s}/absent.zon", .{root});
    defer gpa.free(sources);

    try writeFixture(tmp.dir, "proj/a.zig", "/// proj record\npub fn one() void {}\n");
    var child = try spawnWatch(root, out, sources, &.{});
    defer terminate(&child);
    try waitArtifact(out, &.{"proj record"}, &.{});

    // A fresh clone under the root goes live with no config and no restart.
    try writeFixture(tmp.dir, "newlib/b.zig", "/// new lib record\npub fn n() void {}\n");
    try waitArtifact(out, &.{ "\"project\":\"newlib\"", "new lib record" }, &.{});
    try waitArtifact(status, &.{"\"newlib\":{"}, &.{});

    // Removal is equally live: the records and the sidecar member disappear.
    // `deleteTree` on a missing path is a silent success in 0.17.1 — the tree
    // exists here, created above.
    try tmp.dir.deleteTree(io, "newlib");
    try waitArtifact(out, &.{}, &.{"newlib"});
    try waitArtifact(status, &.{"proj"}, &.{"newlib"});
}

test "watch mode gives a registry entry its key and scope to the matching directory" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const out = try std.fmt.allocPrint(gpa, "{s}/tg/index.jsonl", .{root});
    defer gpa.free(out);
    const sources = try std.fmt.allocPrint(gpa, "{s}/registry.zon", .{root});
    defer gpa.free(sources);

    // The entry name differs from the url basename on purpose: the directory
    // `alpha` joins to the entry through the basename and must ship under the
    // entry's key `alpha_std` — the key clients already use (AGENTS.md §10's
    // manual recipe clones by url).
    const reg =
        \\.{
        \\    .alpha_std = .{
        \\        .url = "git+https://example.com/alpha.git?ref=main#abc123",
        \\        .hash = "h",
        \\        .branch = "main",
        \\        .commit = "abc123",
        \\        .scope = .{ .include = .{ "lib/**" }, .exclude = .{ "**/testdata/**" } },
        \\    },
        \\}
    ;
    try writeFixture(tmp.dir, "registry.zon", reg);
    try writeFixture(tmp.dir, "alpha/lib/d.zig", "/// lib record\npub fn dl() void {}\n");
    try writeFixture(tmp.dir, "alpha/other/e.zig", "/// other record\npub fn eo() void {}\n");

    var child = try spawnWatch(root, out, sources, &.{});
    defer terminate(&child);

    try waitArtifact(
        out,
        &.{ "\"project\":\"alpha_std\"", "lib record" },
        &.{ "other record", "\"project\":\"alpha\"" },
    );
}

test "watch mode exits 2 on a malformed registry, an illegal flag mix, and a missing root" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer gpa.free(root);
    const out = try std.fmt.allocPrint(gpa, "{s}/tg/index.jsonl", .{root});
    defer gpa.free(out);

    // SRV-8's shape: one stderr line and the usage block, never a bare Zig
    // error name or a stack trace. A startup failure is loud and fatal; only
    // mid-run failures degrade.
    try writeFixture(tmp.dir, "bad.zon", "this is not zon {{{");
    const bad_sources = try std.fmt.allocPrint(gpa, "{s}/bad.zon", .{root});
    defer gpa.free(bad_sources);
    const missing_root = try std.fmt.allocPrint(gpa, "{s}/nosuch", .{root});
    defer gpa.free(missing_root);
    const cases = [_][]const []const u8{
        &.{ "--watch", "--root", root, "--out", out, "--sources", bad_sources },
        &.{ "--watch", "--root", root, "--out", out, "--source", "p=c=d", "--poll-ms", "100" },
        &.{ "--watch", "--root", missing_root, "--out", out },
    };
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(gpa);
    for (cases) |c| {
        argv.clearRetainingCapacity();
        try argv.append(gpa, options.indexer_exe);
        try argv.appendSlice(gpa, c);
        var child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        });
        switch (try child.wait(io)) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 2), code),
            else => return error.UnexpectedExit,
        }
    }
}
