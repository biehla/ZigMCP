//! `data/sources.zon` plan parsing (AGENTS.md §8, CI-4/CI-5).
//!
//! Both CI workflows used to carry their own regex copy of this parser, and
//! each one took only the first `include` and ignored `exclude`. This module
//! walks the real ZON AST (`std.zig.Ast` in `.zon` mode), so a comment, a line
//! break or extra whitespace cannot change the plan, and every include and
//! exclude is returned. `tools/sources_plan.zig` is the thin CLI; the
//! workflows call `zig build plan-sources`.

const std = @import("std");
const Ast = std.zig.Ast;

/// One upstream source. `url` is the pinned `git+…?ref=…#<sha>` string as it
/// appears in `data/sources.zon`; the CLI strips it down to a cloneable repo.
pub const Source = struct {
    name: []const u8,
    url: []const u8,
    branch: []const u8,
    commit: []const u8,
    includes: []const []const u8,
    excludes: []const []const u8,
};

/// Parses `data/sources.zon`. Every returned slice points into `source_z`, so
/// the caller must keep it alive; the `Source` array and the include/exclude
/// arrays are `gpa`-owned.
pub fn parse(gpa: std.mem.Allocator, source_z: [:0]const u8) ![]const Source {
    var tree = try Ast.parse(gpa, source_z, .{ .mode = .zon });
    defer tree.deinit(gpa);
    if (tree.errors.len != 0) return error.MalformedSources;

    const roots = tree.rootDecls();
    if (roots.len != 1) return error.MalformedSources;
    var buf: [2]Ast.Node.Index = undefined;
    const root = tree.fullStructInit(&buf, roots[0]) orelse return error.MalformedSources;

    var out: std.ArrayList(Source) = .empty;
    for (root.ast.fields) |field| {
        var src: Source = .{
            .name = try fieldName(&tree, field),
            .url = "",
            .branch = "master",
            .commit = "",
            .includes = &.{},
            .excludes = &.{},
        };
        var sbuf: [2]Ast.Node.Index = undefined;
        const init = tree.fullStructInit(&sbuf, field) orelse return error.MalformedSources;
        for (init.ast.fields) |member| {
            const key = try fieldName(&tree, member);
            if (std.mem.eql(u8, key, "url")) {
                src.url = try stringValue(&tree, member);
            } else if (std.mem.eql(u8, key, "branch")) {
                src.branch = try stringValue(&tree, member);
            } else if (std.mem.eql(u8, key, "commit")) {
                src.commit = try stringValue(&tree, member);
            } else if (std.mem.eql(u8, key, "scope")) {
                var scbuf: [2]Ast.Node.Index = undefined;
                const scope = tree.fullStructInit(&scbuf, member) orelse return error.MalformedSources;
                for (scope.ast.fields) |scoped| {
                    const skey = try fieldName(&tree, scoped);
                    if (std.mem.eql(u8, skey, "include")) {
                        src.includes = try stringList(gpa, &tree, scoped);
                    } else if (std.mem.eql(u8, skey, "exclude")) {
                        src.excludes = try stringList(gpa, &tree, scoped);
                    }
                }
            }
        }
        if (src.url.len == 0 or src.commit.len == 0) return error.MalformedSources;
        try out.append(gpa, src);
    }
    if (out.items.len == 0) return error.MalformedSources;
    return out.toOwnedSlice(gpa);
}

/// The field's value node starts after `.name =`, so the identifier is the
/// token two back from the value's first token (`.name = <expr>`).
fn fieldName(tree: *const Ast, field: Ast.Node.Index) ![]const u8 {
    const first = tree.firstToken(field);
    if (first < 2) return error.MalformedSources;
    const tags = tree.tokens.items(.tag);
    if (tags[first - 1] != .equal or tags[first - 2] != .identifier) return error.MalformedSources;
    return tree.tokenSlice(@intCast(first - 2));
}

fn stringValue(tree: *const Ast, node: Ast.Node.Index) ![]const u8 {
    if (tree.nodeTag(node) != .string_literal) return error.MalformedSources;
    const raw = tree.tokenSlice(@intCast(tree.nodeMainToken(node)));
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"') return error.MalformedSources;
    return raw[1 .. raw.len - 1];
}

fn stringList(gpa: std.mem.Allocator, tree: *const Ast, node: Ast.Node.Index) ![]const []const u8 {
    var buf: [2]Ast.Node.Index = undefined;
    const init = tree.fullArrayInit(&buf, node) orelse return error.MalformedSources;
    const out = try gpa.alloc([]const u8, init.ast.elements.len);
    for (init.ast.elements, 0..) |el, i| out[i] = try stringValue(tree, el);
    return out;
}

test "every include and exclude is parsed regardless of formatting" {
    // CI-4/CI-5: the regex copies both took only the first include and ignored
    // exclude, and a reformatted file broke them. A comment, a one-line
    // struct and a missing scope must not change the plan.
    const zon =
        \\.{
        \\    // a comment must not change the plan
        \\    .alpha = .{
        \\        .url = "git+https://example.com/a.git?ref=main#abc123",
        \\        .hash = "h",
        \\        .branch = "main",
        \\        .commit = "abc123",
        \\        .scope = .{ .include = .{ "src/**", "lib/**" }, .exclude = .{ "src/**/testdata/**" } },
        \\    },
        \\
        \\    .beta = .{
        \\        .url = "git+https://example.com/b.git#def456", .hash = "h", .commit = "def456",
        \\    },
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = try parse(arena.allocator(), zon);

    try std.testing.expectEqual(@as(usize, 2), sources.len);
    try std.testing.expectEqualStrings("alpha", sources[0].name);
    try std.testing.expectEqualStrings("git+https://example.com/a.git?ref=main#abc123", sources[0].url);
    try std.testing.expectEqualStrings("main", sources[0].branch);
    try std.testing.expectEqualStrings("abc123", sources[0].commit);
    try std.testing.expectEqual(@as(usize, 2), sources[0].includes.len);
    try std.testing.expectEqualStrings("src/**", sources[0].includes[0]);
    try std.testing.expectEqualStrings("lib/**", sources[0].includes[1]);
    try std.testing.expectEqual(@as(usize, 1), sources[0].excludes.len);
    try std.testing.expectEqualStrings("src/**/testdata/**", sources[0].excludes[0]);

    // A source without a scope keeps the documented defaults.
    try std.testing.expectEqualStrings("beta", sources[1].name);
    try std.testing.expectEqualStrings("master", sources[1].branch);
    try std.testing.expectEqual(@as(usize, 0), sources[1].includes.len);
    try std.testing.expectEqual(@as(usize, 0), sources[1].excludes.len);
}
