//! Multi-pattern search in Zig, with the automaton built at comptime.
//!
//! Aho-Corasick finds every occurrence of a set of patterns in one pass over
//! the haystack, whatever the number of patterns. Here the automaton is a
//! comptime value: the patterns are part of the type, the trie and its links
//! are built by the compiler, and searching allocates nothing.
//!
//! ```zig
//! const ac = @import("aho-corasick");
//!
//! const Keywords = ac.Matcher(&.{ "apple", "maple" }, .{});
//!
//! const m = Keywords.find("a maple leaf").?;
//! // m.pattern == 1, m.start == 2, m.end == 7
//!
//! var it = Keywords.findOverlappingIter("apples and maples");
//! while (it.next()) |hit| {
//!     // every occurrence, including nested ones
//! }
//! ```

const std = @import("std");
const testing = std.testing;

pub const Matcher = @import("Matcher.zig").Matcher;
pub const MatchKind = @import("Matcher.zig").MatchKind;
pub const Options = @import("Matcher.zig").Options;
pub const Match = @import("Match.zig");

test {
    testing.refAllDecls(@This());
}
