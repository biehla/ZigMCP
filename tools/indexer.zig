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
    /// Every site the walk visited that can carry a record, documented or not
    /// (IDX-10). Null means "not known": a project carried over from
    /// `--previous` has no walk behind it, so reporting zero beside a full
    /// record count would be a fabricated yield.
    declarations: ?usize = null,
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
    var watch_mode = false;
    var watch_root: ?[]const u8 = null;
    var watch_sources: ?[]const u8 = null;
    var watch_poll: ?u64 = null;
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
        } else if (std.mem.eql(u8, arg, "--watch")) {
            watch_mode = true;
        } else if (std.mem.eql(u8, arg, "--root")) {
            watch_root = args_iter.next() orelse usage(io);
        } else if (std.mem.eql(u8, arg, "--sources")) {
            watch_sources = args_iter.next() orelse usage(io);
        } else if (std.mem.eql(u8, arg, "--poll-ms")) {
            const v = args_iter.next() orelse usage(io);
            watch_poll = std.fmt.parseInt(u64, v, 10) catch usage(io);
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

    if (watch_mode) {
        validateWatchArgs(.{
            .out = out_path,
            .root = watch_root,
            .has_source = sources.items.len != 0,
            .has_include = includes.items.len != 0,
            .has_exclude = excludes.items.len != 0,
            .has_previous = previous_path != null,
        }) catch {
            // SRV-8's shape: one line naming the illegal combination, then the
            // usage block, then exit 2 — never a bare Zig error name.
            logStderr(io, "indexer: --watch needs --root and --out and takes no --source/--include/--exclude/--previous\n", .{});
            usage(io);
        };
        const poll_ms = @max(watch_poll orelse default_watch_poll_ms, min_watch_poll_ms); // REL-1
        return watchMain(io, gpa, .{
            .out = out_path.?,
            .root = watch_root.?,
            .sources = watch_sources orelse "data/sources.zon",
            .status = status_path,
            .poll_ms = poll_ms,
        });
    }
    if (watch_root != null or watch_sources != null or watch_poll != null) {
        logStderr(io, "indexer: --root, --sources and --poll-ms apply only to --watch\n", .{});
        usage(io);
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
            // The files were not walked, so the only honest count is the one
            // the run that did walk them reported.
            st.declarations = previousDeclarations(io, gpa, previous_path, src.project, src.commit);
        } else {
            try indexSource(io, gpa, src, includes.items, excludes.items, &records, &st);
        }
        st.records = countForProject(records.items, src.project);
        try statuses.append(gpa, st);
    }

    std.sort.block(Record, records.items, {}, lessThan.byRecord);

    // Compact JSON escaping must stay on the standard path.
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    for (records.items) |rec| {
        const line = try std.json.Stringify.valueAlloc(gpa, rec, .{ .whitespace = .minified });
        try aw.writer.writeAll(line);
        try aw.writer.writeByte('\n');
    }
    const index_payload = try aw.toOwnedSlice();
    writeFileAtomic(io, out_path.?, index_payload) catch |err| {
        std.debug.print("indexer: cannot create {s}: {}\n", .{ out_path.?, err });
        return err;
    };

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
    const expected = previousStatus(io, gpa, path, src.project, src.commit) orelse return true;
    return expected.records == present;
}

const PreviousStatus = struct {
    records: usize,
    /// Null when the previous sidecar predates IDX-10 or was written without it.
    declarations: ?usize,
};

/// The counts the previous run reported for one project, or null when there is
/// no sidecar, it is unreadable, or it does not describe this commit.
fn previousStatus(
    io: std.Io,
    gpa: std.mem.Allocator,
    previous_path: []const u8,
    project: []const u8,
    commit: []const u8,
) ?PreviousStatus {
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
    const record_count = std.math.cast(usize, records.integer) orelse return null;
    var declarations: ?usize = null;
    if (entry.object.get("declarations")) |value| {
        if (value == .integer) declarations = std.math.cast(usize, value.integer);
    }
    return .{ .records = record_count, .declarations = declarations };
}

/// The declaration count the previous sidecar reported, so a carried-over
/// project keeps a measurement instead of publishing a zero (IDX-10).
fn previousDeclarations(
    io: std.Io,
    gpa: std.mem.Allocator,
    previous_path: ?[]const u8,
    project: []const u8,
    commit: []const u8,
) ?usize {
    const path = previous_path orelse return null;
    const status = previousStatus(io, gpa, path, project, commit) orelse return null;
    return status.declarations;
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
    try writeFileAtomic(io, path, payload);
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
        try w.print(",\"records\":{}", .{st.records});
        // Omitted rather than zero when the count is unknown: an incremental run
        // carries records over without walking the files (IDX-10).
        if (st.declarations) |declarations| try w.print(",\"declarations\":{}", .{declarations});
        try w.print(",\"files_total\":{},\"files_degraded\":{}", .{ st.files_total, st.degraded.items.len });
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
        \\       indexer --watch --root <dir> --out <index.jsonl> [--sources <file>] [--status <path>] [--poll-ms <n>]
    ) catch {};
    w.interface.writeAll("\n") catch {};
    w.flush() catch {};
    std.process.exit(2);
}

