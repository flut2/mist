const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});
    _ = b.addModule("mist", .{
        .root_source_file = b.path("src/Generator.zig"),
        .imports = &.{
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
}
