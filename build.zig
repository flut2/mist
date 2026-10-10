const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    // Dependency-free SDF core; usable on any target, including freestanding
    // ones (wasm), as it neither links nor imports freetype/libc.
    const core_module = b.addModule("mist-core", .{
        .root_source_file = b.path("src/mist-core/core.zig"),
    });

    _ = b.addModule("mist", .{
        .root_source_file = b.path("src/mist/Generator.zig"),
        .imports = &.{
            .{ .name = "mist-core", .module = core_module },
            .{
                .name = "mach-freetype",
                .module = b.dependency("mach_freetype", .{
                    .optimize = optimize,
                    .target = target,
                }).module("mach-freetype"),
            },
            .{
                .name = "turbopack",
                .module = b.dependency("turbopack", .{
                    .optimize = optimize,
                    .target = target,
                }).module("turbopack"),
            },
        },
    });

    const test_step = b.step("test", "Run module tests");

    const core_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mist-core/core.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(core_tests).step);
}
