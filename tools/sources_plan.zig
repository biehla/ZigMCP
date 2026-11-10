//! Emit the upstream plan from `data/sources.zon` (AGENTS.md §8, CI-4/CI-5).
//!
//! One line per source, `|`-separated: name, repo, branch, commit, includes,
//! excludes. Includes and excludes are space-separated; the workflows split
//! them with `read -ra`, which does no pathname expansion, so a `**` glob
//! survives. `|` keeps an empty include or exclude list a real, empty field
//! (a tab would collapse under the shell's IFS whitespace rules).
//!
//! Usage: `zig build plan-sources` (the build step passes data/sources.zon).

const std = @import("std");
const sources = @import("sources");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.arena.allocator();
    const args = try std.process.Args.toSlice(init.minimal.args, gpa);
    const path = if (args.len > 1) args[1] else "data/sources.zon";

    const bytes = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(1 << 20),
        .of(u8),
        null,
    );
    const source_z = try gpa.dupeSentinel(u8, bytes, 0);
    const plan = try sources.parse(gpa, source_z);

    var buf: [8192]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var writer = stdout.writer(io, &buf);
    for (plan) |src| {
        // `git+https://host/repo?ref=branch#sha` -> `https://host/repo`.
        var repo = src.url;
        if (std.mem.startsWith(u8, repo, "git+")) repo = repo[4..];
        if (std.mem.indexOfScalar(u8, repo, '?')) |q| repo = repo[0..q];
        if (std.mem.indexOfScalar(u8, repo, '#')) |h| repo = repo[0..h];

        try writer.interface.print("{s}|{s}|{s}|{s}|", .{ src.name, repo, src.branch, src.commit });
        for (src.includes, 0..) |inc, i| {
            if (i != 0) try writer.interface.writeByte(' ');
            try writer.interface.writeAll(inc);
        }
        try writer.interface.writeByte('|');
        for (src.excludes, 0..) |exc, i| {
            if (i != 0) try writer.interface.writeByte(' ');
            try writer.interface.writeAll(exc);
        }
        try writer.interface.writeByte('\n');
    }
    try writer.interface.flush();
}
