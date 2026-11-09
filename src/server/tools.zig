//! Tool handlers: advice lookup, approach recommendation and doc retrieval
//! (PLAN §7.1).
//!
//! All five tools are read-only. A tool-level failure ("nothing matched") is a
//! normal result with `isError: true`; only dispatch failures (unknown tool,
//! invalid arguments) are JSON-RPC errors.

const std = @import("std");
const registry = @import("registry.zig");
const corpus_module = @import("../advice/corpus.zig");
const render = @import("../advice/render.zig");
const rules_module = @import("../advice/rules.zig");
const docs_search = @import("../docs/search.zig");
const text_util = @import("../util/text.zig");

pub const Context = registry.Context;
pub const ToolOutcome = registry.ToolOutcome;
pub const ToolError = registry.ToolError;

pub const advice_lookup_input = registry.Schema{ .fields = &.{
    .{ .name = "concept", .kind = .string, .required = false, .description = "Concept id such as P03." },
    .{ .name = "question", .kind = .string, .required = false, .description = "Free-text question matched against the advice records." },
} };

pub const advice_lookup_output = registry.Schema{ .fields = &.{
    .{ .name = "query", .kind = .string },
    .{ .name = "matches", .kind = .array },
} };

pub const recommend_approach_input = registry.Schema{ .fields = &.{
    .{ .name = "signals", .kind = .string_array, .description = "Observed signals from the system under discussion." },
    .{ .name = "constraints", .kind = .object, .required = false, .description = "Additional constraints, kept opaque." },
} };

pub const recommend_approach_output = registry.Schema{ .fields = &.{
    .{ .name = "signals", .kind = .string_array },
    .{ .name = "matches", .kind = .array },
} };

pub const doc_search_input = registry.Schema{ .fields = &.{
    .{ .name = "query", .kind = .string, .description = "Symbol, path or documentation text to look for." },
    .{ .name = "project", .kind = .string, .required = false, .description = "Restrict the search to one project." },
    .{ .name = "limit", .kind = .integer, .required = false, .description = "Maximum number of results (default 20, max 100)." },
} };

pub const doc_search_output = registry.Schema{ .fields = &.{
    .{ .name = "query", .kind = .string },
    .{ .name = "count", .kind = .integer },
    .{ .name = "results", .kind = .array },
} };

pub const doc_get_input = registry.Schema{ .fields = &.{
    .{ .name = "project", .kind = .string, .description = "Project key, e.g. zig-std." },
    .{ .name = "symbol", .kind = .string, .description = "Fully qualified symbol path, e.g. mem.copyForwards." },
} };

pub const doc_get_output = registry.Schema{ .fields = &.{
    .{ .name = "project", .kind = .string },
    .{ .name = "commit", .kind = .string },
    .{ .name = "path", .kind = .string },
    .{ .name = "line", .kind = .integer },
    .{ .name = "kind", .kind = .string },
    .{ .name = "symbol", .kind = .string },
    .{ .name = "container", .kind = .string },
    .{ .name = "doc", .kind = .string },
    .{ .name = "doc_hash", .kind = .string },
} };

pub const doc_import_status_input = registry.Schema{ .fields = &.{} };

pub const doc_import_status_output = registry.Schema{ .fields = &.{
    .{ .name = "index_path", .kind = .string, .required = false },
    .{ .name = "index_records", .kind = .integer },
    .{ .name = "projects", .kind = .array },
} };

fn toolFailure(gpa: std.mem.Allocator, message: []const u8) ToolError!ToolOutcome {
    const text = try gpa.dupe(u8, message);
    return .{ .text = text, .is_error = true };
}

