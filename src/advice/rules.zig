//! Rule matcher over the SELECT rules (PLAN §6.1, P05).
//!
//! The 12 conditional rules are relational data over
//! `(condition → consider → constraint)`. `recommend_approach` is a join over
//! them: a signal matches a rule when their token sets overlap enough, and the
//! matched rule ids stay visible in the answer together with their evidence
//! label (all rules are GUIDANCE).

const std = @import("std");
const corpus_module = @import("corpus.zig");
const text_util = @import("../util/text.zig");

pub const Corpus = corpus_module.Corpus;
pub const Rule = corpus_module.Rule;

pub const Match = struct {
    rule: *const Rule,
    /// Fraction of the rule's condition tokens that the signals covered.
    score: f64,
    matched: []const []const u8,
};

/// Splits text into lowercase alphanumeric tokens of at least three characters.
pub fn tokenize(gpa: std.mem.Allocator, text: []const u8) ![][]const u8 {
    return text_util.tokenize(gpa, text);
}

fn containsToken(tokens: []const []const u8, needle: []const u8) bool {
    for (tokens) |token| {
        if (std.mem.eql(u8, token, needle)) return true;
    }
    return false;
}

/// Pre-computes the condition tokens once, so matching allocates nothing per
/// rule beyond the signal tokens themselves.
pub const Matcher = struct {
    corpus: *const Corpus,
    condition_tokens: []const []const []const u8,

    pub fn init(gpa: std.mem.Allocator, corpus: *const Corpus) !Matcher {
        const tokens = try gpa.alloc([]const []const u8, corpus.rules.len);
        for (corpus.rules, 0..) |rule, index| {
            tokens[index] = try tokenize(gpa, rule.condition);
        }
        return .{ .corpus = corpus, .condition_tokens = tokens };
    }

    /// Returns the rules whose condition the signals select, best match first.
    pub fn matchSignals(
        self: *const Matcher,
        gpa: std.mem.Allocator,
        signals: []const []const u8,
    ) ![]Match {
        var signal_tokens: std.ArrayList([]const u8) = .empty;
        for (signals) |signal| {
            const tokens = try tokenize(gpa, signal);
            for (tokens) |token| try signal_tokens.append(gpa, token);
        }

        var matches: std.ArrayList(Match) = .empty;
        for (self.corpus.rules, 0..) |*rule, index| {
            const condition = self.condition_tokens[index];
            if (condition.len == 0) continue;

            var matched: std.ArrayList([]const u8) = .empty;
            for (signal_tokens.items) |token| {
                if (containsToken(condition, token) and !containsToken(matched.items, token)) {
                    try matched.append(gpa, token);
                }
            }
            if (matched.items.len == 0) continue;

            const score = @as(f64, @floatFromInt(matched.items.len)) /
                @as(f64, @floatFromInt(condition.len));

            // One shared token only counts when it covers at least half of the
            // condition; two or more shared tokens always count.
            if (matched.items.len < 2 and score < 0.5) continue;

            try matches.append(gpa, .{
                .rule = rule,
                .score = score,
                .matched = matched.items,
            });
        }

        std.mem.sort(Match, matches.items, {}, lessThan);
        return matches.toOwnedSlice(gpa);
    }
};

fn lessThan(_: void, a: Match, b: Match) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.lessThan(u8, a.rule.id, b.rule.id);
}

/// A corpus holding only the given rules, for the matcher tests.
fn testCorpus(rules: []const corpus_module.Rule) !Corpus {
    const arena = try std.testing.allocator.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(std.testing.allocator);
    return .{
        .gpa = std.testing.allocator,
        .arena = arena,
        .version = 1,
        .source_research_date = "2026-11-09",
        .patterns = &.{},
        .rules = rules,
        .guarantees = &.{},
        .limits = .{ .limits = &.{}, .evidence_legend = &.{} },
        .sources = &.{},
    };
}

test "tokenizer drops short tokens and lowercases" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const tokens = try tokenize(gpa, "Repeated I/O over Changing Inputs");
    try std.testing.expectEqual(@as(usize, 4), tokens.len);
    try std.testing.expectEqualStrings("repeated", tokens[0]);
    try std.testing.expectEqualStrings("changing", tokens[2]);
}

test "a matching signal selects the corresponding rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const rules = [_]corpus_module.Rule{
        .{
            .id = "R06",
            .condition = "Repeated recomputation over changing inputs",
            .then = .{ .consider = &.{"P06"} },
            .evidence = .guidance,
        },
        .{
            .id = "R01",
            .condition = "Repeated variants within fixed semantics",
            .then = .{ .consider = &.{"P01"} },
            .evidence = .guidance,
        },
    };
    var corpus = try testCorpus(&rules);
    defer {
        corpus.arena.deinit();
        std.testing.allocator.destroy(corpus.arena);
    }

    var matcher = try Matcher.init(gpa, &corpus);
    const matches = try matcher.matchSignals(gpa, &.{"repeated recomputation over changing inputs"});

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("R06", matches[0].rule.id);
    try std.testing.expectEqual(corpus_module.Evidence.guidance, matches[0].rule.evidence);
}

test "an unrelated signal selects no rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const rules = [_]corpus_module.Rule{.{
        .id = "R10",
        .condition = "Representative execution measurements available",
        .then = .{ .consider = &.{"P10"} },
        .evidence = .guidance,
    }};
    var corpus = try testCorpus(&rules);
    defer {
        corpus.arena.deinit();
        std.testing.allocator.destroy(corpus.arena);
    }

    var matcher = try Matcher.init(gpa, &corpus);
    const matches = try matcher.matchSignals(gpa, &.{"colourful log rotation"});

    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "matches are ordered by score and then rule id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const rules = [_]corpus_module.Rule{
        .{
            .id = "R02",
            .condition = "Input matching dominates control logic",
            .then = .{ .consider = &.{"P02"} },
            .evidence = .guidance,
        },
        .{
            .id = "R03",
            .condition = "Measured memory/access bottleneck",
            .then = .{ .consider = &.{"P03"} },
            .evidence = .guidance,
        },
    };
    var corpus = try testCorpus(&rules);
    defer {
        corpus.arena.deinit();
        std.testing.allocator.destroy(corpus.arena);
    }

    var matcher = try Matcher.init(gpa, &corpus);
    const matches = try matcher.matchSignals(gpa, &.{"measured memory bottleneck"});

    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("R03", matches[0].rule.id);
}
