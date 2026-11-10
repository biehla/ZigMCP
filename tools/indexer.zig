//! Doc indexer: an upstream Zig tree → JSONL records plus a status sidecar (AGENTS.md §8).

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const TokenIndex = Ast.TokenIndex;
const LineTable = @import("line_table.zig").LineTable;

const Record = struct {
    project: []const u8,
    commit: []const u8,
    path: []const u8,
    line: u32,
    kind: []const u8,
    symbol: []const u8,
    container: []const u8,
    doc: []const u8,
    doc_hash: []const u8,
};

const Source = struct {
    project: []const u8,
    commit: []const u8,
    root: []const u8,
};

const Diag = struct {
    tag: []const u8,
    line: u32,
};

const DegradedFile = struct {
    path: []const u8,
    /// Set when the file could not be parsed at all, so there are no
    /// diagnostics to report (IDX-1, IDX-8). Static text.
    reason: ?[]const u8 = null,
    diagnostics: []const Diag,
};

/// Per-file read ceiling. A larger file is recorded as degraded instead of
/// aborting the run (IDX-1).
const max_file_bytes = 64 * 1024 * 1024;

/// Nesting beyond this is treated as hostile and the file is not parsed.
///
/// Real Zig source stays far below it; the parser's Debug overflow point is
/// 2 000 levels and a ReleaseSafe one is 10 000 (IDX-8).
const max_nesting_depth = 256;

/// The deepest run of `{`, `(` or `[` in a source file.
///
/// `std.zig.Ast.parse` recurses once per nesting level, so a pathological file
/// overflows the stack inside the parser — 4 KB of nested parens killed a Debug
/// indexer, 20 KB a ReleaseSafe one — and that aborted every project in the run
/// (IDX-8). A byte counter is deliberately crude: a bracket inside a string or
/// a comment can only make it more conservative.
fn maximumBracketDepth(source: []const u8) usize {
    var depth: usize = 0;
    var deepest: usize = 0;
    for (source) |c| {
        switch (c) {
            '{', '(', '[' => {
                depth += 1;
                if (depth > deepest) deepest = depth;
            },
            '}', ')', ']' => depth -|= 1,
            else => {},
        }
    }
    return deepest;
}

const ProjectStatus = struct {
    project: []const u8,
    commit: []const u8,
    records: usize,
    /// Every declaration the walk visited, documented or not (IDX-10). The
    /// difference from `records` is the yield of the documentation rule, and
    /// reporting it is what makes that yield a measurement rather than a claim.
    declarations: usize = 0,
    files_total: usize,
    degraded: std.ArrayList(DegradedFile),
    skipped: bool = false,
    previous_records: usize = 0,
};

const lessThan = struct {
    fn byRecord(_: void, a: Record, b: Record) bool {
        if (!std.mem.eql(u8, a.project, b.project)) return std.mem.order(u8, a.project, b.project) == .lt;
        if (!std.mem.eql(u8, a.symbol, b.symbol)) return std.mem.order(u8, a.symbol, b.symbol) == .lt;
        if (!std.mem.eql(u8, a.path, b.path)) return std.mem.order(u8, a.path, b.path) == .lt;
        return a.line < b.line;
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();

    var args_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args_iter.deinit();
    _ = args_iter.next(); // program name
    var out_path: ?[]const u8 = null;
    var status_path: ?[]const u8 = null;
    var previous_path: ?[]const u8 = null;
    var sources = std.ArrayList(Source).empty;
    var includes = std.ArrayList([]const u8).empty;
    var excludes = std.ArrayList([]const u8).empty;

    while (args_iter.next()) |raw| {
        const arg: []const u8 = raw;
        if (std.mem.eql(u8, arg, "--")) continue;
        if (std.mem.eql(u8, arg, "--out")) {
            out_path = args_iter.next() orelse usage(io);
        } else if (std.mem.eql(u8, arg, "--status")) {
            status_path = args_iter.next() orelse usage(io);
        } else if (std.mem.eql(u8, arg, "--previous")) {
            previous_path = args_iter.next() orelse usage(io);
        } else if (std.mem.eql(u8, arg, "--source")) {
            const v = args_iter.next() orelse usage(io);
            sources.append(gpa, try parseSource(io, gpa, v)) catch unreachable;
        } else if (std.mem.eql(u8, arg, "--include")) {
            const v = args_iter.next() orelse usage(io);
            includes.append(gpa, v) catch unreachable;
        } else if (std.mem.eql(u8, arg, "--exclude")) {
            const v = args_iter.next() orelse usage(io);
            excludes.append(gpa, v) catch unreachable;
        } else {
            usage(io);
        }
    }

    if (out_path == null or sources.items.len == 0) usage(io);

    var records = std.ArrayList(Record).empty;
    var statuses = std.ArrayList(ProjectStatus).empty;
    var previous: []const Record = &.{};
    if (previous_path) |pp| {
        previous = try loadPrevious(io, gpa, pp);
    }

    for (sources.items) |src| {
        var st = ProjectStatus{
            .project = src.project,
            .commit = src.commit,
            .records = 0,
            .files_total = 0,
            .degraded = .empty,
        };
        if (reusableFromPrevious(io, gpa, previous, previous_path, src)) {
            try carryPrevious(gpa, previous, src.project, src.commit, &records);
            st.skipped = true;
            st.previous_records = countForProject(records.items, src.project);
        } else {
            try indexSource(io, gpa, src, includes.items, excludes.items, &records, &st);
        }
        st.records = countForProject(records.items, src.project);
        try statuses.append(gpa, st);
    }

    std.sort.block(Record, records.items, {}, lessThan.byRecord);

    // Compact JSON escaping must stay on the standard path.
    var out_buf: [8192]u8 = undefined;
    const out_file = std.Io.Dir.cwd().createFile(io, out_path.?, .{}) catch |err| {
        std.debug.print("indexer: cannot create {s}: {}\n", .{ out_path.?, err });
        return err;
    };
    defer out_file.close(io);
    var fw = out_file.writer(io, &out_buf);
    for (records.items) |rec| {
        const line = try std.json.Stringify.valueAlloc(gpa, rec, .{ .whitespace = .minified });
        defer gpa.free(line);
        try fw.interface.writeAll(line);
        try fw.interface.writeByte('\n');
    }
    try fw.flush();

    const sp = (status_path orelse deriveStatusPath(gpa, out_path.?)) catch unreachable;
    try writeStatus(io, gpa, sp, statuses.items, previous_path != null);
}

fn countForProject(records: []Record, project: []const u8) usize {
    var n: usize = 0;
    for (records) |r| {
        if (std.mem.eql(u8, r.project, project)) n += 1;
    }
    return n;
}

fn loadPrevious(io: std.Io, gpa: std.mem.Allocator, path: []const u8) ![]const Record {
    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .limited(1024 * 1024 * 1024), .of(u8), null);
    var out = std.ArrayList(Record).empty;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        const parsed = try std.json.parseFromSlice(Record, gpa, line, .{});
        try out.append(gpa, parsed.value);
    }
    return out.toOwnedSlice(gpa);
}

