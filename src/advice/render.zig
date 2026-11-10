//! Rendering advice records to MCP resources, tool results and prompt text
//! (AGENTS.md §5).
//!
//! Every rendering keeps the evidence label and the source ids attached to the
//! claim they belong to. `GUIDANCE` is never rendered as `FACT`.

const std = @import("std");
const corpus_module = @import("corpus.zig");

pub const Corpus = corpus_module.Corpus;
pub const Pattern = corpus_module.Pattern;
pub const Rule = corpus_module.Rule;
pub const Guarantee = corpus_module.Guarantee;
pub const Source = corpus_module.Source;
pub const Limits = corpus_module.Limits;
pub const Evidence = corpus_module.Evidence;
pub const Fact = corpus_module.Fact;

fn stringArrayValue(gpa: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array: std.json.Array = .init(gpa);
    for (items) |item| try array.append(.{ .string = item });
    return .{ .array = array };
}

pub fn factValue(gpa: std.mem.Allocator, fact: Fact) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "text", .{ .string = fact.text });
    try object.put(gpa, "evidence", .{ .string = fact.evidence.label() });
    try object.put(gpa, "source", .{ .string = fact.source });
    return .{ .object = object };
}

pub fn patternValue(gpa: std.mem.Allocator, pattern: *const Pattern) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "id", .{ .string = pattern.id });
    try object.put(gpa, "name", .{ .string = pattern.name });
    try object.put(gpa, "what_data_controls", .{ .string = pattern.what_data_controls });
    if (pattern.mechanism) |mechanism| {
        try object.put(gpa, "mechanism", .{ .string = mechanism });
    }

    var facts: std.json.Array = .init(gpa);
    for (pattern.facts) |fact| try facts.append(try factValue(gpa, fact));
    try object.put(gpa, "facts", .{ .array = facts });

    try object.put(gpa, "candidate_uses", try stringArrayValue(gpa, pattern.candidate_uses));
    try object.put(gpa, "boundaries", try stringArrayValue(gpa, pattern.boundaries));
    try object.put(gpa, "checks", try stringArrayValue(gpa, pattern.checks));
    try object.put(gpa, "evidence", .{ .string = pattern.evidence.label() });
    try object.put(gpa, "sources", try stringArrayValue(gpa, pattern.sources));
    return .{ .object = object };
}

pub fn ruleValue(gpa: std.mem.Allocator, rule: *const Rule) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "id", .{ .string = rule.id });
    try object.put(gpa, "condition", .{ .string = rule.condition });

    var then: std.json.ObjectMap = .{};
    try then.put(gpa, "consider", try stringArrayValue(gpa, rule.then.consider));
    if (rule.then.and_only_if) |constraint| {
        try then.put(gpa, "and_only_if", .{ .string = constraint });
    }
    try object.put(gpa, "then", .{ .object = then });
    try object.put(gpa, "evidence", .{ .string = rule.evidence.label() });
    return .{ .object = object };
}

pub fn guaranteeValue(gpa: std.mem.Allocator, guarantee: *const Guarantee) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "id", .{ .string = guarantee.id });
    try object.put(gpa, "claim", .{ .string = guarantee.claim });
    try object.put(gpa, "evidence", .{ .string = guarantee.evidence.label() });
    if (guarantee.guidance) |guidance| {
        try object.put(gpa, "guidance", .{ .string = guidance });
    }
    try object.put(gpa, "sources", try stringArrayValue(gpa, guarantee.sources));
    return .{ .object = object };
}

pub fn sourceValue(gpa: std.mem.Allocator, source: *const Source) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "id", .{ .string = source.id });
    try object.put(gpa, "author", .{ .string = source.author });
    try object.put(gpa, "title", .{ .string = source.title });
    try object.put(gpa, "kind", .{ .string = source.kind });
    try object.put(gpa, "url", .{ .string = source.url });
    return .{ .object = object };
}

pub fn limitsValue(gpa: std.mem.Allocator, limits: Limits) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "limits", try stringArrayValue(gpa, limits.limits));

    var legend: std.json.Array = .init(gpa);
    for (limits.evidence_legend) |entry| {
        var item: std.json.ObjectMap = .{};
        try item.put(gpa, "label", .{ .string = entry.label });
        try item.put(gpa, "meaning", .{ .string = entry.meaning });
        try legend.append(.{ .object = item });
    }
    try object.put(gpa, "evidence_legend", .{ .array = legend });
    return .{ .object = object };
}

