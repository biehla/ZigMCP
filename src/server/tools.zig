//! Tool handlers: advice lookup, approach recommendation and doc retrieval
//! (AGENTS.md §5).
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
const docs_columnar = @import("../docs/columnar.zig");
const docs_projects = @import("../docs/projects.zig");
const text_util = @import("../util/text.zig");
const json_array = @import("../util/json_array.zig");

pub const Context = registry.Context;
pub const ToolOutcome = registry.ToolOutcome;
pub const ToolError = registry.ToolError;

pub const advice_lookup_input = registry.Schema{ .fields = &.{
    .{ .name = "concept", .kind = .string, .required = false, .description = "Concept id such as P03." },
    .{ .name = "question", .kind = .string, .required = false, .description = "Free-text question matched against the advice records." },
} };

/// How many pattern records question mode returns before it truncates.
pub const max_advice_matches: usize = 5;

/// How many path-qualified symbol suggestions a `doc_get` miss reports. The
/// list is a next step, not a result set, so it stays small.
pub const max_get_candidates: usize = 5;

pub const advice_lookup_output = registry.Schema{
    .fields = &.{
        .{ .name = "query", .kind = .string },
        .{ .name = "matches", .kind = .array },
        // PROTO-7: the cap was silent, so a caller could not tell five matches
        // from five-and-more. Both members are always present.
        .{ .name = "match_count", .kind = .integer, .description = "Number of records in `matches`." },
        .{ .name = "truncated", .kind = .boolean, .description = "True when more records matched than were returned." },
    },
};

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
    .{ .name = "project", .kind = .string, .required = false, .description = "Restrict the search to one project. Case and - vs _ are forgiven when the spelling names exactly one indexed project." },
    .{ .name = "limit", .kind = .integer, .required = false, .description = "Maximum number of results (default 20, max 100)." },
} };

pub const doc_search_output = registry.Schema{ .fields = &.{
    .{ .name = "query", .kind = .string },
    .{ .name = "count", .kind = .integer },
    .{ .name = "results", .kind = .array },
} };

pub const doc_get_input = registry.Schema{ .fields = &.{
    .{ .name = "project", .kind = .string, .description = "Project key, e.g. zig_std. Case and - vs _ are forgiven when the spelling names exactly one indexed project." },
    .{ .name = "symbol", .kind = .string, .description = "Path-qualified symbol as the index stores it, e.g. lib.std.mem.copyForwards. Case is ignored, and a shorter dotted tail (mem.copyForwards) resolves when exactly one stored symbol ends with it; otherwise a miss lists the closest stored symbols." },
} };

pub const doc_get_output = registry.Schema{
    .fields = &.{
        // `found` is the only always-present member: a "no such symbol" result is
        // still shaped like this schema (PROTO-12).
        .{ .name = "found", .kind = .boolean, .description = "True when the symbol is present in the index." },
        .{ .name = "project", .kind = .string, .required = false },
        .{ .name = "symbol", .kind = .string, .required = false },
        .{ .name = "matches", .kind = .array, .required = false, .description = "Every record sharing the symbol path, ordered by path then line." },
        // PROTO-15: a miss used to be a dead end, so an unqualified spelling
        // (the readme's own example) looked like an absent symbol.
        .{ .name = "candidates", .kind = .string_array, .required = false, .description = "Path-qualified symbols the index holds that resemble `symbol`; present, possibly empty, only when `found` is false." },
        // PROTO-16: a shorter spelling that names exactly one stored symbol
        // resolves; the echo says so rather than pretending it was stored.
        .{ .name = "resolved_from", .kind = .string, .required = false, .description = "The argument as sent, present only when the stored symbol was reached by a unique dotted suffix; `matches[].symbol` holds the stored spelling." },
    },
};

pub const doc_import_status_input = registry.Schema{ .fields = &.{} };

pub const doc_import_status_output = registry.Schema{ .fields = &.{
    .{ .name = "index_path", .kind = .string, .required = false },
    .{ .name = "index_state", .kind = .string, .description = "unloaded, ok, or reload_failed." },
    .{ .name = "index_error", .kind = .string, .required = false, .description = "Why the last load failed." },
    .{ .name = "index_records", .kind = .integer },
    .{ .name = "projects", .kind = .array },
} };