/// One line to stderr; stdout is not this binary's channel (AGENTS.md §6).
fn logStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.File.stderr().writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.flush() catch {};
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
        // The `//!` record is a site too, so `records` can never exceed
        // `declarations` (IDX-10).
        st.declarations = (st.declarations orelse 0) + 1;
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
    st.declarations = (st.declarations orelse 0) + declarations;
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

// ---------------------------------------------------------------------------
// Watch mode (AGENTS.md §8): one binary, a flag — "a different input shape is
// one path with a flag, not two implementations" (D10). Poll `--root`,
// re-index only the projects whose stat triples moved, and publish the merged
// artifact by atomic replace so the server's own file poll hot-swaps it
// (`src/docs/reload.zig`; the server needs no change).
// ---------------------------------------------------------------------------

const sources_lib = @import("sources");
const sleep_util = @import("sleep_util");

/// The provenance every watcher-built record carries: a live tree has no
/// pinned commit, and the sentinel keeps `--previous`'s `(project, commit)`
/// carry-over key out of this path — with a constant commit it would reuse a
/// stale project as if it matched the current tree.
const live_commit = "live";

const default_watch_poll_ms: u64 = 2_000;

/// Mirrors `docs.reload.min_poll_ms` (REL-1): a tighter interval only spins.
const min_watch_poll_ms: u64 = 100;

const max_sources_bytes = 16 * 1024 * 1024;

/// Directories never descended during a poll and never indexed under any
/// project — unioned into every scope, entry-scoped ones included. Batch
/// mode's one-shot `walk` can afford a million-object `.git`; a watcher
/// would re-walk it every tick. The `**/` prefix is load-bearing on both
/// sides: `matchExcludeSegments` with a bare leading segment would anchor to
/// the tree top only, while the walk prunes at any depth — one pattern set
/// keeps the two halves answering the same question (nested submodule
/// `.git`s would otherwise index once and then be invisible to detection
/// forever).
const prune_excludes = [_][]const u8{ "**/.git/**", "**/.zig-cache/**", "**/zig-out/**" };

/// The scope of an auto-discovered project: batch mode takes its scope from
/// `data/sources.zon` or the flags; a new clone has neither, so it indexes the
/// whole tree minus the noise directories and test data.
const default_excludes = [_][]const u8{ "**/.git/**", "**/.zig-cache/**", "**/zig-out/**", "**/testdata/**" };

/// Never descend during a poll.
const always_prune = [_][]const u8{ ".git", ".zig-cache", "zig-out" };

const WatchOptions = struct {
    out: []const u8,
    root: []const u8,
    sources: []const u8,
    status: ?[]const u8,
    poll_ms: u64,
};

const WatchProject = struct {
    /// A project matched by a `data/sources.zon` entry takes that entry's
    /// name as its key — the key clients already query (`zig_std`, not the
    /// directory `zig`); auto-discovered projects take the sanitized
    /// directory name. Keys are exact, case-sensitive project ids (AGENTS.md §5,
    /// PROTO-13).
    key: []const u8,
    root: []const u8,
    includes: []const []const u8,
    excludes: []const []const u8,
};

const WatchArgs = struct {
    out: ?[]const u8,
    root: ?[]const u8,
    has_source: bool,
    has_include: bool,
    has_exclude: bool,
    has_previous: bool,
};

/// Watch mode has its own registration path (discovery plus the registry
/// file), so the batch-only flags are an illegal combination, not a second
/// scoping channel. Pure so a unit test can reach it without `usage`'s
/// `noreturn`.
fn validateWatchArgs(args: WatchArgs) error{IllegalFlagCombination}!void {
    if (args.out == null or args.root == null) return error.IllegalFlagCombination;
    if (args.has_source or args.has_include or args.has_exclude or args.has_previous) {
        return error.IllegalFlagCombination;
    }
}

/// The change-detection triple from REL-7: a rewrite restoring mtime still
/// moves ctime, and a rename storm can fail a stat — the caller keeps the old
/// entry and re-checks next tick.
const FileStat = struct {
    size: u64,
    mtime_ns: i128,
    ctime_ns: i128,
};

const StatChange = enum { unchanged, changed, added, removed };

fn statDiff(old: ?FileStat, now: ?FileStat) StatChange {
    if (old == null) return if (now == null) .unchanged else .added;
    if (now == null) return .removed;
    const a = old.?;
    const b = now.?;
    if (a.size != b.size or a.mtime_ns != b.mtime_ns or a.ctime_ns != b.ctime_ns) return .changed;
    return .unchanged;
}

