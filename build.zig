const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("use_xml", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_step = b.step("test", "Run tests");

    const mod_tests = b.addTest(.{ .root_module = mod });
    test_step.dependOn(&b.addRunArtifact(mod_tests).step);

    // Example: M7 message (tested together with the library).
    const m7 = b.createModule(.{
        .root_source_file = b.path("examples/m7/m7.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "use_xml", .module = mod }},
    });
    const m7_tests = b.addTest(.{ .root_module = m7 });
    test_step.dependOn(&b.addRunArtifact(m7_tests).step);

    // Benchmark, always optimised for speed.
    const fast_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    const fast_m7 = b.createModule(.{
        .root_source_file = b.path("examples/m7/m7.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "use_xml", .module = fast_mod }},
    });
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "use_xml", .module = fast_mod },
                .{ .name = "m7", .module = fast_m7 },
            },
        }),
    });
    const bench_step = b.step("bench", "Run the benchmark (ReleaseFast)");
    bench_step.dependOn(&b.addRunArtifact(bench_exe).step);
}
