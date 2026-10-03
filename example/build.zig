const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const mist_dep = b.dependency("mist", .{ .target = target, .optimize = optimize });
    const stbi_dep = b.dependency("stbi", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "Example",
        .root_module = b.createModule(.{
            .root_source_file = b.path("generate.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "mist", .module = mist_dep.module("mist") },
                .{ .name = "stbi", .module = stbi_dep.module("root") },
            },
        }),
    });

    exe.root_module.linkLibrary(stbi_dep.artifact("stbi"));

    exe.step.dependOn(&b.addInstallDirectory(.{
        .source_dir = b.path("assets/"),
        .install_dir = .{ .bin = {} },
        .install_subdir = "assets",
    }).step);

    const run_step = b.addRunArtifact(exe);
    const run = b.step("run", "Run the example");
    run.dependOn(&run_step.step);

    b.installArtifact(exe);
}
