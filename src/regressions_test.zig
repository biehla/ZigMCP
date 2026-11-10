//! Regression tests for the open defects in `PLAN.md`.
//!
//! Each test names the backlog id and asserts the behaviour the plan wants, not
//! the behaviour the code has today — so a red test is a known, tracked bug and
//! fixing the bug turns it green. This file is deliberately **not** imported by
//! `src/root.zig`: the main suite (`zig build test`) must stay green while the
//! backlog is open. Run it with `zig build test-regressions`.
//!
//! Only defects reachable from a pure function or a handler are here. Items that
//! need the built server process (SRV-1, SRV-2, SRV-3), the indexer executable
//! (IDX-*), the watcher thread (REL-*) or a CI runner (CI-*) are listed in
//! `PLAN.md` §10 with the reason and the layer that should own them.

const std = @import("std");
const registry = @import("server/registry.zig");
const tools = @import("server/tools.zig");
const resources = @import("server/resources.zig");
const corpus_module = @import("advice/corpus.zig");
const rules_module = @import("advice/rules.zig");
const docs_index = @import("docs/index.zig");
const docs_reload = @import("docs/reload.zig");
const pool_module = @import("util/arena_pool.zig");
const text_util = @import("util/text.zig");

/// A server context with the real corpus and an empty doc index.
///
/// Everything is allocated from the caller's arena, so the test only has to
/// deinit the arena; the corpus, matcher, store and pool point into this
/// struct, which is why it is heap-allocated rather than returned by value.
const Harness = struct {
    corpus: corpus_module.Corpus,
    matcher: rules_module.Matcher,
    store: docs_reload.Store,
    pool: pool_module.ArenaPool,
    ctx: registry.Context,
};

fn startHarness(gpa: std.mem.Allocator) !*Harness {
    return startHarnessWithIndex(gpa, "");
}

/// A harness whose doc index holds `jsonl` instead of being empty. The JSONL is
/// loaded from bytes, so a test never needs a scratch file.
fn startHarnessWithIndex(gpa: std.mem.Allocator, jsonl: []const u8) !*Harness {
    const harness = try gpa.create(Harness);
    harness.corpus = try corpus_module.load(std.testing.io, gpa, "data/advice");
    harness.matcher = try rules_module.Matcher.init(gpa, &harness.corpus);

    const index = try gpa.create(docs_index.Index);
    index.* = try docs_index.load(gpa, jsonl);
    harness.store = docs_reload.Store.init(gpa, index);
    harness.pool = try pool_module.ArenaPool.init(gpa);

    harness.ctx = .{
        .gpa = gpa,
        .io = std.testing.io,
        .pool = &harness.pool,
        .corpus = &harness.corpus,
        .matcher = &harness.matcher,
        .docs = &harness.store,
        .index_path = null,
    };
    return harness;
}

test "control: the harness serves a known-good resource" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const harness = try startHarness(arena.allocator());

    const result = try resources.read(&harness.ctx, "advice://overview");
    try std.testing.expect(result.value.object.get("contents") != null);
}

test "PROTO-1: every listed resource can be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const harness = try startHarness(arena.allocator());

    // resources/list advertises every entry of resource_specs; a resource the
    // server lists but cannot read is a client-visible contract break.
    for (resources.resource_specs) |spec| {
        _ = resources.read(&harness.ctx, spec.uri) catch |err| {
            std.debug.print("listed but unreadable: {s} ({s})\n", .{ spec.uri, @errorName(err) });
            return err;
        };
    }
}

test "PROTO-2: doc_import_status rejects unknown arguments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const harness = try startHarness(gpa);

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "bogus", .{ .integer = 1 });

    // registry.validate documents that unknown members are invalid params.
    try std.testing.expectError(
        error.InvalidParams,
        tools.docImportStatus(&harness.ctx, .{ .object = args }),
    );
}

test "PROTO-6: advice_lookup rejects concept and question together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const harness = try startHarness(gpa);

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "concept", .{ .string = "P03" });
    try args.put(gpa, "question", .{ .string = "cache-friendly layout" });

    // Two mutually exclusive selectors must not be resolved silently.
    try std.testing.expectError(
        error.InvalidParams,
        tools.adviceLookup(&harness.ctx, .{ .object = args }),
    );
}

test "PROTO-13: projects differing only in case stay distinct" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"Fixture","commit":"c1","path":"A.zig","line":1,"kind":"fn","symbol":"a","container":"","doc":"alpha docs","doc_hash":"h1"}
        \\{"project":"fixture","commit":"c2","path":"b.zig","line":2,"kind":"fn","symbol":"b","container":"","doc":"alpha docs","doc_hash":"h2"}
    );

    // A project-scoped URI lists only that project's records: the two keys are
    // distinct identifiers, not the same project spelled differently.
    const lower = try resources.read(&harness.ctx, "docs://fixture/index");
    const lower_text = lower.value.object.get("contents").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("b.zig:2 b\n", lower_text);

    const upper = try resources.read(&harness.ctx, "docs://Fixture/index");
    const upper_text = upper.value.object.get("contents").?.array.items[0].object.get("text").?.string;
    try std.testing.expectEqualStrings("A.zig:1 a\n", upper_text);

    // A project-scoped search does the same.
    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "query", .{ .string = "alpha" });
    try args.put(gpa, "project", .{ .string = "fixture" });
    const outcome = try tools.docSearch(&harness.ctx, .{ .object = args });
    const structured = outcome.structured.?.object;
    try std.testing.expectEqual(@as(i64, 1), structured.get("count").?.integer);
}
