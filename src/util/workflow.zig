//! Workflow trigger/expression consistency (AGENTS.md §8, CI-1).
//!
//! `actionlint` types `github.event` as an opaque object, so it accepts a
//! `github.event.X` reference even when the workflow's declared triggers can
//! never produce an `X` event — which is exactly how `index.yml`'s publish job
//! came to be permanently skipped: its `if:` tested
//! `github.event.workflow_run.conclusion` while the triggers were `push` and
//! `workflow_dispatch`.
//!
//! This module holds the pure logic; `tools/workflow_check.zig` is the CLI.

const std = @import("std");

pub const Finding = struct {
    line: usize,
    event: []const u8,
};

const event_prefix = "github.event.";

/// The trigger names declared by the workflow's `on:` block.
pub fn collectTriggers(gpa: std.mem.Allocator, text: []const u8, triggers: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_on = false;
    var trigger_indent: ?usize = null;

    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        const indent = line.len - trimmed.len;

        if (!in_on) {
            if (indent != 0 or !std.mem.startsWith(u8, trimmed, "on:")) continue;
            const rest = std.mem.trim(u8, trimmed["on:".len..], " \t");
            if (rest.len == 0) {
                in_on = true;
                continue;
            }
            // `on: push` and `on: [push, pull_request]` are inline forms.
            var items = rest;
            if (items[0] == '[' and items[items.len - 1] == ']') items = items[1 .. items.len - 1];
            var parts = std.mem.splitScalar(u8, items, ',');
            while (parts.next()) |part| {
                const name = std.mem.trim(u8, part, " \t'\"");
                if (name.len > 0) try triggers.append(gpa, name);
            }
            continue;
        }

        if (indent == 0) break; // the `on:` block has ended
        const expected = trigger_indent orelse blk: {
            trigger_indent = indent;
            break :blk indent;
        };
        if (indent != expected) continue;
        if (trimmed.len < 2 or trimmed[trimmed.len - 1] != ':') continue;
        try triggers.append(gpa, std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t"));
    }
}

/// Every `github.event.<name>` reference whose event the triggers cannot
/// produce.
pub fn collectFindings(
    gpa: std.mem.Allocator,
    text: []const u8,
    triggers: []const []const u8,
    findings: *std.ArrayList(Finding),
) !void {
    var line_number: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (line_number += 1) {
        // A full-line comment never runs, so a reference quoted in prose is not
        // a defect.
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, raw, " \t"), "#")) continue;
        var rest = raw;
        while (std.mem.indexOf(u8, rest, event_prefix)) |position| {
            const after = rest[position + event_prefix.len ..];
            var end: usize = 0;
            while (end < after.len and (std.ascii.isAlphanumeric(after[end]) or after[end] == '_')) : (end += 1) {}
            if (end == 0) break;

            const event = after[0..end];
            var declared = false;
            for (triggers) |trigger| {
                if (std.mem.eql(u8, trigger, event)) {
                    declared = true;
                    break;
                }
            }
            if (!declared) try findings.append(gpa, .{ .line = line_number + 1, .event = event });
            rest = after[end..];
        }
    }
}

test "a reference to an event the triggers cannot produce is reported" {
    const text =
        \\on:
        \\  push:
        \\  workflow_dispatch:
        \\jobs:
        \\  index:
        \\    if: github.event_name == 'push' || github.event.workflow_run.conclusion == 'success'
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var triggers: std.ArrayList([]const u8) = .empty;
    try collectTriggers(gpa, text, &triggers);
    try std.testing.expectEqual(@as(usize, 2), triggers.items.len);

    var findings: std.ArrayList(Finding) = .empty;
    try collectFindings(gpa, text, triggers.items, &findings);
    try std.testing.expectEqual(@as(usize, 1), findings.items.len);
    try std.testing.expectEqualStrings("workflow_run", findings.items[0].event);
    try std.testing.expectEqual(@as(usize, 6), findings.items[0].line);
}

