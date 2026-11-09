//! Test aggregator: pulls every module's test blocks into one test binary.

test {
    _ = @import("advice/corpus.zig");
    _ = @import("advice/render.zig");
    _ = @import("advice/rules.zig");
    _ = @import("docs/columnar.zig");
    _ = @import("docs/index.zig");
    _ = @import("docs/reload.zig");
    _ = @import("docs/search.zig");
    _ = @import("protocol/errors.zig");
    _ = @import("protocol/json_rpc.zig");
    _ = @import("protocol/meta.zig");
    _ = @import("server/prompts.zig");
    _ = @import("server/registry.zig");
    _ = @import("server/resources.zig");
    _ = @import("server/tools.zig");
    _ = @import("transport/stdio.zig");
    _ = @import("util/arena_pool.zig");
    _ = @import("util/sleep.zig");
    _ = @import("util/text.zig");
}
