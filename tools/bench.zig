//! Verification report tool (AGENTS.md §9).
//!
//! Spawns the built server once over pipes, sends `server/discover` and one
//! `tools/call` per tool per iteration, and reports startup time, per-tool
//! p50/p95/p99 latency, error counts, corpus record counts, index size and
//! upstream commits, and best-effort peak RSS.
//!
//! stdout carries the report only; the child's stdout is a private pipe and
//! the child's stderr is inherited, so diagnostics never corrupt the report.

const std = @import("std");
const builtin = @import("builtin");
const schema = @import("advice_schema");

// ---------------------------------------------------------------- corpus ---

const CorpusCounts = struct {
    patterns: ?usize = null,
    rules: ?usize = null,
    sources: ?usize = null,
    guarantees: ?usize = null,
    limits: ?usize = null,
};

fn countOne(comptime T: type, io: std.Io, gpa: std.mem.Allocator, path: []const u8, comptime field: std.meta.FieldEnum(T)) ?usize {
    const source_bytes = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(64 * 1024 * 1024),
        .of(u8),
        0,
    ) catch return null;
    defer gpa.free(source_bytes);
    var scratch = std.heap.ArenaAllocator.init(gpa);
    defer scratch.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diag: std.zon.parse.Diagnostics = undefined;
    const parsed = std.zon.parse.fromSlice(T, .{
        .gpa = scratch.allocator(),
        .arena = arena.allocator(),
        .source = source_bytes,
        .diagnostics = &diag,
    }) catch return null;
    return @field(parsed, @tagName(field)).len;
}

fn loadCorpusCounts(io: std.Io, gpa: std.mem.Allocator) CorpusCounts {
    var counts: CorpusCounts = .{};
    counts.patterns = countOne(schema.PatternsFile, io, gpa, "data/advice/patterns.zon", .patterns);
    counts.rules = countOne(schema.RulesFile, io, gpa, "data/advice/rules.zon", .rules);
    counts.sources = countOne(schema.SourcesFile, io, gpa, "data/advice/sources.zon", .sources);
    counts.guarantees = countOne(schema.GuaranteesFile, io, gpa, "data/advice/guarantees.zon", .guarantees);
    counts.limits = countOne(schema.LimitsFile, io, gpa, "data/advice/limits.zon", .limits);
    return counts;
}

// ------------------------------------------------------------------- tools --

const ToolDef = struct {
    name: []const u8,
    arguments_json: []const u8,
};

const tool_defs = [_]ToolDef{
    .{ .name = "advice_lookup", .arguments_json = "{\"concept\":\"P03\"}" },
    .{ .name = "doc_get", .arguments_json = "{\"project\":\"zig-std\",\"symbol\":\"BitStack\"}" },
    .{ .name = "doc_import_status", .arguments_json = "{}" },
    .{ .name = "doc_search", .arguments_json = "{\"query\":\"BitStack\"}" },
    .{ .name = "recommend_approach", .arguments_json = "{\"signals\":[\"measured memory bottleneck\"]}" },
};

/// The first symbol in an index artifact.
///
/// The doc tools are exercised against the index that was actually loaded, so
/// a report never mixes the latency of one index with the contents of another.
fn firstIndexSymbol(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ?struct { project: []const u8, symbol: []const u8 } {
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        alloc,
        .limited(64 * 1024 * 1024),
        .of(u8),
        null,
    ) catch return null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, alloc, line, .{}) catch return null;
        const value = parsed.value;
        if (value != .object) continue;
        const project = value.object.get("project") orelse continue;
        const symbol = value.object.get("symbol") orelse continue;
        if (project == .string and symbol == .string) {
            return .{ .project = project.string, .symbol = symbol.string };
        }
    }
    return null;
}

