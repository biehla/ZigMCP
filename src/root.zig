//! Test aggregator: pulls every module's test blocks into one test binary.

const std = @import("std");

test {
    _ = @import("advice/corpus.zig");
    _ = @import("advice/render.zig");
    _ = @import("advice/rules.zig");
    _ = @import("docs/columnar.zig");
    _ = @import("docs/index.zig");
    _ = @import("docs/projects.zig");
    _ = @import("docs/reload.zig");
    _ = @import("docs/search.zig");
    _ = @import("protocol/errors.zig");
    _ = @import("protocol/json_rpc.zig");
    _ = @import("protocol/meta.zig");
    _ = @import("protocol/response.zig");
    _ = @import("server/log.zig");
    _ = @import("server/prompts.zig");
    _ = @import("server/registry.zig");
    _ = @import("server/resources.zig");
    _ = @import("server/tools.zig");
    _ = @import("transport/stdio.zig");
    _ = @import("util/arena_pool.zig");
    _ = @import("util/sleep.zig");
    // `data/sources.zon` plan parsing (CI-4/CI-5); its CLI is
    // `tools/sources_plan.zig`, run as `zig build plan-sources`.
    _ = @import("util/sources.zig");
    _ = @import("util/text.zig");
    // The workflow trigger/expression check (CI-1); its CLI is
    // `tools/workflow_check.zig`.
    _ = @import("util/workflow.zig");
    // Cross-cutting handler tests: they need the real corpus and a loaded doc
    // index, so they keep their own harness. Part of the main suite.
    _ = @import("regressions_test.zig");
}

test "DOC-2: the readme embeds client-config.json verbatim" {
    // One canonical snippet, read by the readme and by the release workflow.
    // A hand-edited copy in either place is drift the user would see.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const readme = try std.Io.Dir.cwd().readFileAllocOptions(io, "readme.md", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(readme);
    const canonical = try std.Io.Dir.cwd().readFileAllocOptions(io, "client-config.json", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(canonical);

    const fence = "```json\n";
    const fence_start = std.mem.indexOf(u8, readme, fence) orelse return error.MissingSnippet;
    const body_start = fence_start + fence.len;
    const body_end = std.mem.indexOfPos(u8, readme, body_start, "\n```") orelse return error.MissingSnippet;
    const embedded = readme[body_start..body_end];

    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, canonical, "\n"), embedded);
}

test "GUIDE-8: the limitation lists live only in PLAN.md" {
    // Three copies of the same list drift. `PLAN.md` is canonical; the other two
    // sections must be pointers, not lists, or a stale gap survives a fix.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try expectSectionIsPointer(io, gpa, "readme.md", "## Known limitations", "## ");
    try expectSectionIsPointer(io, gpa, "AGENTS.md", "### Known gaps", "### ");
}

fn expectSectionIsPointer(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    heading: []const u8,
    next_heading: []const u8,
) !void {
    const text = try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(text);

    const start = std.mem.indexOf(u8, text, heading) orelse return error.MissingHeading;
    const body_start = start + heading.len;
    const body_end = std.mem.indexOfPos(u8, text, body_start, next_heading) orelse text.len;
    const body = text[body_start..body_end];

    try std.testing.expect(std.mem.indexOf(u8, body, "PLAN.md") != null);
    if (std.mem.indexOf(u8, body, "\n- ") != null) {
        std.debug.print("{s}: the section under '{s}' restates the backlog; link to PLAN.md instead\n", .{ path, heading });
        return error.DuplicatedBacklog;
    }
}

/// Every file the doc tests scan for citations: the code that carries them and
/// the three documents that own the ids.
const citation_roots = [_][]const u8{ "src", "tools", "tests" };
const citation_files = [_][]const u8{ "AGENTS.md", "PLAN.md", "readme.md", "build.zig" };

/// Calls `visit` with the text of every citation root file and the named docs.
///
/// A walk rather than a list: a new module that cites an id is covered without
/// touching this test.
fn forEachCitationFile(
    io: std.Io,
    gpa: std.mem.Allocator,
    context: anytype,
    comptime visit: fn (@TypeOf(context), []const u8, []const u8) anyerror!void,
) !void {
    for (citation_roots) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = try std.fs.path.join(gpa, &.{ root, entry.path });
            defer gpa.free(path);
            const text = try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
            defer gpa.free(text);
            try visit(context, path, text);
        }
    }
    for (citation_files) |path| {
        const text = try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
        defer gpa.free(text);
        try visit(context, path, text);
    }
}

/// What a citation sweep accumulates, so a scan that matches nothing fails
/// instead of passing as a tautology.
const SectionScan = struct {
    agents: *std.AutoHashMap(u32, void),
    plan: *std.AutoHashMap(u32, void),
    citations: usize = 0,
    bad: usize = 0,
};