/// Project keys keep the charset a client can type and `docs://` can carry:
/// `[A-Za-z0-9_]`, every other byte replaced. Nothing collapses and case is
/// preserved, so `Fixture` and `fixture` stay two projects (PROTO-13).
fn sanitizeName(gpa: std.mem.Allocator, name: []const u8) ![]const u8 {
    const out = try gpa.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
    }
    return out;
}

/// `git+https://github.com/ziglang/zig.git?ref=master#<sha>` → `zig`, and
/// `…/mcp.zig.git?ref=main#<sha>` → `mcp_zig`. The readme clones by url
/// basename, so this is how a checkout directory finds its registry entry.
fn urlBasenameToKey(gpa: std.mem.Allocator, url: []const u8) ![]const u8 {
    var base = if (std.mem.lastIndexOfScalar(u8, url, '/')) |slash| url[slash + 1 ..] else url;
    if (std.mem.indexOfScalar(u8, base, '?')) |query| base = base[0..query];
    if (std.mem.endsWith(u8, base, ".git")) base = base[0 .. base.len - ".git".len];
    return sanitizeName(gpa, base);
}

fn prunedName(name: []const u8) bool {
    for (always_prune) |pruned| {
        if (std.mem.eql(u8, name, pruned)) return true;
    }
    return false;
}

fn scopesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

/// List the watch root's directories and match each against the registry.
/// `log` prints the warnings only on the first pass — a repeated diagnostic
/// every two seconds would bury stderr. A missing registry file is the
/// documented warn-and-discover-only path; a malformed one fails the caller,
/// which decides between exit 2 (startup) and keeping the previous projects.
fn discover(
    io: std.Io,
    gpa: std.mem.Allocator,
    root: []const u8,
    sources_path: []const u8,
    log: bool,
) ![]WatchProject {
    var registry: []const sources_lib.Source = &.{};
    const registry_text = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        sources_path,
        gpa,
        .limited(max_sources_bytes),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (registry_text) |text| {
        registry = try sources_lib.parse(gpa, text);
    } else if (log) {
        logStderr(io, "indexer: {s} not found; discovering directories only\n", .{sources_path});
    }

    var root_trimmed = root;
    while (root_trimmed.len > 0 and (root_trimmed[root_trimmed.len - 1] == '/' or root_trimmed[root_trimmed.len - 1] == '\\')) {
        root_trimmed = root_trimmed[0 .. root_trimmed.len - 1];
    }
    var names = std.ArrayList([]const u8).empty;
    {
        var root_dir = try std.Io.Dir.cwd().openDir(io, root_trimmed, .{ .iterate = true });
        defer root_dir.close(io);
        var it = root_dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
    }
    // Undefined iteration order must not make a collision winner a coin toss.
    std.sort.block([]const u8, names.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    var projects = std.ArrayList(WatchProject).empty;
    var claimed = std.StringHashMap(void).init(gpa);
    defer claimed.deinit();
    for (names.items) |name| {
        const dir_key = try sanitizeName(gpa, name);
        var matched: ?sources_lib.Source = null;
        var matches: usize = 0;
        for (registry) |entry| {
            const url_key = try urlBasenameToKey(gpa, entry.url);
            if (std.mem.eql(u8, entry.name, dir_key) or std.mem.eql(u8, url_key, dir_key)) {
                matches += 1;
                if (matched == null) matched = entry;
            }
        }
        if (matches > 1 and log) {
            logStderr(io, "indexer: directory {s} matches several {s} entries; using the first\n", .{ name, sources_path });
        }
        const key = if (matched) |entry| entry.name else dir_key;
        if (claimed.contains(key)) {
            if (log) logStderr(io, "indexer: directory {s} claims project {s} already claimed; skipping\n", .{ name, key });
            continue;
        }
        const includes: []const []const u8 = if (matched) |entry| entry.includes else &.{};
        // A matched entry passes its scope verbatim with the prune set
        // unioned in; an auto-discovered directory takes the full defaults.
        // Watch mode and CI then index the same set of files for that
        // project, except the noise directories no repo keeps as contract.
        const excludes: []const []const u8 = blk: {
            if (matched) |entry| {
                var list = std.ArrayList([]const u8).empty;
                try list.appendSlice(gpa, entry.excludes);
                try list.appendSlice(gpa, &prune_excludes);
                break :blk list.items;
            }
            break :blk &default_excludes;
        };
        try projects.append(gpa, .{
            .key = key,
            .root = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root_trimmed, name }),
            .includes = includes,
            .excludes = excludes,
        });
        try claimed.put(key, {});
    }
    return projects.toOwnedSlice(gpa);
}

