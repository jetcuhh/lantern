const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{
        .default_target = .{ .cpu_model = .baseline },
    });
    const optimize = b.standardOptimizeOption(.{});

    // Release binaries are stripped: by default the linker keeps full debug
    // info even under ReleaseFast, which inflates the artifacts.
    const strip = b.option(bool, "strip", "Strip debug information from the executable") orelse false;

    const run_step = b.step("run", "Run lantern");
    const test_step = b.step("test", "Run unit tests");
    const integration_step = b.step("test-integration", "Run PTY integration tests");
    const test_all_step = b.step("test-all", "Run all tests");

    // Main executable module.
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
    });

    // nanosvg rasterizes SVG documents sent as kitty graphics (src/svg.zig).
    exe_mod.addIncludePath(b.path("vendor"));
    exe_mod.addCSourceFile(.{ .file = b.path("vendor/nanosvg.c"), .flags = &.{"-fno-sanitize=undefined"} });

    // libghostty-vt provides the terminal emulation core.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const exe = b.addExecutable(.{
        .name = "lantern",
        .root_module = exe_mod,
        // ghostty-vt's generated uucode tables crash the x86_64 self-hosted
        // backend; ghostty uses LLVM for the same reason.
        .use_llvm = true,
    });
    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);

    // Unit tests (in-process, no TTY required).
    const unit_tests = b.addTest(.{ .root_module = exe_mod, .use_llvm = true });
    const run_unit_tests = b.addRunArtifact(unit_tests);
    test_step.dependOn(&run_unit_tests.step);

    // Integration tests: drive the real binary through a real PTY.
    const test_opts = b.addOptions();
    test_opts.addOptionPath("exe_path", exe.getEmittedBin());

    const integration_mod = b.createModule(.{
        .root_source_file = b.path("test/integration.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    integration_mod.addOptions("build_options", test_opts);
    // The integration test also drives the process and PTY directly, so it
    // needs the POSIX shim from src/. Its module root is `test/`, which
    // cannot reach `../src`, so expose the shim as a module import.
    integration_mod.addImport("lantern-sys", b.createModule(.{
        .root_source_file = b.path("src/sys.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    // The tests render captured client output through a terminal
    // emulator to assert what a user would actually see.
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        integration_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }

    const integration_tests = b.addTest(.{ .root_module = integration_mod, .use_llvm = true });
    const run_integration_tests = b.addRunArtifact(integration_tests);
    integration_step.dependOn(&run_integration_tests.step);

    test_all_step.dependOn(test_step);
    test_all_step.dependOn(integration_step);

    // Benchmark: the viewport render hot path (no TTY required).
    const bench_mod = b.createModule(.{
        .root_source_file = b.path("bench/render.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("lantern-sys", b.createModule(.{
        .root_source_file = b.path("src/sys.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }));
    if (b.lazyDependency("ghostty", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        bench_mod.addImport("ghostty-vt", dep.module("ghostty-vt"));
    }
    const bench_exe = b.addExecutable(.{
        .name = "lantern-bench",
        .root_module = bench_mod,
        .use_llvm = true,
    });
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run the render microbenchmark");
    bench_step.dependOn(&bench_run.step);
}
