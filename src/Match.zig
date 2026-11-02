//! One match: which pattern, and where.

const Match = @This();

/// The index into the pattern list the automaton was built from.
pattern: u32,
/// The byte offset in the haystack where the match starts.
start: usize,
/// The byte offset one past the match end.
end: usize,

pub fn len(self: Match) usize {
    return self.end - self.start;
}

pub fn isEmpty(self: Match) bool {
    return self.end == self.start;
}

test "len and isEmpty" {
    const testing = @import("std").testing;

    const m: Match = .{ .pattern = 3, .start = 10, .end = 15 };
    try testing.expectEqual(5, m.len());
    try testing.expect(!m.isEmpty());

    const empty: Match = .{ .pattern = 0, .start = 7, .end = 7 };
    try testing.expect(empty.isEmpty());
}