/// Whether a project's records can be carried over from `--previous` instead of
/// being re-indexed.
///
/// A matching `(project, commit)` alone is not enough: a truncated previous
/// index still holds *some* record for that commit, and reusing it published a
/// partial project as if it were complete (IDX-3). When the previous run left a
/// status sidecar, its record count must equal what the JSONL actually holds.
/// Without a sidecar there is no oracle — a release baseline ships only the
/// JSONL — so the records are trusted as before.
fn reusableFromPrevious(
    io: std.Io,
    gpa: std.mem.Allocator,
    previous: []const Record,
    previous_path: ?[]const u8,
    src: Source,
) bool {
    const path = previous_path orelse return false;
    const present = countPreviousFor(previous, src.project, src.commit);
    if (present == 0) return false;
    const expected = previousRecordCount(io, gpa, path, src.project, src.commit) orelse return true;
    return expected == present;
}

/// The record count the previous run reported for one project, or null when
/// there is no sidecar, it is unreadable, or it does not describe this commit.
fn previousRecordCount(
    io: std.Io,
    gpa: std.mem.Allocator,
    previous_path: []const u8,
    project: []const u8,
    commit: []const u8,
) ?usize {
    const sidecar_path = deriveStatusPath(gpa, previous_path) catch return null;
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        sidecar_path,
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    ) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return null;
    if (parsed.value != .object) return null;
    const projects = parsed.value.object.get("projects") orelse return null;
    if (projects != .object) return null;
    const entry = projects.object.get(project) orelse return null;
    if (entry != .object) return null;
    const entry_commit = entry.object.get("commit") orelse return null;
    if (entry_commit != .string or !std.mem.eql(u8, entry_commit.string, commit)) return null;
    const records = entry.object.get("records") orelse return null;
    if (records != .integer) return null;
    return std.math.cast(usize, records.integer);
}

fn countPreviousFor(previous: []const Record, project: []const u8, commit: []const u8) usize {
    var n: usize = 0;
    for (previous) |r| {
        if (std.mem.eql(u8, r.project, project) and std.mem.eql(u8, r.commit, commit)) n += 1;
    }
    return n;
}

fn carryPrevious(gpa: std.mem.Allocator, previous: []const Record, project: []const u8, commit: []const u8, records: *std.ArrayList(Record)) !void {
    for (previous) |r| {
        if (std.mem.eql(u8, r.project, project) and std.mem.eql(u8, r.commit, commit)) {
            try records.append(gpa, r);
        }
    }
}

fn deriveStatusPath(gpa: std.mem.Allocator, out: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, out, ".jsonl")) {
        var b = try gpa.alloc(u8, out.len - ".jsonl".len + ".status.json".len);
        @memcpy(b[0 .. out.len - ".jsonl".len], out[0 .. out.len - ".jsonl".len]);
        @memcpy(b[out.len - ".jsonl".len ..], ".status.json");
        return b;
    }
    return std.fmt.allocPrint(gpa, "{s}.status.json", .{out});
}