/// A tool-level "no result": the call succeeded, the answer is "nothing
/// matched".
///
/// It still carries `structuredContent` shaped like the tool's output schema,
/// because a typed client cannot tell an empty result from a malformed one
/// otherwise (PROTO-12).
fn toolFailure(gpa: std.mem.Allocator, message: []const u8, structured: std.json.Value) ToolError!ToolOutcome {
    const text = try gpa.dupe(u8, message);
    return .{ .text = text, .structured = structured, .is_error = true };
}

/// `doc_search`'s shape with no results (PROTO-12).
fn emptySearchResult(gpa: std.mem.Allocator, query: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "query", .{ .string = query });
    try object.put(gpa, "count", .{ .integer = 0 });
    try object.put(gpa, "results", .{ .array = json_array.init(gpa) });
    return .{ .object = object };
}

/// `doc_get`'s shape with no result (PROTO-12). `candidates` is present here
/// and absent from a `found: true` result, which the schema allows because the
/// member is optional (PROTO-15).
fn emptyGetResult(
    gpa: std.mem.Allocator,
    project: []const u8,
    symbol: []const u8,
    candidates: []const []const u8,
) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "found", .{ .bool = false });
    try object.put(gpa, "project", .{ .string = project });
    try object.put(gpa, "symbol", .{ .string = symbol });
    var array: std.json.Array = json_array.init(gpa);
    for (candidates) |candidate| try json_array.append(&array, gpa, .{ .string = candidate });
    try object.put(gpa, "candidates", .{ .array = array });
    return .{ .object = object };
}

/// Joins project keys with ", ", stopping after `limit` of them with an
/// ellipsis so one message never grows without bound.
fn joinProjectKeys(gpa: std.mem.Allocator, keys: []const []const u8, limit: usize) ![]const u8 {
    var joined: std.ArrayList(u8) = .empty;
    for (keys, 0..) |key, position| {
        if (position == limit) {
            try joined.appendSlice(gpa, ", …");
            break;
        }
        if (position != 0) try joined.appendSlice(gpa, ", ");
        try joined.appendSlice(gpa, key);
    }
    return joined.toOwnedSlice(gpa);
}

/// The message for a project argument that names no project (PROTO-14).
fn projectMissMessage(
    gpa: std.mem.Allocator,
    index: *const docs_columnar.Columnar,
    wanted: []const u8,
) ![]const u8 {
    if (index.count() == 0) {
        return std.fmt.allocPrint(gpa, "No project '{s}': the doc index is empty.", .{wanted});
    }
    // One key past the cap tells us the list is longer than it prints.
    const keys = try docs_projects.known(gpa, index, docs_projects.max_listed + 1);
    const listed = try joinProjectKeys(gpa, keys, docs_projects.max_listed);
    return std.fmt.allocPrint(gpa, "No project '{s}' in the doc index. Known projects: {s}.", .{ wanted, listed });
}

/// The message for a project argument that two stored keys both answer
/// (PROTO-14): the keys are never merged.
fn ambiguousProjectMessage(
    gpa: std.mem.Allocator,
    wanted: []const u8,
    candidates: []const []const u8,
) ![]const u8 {
    const listed = try joinProjectKeys(gpa, candidates, candidates.len);
    return std.fmt.allocPrint(gpa, "Project '{s}' is ambiguous: {s}. Pass the exact key.", .{ wanted, listed });
}

/// `advice_lookup`'s shape with no matches.
fn emptyAdviceResult(gpa: std.mem.Allocator, query: []const u8) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "query", .{ .string = query });
    try object.put(gpa, "matches", .{ .array = json_array.init(gpa) });
    try object.put(gpa, "match_count", .{ .integer = 0 });
    try object.put(gpa, "truncated", .{ .bool = false });
    return .{ .object = object };
}

