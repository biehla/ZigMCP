//! Resource listing and reading (AGENTS.md §5).
//!
//! `advice://*` resources are stable (long, public cache). `docs://*` resources
//! are derived from the current index (short, private cache). A missing resource
//! is a protocol error (`-32602` with `data.uri`) — never an empty `contents`
//! array.

const std = @import("std");
const registry = @import("registry.zig");
const columnar_module = @import("../docs/columnar.zig");
const corpus_module = @import("../advice/corpus.zig");
const render = @import("../advice/render.zig");
const text_util = @import("../util/text.zig");
const json_array = @import("../util/json_array.zig");

/// The error set every resource text handler may return. Explicit so the
/// caller's `switch` stays exhaustive.
pub const ResourceError = error{ OutOfMemory, UnknownResource };

/// Text renderer for a resource; `uri` has already been matched.
pub const ResourceHandler = *const fn (ctx: *registry.Context, uri: []const u8) ResourceError![]const u8;

pub const ResourceSpec = struct {
    uri: []const u8,
    name: []const u8,
    title: []const u8,
    description: []const u8,
    mime_type: []const u8 = "text/plain",
    handler: ResourceHandler,
    cache: registry.CacheHint,
};

pub const resource_specs = [_]ResourceSpec{
    .{
        .uri = "advice://overview",
        .name = "advice-overview",
        .title = "Systems-programming advice overview",
        .description = "The 12 advice patterns as a compact table with evidence labels.",
        .handler = overviewText,
        .cache = registry.advice_cache,
    },
    .{
        .uri = "advice://patterns",
        .name = "advice-patterns",
        .title = "Advice patterns",
        .description = "All 12 patterns in one document, or one per pattern: advice://patterns/P01 … advice://patterns/P12.",
        .handler = allPatternsText,
        .cache = registry.advice_cache,
    },
    .{
        .uri = "advice://rules",
        .name = "advice-rules",
        .title = "Conditional decision rules",
        .description = "The 12 SELECT rules, all GUIDANCE.",
        .handler = rulesText,
        .cache = registry.advice_cache,
    },
    .{
        .uri = "advice://guarantees",
        .name = "advice-guarantees",
        .title = "Cross-cutting guarantees",
        .description = "Constraints that hold across patterns, with their evidence labels.",
        .handler = guaranteesText,
        .cache = registry.advice_cache,
    },
    .{
        .uri = "advice://limits",
        .name = "advice-limits",
        .title = "Limits and evidence legend",
        .description = "The limits of the source document and the evidence-label legend.",
        .handler = limitsText,
        .cache = registry.advice_cache,
    },
    .{
        .uri = "advice://sources",
        .name = "advice-sources",
        .title = "Source registry",
        .description = "The S01..S24 source registry with URLs.",
        .handler = sourcesText,
        .cache = registry.advice_cache,
    },
};

/// A URI shape rather than one fixed URI: matched by `matcher`, served by `handler`.
pub const ResourceFamily = struct {
    matcher: *const fn (uri: []const u8) bool,
    handler: ResourceHandler,
    cache: registry.CacheHint,
};

fn matchesPatternFamily(uri: []const u8) bool {
    return std.mem.startsWith(u8, uri, "advice://patterns/");
}

fn matchesDocsFamily(uri: []const u8) bool {
    return std.mem.startsWith(u8, uri, "docs://");
}

pub const resource_families = [_]ResourceFamily{
    .{ .matcher = matchesPatternFamily, .handler = patternText, .cache = registry.advice_cache },
    .{ .matcher = matchesDocsFamily, .handler = docsText, .cache = registry.index_cache },
};

fn findResource(uri: []const u8) ?*const ResourceSpec {
    for (&resource_specs) |*spec| {
        if (std.mem.eql(u8, spec.uri, uri)) return spec;
    }
    return null;
}

pub fn findFamily(uri: []const u8) ?*const ResourceFamily {
    for (&resource_families) |*family| {
        if (family.matcher(uri)) return family;
    }
    return null;
}

pub const symbol_template = "docs://{project}/symbols/{symbol}";

