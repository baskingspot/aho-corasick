//! Scan a haystack file for every pattern in a pattern file.

const std = @import("std");
const ac = @import("aho-corasick");

const Io = std.Io;
const mem = std.mem;
const print = std.debug.print;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        print("usage: scan <patterns-file> <haystack-file>\n", .{});
        std.process.exit(2);
    }

    const patterns_text = Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        arena,
        .limited(16 * 1024 * 1024),
    ) catch |err| {
        print("scan: {s}: {s}\n", .{ args[1], @errorName(err) });
        std.process.exit(1);
    };
    const haystack = Io.Dir.cwd().readFileAlloc(
        init.io,
        args[2],
        arena,
        .limited(64 * 1024 * 1024),
    ) catch |err| {
        print("scan: {s}: {s}\n", .{ args[2], @errorName(err) });
        std.process.exit(1);
    };

    var patterns: std.ArrayList([]const u8) = .empty;
    var lines = mem.splitScalar(u8, patterns_text, '\n');
    while (lines.next()) |line| {
        const trimmed = mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try patterns.append(arena, trimmed);
    }

    var automaton = ac.Automaton.init(init.gpa, patterns.items, .{}) catch |err| {
        print("scan: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer automaton.deinit();

    var buffer: [8192]u8 = undefined;
    var file_writer: Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &file_writer.interface;
    defer writer.flush() catch {};

    var iter = automaton.findIter(haystack);
    while (iter.next()) |m| {
        try writer.print("{d}..{d}  {s}\n", .{
            m.start,
            m.end,
            automaton.pattern(m.pattern),
        });
    }
}