/// `advice_lookup`: exact concept lookup or question matching.
pub fn adviceLookup(ctx: *Context, args: std.json.Value) ToolError!ToolOutcome {
    registry.validate(advice_lookup_input, args) catch return error.InvalidParams;
    const gpa = ctx.pool.allocator();

    const concept = registry.getString(args, "concept");
    const question = registry.getString(args, "question");
    if (concept == null and question == null) return error.InvalidParams;

    var matches: std.json.Array = .init(gpa);
    var text: std.ArrayList(u8) = .empty;

    if (concept) |id| {
        const pattern = ctx.corpus.findPattern(id) orelse {
            return toolFailure(gpa, try std.fmt.allocPrint(gpa, "No advice record with concept id '{s}'.", .{id}));
        };
        try matches.append(try render.patternValue(gpa, pattern));
        try text.appendSlice(gpa, try render.patternText(gpa, pattern));
    } else {
        const query = question.?;
        const scored = try scorePatterns(ctx, gpa, query);
        if (scored.len == 0) {
            return toolFailure(gpa, try std.fmt.allocPrint(gpa, "No advice record matched the question '{s}'.", .{query}));
        }
        for (scored) |entry| {
            try matches.append(try render.patternValue(gpa, entry.pattern));
            try text.appendSlice(gpa, try render.patternText(gpa, entry.pattern));
        }
    }

    var structured: std.json.ObjectMap = .{};
    try structured.put(gpa, "query", .{ .string = concept orelse question.? });
    try structured.put(gpa, "matches", .{ .array = matches });

    return .{
        .text = try text.toOwnedSlice(gpa),
        .structured = .{ .object = structured },
    };
}

pub const ScoredPattern = struct {
    pattern: *const corpus_module.Pattern,
    score: usize,
};

/// The advice records that match a free-text question, best match first.
pub fn matchingPatterns(ctx: *Context, gpa: std.mem.Allocator, question: []const u8) ![]ScoredPattern {
    return scorePatterns(ctx, gpa, question);
}

fn scorePatterns(ctx: *Context, gpa: std.mem.Allocator, question: []const u8) ![]ScoredPattern {
    const query_tokens = try text_util.tokenize(gpa, question);

    var scored: std.ArrayList(ScoredPattern) = .empty;
    for (ctx.corpus.patterns) |*pattern| {
        var haystack: std.ArrayList(u8) = .empty;
        try haystack.appendSlice(gpa, pattern.name);
        try haystack.appendSlice(gpa, " ");
        try haystack.appendSlice(gpa, pattern.what_data_controls);
        for (pattern.facts) |fact| {
            try haystack.appendSlice(gpa, " ");
            try haystack.appendSlice(gpa, fact.text);
        }
        for (pattern.candidate_uses) |use| {
            try haystack.appendSlice(gpa, " ");
            try haystack.appendSlice(gpa, use);
        }
        const pattern_tokens = try text_util.tokenize(gpa, haystack.items);

        var overlap: usize = 0;
        for (query_tokens) |token| {
            for (pattern_tokens) |candidate| {
                if (std.mem.eql(u8, token, candidate)) {
                    overlap += 1;
                    break;
                }
            }
        }
        if (overlap == 0) continue;
        try scored.append(gpa, .{ .pattern = pattern, .score = overlap });
    }

    std.mem.sort(ScoredPattern, scored.items, {}, struct {
        fn lessThan(_: void, a: ScoredPattern, b: ScoredPattern) bool {
            if (a.score != b.score) return a.score > b.score;
            return std.mem.lessThan(u8, a.pattern.id, b.pattern.id);
        }
    }.lessThan);

    if (scored.items.len > 5) scored.shrinkRetainingCapacity(5);
    return scored.toOwnedSlice(gpa);
}

