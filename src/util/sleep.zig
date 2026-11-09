//! A plain OS sleep for background threads.
//!
//! `std.Io.sleep` ties the timer to the `Io` instance that services it. A
//! thread that does not own that `Io` — the index watcher, a test watchdog —
//! can therefore wait far longer than it asked for. On Windows the delay is
//! taken from the native timer directly, so no `Io` is involved; elsewhere
//! the `Io` sleep is used, which is the platform's normal path.

const std = @import("std");
const builtin = @import("builtin");

/// Sleeps for roughly `ms` milliseconds. Never blocks longer than the request.
pub fn sleepMilliseconds(io: std.Io, ms: u64) void {
    switch (builtin.os.tag) {
        .windows => sleepWindows(ms),
        else => std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .awake) catch {},
    }
}

fn sleepWindows(ms: u64) void {
    const ntdll = std.os.windows.ntdll;
    const windows = std.os.windows;

    // LARGE_INTEGER counts 100-nanosecond intervals; a negative value is a
    // relative delay. Cap the request so an overflow cannot turn it positive
    // (which would mean "no delay"). The constants are typed explicitly: Zig
    // 0.17 gives an unsuffixed literal the smallest type that fits it, and
    // `std.time.ns_per_ms` cannot even be represented by its own `u10` type.
    const max_ms: u64 = 1_000_000;
    const ticks_per_ms: u64 = 10_000;
    const capped_ms: u64 = @min(ms, max_ms);
    const units: i64 = -@as(i64, @intCast(capped_ms * ticks_per_ms));
    const delay: windows.LARGE_INTEGER = units;
    _ = ntdll.NtDelayExecution(.FALSE, &delay);
}

test "the sleep helper waits and returns" {
    const start = std.Io.Clock.now(.awake, std.testing.io);
    sleepMilliseconds(std.testing.io, 20);
    const elapsed_ms = @divTrunc(std.Io.Clock.now(.awake, std.testing.io).nanoseconds -
        start.nanoseconds, 1_000_000);
    try std.testing.expect(elapsed_ms >= 10);
}
