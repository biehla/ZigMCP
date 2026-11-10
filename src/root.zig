//! Test aggregator: pulls every module's test blocks into one test binary.

const std = @import("std");

test {
    _ = @import("advice/corpus.zig");
    _ = @import("advice/render.zig");
    _ = @import("advice/rules.zig");
    _ = @import("docs/columnar.zig");
    _ = @import("docs/index.zig");
    _ = @import("docs/reload.zig");
    _ = @import("docs/search.zig");
    _ = @import("protocol/errors.zig");
    _ = @import("protocol/json_rpc.zig");
    _ = @import("protocol/meta.zig");
    _ = @import("protocol/response.zig");
    _ = @import("server/log.zig");
    _ = @import("server/prompts.zig");
    _ = @import("server/registry.zig");
    _ = @import("server/resources.zig");
    _ = @import("server/tools.zig");
    _ = @import("transport/stdio.zig");
    _ = @import("util/arena_pool.zig");
    _ = @import("util/sleep.zig");
    _ = @import("util/text.zig");
    // The workflow trigger/expression check (CI-1); its CLI is
    // `tools/workflow_check.zig`.
    _ = @import("util/workflow.zig");
    // Cross-cutting handler tests: they need the real corpus and a loaded doc
    // index, so they keep their own harness. Part of the main suite.
    _ = @import("regressions_test.zig");
}

test "DOC-2: the readme embeds client-config.json verbatim" {
    // One canonical snippet, read by the readme and by the release workflow.
    // A hand-edited copy in either place is drift the user would see.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const readme = try std.Io.Dir.cwd().readFileAllocOptions(io, "readme.md", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(readme);
    const canonical = try std.Io.Dir.cwd().readFileAllocOptions(io, "client-config.json", gpa, .unlimited, .of(u8), 0);
    defer gpa.free(canonical);

    const fence = "```json\n";
    const fence_start = std.mem.indexOf(u8, readme, fence) orelse return error.MissingSnippet;
    const body_start = fence_start + fence.len;
    const body_end = std.mem.indexOfPos(u8, readme, body_start, "\n```") orelse return error.MissingSnippet;
    const embedded = readme[body_start..body_end];

    try std.testing.expectEqualStrings(std.mem.trimEnd(u8, canonical, "\n"), embedded);
}

test "GUIDE-8: the limitation lists live only in PLAN.md" {
    // Three copies of the same list drift. `PLAN.md` is canonical; the other two
    // sections must be pointers, not lists, or a stale gap survives a fix.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    try expectSectionIsPointer(io, gpa, "readme.md", "## Known limitations", "## ");
    try expectSectionIsPointer(io, gpa, "AGENTS.md", "### Known gaps", "### ");
}

fn expectSectionIsPointer(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    heading: []const u8,
    next_heading: []const u8,
) !void {
    const text = try std.Io.Dir.cwd().readFileAllocOptions(io, path, gpa, .unlimited, .of(u8), 0);
    defer gpa.free(text);

    const start = std.mem.indexOf(u8, text, heading) orelse return error.MissingHeading;
    const body_start = start + heading.len;
    const body_end = std.mem.indexOfPos(u8, text, body_start, next_heading) orelse text.len;
    const body = text[body_start..body_end];

    try std.testing.expect(std.mem.indexOf(u8, body, "PLAN.md") != null);
    if (std.mem.indexOf(u8, body, "\n- ") != null) {
        std.debug.print("{s}: the section under '{s}' restates the backlog; link to PLAN.md instead\n", .{ path, heading });
        return error.DuplicatedBacklog;
    }
}

test "GUIDE-1: every src and tools file opens with a //! header" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var missing: usize = 0;
    for ([_][]const u8{ "src", "tools" }) |root| {
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".zig")) continue;
            const path = try std.fs.path.join(gpa, &.{ root, entry.path });
            defer gpa.free(path);
            const source = try std.Io.Dir.cwd().readFileAllocOptions(
                io,
                path,
                gpa,
                .unlimited,
                .of(u8),
                0,
            );
            defer gpa.free(source);
            if (!std.mem.startsWith(u8, source, "//!")) {
                // Every offender, not just the first: one run names them all.
                std.debug.print("missing //! header: {s}\n", .{path});
                missing += 1;
            }
        }
    }
    if (missing != 0) return error.MissingModuleHeader;
}