/// Serializes a JSON value into the arena.
fn jsonString(alloc: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

const ToolStats = struct {
    name: []const u8,
    arguments_json: []const u8,
    requests: usize = 0,
    errors: usize = 0,
    latencies_ms: std.ArrayList(f64) = .empty,

    fn quantile(self: *ToolStats, q: f64) f64 {
        if (self.latencies_ms.items.len == 0) return 0;
        const n: f64 = @floatFromInt(self.latencies_ms.items.len);
        var rank: usize = @intFromFloat(@ceil(q * n));
        if (rank == 0) rank = 1;
        if (rank > self.latencies_ms.items.len) rank = self.latencies_ms.items.len;
        return self.latencies_ms.items[rank - 1];
    }
};

// ------------------------------------------------------------------ server -

const Server = struct {
    child: std.process.Child,
    stdin_buffer: [4096]u8,
    stdout_buffer: [256 * 1024]u8,
    stdin_writer: std.Io.File.Writer,
    stdout_reader: std.Io.File.Reader,

    fn start(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) !*Server {
        const server = try gpa.create(Server);
        errdefer gpa.destroy(server);
        server.* = .{
            .child = try std.process.spawn(io, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .pipe,
                .stderr = .inherit,
                .request_resource_usage_statistics = true,
            }),
            .stdin_buffer = undefined,
            .stdout_buffer = undefined,
            .stdin_writer = undefined,
            .stdout_reader = undefined,
        };
        server.stdin_writer = server.child.stdin.?.writerStreaming(io, &server.stdin_buffer);
        server.stdout_reader = server.child.stdout.?.readerStreaming(io, &server.stdout_buffer);
        return server;
    }

    fn send(self: *Server, request: []const u8) !void {
        try self.stdin_writer.interface.writeAll(request);
        try self.stdin_writer.interface.writeByte('\n');
        try self.stdin_writer.interface.flush();
    }

    fn receive(self: *Server, gpa: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        const line = (try self.stdout_reader.interface.takeDelimiter('\n')) orelse
            return error.NoResponse;
        return std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    }

    /// Closes stdin, waits for the server to exit, and returns the peak
    /// resident set size the runtime collected for the child
    /// (`ResourceUsageStatistics.getMaxRss`: Linux `ru_maxrss` from wait4,
    /// Windows `PeakWorkingSetSize`, and friends), or `null` when the
    /// platform does not provide it.
    fn stop(self: *Server, io: std.Io) ?u64 {
        if (self.child.stdin) |stdin| {
            stdin.close(io);
            self.child.stdin = null;
        }
        _ = self.child.wait(io) catch {};
        return self.child.resource_usage_statistics.getMaxRss();
    }

    fn kill(self: *Server, io: std.Io) void {
        self.child.kill(io);
    }
};

// ------------------------------------------------------------------- clock -

fn nowMs(io: std.Io) f64 {
    const ts = std.Io.Clock.now(.awake, io);
    return @as(f64, @floatFromInt(ts.nanoseconds)) / 1_000_000.0;
}

// ------------------------------------------------------------------- index -

/// Distinct `commit` per `project` from a JSONL index artifact.
fn collectIndexProjects(io: std.Io, gpa: std.mem.Allocator, path: []const u8, out: *std.json.ObjectMap) void {
    const bytes = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(512 * 1024 * 1024),
        .of(u8),
        0,
    ) catch return;
    defer gpa.free(bytes);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var entries = std.ArrayList(struct { project: []const u8, commit: []const u8 }).empty;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena.allocator(), trimmed, .{}) catch continue;
        const value = parsed.value;
        if (value != .object) continue;
        const project = value.object.get("project") orelse continue;
        const commit = value.object.get("commit") orelse continue;
        if (project != .string or commit != .string) continue;
        var found = false;
        for (entries.items) |entry| {
            if (std.mem.eql(u8, entry.project, project.string)) {
                found = true;
                break;
            }
        }
        if (!found) entries.append(gpa, .{ .project = project.string, .commit = commit.string }) catch continue;
    }
    for (entries.items) |entry| {
        var item: std.json.ObjectMap = .{};
        const commit_copy = gpa.dupe(u8, entry.commit) catch continue;
        item.put(gpa, "commit", .{ .string = commit_copy }) catch continue;
        const project_copy = gpa.dupe(u8, entry.project) catch continue;
        out.put(gpa, project_copy, .{ .object = item }) catch continue;
    }
    entries.deinit(gpa);
}

