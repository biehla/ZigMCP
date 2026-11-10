//! Hot reload of the doc index: validate-then-atomic-swap (AGENTS.md D3, §8).
//!
//! The watcher thread is the only writer of the active index pointer. A new
//! artifact is parsed and validated in full before it becomes active; the
//! previous index stays readable until the last in-flight reader releases it,
//! so a request can never observe a torn index.

const std = @import("std");
const index_module = @import("index.zig");
const sleep_module = @import("../util/sleep.zig");

pub const Index = index_module.Index;

/// Digest of an index artifact's bytes (SHA-256).
pub const Digest = [32]u8;

/// Where the index artifact comes from (AGENTS.md §2, §8).
///
/// The server resolves its index from `ZIGMCP_INDEX` / `--index`, which may be
/// a local path or an HTTP(S) URL pointing at the published artifact.
pub const Source = union(enum) {
    file: []const u8,
    url: []const u8,

    /// Classifies a configured index location.
    pub fn fromString(location: []const u8) Source {
        if (std.mem.startsWith(u8, location, "http://") or std.mem.startsWith(u8, location, "https://")) {
            return .{ .url = location };
        }
        return .{ .file = location };
    }

    /// The configured location as text (for diagnostics and status output).
    pub fn text(self: Source) []const u8 {
        return switch (self) {
            .file => |path| path,
            .url => |url| url,
        };
    }

    /// True when the artifact is fetched over HTTP(S).
    pub fn isUrl(self: Source) bool {
        return self == .url;
    }
};

/// An index loaded from a source, plus the digest of the bytes it came from.
pub const Loaded = struct {
    index: Index,
    /// Only meaningful for a URL source; the file watcher uses mtime + size.
    digest: Digest,
};

/// Loads an index artifact from a local path or an HTTP(S) URL.
pub fn loadSource(io: std.Io, gpa: std.mem.Allocator, source: Source) !Loaded {
    switch (source) {
        .file => |path| {
            return .{ .index = try index_module.loadFile(io, gpa, path), .digest = @splat(0) };
        },
        .url => |url| {
            const bytes = try fetchUrl(io, gpa, url);
            defer gpa.free(bytes);
            return .{ .index = try index_module.load(gpa, bytes), .digest = digestOf(bytes) };
        },
    }
}

/// Downloads the artifact at `url`; the caller owns the returned bytes.
///
/// The stdlib client has no conditional-GET support (no `ETag` plumbing), so a
/// remote index is refreshed by re-fetching and comparing content hashes
/// (AGENTS.md §8). The download is bounded by the same ceiling the local loader
/// enforces, so a hostile artifact cannot exhaust memory.
fn fetchUrl(io: std.Io, gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var bounded = try BoundedWriter.init(gpa, index_module.max_index_bytes);
    defer bounded.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &bounded.writer,
    });
    if (result.status != .ok) return error.UnexpectedStatus;
    // The body may still sit in the writer's buffer: move it into the
    // downloaded bytes before handing them over.
    try bounded.writer.flush();
    return bounded.toOwnedSlice();
}

