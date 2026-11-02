const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const library = b.dependency("aho_corasick", .{ .target = target, .optimize = optimize });
    const cli = b.dependency("cli", .{ .target = target });
    const vaxis = b.dependency("vaxis", .{ .target = target, .optimize = optimize });

    const exe = b.addExecutable(.{
        .name = "acviz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("acviz.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aho-corasick", .module = library.module("aho-corasick") },
                .{ .name = "cli", .module = cli.module("cli") },
                .{ .name = "vaxis", .module = vaxis.module("vaxis") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (comptime @hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run.addPassthruArgs();
    } else if (b.args) |args| {
        run.addArgs(args);
    }
    const step = b.step("viz", "Inspect an Aho-Corasick automaton");
    step.dependOn(&run.step);
}