/// One watched project's live state. Two arenas with different lifetimes:
/// the stat table is rebuilt every tick, the records only when a project is
/// dirty — resetting one must not dangle the other (AGENTS.md §11: an arena is only
/// ever created on the heap, never copied by value).
const ProjectState = struct {
    project: WatchProject, // strings owned by the long-lived allocator
    records_arena: ?*std.heap.ArenaAllocator,
    records: []const Record,
    status: ProjectStatus,
    stats_arena: ?*std.heap.ArenaAllocator,
    stats: std.StringHashMap(FileStat),
    dirty: bool,
};

fn dupeStrings(gpa: std.mem.Allocator, list: []const []const u8) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, list.len);
    for (list, 0..) |s, i| out[i] = try gpa.dupe(u8, s);
    return out;
}

fn cloneProject(gpa: std.mem.Allocator, p: WatchProject) !WatchProject {
    return .{
        .key = try gpa.dupe(u8, p.key),
        .root = try gpa.dupe(u8, p.root),
        .includes = try dupeStrings(gpa, p.includes),
        .excludes = try dupeStrings(gpa, p.excludes),
    };
}

/// Frees everything of a project except the key: the key doubles as the
/// `states` map key, so it must outlive a scope replacement and is freed only
/// when the map entry itself is gone (see `dropState`). Under the server's
/// startup arena these are near-no-ops — an arena releases individual
/// allocations only at its tail — so the real cleanup is the whole-arena
/// `deinit`; production churn per add/remove/scope-edit stays bounded and
/// tiny. The frees are not theater either: under a testing allocator they are
/// real, and the unit layer is leak-checked.
fn freeProjectStrings(gpa: std.mem.Allocator, p: WatchProject) void {
    gpa.free(p.root);
    for (p.includes) |s| gpa.free(s);
    gpa.free(p.includes);
    for (p.excludes) |s| gpa.free(s);
    gpa.free(p.excludes);
}

fn createState(gpa: std.mem.Allocator, project: WatchProject) !*ProjectState {
    const state = try gpa.create(ProjectState);
    const owned = try cloneProject(gpa, project);
    state.* = .{
        .project = owned,
        .records_arena = null,
        .records = &.{},
        .status = .{
            .project = owned.key,
            .commit = live_commit,
            .records = 0,
            .files_total = 0,
            .degraded = .empty,
        },
        .stats_arena = null,
        .stats = std.StringHashMap(FileStat).init(gpa),
        .dirty = true,
    };
    return state;
}

fn dropState(gpa: std.mem.Allocator, state: *ProjectState) void {
    if (state.records_arena) |arena| {
        arena.deinit();
        gpa.destroy(arena);
    }
    if (state.stats_arena) |arena| {
        arena.deinit();
        gpa.destroy(arena);
    }
    freeProjectStrings(gpa, state.project);
    gpa.free(state.project.key);
    gpa.destroy(state);
}

/// Re-index into a fresh arena and swap only on success: a parse or read
/// failure mid-pass must leave the last good records serving, the same rule
/// the server applies to index artifacts (AGENTS.md §8, REL-9's whole-or-nothing).
fn indexNow(io: std.Io, gpa: std.mem.Allocator, state: *ProjectState) !void {
    const fresh = try gpa.create(std.heap.ArenaAllocator);
    fresh.* = std.heap.ArenaAllocator.init(gpa); // no allocation before the store: safe
    errdefer {
        fresh.deinit();
        gpa.destroy(fresh);
    }
    var records = std.ArrayList(Record).empty;
    var st = ProjectStatus{
        .project = state.project.key,
        .commit = live_commit,
        .records = 0,
        .files_total = 0,
        .degraded = .empty,
    };
    try indexSource(
        io,
        fresh.allocator(),
        .{ .project = state.project.key, .commit = live_commit, .root = state.project.root },
        state.project.includes,
        state.project.excludes,
        &records,
        &st,
    );
    st.records = records.items.len;
    const old = state.records_arena;
    state.records_arena = fresh;
    state.records = records.items;
    state.status = st;
    if (old) |arena| {
        arena.deinit();
        gpa.destroy(arena);
    }
}