/// A writer that refuses to grow past a byte limit.
///
/// It follows the `std.Io.Writer` contract: the pending buffer is consumed
/// first, then the supplied data, and the last data slice is the splat
/// pattern.
const BoundedWriter = struct {
    writer: std.Io.Writer,
    inner: std.Io.Writer.Allocating,
    buffer: []u8,
    limit: usize,
    gpa: std.mem.Allocator,

    const vtable: std.Io.Writer.VTable = .{
        .drain = drain,
        .flush = flush,
        .rebase = rebase,
    };

    fn init(gpa: std.mem.Allocator, limit: usize) !BoundedWriter {
        const buffer = try gpa.alloc(u8, 64 * 1024);
        return .{
            .writer = .{ .vtable = &vtable, .buffer = buffer },
            .inner = std.Io.Writer.Allocating.init(gpa),
            .buffer = buffer,
            .limit = limit,
            .gpa = gpa,
        };
    }

    fn deinit(self: *BoundedWriter) void {
        self.gpa.free(self.buffer);
        self.inner.deinit();
    }

    fn toOwnedSlice(self: *BoundedWriter) ![]u8 {
        return self.inner.toOwnedSlice();
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *BoundedWriter = @fieldParentPtr("writer", writer);
        if (data.len == 0) return 0;

        // The pending buffer is consumed first, then the supplied data.
        const pending = writer.buffer[0..writer.end];

        var data_bytes: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            data_bytes = std.math.add(usize, data_bytes, chunk.len) catch return error.WriteFailed;
        }
        const pattern = data[data.len - 1];
        const pattern_bytes = std.math.mul(usize, splat, pattern.len) catch return error.WriteFailed;
        const written = std.math.add(usize, data_bytes, pattern_bytes) catch return error.WriteFailed;
        const needed = std.math.add(usize, pending.len, written) catch return error.WriteFailed;

        const total = std.math.add(usize, self.inner.writer.end, needed) catch return error.WriteFailed;
        if (total > self.limit) return error.WriteFailed;

        self.inner.ensureUnusedCapacity(needed + 1) catch return error.WriteFailed;
        @memcpy(self.inner.writer.buffer[self.inner.writer.end..][0..pending.len], pending);
        self.inner.writer.end += pending.len;
        writer.end = 0;

        for (data[0 .. data.len - 1]) |chunk| {
            @memcpy(self.inner.writer.buffer[self.inner.writer.end..][0..chunk.len], chunk);
            self.inner.writer.end += chunk.len;
        }
        switch (pattern.len) {
            0 => {},
            1 => {
                @memset(self.inner.writer.buffer[self.inner.writer.end..][0..splat], pattern[0]);
                self.inner.writer.end += splat;
            },
            else => for (0..splat) |_| {
                @memcpy(self.inner.writer.buffer[self.inner.writer.end..][0..pattern.len], pattern);
                self.inner.writer.end += pattern.len;
            },
        }
        return written;
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (writer.end == 0) return;
        _ = try drain(writer, &.{""}, 1);
    }

    /// The buffer is fixed size: make room by draining what is pending.
    fn rebase(writer: *std.Io.Writer, preserve: usize, minimum_len: usize) std.Io.Writer.Error!void {
        if (writer.buffer.len - preserve < minimum_len) return error.WriteFailed;
        _ = try drain(writer, &.{""}, 1);
    }
};

fn digestOf(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return digest;
}

/// A tiny spin lock.
///
/// The critical sections here are a pointer swap and a counter update, so a
/// spin lock is cheaper than a futex-backed mutex — and it keeps the store
/// independent of an `Io` instance.
const SpinLock = struct {
    state: std.atomic.Value(bool) = .init(false),

    fn lock(self: *SpinLock) void {
        while (self.state.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
            std.Thread.yield() catch {};
        }
    }

    fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    mutex: SpinLock = .{},
    current: *Index,
    retired: std.ArrayList(*Index) = .empty,
    /// Fallback slot used when the retired list cannot grow (out of memory).
    overflow: ?*Index = null,
    readers: usize = 0,

    pub fn init(gpa: std.mem.Allocator, current: *Index) Store {
        return .{ .gpa = gpa, .current = current };
    }

    pub fn deinit(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.retired.items) |old| {
            old.deinit();
            self.gpa.destroy(old);
        }
        self.retired.deinit(self.gpa);
        if (self.overflow) |old| {
            old.deinit();
            self.gpa.destroy(old);
            self.overflow = null;
        }
        self.current.deinit();
        self.gpa.destroy(self.current);
    }

    /// Takes a read snapshot; the caller must call `deinit` on it.
    pub fn snapshot(self: *Store) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.readers += 1;
        return .{ .store = self, .index = self.current };
    }

    fn release(self: *Store) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.readers > 0);
        self.readers -= 1;
        if (self.readers == 0) self.reclaimLocked();
    }

    fn reclaimLocked(self: *Store) void {
        for (self.retired.items) |old| {
            old.deinit();
            self.gpa.destroy(old);
        }
        self.retired.clearRetainingCapacity();
        if (self.overflow) |old| {
            old.deinit();
            self.gpa.destroy(old);
            self.overflow = null;
        }
    }

    /// Replaces the active index. The old index is retired and reclaimed once
    /// no reader holds it.
    pub fn swap(self: *Store, replacement: *Index) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old = self.current;
        self.current = replacement;
        self.retired.append(self.gpa, old) catch {
            // The old index cannot be freed while a reader may still hold it,
            // so it waits in the overflow slot instead.
            self.overflow = old;
        };
        if (self.readers == 0) self.reclaimLocked();
    }
};