/// `advice_lookup`: exact concept lookup or question matching.
pub fn adviceLookup(ctx: *Context, args: std.json.Value) ToolError!ToolOutcome {
    registry.validate(advice_lookup_input, args) catch return error.InvalidParams;
    const gpa = ctx.pool.allocator();

    const concept = registry.getString(args, "concept");
    const question = registry.getString(args, "question");
    if (concept == null and question == null) return error.InvalidParams;
    // Two mutually exclusive selectors are never resolved silently (PROTO-6):
    // the caller asked for two different answers.
    if (concept != null and question != null) return error.InvalidParams;

    var matches: std.json.Array = json_array.init(gpa);
    var text: std.ArrayList(u8) = .empty;
    var truncated = false;

    if (concept) |id| {
        const pattern = ctx.corpus.findPattern(id) orelse {
            return toolFailure(
                gpa,
                try std.fmt.allocPrint(gpa, "No advice record with concept id '{s}'.", .{id}),
                try emptyAdviceResult(gpa, id),
            );
        };
        try json_array.append(&matches, gpa, try render.patternValue(gpa, pattern));
        try text.appendSlice(gpa, try render.patternText(gpa, pattern));
    } else {
        const query = question.?;
        const query_tokens = try text_util.tokenize(gpa, query);
        if (query_tokens.len > registry.max_query_tokens) return error.InvalidParams;
        const scored = try scorePatterns(ctx, gpa, query_tokens);
        if (scored.len == 0) {
            return toolFailure(
                gpa,
                try std.fmt.allocPrint(gpa, "No advice record matched the question '{s}'.", .{query}),
                try emptyAdviceResult(gpa, query),
            );
        }
        // The cap is reported, never silent (PROTO-7): `match_count` is what
        // was returned and `truncated` says more matched.
        const shown = @min(scored.len, max_advice_matches);
        truncated = scored.len > shown;
        for (scored[0..shown]) |entry| {
            try json_array.append(&matches, gpa, try render.patternValue(gpa, entry.pattern));
            try text.appendSlice(gpa, try render.patternText(gpa, entry.pattern));
        }
        if (truncated) {
            try text.print(gpa, "\n({d} more records matched; narrow the question to see them.)\n", .{scored.len - shown});
        }
    }

    var structured: std.json.ObjectMap = .{};
    try structured.put(gpa, "query", .{ .string = concept orelse question.? });
    try structured.put(gpa, "matches", .{ .array = matches });
    try structured.put(gpa, "match_count", .{ .integer = @intCast(matches.items.len) });
    try structured.put(gpa, "truncated", .{ .bool = truncated });

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
    const scored = try scorePatterns(ctx, gpa, try text_util.tokenize(gpa, question));
    // A prompt renders its matches inline, so it keeps the compact cap that
    // `advice_lookup` used to apply on its way out.
    if (scored.len > max_advice_matches) return scored[0..max_advice_matches];
    return scored;
}

fn scorePatterns(
    ctx: *Context,
    gpa: std.mem.Allocator,
    query_tokens: []const []const u8,
) ![]ScoredPattern {
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

    // Every match is returned: the handler decides how many to show and says
    // whether it truncated (PROTO-7).
    return scored.toOwnedSlice(gpa);
}

/// Collects the string leaves of an opaque `constraints` object so they can
/// take part in matching (PROTO-5). `validate` has already bounded the shape:
/// at most 64 members per container, four levels deep, 4 KiB per string.
fn collectConstraintStrings(
    gpa: std.mem.Allocator,
    value: std.json.Value,
    out: *std.ArrayList([]const u8),
) !void {
    switch (value) {
        .string => |text| try out.append(gpa, text),
        .array => |items| for (items.items) |item| try collectConstraintStrings(gpa, item, out),
        .object => |object| {
            var it = object.iterator();
            while (it.next()) |entry| try collectConstraintStrings(gpa, entry.value_ptr.*, out);
        },
        else => {},
    }
}