/// The display half of a resource entry: what `resources/list` reports. A
/// listing never has to name a handler, so the synthesized `docs://` and
/// per-pattern entries carry display data only.
const ResourceDisplay = struct {
    uri: []const u8,
    name: []const u8,
    title: []const u8,
    description: []const u8,
    mime_type: []const u8 = "text/plain",
};

fn resourceValue(gpa: std.mem.Allocator, display: ResourceDisplay) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "uri", .{ .string = display.uri });
    try object.put(gpa, "name", .{ .string = display.name });
    try object.put(gpa, "title", .{ .string = display.title });
    try object.put(gpa, "description", .{ .string = display.description });
    try object.put(gpa, "mimeType", .{ .string = display.mime_type });
    return .{ .object = object };
}

/// `resources/list`: the fixed advice resources plus one index listing per
/// project currently present in the doc index.
pub fn list(ctx: *registry.Context) !registry.Result {
    const gpa = ctx.pool.allocator();

    var resources: std.json.Array = json_array.init(gpa);
    for (resource_specs) |spec| {
        try json_array.append(&resources, gpa, try resourceValue(gpa, .{
            .uri = spec.uri,
            .name = spec.name,
            .title = spec.title,
            .description = spec.description,
            .mime_type = spec.mime_type,
        }));
    }
    for (ctx.corpus.patterns) |pattern| {
        const uri = try std.fmt.allocPrint(gpa, "advice://patterns/{s}", .{pattern.id});
        try json_array.append(&resources, gpa, try resourceValue(gpa, .{
            .uri = uri,
            .name = try std.fmt.allocPrint(gpa, "advice-pattern-{s}", .{pattern.id}),
            .title = try std.fmt.allocPrint(gpa, "Advice pattern {s}", .{pattern.id}),
            .description = pattern.name,
        }));
    }

    const snapshot = ctx.docs.snapshot();
    defer snapshot.deinit();
    for (try projectNames(gpa, &snapshot.index.columnar)) |project| {
        const uri = try std.fmt.allocPrint(gpa, "docs://{s}/index", .{project});
        try json_array.append(&resources, gpa, try resourceValue(gpa, .{
            .uri = uri,
            .name = try std.fmt.allocPrint(gpa, "{s}-index", .{project}),
            .title = try std.fmt.allocPrint(gpa, "{s} symbol index", .{project}),
            .description = "Symbols imported for this project.",
        }));
    }

    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "resources", .{ .array = resources });
    return .{ .value = .{ .object = object }, .cache = registry.index_cache };
}

/// `resources/templates/list`: the unbounded symbol space is a template.
pub fn listTemplates(ctx: *registry.Context) !registry.Result {
    const gpa = ctx.pool.allocator();

    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "uriTemplate", .{ .string = symbol_template });
    try object.put(gpa, "name", .{ .string = "doc-symbol" });
    try object.put(gpa, "title", .{ .string = "Imported documentation for one symbol" });
    try object.put(gpa, "description", .{ .string = "Full documentation of one imported symbol." });
    try object.put(gpa, "mimeType", .{ .string = "text/plain" });

    var templates: std.json.Array = json_array.init(gpa);
    try json_array.append(&templates, gpa, .{ .object = object });

    var list_object: std.json.ObjectMap = .{};
    try list_object.put(gpa, "resourceTemplates", .{ .array = templates });
    return .{ .value = .{ .object = list_object }, .cache = registry.index_cache };
}

/// Records one `docs://{project}/index` listing renders before it truncates.
///
/// One read used to return every symbol of a project, unbounded in size
/// (PROTO-10). The cap is a truncation with a marker, not a silent cut: a
/// client can see that more records exist and reach them through
/// `doc_search` / `doc_get`.
pub const max_index_listing_records: usize = 5_000;