/// `recommend_approach`: applies the SELECT rules as data.
pub fn recommendApproach(ctx: *Context, args: std.json.Value) ToolError!ToolOutcome {
    registry.validate(recommend_approach_input, args) catch return error.InvalidParams;
    const gpa = ctx.pool.allocator();

    const signals = (registry.getStringArray(gpa, args, "signals") catch return error.InvalidParams) orelse
        return error.InvalidParams;
    if (signals.len == 0) return error.InvalidParams;

    const matches = try ctx.matcher.matchSignals(gpa, signals);
    if (matches.len == 0) {
        return toolFailure(gpa, "No decision rule matched the given signals.");
    }

    var structured_matches: std.json.Array = .init(gpa);
    var text: std.ArrayList(u8) = .empty;
    for (matches) |match| {
        var item: std.json.ObjectMap = .{};
        try item.put(gpa, "rule_id", .{ .string = match.rule.id });
        try item.put(gpa, "condition", .{ .string = match.rule.condition });
        var consider: std.json.Array = .init(gpa);
        for (match.rule.then.consider) |pattern_id| {
            try consider.append(.{ .string = pattern_id });
        }
        try item.put(gpa, "consider", .{ .array = consider });
        if (match.rule.then.and_only_if) |constraint| {
            try item.put(gpa, "and_only_if", .{ .string = constraint });
        }
        try item.put(gpa, "evidence", .{ .string = match.rule.evidence.label() });
        try item.put(gpa, "score", .{ .float = match.score });
        try structured_matches.append(.{ .object = item });

        try text.appendSlice(gpa, try render.ruleText(gpa, match.rule));
    }

    var signal_values: std.json.Array = .init(gpa);
    for (signals) |signal| try signal_values.append(.{ .string = signal });

    var structured: std.json.ObjectMap = .{};
    try structured.put(gpa, "signals", .{ .array = signal_values });
    try structured.put(gpa, "matches", .{ .array = structured_matches });

    return .{
        .text = try text.toOwnedSlice(gpa),
        .structured = .{ .object = structured },
    };
}

/// `doc_search`: symbol / path / text search over the imported index.
pub fn docSearch(ctx: *Context, args: std.json.Value) ToolError!ToolOutcome {
    registry.validate(doc_search_input, args) catch return error.InvalidParams;
    const gpa = ctx.pool.allocator();

    const query = registry.getString(args, "query") orelse return error.InvalidParams;
    if (query.len == 0) return error.InvalidParams;
    const project = registry.getString(args, "project");
    const limit = registry.getInteger(args, "limit");

    const snapshot = ctx.docs.snapshot();
    defer snapshot.deinit();

    const effective_limit: usize = if (limit) |value|
        (if (value <= 0) docs_search.default_limit else @min(@as(usize, @intCast(value)), docs_search.max_limit))
    else
        docs_search.default_limit;

    const matches = try docs_search.search(gpa, &snapshot.index.columnar, query, project, effective_limit);
    if (matches.len == 0) {
        return toolFailure(gpa, try std.fmt.allocPrint(gpa, "No indexed documentation matched '{s}'.", .{query}));
    }

    var results: std.json.Array = .init(gpa);
    var text: std.ArrayList(u8) = .empty;
    for (matches) |match| {
        const columnar = &snapshot.index.columnar;
        var item: std.json.ObjectMap = .{};
        try item.put(gpa, "project", .{ .string = columnar.projectAt(match.record_index) });
        try item.put(gpa, "commit", .{ .string = columnar.commitAt(match.record_index) });
        try item.put(gpa, "path", .{ .string = columnar.pathAt(match.record_index) });
        try item.put(gpa, "line", .{ .integer = columnar.lines[match.record_index] });
        try item.put(gpa, "kind", .{ .string = columnar.kinds[match.record_index].label() });
        try item.put(gpa, "symbol", .{ .string = columnar.symbolAt(match.record_index) });
        try item.put(gpa, "container", .{ .string = columnar.containerAt(match.record_index) });
        try item.put(gpa, "doc", .{ .string = columnar.docAt(match.record_index) });
        try results.append(.{ .object = item });

        try text.print(gpa, "{s}:{d} {s} — {s}\n", .{
            columnar.pathAt(match.record_index),
            columnar.lines[match.record_index],
            columnar.symbolAt(match.record_index),
            columnar.docAt(match.record_index),
        });
    }

    var structured: std.json.ObjectMap = .{};
    try structured.put(gpa, "query", .{ .string = query });
    try structured.put(gpa, "count", .{ .integer = @intCast(matches.len) });
    try structured.put(gpa, "results", .{ .array = results });

    return .{
        .text = try text.toOwnedSlice(gpa),
        .structured = .{ .object = structured },
    };
}