/// `recommend_approach`: applies the SELECT rules as data.
pub fn recommendApproach(ctx: *Context, args: std.json.Value) ToolError!ToolOutcome {
    registry.validate(recommend_approach_input, args) catch return error.InvalidParams;
    const gpa = ctx.pool.allocator();

    const signals = (registry.getStringArray(gpa, args, "signals") catch return error.InvalidParams) orelse
        return error.InvalidParams;
    if (signals.len == 0) return error.InvalidParams;

    // PROTO-5: `constraints` used to be accepted and ignored, so a caller
    // believed it filtered. Its string leaves join the signal set the matcher
    // sees; the echo still shows only what the caller sent as signals.
    var matcher_signals: std.ArrayList([]const u8) = .empty;
    try matcher_signals.appendSlice(gpa, signals);
    if (args.object.get("constraints")) |constraints| {
        try collectConstraintStrings(gpa, constraints, &matcher_signals);
    }

    // The matcher compares rule tokens against signal tokens: the same
    // client-chosen cost as a query, so the same bound applies (SRV-7).
    var signal_tokens: usize = 0;
    for (matcher_signals.items) |signal| signal_tokens += (try text_util.tokenize(gpa, signal)).len;
    if (signal_tokens > registry.max_query_tokens) return error.InvalidParams;

    const matches = try ctx.matcher.matchSignals(gpa, matcher_signals.items);
    if (matches.len == 0) {
        // Same defect class as PROTO-12: the tool declares an output schema, so
        // "no rule matched" still has to be shaped like one.
        var signal_values: std.json.Array = json_array.init(gpa);
        for (signals) |signal| try json_array.append(&signal_values, gpa, .{ .string = signal });
        var structured: std.json.ObjectMap = .{};
        try structured.put(gpa, "signals", .{ .array = signal_values });
        try structured.put(gpa, "matches", .{ .array = json_array.init(gpa) });
        return toolFailure(gpa, "No decision rule matched the given signals.", .{ .object = structured });
    }

    var structured_matches: std.json.Array = json_array.init(gpa);
    var text: std.ArrayList(u8) = .empty;
    for (matches) |match| {
        var item: std.json.ObjectMap = .{};
        try item.put(gpa, "rule_id", .{ .string = match.rule.id });
        try item.put(gpa, "condition", .{ .string = match.rule.condition });
        var consider: std.json.Array = json_array.init(gpa);
        for (match.rule.then.consider) |pattern_id| {
            try json_array.append(&consider, gpa, .{ .string = pattern_id });
        }
        try item.put(gpa, "consider", .{ .array = consider });
        if (match.rule.then.and_only_if) |constraint| {
            try item.put(gpa, "and_only_if", .{ .string = constraint });
        }
        try item.put(gpa, "evidence", .{ .string = match.rule.evidence.label() });
        try item.put(gpa, "score", .{ .float = match.score });
        try json_array.append(&structured_matches, gpa, .{ .object = item });

        try text.appendSlice(gpa, try render.ruleText(gpa, match.rule));
    }

    var signal_values: std.json.Array = json_array.init(gpa);
    for (signals) |signal| try json_array.append(&signal_values, gpa, .{ .string = signal });

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
    // Search compares every query token against every record, so a query with
    // thousands of tokens held the server for tens of seconds (SRV-7). The
    // token count is a documented input bound, not a silent truncation.
    const query_tokens = try text_util.tokenize(gpa, query);
    if (query_tokens.len > registry.max_query_tokens) return error.InvalidParams;
    const project = registry.getString(args, "project");
    const limit = registry.getInteger(args, "limit");

    const snapshot = ctx.docs.snapshot();
    defer snapshot.deinit();

    // A tool argument is typed by a caller, so a loose spelling resolves when
    // it names exactly one project; two distinct keys are never merged
    // (PROTO-14).
    var resolved_project = project;
    if (project) |wanted| {
        switch (try docs_projects.resolve(gpa, &snapshot.index.columnar, wanted)) {
            .found => |key| resolved_project = key,
            .missing => return toolFailure(
                gpa,
                try projectMissMessage(gpa, &snapshot.index.columnar, wanted),
                try emptySearchResult(gpa, query),
            ),
            .ambiguous => |candidates| return toolFailure(
                gpa,
                try ambiguousProjectMessage(gpa, wanted, candidates),
                try emptySearchResult(gpa, query),
            ),
        }
    }

    const effective_limit: usize = if (limit) |value|
        (if (value <= 0) docs_search.default_limit else @min(@as(usize, @intCast(value)), docs_search.max_limit))
    else
        docs_search.default_limit;

    const matches = try docs_search.searchWithTokens(
        gpa,
        &snapshot.index.columnar,
        query,
        query_tokens,
        resolved_project,
        effective_limit,
    );
    if (matches.len == 0) {
        return toolFailure(
            gpa,
            try std.fmt.allocPrint(gpa, "No indexed documentation matched '{s}'.", .{query}),
            try emptySearchResult(gpa, query),
        );
    }

    var results: std.json.Array = json_array.init(gpa);
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
        try json_array.append(&results, gpa, .{ .object = item });

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

/// The stored symbols closest to a spelling that matched nothing.
///
/// A miss is only a miss for the spelling that was tried: the index stores
/// path-qualified symbols, so `mem.copyForwards` finds nothing while
/// `lib.std.mem.copyForwards` is a record. The suggestions come from the same
/// scorer `doc_search` uses, so a suggestion always agrees with what a
/// follow-up `doc_search` call returns; they are deduplicated because several
/// records can share a symbol path.
fn closestSymbols(
    gpa: std.mem.Allocator,
    index: *const docs_columnar.Columnar,
    project: []const u8,
    symbol: []const u8,
) ![]const []const u8 {
    if (symbol.len == 0) return &.{};

    const tokens = try text_util.tokenize(gpa, symbol);
    // `doc_search` rejects a query over the token bound (-32602); a suggestion
    // list instead keeps the substring signal and drops the surplus tokens.
    const bounded = tokens[0..@min(tokens.len, registry.max_query_tokens)];

    const matches = try docs_search.searchWithTokens(
        gpa,
        index,
        symbol,
        bounded,
        project,
        max_get_candidates,
    );

    var symbols: std.ArrayList([]const u8) = .empty;
    for (matches) |match| {
        const stored = index.symbolAt(match.record_index);
        var seen = false;
        for (symbols.items) |existing| {
            if (std.mem.eql(u8, existing, stored)) {
                seen = true;
                break;
            }
        }
        if (!seen) try symbols.append(gpa, stored);
    }
    return symbols.toOwnedSlice(gpa);
}

/// A shorter spelling that names exactly one stored symbol, with every record of
/// that symbol.
const SuffixMatch = struct {
    records: []const usize,
    symbol: []const u8,
};

/// Resolves `symbol` as the dotted tail of a stored symbol, or null.
///
/// `ArrayList.append` is `lib.std.std.ArrayList.append`, so an exact compare
/// misses it while the declaration is present (PROTO-16). Two guards keep this
/// from becoming a guess: the character before the tail must be `.` (so `lain`
/// never matches `comments.plain`), and exactly one *stored symbol* may end with
/// the tail — two candidates stay a miss, reported with their suggestions.
fn suffixMatch(
    gpa: std.mem.Allocator,
    index: *const docs_columnar.Columnar,
    project: []const u8,
    symbol: []const u8,
) !?SuffixMatch {
    if (symbol.len == 0) return null;

    var records: std.ArrayList(usize) = .empty;
    var resolved: ?[]const u8 = null;
    for (0..index.count()) |record| {
        if (!std.mem.eql(u8, index.projectAt(record), project)) continue;
        const stored = index.symbolAt(record);
        // `stored.len > symbol.len + 1` keeps both the `.` boundary and a
        // non-empty prefix real, so the tail is a component, not a whole name.
        if (stored.len <= symbol.len + 1) continue;
        if (stored[stored.len - symbol.len - 1] != '.') continue;
        if (!text_util.eqlIgnoreCase(stored[stored.len - symbol.len ..], symbol)) continue;
        if (resolved) |seen| {
            // Several records may share one symbol (IDX-4); two *symbols* are
            // the ambiguity this refuses to resolve.
            if (!text_util.eqlIgnoreCase(seen, stored)) return null;
        } else {
            resolved = stored;
        }
        try records.append(gpa, record);
    }

    const stored_symbol = resolved orelse return null;
    return .{ .records = try records.toOwnedSlice(gpa), .symbol = stored_symbol };
}

/// The message for a symbol that matched nothing: the two rules a caller cannot
/// see from outside (path-qualified spelling, documented declarations only),
/// the closest stored symbols, and the tool that finds the spelling.
fn symbolMissMessage(
    gpa: std.mem.Allocator,
    symbol: []const u8,
    project: []const u8,
    candidates: []const []const u8,
) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    try text.print(
        gpa,
        "No indexed symbol '{s}' in project '{s}'. Symbols are stored path-qualified, and only declarations that carry a comment are indexed.",
        .{ symbol, project },
    );
    if (candidates.len > 0) {
        try text.appendSlice(gpa, "\nClosest indexed symbols:");
        for (candidates) |candidate| try text.print(gpa, "\n  {s}", .{candidate});
    }
    try text.appendSlice(gpa, "\nUse doc_search with a shorter query to find the stored spelling.");
    return text.toOwnedSlice(gpa);
}