/// Renders the project's `path:line symbol` lines, at most `max_records` of
/// them, and returns the project's total record count.
fn appendIndexListing(
    gpa: std.mem.Allocator,
    columnar: *const columnar_module.Columnar,
    project: []const u8,
    max_records: usize,
    text: *std.ArrayList(u8),
) !usize {
    var written: usize = 0;
    var total: usize = 0;
    for (0..columnar.count()) |record| {
        // Project keys are exact identifiers (PROTO-13): `Fixture` and
        // `fixture` are different projects and different URIs.
        if (!std.mem.eql(u8, columnar.projectAt(record), project)) continue;
        total += 1;
        if (written >= max_records) continue;
        try text.print(gpa, "{s}:{d} {s}\n", .{
            columnar.pathAt(record),
            columnar.lines[record],
            columnar.symbolAt(record),
        });
        written += 1;
    }
    if (total > written) {
        try text.print(gpa, "\n… truncated: {d} more records; use doc_search or doc_get for the rest\n", .{total - written});
    }
    return total;
}

fn projectNames(gpa: std.mem.Allocator, columnar: *const columnar_module.Columnar) ![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (0..columnar.count()) |record| {
        const name = columnar.projectAt(record);
        var seen = false;
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing, name)) {
                seen = true;
                break;
            }
        }
        if (!seen) try names.append(gpa, name);
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);
    return names.toOwnedSlice(gpa);
}

/// `resources/read`. Dispatch goes through the two tables (D8/P01): a fixed URI
/// is a `resource_specs` row, a URI shape is a `resource_families` row.
pub fn read(ctx: *registry.Context, uri: []const u8) ResourceError!registry.Result {
    const gpa = ctx.pool.allocator();

    var text: []const u8 = undefined;
    var cache: registry.CacheHint = undefined;
    if (findResource(uri)) |spec| {
        text = try spec.handler(ctx, uri);
        cache = spec.cache;
    } else if (findFamily(uri)) |family| {
        text = try family.handler(ctx, uri);
        cache = family.cache;
    } else {
        return error.UnknownResource;
    }

    var contents: std.json.ObjectMap = .{};
    try contents.put(gpa, "uri", .{ .string = uri });
    try contents.put(gpa, "mimeType", .{ .string = "text/plain" });
    try contents.put(gpa, "text", .{ .string = text });

    var contents_array: std.json.Array = json_array.init(gpa);
    try json_array.append(&contents_array, gpa, .{ .object = contents });

    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "contents", .{ .array = contents_array });

    return .{ .value = .{ .object = object }, .cache = cache };
}

fn overviewText(ctx: *registry.Context, uri: []const u8) ResourceError![]const u8 {
    _ = uri;
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.print(gpa, "Systems-programming advice (version {d}, source research date {s})\n\n", .{
        ctx.corpus.version,
        ctx.corpus.source_research_date,
    });
    for (ctx.corpus.patterns) |pattern| {
        try text.print(gpa, "{s}  {s}  [{s}]  controls: {s}\n", .{
            pattern.id,
            pattern.name,
            pattern.evidence.label(),
            pattern.what_data_controls,
        });
    }
    return text.toOwnedSlice(gpa);
}

fn patternText(ctx: *registry.Context, uri: []const u8) ResourceError![]const u8 {
    const prefix = "advice://patterns/";
    if (!std.mem.startsWith(u8, uri, prefix)) return error.UnknownResource;
    const pattern = ctx.corpus.findPattern(uri[prefix.len..]) orelse return error.UnknownResource;
    return render.patternText(ctx.pool.allocator(), pattern);
}

/// `advice://patterns`: every pattern in one document.
///
/// `resources/list` advertises this URI, so it has to be readable: a listed
/// resource that `resources/read` rejects is a client-visible contract break
/// (PROTO-1).
fn allPatternsText(ctx: *registry.Context, uri: []const u8) ResourceError![]const u8 {
    _ = uri;
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (ctx.corpus.patterns) |*pattern| {
        try text.appendSlice(gpa, try render.patternText(gpa, pattern));
        try text.appendSlice(gpa, "\n");
    }
    return text.toOwnedSlice(gpa);
}

fn rulesText(ctx: *registry.Context, uri: []const u8) ResourceError![]const u8 {
    _ = uri;
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (ctx.corpus.rules) |*rule| {
        try text.appendSlice(gpa, try render.ruleText(gpa, rule));
        try text.appendSlice(gpa, "\n");
    }
    return text.toOwnedSlice(gpa);
}

