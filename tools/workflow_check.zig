//! Workflow trigger/expression consistency check (AGENTS.md §8, CI-1).
//!
//! Usage: `workflow_check [<dir>]` — default `.github/workflows`.
//!
//! Exits 1 when an `if:` reads a `github.event.<name>` the workflow's declared
//! triggers can never produce. The logic lives in `src/util/workflow.zig` so
//! its tests run in the main suite.

const std = @import("std");
const workflow = @import("workflow");

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try std.process.Args.toSlice(init.minimal.args, gpa);
    const dir_path = if (args.len > 1) args[1] else ".github/workflows";

    var dir = try std.Io.Dir.cwd().openDir(init.io, dir_path, .{ .iterate = true });
    defer dir.close(init.io);

    var failures: usize = 0;
    var walker = try dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(init.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".yml") and !std.mem.endsWith(u8, entry.basename, ".yaml")) continue;

        const bytes = try entry.dir.readFileAlloc(init.io, entry.basename, gpa, .limited(1024 * 1024));

        var triggers: std.ArrayList([]const u8) = .empty;
        try workflow.collectTriggers(gpa, bytes, &triggers);
        if (triggers.items.len == 0) {
            std.debug.print("{s}: no `on:` triggers found\n", .{entry.path});
            failures += 1;
            continue;
        }

        var findings: std.ArrayList(workflow.Finding) = .empty;
        try workflow.collectFindings(gpa, bytes, triggers.items, &findings);
        for (findings.items) |finding| {
            std.debug.print(
                "{s}:{d}: github.event.{s} is not produced by the declared triggers\n",
                .{ entry.path, finding.line, finding.event },
            );
            failures += 1;
        }
    }

    if (failures > 0) std.process.exit(1);
}
