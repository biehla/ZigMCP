const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The ZON schema: one module so the server, the validator and the report
    // cannot drift (GUIDE-3).
    const advice_schema = b.createModule(.{
        .root_source_file = b.path("src/advice/schema.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The server binary: a thin host that loads its corpora at runtime.
    const exe = b.addExecutable(.{
        .name = "zigmcp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "advice_schema", .module = advice_schema }},
        }),
    });
    // DOC-4: a Windows release binary with a manifest (asInvoker, supported OS)
    // and a version resource; other targets need no resource section.
    if (target.result.os.tag == .windows) {
        exe.root_module.addWin32ResourceFile(.{
            .file = b.path("res/zigmcp.rc"),
            .include_paths = &.{b.path("res")},
        });
    }
    b.installArtifact(exe);

    // The doc indexer: upstream tree -> generated/index.jsonl (AGENTS.md §8).
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
    // missing evidence label (AGENTS.md §12).
    const advice_check = b.addExecutable(.{
        .name = "advice_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/advice_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "advice_schema", .module = advice_schema }},
        }),
    });

    // The verification report tool (AGENTS.md §9): startup time, per-tool
    // latency quantiles, error counts and peak RSS.
    const bench = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "advice_schema", .module = advice_schema }},
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
    const bench_step = b.step("bench", "Produce the verification report (AGENTS.md §9)");
    bench_step.dependOn(&run_bench.step);

    const run_step = b.step("run", "Run the MCP server over stdio");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_step.dependOn(&run_cmd.step);
    // `zig build run -- <args>` forwards the arguments to the server.
    run_cmd.addPassthruArgs();

    // `data/sources.zon` plan parsing (CI-4/CI-5): one parser shared by both
    // workflows, so their regex copies cannot drift.
    const sources_module = b.createModule(.{
        .root_source_file = b.path("src/util/sources.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sources_plan = b.addExecutable(.{
        .name = "sources_plan",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sources_plan.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sources", .module = sources_module }},
        }),
    });
    const run_sources_plan = b.addRunArtifact(sources_plan);
    run_sources_plan.addArg("data/sources.zon");
    const plan_step = b.step("plan-sources", "Print the upstream plan from data/sources.zon");
    plan_step.dependOn(&run_sources_plan.step);

    // Workflow trigger/expression consistency (CI-1): actionlint accepts a
    // `github.event.X` its triggers cannot produce, this does not.
    const workflow_module = b.createModule(.{
        .root_source_file = b.path("src/util/workflow.zig"),
        .target = target,
        .optimize = optimize,
    });
    const workflow_check = b.addExecutable(.{
        .name = "workflow_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/workflow_check.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "workflow", .module = workflow_module }},
        }),
    });
    const run_workflow_check = b.addRunArtifact(workflow_check);
    run_workflow_check.addArg(".github/workflows");
    const workflow_step = b.step("workflows", "Check workflow trigger/expression consistency");
    workflow_step.dependOn(&run_workflow_check.step);

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
            .imports = &.{.{ .name = "advice_schema", .module = advice_schema }},
        }),
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Protocol tests: drive the built binary as a subprocess, exactly as a
    // client would (AGENTS.md §9).
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

    // The corpus validator is a CI gate, so its failure behaviour is tested too
    // (CI-3).
    const advice_options = b.addOptions();
    advice_options.addOptionPath("advice_check_exe", advice_check.getEmittedBin());

    const advice_check_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/advice_check_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "advice_options", .module = advice_options.createModule() }},
        }),
    });
    const run_advice_check_tests = b.addRunArtifact(advice_check_tests);
    run_advice_check_tests.step.dependOn(&advice_check.step);

    // The indexer's line table (IDX-9): a binary search that replaced the
    // per-record rescan from byte 0.
    const line_table_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/line_table.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_line_table_tests = b.addRunArtifact(line_table_tests);

    // The indexer's own unit layer (IDX-6: modulePath), compiled from the same
    // root the executable uses.
    const indexer_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/indexer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_indexer_unit_tests = b.addRunArtifact(indexer_unit_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_protocol_tests.step);
    test_step.dependOn(&run_indexer_tests.step);
    test_step.dependOn(&run_advice_check_tests.step);
    test_step.dependOn(&run_line_table_tests.step);
    test_step.dependOn(&run_indexer_unit_tests.step);

    // A protocol-only step: the protocol layer drives the built binary as a
    // subprocess, so it is useful on its own when debugging the wire format.
    const protocol_step = b.step("test-protocol", "Run the protocol tests only");
    protocol_step.dependOn(&run_protocol_tests.step);

    // The cross-cutting handler tests (real corpus + a doc index). They also run
    // as part of `zig build test`, since src/root.zig imports the file.
    const regression_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/regressions_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "advice_schema", .module = advice_schema }},
        }),
    });
    const run_regression_tests = b.addRunArtifact(regression_tests);
    const regression_step = b.step("test-regressions", "Run the cross-cutting handler tests");
    regression_step.dependOn(&run_regression_tests.step);
}