pub const Snapshot = struct {
    store: *Store,
    index: *const Index,

    pub fn deinit(self: Snapshot) void {
        self.store.release();
    }
};

/// The background watcher: polls the artifact's mtime + size and swaps in a
/// freshly validated index when it changes.
pub const Watcher = struct {
    thread: std.Thread,
    context: *Context,
    gpa: std.mem.Allocator,

    /// Stops the watcher and waits for the thread to finish.
    ///
    /// Returns false when the thread did not stop within the grace period —
    /// it can be parked inside a network read, and the stdlib HTTP client
    /// exposes no read timeout. In that case the thread and its context are
    /// deliberately left alone: the process is exiting, and freeing the
    /// context under a live thread would be a use-after-free.
    pub fn stop(self: *Watcher) bool {
        self.context.stop.store(true, .release);

        var waited_ms: u64 = 0;
        while (waited_ms < stop_grace_ms) : (waited_ms += 50) {
            if (self.context.finished.load(.acquire)) {
                self.thread.join();
                self.gpa.destroy(self.context);
                return true;
            }
            sleep_module.sleepMilliseconds(self.context.io, 50);
        }
        return false;
    }

    const stop_grace_ms = 2_000;
};

const Context = struct {
    store: *Store,
    /// The server's Io. The watcher only *uses* it (stat, read, fetch, sleep);
    /// it never initialises another one — a second Io instance would take over
    /// the process's inherited standard handles and close stdin underneath the
    /// server.
    io: std.Io,
    source: Source,
    poll_interval_ms: u64,
    stop: std.atomic.Value(bool) = .init(false),
    /// Set when the watch loop has returned.
    finished: std.atomic.Value(bool) = .init(false),
    last_size: u64 = 0,
    last_mtime: i128 = 0,
    have_stat: bool = false,
    last_digest: Digest = @splat(0),
    have_digest: bool = false,
};

/// Starts the watcher thread for `source`.
///
/// `seed_digest` is the digest of the artifact that is already active; it
/// stops the first poll from reloading what the server just loaded.
pub fn startWatcher(
    gpa: std.mem.Allocator,
    io: std.Io,
    store: *Store,
    source: Source,
    poll_interval_ms: u64,
    seed_digest: ?Digest,
) !Watcher {
    const context = try gpa.create(Context);
    context.* = .{
        .store = store,
        .io = io,
        .source = source,
        .poll_interval_ms = poll_interval_ms,
    };
    switch (source) {
        .file => |path| {
            // Seed the stat so the first poll only reacts to a real change.
            if (statFile(io, path)) |stat| {
                context.last_size = stat.size;
                context.last_mtime = stat.mtime.nanoseconds;
                context.have_stat = true;
            }
        },
        .url => {
            if (seed_digest) |digest| {
                context.last_digest = digest;
                context.have_digest = true;
            }
        },
    }

    const thread = try std.Thread.spawn(.{}, watchLoop, .{context});
    return .{ .thread = thread, .context = context, .gpa = gpa };
}

fn watchLoop(context: *Context) void {
    defer context.finished.store(true, .release);
    while (!context.stop.load(.acquire)) {
        sleepUntilStopped(context);
        if (context.stop.load(.acquire)) break;

        switch (context.source) {
            .file => |path| watchFile(context, path),
            .url => |url| watchUrl(context, url),
        }
    }
}

