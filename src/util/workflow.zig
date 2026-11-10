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
