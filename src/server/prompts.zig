//! Prompts: `systems_review` and `approach_selection` (AGENTS.md §5).
//!
//! Both prompts keep GUIDANCE separate from FACT and state which checks were
//! not run, and the approach prompt cites the matched rule ids.

const std = @import("std");
const registry = @import("registry.zig");
const render = @import("../advice/render.zig");
const rules_module = @import("../advice/rules.zig");
const tools_module = @import("tools.zig");
const json_array = @import("../util/json_array.zig");

pub const PromptSpec = struct {
    name: []const u8,
    title: []const u8,
    description: []const u8,
    argument: []const u8,
    argument_description: []const u8,
};

pub const prompt_specs = [_]PromptSpec{
    .{
        .name = "approach_selection",
        .title = "Approach selection",
        .description = "Applies the conditional decision rules and cites the matched rule ids.",
        .argument = "situation",
        .argument_description = "The diagnosed situation: signals, constraints and what is being decided.",
    },
    .{
        .name = "systems_review",
        .title = "Systems-programming review",
        .description = "Reviews a design against the matching advice records, their checks and their boundaries.",
        .argument = "design",
        .argument_description = "The design or plan under review.",
    },
};

pub fn findPrompt(name: []const u8) ?*const PromptSpec {
    for (&prompt_specs) |*spec| {
        if (std.mem.eql(u8, spec.name, name)) return spec;
    }
    return null;
}

/// `prompts/list`.
pub fn list(ctx: *registry.Context) !registry.Result {
    const gpa = ctx.pool.allocator();

    var prompts: std.json.Array = json_array.init(gpa);
    for (prompt_specs) |spec| {
        var argument: std.json.ObjectMap = .{};
        try argument.put(gpa, "name", .{ .string = spec.argument });
        try argument.put(gpa, "description", .{ .string = spec.argument_description });
        try argument.put(gpa, "required", .{ .bool = true });
        var arguments: std.json.Array = json_array.init(gpa);
        try json_array.append(&arguments, gpa, .{ .object = argument });

        var object: std.json.ObjectMap = .{};
        try object.put(gpa, "name", .{ .string = spec.name });
        try object.put(gpa, "title", .{ .string = spec.title });
        try object.put(gpa, "description", .{ .string = spec.description });
        try object.put(gpa, "arguments", .{ .array = arguments });
        try json_array.append(&prompts, gpa, .{ .object = object });
    }

    var result: std.json.ObjectMap = .{};
    try result.put(gpa, "prompts", .{ .array = prompts });
    return .{ .value = .{ .object = result }, .cache = registry.advice_cache };
}

/// `prompts/get`.
pub fn get(ctx: *registry.Context, name: []const u8, arguments: ?std.json.Value) !registry.Result {
    const gpa = ctx.pool.allocator();

    const spec = findPrompt(name) orelse return error.UnknownPrompt;
    const argument_text = registry.getString(arguments, spec.argument) orelse return error.InvalidArguments;

    const text = if (std.mem.eql(u8, name, "systems_review"))
        try systemsReviewText(ctx, argument_text)
    else
        try approachSelectionText(ctx, argument_text);

    var content: std.json.ObjectMap = .{};
    try content.put(gpa, "type", .{ .string = "text" });
    try content.put(gpa, "text", .{ .string = text });

    var message: std.json.ObjectMap = .{};
    try message.put(gpa, "role", .{ .string = "user" });
    try message.put(gpa, "content", .{ .object = content });

    var messages: std.json.Array = json_array.init(gpa);
    try json_array.append(&messages, gpa, .{ .object = message });

    var object: std.json.ObjectMap = .{};
    try object.put(gpa, "description", .{ .string = spec.description });
    try object.put(gpa, "messages", .{ .array = messages });
    return .{ .value = .{ .object = object }, .cache = null };
}

fn systemsReviewText(ctx: *registry.Context, design: []const u8) ![]const u8 {
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;

    try text.print(gpa, "Review this design against the systems-programming advice corpus:\n\n{s}\n\n", .{design});

    const matched = try tools_module.matchingPatterns(ctx, gpa, design);
    if (matched.len == 0) {
        try text.appendSlice(gpa, "No advice record matched the design text.\n\n");
    } else {
        try text.appendSlice(gpa, "Matching advice records:\n");
        for (matched) |entry| {
            try text.appendSlice(gpa, try render.patternText(gpa, entry.pattern));
            try text.appendSlice(gpa, "\n");
        }
    }

    try text.appendSlice(gpa,
        \\How to review:
        \\1. Keep GUIDANCE separate from FACT, RESULT and SYNTHESIS. Say which label applies to every claim you rely on.
        \\2. Treat the boundaries of each record as hard limits: report a design that crosses one instead of assuming it is fine.
        \\3. Treat the checks as a work list. State explicitly which checks you did not run and why.
        \\4. Cite the record ids (P01..P12, R01..R12, G01..) and the source ids (S01..S24) you used.
        \\5. The advice is reference material, not a mandate: project requirements and measured behaviour decide.
        \\
    );
    return text.toOwnedSlice(gpa);
}

fn approachSelectionText(ctx: *registry.Context, situation: []const u8) ![]const u8 {
    const gpa = ctx.pool.allocator();
    var text: std.ArrayList(u8) = .empty;

    try text.print(gpa, "Choose an approach for this situation:\n\n{s}\n\n", .{situation});

    const matches = try ctx.matcher.matchSignals(gpa, &.{situation});
    if (matches.len == 0) {
        try text.appendSlice(gpa, "No decision rule matched the situation.\n\n");
    } else {
        try text.appendSlice(gpa, "Matched decision rules (all GUIDANCE):\n");
        for (matches) |match| {
            try text.appendSlice(gpa, try render.ruleText(gpa, match.rule));
            try text.appendSlice(gpa, "\n");
        }
    }

    try text.appendSlice(gpa,
        \\How to answer:
        \\1. Cite the matched rule ids (R01..R12) next to every recommendation they justify.
        \\2. Keep every rule labelled GUIDANCE: these are conditional recommendations, not facts about the system.
        \\3. Name the pattern ids (P01..P12) you would apply and why, and state the boundary of each one.
        \\4. If no rule matches, say so instead of stretching a rule to fit.
        \\
    );
    return text.toOwnedSlice(gpa);
}

test "the prompt table is sorted by name" {
    var index: usize = 1;
    while (index < prompt_specs.len) : (index += 1) {
        try std.testing.expect(
            std.mem.lessThan(u8, prompt_specs[index - 1].name, prompt_specs[index].name),
        );
    }
}
