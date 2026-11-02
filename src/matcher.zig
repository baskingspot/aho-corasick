//! A comptime-built Aho-Corasick automaton.
//!
//! The patterns and the options are comptime values. The trie, the failure
//! links, and the output links are built while the type is analyzed, and the
//! result is one block of read-only data. A search allocates nothing and takes
//! an `[]const u8`.
//!
//! ```zig
//! const ac = @import("aho-corasick");
//!
//! const Keywords = ac.Matcher(&.{ "apple", "maple" }, .{});
//! const m = Keywords.find("a maple leaf").?;
//! // m.pattern == 1, m.start == 2, m.end == 7
//! ```
//!
//! The build is arranged to suit the comptime evaluator. Every table is
//! written once and then copied into a `const` before anything reads it: a
//! mutable array that has been written many times is roughly a hundred times
//! slower to index than the same array behind a `const`.

const std = @import("std");
const math = std.math;
const testing = std.testing;
const ascii = std.ascii;
const Io = std.Io;

const bit_set = @import("bit_set.zig");
const Match = @import("Match.zig");
const MatchKind = @import("Options.zig").MatchKind;
const Options = @import("Options.zig").Options;
const Searcher = @import("Search.zig").Searcher;
const Tables = @import("Tables.zig").Tables;

/// Builds a matcher for `patterns` at comptime.
///
/// Pattern `i` in `patterns` is pattern id `i` in every `Match`. Two patterns
/// that are equal, including equal after ASCII case folding, are a compile
/// error. Empty patterns are a compile error: a zero-length match is a
/// different algorithm, and the iterators here promise progress.
pub fn Matcher(comptime patterns: []const []const u8, comptime options: Options) type {
    // The automaton is built while this type is analyzed. The default quota
    // of 1000 branches does not cover a dictionary.
    @setEvalBranchQuota(10_000_000);

    const n_patterns = patterns.len;
    if (n_patterns == 0) @compileError("aho-corasick: at least one pattern is required");
    if (n_patterns > math.maxInt(u32)) @compileError("aho-corasick: too many patterns");

    const total_bytes, const max_len = blk: {
        var bytes: usize = 0;
        var longest: usize = 0;
        for (patterns) |pattern| {
            if (pattern.len == 0) @compileError("aho-corasick: empty patterns are not supported");
            bytes += pattern.len;
            longest = @max(longest, pattern.len);
        }
        break :blk .{ bytes, longest };
    };

    const max_nodes = total_bytes + 1;
    const max_edges = max_nodes - 1;

    if (max_len > math.maxInt(u16)) @compileError("aho-corasick: pattern longer than 65535 bytes");

    // A node id never exceeds max_nodes. max_nodes itself is "no node".
    const NodeIndex = math.IntFittingRange(0, max_nodes);
    const none: NodeIndex = max_nodes;

    const no_id: u32 = @intCast(n_patterns);

    // Case folding is a byte-class remap, not extra trie branches, so a
    // case-insensitive automaton has the same shape as a sensitive one.
    const fold_table: [256]u8 = blk: {
        var table: [256]u8 = undefined;
        for (&table, 0..) |*folded, byte| {
            folded.* = @intCast(byte);
            if (options.ascii_case_insensitive and ascii.isAlphabetic(@intCast(byte))) {
                folded.* = ascii.toLower(@intCast(byte));
            }
        }
        break :blk table;
    };

    // One contiguous copy of every pattern, already folded. Comparisons and
    // the trie build then read `const` bytes instead of calling a function
    // per byte.
    const Folded = struct {
        const Self = @This();

        bytes: [total_bytes]u8,
        starts: [n_patterns + 1]u32,

        fn pattern(self: Self, id: u32) []const u8 {
            return self.bytes[self.starts[id]..self.starts[id + 1]];
        }
    };

    const folded: Folded = blk: {
        var bytes: [total_bytes]u8 = undefined;
        var starts: [n_patterns + 1]u32 = undefined;
        var at: usize = 0;
        for (patterns, 0..) |pattern, id| {
            starts[id] = @intCast(at);
            for (pattern) |byte| {
                bytes[at] = fold_table[byte];
                at += 1;
            }
        }
        starts[n_patterns] = @intCast(at);
        break :blk .{ .bytes = bytes, .starts = starts };
    };

    // Lexicographic order over the folded patterns. Building the trie in this
    // order means each pattern shares a prefix with the one before it, so the
    // trie is written from a path stack and never searched.
    const order: [n_patterns]u32 = blk: {
        var current: [n_patterns]u32 = undefined;
        for (&current, 0..) |*id, i| id.* = @intCast(i);

        var width: usize = 1;
        while (width < n_patterns) : (width *= 2) {
            const previous = current;
            var merged: [n_patterns]u32 = undefined;
            var low: usize = 0;
            while (low < n_patterns) : (low += 2 * width) {
                const mid = @min(low + width, n_patterns);
                const high = @min(low + 2 * width, n_patterns);
                var i: usize = low;
                var j: usize = mid;
                var k: usize = low;
                while (i < mid and j < high) {
                    const a = folded.pattern(previous[i]);
                    const b = folded.pattern(previous[j]);
                    if (std.mem.order(u8, b, a) == .lt) {
                        merged[k] = previous[j];
                        j += 1;
                    } else {
                        merged[k] = previous[i];
                        i += 1;
                    }
                    k += 1;
                }
                while (i < mid) {
                    merged[k] = previous[i];
                    i += 1;
                    k += 1;
                }
                while (j < high) {
                    merged[k] = previous[j];
                    j += 1;
                    k += 1;
                }
            }
            current = merged;
        }

        for (1..n_patterns) |i| {
            if (std.mem.eql(u8, folded.pattern(current[i - 1]), folded.pattern(current[i]))) {
                @compileError("aho-corasick: duplicate pattern");
            }
        }
        break :blk current;
    };

    const Trie = struct {
        const Self = @This();

        first_child: [max_nodes]NodeIndex,
        next_sibling: [max_edges]NodeIndex,
        edge_byte: [max_edges]u8,
        edge_to: [max_edges]NodeIndex,
        parent: [max_nodes]NodeIndex,
        in_byte: [max_nodes]u8,
        depths: [max_nodes]u16,
        /// The pattern that ends at the node, or no_id.
        own_id: [max_nodes]u32,
        node_count: u32,
        edge_count: u32,

        fn walk(self: Self, node: NodeIndex, byte: u8) NodeIndex {
            var edge = self.first_child[node];
            while (edge != none and self.edge_byte[edge] != byte) {
                edge = self.next_sibling[edge];
            }
            return if (edge == none) none else self.edge_to[edge];
        }
    };

    const trie: Trie = blk: {
        var first_child: [max_nodes]NodeIndex = @splat(none);
        var next_sibling: [max_edges]NodeIndex = @splat(none);
        var edge_byte: [max_edges]u8 = @splat(0);
        var edge_to: [max_edges]NodeIndex = @splat(0);
        var parent: [max_nodes]NodeIndex = @splat(0);
        var in_byte: [max_nodes]u8 = @splat(0);
        var depths: [max_nodes]u16 = @splat(0);
        var own_id: [max_nodes]u32 = @splat(no_id);
        var node_count: u32 = 1;
        var edge_count: u32 = 0;

        // stack[d] is the node for the length-d prefix of the previous
        // pattern. The previous pattern's path is the only one still open.
        var stack: [max_len + 1]NodeIndex = @splat(0);
        var previous: []const u8 = &.{};
        for (order) |id| {
            const pattern = folded.pattern(id);
            var shared: usize = 0;
            while (shared < previous.len and
                shared < pattern.len and
                previous[shared] == pattern[shared]) : (shared += 1)
            {}

            var depth: usize = shared;
            var node = stack[shared];
            while (depth < pattern.len) : (depth += 1) {
                const child: NodeIndex = @intCast(node_count);
                const edge: u32 = edge_count;
                node_count += 1;
                edge_count += 1;

                edge_byte[edge] = pattern[depth];
                edge_to[edge] = child;
                parent[child] = node;
                in_byte[child] = pattern[depth];
                depths[child] = @intCast(depth + 1);
                next_sibling[edge] = first_child[node];
                first_child[node] = edge;

                node = child;
                stack[depth + 1] = child;
            }
            own_id[node] = id;
            previous = pattern;
        }

        break :blk .{
            .first_child = first_child,
            .next_sibling = next_sibling,
            .edge_byte = edge_byte,
            .edge_to = edge_to,
            .parent = parent,
            .in_byte = in_byte,
            .depths = depths,
            .own_id = own_id,
            .node_count = node_count,
            .edge_count = edge_count,
        };
    };

    const alphabet_bytes = blk: {
        var seen: [256]bool = @splat(false);
        for (0..trie.edge_count) |edge| seen[trie.edge_byte[edge]] = true;
        var count: usize = 0;
        for (seen) |used| {
            if (used) count += 1;
        }
        var list: [count]u8 = undefined;
        var i: usize = 0;
        for (seen, 0..) |used, byte| {
            if (used) {
                list[i] = @intCast(byte);
                i += 1;
            }
        }
        break :blk list;
    };

    const Mask = bit_set.StateMask(@intCast(alphabet_bytes.len));

    const rank = struct {
        fn rank(mask: Mask, index: usize) usize {
            const shift: Mask.ShiftInt = @intCast(index);
            const one: Mask.MaskInt = 1;
            return @popCount(mask.mask & ((one << shift) - one));
        }
    }.rank;

    // Nodes grouped by depth. Failure links go to strictly shallower nodes,
    // so the build walks one level at a time and never re-reads the array it
    // is filling. Scanning every node once per level would be one array read
    // per node per level, and an array read costs its whole length.
    const Levels = struct {
        const Self = @This();

        start: [max_len + 2]u32,
        nodes: [max_nodes]NodeIndex,

        fn slice(self: Self, depth: usize) []const NodeIndex {
            return self.nodes[self.start[depth]..self.start[depth + 1]];
        }
    };

    const levels: Levels = blk: {
        var counts: [max_len + 2]u32 = @splat(0);
        for (0..trie.node_count) |node| counts[trie.depths[node]] += 1;

        var start: [max_len + 2]u32 = @splat(0);
        var at: u32 = 0;
        for (&start, 0..) |*slot, depth| {
            slot.* = at;
            at += counts[depth];
        }

        var cursor = start;
        var nodes: [max_nodes]NodeIndex = @splat(0);
        for (0..trie.node_count) |node| {
            const depth = trie.depths[node];
            nodes[cursor[depth]] = @intCast(node);
            cursor[depth] += 1;
        }
        break :blk .{ .start = start, .nodes = nodes };
    };

    const failures: [max_nodes]NodeIndex = blk: {
        var table: [max_nodes]NodeIndex = @splat(0);
        var depth: usize = 2;
        while (depth <= max_len) : (depth += 1) {
            const previous = table;
            var level = previous;
            for (levels.slice(depth)) |node| {
                const byte = trie.in_byte[node];
                var f = previous[trie.parent[node]];
                while (true) {
                    const candidate = trie.walk(f, byte);
                    if (candidate != none) {
                        level[node] = candidate;
                        break;
                    }
                    if (f == 0) {
                        level[node] = 0;
                        break;
                    }
                    f = previous[f];
                }
            }
            table = level;
        }
        break :blk table;
    };

    const links: [max_nodes]NodeIndex = blk: {
        var table: [max_nodes]NodeIndex = @splat(none);
        var depth: usize = 1;
        while (depth <= max_len) : (depth += 1) {
            const previous = table;
            var level = previous;
            for (levels.slice(depth)) |node| {
                const f = failures[node];
                level[node] = if (trie.own_id[f] != no_id) f else previous[f];
            }
            table = level;
        }
        break :blk table;
    };

    const classes: [256]u16 = blk: {
        var table: [256]u16 = @splat(@as(u16, @intCast(alphabet_bytes.len)));
        for (&table, 0..) |*class, byte| {
            const folded_byte = fold_table[@intCast(byte)];
            for (alphabet_bytes, 0..) |candidate, index| {
                if (candidate == folded_byte) {
                    class.* = @intCast(index);
                    break;
                }
            }
        }
        break :blk table;
    };

    const pattern_lens: [n_patterns]u32 = blk: {
        var lens: [n_patterns]u32 = undefined;
        for (patterns, 0..) |bytes, id| lens[id] = @intCast(bytes.len);
        break :blk lens;
    };

    const Compact = struct {
        masks: [max_nodes]Mask,
        offsets: [max_nodes]u32,
        children: [max_edges]NodeIndex,
    };

    const compact: Compact = blk: {
        var masks: [max_nodes]Mask = @splat(bit_set.empty(Mask));
        var offsets: [max_nodes]u32 = @splat(0);
        var children: [max_edges]NodeIndex = @splat(0);
        var packed_len: usize = 0;

        for (0..trie.node_count) |node| {
            var mask = bit_set.empty(Mask);
            var edge = trie.first_child[node];
            while (edge != none) : (edge = trie.next_sibling[edge]) {
                mask.set(classes[trie.edge_byte[edge]]);
            }
            masks[node] = mask;
            offsets[node] = @intCast(packed_len);

            edge = trie.first_child[node];
            while (edge != none) : (edge = trie.next_sibling[edge]) {
                const class = classes[trie.edge_byte[edge]];
                children[packed_len + rank(mask, class)] = trie.edge_to[edge];
            }
            packed_len += mask.count();
        }

        break :blk .{ .masks = masks, .offsets = offsets, .children = children };
    };

    const root_next: [256]NodeIndex = blk: {
        var out: [256]NodeIndex = @splat(0);
        for (0..256) |byte| {
            const class = classes[byte];
            if (class == alphabet_bytes.len) continue;
            if (compact.masks[0].isSet(class)) {
                out[byte] = compact.children[rank(compact.masks[0], class)];
            }
        }
        break :blk out;
    };

    const TablesImpl = Tables(NodeIndex, Mask);
    const Search = Searcher(TablesImpl);

    return struct {
        const tables: TablesImpl = .{
            .failure = failures[0..trie.node_count],
            .links = links[0..trie.node_count],
            .masks = compact.masks[0..trie.node_count],
            .offsets = compact.offsets[0..trie.node_count],
            .children = compact.children[0..trie.edge_count],
            .depths = trie.depths[0..trie.node_count],
            .own_id = trie.own_id[0..trie.node_count],
            .classes = classes,
            .alphabet = &alphabet_bytes,
            .root = &root_next,
            .pattern_lens = &pattern_lens,
            .match_kind = options.match_kind,
            .no_id = no_id,
            .none = none,
        };

        pub const State = NodeIndex;

        /// The state before any byte has been read.
        pub const start_state: State = 0;

        pub fn patternCount() usize {
            return n_patterns;
        }

        pub fn patternLen(id: u32) usize {
            return patterns[id].len;
        }

        pub fn minPatternLen() usize {
            var min: usize = max_len;
            for (patterns) |bytes| min = @min(min, bytes.len);
            return min;
        }

        pub fn maxPatternLen() usize {
            return max_len;
        }

        pub fn matchKind() MatchKind {
            return options.match_kind;
        }

        /// The size of each table in the automaton, in bytes. The arrays are
        /// sized for the worst case, not for the nodes actually built.
        pub const Memory = struct {
            total: usize,
            failure: usize,
            links: usize,
            masks: usize,
            offsets: usize,
            children: usize,
            depths: usize,
            own_id: usize,
            classes: usize,
            alphabet: usize,
        };

        pub fn memory() Memory {
            const failure_size = max_nodes * @sizeOf(NodeIndex);
            const links_size = max_nodes * @sizeOf(NodeIndex);
            const masks_size = max_nodes * @sizeOf(Mask);
            const offsets_size = max_nodes * @sizeOf(u32);
            const children_size = max_edges * @sizeOf(NodeIndex);
            const depths_size = max_nodes * @sizeOf(u16);
            const own_id_size = max_nodes * @sizeOf(u32);
            const classes_size = 256 * @sizeOf(u16);
            const alphabet_size = alphabet_bytes.len * @sizeOf(u8);
            return .{
                .total = failure_size + links_size + masks_size + offsets_size +
                    children_size + depths_size + own_id_size + classes_size + alphabet_size,
                .failure = failure_size,
                .links = links_size,
                .masks = masks_size,
                .offsets = offsets_size,
                .children = children_size,
                .depths = depths_size,
                .own_id = own_id_size,
                .classes = classes_size,
                .alphabet = alphabet_size,
            };
        }

        pub fn memoryUsage() usize {
            return memory().total;
        }

        pub fn stateCount() usize {
            return tables.stateCount();
        }

        pub fn transitionCount() usize {
            return trie.edge_count;
        }

        pub fn alphabet() []const u8 {
            return tables.alphabet;
        }

        /// The pattern at `id`.
        pub fn pattern(id: u32) []const u8 {
            return patterns[id];
        }

        pub fn stateDepth(state: State) usize {
            return tables.stateDepth(state);
        }

        pub fn stateFailure(state: State) State {
            return tables.stateFailure(state);
        }

        pub fn stateOutput(state: State) ?u32 {
            return tables.stateOutput(state);
        }

        pub fn transitions(state: State) Search.Transitions {
            return Search.transitions(&tables, state);
        }

        pub fn matchesAt(state: State, end: usize) Search.Matches {
            return Search.matchesAt(&tables, state, end);
        }

        pub fn firstMatch(state: State, end: usize) ?Match {
            return Search.firstMatch(&tables, state, end);
        }

        pub inline fn nextState(state: State, byte: u8) State {
            return tables.nextState(state, byte);
        }

        pub fn isMatchState(state: State) bool {
            return tables.own_id[state] != no_id or tables.links[state] != none;
        }

        /// The first match in the haystack, or null.
        pub fn find(haystack: []const u8) ?Match {
            return Search.find(&tables, haystack);
        }

        pub fn isMatch(haystack: []const u8) bool {
            return Search.isMatch(&tables, haystack);
        }

        /// Non-overlapping matches according to `matchKind()`.
        pub fn findIter(haystack: []const u8) Search.Iterator {
            return Search.findIter(&tables, haystack);
        }

        /// The first match in end-offset order. Only for `.standard`.
        pub fn findOverlapping(haystack: []const u8) ?Match {
            comptime requireStandard("findOverlapping");
            return Search.findOverlapping(&tables, haystack);
        }

        /// Every match, including overlapping ones, in end-offset order.
        /// Only for `.standard`.
        pub fn findOverlappingIter(haystack: []const u8) Search.OverlappingIterator {
            comptime requireStandard("findOverlappingIter");
            return Search.findOverlappingIter(&tables, haystack);
        }

        /// The set of patterns that match anywhere in the haystack. Only for
        /// `.standard`.
        pub const PatternSet = bit_set.PatternSet(n_patterns);

        pub fn whichMatches(haystack: []const u8) PatternSet {
            comptime requireStandard("whichMatches");
            var set = bit_set.empty(PatternSet);
            var iter = Search.findOverlappingIter(&tables, haystack);
            while (iter.next()) |m| set.set(m.pattern);
            return set;
        }

        /// Write `haystack` to `writer`, replacing each non-overlapping match
        /// with the replacement at the same pattern index.
        pub fn replaceAll(
            writer: anytype,
            haystack: []const u8,
            replacements: []const []const u8,
        ) !void {
            return Search.replaceAll(&tables, writer, haystack, replacements);
        }

        fn requireStandard(comptime method: []const u8) void {
            if (options.match_kind != .standard) @compileError(
                "aho-corasick: " ++ method ++ " needs MatchKind.standard",
            );
        }
    };
}

