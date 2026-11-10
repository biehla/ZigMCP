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
