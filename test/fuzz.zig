//! Randomized agreement with a naive scan.
//!
//! The naive scan tries every pattern at every offset. It is slow and
//! obviously right, which is what the automaton is checked against. The
//! haystacks are generated from a small alphabet so overlaps, shared
//! prefixes, and suffix matches come up constantly.

const std = @import("std");
const testing = std.testing;
const print = std.debug.print;
const ascii = std.ascii;

const ac = @import("aho-corasick");
const Match = ac.Match;

const Set = struct {
    patterns: []const []const u8,
    alphabet: []const u8,
    fold: bool = false,
};

fn folded(comptime fold: bool, byte: u8) u8 {
    return if (fold and ascii.isAlphabetic(byte)) ascii.toLower(byte) else byte;
}

fn collect(
    comptime set: Set,
    haystack: []const u8,
    list: *std.ArrayList(Match),
) !void {
    for (set.patterns, 0..) |pattern, id| {
        if (pattern.len > haystack.len) continue;
        var start: usize = 0;
        while (start + pattern.len <= haystack.len) : (start += 1) {
            var equal = true;
            for (pattern, 0..) |byte, k| {
                if (folded(set.fold, byte) != folded(set.fold, haystack[start + k])) {
                    equal = false;
                    break;
                }
            }
            if (equal) {
                try list.append(testing.allocator, .{
                    .pattern = @intCast(id),
                    .start = start,
                    .end = start + pattern.len,
                });
            }
        }
    }
}

fn byEnd(_: void, a: Match, b: Match) bool {
    if (a.end != b.end) return a.end < b.end;
    if (a.len() != b.len()) return a.len() > b.len();
    return a.pattern < b.pattern;
}

fn byStartPattern(_: void, a: Match, b: Match) bool {
    if (a.start != b.start) return a.start < b.start;
    return a.pattern < b.pattern;
}

fn byStartLength(_: void, a: Match, b: Match) bool {
    if (a.start != b.start) return a.start < b.start;
    if (a.len() != b.len()) return a.len() > b.len();
    return a.pattern < b.pattern;
}

fn same(want: Match, got: Match) !void {
    try testing.expectEqual(want.pattern, got.pattern);
    try testing.expectEqual(want.start, got.start);
    try testing.expectEqual(want.end, got.end);
}

fn check(comptime set: Set, haystack: []const u8, matches: *std.ArrayList(Match)) !void {
    matches.clearRetainingCapacity();
    try collect(set, haystack, matches);

    const Standard = ac.Matcher(set.patterns, .{ .ascii_case_insensitive = set.fold });
    const First = ac.Matcher(set.patterns, .{
        .match_kind = .leftmost_first,
        .ascii_case_insensitive = set.fold,
    });
    const Longest = ac.Matcher(set.patterns, .{
        .match_kind = .leftmost_longest,
        .ascii_case_insensitive = set.fold,
    });

    // Overlapping: every match, in end order.
    std.mem.sort(Match, matches.items, {}, byEnd);
    {
        var iter = Standard.findOverlappingIter(haystack);
        for (matches.items) |want| {
            const got = iter.next() orelse {
                print("missing overlapping {any} in {s}\n", .{ want, haystack });
                return error.Missing;
            };
            try same(want, got);
        }
        try testing.expect(iter.next() == null);
    }

    // Standard: earliest end, skipping anything that overlaps the last match.
    {
        var iter = Standard.findIter(haystack);
        var at: usize = 0;
        for (matches.items) |candidate| {
            if (candidate.start < at) continue;
            const got = iter.next() orelse {
                print("missing standard {any} in {s}\n", .{ candidate, haystack });
                return error.Missing;
            };
            try same(candidate, got);
            at = candidate.end;
        }
        try testing.expect(iter.next() == null);
    }

    // Leftmost first: smallest start, then the earliest pattern.
    std.mem.sort(Match, matches.items, {}, byStartPattern);
    {
        var iter = First.findIter(haystack);
        var at: usize = 0;
        for (matches.items) |candidate| {
            if (candidate.start < at) continue;
            const got = iter.next() orelse {
                print("missing first {any} in {s}\n", .{ candidate, haystack });
                return error.Missing;
            };
            try same(candidate, got);
            at = candidate.end;
        }
        try testing.expect(iter.next() == null);
    }

    // Leftmost longest: smallest start, then the longest.
    std.mem.sort(Match, matches.items, {}, byStartLength);
    {
        var iter = Longest.findIter(haystack);
        var at: usize = 0;
        for (matches.items) |candidate| {
            if (candidate.start < at) continue;
            const got = iter.next() orelse {
                print("missing longest {any} in {s}\n", .{ candidate, haystack });
                return error.Missing;
            };
            try same(candidate, got);
            at = candidate.end;
        }
        try testing.expect(iter.next() == null);
    }
}

fn run(comptime set: Set) !void {
    var matches: std.ArrayList(Match) = .empty;
    defer matches.deinit(testing.allocator);

    var prng: std.Random.DefaultPrng = .init(testing.random_seed);
    const random = prng.random();

    var haystack: [24]u8 = undefined;
    for (0..400) |_| {
        const len = random.uintLessThan(usize, haystack.len + 1);
        for (haystack[0..len]) |*byte| {
            byte.* = set.alphabet[random.uintLessThan(usize, set.alphabet.len)];
        }
        try check(set, haystack[0..len], &matches);
    }
}

test "agrees with a naive scan: overlapping suffixes" {
    try run(.{
        .patterns = &.{ "he", "she", "hers", "his" },
        .alphabet = "hesri",
    });
}

test "agrees with a naive scan: prefixes" {
    try run(.{
        .patterns = &.{ "a", "ab", "abc", "b", "bc" },
        .alphabet = "abc",
    });
}

test "agrees with a naive scan: a longer match through a detour" {
    try run(.{
        .patterns = &.{ "ab", "abcx", "b", "cx" },
        .alphabet = "abcx",
    });
}

test "agrees with a naive scan: append and its suffixes" {
    try run(.{
        .patterns = &.{ "append", "appendage", "app" },
        .alphabet = "appendg ",
    });
}

test "agrees with a naive scan: single bytes" {
    try run(.{
        .patterns = &.{ "a", "aa", "aaa" },
        .alphabet = "a",
    });
}

test "agrees with a naive scan: case folded" {
    try run(.{
        .patterns = &.{ "Ab", "bC", "CAB" },
        .alphabet = "aAbBcC",
        .fold = true,
    });
}

test "agrees with a naive scan: non-ASCII bytes" {
    try run(.{
        .patterns = &.{ "\x00\x01", "\x01", "\xff\xfe", "a" },
        .alphabet = "\x00\x01\xff\xfea",
    });
}