/// `doc_get`: the full documentation of a symbol. Several records can share a
/// symbol path — a `//!` container record and a declaration from the sibling
/// `<dir>.zig` can both produce `std.os` — so every match is returned (IDX-4);
/// stopping at the first one made the rest unreachable.
pub fn docGet(ctx: *Context, args: std.json.Value) ToolError!ToolOutcome {
    registry.validate(doc_get_input, args) catch return error.InvalidParams;
    const gpa = ctx.pool.allocator();

    const project = registry.getString(args, "project") orelse return error.InvalidParams;
    const symbol = registry.getString(args, "symbol") orelse return error.InvalidParams;

    const snapshot = ctx.docs.snapshot();
    defer snapshot.deinit();
    const columnar = &snapshot.index.columnar;

    // Same forgiving resolution as `doc_search`, but the caller's spelling is
    // what the result echoes back (PROTO-14).
    var resolved_project = project;
    switch (try docs_projects.resolve(gpa, columnar, project)) {
        .found => |key| resolved_project = key,
        // A project that does not resolve leaves nothing to suggest from, so
        // the array is empty rather than absent: every `found: false` result
        // carries the member.
        .missing => return toolFailure(
            gpa,
            try projectMissMessage(gpa, columnar, project),
            try emptyGetResult(gpa, project, symbol, &.{}),
        ),
        .ambiguous => |candidates| return toolFailure(
            gpa,
            try ambiguousProjectMessage(gpa, project, candidates),
            try emptyGetResult(gpa, project, symbol, &.{}),
        ),
    }

    var records: std.ArrayList(usize) = .empty;
    for (0..columnar.count()) |record| {
        // The project key resolved above; only symbols are matched
        // case-insensitively (PROTO-13).
        if (!std.mem.eql(u8, columnar.projectAt(record), resolved_project)) continue;
        if (!text_util.eqlIgnoreCase(columnar.symbolAt(record), symbol)) continue;
        try records.append(gpa, record);
    }

    // A miss for the exact spelling is not a miss for the declaration: the same
    // symbol may be stored path-qualified (PROTO-16).
    var resolved_from: ?[]const u8 = null;
    if (records.items.len == 0) {
        if (try suffixMatch(gpa, columnar, resolved_project, symbol)) |hit| {
            try records.appendSlice(gpa, hit.records);
            resolved_from = symbol;
        } else {
            const candidates = try closestSymbols(gpa, columnar, resolved_project, symbol);
            return toolFailure(
                gpa,
                try symbolMissMessage(gpa, symbol, project, candidates),
                try emptyGetResult(gpa, project, symbol, candidates),
            );
        }
    }

    var matches: std.json.Array = json_array.init(gpa);
    var text: std.ArrayList(u8) = .empty;
    // The caller asked for a shorter name, so say which symbol answered: the
    // result must never look like a record stored under the spelling sent.
    if (resolved_from) |from| {
        try text.print(gpa, "Resolved '{s}' to {s}\n\n", .{ from, columnar.symbolAt(records.items[0]) });
    }
    for (records.items, 0..) |record, index| {
        var item: std.json.ObjectMap = .{};
        try item.put(gpa, "commit", .{ .string = columnar.commitAt(record) });
        try item.put(gpa, "path", .{ .string = columnar.pathAt(record) });
        try item.put(gpa, "line", .{ .integer = columnar.lines[record] });
        try item.put(gpa, "kind", .{ .string = columnar.kinds[record].label() });
        try item.put(gpa, "symbol", .{ .string = columnar.symbolAt(record) });
        try item.put(gpa, "container", .{ .string = columnar.containerAt(record) });
        try item.put(gpa, "doc", .{ .string = columnar.docAt(record) });
        try item.put(gpa, "doc_hash", .{ .string = columnar.docHashAt(record) });
        try json_array.append(&matches, gpa, .{ .object = item });

        if (index > 0) try text.append(gpa, '\n');
        try text.print(gpa, "{s}:{d} {s}\n\n{s}\n", .{
            columnar.pathAt(record),
            columnar.lines[record],
            columnar.symbolAt(record),
            columnar.docAt(record),
        });
    }

    var structured: std.json.ObjectMap = .{};
    try structured.put(gpa, "found", .{ .bool = true });
    try structured.put(gpa, "project", .{ .string = project });
    try structured.put(gpa, "symbol", .{ .string = symbol });
    try structured.put(gpa, "matches", .{ .array = matches });
    if (resolved_from) |from| try structured.put(gpa, "resolved_from", .{ .string = from });

    return .{ .text = try text.toOwnedSlice(gpa), .structured = .{ .object = structured } };
}