/// Rebuild the `.zig` stat table of one project. The walk deliberately
/// ignores include/exclude scope — the matcher's canonical home is this
/// file's batch walker and a branch-wise copy would be a second convention
/// (AGENTS.md §12); an edit to an excluded path costs one re-index whose identical
/// bytes are dropped by the digest skip. `walkSelectively` because batch
/// mode's `walk` auto-descends everything, `.git` included.
fn scanProject(io: std.Io, gpa: std.mem.Allocator, state: *ProjectState) !void {
    const fresh = try gpa.create(std.heap.ArenaAllocator);
    fresh.* = std.heap.ArenaAllocator.init(gpa);
    errdefer {
        fresh.deinit();
        gpa.destroy(fresh);
    }
    const arena = fresh.allocator();
    var stats = std.StringHashMap(FileStat).init(arena);
    var root_dir = try std.Io.Dir.cwd().openDir(io, state.project.root, .{ .iterate = true });
    defer root_dir.close(io);
    var walker = try root_dir.walkSelectively(arena);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        switch (entry.kind) {
            .file => {
                if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
                const stat = entry.dir.statFile(io, entry.basename, .{}) catch continue;
                const rel = try normalizeSlashes(arena, entry.path);
                try stats.put(rel, .{
                    .size = stat.size,
                    .mtime_ns = stat.mtime.nanoseconds,
                    .ctime_ns = stat.ctime.nanoseconds,
                });
            },
            .directory => {
                if (prunedName(entry.basename)) continue;
                try walker.enter(io, entry);
            },
            else => {},
        }
    }

    var changed = false;
    var old_it = state.stats.iterator();
    while (old_it.next()) |kv| {
        const now = stats.get(kv.key_ptr.*) orelse {
            changed = true; // removed
            break;
        };
        if (statDiff(kv.value_ptr.*, now) != .unchanged) changed = true;
    }
    if (!changed) {
        var new_it = stats.iterator();
        while (new_it.next()) |kv| {
            if (!state.stats.contains(kv.key_ptr.*)) {
                changed = true; // added
                break;
            }
        }
    }

    if (state.stats_arena) |arena_box| {
        arena_box.deinit();
        gpa.destroy(arena_box);
    }
    state.stats_arena = fresh;
    state.stats = stats;
    if (changed) state.dirty = true;
}