/// Compact table of every pattern: id, name, what it controls, evidence label.
pub fn overviewValue(gpa: std.mem.Allocator, corpus: *const Corpus) !std.json.Value {
    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "version", .{ .integer = corpus.version });
    try object.put(gpa, "source_research_date", .{ .string = corpus.source_research_date });

    var patterns: std.json.Array = .init(gpa);
    for (corpus.patterns) |*pattern| {
        var item: std.json.ObjectMap = .{};
        try item.put(gpa, "id", .{ .string = pattern.id });
        try item.put(gpa, "name", .{ .string = pattern.name });
        try item.put(gpa, "what_data_controls", .{ .string = pattern.what_data_controls });
        try item.put(gpa, "evidence", .{ .string = pattern.evidence.label() });
        try item.put(gpa, "sources", try stringArrayValue(gpa, pattern.sources));
        try patterns.append(.{ .object = item });
    }
    try object.put(gpa, "patterns", .{ .array = patterns });
    return .{ .object = object };
}

pub fn joinStrings(gpa: std.mem.Allocator, items: []const []const u8, separator: []const u8) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, index| {
        if (index > 0) try text.print(gpa, "{s}", .{separator});
        try text.print(gpa, "{s}", .{item});
    }
    return text.toOwnedSlice(gpa);
}

/// Human-readable rendering used for resource and tool text content.
pub fn patternText(gpa: std.mem.Allocator, pattern: *const Pattern) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;

    try text.print(gpa, "{s} — {s} [{s}]\n", .{ pattern.id, pattern.name, pattern.evidence.label() });
    try text.print(gpa, "Controls: {s}\n", .{pattern.what_data_controls});
    if (pattern.mechanism) |mechanism| {
        try text.print(gpa, "Mechanism: {s}\n", .{mechanism});
    }
    if (pattern.facts.len > 0) {
        try text.print(gpa, "Facts:\n", .{});
        for (pattern.facts) |fact| {
            try text.print(gpa, "- [{s}] {s} [{s}]\n", .{ fact.evidence.label(), fact.text, fact.source });
        }
    }
    if (pattern.candidate_uses.len > 0) {
        try text.print(gpa, "Candidate uses:\n", .{});
        for (pattern.candidate_uses) |use| try text.print(gpa, "- {s}\n", .{use});
    }
    if (pattern.boundaries.len > 0) {
        try text.print(gpa, "Boundaries:\n", .{});
        for (pattern.boundaries) |boundary| try text.print(gpa, "- {s}\n", .{boundary});
    }
    if (pattern.checks.len > 0) {
        try text.print(gpa, "Checks:\n", .{});
        for (pattern.checks) |check| try text.print(gpa, "- {s}\n", .{check});
    }
    try text.print(gpa, "Sources: {s}\n", .{try joinStrings(gpa, pattern.sources, ", ")});
    return text.toOwnedSlice(gpa);
}

pub fn ruleText(gpa: std.mem.Allocator, rule: *const Rule) ![]const u8 {
    var text: std.ArrayList(u8) = .empty;

    try text.print(gpa, "{s} [{s}]: {s}\n", .{ rule.id, rule.evidence.label(), rule.condition });
    try text.print(gpa, "Consider: {s}\n", .{try joinStrings(gpa, rule.then.consider, ", ")});
    if (rule.then.and_only_if) |constraint| {
        try text.print(gpa, "Only if: {s}\n", .{constraint});
    }
    return text.toOwnedSlice(gpa);
}

test "a rendered pattern keeps its evidence label and sources" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const pattern = Pattern{
        .id = "P03",
        .name = "Data-oriented design",
        .what_data_controls = "Physical representation and transformations",
        .facts = &.{
            .{ .text = "Fabian emphasises data and the machine.", .source = "S15", .evidence = .fact },
        },
        .candidate_uses = &.{"memory-intensive loops"},
        .boundaries = &.{"not configuration-driven behaviour"},
        .checks = &.{"actual field access"},
        .evidence = .synthesis,
        .sources = &.{"S15"},
    };

    const value = try patternValue(gpa, &pattern);
    try std.testing.expectEqualStrings("SYNTHESIS", value.object.get("evidence").?.string);
    try std.testing.expectEqualStrings("S15", value.object.get("sources").?.array.items[0].string);
    try std.testing.expectEqualStrings(
        "FACT",
        value.object.get("facts").?.array.items[0].object.get("evidence").?.string,
    );

    const text = try patternText(gpa, &pattern);
    try std.testing.expect(std.mem.indexOf(u8, text, "[SYNTHESIS]") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "[FACT]") != null);
}