/// `tools/list`: the advertised capability table.
pub fn list(ctx: *registry.Context) !registry.Result {
    const gpa = ctx.pool.allocator();

    var tools: std.json.Array = json_array.init(gpa);
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

        try json_array.append(&tools, gpa, .{ .object = object });
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

    var contents: std.json.Array = json_array.init(gpa);
    try json_array.append(&contents, gpa, .{ .object = content });

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

/// A remote artifact has no local sidecar: the indexer wrote it next to the
/// file it produced, not next to the URL the server downloads from. Degraded
/// counts are therefore omitted for a URL index (REL-6, accepted).
fn isRemoteIndexPath(index_path: []const u8) bool {
    return std.mem.startsWith(u8, index_path, "http://") or
        std.mem.startsWith(u8, index_path, "https://");
}

/// Loads the status sidecar, if the indexer wrote one.
fn loadStatusSidecar(ctx: *Context, gpa: std.mem.Allocator) !?std.json.Value {
    const index_path = ctx.index_path orelse return null;
    if (isRemoteIndexPath(index_path)) return null;
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

/// Copies a sidecar array member verbatim, but only when it really is an array.
///
/// The advertised output schema says `degraded` is an array; echoing a string
/// or a number there would contradict it, so a mistyped member is dropped
/// (PROTO-11).
fn putSidecarArray(
    item: *std.json.ObjectMap,
    gpa: std.mem.Allocator,
    entry: std.json.ObjectMap,
    key: []const u8,
) !void {
    const value = entry.get(key) orelse return;
    if (value != .array) return;
    try item.put(gpa, key, value);
}

/// Copies one sidecar count into the result when it is a non-negative integer
/// that fits `usize`, returning the count it reported.
///
/// The sidecar is ordinary local data — a hand edit or a truncated indexer run
/// is enough — so a value of the wrong type or sign is dropped rather than
/// `@intCast`-ed, which aborted the process on the first `doc_import_status`
/// call (SRV-6).
fn putSidecarCount(
    item: *std.json.ObjectMap,
    gpa: std.mem.Allocator,
    entry: std.json.ObjectMap,
    key: []const u8,
) !?usize {
    const value = entry.get(key) orelse return null;
    if (value != .integer) return null;
    const count = std.math.cast(usize, value.integer) orelse return null;
    try item.put(gpa, key, .{ .integer = @intCast(count) });
    return count;
}

/// `doc_import_status`: what the index currently holds.
pub fn docImportStatus(ctx: *Context, args: std.json.Value) ToolError!ToolOutcome {
    registry.validate(doc_import_status_input, args) catch return error.InvalidParams;
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

    var project_values: std.json.Array = json_array.init(gpa);
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
                _ = try putSidecarCount(&item, gpa, entry, "files_total");
                degraded_files = try putSidecarCount(&item, gpa, entry, "files_degraded");
                try putSidecarArray(&item, gpa, entry, "degraded");
            }
        }
        try json_array.append(&project_values, gpa, .{ .object = item });
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
    // The active index may be stale: the artifact on disk failed to load and a
    // previous index kept serving. Only stderr knew that before (REL-4).
    const index_status = ctx.docs.statusSnapshot();
    try structured.put(gpa, "index_state", .{ .string = index_status.state.label() });
    if (index_status.error_name) |name| {
        try structured.put(gpa, "index_error", .{ .string = name });
    }
    if (index_status.state != .ok) {
        try text.print(gpa, "index: {s}", .{index_status.state.label()});
        if (index_status.error_name) |name| try text.print(gpa, " ({s})", .{name});
        try text.appendSlice(gpa, "\n");
    }
    try structured.put(gpa, "index_records", .{ .integer = @intCast(columnar.count()) });
    try structured.put(gpa, "projects", .{ .array = project_values });

    return .{ .text = try text.toOwnedSlice(gpa), .structured = .{ .object = structured } };
}

