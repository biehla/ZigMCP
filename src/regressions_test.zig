//! Cross-cutting handler tests: the real advice corpus plus a loaded doc index.
//!
//! These need a `Corpus`, a `Matcher` and a `Store` at once, which module-local
//! test blocks cannot share, so they use the `Harness` below. The file used to
//! be `PLAN.md`'s red-by-design suite: every item it covered is fixed, the
//! pure-function tests moved into `registry.zig` and `text.zig`, and what
//! remains are permanent regressions for behaviour that must not come back.
//!
//! Run with `zig build test-regressions`, or as part of `zig build test`
//! (`src/root.zig` imports this file).

const std = @import("std");
const registry = @import("server/registry.zig");
const tools = @import("server/tools.zig");
const resources = @import("server/resources.zig");
const prompts = @import("server/prompts.zig");
const log_module = @import("server/log.zig");
const corpus_module = @import("advice/corpus.zig");
const rules_module = @import("advice/rules.zig");
const docs_index = @import("docs/index.zig");
const docs_reload = @import("docs/reload.zig");
const pool_module = @import("util/arena_pool.zig");
const text_util = @import("util/text.zig");
const json_array = @import("util/json_array.zig");

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
    log: log_module.Queue,
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
    harness.log = .{};

    harness.ctx = .{
        .gpa = gpa,
        .io = std.testing.io,
        .pool = &harness.pool,
        .corpus = &harness.corpus,
        .matcher = &harness.matcher,
        .docs = &harness.store,
        .index_path = null,
        .log = &harness.log,
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
        \\{"project":"Fixture","commit":"c1","path":"A.zig","line":1,"kind":"fn","symbol":"a","container":"","doc":"alpha docs","doc_hash":"36a69add5014cf58a2cee74b1c30ef5fe3b80cd48ab14cd5e5efa3b22dc8dc2d"}
        \\{"project":"fixture","commit":"c2","path":"b.zig","line":2,"kind":"fn","symbol":"b","container":"","doc":"alpha docs","doc_hash":"36a69add5014cf58a2cee74b1c30ef5fe3b80cd48ab14cd5e5efa3b22dc8dc2d"}
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

test "GUIDE-2: resource families dispatch through the table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // A one-record index for project `p`, so both families have something to serve.
    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"p","commit":"c","path":"a.zig","line":1,"kind":"fn","symbol":"s","container":"","doc":"alpha docs","doc_hash":"36a69add5014cf58a2cee74b1c30ef5fe3b80cd48ab14cd5e5efa3b22dc8dc2d"}
    );

    // A URI shape is a table row, a fixed URI is not a family.
    try std.testing.expect(resources.findFamily("advice://patterns/P03") != null);
    try std.testing.expect(resources.findFamily("docs://p/index") != null);
    try std.testing.expect(resources.findFamily("advice://overview") == null);

    for ([_][]const u8{ "advice://patterns/P03", "docs://p/index", "docs://p/symbols/s" }) |uri| {
        _ = resources.read(&harness.ctx, uri) catch |err| {
            std.debug.print("family URI unreadable: {s} ({s})\n", .{ uri, @errorName(err) });
            return err;
        };
    }
}

test "GUIDE-2: prompts dispatch through the table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarness(gpa);

    for (prompts.prompt_specs) |spec| {
        var args: std.json.ObjectMap = .{};
        try args.put(gpa, spec.argument, .{ .string = "memory-bound workload" });
        const result = try prompts.get(&harness.ctx, spec.name, .{ .object = args });
        const text = result.value.object.get("messages").?.array.items[0]
            .object.get("content").?.object.get("text").?.string;
        // Both builders emit this word; a wrong or missing handler cannot.
        try std.testing.expect(std.mem.indexOf(u8, text, "GUIDANCE") != null);
    }
}

test "GUIDE-4/SRV-7: a query beyond the input bounds is invalid params" {
    // The §0 amplification recipe: a 60 KB query used to be scored token by
    // token against every record (19.7 s on a 50 000-record index), and
    // nothing bounded the string at all before the search.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const harness = try startHarness(gpa);

    const huge = try gpa.alloc(u8, 60 * 1024);
    @memset(huge, 'x');
    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "query", .{ .string = huge });
    try std.testing.expectError(
        error.InvalidParams,
        tools.docSearch(&harness.ctx, .{ .object = args }),
    );

    // Within the byte bound but over the token bound: still invalid params,
    // not a silent truncation.
    var many: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < registry.max_query_tokens + 1) : (index += 1) try many.appendSlice(gpa, "memo ");
    var token_args: std.json.ObjectMap = .{};
    try token_args.put(gpa, "query", .{ .string = many.items });
    try std.testing.expectError(
        error.InvalidParams,
        tools.docSearch(&harness.ctx, .{ .object = token_args }),
    );

    // A bounded query reaches the index: an empty one answers "nothing
    // matched", which is a result, not an error.
    var small: std.ArrayList(u8) = .empty;
    index = 0;
    while (index < 8) : (index += 1) try small.appendSlice(gpa, "memo ");
    var ok_args: std.json.ObjectMap = .{};
    try ok_args.put(gpa, "query", .{ .string = small.items });
    const outcome = try tools.docSearch(&harness.ctx, .{ .object = ok_args });
    try std.testing.expect(outcome.is_error);

    // The advice question mode and the signal set share the bound.
    const question = try gpa.alloc(u8, registry.max_string_bytes + 1);
    @memset(question, 'q');
    var question_args: std.json.ObjectMap = .{};
    try question_args.put(gpa, "question", .{ .string = question });
    try std.testing.expectError(
        error.InvalidParams,
        tools.adviceLookup(&harness.ctx, .{ .object = question_args }),
    );
}