test "a declared trigger is not reported" {
    const text =
        \\on:
        \\  workflow_run:
        \\    types: [completed]
        \\  push:
        \\jobs:
        \\  index:
        \\    if: github.event.workflow_run.conclusion == 'success'
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var triggers: std.ArrayList([]const u8) = .empty;
    try collectTriggers(gpa, text, &triggers);
    try std.testing.expectEqual(@as(usize, 2), triggers.items.len);
    try std.testing.expectEqualStrings("workflow_run", triggers.items[0]);
    try std.testing.expectEqualStrings("push", triggers.items[1]);

    var findings: std.ArrayList(Finding) = .empty;
    try collectFindings(gpa, text, triggers.items, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "a reference inside a comment is not a finding" {
    const text =
        \\on:
        \\  push:
        \\jobs:
        \\  a:
        \\    # the previous version tested github.event.workflow_run
        \\    if: github.event_name == 'push'
        \\
    ;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var triggers: std.ArrayList([]const u8) = .empty;
    try collectTriggers(gpa, text, &triggers);

    var findings: std.ArrayList(Finding) = .empty;
    try collectFindings(gpa, text, triggers.items, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "the inline `on:` forms are understood" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var single: std.ArrayList([]const u8) = .empty;
    try collectTriggers(gpa, "on: push\n", &single);
    try std.testing.expectEqual(@as(usize, 1), single.items.len);
    try std.testing.expectEqualStrings("push", single.items[0]);

    var list: std.ArrayList([]const u8) = .empty;
    try collectTriggers(gpa, "on: [push, pull_request]\n", &list);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("pull_request", list.items[1]);
}

// --- CI portability checks -------------------------------------------------
//
// The four checks below exist because the workflow files are code too: the
// actionlint step failed differently on each OS (a PowerShell glob, a missing
// Go toolchain, and shellcheck SC2034), and the canary used a Zig flag master
// no longer accepts. These checks run in the main suite, so `zig build test`
// fails before a portable-workflow regression reaches CI.

pub const JobBlock = struct {
    name: []const u8,
    /// First line of the job body (the line after the job header).
    start: usize,
    /// One past the last line of the job body.
    end: usize,
};

pub const JobFinding = struct {
    line: usize,
    job: []const u8,
};

pub const SimpleFinding = struct {
    line: usize,
};

pub const UnusedReadFinding = struct {
    line: usize,
    variable: []const u8,
};

/// Collect the `jobs:` blocks. Job headers are the two-space-indented keys.
pub fn collectJobs(gpa: std.mem.Allocator, text: []const u8, jobs: *std.ArrayList(JobBlock)) !void {
    var line_no: usize = 0;
    var in_jobs = false;
    var jobs_end: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (line_no += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const indent = line.len - trimmed.len;
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (!in_jobs) {
            if (indent == 0 and std.mem.startsWith(u8, trimmed, "jobs:")) in_jobs = true;
            continue;
        }
        if (indent == 0) {
            jobs_end = line_no;
            in_jobs = false;
            continue;
        }
        if (indent == 2 and trimmed[trimmed.len - 1] == ':' and !std.mem.startsWith(u8, trimmed, "-")) {
            const name = std.mem.trim(u8, trimmed[0 .. trimmed.len - 1], " \t");
            try jobs.append(gpa, .{ .name = name, .start = line_no + 1, .end = 0 });
        }
    }
    if (in_jobs) jobs_end = line_no;
    for (jobs.items, 0..) |*job, index| {
        job.end = if (index + 1 < jobs.items.len) jobs.items[index + 1].start - 1 else jobs_end;
    }
}

/// Collect the steps of one job. A step starts at a `- ` line at the step
/// indentation and ends before the next step (or the end of the job).
pub fn collectSteps(gpa: std.mem.Allocator, text: []const u8, job: JobBlock, steps: *std.ArrayList(JobBlock)) !void {
    var line_no: usize = 0;
    var in_steps = false;
    var step_indent: ?usize = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (line_no += 1) {
        if (line_no < job.start) continue;
        if (line_no >= job.end) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        const indent = line.len - trimmed.len;
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (!in_steps) {
            if (std.mem.eql(u8, trimmed, "steps:")) in_steps = true;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "- ")) {
            const expected = step_indent orelse blk: {
                step_indent = indent;
                break :blk indent;
            };
            if (indent == expected) {
                if (steps.items.len > 0) steps.items[steps.items.len - 1].end = line_no;
                try steps.append(gpa, .{ .name = "", .start = line_no, .end = job.end });
            }
        }
    }
    if (steps.items.len > 0) steps.items[steps.items.len - 1].end = job.end;
}

/// True when a non-comment line in `[start, end)` contains `needle`.
fn rangeHasCode(text: []const u8, start: usize, end: usize, needle: []const u8) bool {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (line_no += 1) {
        if (line_no < start) continue;
        if (line_no >= end) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.indexOf(u8, line, needle) != null) return true;
    }
    return false;
}

/// Jobs whose setup-zig is on `master` must not run `--fetch=all` unless the
/// step tolerates failure; Zig master no longer accepts the flag.
pub fn collectUnsupportedFetchFindings(
    gpa: std.mem.Allocator,
    text: []const u8,
    findings: *std.ArrayList(JobFinding),
) !void {
    var jobs: std.ArrayList(JobBlock) = .empty;
    defer jobs.deinit(gpa);
    try collectJobs(gpa, text, &jobs);

    for (jobs.items) |job| {
        if (!rangeHasCode(text, job.start, job.end, "version: master")) continue;
        var steps: std.ArrayList(JobBlock) = .empty;
        defer steps.deinit(gpa);
        try collectSteps(gpa, text, job, &steps);
        for (steps.items) |step| {
            if (!rangeHasCode(text, step.start, step.end, "--fetch=all")) continue;
            if (rangeHasCode(text, step.start, step.end, "continue-on-error: true")) continue;
            try findings.append(gpa, .{ .line = step.start + 1, .job = job.name });
        }
    }
}

/// A `go run` shell command must not pass a `*.yml`/`*.yaml` glob: PowerShell
/// does not expand it, so actionlint receives a literal filename.
pub fn collectGlobFindings(gpa: std.mem.Allocator, text: []const u8, findings: *std.ArrayList(SimpleFinding)) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (line_no += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "go run") == null) continue;
        if (std.mem.indexOf(u8, line, "*.yml") != null or std.mem.indexOf(u8, line, "*.yaml") != null) {
            try findings.append(gpa, .{ .line = line_no + 1 });
        }
    }
}