// ------------------------------------------------------------------- main --

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    const argv = try std.process.Args.toSlice(init.minimal.args, alloc);

    var server_path: ?[]const u8 = null;
    var index_path: ?[]const u8 = null;
    var iterations: usize = 30;
    var as_json = false;

    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            continue;
        } else if (std.mem.eql(u8, arg, "--server")) {
            i += 1;
            if (i >= argv.len) return usageError(io);
            server_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--index")) {
            i += 1;
            if (i >= argv.len) return usageError(io);
            index_path = argv[i];
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            i += 1;
            if (i >= argv.len) return usageError(io);
            iterations = std.fmt.parseInt(usize, argv[i], 10) catch return usageError(io);
        } else if (std.mem.eql(u8, arg, "--json")) {
            as_json = true;
        } else {
            return usageError(io);
        }
    }

    if (server_path == null) return usageError(io);
    if (iterations == 0) return usageError(io);

    var child_argv = std.ArrayList([]const u8).empty;
    try child_argv.append(alloc, server_path.?);
    if (index_path) |index| {
        try child_argv.append(alloc, "--index");
        try child_argv.append(alloc, index);
    }
    const child_argv_slice = child_argv.items;

    const startup_start = nowMs(io);
    var server = try Server.start(io, gpa, child_argv_slice);
    errdefer server.kill(io);

    const meta = "{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{}}}";
    var next_id: i64 = 1;

    const discover_req = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"server/discover\",\"params\":{s}}}",
        .{ next_id, meta },
    );
    next_id += 1;
    try server.send(discover_req);
    {
        var op = try server.receive(gpa);
        defer op.deinit();
    }
    const startup_ms = nowMs(io) - startup_start;

    // The doc tools are pointed at the index that was actually loaded, so the
    // report's latency and the index it names always agree.
    var defs = tool_defs;
    if (index_path) |path| {
        if (firstIndexSymbol(io, alloc, path)) |symbol| {
            defs[1].arguments_json = try std.fmt.allocPrint(alloc, "{{\"project\":{s},\"symbol\":{s}}}", .{
                try jsonString(alloc, .{ .string = symbol.project }),
                try jsonString(alloc, .{ .string = symbol.symbol }),
            });
            defs[3].arguments_json = try std.fmt.allocPrint(alloc, "{{\"query\":{s}}}", .{
                try jsonString(alloc, .{ .string = symbol.symbol }),
            });
        }
    }

    var stats: [tool_defs.len]ToolStats = undefined;
    for (&stats, defs) |*stat, def| {
        stat.* = .{ .name = def.name, .arguments_json = def.arguments_json };
    }
    defer for (&stats) |*stat| stat.latencies_ms.deinit(gpa);

    var req_arena = std.heap.ArenaAllocator.init(gpa);
    defer req_arena.deinit();

    for (0..iterations) |_| {
        for (&stats) |*stat| {
            const req = try std.fmt.allocPrint(
                alloc,
                "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s},\"_meta\":{{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{{}}}}}}}}",
                .{ next_id, stat.name, stat.arguments_json },
            );
            next_id += 1;

            const start = nowMs(io);
            try server.send(req);
            var parsed = try server.receive(req_arena.allocator());
            defer parsed.deinit();
            const elapsed = nowMs(io) - start;

            stat.requests += 1;
            const value = parsed.value;
            var is_error = false;
            if (value == .object) {
                if (value.object.get("error") != null) {
                    is_error = true;
                } else if (value.object.get("result")) |result| {
                    if (result == .object) {
                        if (result.object.get("isError")) |flag| {
                            if (flag == .bool and flag.bool) is_error = true;
                        }
                    }
                }
            }
            if (is_error) stat.errors += 1;
            try stat.latencies_ms.append(gpa, elapsed);
        }
    }

    for (&stats) |*stat| {
        std.mem.sort(f64, stat.latencies_ms.items, {}, struct {
            fn lessThan(_: void, a: f64, b: f64) bool {
                return a < b;
            }
        }.lessThan);
    }

    const rss = server.stop(io);
    gpa.destroy(server);
    const corpus = loadCorpusCounts(io, gpa);

    var index_bytes: ?u64 = null;
    var index_projects = std.json.ObjectMap{};
    if (index_path) |path| {
        if (std.Io.Dir.cwd().statFile(io, path, .{})) |st| {
            index_bytes = st.size;
        } else |_| {}
        collectIndexProjects(io, alloc, path, &index_projects);
    }

    var out_buf: [4096]u8 = undefined;
    const stdout = std.Io.File.stdout();
    var out = stdout.writer(io, &out_buf);

    const rep = Report{
        .startup_ms = startup_ms,
        .iterations = iterations,
        .stats = &stats,
        .corpus = corpus,
        .index_path = index_path,
        .index_bytes = index_bytes,
        .index_projects = index_projects,
        .rss = rss,
    };

    if (as_json) {
        try printJsonReport(alloc, &out, rep);
    } else {
        try printTextReport(&out, rep);
    }
    try out.interface.flush();
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    const stderr = std.Io.File.stderr();
    var buf: [8192]u8 = undefined;
    var w = stderr.writer(io, &buf);
    w.interface.print(fmt, args) catch {};
    w.interface.flush() catch {};
}