test "finds a pattern and its span" {
    const Keywords = Matcher(&.{ "apple", "maple" }, .{});
    const m = Keywords.find("a maple leaf").?;
    try testing.expectEqual(1, m.pattern);
    try testing.expectEqual(2, m.start);
    try testing.expectEqual(7, m.end);
    try testing.expect(Keywords.isMatch("apple"));
    try testing.expect(!Keywords.isMatch("banana"));
}

test "standard reports the earliest end" {
    const M = Matcher(&.{ "b", "abc", "abcd" }, .{});
    const m = M.find("abcd").?;
    try testing.expectEqual(0, m.pattern);
    try testing.expectEqual(1, m.start);
    try testing.expectEqual(2, m.end);
}

test "leftmost first prefers the earlier pattern at one start" {
    const M = Matcher(&.{ "b", "abc", "abcd" }, .{ .match_kind = .leftmost_first });
    const m = M.find("abcd").?;
    try testing.expectEqual(1, m.pattern);
    try testing.expectEqual(0, m.start);
    try testing.expectEqual(3, m.end);
}

test "leftmost longest prefers the longer pattern at one start" {
    const M = Matcher(&.{ "b", "abc", "abcd" }, .{ .match_kind = .leftmost_longest });
    const m = M.find("abcd").?;
    try testing.expectEqual(2, m.pattern);
    try testing.expectEqual(0, m.start);
    try testing.expectEqual(4, m.end);
}

