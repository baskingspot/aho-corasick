//! The benchmark suite root. The rows live in `bench_impl.zig`; `addMod`
//! discovers the `pub fn benchmark*` functions there.

const testingx = @import("testingx");
const impl = @import("bench_impl.zig");

pub fn benchmarkMain(b: *testingx.B) !void {
    try b.addMod(impl);
}