/// Every `go run` step needs an earlier `actions/setup-go` in the same job;
/// the macOS runner does not ship Go.
pub fn collectMissingGoSetupFindings(
    gpa: std.mem.Allocator,
    text: []const u8,
    findings: *std.ArrayList(JobFinding),
) !void {
    var jobs: std.ArrayList(JobBlock) = .empty;
    defer jobs.deinit(gpa);
    try collectJobs(gpa, text, &jobs);

    for (jobs.items) |job| {
        var steps: std.ArrayList(JobBlock) = .empty;
        defer steps.deinit(gpa);
        try collectSteps(gpa, text, job, &steps);

        var seen_setup = false;
        for (steps.items) |step| {
            if (rangeHasCode(text, step.start, step.end, "actions/setup-go")) seen_setup = true;
            if (rangeHasCode(text, step.start, step.end, "go run") and !seen_setup) {
                try findings.append(gpa, .{ .line = step.start + 1, .job = job.name });
            }
        }
    }
}

/// Drop a shell comment, respecting simple quoting.
fn stripShellComment(line: []const u8) []const u8 {
    var in_single = false;
    var in_double = false;
    var index: usize = 0;
    while (index < line.len) : (index += 1) {
        const char = line[index];
        if (char == '\'' and !in_double) in_single = !in_single;
        if (char == '"' and !in_single) in_double = !in_double;
        if (char == '#' and !in_single and !in_double) {
            if (index == 0 or std.ascii.isWhitespace(line[index - 1])) return line[0..index];
        }
    }
    return line;
}

/// True when the shell line references `variable` as `$variable` or
/// `${variable}`, not as a prefix of a longer name and not in a comment.
fn lineUsesVariable(line: []const u8, variable: []const u8) bool {
    const stripped = stripShellComment(line);
    var search_from: usize = 0;
    while (std.mem.indexOf(u8, stripped[search_from..], "$")) |relative| {
        const dollar = search_from + relative;
        const rest = stripped[dollar + 1 ..];
        if (rest.len >= 2 and rest[0] == '{') {
            const close = std.mem.indexOfScalar(u8, rest, '}') orelse return false;
            if (std.mem.eql(u8, rest[1..close], variable)) return true;
        } else if (std.mem.startsWith(u8, rest, variable)) {
            const after = rest[variable.len..];
            if (after.len == 0 or !(std.ascii.isAlphanumeric(after[0]) or after[0] == '_')) return true;
        }
        search_from = dollar + 1;
    }
    return false;
}