test "leftmost longest waits for a longer match to finish" {
    const M = Matcher(&.{ "ab", "abcx" }, .{ .match_kind = .leftmost_longest });
    const m = M.find("abcx").?;
    try testing.expectEqual(1, m.pattern);
    try testing.expectEqual(0, m.start);
    try testing.expectEqual(4, m.end);
}

test "leftmost first keeps the earlier pattern when a longer one finishes" {
    const M = Matcher(&.{ "ab", "abcx" }, .{ .match_kind = .leftmost_first });
    const m = M.find("abcx").?;
    try testing.expectEqual(0, m.pattern);
    try testing.expectEqual(2, m.end);
}

test "iterates like the rust crate: standard" {
    const M = Matcher(&.{ "append", "appendage", "app" }, .{});
    var iter = M.findIter("append the app to the appendage");
    const expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 2, .start = 0, .end = 3 },
        .{ .pattern = 2, .start = 11, .end = 14 },
        .{ .pattern = 2, .start = 22, .end = 25 },
    };
    for (expected) |want| {
        const got = iter.next().?;
        try testing.expectEqual(want.pattern, got.pattern);
        try testing.expectEqual(want.start, got.start);
        try testing.expectEqual(want.end, got.end);
    }
    try testing.expect(iter.next() == null);
}