test "REL-6: a URL index has no local status sidecar" {
    // Accepted limitation: the sidecar lives next to the file the indexer
    // wrote, so a remote index has none and the degraded counts are omitted.
    try std.testing.expect(isRemoteIndexPath("http://example.org/index.jsonl"));
    try std.testing.expect(isRemoteIndexPath("https://example.org/index.jsonl"));
    try std.testing.expect(!isRemoteIndexPath("generated/index.jsonl"));
    try std.testing.expect(!isRemoteIndexPath("file:///tmp/index.jsonl"));
}

test "a negative sidecar count is dropped instead of cast" {
    // SRV-6: `@intCast` on a negative `files_degraded` aborted the process on
    // the first `doc_import_status` call. A bad count is now omitted.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"files_degraded\":-1,\"files_total\":3}",
        .{},
    );
    const entry = parsed.value.object;

    var item: std.json.ObjectMap = .{};
    try std.testing.expectEqual(
        @as(?usize, null),
        try putSidecarCount(&item, gpa, entry, "files_degraded"),
    );
    try std.testing.expect(item.get("files_degraded") == null);

    try std.testing.expectEqual(
        @as(?usize, 3),
        try putSidecarCount(&item, gpa, entry, "files_total"),
    );
    try std.testing.expectEqual(@as(i64, 3), item.get("files_total").?.integer);
}