/// `doc_get`: the full documentation of one symbol.
pub fn docGet(ctx: *Context, args: std.json.Value) ToolError!ToolOutcome {
    registry.validate(doc_get_input, args) catch return error.InvalidParams;
    const gpa = ctx.pool.allocator();

    const project = registry.getString(args, "project") orelse return error.InvalidParams;
    const symbol = registry.getString(args, "symbol") orelse return error.InvalidParams;

    const snapshot = ctx.docs.snapshot();
    defer snapshot.deinit();
    const columnar = &snapshot.index.columnar;

    var found: ?usize = null;
    for (0..columnar.count()) |record| {
        if (!text_util.eqlIgnoreCase(columnar.projectAt(record), project)) continue;
        if (!text_util.eqlIgnoreCase(columnar.symbolAt(record), symbol)) continue;
        found = record;
        break;
    }

    const record = found orelse {
        return toolFailure(gpa, try std.fmt.allocPrint(gpa, "No indexed symbol '{s}' in project '{s}'.", .{ symbol, project }));
    };

    var structured: std.json.ObjectMap = .{};
    try structured.put(gpa, "project", .{ .string = columnar.projectAt(record) });
    try structured.put(gpa, "commit", .{ .string = columnar.commitAt(record) });
    try structured.put(gpa, "path", .{ .string = columnar.pathAt(record) });
    try structured.put(gpa, "line", .{ .integer = columnar.lines[record] });
    try structured.put(gpa, "kind", .{ .string = columnar.kinds[record].label() });
    try structured.put(gpa, "symbol", .{ .string = columnar.symbolAt(record) });
    try structured.put(gpa, "container", .{ .string = columnar.containerAt(record) });
    try structured.put(gpa, "doc", .{ .string = columnar.docAt(record) });
    try structured.put(gpa, "doc_hash", .{ .string = columnar.docHashAt(record) });

    const text = try std.fmt.allocPrint(gpa, "{s}:{d} {s}\n\n{s}\n", .{
        columnar.pathAt(record),
        columnar.lines[record],
        columnar.symbolAt(record),
        columnar.docAt(record),
    });

    return .{ .text = text, .structured = .{ .object = structured } };
}

/// `tools/list`: the advertised capability table.
pub fn list(ctx: *registry.Context) !registry.Result {
    const gpa = ctx.pool.allocator();

    var tools: std.json.Array = .init(gpa);
    for (registry.tool_specs) |spec| {
        var object: std.json.ObjectMap = .{};
        try object.put(gpa, "name", .{ .string = spec.name });
        try object.put(gpa, "description", .{ .string = spec.description });
        try object.put(gpa, "inputSchema", try registry.schemaFrom(gpa, spec.input));
        try object.put(gpa, "outputSchema", try registry.schemaFrom(gpa, spec.output));

        var annotations: std.json.ObjectMap = .{};
        try annotations.put(gpa, "readOnlyHint", .{ .bool = true });
        try annotations.put(gpa, "destructiveHint", .{ .bool = false });
        try annotations.put(gpa, "idempotentHint", .{ .bool = true });
        try annotations.put(gpa, "openWorldHint", .{ .bool = false });
        try object.put(gpa, "annotations", .{ .object = annotations });

        try tools.append(.{ .object = object });
    }

    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "tools", .{ .array = tools });
    return .{ .value = .{ .object = object }, .cache = registry.advice_cache };
}

/// Builds the MCP tool result envelope for a handler outcome.
pub fn result(ctx: *registry.Context, outcome: ToolOutcome) !registry.Result {
    const gpa = ctx.pool.allocator();

    var content: std.json.ObjectMap = .{};
    try content.put(gpa, "type", .{ .string = "text" });
    try content.put(gpa, "text", .{ .string = outcome.text });

    var contents: std.json.Array = .init(gpa);
    try contents.append(.{ .object = content });

    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "content", .{ .array = contents });
    if (outcome.structured) |structured| try object.put(gpa, "structuredContent", structured);
    try object.put(gpa, "isError", .{ .bool = outcome.is_error });
    return .{ .value = .{ .object = object }, .cache = null };
}

