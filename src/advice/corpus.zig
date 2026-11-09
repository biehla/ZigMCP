//! Advice corpus: the runtime-loaded ZON data plane (PLAN §6.1, D2).
//!
//! The corpus is data, not code: editing advice never touches a handler. Every
//! record carries an evidence label (`FACT` / `RESULT` / `SYNTHESIS` /
//! `GUIDANCE`) and its `Sxx` source ids, so the server can never launder a
//! hypothesis into a fact.

const std = @import("std");

pub const Evidence = enum {
    fact,
    result,
    synthesis,
    guidance,

    pub fn label(self: Evidence) []const u8 {
        return switch (self) {
            .fact => "FACT",
            .result => "RESULT",
            .synthesis => "SYNTHESIS",
            .guidance => "GUIDANCE",
        };
    }

    pub fn parse(text: []const u8) ?Evidence {
        if (std.mem.eql(u8, text, "FACT")) return .fact;
        if (std.mem.eql(u8, text, "RESULT")) return .result;
        if (std.mem.eql(u8, text, "SYNTHESIS")) return .synthesis;
        if (std.mem.eql(u8, text, "GUIDANCE")) return .guidance;
        return null;
    }
};

pub const Fact = struct {
    text: []const u8,
    source: []const u8,
    evidence: Evidence,
};

pub const Pattern = struct {
    id: []const u8,
    name: []const u8,
    what_data_controls: []const u8,
    mechanism: ?[]const u8 = null,
    facts: []const Fact,
    candidate_uses: []const []const u8,
    boundaries: []const []const u8,
    checks: []const []const u8,
    evidence: Evidence,
    sources: []const []const u8,
};

pub const Then = struct {
    consider: []const []const u8,
    and_only_if: ?[]const u8 = null,
};

pub const Rule = struct {
    id: []const u8,
    condition: []const u8,
    then: Then,
    evidence: Evidence,
};

pub const Guarantee = struct {
    id: []const u8,
    claim: []const u8,
    evidence: Evidence,
    guidance: ?[]const u8 = null,
    sources: []const []const u8,
};

pub const LegendEntry = struct {
    label: []const u8,
    meaning: []const u8,
};

pub const Limits = struct {
    limits: []const []const u8,
    evidence_legend: []const LegendEntry,
};

pub const Source = struct {
    id: []const u8,
    author: []const u8,
    title: []const u8,
    kind: []const u8,
    url: []const u8,
};

const PatternsFile = struct {
    version: u32,
    source_research_date: []const u8,
    patterns: []const Pattern,
};

const RulesFile = struct {
    version: u32,
    rules: []const Rule,
};

const GuaranteesFile = struct {
    version: u32,
    guarantees: []const Guarantee,
};

const LimitsFile = struct {
    version: u32,
    limits: []const []const u8,
    evidence_legend: []const LegendEntry,
};

const SourcesFile = struct {
    version: u32,
    sources: []const Source,
};

/// The loaded corpus. All strings point into the corpus arena.
pub const Corpus = struct {
    gpa: std.mem.Allocator,
    /// Heap-allocated: in Zig 0.17 the arena's allocator points back at the
    /// arena instance, so the arena must not be copied by value.
    arena: *std.heap.ArenaAllocator,
    version: u32,
    source_research_date: []const u8,
    patterns: []const Pattern,
    rules: []const Rule,
    guarantees: []const Guarantee,
    limits: Limits,
    sources: []const Source,

    pub fn deinit(self: *Corpus) void {
        self.arena.deinit();
        self.gpa.destroy(self.arena);
    }

    pub fn findPattern(self: *const Corpus, id: []const u8) ?*const Pattern {
        for (self.patterns) |*pattern| {
            if (std.mem.eql(u8, pattern.id, id)) return pattern;
        }
        return null;
    }

    pub fn findRule(self: *const Corpus, id: []const u8) ?*const Rule {
        for (self.rules) |*rule| {
            if (std.mem.eql(u8, rule.id, id)) return rule;
        }
        return null;
    }

    pub fn findSource(self: *const Corpus, id: []const u8) ?*const Source {
        for (self.sources) |*source| {
            if (std.mem.eql(u8, source.id, id)) return source;
        }
        return null;
    }
};

pub const LoadError = error{
    OutOfMemory,
    FileNotFound,
    ParseError,
    CorpusIncomplete,
};

/// Maximum size of a single corpus file (the corpus is a few tens of KiB).
const max_file_bytes = 4 * 1024 * 1024;