test "a mistyped sidecar member never reaches structuredContent" {
    // PROTO-11: `files_total:"oops"`, `files_degraded:1.5` and a non-array
    // `degraded` were echoed verbatim, so the tool result contradicted the
    // `integer`/`array` types it advertises in `tools/list`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"files_total\":\"oops\",\"files_degraded\":1.5,\"degraded\":\"nope\"}",
        .{},
    );
    const entry = parsed.value.object;

    var item: std.json.ObjectMap = .{};
    try std.testing.expectEqual(
        @as(?usize, null),
        try putSidecarCount(&item, gpa, entry, "files_total"),
    );
    try std.testing.expectEqual(
        @as(?usize, null),
        try putSidecarCount(&item, gpa, entry, "files_degraded"),
    );
    try putSidecarArray(&item, gpa, entry, "degraded");

    try std.testing.expect(item.get("files_total") == null);
    try std.testing.expect(item.get("files_degraded") == null);
    try std.testing.expect(item.get("degraded") == null);

    // A well-formed member is still copied verbatim.
    const good = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"degraded\":[{\"path\":\"a.zig\"}]}",
        .{},
    );
    try putSidecarArray(&item, gpa, good.value.object, "degraded");
    try std.testing.expectEqual(@as(usize, 1), item.get("degraded").?.array.items.len);
}