fn usageError(io: std.Io) error{Usage} {
    printStderr(io, "usage: bench --server <path-to-zigmcp> [--index <index.jsonl>] [--iterations <n>] [--json]\n", .{});
    return error.Usage;
}

const Report = struct {
    startup_ms: f64,
    iterations: usize,
    stats: []ToolStats,
    corpus: CorpusCounts,
    index_path: ?[]const u8,
    index_bytes: ?u64,
    index_projects: std.json.ObjectMap,
    rss: ?u64,
};

// ----------------------------------------------------------------- reports -

fn printTextReport(out: *std.Io.File.Writer, rep: Report) !void {
    const w = &out.interface;
    try w.print("zigmcp bench\n", .{});
    try w.print("zig version: {s} (optimize: {s})\n", .{ builtin.zig_version_string, @tagName(builtin.mode) });
    try w.print("iterations: {d}\n", .{rep.iterations});
    try w.print("startup time: {d:.3} ms\n", .{rep.startup_ms});
    if (rep.index_path) |path| {
        try w.print("index: {s}", .{path});
        if (rep.index_bytes) |bytes| try w.print(" ({d} bytes)", .{bytes});
        try w.print("\nupstream commits:", .{});
        var it = rep.index_projects.iterator();
        var first = true;
        while (it.next()) |entry| {
            const proj = entry.key_ptr.*;
            const commit = entry.value_ptr.object.get("commit").?.string;
            if (first) {
                try w.print(" {s}@{s}", .{ proj, commit });
                first = false;
            } else {
                try w.print(", {s}@{s}", .{ proj, commit });
            }
        }
        try w.print("\n", .{});
    } else {
        try w.print("index: none\n", .{});
    }
    try w.print("corpus:", .{});
    try printCorpusCount(w, "patterns", rep.corpus.patterns);
    try printCorpusCount(w, "rules", rep.corpus.rules);
    try printCorpusCount(w, "sources", rep.corpus.sources);
    try printCorpusCount(w, "guarantees", rep.corpus.guarantees);
    try printCorpusCount(w, "limits", rep.corpus.limits);
    try w.print("\n", .{});
    if (rep.rss) |rss| {
        try w.print("peak RSS: {d} bytes\n", .{rss});
    } else {
        try w.print("peak RSS: unavailable\n", .{});
    }
    try w.print("tool requests errors p50_ms p95_ms p99_ms\n", .{});
    for (rep.stats) |*stat| {
        try w.print("{s} {d} {d} {d:.3} {d:.3} {d:.3}\n", .{
            stat.name,
            stat.requests,
            stat.errors,
            stat.quantile(0.50),
            stat.quantile(0.95),
            stat.quantile(0.99),
        });
    }
}