/// SHA-256 over an artifact's bytes, the same call shape as `digestOf` in
/// `src/docs/reload.zig`.
fn digestOf(bytes: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

/// Write `payload` at `path` by atomic replace, creating the parent
/// directory if needed. The server polls size+mtime+ctime and swaps only a
/// fully validated artifact, so a publish must never be observable as a torn
/// file — a plain `createFile` would stream the payload past a poll (REL-7,
/// AGENTS.md §8). Windows leaves a brief `AccessDenied` window on the destination
/// during `replace`; the server's stat poll swallows it as one no-change tick.
fn writeFileAtomic(io: std.Io, path: []const u8, payload: []const u8) !void {
    const sep = std.mem.lastIndexOfAny(u8, path, "/\\");
    const base = if (sep) |s| path[s + 1 ..] else path;
    var stem: []const u8 = if (sep) |s| path[0..s] else "";
    if (stem.len == 0 and path.len > 0 and (path[0] == '/' or path[0] == '\\')) stem = path[0..1];

    var dir = std.Io.Dir.cwd();
    var opened = false;
    if (stem.len > 0) {
        std.Io.Dir.cwd().createDirPath(io, stem) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        dir = try std.Io.Dir.cwd().openDir(io, stem, .{});
        opened = true;
    }
    var af = dir.createFileAtomic(io, base, .{ .replace = true }) catch |err| {
        if (opened) dir.close(io);
        return err;
    };
    defer if (opened) dir.close(io); // runs after af.deinit, which may delete a tmp
    defer af.deinit(io);
    var buf: [64 * 1024]u8 = undefined;
    var w = af.file.writer(io, &buf);
    try w.interface.writeAll(payload);
    try w.flush();
    try af.replace(io);
}

const StatesMap = std.StringHashMap(*ProjectState);

/// Serialize the live in-memory state in canonical order (AGENTS.md §7) and publish
/// both artifacts, skipping any write whose bytes equal the last publish:
/// the server keys on mtime/ctime, so a gratuitous rewrite would trigger a
/// full validate-and-swap for identical content.
fn publish(
    io: std.Io,
    scratch: std.mem.Allocator,
    states: *const StatesMap,
    out_path: []const u8,
    status_path: []const u8,
    last_index: *?[32]u8,
    last_status: *?[32]u8,
) !void {
    var present = std.ArrayList(*ProjectState).empty;
    var vit = states.valueIterator();
    while (vit.next()) |boxed| try present.append(scratch, boxed.*);
    // Sidecar and digest stability: map iteration order is undefined, so the
    // projects go out in key order.
    std.sort.block(*ProjectState, present.items, {}, struct {
        fn lt(_: void, a: *ProjectState, b: *ProjectState) bool {
            return std.mem.lessThan(u8, a.project.key, b.project.key);
        }
    }.lt);

    var records = std.ArrayList(Record).empty;
    for (present.items) |state| try records.appendSlice(scratch, state.records);
    std.sort.block(Record, records.items, {}, lessThan.byRecord);

    var aw: std.Io.Writer.Allocating = .init(scratch);
    defer aw.deinit();
    for (records.items) |rec| {
        const line = try std.json.Stringify.valueAlloc(scratch, rec, .{ .whitespace = .minified });
        try aw.writer.writeAll(line);
        try aw.writer.writeByte('\n');
    }
    const payload = try aw.toOwnedSlice();
    const index_digest = digestOf(payload);
    if (last_index.* == null or !std.mem.eql(u8, &last_index.*.?, &index_digest)) {
        try writeFileAtomic(io, out_path, payload);
    }
    last_index.* = index_digest;

    var statuses = std.ArrayList(ProjectStatus).empty;
    for (present.items) |state| try statuses.append(scratch, state.status);
    // `report_skip = false`: the skipped/previous_records members are a
    // `--previous` batch concept, and every project here was actually walked,
    // so `declarations` is always a real count (IDX-10).
    const status_payload = try buildStatus(scratch, statuses.items, false);
    const status_digest = digestOf(status_payload);
    if (last_status.* == null or !std.mem.eql(u8, &last_status.*.?, &status_digest)) {
        try writeFileAtomic(io, status_path, status_payload);
    }
    last_status.* = status_digest;
}

fn sleepPoll(io: std.Io, ms: u64) void {
    // Sliced so Ctrl+C does not wait out a long interval, and routed through
    // the verified sleep helper (`src/util/sleep.zig`): on Windows the delay
    // comes from the native timer, so a sleep that would have to be serviced
    // by an `Io` can never degrade the loop into the spin class (AGENTS.md §16 #14).
    var remaining = ms;
    while (remaining > 0) {
        const step = @min(remaining, 1_000);
        sleep_util.sleepMilliseconds(io, step);
        remaining -= step;
    }
}

/// The foreground watch loop. Startup is the first tick — index everything,
/// publish — and a failure to open the root or parse the registry is fatal
/// and loud (a typo'd `--root` must not silently watch nothing). After
/// startup, nothing a single tick does is fatal: a vanished directory, a
/// failed re-index, a broken registry edit keeps the previous state serving
/// and retries on the next poll (the same degrade-never-abort rule as the
/// indexer's own walk, IDX-1).
fn watchMain(io: std.Io, gpa: std.mem.Allocator, opts: WatchOptions) !void {
    var states = StatesMap.init(gpa);
    const scratch_box = try gpa.create(std.heap.ArenaAllocator);
    scratch_box.* = std.heap.ArenaAllocator.init(gpa);
    const status_path = opts.status orelse try deriveStatusPath(gpa, opts.out);
    var last_index_digest: ?[32]u8 = null;
    var last_status_digest: ?[32]u8 = null;

    var first_tick = true;
    while (true) {
        _ = scratch_box.reset(.retain_capacity);
        const tick = scratch_box.allocator();
        var need_publish = first_tick;
        var startup_ok = true;

        var discovery_ok = true;
        var discovered: []WatchProject = &.{};
        discovered = discover(io, tick, opts.root, opts.sources, first_tick) catch |err| blk: {
            if (first_tick) {
                // SRV-8's spirit: the operator must see which path failed.
                logStderr(io, "indexer: watch startup failed: {s} (root {s}, registry {s})\n", .{ @errorName(err), opts.root, opts.sources });
                std.process.exit(2);
            }
            logStderr(io, "indexer: discovery failed: {s}; keeping previous projects this tick\n", .{@errorName(err)});
            discovery_ok = false;
            break :blk &.{};
        };

        if (discovery_ok) {
            var seen = std.StringHashMap(void).init(tick);
            for (discovered) |project| {
                try seen.put(project.key, {});
                if (states.get(project.key)) |state| {
                    if (!std.mem.eql(u8, state.project.root, project.root) or
                        !scopesEqual(state.project.includes, project.includes) or
                        !scopesEqual(state.project.excludes, project.excludes))
                    {
                        // The registry moved under this directory; the scope
                        // strings live in tick scratch, so own a copy. The
                        // key string is the map key and stays put.
                        var replacement = try cloneProject(gpa, project);
                        gpa.free(replacement.key);
                        replacement.key = state.project.key;
                        freeProjectStrings(gpa, state.project);
                        state.project = replacement;
                        state.dirty = true;
                    }
                } else {
                    const new_state = try createState(gpa, project);
                    // The key is the clone's own string, not the tick scratch:
                    // the map outlives every scratch reset.
                    states.put(new_state.project.key, new_state) catch |err| {
                        dropState(gpa, new_state);
                        return err;
                    };
                    need_publish = true;
                }
            }
            var removed = std.ArrayList([]const u8).empty;
            var sit = states.keyIterator();
            while (sit.next()) |key| {
                if (!seen.contains(key.*)) try removed.append(tick, key.*);
            }
            for (removed.items) |key| {
                if (states.fetchRemove(key)) |kv| dropState(gpa, kv.value);
                need_publish = true; // the artifact must lose this project
            }
        }

        var ait = states.valueIterator();
        while (ait.next()) |boxed| {
            const state = boxed.*;
            scanProject(io, gpa, state) catch |err| {
                logStderr(io, "indexer: scan failed for {s}: {s}\n", .{ state.project.key, @errorName(err) });
                continue;
            };
            if (!state.dirty) continue;
            indexNow(io, gpa, state) catch |err| {
                logStderr(io, "indexer: re-index failed for {s}: {s}\n", .{ state.project.key, @errorName(err) });
                if (first_tick) startup_ok = false;
                continue;
            };
            state.dirty = false;
            need_publish = true;
        }

        if (need_publish and startup_ok) {
            publish(io, tick, &states, opts.out, status_path, &last_index_digest, &last_status_digest) catch |err| {
                logStderr(io, "indexer: publish failed: {s}\n", .{@errorName(err)});
            };
        }

        first_tick = false;
        sleepPoll(io, opts.poll_ms);
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

test "validateWatchArgs pins the flag matrix" {
    // D10: one path with a flag. Watch mode owns discovery for scope, so the
    // batch flags there are illegal combinations, and --root/--out are not
    // optional.
    const good = WatchArgs{ .out = "o", .root = "r", .has_source = false, .has_include = false, .has_exclude = false, .has_previous = false };
    try validateWatchArgs(good);
    const bad = [_]WatchArgs{
        .{ .out = null, .root = "r", .has_source = false, .has_include = false, .has_exclude = false, .has_previous = false },
        .{ .out = "o", .root = null, .has_source = false, .has_include = false, .has_exclude = false, .has_previous = false },
        .{ .out = "o", .root = "r", .has_source = true, .has_include = false, .has_exclude = false, .has_previous = false },
        .{ .out = "o", .root = "r", .has_source = false, .has_include = true, .has_exclude = false, .has_previous = false },
        .{ .out = "o", .root = "r", .has_source = false, .has_include = false, .has_exclude = true, .has_previous = false },
        .{ .out = "o", .root = "r", .has_source = false, .has_include = false, .has_exclude = false, .has_previous = true },
    };
    for (bad) |args| {
        try std.testing.expectError(error.IllegalFlagCombination, validateWatchArgs(args));
    }
}

test "sanitize keeps the docs-URI charset and the url basename maps a clone to its entry" {
    // AGENTS.md §10's manual recipe clones by url; the watch root sees the checkout's
    // directory name, so the url basename is the join key.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    try std.testing.expectEqualStrings("mcp_zig", try sanitizeName(gpa, "mcp.zig"));
    try std.testing.expectEqualStrings("my_lib_2", try sanitizeName(gpa, "my-lib 2"));
    try std.testing.expectEqualStrings("Zig", try sanitizeName(gpa, "Zig")); // case preserved (PROTO-13)

    try std.testing.expectEqualStrings(
        "zig",
        try urlBasenameToKey(gpa, "git+https://github.com/ziglang/zig.git?ref=master#738d2be"),
    );
    try std.testing.expectEqualStrings(
        "mcp_zig",
        try urlBasenameToKey(gpa, "git+https://github.com/kapzy/mcp.zig.git?ref=main#abc"),
    );
    // A url whose basename differs from the entry name is what makes the
    // `upstream/zig` directory land on the `zig_std` key.
    try std.testing.expectEqualStrings("zig", try urlBasenameToKey(gpa, "https://example.com/zig"));
}

test "statDiff reports only triple transitions" {
    const a = FileStat{ .size = 10, .mtime_ns = 20, .ctime_ns = 30 };
    var b = a;
    try std.testing.expectEqual(StatChange.unchanged, statDiff(a, b));
    b.ctime_ns += 1; // an in-place rewrite restoring mtime still moves ctime (REL-7)
    try std.testing.expectEqual(StatChange.changed, statDiff(a, b));
    try std.testing.expectEqual(StatChange.added, statDiff(null, a));
    try std.testing.expectEqual(StatChange.removed, statDiff(a, null));
    try std.testing.expectEqual(StatChange.unchanged, statDiff(null, null));
}

test "discover scopes by entry name and url basename, sanitizes the rest, and skips dots" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});

    // Directories mirroring the real layout: `zig` joined by url basename,
    // `mcp.zig` by name, one auto-discovered, one dotted (skipped), one a
    // prune-name (not skipped by discovery — it is a project to watch, and
    // `always_prune` governs the descent inside a project).
    for ([_][]const u8{ "zig", "mcp.zig", ".hidden", "env zig" }) |name| {
        tmp.dir.createDirPath(io, name) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const reg =
        \\.{
        \\    .zig_std = .{ .url = "git+https://github.com/ziglang/zig.git?ref=master#deadbeef", .hash = "h", .branch = "master", .commit = "deadbeef", .scope = .{ .include = .{ "lib/std/**" }, .exclude = .{ "lib/std/**/testdata/**" } } },
        \\    .mcp_zig = .{ .url = "git+https://github.com/kapzy/mcp.zig.git?ref=main#cafe", .hash = "h", .commit = "cafe" },
        \\}
    ;
    const reg_path = try std.fmt.allocPrint(gpa, "{s}/reg.zon", .{root});
    {
        const f = try tmp.dir.createFile(io, "reg.zon", .{});
        defer f.close(io);
        var buf: [4096]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll(reg);
        try w.flush();
    }

    const projects = try discover(io, gpa, root, reg_path, false);
    try std.testing.expectEqual(@as(usize, 3), projects.len);
    // Sorted directory order: "env zig", "mcp.zig", "zig".
    try std.testing.expectEqualStrings("env_zig", projects[0].key);
    try std.testing.expectEqual(@as(usize, 0), projects[0].includes.len);
    try std.testing.expectEqual(default_excludes.len, projects[0].excludes.len);
    try std.testing.expectEqualStrings("mcp_zig", projects[1].key);
    // A scope-less entry keeps its own scope empty, but the prune set is
    // unioned into every watched project: detection prunes `.git` at any
    // depth, so indexing must refuse it at any depth too.
    try std.testing.expectEqual(@as(usize, 0), projects[1].includes.len);
    try std.testing.expectEqual(prune_excludes.len, projects[1].excludes.len);
    try std.testing.expectEqualStrings("zig_std", projects[2].key); // via url basename
    try std.testing.expectEqual(1 + prune_excludes.len, projects[2].excludes.len);
    try std.testing.expectEqualStrings("lib/std/**", projects[2].includes[0]);
    try std.testing.expect(std.mem.indexOfScalar(u8, projects[2].root, '\\') == null);
    for (projects) |p| {
        try std.testing.expect(!std.mem.eql(u8, p.key, ".hidden"));
    }

    // A missing registry file is the warn-and-discover-only path, not an error.
    const auto = try discover(io, gpa, root, try std.fmt.allocPrint(gpa, "{s}/absent.zon", .{root}), false);
    try std.testing.expectEqual(@as(usize, 3), auto.len);
    try std.testing.expectEqualStrings("zig", auto[2].key); // no entry to join to: raw sanitized name
}

test "discover refuses to put two directories under one project key" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    for ([_][]const u8{ "a-b", "a_b" }) |name| {
        tmp.dir.createDirPath(io, name) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }
    const projects = try discover(io, gpa, root, "/nonexistent-regardless.zon", false);
    // Both sanitize to `a_b`; the first (sorted order) claims it, the other
    // is skipped — one key is one project (PROTO-13).
    try std.testing.expectEqual(@as(usize, 1), projects.len);
    try std.testing.expectEqualStrings("a_b", projects[0].key);
}

