//! Resource listing and reading (AGENTS.md §5).
//!
//! `advice://*` resources are stable (long, public cache). `docs://*` resources
//! are derived from the current index (short, private cache). A missing resource
//! is a protocol error (`-32602` with `data.uri`) — never an empty `contents`
//! array.

const std = @import("std");
const registry = @import("registry.zig");
const corpus_module = @import("../advice/corpus.zig");
const render = @import("../advice/render.zig");
const text_util = @import("../util/text.zig");

pub const ResourceSpec = struct {
    uri: []const u8,
    name: []const u8,
    title: []const u8,
    description: []const u8,
    mime_type: []const u8 = "text/plain",
};

pub const resource_specs = [_]ResourceSpec{
    .{
        .uri = "advice://overview",
        .name = "advice-overview",
        .title = "Systems-programming advice overview",
        .description = "The 12 advice patterns as a compact table with evidence labels.",
    },
    .{
        .uri = "advice://patterns",
        .name = "advice-patterns",
        .title = "Advice patterns",
        .description = "All 12 patterns in one document, or one per pattern: advice://patterns/P01 … advice://patterns/P12.",
    },
    .{
        .uri = "advice://rules",
        .name = "advice-rules",
        .title = "Conditional decision rules",
        .description = "The 12 SELECT rules, all GUIDANCE.",
    },
    .{
        .uri = "advice://guarantees",
        .name = "advice-guarantees",
        .title = "Cross-cutting guarantees",
        .description = "Constraints that hold across patterns, with their evidence labels.",
    },
    .{
        .uri = "advice://limits",
        .name = "advice-limits",
        .title = "Limits and evidence legend",
        .description = "The limits of the source document and the evidence-label legend.",
    },
    .{
        .uri = "advice://sources",
        .name = "advice-sources",
        .title = "Source registry",
        .description = "The S01..S24 source registry with URLs.",
    },
};

pub const symbol_template = "docs://{project}/symbols/{symbol}";

fn resourceValue(gpa: std.mem.Allocator, spec: ResourceSpec) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "uri", .{ .string = spec.uri });
    try object.put(gpa, "name", .{ .string = spec.name });
    try object.put(gpa, "title", .{ .string = spec.title });
    try object.put(gpa, "description", .{ .string = spec.description });
    try object.put(gpa, "mimeType", .{ .string = spec.mime_type });
    return .{ .object = object };
}

/// `resources/list`: the fixed advice resources plus one index listing per
/// project currently present in the doc index.
pub fn list(ctx: *registry.Context) !registry.Result {
    const gpa = ctx.pool.allocator();

    var resources: std.json.Array = .init(gpa);
    for (resource_specs) |spec| {
        try resources.append(try resourceValue(gpa, spec));
    }
    for (ctx.corpus.patterns) |pattern| {
        const uri = try std.fmt.allocPrint(gpa, "advice://patterns/{s}", .{pattern.id});
        try resources.append(try resourceValue(gpa, .{
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
        try resources.append(try resourceValue(gpa, .{
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

    var templates: std.json.Array = .init(gpa);
    try templates.append(.{ .object = object });

    var list_object: std.json.ObjectMap = .{};
    try list_object.put(gpa, "resourceTemplates", .{ .array = templates });
    return .{ .value = .{ .object = list_object }, .cache = registry.index_cache };
}

fn projectNames(gpa: std.mem.Allocator, columnar: *const @import("../docs/columnar.zig").Columnar) ![][]const u8 {
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

/// `resources/read`.
pub fn read(ctx: *registry.Context, uri: []const u8) !registry.Result {
    const gpa = ctx.pool.allocator();

    const text = if (std.mem.eql(u8, uri, "advice://overview"))
        try overviewText(ctx)
    else if (std.mem.eql(u8, uri, "advice://rules"))
        try rulesText(ctx)
    else if (std.mem.eql(u8, uri, "advice://guarantees"))
        try guaranteesText(ctx)
    else if (std.mem.eql(u8, uri, "advice://limits"))
        try limitsText(ctx)
    else if (std.mem.eql(u8, uri, "advice://sources"))
        try sourcesText(ctx)
    else if (std.mem.eql(u8, uri, "advice://patterns"))
        try allPatternsText(ctx)
    else if (std.mem.startsWith(u8, uri, "advice://patterns/"))
        try patternText(ctx, uri["advice://patterns/".len..])
    else if (std.mem.startsWith(u8, uri, "docs://"))
        try docsText(ctx, uri)
    else
        return error.UnknownResource;

    var contents: std.json.ObjectMap = .{};
    try contents.put(gpa, "uri", .{ .string = uri });
    try contents.put(gpa, "mimeType", .{ .string = "text/plain" });
    try contents.put(gpa, "text", .{ .string = text });

    var contents_array: std.json.Array = .init(gpa);
    try contents_array.append(.{ .object = contents });

    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "contents", .{ .array = contents_array });

    const cache = if (std.mem.startsWith(u8, uri, "docs://")) registry.index_cache else registry.advice_cache;
    return .{ .value = .{ .object = object }, .cache = cache };
}

fn overviewText(ctx: *registry.Context) ![]const u8 {
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

fn patternText(ctx: *registry.Context, id: []const u8) ![]const u8 {
    const gpa = ctx.pool.allocator();
    const pattern = ctx.corpus.findPattern(id) orelse return error.UnknownResource;
    return render.patternText(gpa, pattern);
}

/// `advice://patterns`: every pattern in one document.
///
/// `resources/list` advertises this URI, so it has to be readable: a listed
/// resource that `resources/read` rejects is a client-visible contract break
/// (PROTO-1).
fn allPatternsText(ctx: *registry.Context) ![]const u8 {
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (ctx.corpus.patterns) |*pattern| {
        try text.appendSlice(gpa, try render.patternText(gpa, pattern));
        try text.appendSlice(gpa, "\n");
    }
    return text.toOwnedSlice(gpa);
}

fn rulesText(ctx: *registry.Context) ![]const u8 {
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;
    for (ctx.corpus.rules) |*rule| {
        try text.appendSlice(gpa, try render.ruleText(gpa, rule));
        try text.appendSlice(gpa, "\n");
    }
    return text.toOwnedSlice(gpa);
}

fn guaranteesText(ctx: *registry.Context) ![]const u8 {
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

fn limitsText(ctx: *registry.Context) ![]const u8 {
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

fn sourcesText(ctx: *registry.Context) ![]const u8 {
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

fn docsText(ctx: *registry.Context, uri: []const u8) ![]const u8 {
    const gpa = ctx.pool.allocator();

    const snapshot = ctx.docs.snapshot();
    defer snapshot.deinit();
    const columnar = &snapshot.index.columnar;

    const rest = uri["docs://".len..];

    if (std.mem.endsWith(u8, rest, "/index")) {
        const project = rest[0 .. rest.len - "/index".len];
        var text: std.ArrayList(u8) = .empty;
        for (0..columnar.count()) |record| {
            // Project keys are exact identifiers (PROTO-13): `Fixture` and
            // `fixture` are different projects and different URIs.
            if (!std.mem.eql(u8, columnar.projectAt(record), project)) continue;
            try text.print(gpa, "{s}:{d} {s}\n", .{
                columnar.pathAt(record),
                columnar.lines[record],
                columnar.symbolAt(record),
            });
        }
        if (text.items.len == 0) return error.UnknownResource;
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
