const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The only exported module. Everything below is developer-only: returning
    // early for a consumer keeps testingx out of its fetch graph.
    const mod = b.addModule("aho-corasick", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    if (b.pkg_hash.len != 0) return;

    // testingx provides the test runner. It is lazy because only the root
    // build uses it; a consumer never fetches it. On the first configure pass
    // it is not fetched yet, `lazyDependency` returns null, and the build
    // runner fetches it and reruns this script.
    const testingx_dep = b.lazyDependency("testingx", .{ .target = target });
    const test_runner: ?std.Build.Step.Compile.TestRunner = if (testingx_dep) |dep|
        .{ .path = dep.path("src/runner.zig"), .mode = .simple }
    else
        null;

    const test_step = b.step("test", "Run the unit tests and the fuzz comparison");

    const mod_tests = b.addTest(.{ .root_module = mod, .test_runner = test_runner });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    passthruArgs(b, run_mod_tests);
    test_step.dependOn(&run_mod_tests.step);

    // The fuzz test imports the public module, so it sees the same API a
    // consumer does.
    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("test/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "aho-corasick", .module = mod }},
    });
    const fuzz_tests = b.addTest(.{ .root_module = fuzz_mod, .test_runner = test_runner });
    const run_fuzz = b.addRunArtifact(fuzz_tests);
    passthruArgs(b, run_fuzz);
    test_step.dependOn(&run_fuzz.step);
}

/// `b.args` (removed in Zig 0.17) and `Run.addPassthruArgs` are the same
/// feature on either side of the split. Probe the build API, not the version.
fn passthruArgs(b: *std.Build, run: *std.Build.Step.Run) void {
    if (comptime @hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        run.addPassthruArgs();
    } else if (b.args) |args| {
        run.addArgs(args);
    }
}