fn writeStatus(io: std.Io, gpa: std.mem.Allocator, path: []const u8, statuses: []ProjectStatus, report_skip: bool) !void {
    const payload = try buildStatus(gpa, statuses, report_skip);
    var buf: [8192]u8 = undefined;
    const f = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer f.close(io);
    var w = f.writer(io, &buf);
    try w.interface.writeAll(payload);
    try w.flush();
}

fn buildStatus(gpa: std.mem.Allocator, statuses: []ProjectStatus, report_skip: bool) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const w = &aw.writer;
    try w.writeAll("{\"projects\":{");
    var first_p = true;
    for (statuses) |st| {
        if (!first_p) try w.writeByte(',');
        first_p = false;
        try writeJsonString(gpa, w, st.project);
        try w.writeAll(":{\"commit\":");
        try writeJsonString(gpa, w, st.commit);
        try w.print(",\"records\":{},\"declarations\":{},\"files_total\":{},\"files_degraded\":{}", .{ st.records, st.declarations, st.files_total, st.degraded.items.len });
        if (report_skip) {
            try w.print(",\"skipped\":{s}", .{if (st.skipped) "true" else "false"});
            if (st.skipped) try w.print(",\"previous_records\":{}", .{st.previous_records});
        }
        try w.writeAll(",\"degraded\":[");
        var first_f = true;
        for (st.degraded.items) |df| {
            if (!first_f) try w.writeByte(',');
            first_f = false;
            try w.writeAll("{\"path\":");
            try writeJsonString(gpa, w, df.path);
            if (df.reason) |reason| {
                try w.writeAll(",\"reason\":");
                try writeJsonString(gpa, w, reason);
            }
            try w.writeAll(",\"diagnostics\":[");
            var first_d = true;
            for (df.diagnostics) |d| {
                if (!first_d) try w.writeByte(',');
                first_d = false;
                try w.writeAll("{\"tag\":");
                try writeJsonString(gpa, w, d.tag);
                try w.print(",\"line\":{}}}", .{d.line});
            }
            try w.writeAll("]}");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("}}\n");
    return aw.toOwnedSlice();
}

fn writeJsonString(gpa: std.mem.Allocator, w: *std.Io.Writer, s: []const u8) !void {
    const enc = try std.json.Stringify.valueAlloc(gpa, s, .{ .whitespace = .minified });
    defer gpa.free(enc);
    try w.writeAll(enc);
}

fn usage(io: std.Io) noreturn {
    var buf: [4096]u8 = undefined;
    const f = std.Io.File.stderr();
    var w = f.writer(io, &buf);
    w.interface.writeAll(
        \\usage: indexer --out <index.jsonl> --source <project>=<commit>=<root> [--source ...] [--include <subpath> ...] [--exclude <subpath> ...] [--status <path>] [--previous <index.jsonl>]
    ) catch {};
    w.interface.writeAll("\n") catch {};
    w.flush() catch {};
    std.process.exit(2);
}

fn parseSource(io: std.Io, gpa: std.mem.Allocator, v: []const u8) !Source {
    const eq1 = std.mem.indexOfScalar(u8, v, '=') orelse usage(io);
    const rest = v[eq1 + 1 ..];
    const eq2 = std.mem.indexOfScalar(u8, rest, '=') orelse usage(io);
    return .{
        .project = try gpa.dupe(u8, v[0..eq1]),
        .commit = try gpa.dupe(u8, rest[0..eq2]),
        .root = try gpa.dupe(u8, rest[eq2 + 1 ..]),
    };
}

fn normalizeSlashes(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out = try gpa.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = if (c == '\\') '/' else c;
    return out;
}

fn matchesInclude(rel: []const u8, include: []const u8) bool {
    var inc = include;
    // `lib/std/**` is how `data/sources.zon` spells "everything under this
    // directory"; the walker compares prefixes, so the glob suffix is dropped
    // rather than matched (IDX-2).
    if (std.mem.endsWith(u8, inc, "/**")) inc = inc[0 .. inc.len - "/**".len];
    while (inc.len > 0 and (inc[inc.len - 1] == '/' or inc[inc.len - 1] == '\\')) inc = inc[0 .. inc.len - 1];
    if (inc.len == 0) return true;
    // Compare slash-normalized.
    if (rel.len < inc.len) return false;
    if (!std.mem.eql(u8, rel[0..inc.len], inc)) return false;
    if (rel.len == inc.len) return true;
    const next = rel[inc.len];
    return next == '/';
}

/// `lib/std/**/testdata/**` is how `data/sources.zon` spells "every testdata
/// directory under lib/std": `**` matches zero or more path segments, and a
/// bare directory prefix excludes everything below it (CI-4).
fn excludeSegments(gpa: std.mem.Allocator, exclude: []const u8) ![]const []const u8 {
    var pat = try normalizeSlashes(gpa, exclude);
    while (pat.len > 0 and (pat[pat.len - 1] == '/' or pat[pat.len - 1] == '\\')) pat = pat[0 .. pat.len - 1];
    var out: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, pat, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        try out.append(gpa, seg);
    }
    if (out.items.len > 0 and !std.mem.eql(u8, out.items[out.items.len - 1], "**")) {
        try out.append(gpa, "**");
    }
    return out.toOwnedSlice(gpa);
}