test "scanProject tables .zig files and never descends a prune name" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    // A .git nested at depth and a .zig-cache sibling: both carry .zig files
    // that must never reach the stat table.
    for ([_][]const u8{ "lib.zig", ".git/obj.zig", "sub/.zig-cache/deep.zig", "notes.txt", "sub/real.zig" }) |rel| {
        const parent = std.fs.path.dirname(rel);
        if (parent) |p| {
            tmp.dir.createDirPath(io, p) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        const f = try tmp.dir.createFile(io, rel, .{});
        defer f.close(io);
        if (std.mem.endsWith(u8, rel, ".zig")) {
            // Every .zig file carries a documented declaration: the noise
            // directories' records are the failure being pinned.
            var buf: [64]u8 = undefined;
            var w = f.writer(io, &buf);
            try w.interface.writeAll("/// documented fn\npub fn f() void {}\n");
            try w.flush();
        }
    }

    const s = try createState(gpa, .{
        .key = "p",
        .root = root,
        .includes = &.{},
        .excludes = &default_excludes,
    });
    defer dropState(gpa, s);
    try std.testing.expect(s.dirty);
    try scanProject(io, gpa, s);
    s.dirty = false;
    try std.testing.expectEqual(@as(usize, 2), s.stats.count()); // lib.zig + sub/real.zig
    try std.testing.expect(!s.dirty);
    // The same paths the poll prunes must also be refused at index time:
    // a nested `.git/…` that indexed once and was never tabled again would
    // serve records no detection could ever refresh or remove.
    try indexNow(io, gpa, s);
    try std.testing.expectEqual(@as(usize, 2), s.records.len);
    try std.testing.expectEqual(@as(usize, 2), s.status.files_total);
    for (s.records) |rec| {
        try std.testing.expect(std.mem.indexOf(u8, rec.path, ".git") == null);
        try std.testing.expect(std.mem.indexOf(u8, rec.path, ".zig-cache") == null);
    }
    // A second scan with no writes changes nothing.
    try scanProject(io, gpa, s);
    try std.testing.expect(!s.dirty);
    // An edit — ctime only — is enough to mark dirty.
    {
        const f = try tmp.dir.createFile(io, "lib.zig", .{});
        defer f.close(io);
        var buf: [64]u8 = undefined;
        var w = f.writer(io, &buf);
        try w.interface.writeAll("/// documented fn edited\npub fn f() void {}\n");
        try w.flush();
    }
    try scanProject(io, gpa, s);
    try std.testing.expect(s.dirty);
}
