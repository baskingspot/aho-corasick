//! The tables a searcher reads.
//!
//! The comptime `Matcher` keeps them in arrays that are sized for the worst
//! case. The runtime `Automaton` keeps the same fields in allocated slices.
//! Sharing the field names lets one searcher work on both.

const Options = @import("Options.zig");

pub fn Tables(comptime State: type, comptime Mask: type) type {
    return struct {
        const Self = @This();

        pub const StateType = State;
        pub const MaskType = Mask;

        failure: []const State,
        /// The nearest node up the failure chain with an own id, or none.
        links: []const State,
        /// One bit per alphabet class. The set bits index the packed child
        /// array through `offsets` and `rank`.
        masks: []const Mask,
        offsets: []const u32,
        children: []const State,
        /// The length of the text a node matched, used by leftmost search to
        /// decide when no earlier match can still be in flight.
        depths: []const u16,
        own_id: []const u32,
        /// The alphabet class of every byte, or `alphabet.len` when the byte
        /// cannot start or extend a match.
        classes: [256]u16,
        /// The distinct pattern bytes, in class order.
        alphabet: []const u8,
        /// The length of each pattern, indexed by pattern id.
        pattern_lens: []const u32,
        match_kind: Options.MatchKind,
        no_id: u32,
        none: State,

        pub fn stateCount(self: Self) usize {
            return self.masks.len;
        }

        pub fn alphabetLen(self: Self) usize {
            return self.alphabet.len;
        }

        pub fn rank(mask: Mask, index: usize) usize {
            const shift: Mask.ShiftInt = @intCast(index);
            const one: Mask.MaskInt = 1;
            return @popCount(mask.mask & ((one << shift) - one));
        }

        pub fn nextState(self: Self, state: State, byte: u8) State {
            const class = self.classes[byte];
            if (self.alphabetLen() != 256 and class == self.alphabetLen()) return 0;

            var current = state;
            while (!self.masks[current].isSet(class)) {
                if (current == 0) return 0;
                current = self.failure[current];
            }
            const index = rank(self.masks[current], class);
            return self.children[@as(usize, self.offsets[current]) + index];
        }

        pub fn stateDepth(self: Self, state: State) usize {
            return self.depths[state];
        }

        pub fn stateFailure(self: Self, state: State) State {
            return self.failure[state];
        }

        pub fn stateOutput(self: Self, state: State) ?u32 {
            const id = self.own_id[state];
            return if (id == self.no_id) null else id;
        }

        pub fn linkOf(self: Self, state: State) State {
            return self.links[state];
        }

        pub fn patternLen(self: Self, id: u32) usize {
            return self.pattern_lens[id];
        }
    };
}