/// Report loop variables declared by `while ... read -r a b c` but never
/// referenced in the loop body. Single-variable reads are skipped because the
/// variable captures the rest of the line and cannot be proven unused here;
/// nested loops are out of scope.
pub fn collectUnusedReadFindings(
    gpa: std.mem.Allocator,
    text: []const u8,
    findings: *std.ArrayList(UnusedReadFinding),
) !void {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| : (line_no += 1) {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        if (std.mem.indexOf(u8, line, "while") == null) continue;
        const read_pos = std.mem.indexOf(u8, line, "read -r") orelse continue;
        const after_read = line[read_pos + "read -r".len ..];
        if (std.mem.indexOf(u8, after_read, "; do") == null and std.mem.indexOf(u8, after_read, " do") == null) continue;

        var vars_text = after_read;
        if (std.mem.indexOfScalar(u8, vars_text, ';')) |semi| vars_text = vars_text[0..semi];
        vars_text = std.mem.trim(u8, vars_text, " \t");
        if (std.mem.endsWith(u8, vars_text, " do")) vars_text = vars_text[0 .. vars_text.len - 3];

        var variables: std.ArrayList([]const u8) = .empty;
        defer variables.deinit(gpa);
        var parts = std.mem.splitScalar(u8, vars_text, ' ');
        while (parts.next()) |part| {
            const variable = std.mem.trim(u8, part, " \t");
            if (variable.len > 0) try variables.append(gpa, variable);
        }
        if (variables.items.len <= 1) continue;

        var body_end: usize = line_no + 1;
        var body_lines = std.mem.splitScalar(u8, text, '\n');
        var body_line: usize = 0;
        while (body_lines.next()) |body_raw| : (body_line += 1) {
            if (body_line <= line_no) continue;
            const body_trimmed = std.mem.trimStart(u8, body_raw, " \t");
            if (std.mem.startsWith(u8, body_trimmed, "done")) {
                body_end = body_line;
                break;
            }
        }

        for (variables.items) |variable| {
            if (variable[0] == '_') continue;
            var used = false;
            var check_lines = std.mem.splitScalar(u8, text, '\n');
            var check_line: usize = 0;
            while (check_lines.next()) |body_raw| : (check_line += 1) {
                if (check_line <= line_no) continue;
                if (check_line >= body_end) break;
                const body = std.mem.trimEnd(u8, body_raw, "\r");
                if (lineUsesVariable(body, variable)) {
                    used = true;
                    break;
                }
            }
            if (!used) try findings.append(gpa, .{ .line = line_no + 1, .variable = variable });
        }
    }
}

fn readWorkflow(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(1024 * 1024),
        .of(u8),
        null,
    );
}

test "the canary fetch step is master-safe" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text = try readWorkflow(gpa, ".github/workflows/ci.yml");
    var findings: std.ArrayList(JobFinding) = .empty;
    try collectUnsupportedFetchFindings(gpa, text, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "the canary fetch check understands pinned versions and opt-outs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const pinned =
        \\jobs:
        \\  release:
        \\    steps:
        \\      - uses: mlugg/setup-zig@v2
        \\        with:
        \\          version: 0.17.1
        \\      - name: Fetch dependencies
        \\        run: zig build --fetch=all
        \\
    ;
    var pinned_findings: std.ArrayList(JobFinding) = .empty;
    try collectUnsupportedFetchFindings(gpa, pinned, &pinned_findings);
    try std.testing.expectEqual(@as(usize, 0), pinned_findings.items.len);

    const tolerated =
        \\jobs:
        \\  canary:
        \\    steps:
        \\      - uses: mlugg/setup-zig@v2
        \\        with:
        \\          version: master
        \\      - name: Fetch dependencies
        \\        continue-on-error: true
        \\        run: |
        \\          zig build --fetch=all
        \\
    ;
    var tolerated_findings: std.ArrayList(JobFinding) = .empty;
    try collectUnsupportedFetchFindings(gpa, tolerated, &tolerated_findings);
    try std.testing.expectEqual(@as(usize, 0), tolerated_findings.items.len);

    const commented =
        \\jobs:
        \\  canary:
        \\    steps:
        \\      - uses: mlugg/setup-zig@v2
        \\        with:
        \\          version: master
        \\      - name: Fetch dependencies
        \\        run: |
        \\          # zig build --fetch=all
        \\          zig build test
        \\
    ;
    var commented_findings: std.ArrayList(JobFinding) = .empty;
    try collectUnsupportedFetchFindings(gpa, commented, &commented_findings);
    try std.testing.expectEqual(@as(usize, 0), commented_findings.items.len);
}

