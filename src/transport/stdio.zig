//! Newline-framed stdio transport (AGENTS.md §6).
//!
//! * one JSON-RPC message per line, no embedded newlines;
//! * stdout carries MCP messages only — diagnostics go to stderr;
//! * every response line is flushed before the next request is read, because the
//!   stdout writer is buffered and a client that blocks on the response would
//!   otherwise wait forever;
//! * stdin EOF ends the loop and the process exits cleanly.

const std = @import("std");

pub const Transport = struct {
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,

    pub fn init(io: std.Io, reader_buffer: []u8, writer_buffer: []u8) Transport {
        return .{
            // Streaming mode: stdin and stdout are pipes, not seekable files.
            // Positional I/O on a pipe has no meaningful file position — the
            // bytes can end up nowhere, and the peer then waits forever for a
            // response that was written "successfully".
            .reader = std.Io.File.stdin().readerStreaming(io, reader_buffer),
            .writer = std.Io.File.stdout().writerStreaming(io, writer_buffer),
        };
    }

    /// Returns the next line without its newline terminator, or `null` at EOF.
    pub fn nextLine(self: *Transport) !?[]const u8 {
        return self.reader.interface.takeDelimiter('\n');
    }

    /// Discards the rest of the current line after an oversized-line failure.
    ///
    /// `takeDelimiter` leaves the stream unmodified when the line does not fit
    /// in the buffer ("as if this function was never called"), so those bytes
    /// are still pending. They are consumed up to and including the next
    /// newline, so the next read starts on a fresh message instead of the
    /// middle of a discarded one (SRV-1).
    pub fn discardRemainderOfLine(self: *Transport) !void {
        _ = try self.reader.interface.discardDelimiterInclusive('\n');
    }

    /// Serializes `value` as one JSON line and flushes it.
    ///
    /// The flush happens before this function returns, so the caller may read
    /// the next request only after the client has the response in hand.
    pub fn writeValue(self: *Transport, value: std.json.Value) !void {
        const writer = &self.writer.interface;
        try std.json.Stringify.value(value, .{}, writer);
        try writer.writeByte('\n');
        try writer.flush();
    }
};

test "a response is serialized as a single line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var out: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&out);
    const value: std.json.Value = .{ .string = "hello" };
    try std.json.Stringify.value(value, .{}, &stream);
    try stream.writeByte('\n');

    const written = stream.buffered();
    try std.testing.expectEqualStrings("\"hello\"\n", written);
}