/// Sleeps in short slices so a stop request is acted on promptly, even when
/// the poll interval is a minute (a remote index).
fn sleepUntilStopped(context: *Context) void {
    var remaining = context.poll_interval_ms;
    while (remaining > 0 and !context.stop.load(.acquire)) {
        const slice = @min(remaining, 100);
        sleep_module.sleepMilliseconds(context.io, slice);
        remaining -= slice;
    }
}

/// A local artifact is polled by mtime + size: cheap, and no network stack.
fn watchFile(context: *Context, path: []const u8) void {
    const io = context.io;
    const stat = statFile(io, path) orelse return;
    if (context.have_stat and stat.size == context.last_size and stat.mtime.nanoseconds == context.last_mtime) {
        return;
    }

    const replacement = context.store.gpa.create(Index) catch |err| {
        logStderr(io, "zigmcp: index reload failed ({s}); keeping the previous index\n", .{@errorName(err)});
        context.last_size = stat.size;
        context.last_mtime = stat.mtime.nanoseconds;
        context.have_stat = true;
        return;
    };
    replacement.* = index_module.loadFile(io, context.store.gpa, path) catch |err| {
        context.store.gpa.destroy(replacement);
        logStderr(io, "zigmcp: index reload failed ({s}); keeping the previous index\n", .{@errorName(err)});
        // Remember the failed artifact so a broken file is not retried in a
        // tight loop; the next change triggers another attempt.
        context.last_size = stat.size;
        context.last_mtime = stat.mtime.nanoseconds;
        context.have_stat = true;
        return;
    };

    context.store.swap(replacement);
    context.last_size = stat.size;
    context.last_mtime = stat.mtime.nanoseconds;
    context.have_stat = true;
}

/// A remote artifact is re-fetched on every poll and compared by content
/// hash (the stdlib client has no conditional-GET support).
fn watchUrl(context: *Context, url: []const u8) void {
    const io = context.io;
    const gpa = context.store.gpa;

    const bytes = fetchUrl(io, gpa, url) catch |err| {
        logStderr(io, "zigmcp: index refresh failed ({s}); keeping the previous index\n", .{@errorName(err)});
        return;
    };
    defer gpa.free(bytes);

    const digest = digestOf(bytes);
    if (context.have_digest and std.mem.eql(u8, &context.last_digest, &digest)) return;

    const replacement = gpa.create(Index) catch |err| {
        logStderr(io, "zigmcp: index reload failed ({s}); keeping the previous index\n", .{@errorName(err)});
        context.last_digest = digest;
        context.have_digest = true;
        return;
    };
    replacement.* = index_module.load(gpa, bytes) catch |err| {
        gpa.destroy(replacement);
        logStderr(io, "zigmcp: index reload failed ({s}); keeping the previous index\n", .{@errorName(err)});
        // Remember the failed artifact so a broken download is not retried in a
        // tight loop; the next publish triggers another attempt.
        context.last_digest = digest;
        context.have_digest = true;
        return;
    };

    context.store.swap(replacement);
    context.last_digest = digest;
    context.have_digest = true;
}

fn statFile(io: std.Io, path: []const u8) ?std.Io.File.Stat {
    return std.Io.Dir.cwd().statFile(io, path, .{}) catch null;
}

fn logStderr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buffer: [1024]u8 = undefined;
    var stderr = std.Io.File.stderr().writer(io, &buffer);
    stderr.interface.print(fmt, args) catch {};
    stderr.interface.flush() catch {};
}

test "a snapshot keeps the old index alive across a swap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const first = try gpa.create(Index);
    first.* = try index_module.load(gpa,
        \\{"project":"p","commit":"a","path":"x.zig","line":1,"kind":"fn","symbol":"old","doc":"d","doc_hash":"h"}
    );
    const second = try gpa.create(Index);
    second.* = try index_module.load(gpa,
        \\{"project":"p","commit":"b","path":"x.zig","line":1,"kind":"fn","symbol":"new","doc":"d","doc_hash":"h"}
    );

    var store = Store.init(gpa, first);
    defer store.deinit();

    const snapshot = store.snapshot();
    store.swap(second);

    try std.testing.expectEqualStrings("old", snapshot.index.columnar.symbolAt(0));
    try std.testing.expectEqualStrings("new", store.current.columnar.symbolAt(0));

    snapshot.deinit();
}