test "the lint command has no shell glob" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text = try readWorkflow(gpa, ".github/workflows/ci.yml");
    var findings: std.ArrayList(SimpleFinding) = .empty;
    try collectGlobFindings(gpa, text, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "the glob check rejects literal workflow globs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const bad =
        \\jobs:
        \\  lint:
        \\    steps:
        \\      - name: Lint
        \\        run: go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7 .github/workflows/*.yml
        \\
    ;
    var bad_findings: std.ArrayList(SimpleFinding) = .empty;
    try collectGlobFindings(gpa, bad, &bad_findings);
    try std.testing.expectEqual(@as(usize, 1), bad_findings.items.len);

    const good =
        \\jobs:
        \\  lint:
        \\    steps:
        \\      - name: Lint
        \\        run: go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
        \\
    ;
    var good_findings: std.ArrayList(SimpleFinding) = .empty;
    try collectGlobFindings(gpa, good, &good_findings);
    try std.testing.expectEqual(@as(usize, 0), good_findings.items.len);

    const commented =
        \\jobs:
        \\  lint:
        \\    steps:
        \\      - name: Lint
        \\        run: |
        \\          # go run actionlint .github/workflows/*.yml
        \\          go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
        \\
    ;
    var commented_findings: std.ArrayList(SimpleFinding) = .empty;
    try collectGlobFindings(gpa, commented, &commented_findings);
    try std.testing.expectEqual(@as(usize, 0), commented_findings.items.len);
}

test "every go run step is preceded by setup-go" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const text = try readWorkflow(gpa, ".github/workflows/ci.yml");
    var findings: std.ArrayList(JobFinding) = .empty;
    try collectMissingGoSetupFindings(gpa, text, &findings);
    try std.testing.expectEqual(@as(usize, 0), findings.items.len);
}

test "the go setup check is per job and order-sensitive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const setup_first =
        \\jobs:
        \\  lint:
        \\    steps:
        \\      - uses: actions/setup-go@v5
        \\        with:
        \\          go-version: '1.23'
        \\      - name: Lint
        \\        run: go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
        \\
    ;
    var setup_first_findings: std.ArrayList(JobFinding) = .empty;
    try collectMissingGoSetupFindings(gpa, setup_first, &setup_first_findings);
    try std.testing.expectEqual(@as(usize, 0), setup_first_findings.items.len);

    const setup_late =
        \\jobs:
        \\  lint:
        \\    steps:
        \\      - name: Lint
        \\        run: |
        \\          go run github.com/rhysd/actionlint/cmd/actionlint@v1.7.7
        \\      - uses: actions/setup-go@v5
        \\        with:
        \\          go-version: '1.23'
        \\
    ;
    var setup_late_findings: std.ArrayList(JobFinding) = .empty;
    try collectMissingGoSetupFindings(gpa, setup_late, &setup_late_findings);
    try std.testing.expectEqual(@as(usize, 1), setup_late_findings.items.len);
}

test "the shell loops do not declare unused variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    for ([_][]const u8{ ".github/workflows/bump-master.yml", ".github/workflows/index.yml" }) |path| {
        const text = try readWorkflow(gpa, path);
        var findings: std.ArrayList(UnusedReadFinding) = .empty;
        try collectUnusedReadFindings(gpa, text, &findings);
        try std.testing.expectEqual(@as(usize, 0), findings.items.len);
    }
}

test "the unused-read check understands use, underscore and comments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const used =
        \\while IFS=$'\t' read -r name repo branch commit include; do
        \\  echo "$branch"
        \\  echo "$name $repo $commit $include"
        \\done < plan.tsv
        \\
    ;
    var used_findings: std.ArrayList(UnusedReadFinding) = .empty;
    try collectUnusedReadFindings(gpa, used, &used_findings);
    try std.testing.expectEqual(@as(usize, 0), used_findings.items.len);

    const underscored =
        \\while IFS=$'\t' read -r name _branch commit; do
        \\  echo "$name $commit"
        \\done < plan.tsv
        \\
    ;
    var underscored_findings: std.ArrayList(UnusedReadFinding) = .empty;
    try collectUnusedReadFindings(gpa, underscored, &underscored_findings);
    try std.testing.expectEqual(@as(usize, 0), underscored_findings.items.len);

    const single =
        \\while IFS= read -r line; do
        \\  echo "$line"
        \\done < plan.tsv
        \\
    ;
    var single_findings: std.ArrayList(UnusedReadFinding) = .empty;
    try collectUnusedReadFindings(gpa, single, &single_findings);
    try std.testing.expectEqual(@as(usize, 0), single_findings.items.len);

    const comment_only =
        \\while IFS=$'\t' read -r name branch; do
        \\  echo "$name"
        \\  # echo "$branch"
        \\done < plan.tsv
        \\
    ;
    var comment_findings: std.ArrayList(UnusedReadFinding) = .empty;
    try collectUnusedReadFindings(gpa, comment_only, &comment_findings);
    try std.testing.expectEqual(@as(usize, 1), comment_findings.items.len);
    try std.testing.expectEqualStrings("branch", comment_findings.items[0].variable);
}