/// Which document a section number belongs to.
///
/// The tree writes both `` `AGENTS.md` §5 `` and "§14 of `AGENTS.md`", and
/// `PLAN.md` cites its own sections the same way, so the document name may come
/// before the sign or after it.
fn citationTarget(around: []const u8, path: []const u8) enum { agents, plan } {
    if (std.mem.indexOf(u8, around, "AGENTS.md") != null) return .agents;
    if (std.mem.indexOf(u8, around, "PLAN.md") != null) return .plan;
    if (std.mem.eql(u8, path, "AGENTS.md")) return .agents;
    return .plan;
}

const DecisionScan = struct {
    known: *std.AutoHashMap(u32, void),
    refs: usize = 0,
};

const IdScan = struct {
    known: *std.StringHashMap(void),
    checked: usize = 0,
};

/// The `## N.` numbers of a markdown document.
fn headingNumbers(gpa: std.mem.Allocator, text: []const u8, prefix: []const u8) !std.AutoHashMap(u32, void) {
    var numbers: std.AutoHashMap(u32, void) = .init(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var i = prefix.len;
        const start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == start) continue;
        const n = std.fmt.parseInt(u32, line[start..i], 10) catch continue;
        try numbers.put(n, {});
    }
    return numbers;
}

/// Every `D<n>` and `<family>-<n>` id a file mentions.
fn collectIds(gpa: std.mem.Allocator, text: []const u8, out: *std.StringHashMap(void)) !void {
    const families = [_][]const u8{
        "CI-", "PROTO-", "SRV-", "IDX-", "REL-", "DOC-", "GUIDE-", "TEST-", "ENV-", "PERF-",
    };
    for (families) |family| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, text, cursor, family)) |pos| {
            var end = pos + family.len;
            while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
            if (end > pos + family.len) {
                const id = text[pos..end];
                // `put` keeps the stored key when it already exists, so a
                // second dupe for the same id would leak.
                if (!out.contains(id)) try out.put(try gpa.dupe(u8, id), {});
                cursor = end;
            } else {
                cursor = pos + family.len;
            }
        }
    }
}

test "every AGENTS.md section citation resolves" {
    // §-numbers are load-bearing: thirty-five files cite them, and a rewrite that
    // renumbers a section leaves the tree pointing at the wrong topic. This is
    // the check a heading-only review cannot do.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const agents = try std.Io.Dir.cwd().readFileAllocOptions(io, "AGENTS.md", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(agents);
    var sections = try headingNumbers(gpa, agents, "## ");
    defer sections.deinit();
    try std.testing.expect(sections.count() >= 16);

    const plan = try std.Io.Dir.cwd().readFileAllocOptions(io, "PLAN.md", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(plan);
    var plan_sections = try headingNumbers(gpa, plan, "## ");
    defer plan_sections.deinit();
    try std.testing.expect(plan_sections.count() >= 4);

    // A scan that finds nothing passes vacuously, so the count is asserted too.
    var scan = SectionScan{ .agents = &sections, .plan = &plan_sections };
    try forEachCitationFile(io, gpa, &scan, struct {
        fn visit(state: *SectionScan, path: []const u8, text: []const u8) anyerror!void {
            var cursor: usize = 0;
            while (std.mem.indexOfPos(u8, text, cursor, "§")) |pos| {
                var i = pos + "§".len;
                const start = i;
                while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
                if (i == start) {
                    cursor = i;
                    continue;
                }
                const n = std.fmt.parseInt(u32, text[start..i], 10) catch {
                    cursor = i;
                    continue;
                };
                const window_start = pos - @min(pos, 24);
                const window_end = @min(text.len, i + 16);
                const target = citationTarget(text[window_start..window_end], path);
                const numbers = switch (target) {
                    .agents => state.agents,
                    .plan => state.plan,
                };
                if (!numbers.contains(n)) {
                    // Every offender, not just the first: one run names them all.
                    std.debug.print(
                        "{s}:{d}: cites §{d} of {s}, which is not a heading there\n",
                        .{ path, std.mem.count(u8, text[0..pos], "\n") + 1, n, if (target == .agents) "AGENTS.md" else "PLAN.md" },
                    );
                    state.bad += 1;
                }
                state.citations += 1;
                cursor = i;
            }
        }
    }.visit);
    try std.testing.expect(scan.citations >= 60);
    if (scan.bad != 0) return error.DanglingSectionCitation;
}

test "every decision reference resolves to a §3 row" {
    // `Dn` is a decision id, not a section number: a renumbered or deleted row
    // would leave "(D8)" in a comment pointing at nothing.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const agents = try std.Io.Dir.cwd().readFileAllocOptions(io, "AGENTS.md", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(agents);

    var decisions: std.AutoHashMap(u32, void) = .init(gpa);
    defer decisions.deinit();
    var lines = std.mem.splitScalar(u8, agents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "|D")) continue;
        var i: usize = 2;
        const start = i;
        while (i < line.len and std.ascii.isDigit(line[i])) i += 1;
        if (i == start) continue;
        const n = std.fmt.parseInt(u32, line[start..i], 10) catch continue;
        try decisions.put(n, {});
    }
    try std.testing.expectEqual(@as(u32, 10), decisions.count()); // D1..D10

    var scan = DecisionScan{ .known = &decisions };
    try forEachCitationFile(io, gpa, &scan, struct {
        fn visit(state: *DecisionScan, path: []const u8, text: []const u8) anyerror!void {
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                if (text[i] != 'D') continue;
                // A decision id is a boundary token: `MD5` and `IDX-1` are not.
                if (i > 0 and std.ascii.isAlphanumeric(text[i - 1])) continue;
                var end = i + 1;
                while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
                if (end == i + 1) continue;
                const n = std.fmt.parseInt(u32, text[i + 1 .. end], 10) catch continue;
                if (!state.known.contains(n)) {
                    std.debug.print("{s}: cites D{d}, which is not a decision in AGENTS.md §3\n", .{ path, n });
                    return error.DanglingDecisionReference;
                }
                state.refs += 1;
                i = end - 1;
            }
        }
    }.visit);
    try std.testing.expect(scan.refs >= 10);
}