test "iterates like the rust crate: leftmost first" {
    const M = Matcher(&.{ "append", "appendage", "app" }, .{ .match_kind = .leftmost_first });
    var iter = M.findIter("append the app to the appendage");
    const expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 0, .start = 0, .end = 6 },
        .{ .pattern = 2, .start = 11, .end = 14 },
        .{ .pattern = 0, .start = 22, .end = 28 },
    };
    for (expected) |want| {
        const got = iter.next().?;
        try testing.expectEqual(want.pattern, got.pattern);
        try testing.expectEqual(want.start, got.start);
        try testing.expectEqual(want.end, got.end);
    }
    try testing.expect(iter.next() == null);
}

test "iterates like the rust crate: leftmost longest" {
    const M = Matcher(&.{ "append", "appendage", "app" }, .{ .match_kind = .leftmost_longest });
    var iter = M.findIter("append the app to the appendage");
    const expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 0, .start = 0, .end = 6 },
        .{ .pattern = 2, .start = 11, .end = 14 },
        .{ .pattern = 1, .start = 22, .end = 31 },
    };
    for (expected) |want| {
        const got = iter.next().?;
        try testing.expectEqual(want.pattern, got.pattern);
        try testing.expectEqual(want.start, got.start);
        try testing.expectEqual(want.end, got.end);
    }
    try testing.expect(iter.next() == null);
}