/// The indexer's status sidecar lives next to the index: `index.jsonl` becomes
/// `index.status.json` (the same rule the indexer uses).
fn statusSidecarPath(gpa: std.mem.Allocator, index_path: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, index_path, ".jsonl")) {
        return std.fmt.allocPrint(
            gpa,
            "{s}.status.json",
            .{index_path[0 .. index_path.len - ".jsonl".len]},
        );
    }
    return std.fmt.allocPrint(gpa, "{s}.status.json", .{index_path});
}

/// Loads the status sidecar, if the indexer wrote one.
fn loadStatusSidecar(ctx: *Context, gpa: std.mem.Allocator) !?std.json.Value {
    const index_path = ctx.index_path orelse return null;
    const sidecar_path = try statusSidecarPath(gpa, index_path);
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(
        ctx.io,
        sidecar_path,
        gpa,
        .limited(16 * 1024 * 1024),
        .of(u8),
        null,
    ) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, bytes, .{}) catch return null;
    return parsed.value;
}

/// The sidecar entry of one project, if the sidecar has one.
fn sidecarProject(value: std.json.Value, name: []const u8) ?std.json.ObjectMap {
    if (value != .object) return null;
    const projects = value.object.get("projects") orelse return null;
    if (projects != .object) return null;
    const entry = projects.object.get(name) orelse return null;
    if (entry != .object) return null;
    return entry.object;
}

/// `doc_import_status`: what the index currently holds.
pub fn docImportStatus(ctx: *Context, args: std.json.Value) ToolError!ToolOutcome {
    _ = args;
    registry.validate(doc_import_status_input, null) catch return error.InvalidParams;
    const gpa = ctx.pool.allocator();

    const snapshot = ctx.docs.snapshot();
    defer snapshot.deinit();
    const columnar = &snapshot.index.columnar;

    const ProjectStat = struct {
        name: []const u8,
        commit: []const u8,
        records: usize,
    };

    var stats: std.ArrayList(ProjectStat) = .empty;
    for (0..columnar.count()) |record| {
        const name = columnar.projectAt(record);
        const commit = columnar.commitAt(record);
        var found = false;
        for (stats.items) |*stat| {
            if (std.mem.eql(u8, stat.name, name)) {
                stat.records += 1;
                found = true;
                break;
            }
        }
        if (!found) {
            try stats.append(gpa, .{ .name = name, .commit = commit, .records = 1 });
        }
    }
    std.mem.sort(ProjectStat, stats.items, {}, struct {
        fn lessThan(_: void, a: ProjectStat, b: ProjectStat) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var project_values: std.json.Array = .init(gpa);
    var text: std.ArrayList(u8) = .empty;
    const sidecar = try loadStatusSidecar(ctx, gpa);
    for (stats.items) |stat| {
        var item: std.json.ObjectMap = .{};
        try item.put(gpa, "project", .{ .string = stat.name });
        try item.put(gpa, "commit", .{ .string = stat.commit });
        try item.put(gpa, "records", .{ .integer = @intCast(stat.records) });
        var degraded_files: ?usize = null;
        if (sidecar) |value| {
            if (sidecarProject(value, stat.name)) |entry| {
                if (entry.get("files_total")) |files_total| {
                    try item.put(gpa, "files_total", files_total);
                }
                if (entry.get("files_degraded")) |files_degraded| {
                    try item.put(gpa, "files_degraded", files_degraded);
                    if (files_degraded == .integer) degraded_files = @intCast(files_degraded.integer);
                }
                if (entry.get("degraded")) |degraded| {
                    try item.put(gpa, "degraded", degraded);
                }
            }
        }
        try project_values.append(.{ .object = item });
        try text.print(gpa, "{s}: commit {s}, {d} records", .{ stat.name, stat.commit, stat.records });
        if (degraded_files) |count| {
            try text.print(gpa, ", {d} degraded files", .{count});
        }
        try text.appendSlice(gpa, "\n");
    }

    var structured: std.json.ObjectMap = .{};
    if (ctx.index_path) |path| {
        try structured.put(gpa, "index_path", .{ .string = path });
    }
    try structured.put(gpa, "index_records", .{ .integer = @intCast(columnar.count()) });
    try structured.put(gpa, "projects", .{ .array = project_values });

    return .{ .text = try text.toOwnedSlice(gpa), .structured = .{ .object = structured } };
}
