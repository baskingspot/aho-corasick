//! The benchmarks: the comptime matcher and the runtime automaton over a
//! generated dictionary and two generated haystacks.
//!
//! The dictionary is 1,000 random words of 4 to 10 lowercase letters. The
//! dense haystack is 64 KiB of those words separated by spaces. The miss
//! haystack is 64 KiB of bytes outside the pattern alphabet, so every byte
//! takes the no-class path. The numbers are local, not claims.

const std = @import("std");
const testingx = @import("testingx");
const ac = @import("aho-corasick");

const words = 1000;
const max_word_len = 10;
const text_len = 64 * 1024;

const Bank = struct {
    bytes: [words][max_word_len]u8,
    lengths: [words]u8,
};

const bank = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: Bank = undefined;
    var state: u64 = 0x9e3779b97f4a7c15;
    for (0..words) |i| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const len: u8 = @intCast(4 + (state >> 33) % 7);
        out.lengths[i] = len;
        for (0..len) |j| {
            state = state *% 6364136223846793005 +% 1442695040888963407;
            out.bytes[i][j] = 'a' + @as(u8, @intCast((state >> 33) % 26));
        }
    }
    break :blk out;
};

const patterns = blk: {
    var out: [words][]const u8 = undefined;
    for (0..words) |i| out[i] = bank.bytes[i][0..bank.lengths[i]];
    break :blk out;
};

const dense_text = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [text_len]u8 = undefined;
    var at: usize = 0;
    var i: usize = 0;
    while (at + max_word_len + 1 <= text_len) : (i += 1) {
        const word = patterns[i % words];
        @memcpy(out[at..][0..word.len], word);
        at += word.len;
        out[at] = ' ';
        at += 1;
    }
    @memset(out[at..], ' ');
    break :blk out;
};

const miss_text = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [text_len]u8 = undefined;
    const alphabet = "0123456789 .,:;-_/";
    var state: u64 = 0x243f6a8885a308d3;
    for (&out) |*byte| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        byte.* = alphabet[(state >> 33) % alphabet.len];
    }
    break :blk out;
};

const small_patterns = [_][]const u8{ "she", "he", "hers" };
const small_text = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: ["ushers ".len * 4096]u8 = undefined;
    for (0..4096) |i| @memcpy(out[i * 7 ..][0..7], "ushers ");
    break :blk out;
};

const Matcher = ac.Matcher(&patterns, .{});
const FirstMatcher = ac.Matcher(&patterns, .{ .match_kind = .leftmost_first });
const Overlap = ac.Matcher(&small_patterns, .{});

fn findBytes(
    comptime find: fn ([]const u8) ?ac.Match,
    text: []const u8,
    b: *testingx.B,
) !void {
    const hidden = b.blackBox(text);
    b.setBytes(@intCast(text.len));
    b.reportCounters();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        sink += @intFromBool(find(hidden) != null);
    }
}

fn isMatchBytes(
    comptime check: fn ([]const u8) bool,
    text: []const u8,
    b: *testingx.B,
) !void {
    const hidden = b.blackBox(text);
    b.setBytes(@intCast(text.len));
    b.reportCounters();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        sink += @intFromBool(check(hidden));
    }
}

pub fn benchmarkByteSum(b: *testingx.B) !void {
    const hidden = b.blackBox(&miss_text);
    b.setBytes(miss_text.len);
    b.reportCounters();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        for (hidden) |byte| sink +%= byte;
    }
}

pub fn benchmarkNextStateMiss(b: *testingx.B) !void {
    const hidden = b.blackBox(&miss_text);
    b.setBytes(miss_text.len);
    b.reportCounters();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var state: Matcher.State = 0;
        for (hidden) |byte| state = Matcher.nextState(state, byte);
        sink +%= @as(usize, state);
    }
}

pub fn benchmarkComptimeFindMiss(b: *testingx.B) !void {
    try findBytes(Matcher.find, &miss_text, b);
}

pub fn benchmarkComptimeIsMatchMiss(b: *testingx.B) !void {
    try isMatchBytes(Matcher.isMatch, &miss_text, b);
}

pub fn benchmarkComptimeFindIterDense(b: *testingx.B) !void {
    const hidden = b.blackBox(&dense_text);
    b.setBytes(dense_text.len);
    b.reportCounters();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var iter = Matcher.findIter(hidden);
        while (iter.next()) |m| sink +%= m.end - m.start;
    }
}

pub fn benchmarkLeftmostFindIterDense(b: *testingx.B) !void {
    const hidden = b.blackBox(&dense_text);
    b.setBytes(dense_text.len);
    b.reportCounters();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var iter = FirstMatcher.findIter(hidden);
        while (iter.next()) |m| sink +%= m.end - m.start;
    }
}

pub fn benchmarkRuntimeFindIterDense(b: *testingx.B) !void {
    var automaton = try ac.Automaton.init(std.heap.page_allocator, &patterns, .{});
    defer automaton.deinit();

    const hidden = b.blackBox(&dense_text);
    b.setBytes(dense_text.len);
    b.reportCounters();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var iter = automaton.findIter(hidden);
        while (iter.next()) |m| sink +%= m.end - m.start;
    }
}

pub fn benchmarkRuntimeFindMiss(b: *testingx.B) !void {
    var automaton = try ac.Automaton.init(std.heap.page_allocator, &patterns, .{});
    defer automaton.deinit();

    const hidden = b.blackBox(&miss_text);
    b.setBytes(miss_text.len);
    b.reportCounters();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        sink += @intFromBool(automaton.find(hidden) != null);
    }
}

pub fn benchmarkOverlappingSmall(b: *testingx.B) !void {
    const hidden = b.blackBox(&small_text);
    b.setBytes(small_text.len);
    b.reportCounters();
    var sink: usize = 0;
    defer b.keepAlive(sink);
    while (try b.loop()) {
        var iter = Overlap.findOverlappingIter(hidden);
        while (iter.next()) |m| sink +%= m.end - m.start;
    }
}
