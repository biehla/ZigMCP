//! ZON schema for the advice corpus (AGENTS.md §7).
//!
//! One definition shared by the server, `advice_check` and `bench` through the
//! `advice_schema` module, so a schema change is one edit (GUIDE-3).

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

pub const PatternsFile = struct {
    version: u32,
    source_research_date: []const u8,
    patterns: []const Pattern,
};

pub const RulesFile = struct {
    version: u32,
    rules: []const Rule,
};

pub const GuaranteesFile = struct {
    version: u32,
    guarantees: []const Guarantee,
};

pub const LimitsFile = struct {
    version: u32,
    limits: []const []const u8,
    evidence_legend: []const LegendEntry,
};

pub const SourcesFile = struct {
    version: u32,
    sources: []const Source,
};