fn guaranteesText(ctx: *registry.Context, uri: []const u8) ResourceError![]const u8 {
    _ = uri;
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (ctx.corpus.guarantees) |guarantee| {
        try text.print(gpa, "{s} [{s}] {s}", .{ guarantee.id, guarantee.evidence.label(), guarantee.claim });
        if (guarantee.guidance) |guidance| {
            try text.print(gpa, " — GUIDANCE: {s}", .{guidance});
        }
        if (guarantee.sources.len > 0) {
            try text.print(gpa, " [{s}]", .{try render.joinStrings(gpa, guarantee.sources, ", ")});
        }
        try text.appendSlice(gpa, "\n");
    }
    return text.toOwnedSlice(gpa);
}

fn limitsText(ctx: *registry.Context, uri: []const u8) ResourceError![]const u8 {
    _ = uri;
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(gpa, "Limits:\n");
    for (ctx.corpus.limits.limits) |limit| {
        try text.print(gpa, "- {s}\n", .{limit});
    }
    try text.appendSlice(gpa, "\nEvidence labels:\n");
    for (ctx.corpus.limits.evidence_legend) |entry| {
        try text.print(gpa, "- {s}: {s}\n", .{ entry.label, entry.meaning });
    }
    return text.toOwnedSlice(gpa);
}

fn sourcesText(ctx: *registry.Context, uri: []const u8) ResourceError![]const u8 {
    _ = uri;
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (ctx.corpus.sources) |source| {
        try text.print(gpa, "{s} — {s}. {s} ({s}). {s}\n", .{
            source.id,
            source.author,
            source.title,
            source.kind,
            source.url,
        });
    }
    return text.toOwnedSlice(gpa);
}

fn docsText(ctx: *registry.Context, uri: []const u8) ResourceError![]const u8 {
    const gpa = ctx.pool.allocator();

    const snapshot = ctx.docs.snapshot();
    defer snapshot.deinit();
    const columnar = &snapshot.index.columnar;

    const rest = uri["docs://".len..];

    if (std.mem.endsWith(u8, rest, "/index")) {
        const project = rest[0 .. rest.len - "/index".len];
        var text: std.ArrayList(u8) = .empty;
        const total = try appendIndexListing(gpa, columnar, project, max_index_listing_records, &text);
        if (total == 0) return error.UnknownResource;
        return text.toOwnedSlice(gpa);
    }

    const marker = "/symbols/";
    if (std.mem.indexOf(u8, rest, marker)) |position| {
        const project = rest[0..position];
        const symbol = rest[position + marker.len ..];
        for (0..columnar.count()) |record| {
            // Project keys are exact identifiers (PROTO-13): `Fixture` and
            // `fixture` are different projects and different URIs.
            if (!std.mem.eql(u8, columnar.projectAt(record), project)) continue;
            if (!text_util.eqlIgnoreCase(columnar.symbolAt(record), symbol)) continue;
            return std.fmt.allocPrint(gpa, "{s}:{d} {s}\n\n{s}\n", .{
                columnar.pathAt(record),
                columnar.lines[record],
                columnar.symbolAt(record),
                columnar.docAt(record),
            });
        }
    }

    return error.UnknownResource;
}

test "PROTO-10: a project index listing is capped and says so" {
    // One read used to return every symbol of a project, unbounded in size.
    // The helper takes the cap as a parameter so the truncation contract is
    // testable with three records; the policy constant is
    // `max_index_listing_records`.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var builder = columnar_module.Builder.init(gpa);
    for ([_][]const u8{ "a", "b", "c" }, 0..) |symbol, index| {
        try builder.append(.{
            .project = "p",
            .commit = "c",
            .path = "m.zig",
            .line = @intCast(index + 1),
            .kind = .function,
            .symbol = symbol,
            .container = "",
            .doc = "docs",
            .doc_hash = "h",
        });
    }
    const index = try builder.finish();

    var text: std.ArrayList(u8) = .empty;
    const total = try appendIndexListing(gpa, &index, "p", 2, &text);

    try std.testing.expectEqual(@as(usize, 3), total);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "m.zig:1 a") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "m.zig:2 b") != null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "m.zig:3 c") == null);
    try std.testing.expect(std.mem.indexOf(u8, text.items, "truncated: 1 more records") != null);
}