test "PROTO-5: constraints take part in rule matching" {
    // PROTO-5: `constraints` was accepted and ignored, so a caller believed it
    // filtered. Its string leaves now join the matcher's signal tokens while
    // the echoed `signals` stay exactly what the caller sent.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const harness = try startHarness(gpa);

    var bare: std.json.ObjectMap = .{};
    var bare_signals: std.json.Array = json_array.init(gpa);
    try json_array.append(&bare_signals, gpa, .{ .string = "unrelated observation" });
    try bare.put(gpa, "signals", .{ .array = bare_signals });
    const unmatched = try tools.recommendApproach(&harness.ctx, .{ .object = bare });
    try std.testing.expect(unmatched.is_error);

    var constraint: std.json.ObjectMap = .{};
    try constraint.put(gpa, "note", .{ .string = "measured memory bottleneck" });
    var with_constraints: std.json.ObjectMap = .{};
    var signals: std.json.Array = json_array.init(gpa);
    try json_array.append(&signals, gpa, .{ .string = "unrelated observation" });
    try with_constraints.put(gpa, "signals", .{ .array = signals });
    try with_constraints.put(gpa, "constraints", .{ .object = constraint });

    const matched = try tools.recommendApproach(&harness.ctx, .{ .object = with_constraints });
    try std.testing.expect(!matched.is_error);
    const structured = matched.structured.?.object;
    const matches = structured.get("matches").?.array.items;
    try std.testing.expect(matches.len > 0);
    try std.testing.expectEqualStrings("R03", matches[0].object.get("rule_id").?.string);
    // The echo is the caller's signals only: the constraint text is input to
    // the matcher, not output.
    try std.testing.expectEqual(@as(usize, 1), structured.get("signals").?.array.items.len);
}

test "IDX-4: doc_get returns every record sharing a symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    // Two records with the same symbol path: the container record styles of a
    // `//!` module and of a declaration in the sibling `<dir>.zig` collide.
    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"p","commit":"c1","path":"a.zig","line":1,"kind":"fn","symbol":"mod.dup","container":"mod","doc":"alpha docs","doc_hash":"36a69add5014cf58a2cee74b1c30ef5fe3b80cd48ab14cd5e5efa3b22dc8dc2d"}
        \\{"project":"p","commit":"c2","path":"b.zig","line":2,"kind":"container","symbol":"mod.dup","container":"","doc":"beta docs","doc_hash":"b507a2bbaa3c9ea48eb66a2b270e02fe438ccf1138feb6714b7d03897e7aa8e9"}
    );

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "project", .{ .string = "p" });
    try args.put(gpa, "symbol", .{ .string = "MOD.DUP" });

    const outcome = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(!outcome.is_error);

    const structured = outcome.structured.?.object;
    try std.testing.expect(structured.get("found").?.bool);
    // The caller's spelling is echoed, not the stored one.
    try std.testing.expectEqualStrings("MOD.DUP", structured.get("symbol").?.string);

    const matches = structured.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), matches.len);
    try std.testing.expectEqualStrings("a.zig", matches[0].object.get("path").?.string);
    try std.testing.expectEqualStrings("alpha docs", matches[0].object.get("doc").?.string);
    try std.testing.expectEqualStrings("b.zig", matches[1].object.get("path").?.string);
    try std.testing.expectEqualStrings("container", matches[1].object.get("kind").?.string);
    try std.testing.expectEqualStrings("", matches[1].object.get("container").?.string);
}

