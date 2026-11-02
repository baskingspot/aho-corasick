//! Aho-Corasick multi-pattern search in Zig, with the automaton built at comptime.
//!
//! Aho-Corasick finds every occurrence of a set of patterns in one pass over
//! the haystack, whatever the number of patterns. `Matcher` puts the patterns
//! in the type and builds the automaton at comptime, so searching allocates
//! nothing. `Automaton` builds the same tables at runtime from a pattern list
//! and an allocator.
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

pub const Automaton = @import("Automaton.zig");
pub const Dfa = @import("Automaton.zig").Dfa;
pub const Match = @import("Match.zig");
pub const Matcher = @import("matcher.zig").Matcher;
pub const MatchKind = @import("Options.zig").MatchKind;
pub const Options = @import("Options.zig").Options;

test {
    testing.refAllDecls(@This());
}
