const std = @import("std");

const Evidence = enum { fact, result, synthesis, guidance };

const Fact = struct {
    text: []const u8,
    source: []const u8,
    evidence: Evidence,
};

const Pattern = struct {
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

const PatternsFile = struct {
    version: u32,
    source_research_date: []const u8,
    patterns: []const Pattern,
};

const Rule = struct {
    id: []const u8,
    condition: []const u8,
    then: struct {
        consider: []const []const u8,
        and_only_if: ?[]const u8 = null,
    },
    evidence: Evidence,
};

const RulesFile = struct {
    version: u32,
    rules: []const Rule,
};

const Guarantee = struct {
    id: []const u8,
    claim: []const u8,
    evidence: Evidence,
    guidance: ?[]const u8 = null,
    sources: []const []const u8,
};

const GuaranteesFile = struct {
    version: u32,
    guarantees: []const Guarantee,
};

const LimitsFile = struct {
    version: u32,
    limits: []const []const u8,
    evidence_legend: []const struct {
        label: []const u8,
        meaning: []const u8,
    },
};

const Source = struct {
    id: []const u8,
    author: []const u8,
    title: []const u8,
    kind: []const u8,
    url: []const u8,
};

const SourcesFile = struct {
    version: u32,
    sources: []const Source,
};

var failures: usize = 0;
var io_glob: std.Io = undefined;

fn fail(comptime fmt: []const u8, args: anytype) void {
    failures += 1;
    const stderr = std.Io.File.stderr();
    var buf: [8192]u8 = undefined;
    var w = stderr.writer(io_glob, &buf);
    w.interface.print("error: ", .{}) catch {};
    w.interface.print(fmt ++ "\n", args) catch {};
    w.interface.flush() catch {};
}

fn isPxx(id: []const u8, tag: u8) bool {
    if (id.len != 3) return false;
    if (id[0] != tag) return false;
    if (id[1] < '0' or id[1] > '9') return false;
    if (id[2] < '0' or id[2] > '9') return false;
    const n = (id[1] - '0') * 10 + (id[2] - '0');
    return n >= 1 and n <= 12;
}

fn isSxx(id: []const u8) bool {
    if (id.len != 3) return false;
    if (id[0] != 'S') return false;
    if (id[1] < '0' or id[1] > '9') return false;
    if (id[2] < '0' or id[2] > '9') return false;
    return true;
}

fn hasDuplicate(ids: []const []const u8) bool {
    for (ids, 0..) |id, i| {
        for (ids[i + 1 ..]) |other| {
            if (std.mem.eql(u8, id, other)) return true;
        }
    }
    return false;
}

fn hasSource(ids: []const []const u8, id: []const u8) bool {
    for (ids) |x| {
        if (std.mem.eql(u8, x, id)) return true;
    }
    return false;
}

fn parseZon(comptime T: type, scratch: std.mem.Allocator, arena: std.mem.Allocator, source: [:0]const u8, fname: []const u8) !T {
    var diag: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(T, .{
        .gpa = scratch,
        .arena = arena,
        .source = source,
        .diagnostics = &diag,
    }) catch |err| {
        if (err == error.ParseZon) {
            const stderr = std.Io.File.stderr();
            var buf: [8192]u8 = undefined;
            var w = stderr.writer(io_glob, &buf);
            w.interface.print("error: {s}: failed to parse ZON\n", .{fname}) catch {};
            w.interface.print("{f}\n", .{diag.fmt(fname)}) catch {};
            w.interface.flush() catch {};
        }
        return err;
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    io_glob = io;
    const gpa = init.gpa;

    var args_iter = try init.minimal.args.iterateAllocator(gpa);
    defer args_iter.deinit();
    var data_dir: []const u8 = "data/advice";
    var arg_index: usize = 0;
    while (args_iter.next()) |a| {
        if (arg_index == 1) data_dir = a;
        arg_index += 1;
    }

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Scratch allocator for ZON parse temporaries: the parsed results themselves
    // live in `alloc` (the arena above), which outlives the validation below.
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    const scratch_alloc = scratch.allocator();

    const dir = std.Io.Dir.cwd();

    const patterns_src = try dir.readFileAllocOptions(io, try std.fmt.allocPrint(alloc, "{s}/patterns.zon", .{data_dir}), alloc, .unlimited, .of(u8), 0);
    const rules_src = try dir.readFileAllocOptions(io, try std.fmt.allocPrint(alloc, "{s}/rules.zon", .{data_dir}), alloc, .unlimited, .of(u8), 0);
    const guarantees_src = try dir.readFileAllocOptions(io, try std.fmt.allocPrint(alloc, "{s}/guarantees.zon", .{data_dir}), alloc, .unlimited, .of(u8), 0);
    const limits_src = try dir.readFileAllocOptions(io, try std.fmt.allocPrint(alloc, "{s}/limits.zon", .{data_dir}), alloc, .unlimited, .of(u8), 0);
    const sources_src = try dir.readFileAllocOptions(io, try std.fmt.allocPrint(alloc, "{s}/sources.zon", .{data_dir}), alloc, .unlimited, .of(u8), 0);

    const patterns_file = parseZon(PatternsFile, scratch_alloc, alloc, patterns_src, "patterns.zon") catch std.process.exit(1);
    const rules_file = parseZon(RulesFile, scratch_alloc, alloc, rules_src, "rules.zon") catch std.process.exit(1);
    const guarantees_file = parseZon(GuaranteesFile, scratch_alloc, alloc, guarantees_src, "guarantees.zon") catch std.process.exit(1);
    const limits_file = parseZon(LimitsFile, scratch_alloc, alloc, limits_src, "limits.zon") catch std.process.exit(1);
    const sources_file = parseZon(SourcesFile, scratch_alloc, alloc, sources_src, "sources.zon") catch std.process.exit(1);

    // Build source id set.
    const source_ids = try alloc.alloc([]const u8, sources_file.sources.len);
    for (sources_file.sources, 0..) |s, idx| {
        source_ids[idx] = s.id;
        if (!isSxx(s.id)) fail("source id '{s}' is not S + two digits", .{s.id});
    }
    if (hasDuplicate(source_ids)) fail("duplicate source id in sources.zon", .{});
    if (sources_file.sources.len == 0) fail("sources.zon has no sources", .{});

    // Patterns.
    const pattern_ids = try alloc.alloc([]const u8, patterns_file.patterns.len);
    for (patterns_file.patterns, 0..) |p, idx| {
        pattern_ids[idx] = p.id;
        if (!isPxx(p.id, 'P')) fail("pattern id '{s}' is not P01..P12", .{p.id});
        for (p.sources) |s| {
            if (!isSxx(s)) fail("pattern {s} source '{s}' is not S + two digits", .{ p.id, s });
            if (!hasSource(source_ids, s)) fail("pattern {s} references unknown source '{s}'", .{ p.id, s });
            var in_facts = false;
            for (p.facts) |fact| {
                if (std.mem.eql(u8, fact.source, s)) in_facts = true;
            }
            if (!in_facts) fail("pattern {s} sources entry '{s}' does not appear among its facts[].source values", .{ p.id, s });
        }
        for (p.facts) |fact| {
            if (!isSxx(fact.source)) fail("pattern {s} fact source '{s}' is not S + two digits", .{ p.id, fact.source });
            if (!hasSource(source_ids, fact.source)) fail("pattern {s} fact references unknown source '{s}'", .{ p.id, fact.source });
        }
    }
    if (hasDuplicate(pattern_ids)) fail("duplicate pattern id in patterns.zon", .{});
    if (patterns_file.patterns.len != 12) fail("expected 12 patterns, found {d}", .{patterns_file.patterns.len});

    // Rules.
    const rule_ids = try alloc.alloc([]const u8, rules_file.rules.len);
    for (rules_file.rules, 0..) |r, idx| {
        rule_ids[idx] = r.id;
        if (!isPxx(r.id, 'R')) fail("rule id '{s}' is not R01..R12", .{r.id});
        for (r.then.consider) |c| {
            if (!isPxx(c, 'P')) fail("rule {s} consider '{s}' is not P01..P12", .{ r.id, c });
        }
    }
    if (hasDuplicate(rule_ids)) fail("duplicate rule id in rules.zon", .{});
    if (rules_file.rules.len != 12) fail("expected 12 rules, found {d}", .{rules_file.rules.len});

    // Guarantees.
    for (guarantees_file.guarantees) |g| {
        for (g.sources) |s| {
            if (!isSxx(s)) fail("guarantee {s} source '{s}' is not S + two digits", .{ g.id, s });
            if (!hasSource(source_ids, s)) fail("guarantee {s} references unknown source '{s}'", .{ g.id, s });
        }
    }

    if (failures != 0) {
        const stderr = std.Io.File.stderr();
        var buf: [8192]u8 = undefined;
        var w = stderr.writer(io, &buf);
        w.interface.print("advice_check: {d} error(s)\n", .{failures}) catch {};
        w.interface.flush() catch {};
        std.process.exit(1);
    }

    var obuf: [8192]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var ow = stdout.writer(io, &obuf);
    ow.interface.print("advice_check: ok — {d} patterns, {d} rules, {d} guarantees, {d} limits, {d} sources\n", .{
        patterns_file.patterns.len,
        rules_file.rules.len,
        guarantees_file.guarantees.len,
        limits_file.limits.len,
        sources_file.sources.len,
    }) catch {};
    try ow.interface.flush();
}
