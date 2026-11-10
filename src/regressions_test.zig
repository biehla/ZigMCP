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
    // The amplification recipe in `PLAN.md` §2.2: a 60 KB query used to be scored
    // token by token against every record (19.7 s on a 50 000-record index), and
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

test "PROTO-16: a unique dotted tail reaches the stored symbol" {
    // `mem.copyForwards` is the same declaration the index stores as
    // `lib.std.mem.copyForwards`. The tail resolves only when exactly one stored
    // symbol ends with it and the boundary is a `.` — otherwise the caller would
    // get an answer for a spelling nobody stored.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"zig_std","commit":"c","path":"lib/std/mem.zig","line":238,"kind":"fn","symbol":"lib.std.mem.copyForwards","container":"lib.std.mem","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
        \\{"project":"zig_std","commit":"c","path":"lib/std/std.zig","line":48,"kind":"container","symbol":"lib.std.std.ArrayList","container":"","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
        \\{"project":"zig_std","commit":"c","path":"mod/a.zig","line":3,"kind":"fn","symbol":"mod.a.dup","container":"mod.a","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
        \\{"project":"zig_std","commit":"c","path":"mod/b.zig","line":4,"kind":"fn","symbol":"mod.b.dup","container":"mod.b","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
    );

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "project", .{ .string = "zig_std" });
    try args.put(gpa, "symbol", .{ .string = "mem.copyForwards" });

    const resolved = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(!resolved.is_error);
    const structured = resolved.structured.?.object;
    try std.testing.expect(structured.get("found").?.bool);
    // The caller's spelling is echoed, and the resolution is stated rather than
    // passed off as a stored name.
    try std.testing.expectEqualStrings("mem.copyForwards", structured.get("symbol").?.string);
    try std.testing.expectEqualStrings("mem.copyForwards", structured.get("resolved_from").?.string);
    const matches = structured.get("matches").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), matches.len);
    try std.testing.expectEqualStrings("lib.std.mem.copyForwards", matches[0].object.get("symbol").?.string);
    try std.testing.expect(std.mem.indexOf(u8, resolved.text, "Resolved 'mem.copyForwards' to lib.std.mem.copyForwards") != null);

    // The boundary is a component, not a substring: `em.copyForwards` is inside
    // the stored name but is not a tail of it.
    try args.put(gpa, "symbol", .{ .string = "em.copyForwards" });
    const boundary = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(boundary.is_error);
    try std.testing.expect(!boundary.structured.?.object.get("found").?.bool);

    // Two stored symbols share the tail, so resolving it would be a guess.
    try args.put(gpa, "symbol", .{ .string = "dup" });
    const ambiguous = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(ambiguous.is_error);
    const ambiguous_structured = ambiguous.structured.?.object;
    try std.testing.expect(!ambiguous_structured.get("found").?.bool);
    try std.testing.expect(ambiguous_structured.get("candidates").?.array.items.len >= 2);
}

test "PROTO-16: only a dotted tail of one stored symbol resolves" {
    // One case per guard: case-insensitivity, the `.` boundary on both sides,
    // an empty argument, and a name that exists only as a container record.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"zig_std","commit":"c","path":"lib/std/mem.zig","line":238,"kind":"fn","symbol":"lib.std.mem.copyForwards","container":"lib.std.mem","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
        \\{"project":"zig_std","commit":"c","path":"lib/std/std.zig","line":48,"kind":"container","symbol":"lib.std.std.ArrayList","container":"","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
    );

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "project", .{ .string = "zig_std" });

    // Case is forgiven here as in the exact lookup, and the argument is echoed
    // as sent.
    try args.put(gpa, "symbol", .{ .string = "MEM.COPYFORWARDS" });
    const upper = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(!upper.is_error);
    const upper_structured = upper.structured.?.object;
    try std.testing.expectEqualStrings("MEM.COPYFORWARDS", upper_structured.get("resolved_from").?.string);
    try std.testing.expectEqualStrings(
        "lib.std.mem.copyForwards",
        upper_structured.get("matches").?.array.items[0].object.get("symbol").?.string,
    );
    // The two hints are exclusive: a hit reports how it resolved, a miss reports
    // what it could have been — never both.
    try std.testing.expect(upper_structured.get("candidates") == null);

    // A leading dot is the separator, not part of the tail; a trailing dot names
    // nothing stored.
    for ([_][]const u8{ ".copyForwards", "mem.copyForwards." }) |spelling| {
        try args.put(gpa, "symbol", .{ .string = spelling });
        const miss = try tools.docGet(&harness.ctx, .{ .object = args });
        try std.testing.expect(miss.is_error);
        const miss_structured = miss.structured.?.object;
        try std.testing.expect(!miss_structured.get("found").?.bool);
        // A miss never claims a resolution, and never carries `matches`.
        try std.testing.expect(miss_structured.get("resolved_from") == null);
        try std.testing.expect(miss_structured.get("matches") == null);
    }

    // The last component on its own is a tail, so it resolves.
    try args.put(gpa, "symbol", .{ .string = "copyForwards" });
    const component = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(!component.is_error);
    try std.testing.expectEqualStrings(
        "lib.std.mem.copyForwards",
        component.structured.?.object.get("matches").?.array.items[0].object.get("symbol").?.string,
    );

    // The container record's own name is a tail of itself, so a type name reaches
    // its `//!` doc rather than a miss.
    try args.put(gpa, "symbol", .{ .string = "ArrayList" });
    const type_name = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(!type_name.is_error);
    const type_structured = type_name.structured.?.object;
    try std.testing.expectEqualStrings("ArrayList", type_structured.get("resolved_from").?.string);
    try std.testing.expectEqualStrings(
        "lib.std.std.ArrayList",
        type_structured.get("matches").?.array.items[0].object.get("symbol").?.string,
    );

    // An empty argument resolves nothing and resembles nothing.
    try args.put(gpa, "symbol", .{ .string = "" });
    const empty = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(empty.is_error);
    try std.testing.expectEqual(
        @as(usize, 0),
        empty.structured.?.object.get("candidates").?.array.items.len,
    );

    // A member of a type whose members are not indexed is a miss, and the miss
    // names the type: this is the `std.ArrayList` case from `TODO.md`.
    try args.put(gpa, "symbol", .{ .string = "ArrayList.create" });
    const near = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(near.is_error);
    try std.testing.expectEqualStrings(
        "lib.std.std.ArrayList",
        near.structured.?.object.get("candidates").?.array.items[0].string,
    );
}