fn matchesExclude(rel: []const u8, segments: []const []const u8) bool {
    var rel_segs: [256][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, rel, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (n == rel_segs.len) return false;
        rel_segs[n] = seg;
        n += 1;
    }
    return matchExcludeSegments(rel_segs[0..n], segments);
}

/// Greedy wildcard match over path segments: `**` consumes zero or more
/// segments. One backtrack point suffices, so this is O(path × pattern) and
/// cannot recurse on a hostile pattern.
fn matchExcludeSegments(rel: []const []const u8, pat: []const []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;
    while (i < rel.len) {
        if (j < pat.len and std.mem.eql(u8, pat[j], "**")) {
            star = j;
            mark = i;
            j += 1;
            continue;
        }
        if (j < pat.len and std.mem.eql(u8, pat[j], rel[i])) {
            i += 1;
            j += 1;
            continue;
        }
        if (star) |s| {
            mark += 1;
            i = mark;
            j = s + 1;
            continue;
        }
        return false;
    }
    while (j < pat.len and std.mem.eql(u8, pat[j], "**")) j += 1;
    return j == pat.len;
}

fn indexSource(io: std.Io, gpa: std.mem.Allocator, src: Source, includes: []const []const u8, excludes: []const []const u8, records: *std.ArrayList(Record), st: *ProjectStatus) !void {
    var root_dir = try std.Io.Dir.cwd().openDir(io, src.root, .{ .iterate = true });
    defer root_dir.close(io);
    // Normalize the filters once; a per-file re-normalization would allocate a
    // copy for every file in the tree.
    const include_n = try gpa.alloc([]const u8, includes.len);
    for (includes, 0..) |inc, i| include_n[i] = try normalizeSlashes(gpa, inc);
    const exclude_n = try gpa.alloc([]const []const u8, excludes.len);
    for (excludes, 0..) |exc, i| exclude_n[i] = try excludeSegments(gpa, exc);
    var walker = try root_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const base = entry.basename;
        if (!std.mem.endsWith(u8, base, ".zig")) continue;
        const rel_raw: []const u8 = entry.path;
        const rel = try normalizeSlashes(gpa, rel_raw);
        if (include_n.len > 0) {
            var ok = false;
            for (include_n) |inc| {
                if (matchesInclude(rel, inc)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) continue;
        }
        var excluded = false;
        for (exclude_n) |seg| {
            if (matchesExclude(rel, seg)) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;
        st.files_total += 1;
        // Degrade, never skip: one unreadable or oversized file must not abort
        // every project in the run (IDX-1).
        const bytes = entry.dir.readFileAlloc(io, base, gpa, std.Io.Limit.limited(max_file_bytes)) catch |err| {
            try st.degraded.append(gpa, .{
                .path = rel,
                .reason = if (err == error.StreamTooLong)
                    "file exceeds the per-file size limit"
                else
                    @errorName(err),
                .diagnostics = &.{},
            });
            continue;
        };
        const src_z = try gpa.dupeSentinel(u8, bytes, 0);
        try indexFile(gpa, src.project, src.commit, rel, src_z, records, st);
    }
}

fn indexFile(gpa: std.mem.Allocator, project: []const u8, commit: []const u8, rel: []const u8, source_z: [:0]const u8, records: *std.ArrayList(Record), st: *ProjectStatus) !void {
    if (maximumBracketDepth(source_z) > max_nesting_depth) {
        try st.degraded.append(gpa, .{
            .path = rel,
            .reason = "nesting exceeds the depth limit",
            .diagnostics = &.{},
        });
        return;
    }

    var tree = try Ast.parse(gpa, source_z, .{ .mode = .zig });
    defer tree.deinit(gpa);
    const line_table = try LineTable.init(gpa, source_z);

    // Collect unattached doc runs (by first token of run).
    var unattached = std.AutoHashMap(TokenIndex, void).init(gpa);
    defer unattached.deinit();
    for (tree.errors) |err| {
        if (err.tag != .unattached_doc_comment) continue;
        var tok = err.token;
        if (err.token_is_prev) tok +%= 1;
        while (tok < tree.tokens.items(.tag).len) : (tok += 1) {
            if (tree.tokenTag(tok) != .doc_comment) break;
            unattached.put(tok, {}) catch {};
        }
    }

    // Degraded bookkeeping.
    if (tree.errors.len > 0) {
        var diags = std.ArrayList(Diag).empty;
        for (tree.errors) |err| {
            var tok = err.token;
            if (err.token_is_prev and tok > 0) tok -= 1;
            try diags.append(gpa, .{ .tag = @tagName(err.tag), .line = line_table.lineOf(tree.tokenStart(tok)) });
        }
        try st.degraded.append(gpa, .{ .path = rel, .diagnostics = try diags.toOwnedSlice(gpa) });
    }

    // //! container doc.
    const tags = tree.tokens.items(.tag);
    if (tags.len > 0 and tags[0] == .container_doc_comment) {
        var i: usize = 0;
        var lines = std.ArrayList([]const u8).empty;
        while (i < tags.len and tags[@intCast(i)] == .container_doc_comment) : (i += 1) {
            try lines.append(gpa, try stripPrefix3(gpa, tree.tokenSlice(@intCast(i)), "//!"));
        }
        const doc = try std.mem.join(gpa, "\n", lines.items);
        const sym = try modulePath(gpa, rel);
        try records.append(gpa, .{
            .project = project,
            .commit = commit,
            .path = rel,
            .line = 1,
            .kind = "container",
            .symbol = sym,
            .container = "",
            .doc = doc,
            .doc_hash = try hashDoc(gpa, doc),
        });
    }

    const mod_path = try modulePath(gpa, rel);
    var declarations: usize = 0;
    try walkDecls(gpa, &tree, &line_table, tree.rootDecls(), mod_path, project, commit, rel, records, &declarations, unattached);
    st.declarations += declarations;
}

fn stripPrefix3(gpa: std.mem.Allocator, slice: []const u8, prefix: []const u8) ![]const u8 {
    var result = slice;
    if (result.len >= prefix.len and std.mem.eql(u8, result[0..prefix.len], prefix)) {
        result = result[prefix.len..];
    }
    // A checkout with CRLF line endings must not change the extracted text:
    // the line ending is not part of the documentation, and the golden
    // comparison is byte-for-byte.
    if (result.len > 0 and result[result.len - 1] == '\r') {
        result = result[0 .. result.len - 1];
    }
    return sanitizeUtf8(gpa, result);
}

/// The JSON writer falls back to an array of bytes for invalid UTF-8, and the
/// loader then rejects the record's `doc` as the wrong type (IDX-5). Replace
/// each invalid byte with U+FFFD; the caller hashes the sanitized text, so the
/// `doc_hash` the loader recomputes still matches.
fn sanitizeUtf8(gpa: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        const b = s[i];
        const len: usize = if (b < 0x80)
            1
        else if (b & 0xE0 == 0xC0)
            2
        else if (b & 0xF0 == 0xE0)
            3
        else if (b & 0xF8 == 0xF0)
            4
        else
            0;
        if (len > 0 and i + len <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + len])) {
            try out.appendSlice(gpa, s[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(gpa, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The module path is the file path with `/` → `.` and `.zig` stripped. A `..`
/// component escapes the source root; refuse it rather than collapsing
/// `../x.zig` and `x.zig` onto the same symbol (IDX-6). Only an exact leading
/// `./` is removed — a dotfile's leading dot is part of its name.
pub fn modulePath(gpa: std.mem.Allocator, rel: []const u8) ![]const u8 {
    var s = rel;
    if (std.mem.startsWith(u8, s, "./")) s = s[2..];
    if (std.mem.endsWith(u8, s, ".zig")) s = s[0 .. s.len - 4];
    var parts = std.mem.splitScalar(u8, s, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..")) return error.PathEscapesRoot;
    }
    var out = try gpa.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = if (c == '/' or c == '\\') '.' else c;
    return out;
}

fn hashDoc(gpa: std.mem.Allocator, doc: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(doc, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return gpa.dupe(u8, &hex);
}

fn tokenLine(tree: *Ast, line_table: *const LineTable, tok: TokenIndex) u32 {
    return line_table.lineOf(tree.tokenStart(tok));
}

/// The `///` run attached to `first_tok`, or null when there is none.
///
/// Reports only an attached doc-comment run: a run the parser flagged
/// `unattached_doc_comment` is dropped, and what a declaration without one
/// means is the caller's decision (`collectDoc`).
fn collectDocRun(gpa: std.mem.Allocator, tree: *Ast, first_tok: TokenIndex, unattached: *const std.AutoHashMap(TokenIndex, void)) !?[]const u8 {
    if (first_tok == 0) return null;
    if (tree.tokenTag(first_tok - 1) != .doc_comment) return null;
    var start = first_tok - 1;
    while (start > 0 and tree.tokenTag(start - 1) == .doc_comment) start -= 1;
    if (unattached.contains(start)) return null;
    var lines = std.ArrayList([]const u8).empty;
    var i = start;
    while (i < first_tok) : (i += 1) {
        try lines.append(gpa, try stripPrefix3(gpa, tree.tokenSlice(i), "///"));
    }
    const joined: []const u8 = try std.mem.join(gpa, "\n", lines.items);
    return joined;
}

/// The documentation for a declaration: an attached `///` run when there is
/// one, otherwise the plain `//` run above it. Doc comments always win.
fn collectDoc(gpa: std.mem.Allocator, tree: *Ast, first_tok: TokenIndex, unattached: *const std.AutoHashMap(TokenIndex, void)) !?[]const u8 {
    if (try collectDocRun(gpa, tree, first_tok, unattached)) |doc| return doc;
    return collectLineComments(gpa, tree.source, tree.tokenStart(first_tok));
}

/// The byte offset of the start of the line containing `offset`.
fn lineStartOf(source: []const u8, offset: usize) usize {
    var i = offset;
    while (i > 0 and source[i - 1] != '\n') i -= 1;
    return i;
}

/// The text of one line when it is a plain `//` comment, else null.
///
/// `///` and `//!` lines are excluded so a doc run the attachment rule rejected
/// is never resurrected as a plain comment; `////` is excluded with them
/// (it starts with `///`) — a decorative separator documents nothing.
fn plainCommentText(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trimStart(u8, line, " \t\r");
    if (!std.mem.startsWith(u8, trimmed, "//")) return null;
    if (std.mem.startsWith(u8, trimmed, "///")) return null;
    if (std.mem.startsWith(u8, trimmed, "//!")) return null;
    return trimmed;
}

/// The plain `//` run that ends on the line directly above `decl_start`, joined
/// in source order with `\n`, or null when there is none.
///
/// Stricter than the `///` rule on purpose: no blank line may separate the run
/// from the declaration, because plain comments are routinely floating (license
/// headers, section dividers, TODOs) and a blank-line-tolerant rule would attach
/// them to whatever declaration came next. A trailing `// note` after code is
/// excluded by requiring the declaration to begin its own line.
fn collectLineComments(gpa: std.mem.Allocator, source: []const u8, decl_start: usize) !?[]const u8 {
    const start = lineStartOf(source, decl_start);
    for (source[start..decl_start]) |c| {
        if (c != ' ' and c != '\t' and c != '\r') return null;
    }
    if (start == 0) return null;

    var lines = std.ArrayList([]const u8).empty;
    var end = start - 1; // the '\n' that ends the previous line
    while (true) {
        const begin = lineStartOf(source, end);
        const text = plainCommentText(source[begin..end]) orelse break;
        try lines.append(gpa, try stripPrefix3(gpa, text, "//"));
        if (begin == 0) break;
        end = begin - 1;
    }
    if (lines.items.len == 0) return null;
    std.mem.reverse([]const u8, lines.items);
    const joined = try std.mem.join(gpa, "\n", lines.items);
    // A run of bare `//` lines is a separator, not documentation.
    if (std.mem.trim(u8, joined, " \t\r\n").len == 0) return null;
    return joined;
}

fn prefixJoin(gpa: std.mem.Allocator, prefix: []const u8, name: []const u8) ![]const u8 {
    if (prefix.len == 0) return gpa.dupe(u8, name);
    if (prefix[prefix.len - 1] == '.') {
        var buf = try gpa.alloc(u8, prefix.len + name.len);
        @memcpy(buf[0..prefix.len], prefix);
        @memcpy(buf[prefix.len..], name);
        return buf;
    }
    var buf = try gpa.alloc(u8, prefix.len + 1 + name.len);
    @memcpy(buf[0..prefix.len], prefix);
    buf[prefix.len] = '.';
    @memcpy(buf[prefix.len + 1 ..], name);
    return buf;
}

fn trimSuffixDot(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '.') return s[0 .. s.len - 1];
    return s;
}

fn walkDecls(gpa: std.mem.Allocator, tree: *Ast, line_table: *const LineTable, decls: []const Node.Index, prefix: []const u8, project: []const u8, commit: []const u8, rel: []const u8, records: *std.ArrayList(Record), declarations: *usize, unattached: std.AutoHashMap(TokenIndex, void)) anyerror!void {
    for (decls) |decl| {
        const tag = tree.nodeTag(decl);
        switch (tag) {
            .fn_decl, .fn_proto, .fn_proto_one, .fn_proto_multi, .fn_proto_simple => {
                // Counted before the doc decide: an undocumented declaration is
                // a declaration the rule dropped (IDX-10).
                declarations.* += 1;
                try handleFn(gpa, tree, line_table, decl, prefix, project, commit, rel, records, declarations, unattached);
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                declarations.* += 1;
                try handleVar(gpa, tree, line_table, decl, prefix, project, commit, rel, records, declarations, unattached);
            },
            .container_field_init, .container_field, .container_field_align => {
                declarations.* += 1;
                try handleField(gpa, tree, line_table, decl, prefix, project, commit, rel, records, declarations, unattached);
            },
            else => {
                // Unknown / non-declaration node: skip silently (degrade, never fail the file).
            },
        }
    }
}

/// The `///` run the parser attached to a parameter, or null when there is none
/// or the run is unattached.
fn paramDocRun(gpa: std.mem.Allocator, tree: *Ast, p: Ast.full.FnProto.Param, unattached: *const std.AutoHashMap(TokenIndex, void)) !?[]const u8 {
    const first_doc = p.first_doc_comment orelse return null;
    if (unattached.contains(first_doc)) return null;
    var lines = std.ArrayList([]const u8).empty;
    var i = first_doc;
    const toks = tree.tokens.items(.tag);
    while (i < toks.len and toks[i] == .doc_comment) : (i += 1) {
        try lines.append(gpa, try stripPrefix3(gpa, tree.tokenSlice(i), "///"));
    }
    const joined: []const u8 = try std.mem.join(gpa, "\n", lines.items);
    return joined;
}

fn handleFn(gpa: std.mem.Allocator, tree: *Ast, line_table: *const LineTable, decl: Node.Index, prefix: []const u8, project: []const u8, commit: []const u8, rel: []const u8, records: *std.ArrayList(Record), declarations: *usize, unattached: std.AutoHashMap(TokenIndex, void)) anyerror!void {
    var buf1: [1]Node.Index = undefined;
    const proto = tree.fullFnProto(&buf1, decl) orelse return;
    const first = tree.firstToken(decl);
    // Params are emitted even if the fn itself has no doc? Only emit fn record when documented; params independently.
    var fn_symbol: ?[]const u8 = null;
    if (proto.name_token) |nt| {
        const name = tree.tokenSlice(nt);
        const sym = try prefixJoin(gpa, prefix, name);
        fn_symbol = sym;
        if (try collectDoc(gpa, tree, first, &unattached)) |doc| {
            try records.append(gpa, .{
                .project = project,
                .commit = commit,
                .path = rel,
                .line = tokenLine(tree, line_table, first),
                .kind = "fn",
                .symbol = sym,
                .container = trimSuffixDot(prefix),
                .doc = doc,
                .doc_hash = try hashDoc(gpa, doc),
            });
        }
    }
    // Params.
    if (fn_symbol) |fsym| {
        var it = proto.iterate(tree);
        while (it.next()) |p| {
            const nt = p.name_token orelse continue;
            // A named parameter can carry a record too, so it is a site the
            // documentation rule either fills or drops (IDX-10).
            declarations.* += 1;
            // A parameter's first token is `comptime`/`noalias` when present,
            // so `noalias x: T` is scanned from `noalias`.
            const doc: []const u8 = (try paramDocRun(gpa, tree, p, &unattached)) orelse
                (try collectLineComments(gpa, tree.source, tree.tokenStart(p.comptime_noalias orelse nt))) orelse
                continue;
            const sym = try prefixJoin(gpa, fsym, tree.tokenSlice(nt));
            try records.append(gpa, .{
                .project = project,
                .commit = commit,
                .path = rel,
                .line = tokenLine(tree, line_table, nt),
                .kind = "param",
                .symbol = sym,
                .container = fsym,
                .doc = doc,
                .doc_hash = try hashDoc(gpa, doc),
            });
        }
    }
}

fn handleVar(gpa: std.mem.Allocator, tree: *Ast, line_table: *const LineTable, decl: Node.Index, prefix: []const u8, project: []const u8, commit: []const u8, rel: []const u8, records: *std.ArrayList(Record), declarations: *usize, unattached: std.AutoHashMap(TokenIndex, void)) anyerror!void {
    const vd = tree.fullVarDecl(decl) orelse return;
    const name_tok = vd.ast.mut_token + 1;
    if (name_tok >= tree.tokens.items(.tag).len) return;
    if (tree.tokenTag(name_tok) != .identifier) return;
    const name = tree.tokenSlice(name_tok);
    const sym = try prefixJoin(gpa, prefix, name);
    const first = tree.firstToken(decl);

    if (try collectDoc(gpa, tree, first, &unattached)) |doc| {
        try records.append(gpa, .{
            .project = project,
            .commit = commit,
            .path = rel,
            .line = tokenLine(tree, line_table, first),
            .kind = "var",
            .symbol = sym,
            .container = trimSuffixDot(prefix),
            .doc = doc,
            .doc_hash = try hashDoc(gpa, doc),
        });
    }

    const init = vd.ast.init_node.unwrap() orelse return;
    const init_tag = tree.nodeTag(init);
    if (init_tag == .error_set_decl) {
        try handleErrorSet(gpa, tree, line_table, init, prefix, sym, project, commit, rel, records, declarations, unattached);
        return;
    }
    // Container initializer -> recurse.
    var buf2: [2]Node.Index = undefined;
    if (tree.fullContainerDecl(&buf2, init)) |cd| {
        const new_prefix = try prefixJoin(gpa, prefix, name);
        var np = try gpa.alloc(u8, new_prefix.len + 1);
        @memcpy(np[0..new_prefix.len], new_prefix);
        np[new_prefix.len] = '.';
        try walkDecls(gpa, tree, line_table, cd.ast.members, np, project, commit, rel, records, declarations, unattached);
    }
}

fn handleErrorSet(gpa: std.mem.Allocator, tree: *Ast, line_table: *const LineTable, node: Node.Index, prefix: []const u8, outer_sym: []const u8, project: []const u8, commit: []const u8, rel: []const u8, records: *std.ArrayList(Record), declarations: *usize, unattached: std.AutoHashMap(TokenIndex, void)) anyerror!void {
    _ = prefix;
    const lbrace, const rbrace = tree.nodeData(node).token_and_token;
    const toks = tree.tokens.items(.tag);
    var i: TokenIndex = lbrace + 1;
    while (i < rbrace) : (i += 1) {
        if (toks[i] != .identifier) continue;
        declarations.* += 1;
        const doc: []const u8 = (try collectDocRun(gpa, tree, i, &unattached)) orelse
            (try collectLineComments(gpa, tree.source, tree.tokenStart(i))) orelse
            continue;
        const name = tree.tokenSlice(i);
        const sym = try prefixJoin(gpa, outer_sym, name);
        try records.append(gpa, .{
            .project = project,
            .commit = commit,
            .path = rel,
            .line = tokenLine(tree, line_table, i),
            .kind = "error",
            .symbol = sym,
            .container = outer_sym,
            .doc = doc,
            .doc_hash = try hashDoc(gpa, doc),
        });
    }
}

fn handleField(gpa: std.mem.Allocator, tree: *Ast, line_table: *const LineTable, decl: Node.Index, prefix: []const u8, project: []const u8, commit: []const u8, rel: []const u8, records: *std.ArrayList(Record), declarations: *usize, unattached: std.AutoHashMap(TokenIndex, void)) anyerror!void {
    const cf = tree.fullContainerField(decl) orelse return;
    const name_tok = cf.ast.main_token;
    if (tree.tokenTag(name_tok) != .identifier) return;
    const name = tree.tokenSlice(name_tok);
    const sym = try prefixJoin(gpa, prefix, name);
    const first = tree.firstToken(decl);
    if (try collectDoc(gpa, tree, first, &unattached)) |doc| {
        try records.append(gpa, .{
            .project = project,
            .commit = commit,
            .path = rel,
            .line = tokenLine(tree, line_table, first),
            .kind = "field",
            .symbol = sym,
            .container = trimSuffixDot(prefix),
            .doc = doc,
            .doc_hash = try hashDoc(gpa, doc),
        });
    }
    // A field may itself hold a container initializer (nested anonymous struct).
    const init = cf.ast.value_expr.unwrap() orelse if (cf.ast.type_expr.unwrap()) |te| te else return;
    var buf2: [2]Node.Index = undefined;
    if (tree.fullContainerDecl(&buf2, init)) |cd| {
        var np = try gpa.alloc(u8, sym.len + 1);
        @memcpy(np[0..sym.len], sym);
        np[sym.len] = '.';
        try walkDecls(gpa, tree, line_table, cd.ast.members, np, project, commit, rel, records, declarations, unattached);
    }
}

test "a plain comment run attaches only when adjacent and not a doc comment" {
    // The tokenizer emits no token for `//` (only `///` and `//!`), so the
    // fallback scans source lines. Each case pins one rule of the attachment.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const Case = struct {
        source: []const u8,
        expected: ?[]const u8,
    };
    const cases = [_]Case{
        // Adjacent lines are one run, joined in source order.
        .{ .source = "// one\n// two\npub const x = 1;\n", .expected = " one\n two" },
        // A blank line breaks the run: plain comments are routinely floating.
        .{ .source = "// one\n\npub const x = 1;\n", .expected = null },
        // A `///` run belongs to the doc path, never to prose.
        .{ .source = "/// doc\npub const x = 1;\n", .expected = null },
        // A trailing comment after code documents nothing.
        .{ .source = "const a = 1; // note\npub const x = 1;\n", .expected = null },
        // A CRLF checkout must not change the extracted text.
        .{ .source = "// one\r\npub const x = 1;\r\n", .expected = " one" },
        // A run of bare `//` lines is a separator.
        .{ .source = "//\n//\npub const x = 1;\n", .expected = null },
        // Nothing above the declaration.
        .{ .source = "pub const x = 1;\n", .expected = null },
    };
    for (cases) |case| {
        const decl_start = std.mem.indexOf(u8, case.source, "pub").?;
        const got = try collectLineComments(gpa, case.source, decl_start);
        if (case.expected) |want| {
            try std.testing.expect(got != null);
            try std.testing.expectEqualStrings(want, got.?);
        } else {
            try std.testing.expect(got == null);
        }
    }
}

test "modulePath keeps dotfiles distinct and rejects a parent escape" {
    // IDX-6: stripping every leading dot turned `../x.zig` into `x` — the same
    // symbol as `x.zig` — and a dotfile lost its leading dot.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try std.testing.expectEqualStrings("x", try modulePath(gpa, "x.zig"));
    try std.testing.expectEqualStrings("x", try modulePath(gpa, "./x.zig"));
    try std.testing.expectEqualStrings(".hidden", try modulePath(gpa, ".hidden.zig"));
    try std.testing.expectEqualStrings("lib.std.mem", try modulePath(gpa, "lib/std/mem.zig"));
    try std.testing.expectError(error.PathEscapesRoot, modulePath(gpa, "../x.zig"));
    try std.testing.expectError(error.PathEscapesRoot, modulePath(gpa, "lib/../x.zig"));
}