test "overlapping matches come in end order" {
    const M = Matcher(&.{ "append", "appendage", "app" }, .{});
    var iter = M.findOverlappingIter("append the app to the appendage");
    const expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 2, .start = 0, .end = 3 },
        .{ .pattern = 0, .start = 0, .end = 6 },
        .{ .pattern = 2, .start = 11, .end = 14 },
        .{ .pattern = 2, .start = 22, .end = 25 },
        .{ .pattern = 0, .start = 22, .end = 28 },
        .{ .pattern = 1, .start = 22, .end = 31 },
    };
    for (expected) |want| {
        const got = iter.next().?;
        try testing.expectEqual(want.pattern, got.pattern);
        try testing.expectEqual(want.start, got.start);
        try testing.expectEqual(want.end, got.end);
    }
    try testing.expect(iter.next() == null);
}

test "suffix matches are reported from the failure chain" {
    const M = Matcher(&.{ "he", "she", "hers" }, .{});
    var iter = M.findOverlappingIter("ushers");
    const expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 1, .start = 1, .end = 4 }, // she
        .{ .pattern = 0, .start = 2, .end = 4 }, // he
        .{ .pattern = 2, .start = 2, .end = 6 }, // hers
    };
    for (expected) |want| {
        const got = iter.next().?;
        try testing.expectEqual(want.pattern, got.pattern);
        try testing.expectEqual(want.start, got.start);
        try testing.expectEqual(want.end, got.end);
    }
    try testing.expect(iter.next() == null);
}