test "doc_get: a miss names the stored path-qualified symbols" {
    // PROTO-15: the index stores path-qualified symbols, so the readme's own
    // unqualified example found nothing and gave the caller no next step.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"zig_std","commit":"c","path":"lib/std/mem.zig","line":238,"kind":"fn","symbol":"lib.std.mem.copyForwards","container":"lib.std.mem","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
        \\{"project":"zig_std","commit":"c","path":"lib/std/std.zig","line":48,"kind":"container","symbol":"lib.std.std.ArrayList","container":"","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
    );

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "project", .{ .string = "zig_std" });
    try args.put(gpa, "symbol", .{ .string = "mem.copyForwards" });

    const unqualified = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(unqualified.is_error);
    const unqualified_structured = unqualified.structured.?.object;
    try std.testing.expect(!unqualified_structured.get("found").?.bool);
    const candidates = unqualified_structured.get("candidates").?.array.items;
    try std.testing.expect(candidates.len >= 1);
    try std.testing.expectEqualStrings("lib.std.mem.copyForwards", candidates[0].string);
    try std.testing.expect(std.mem.indexOf(u8, unqualified.text, "lib.std.mem.copyForwards") != null);
    try std.testing.expect(std.mem.indexOf(u8, unqualified.text, "doc_search") != null);

    // A container-only name still reaches the type through its tokens.
    try args.put(gpa, "symbol", .{ .string = "ArrayList.append" });
    const container_miss = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(container_miss.is_error);
    const container_candidates = container_miss.structured.?.object.get("candidates").?.array.items;
    try std.testing.expectEqualStrings("lib.std.std.ArrayList", container_candidates[0].string);
}

test "PROTO-14: a separator spelling reaches the records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"zig_std","commit":"c","path":"mem.zig","line":1,"kind":"fn","symbol":"mem.copyForwards","container":"mem","doc":"alpha docs","doc_hash":"36a69add5014cf58a2cee74b1c30ef5fe3b80cd48ab14cd5e5efa3b22dc8dc2d"}
    );

    // `zig-std` is what a caller types; the stored key is `zig_std`.
    var search_args: std.json.ObjectMap = .{};
    try search_args.put(gpa, "query", .{ .string = "alpha" });
    try search_args.put(gpa, "project", .{ .string = "zig-std" });
    const search = try tools.docSearch(&harness.ctx, .{ .object = search_args });
    try std.testing.expect(!search.is_error);
    try std.testing.expectEqual(@as(i64, 1), search.structured.?.object.get("count").?.integer);

    // Case is forgiven too, and the caller's spelling is what comes back.
    var get_args: std.json.ObjectMap = .{};
    try get_args.put(gpa, "project", .{ .string = "ZIG_STD" });
    try get_args.put(gpa, "symbol", .{ .string = "mem.copyforwards" });
    const get = try tools.docGet(&harness.ctx, .{ .object = get_args });
    try std.testing.expect(!get.is_error);
    const structured = get.structured.?.object;
    try std.testing.expect(structured.get("found").?.bool);
    try std.testing.expectEqualStrings("ZIG_STD", structured.get("project").?.string);
}

test "PROTO-14: a wrong project names the ones that exist" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"mcp_zig","commit":"c","path":"b.zig","line":1,"kind":"fn","symbol":"b","container":"","doc":"alpha docs","doc_hash":"36a69add5014cf58a2cee74b1c30ef5fe3b80cd48ab14cd5e5efa3b22dc8dc2d"}
        \\{"project":"zig_std","commit":"c","path":"a.zig","line":1,"kind":"fn","symbol":"a","container":"","doc":"alpha docs","doc_hash":"36a69add5014cf58a2cee74b1c30ef5fe3b80cd48ab14cd5e5efa3b22dc8dc2d"}
    );

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "query", .{ .string = "alpha" });
    try args.put(gpa, "project", .{ .string = "nope" });
    const outcome = try tools.docSearch(&harness.ctx, .{ .object = args });
    try std.testing.expect(outcome.is_error);
    try std.testing.expectEqual(@as(i64, 0), outcome.structured.?.object.get("count").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, outcome.text, "Known projects: mcp_zig, zig_std") != null);
}

test "PROTO-14: one spelling matching two keys is ambiguous" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"Fixture","commit":"c1","path":"A.zig","line":1,"kind":"fn","symbol":"a","container":"","doc":"alpha docs","doc_hash":"36a69add5014cf58a2cee74b1c30ef5fe3b80cd48ab14cd5e5efa3b22dc8dc2d"}
        \\{"project":"fixture","commit":"c2","path":"b.zig","line":2,"kind":"fn","symbol":"b","container":"","doc":"alpha docs","doc_hash":"36a69add5014cf58a2cee74b1c30ef5fe3b80cd48ab14cd5e5efa3b22dc8dc2d"}
    );

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "query", .{ .string = "alpha" });
    try args.put(gpa, "project", .{ .string = "FIXTURE" });
    const outcome = try tools.docSearch(&harness.ctx, .{ .object = args });
    try std.testing.expect(outcome.is_error);
    try std.testing.expectEqual(@as(i64, 0), outcome.structured.?.object.get("count").?.integer);
    try std.testing.expect(std.mem.indexOf(u8, outcome.text, "ambiguous") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.text, "Fixture") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.text, "fixture") != null);
}
