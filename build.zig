const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The server binary: a thin host that loads its corpora at runtime.
    const exe = b.addExecutable(.{
        .name = "zigmcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // The doc indexer: upstream tree -> generated/index.jsonl (PLAN §8.1).
    const indexer = b.addExecutable(.{
        .name = "indexer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/indexer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(indexer);

    // The corpus validator fails the build on a dangling source id or a
    // missing evidence label (PLAN §11 M1).
    const advice_check = b.addExecutable(.{
        .name = "advice_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/advice_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // The verification report tool (PLAN §10.3): startup time, per-tool
    // latency quantiles, error counts and peak RSS.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(bench);

    const run_bench = b.addRunArtifact(bench);
    run_bench.step.dependOn(b.getInstallStep());
    run_bench.addArg("--server");
    run_bench.addFileArg(exe.getEmittedBin());
    // An explicit index keeps the report reproducible: without one the server
    // silently picks up whatever `generated/index.jsonl` happens to be, which
    // is gitignored and absent in CI.
    run_bench.addArg("--index");
    run_bench.addArg("tests/golden/index.jsonl");
    const bench_step = b.step("bench", "Produce the verification report (PLAN §10.3)");
    bench_step.dependOn(&run_bench.step);

    const run_step = b.step("run", "Run the MCP server over stdio");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    // `zig build run -- <args>` forwards the arguments to the server.
    run_cmd.addPassthruArgs();

    const run_advice_check = b.addRunArtifact(advice_check);
    run_advice_check.addArgs(&.{"data/advice"});
    const check_step = b.step("check", "Validate the advice corpus");
    check_step.dependOn(&run_advice_check.step);

    // Unit tests: every module's own test blocks, pulled in through src/root.zig.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Protocol tests: drive the built binary as a subprocess, exactly as a
    // client would (PLAN §10.2).
    const server_options = b.addOptions();
    server_options.addOptionPath("server_exe", exe.getEmittedBin());

    const sleep_module = b.createModule(.{
        .root_source_file = b.path("src/util/sleep.zig"),
        .target = target,
        .optimize = optimize,
    });

    const protocol_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/protocol_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "server_options", .module = server_options.createModule() },
                .{ .name = "sleep_util", .module = sleep_module },
            },
        }),
    });
    const run_protocol_tests = b.addRunArtifact(protocol_tests);
    run_protocol_tests.step.dependOn(&exe.step);

    // Golden test: the indexer must reproduce the checked-in index exactly.
    const indexer_options = b.addOptions();
    indexer_options.addOptionPath("indexer_exe", indexer.getEmittedBin());

    const indexer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/indexer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "indexer_options", .module = indexer_options.createModule() }},
        }),
    });
    const run_indexer_tests = b.addRunArtifact(indexer_tests);
    run_indexer_tests.step.dependOn(&indexer.step);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_protocol_tests.step);
    test_step.dependOn(&run_indexer_tests.step);

    // A protocol-only step: the protocol layer drives the built binary as a
    // subprocess, so it is useful on its own when debugging the wire format.
    const protocol_step = b.step("test-protocol", "Run the protocol tests only");
    protocol_step.dependOn(&run_protocol_tests.step);
}