test "shared prefixes" {
    const M = Matcher(&.{ "abc", "abcd", "abcde" }, .{});
    try testing.expectEqual(0, M.find("abc").?.pattern);
    try testing.expectEqual(0, M.find("xabc").?.pattern);
    try testing.expectEqual(0, M.find("abcd").?.pattern);
    try testing.expectEqual(0, M.find("xabcde").?.pattern);
}

test "single byte patterns" {
    const M = Matcher(&.{ "a", "b" }, .{});
    try testing.expectEqual(0, M.find("a").?.pattern);
    try testing.expectEqual(1, M.find("b").?.pattern);
    try testing.expectEqual(0, M.find("xax").?.pattern);
    try testing.expect(M.find("xyz") == null);
}

test "empty and unmatched haystacks" {
    const M = Matcher(&.{"test"}, .{});
    try testing.expect(M.find("") == null);
    try testing.expect(M.find("xyz123") == null);
    try testing.expect(M.find("tes") == null);
}

test "non-ASCII bytes match exactly" {
    const M = Matcher(&.{ "caf\xc3\xa9", "\xf0\x9f\xa6\x8e" }, .{});
    const m = M.find("un caf\xc3\xa9").?;
    try testing.expectEqual(0, m.pattern);
    try testing.expectEqual(3, m.start);
    try testing.expectEqual(8, m.end);
    try testing.expectEqual(1, M.find("lizard \xf0\x9f\xa6\x8e").?.pattern);
}