fn printCorpusCount(w: *std.Io.Writer, label: []const u8, value: ?usize) !void {
    if (value) |n| {
        try w.print(" {s}={d}", .{ label, n });
    } else {
        try w.print(" {s}=unknown", .{label});
    }
}

fn printJsonReport(gpa: std.mem.Allocator, out: *std.Io.File.Writer, rep: Report) !void {
    var root: std.json.ObjectMap = .{};
    try root.put(gpa, "zigVersion", .{ .string = builtin.zig_version_string });
    try root.put(gpa, "optimize", .{ .string = @tagName(builtin.mode) });
    try root.put(gpa, "iterations", .{ .integer = @intCast(rep.iterations) });
    try root.put(gpa, "startupMs", .{ .float = rep.startup_ms });

    var index_obj: std.json.ObjectMap = .{};
    if (rep.index_path) |path| {
        try index_obj.put(gpa, "path", .{ .string = path });
    } else {
        try index_obj.put(gpa, "path", .null);
    }
    if (rep.index_bytes) |bytes| {
        try index_obj.put(gpa, "bytes", .{ .integer = @intCast(bytes) });
    } else {
        try index_obj.put(gpa, "bytes", .null);
    }
    var projects_obj: std.json.ObjectMap = .{};
    var it = rep.index_projects.iterator();
    while (it.next()) |entry| {
        try projects_obj.put(gpa, entry.key_ptr.*, entry.value_ptr.*);
    }
    try index_obj.put(gpa, "projects", .{ .object = projects_obj });
    try root.put(gpa, "index", .{ .object = index_obj });

    var corpus_obj: std.json.ObjectMap = .{};
    try putOptUsize(gpa, &corpus_obj, "patterns", rep.corpus.patterns);
    try putOptUsize(gpa, &corpus_obj, "rules", rep.corpus.rules);
    try putOptUsize(gpa, &corpus_obj, "sources", rep.corpus.sources);
    try putOptUsize(gpa, &corpus_obj, "guarantees", rep.corpus.guarantees);
    try putOptUsize(gpa, &corpus_obj, "limits", rep.corpus.limits);
    try root.put(gpa, "corpus", .{ .object = corpus_obj });

    var tools_obj: std.json.ObjectMap = .{};
    for (rep.stats) |*stat| {
        var tool_obj: std.json.ObjectMap = .{};
        try tool_obj.put(gpa, "requests", .{ .integer = @intCast(stat.requests) });
        try tool_obj.put(gpa, "errors", .{ .integer = @intCast(stat.errors) });
        try tool_obj.put(gpa, "p50Ms", .{ .float = stat.quantile(0.50) });
        try tool_obj.put(gpa, "p95Ms", .{ .float = stat.quantile(0.95) });
        try tool_obj.put(gpa, "p99Ms", .{ .float = stat.quantile(0.99) });
        try tools_obj.put(gpa, stat.name, .{ .object = tool_obj });
    }
    try root.put(gpa, "tools", .{ .object = tools_obj });

    if (rep.rss) |rss| {
        try root.put(gpa, "peakRssBytes", .{ .integer = @intCast(rss) });
    } else {
        try root.put(gpa, "peakRssBytes", .null);
    }

    const value: std.json.Value = .{ .object = root };
    const json = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .minified });
    defer gpa.free(json);
    try out.interface.writeAll(json);
    try out.interface.writeByte('\n');
}

fn putOptUsize(gpa: std.mem.Allocator, map: *std.json.ObjectMap, key: []const u8, v: ?usize) !void {
    if (v) |n| {
        try map.put(gpa, key, .{ .integer = @intCast(n) });
    } else {
        try map.put(gpa, key, .null);
    }
}
