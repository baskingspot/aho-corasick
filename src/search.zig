//! The search algorithms. One implementation, instantiated for the comptime
//! tables and for the runtime tables.

const Match = @import("Match.zig");

pub fn Searcher(comptime T: type) type {
    return struct {
        const Self = @This();
        const State = T.StateType;

        pub const Transition = struct {
            byte: u8,
            state: State,
        };

        /// The trie transitions out of one state, in byte order.
        pub const Transitions = struct {
            tables: *const T,
            state: State,
            class: usize,

            pub fn next(self: *Transitions) ?Transition {
                const mask = self.tables.masks[self.state];
                while (self.class < self.tables.alphabetLen()) {
                    const class = self.class;
                    self.class += 1;
                    if (mask.isSet(class)) {
                        const rank = T.rank(mask, class);
                        return .{
                            .byte = self.tables.alphabet[class],
                            .state = self.tables.children[
                                @as(usize, self.tables.offsets[self.state]) + rank
                            ],
                        };
                    }
                }
                return null;
            }
        };

        pub fn transitions(t: *const T, state: State) Transitions {
            return .{ .tables = t, .state = state, .class = 0 };
        }

        /// The matches that end at one state, longest first, then the suffix
        /// patterns on the failure chain.
        pub const Matches = struct {
            tables: *const T,
            node: State,
            end: usize,

            pub fn next(self: *Matches) ?Match {
                const node = self.node;
                if (node == self.tables.none) return null;
                const id = self.tables.own_id[node];
                self.node = self.tables.links[node];
                return .{
                    .pattern = id,
                    .start = self.end - self.tables.patternLen(id),
                    .end = self.end,
                };
            }
        };

        pub fn matchesAt(t: *const T, state: State, end: usize) Matches {
            return .{
                .tables = t,
                .node = if (t.own_id[state] != t.no_id) state else t.links[state],
                .end = end,
            };
        }

        /// The first match that ends at `state`, with `end` as its end offset.
        pub fn firstMatch(t: *const T, state: State, end: usize) ?Match {
            var matches = matchesAt(t, state, end);
            return matches.next();
        }

        /// Non-overlapping matches according to the tables' match kind.
        pub const Iterator = struct {
            tables: *const T,
            haystack: []const u8,
            at: usize,
            end: usize,
            state: State,
            node: State,

            pub fn next(self: *Iterator) ?Match {
                return switch (self.tables.match_kind) {
                    .standard => self.nextStandard(),
                    .leftmost_first, .leftmost_longest => self.nextLeftmost(),
                };
            }

            fn nextStandard(self: *Iterator) ?Match {
                while (true) {
                    if (self.node != self.tables.none) {
                        const node = self.node;
                        self.node = self.tables.links[node];
                        const id = self.tables.own_id[node];
                        const m: Match = .{
                            .pattern = id,
                            .start = self.end - self.tables.patternLen(id),
                            .end = self.end,
                        };
                        // The state is reset so the next match starts at or
                        // after the end of this one.
                        self.state = 0;
                        self.node = self.tables.none;
                        return m;
                    }
                    if (self.at == self.haystack.len) return null;
                    self.state = self.tables.nextState(self.state, self.haystack[self.at]);
                    self.at += 1;
                    self.end = self.at;
                    self.node = if (self.tables.own_id[self.state] != self.tables.no_id)
                        self.state
                    else
                        self.tables.links[self.state];
                }
            }

            fn nextLeftmost(self: *Iterator) ?Match {
                if (self.at == self.haystack.len) return null;

                var state: State = 0;
                var best: ?Match = null;
                var pos = self.at;
                while (pos < self.haystack.len) {
                    state = self.tables.nextState(state, self.haystack[pos]);
                    pos += 1;

                    var node = if (self.tables.own_id[state] != self.tables.no_id)
                        state
                    else
                        self.tables.links[state];
                    while (node != self.tables.none) {
                        const id = self.tables.own_id[node];
                        const m: Match = .{
                            .pattern = id,
                            .start = pos - self.tables.patternLen(id),
                            .end = pos,
                        };
                        if (best == null or self.isBetter(m, best.?)) best = m;
                        node = self.tables.links[node];
                    }

                    // A match that starts at or before the best candidate and
                    // has not ended yet would be a suffix of the bytes read so
                    // far. Once the current state is shorter than that suffix,
                    // no such match can exist and the candidate is final.
                    if (best) |candidate| {
                        if (self.tables.stateDepth(state) < pos - candidate.start) break;
                    }
                }

                if (best) |candidate| {
                    self.at = candidate.end;
                    return candidate;
                }
                self.at = self.haystack.len;
                return null;
            }

            fn isBetter(self: *Iterator, a: Match, b: Match) bool {
                if (a.start != b.start) return a.start < b.start;
                return switch (self.tables.match_kind) {
                    .leftmost_first => a.pattern < b.pattern,
                    .leftmost_longest => if (a.len() != b.len())
                        a.len() > b.len()
                    else
                        a.pattern < b.pattern,
                    .standard => unreachable,
                };
            }
        };

        pub fn findIter(t: *const T, haystack: []const u8) Iterator {
            return .{
                .tables = t,
                .haystack = haystack,
                .at = 0,
                .end = 0,
                .state = 0,
                .node = t.none,
            };
        }

        pub fn find(t: *const T, haystack: []const u8) ?Match {
            var iter = findIter(t, haystack);
            return iter.next();
        }

        pub fn isMatch(t: *const T, haystack: []const u8) bool {
            return find(t, haystack) != null;
        }

        /// Every match, including overlapping ones, in end-offset order. At
        /// one end offset the longest match comes first.
        pub const OverlappingIterator = struct {
            tables: *const T,
            haystack: []const u8,
            at: usize,
            end: usize,
            state: State,
            node: State,

            pub fn next(self: *OverlappingIterator) ?Match {
                while (true) {
                    if (self.node != self.tables.none) {
                        const node = self.node;
                        self.node = self.tables.links[node];
                        const id = self.tables.own_id[node];
                        return .{
                            .pattern = id,
                            .start = self.end - self.tables.patternLen(id),
                            .end = self.end,
                        };
                    }
                    if (self.at == self.haystack.len) return null;
                    self.state = self.tables.nextState(self.state, self.haystack[self.at]);
                    self.at += 1;
                    self.end = self.at;
                    self.node = if (self.tables.own_id[self.state] != self.tables.no_id)
                        self.state
                    else
                        self.tables.links[self.state];
                }
            }
        };

        pub fn findOverlappingIter(t: *const T, haystack: []const u8) OverlappingIterator {
            requireStandard(t, "findOverlappingIter");
            return .{
                .tables = t,
                .haystack = haystack,
                .at = 0,
                .end = 0,
                .state = 0,
                .node = t.none,
            };
        }

        pub fn findOverlapping(t: *const T, haystack: []const u8) ?Match {
            requireStandard(t, "findOverlapping");
            var iter = findOverlappingIter(t, haystack);
            return iter.next();
        }

        /// Write `haystack` to `writer`, replacing each non-overlapping match
        /// with the replacement at the same pattern index.
        pub fn replaceAll(
            t: *const T,
            writer: anytype,
            haystack: []const u8,
            replacements: []const []const u8,
        ) !void {
            if (replacements.len != t.pattern_lens.len) {
                @panic("aho-corasick: replaceAll needs one replacement per pattern");
            }
            var last: usize = 0;
            var iter = findIter(t, haystack);
            while (iter.next()) |m| {
                try writer.writeAll(haystack[last..m.start]);
                try writer.writeAll(replacements[m.pattern]);
                last = m.end;
            }
            try writer.writeAll(haystack[last..]);
        }

        fn requireStandard(t: *const T, comptime method: []const u8) void {
            if (t.match_kind != .standard) {
                @panic("aho-corasick: " ++ method ++ " needs MatchKind.standard");
            }
        }
    };
}
