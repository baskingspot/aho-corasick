//! The guide's examples, compiled and run with the module's own test suite.
//! A guide page cannot show code that does not build.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const ac = @import("aho-corasick");

test "find a span" {
    const Keywords = ac.Matcher(&.{ "apple", "maple" }, .{});

    const m = Keywords.find("a maple leaf").?;
    try testing.expectEqual(@as(u32, 1), m.pattern);
    try testing.expectEqual(@as(usize, 2), m.start);
    try testing.expectEqual(@as(usize, 7), m.end);
    try testing.expectEqualStrings("maple", "a maple leaf"[m.start..m.end]);
}

test "keep a value by pattern id" {
    const levels = [_][]const u8{ "debug", "info", "warn", "error" };
    const Levels = ac.Matcher(&.{ "[DEBUG]", "[INFO]", "[WARN]", "[ERROR]" }, .{});

    const line = "[WARN] connection timeout";
    const m = Levels.find(line).?;
    try testing.expectEqualStrings("warn", levels[m.pattern]);
}

test "iterate non-overlapping matches" {
    const Keywords = ac.Matcher(&.{ "apple", "maple" }, .{});

    var it = Keywords.findIter("maple, apple, maple");
    const expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 1, .start = 0, .end = 5 },
        .{ .pattern = 0, .start = 7, .end = 12 },
        .{ .pattern = 1, .start = 14, .end = 19 },
    };
    for (expected) |want| {
        const m = it.next().?;
        try testing.expectEqual(want.pattern, m.pattern);
        try testing.expectEqual(want.start, m.start);
        try testing.expectEqual(want.end, m.end);
    }
    try testing.expect(it.next() == null);
}

test "match kinds" {
    const patterns = &.{ "append", "appendage", "app" };
    const haystack = "append the app to the appendage";

    const Standard = ac.Matcher(patterns, .{});
    const First = ac.Matcher(patterns, .{ .match_kind = .leftmost_first });
    const Longest = ac.Matcher(patterns, .{ .match_kind = .leftmost_longest });

    const standard_expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 2, .start = 0, .end = 3 },
        .{ .pattern = 2, .start = 11, .end = 14 },
        .{ .pattern = 2, .start = 22, .end = 25 },
    };
    const first_expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 0, .start = 0, .end = 6 },
        .{ .pattern = 2, .start = 11, .end = 14 },
        .{ .pattern = 0, .start = 22, .end = 28 },
    };
    const longest_expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 0, .start = 0, .end = 6 },
        .{ .pattern = 2, .start = 11, .end = 14 },
        .{ .pattern = 1, .start = 22, .end = 31 },
    };

    var standard = Standard.findIter(haystack);
    for (standard_expected) |want| {
        const m = standard.next().?;
        try testing.expectEqual(want.pattern, m.pattern);
        try testing.expectEqual(want.start, m.start);
        try testing.expectEqual(want.end, m.end);
    }

    var first = First.findIter(haystack);
    for (first_expected) |want| {
        const m = first.next().?;
        try testing.expectEqual(want.pattern, m.pattern);
        try testing.expectEqual(want.start, m.start);
        try testing.expectEqual(want.end, m.end);
    }

    var longest = Longest.findIter(haystack);
    for (longest_expected) |want| {
        const m = longest.next().?;
        try testing.expectEqual(want.pattern, m.pattern);
        try testing.expectEqual(want.start, m.start);
        try testing.expectEqual(want.end, m.end);
    }
}

test "overlapping matches" {
    const Words = ac.Matcher(&.{ "she", "he", "hers" }, .{});

    var it = Words.findOverlappingIter("ushers");
    const expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 0, .start = 1, .end = 4 },
        .{ .pattern = 1, .start = 2, .end = 4 },
        .{ .pattern = 2, .start = 2, .end = 6 },
    };
    for (expected) |want| {
        const m = it.next().?;
        try testing.expectEqual(want.pattern, m.pattern);
        try testing.expectEqual(want.start, m.start);
        try testing.expectEqual(want.end, m.end);
    }
    try testing.expect(it.next() == null);
}

test "which matches" {
    const Words = ac.Matcher(&.{ "she", "he", "hers" }, .{});

    const set = Words.whichMatches("ushers");
    try testing.expect(set.isSet(0));
    try testing.expect(set.isSet(1));
    try testing.expect(set.isSet(2));
    try testing.expectEqual(@as(usize, 3), set.count());
}

test "replace all" {
    const Replace = ac.Matcher(&.{ "fox", "brown", "quick" }, .{});

    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try Replace.replaceAll(&writer, "The quick brown fox.", &.{ "sloth", "grey", "slow" });
    try testing.expectEqualStrings("The slow grey sloth.", writer.buffered());
}

test "runtime automaton" {
    const gpa = testing.allocator;
    var automaton = try ac.Automaton.init(gpa, &.{ "she", "he", "hers" }, .{});
    defer automaton.deinit();

    const m = automaton.find("ushers").?;
    try testing.expectEqual(@as(u32, 0), m.pattern);
    try testing.expectEqual(@as(usize, 1), m.start);
    try testing.expectEqual(@as(usize, 4), m.end);
    try testing.expectEqualStrings("she", automaton.pattern(m.pattern));

    var set = try automaton.whichMatches(gpa, "ushers");
    defer set.deinit(gpa);
    try testing.expect(set.isSet(0));
    try testing.expect(set.isSet(1));
}

test "case folding" {
    const Warning = ac.Matcher(&.{"warning"}, .{ .ascii_case_insensitive = true });
    try testing.expect(Warning.isMatch("WaRnInG"));
}

test "inspect a state" {
    const gpa = testing.allocator;
    var automaton = try ac.Automaton.init(gpa, &.{ "she", "he", "hers" }, .{});
    defer automaton.deinit();

    var state = ac.Automaton.start_state;
    for ("she") |byte| state = automaton.nextState(state, byte);

    try testing.expectEqual(@as(u32, 0), automaton.stateOutput(state).?);
    try testing.expectEqual(@as(usize, 3), automaton.stateDepth(state));

    var matches = automaton.matchesAt(state, 3);
    try testing.expectEqual(@as(u32, 0), matches.next().?.pattern);
    try testing.expectEqual(@as(u32, 1), matches.next().?.pattern);
    try testing.expect(matches.next() == null);
}

test "runtime errors" {
    try testing.expectError(error.NoPatterns, ac.Automaton.init(testing.allocator, &.{}, .{}));
    try testing.expectError(error.EmptyPattern, ac.Automaton.init(testing.allocator, &.{""}, .{}));
    try testing.expectError(
        error.DuplicatePattern,
        ac.Automaton.init(testing.allocator, &.{ "she", "she" }, .{}),
    );
}
