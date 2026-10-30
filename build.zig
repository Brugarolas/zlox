const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption(bool, "PRINT_CODE_AFTER_COMPILE",
        b.option(bool, "print-code", "Disassemble bytecode after compilation") orelse false);
    options.addOption(bool, "TRACING",
        b.option(bool, "trace", "Trace VM registers and bytecode execution") orelse false);
    options.addOption(bool, "SAFE_OBJ_CAST",
        b.option(bool, "safe-object-casts", "Check heap-object downcasts at runtime") orelse false);
    options.addOption(bool, "DEBUG_STRESS_GC",
        b.option(bool, "stress-gc", "Schedule a moving major GC after every object allocation") orelse false);
    options.addOption(bool, "DEBUG_LOG_GC",
        b.option(bool, "log-gc", "Log garbage-collector activity") orelse false);
    options.addOption(usize, "GC_HEAP_GROW_FACTOR",
        b.option(usize, "gc-growth", "Heap growth factor after a collection") orelse 2);
    options.addOption(usize, "GC_NURSERY_BYTES",
        b.option(usize, "gc-nursery", "Young-generation collection threshold in bytes") orelse 512 * 1024);
    options.addOption(u8, "GC_PROMOTION_AGE",
        b.option(u8, "gc-promotion-age", "Minor collections survived before promotion") orelse 2);
    options.addOption(usize, "GC_OLD_ARENA_BYTES",
        b.option(usize, "gc-old-arena", "Minimum compact old-space arena size") orelse 256 * 1024);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "zlox",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run the Lox interpreter");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = test_module });
    const test_run = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&test_run.step);
}