test "an index location is classified as a file or a URL" {
    try std.testing.expectEqual(Source{ .file = "generated/index.jsonl" }, Source.fromString("generated/index.jsonl"));
    try std.testing.expectEqual(Source{ .url = "http://example.test/index.jsonl" }, Source.fromString("http://example.test/index.jsonl"));
    try std.testing.expectEqual(Source{ .url = "https://example.test/index.jsonl" }, Source.fromString("https://example.test/index.jsonl"));
    try std.testing.expectEqualStrings("https://example.test/index.jsonl", Source.fromString("https://example.test/index.jsonl").text());
}

test "a reload concurrent with in-flight reads never tears an index" {
    // The integration layer from AGENTS.md §9: the watcher is the only writer of
    // the active pointer, and a reader that holds a snapshot must see one
    // whole index version, never a mix of two.
    const gpa = std.testing.allocator;

    const first = try gpa.create(Index);
    first.* = try index_module.load(gpa,
        \\{"project":"p","commit":"a","path":"x.zig","line":1,"kind":"fn","symbol":"old","doc":"d","doc_hash":"h"}
    );

    var store = Store.init(gpa, first);
    defer store.deinit();

    const Reader = struct {
        store: *Store,
        torn: std.atomic.Value(bool) = .init(false),
        reads: std.atomic.Value(usize) = .init(0),

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < 5000) : (i += 1) {
                const snapshot = self.store.snapshot();
                defer snapshot.deinit();

                const count = snapshot.index.count();
                const symbol = snapshot.index.columnar.symbolAt(0);
                // Version one has one record ("old"); version two has two
                // ("new", "newer"). A torn read would mix the two.
                const whole = (count == 1 and std.mem.eql(u8, symbol, "old")) or
                    (count == 2 and std.mem.eql(u8, symbol, "new"));
                if (!whole) self.torn.store(true, .release);
                _ = self.reads.fetchAdd(1, .monotonic);
            }
        }
    };

    const Swapper = struct {
        store: *Store,
        gpa: std.mem.Allocator,

        fn run(self: *@This()) void {
            var i: usize = 0;
            while (i < 200) : (i += 1) {
                const replacement = self.gpa.create(Index) catch return;
                replacement.* = index_module.load(self.gpa,
                    \\{"project":"p","commit":"b","path":"x.zig","line":1,"kind":"fn","symbol":"new","doc":"d","doc_hash":"h"}
                    \\{"project":"p","commit":"b","path":"x.zig","line":2,"kind":"fn","symbol":"newer","doc":"d","doc_hash":"h"}
                ) catch {
                    self.gpa.destroy(replacement);
                    return;
                };
                self.store.swap(replacement);
            }
        }
    };

    var reader = Reader{ .store = &store };
    var swapper = Swapper{ .store = &store, .gpa = gpa };

    const reader_thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    const swapper_thread = try std.Thread.spawn(.{}, Swapper.run, .{&swapper});
    reader_thread.join();
    swapper_thread.join();

    try std.testing.expect(!reader.torn.load(.acquire));
    try std.testing.expect(reader.reads.load(.monotonic) > 0);
    try std.testing.expectEqual(@as(usize, 2), store.current.count());
}

test "swapping without readers reclaims the old index immediately" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    const first = try gpa.create(Index);
    first.* = try index_module.load(gpa,
        \\{"project":"p","commit":"a","path":"x.zig","line":1,"kind":"fn","symbol":"old","doc":"d","doc_hash":"h"}
    );
    const second = try gpa.create(Index);
    second.* = try index_module.load(gpa,
        \\{"project":"p","commit":"b","path":"x.zig","line":1,"kind":"fn","symbol":"new","doc":"d","doc_hash":"h"}
    );

    var store = Store.init(gpa, first);
    defer store.deinit();

    store.swap(second);
    try std.testing.expectEqual(@as(usize, 0), store.retired.items.len);
    try std.testing.expectEqualStrings("new", store.current.columnar.symbolAt(0));
}