test "PROTO-15: the candidate list is bounded" {
    // The list is a next step, not a result set: a spelling that resembles many
    // symbols must not turn a miss into an unbounded payload.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"zig_std","commit":"c","path":"mod/w0.zig","line":1,"kind":"fn","symbol":"mod.widget0","container":"mod","doc":"shared widget docs.","doc_hash":"1a02e09bd08d42878bcfd694455c744688b8f480ca353def4f35ef5c5ca1c546"}
        \\{"project":"zig_std","commit":"c","path":"mod/w1.zig","line":1,"kind":"fn","symbol":"mod.widget1","container":"mod","doc":"shared widget docs.","doc_hash":"1a02e09bd08d42878bcfd694455c744688b8f480ca353def4f35ef5c5ca1c546"}
        \\{"project":"zig_std","commit":"c","path":"mod/w2.zig","line":1,"kind":"fn","symbol":"mod.widget2","container":"mod","doc":"shared widget docs.","doc_hash":"1a02e09bd08d42878bcfd694455c744688b8f480ca353def4f35ef5c5ca1c546"}
        \\{"project":"zig_std","commit":"c","path":"mod/w3.zig","line":1,"kind":"fn","symbol":"mod.widget3","container":"mod","doc":"shared widget docs.","doc_hash":"1a02e09bd08d42878bcfd694455c744688b8f480ca353def4f35ef5c5ca1c546"}
        \\{"project":"zig_std","commit":"c","path":"mod/w4.zig","line":1,"kind":"fn","symbol":"mod.widget4","container":"mod","doc":"shared widget docs.","doc_hash":"1a02e09bd08d42878bcfd694455c744688b8f480ca353def4f35ef5c5ca1c546"}
        \\{"project":"zig_std","commit":"c","path":"mod/w5.zig","line":1,"kind":"fn","symbol":"mod.widget5","container":"mod","doc":"shared widget docs.","doc_hash":"1a02e09bd08d42878bcfd694455c744688b8f480ca353def4f35ef5c5ca1c546"}
        \\{"project":"zig_std","commit":"c","path":"mod/w6.zig","line":1,"kind":"fn","symbol":"mod.widget6","container":"mod","doc":"shared widget docs.","doc_hash":"1a02e09bd08d42878bcfd694455c744688b8f480ca353def4f35ef5c5ca1c546"}
    );

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "project", .{ .string = "zig_std" });
    try args.put(gpa, "symbol", .{ .string = "widget" });

    const miss = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(miss.is_error);
    try std.testing.expectEqual(
        tools.max_get_candidates,
        miss.structured.?.object.get("candidates").?.array.items.len,
    );
}

test "PROTO-15: a miss names the stored path-qualified symbols" {
    // No record in this index carries a member of the type, so the tail names
    // nothing and the miss has to say what the index does hold.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const harness = try startHarnessWithIndex(gpa,
        \\{"project":"zig_std","commit":"c","path":"lib/std/mem.zig","line":238,"kind":"fn","symbol":"lib.std.mem.copyForwards","container":"lib.std.mem","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
        \\{"project":"zig_std","commit":"c","path":"lib/std/std.zig","line":48,"kind":"container","symbol":"lib.std.std.ArrayList","container":"","doc":"Copies source into dest.","doc_hash":"5b9b51d9a8c4c3a5174688eb4c984931a3874fe30db40b99c862e57c26ef97fa"}
    );

    var args: std.json.ObjectMap = .{};
    try args.put(gpa, "project", .{ .string = "zig_std" });
    try args.put(gpa, "symbol", .{ .string = "ArrayList.append" });

    const miss = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(miss.is_error);
    const structured = miss.structured.?.object;
    try std.testing.expect(!structured.get("found").?.bool);
    const candidates = structured.get("candidates").?.array.items;
    try std.testing.expect(candidates.len >= 1);
    try std.testing.expectEqualStrings("lib.std.std.ArrayList", candidates[0].string);
    try std.testing.expect(std.mem.indexOf(u8, miss.text, "lib.std.std.ArrayList") != null);
    try std.testing.expect(std.mem.indexOf(u8, miss.text, "doc_search") != null);

    // Nothing resembles a nonsense spelling: an empty list is how a caller sees
    // "not documented" rather than "misspelled".
    try args.put(gpa, "symbol", .{ .string = "zzznotpresent" });
    const nothing = try tools.docGet(&harness.ctx, .{ .object = args });
    try std.testing.expect(nothing.is_error);
    try std.testing.expectEqual(
        @as(usize, 0),
        nothing.structured.?.object.get("candidates").?.array.items.len,
    );
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