test "PLAN.md knows every id the tree cites" {
    // The ledger is the one place an id's option, commit and check live. An id
    // cited in a comment but absent here is work with no record, or a typo.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const plan = try std.Io.Dir.cwd().readFileAllocOptions(io, "PLAN.md", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(plan);
    var known: std.StringHashMap(void) = .init(gpa);
    defer {
        var it = known.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        known.deinit();
    }
    try collectIds(gpa, plan, &known);
    try std.testing.expect(known.count() > 50);

    var scan = IdScan{ .known = &known };
    try forEachCitationFile(io, gpa, &scan, struct {
        fn visit(state: *IdScan, path: []const u8, text: []const u8) anyerror!void {
            var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena_state.deinit();
            var cited: std.StringHashMap(void) = .init(arena_state.allocator());
            try collectIds(arena_state.allocator(), text, &cited);

            var it = cited.keyIterator();
            while (it.next()) |id| {
                if (!state.known.contains(id.*)) {
                    std.debug.print("{s}: cites {s}, which PLAN.md does not record\n", .{ path, id.* });
                    return error.UnknownId;
                }
                state.checked += 1;
            }
        }
    }.visit);
    try std.testing.expect(scan.checked >= 30);
}

test "PLAN.md's ledger has one row per id" {
    // A duplicated row means two fixes claim the same id and one of them is not
    // recorded where a reader will look.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const plan = try std.Io.Dir.cwd().readFileAllocOptions(io, "PLAN.md", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(plan);

    var seen: std.StringHashMap(void) = .init(gpa);
    defer {
        var it = seen.keyIterator();
        while (it.next()) |key| gpa.free(key.*);
        seen.deinit();
    }

    var lines = std.mem.splitScalar(u8, plan, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "|")) continue;
        // First cell only, and only when it is exactly an id: a campaign row
        // starts with the id but carries prose after it.
        const next_pipe = std.mem.indexOfScalarPos(u8, line, 1, '|') orelse continue;
        const cell = std.mem.trim(u8, line[1..next_pipe], " ");
        if (!isExactId(cell)) continue;
        const key = try gpa.dupe(u8, cell);
        if (seen.contains(key)) {
            std.debug.print("PLAN.md: {s} appears in more than one ledger row\n", .{key});
            gpa.free(key);
            return error.DuplicateLedgerRow;
        }
        try seen.put(key, {});
    }
    try std.testing.expect(seen.count() > 70);
}

fn isExactId(cell: []const u8) bool {
    const families = [_][]const u8{
        "CI-", "PROTO-", "SRV-", "IDX-", "REL-", "DOC-", "GUIDE-", "TEST-", "ENV-", "PERF-",
    };
    for (families) |family| {
        if (!std.mem.startsWith(u8, cell, family)) continue;
        if (cell.len == family.len) return false;
        for (cell[family.len..]) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    return false;
}

test "GUIDE-1: every src and tools file opens with a //! header" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var missing: usize = 0;
    for ([_][]const u8{ "src", "tools" }) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = try std.fs.path.join(gpa, &.{ root, entry.path });
            defer gpa.free(path);
            const source = try std.Io.Dir.cwd().readFileAllocOptions(
                io,
                path,
                gpa,
                .unlimited,
                .of(u8),
                0,
            );
            defer gpa.free(source);
            if (!std.mem.startsWith(u8, source, "//!")) {
                // Every offender, not just the first: one run names them all.
                std.debug.print("missing //! header: {s}\n", .{path});
                missing += 1;
            }
        }
    }
    if (missing != 0) return error.MissingModuleHeader;
}
