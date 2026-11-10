//! CLI test for the corpus validator (AGENTS.md §9, PLAN.md CI-3).
//!
//! `zig build check` is a CI gate, so the validator must fail closed: a corpus
//! it cannot read must exit non-zero rather than pass silently and let an
//! invalid corpus merge green.

const std = @import("std");
const options = @import("advice_options");

const io = std.testing.io;

fn exitCode(argument: []const u8) !u8 {
    var child = try std.process.spawn(io, .{
        .argv = &.{ options.advice_check_exe, argument },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io);
    return switch (term) {
        .exited => |code| code,
        else => error.UnexpectedExit,
    };
}

test "the checked-in corpus validates" {
    try std.testing.expectEqual(@as(u8, 0), try exitCode("data/advice"));
}

test "a corpus directory that cannot be read fails the check" {
    try std.testing.expect(try exitCode("tests/no-such-advice-dir") != 0);
}