test "ASCII case insensitive matches both cases" {
    const M = Matcher(&.{ "apple", "maple", "snapple" }, .{ .ascii_case_insensitive = true });
    var iter = M.findIter("Nobody likes maple in their apple flavored Snapple.");
    const expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 1, .start = 13, .end = 18 },
        .{ .pattern = 0, .start = 28, .end = 33 },
        .{ .pattern = 2, .start = 43, .end = 50 },
    };
    for (expected) |want| {
        const got = iter.next().?;
        try testing.expectEqual(want.pattern, got.pattern);
        try testing.expectEqual(want.start, got.start);
        try testing.expectEqual(want.end, got.end);
    }
    try testing.expect(iter.next() == null);
}

test "case insensitivity folds a pattern written in mixed case" {
    const M = Matcher(&.{"WaRnInG"}, .{ .ascii_case_insensitive = true });
    const m = M.find("a warning sign").?;
    try testing.expectEqual(2, m.start);
    try testing.expectEqual(9, m.end);
}

test "whichMatches reports every pattern that appears" {
    const M = Matcher(&.{ "error", "warning", "info" }, .{});
    const set = M.whichMatches("an error and a warning");
    try testing.expect(set.isSet(0));
    try testing.expect(set.isSet(1));
    try testing.expect(!set.isSet(2));
    try testing.expectEqual(2, set.count());
}

test "replaceAll writes the replacements in place" {
    const M = Matcher(&.{ "fox", "brown", "quick" }, .{});
    var buffer: [64]u8 = undefined;
    var writer: Io.Writer = .fixed(&buffer);
    try M.replaceAll(&writer, "The quick brown fox.", &.{ "sloth", "grey", "slow" });
    try testing.expectEqualStrings("The slow grey sloth.", writer.buffered());
}

test "the state machine can be driven by hand" {
    const M = Matcher(&.{ "she", "he" }, .{});
    var state = M.start_state;
    var end: usize = 0;
    for ("she") |byte| {
        state = M.nextState(state, byte);
        end += 1;
    }
    try testing.expect(M.isMatchState(state));
    const first = M.firstMatch(state, end).?;
    try testing.expectEqual(0, first.pattern);
    try testing.expectEqual(0, first.start);
    try testing.expectEqual(3, first.end);
}

test "memory usage is the table and nothing else" {
    const M = Matcher(&.{ "alpha", "beta", "gamma" }, .{});
    try testing.expect(M.memoryUsage() > 0);
    try testing.expectEqual(@as(usize, 3), M.patternCount());
    try testing.expectEqual(@as(usize, 4), M.minPatternLen());
    try testing.expectEqual(@as(usize, 5), M.maxPatternLen());
}