/// Loads the five corpus files from `dir_path` (e.g. `data/advice`).
pub fn load(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8) !Corpus {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    errdefer gpa.destroy(arena);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    const agpa = arena.allocator();

    const patterns_file = try parseFile(PatternsFile, io, agpa, dir_path, "patterns.zon");
    const rules_file = try parseFile(RulesFile, io, agpa, dir_path, "rules.zon");
    const guarantees_file = try parseFile(GuaranteesFile, io, agpa, dir_path, "guarantees.zon");
    const limits_file = try parseFile(LimitsFile, io, agpa, dir_path, "limits.zon");
    const sources_file = try parseFile(SourcesFile, io, agpa, dir_path, "sources.zon");

    if (patterns_file.patterns.len == 0) return error.CorpusIncomplete;
    if (rules_file.rules.len == 0) return error.CorpusIncomplete;

    return .{
        .gpa = gpa,
        .arena = arena,
        .version = patterns_file.version,
        .source_research_date = patterns_file.source_research_date,
        .patterns = patterns_file.patterns,
        .rules = rules_file.rules,
        .guarantees = guarantees_file.guarantees,
        .limits = .{
            .limits = limits_file.limits,
            .evidence_legend = limits_file.evidence_legend,
        },
        .sources = sources_file.sources,
    };
}

fn parseFile(
    comptime T: type,
    io: std.Io,
    gpa: std.mem.Allocator,
    dir_path: []const u8,
    file_name: []const u8,
) !T {
    const path = try std.fs.path.join(gpa, &.{ dir_path, file_name });
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(max_file_bytes),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return error.FileNotFound,
        else => return error.FileNotFound,
    };

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{
        .gpa = gpa,
        .arena = gpa,
        .source = source,
        .diagnostics = &diagnostics,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ParseZon => {
            var stderr_buf: [4096]u8 = undefined;
            var stderr = std.Io.File.stderr().writer(io, &stderr_buf);
            stderr.interface.print("corpus: cannot parse {s}\n", .{path}) catch {};
            for (diagnostics.errors) |diagnostic| {
                stderr.interface.print("corpus: {d}:{d}: {s}\n", .{
                    diagnostic.loc.line + 1,
                    diagnostic.loc.column + 1,
                    diagnostic.msg,
                }) catch {};
            }
            stderr.interface.flush() catch {};
            return error.ParseError;
        },
    };
}

test "evidence labels round-trip" {
    try std.testing.expectEqualStrings("FACT", Evidence.fact.label());
    try std.testing.expectEqual(Evidence.guidance, Evidence.parse("GUIDANCE"));
    try std.testing.expect(Evidence.parse("MAYBE") == null);
}

test "the shipped corpus loads with all its records" {
    var corpus = try load(std.testing.io, std.testing.allocator, "data/advice");
    defer corpus.deinit();

    try std.testing.expectEqual(@as(u32, 1), corpus.version);
    try std.testing.expectEqual(@as(usize, 12), corpus.patterns.len);
    try std.testing.expectEqual(@as(usize, 12), corpus.rules.len);
    try std.testing.expectEqual(@as(usize, 24), corpus.sources.len);
    try std.testing.expect(corpus.findPattern("P03") != null);
    try std.testing.expect(corpus.findSource("S24") != null);
    try std.testing.expect(corpus.limits.evidence_legend.len >= 4);
}

test "corpus lookups find records by id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const pattern = Pattern{
        .id = "P03",
        .name = "Data-oriented design",
        .what_data_controls = "Physical representation and transformations",
        .facts = &.{},
        .candidate_uses = &.{},
        .boundaries = &.{},
        .checks = &.{},
        .evidence = .synthesis,
        .sources = &.{"S06"},
    };
    const source = Source{
        .id = "S06",
        .author = "DPDK Project",
        .title = "Writing Efficient Code",
        .kind = "documentation",
        .url = "https://doc.dpdk.org/",
    };

    const test_arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    test_arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);

    const corpus = Corpus{
        .gpa = std.testing.allocator,
        .arena = test_arena,
        .version = 1,
        .source_research_date = "2026-11-09",
        .patterns = &.{pattern},
        .rules = &.{},
        .guarantees = &.{},
        .limits = .{ .limits = &.{}, .evidence_legend = &.{} },
        .sources = &.{source},
    };
    // `defer` runs in reverse order: destroy the arena only after it is deinited.
    defer std.testing.allocator.destroy(corpus.arena);
    defer corpus.arena.deinit();

    try std.testing.expect(corpus.findPattern("P03") != null);
    try std.testing.expect(corpus.findPattern("P99") == null);
    try std.testing.expect(corpus.findSource("S06") != null);
}
