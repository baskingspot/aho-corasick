//! A runtime-built Aho-Corasick automaton.
//!
//! `Matcher` builds at comptime from a pattern list in the type. This type
//! builds the same tables at runtime from patterns the caller supplies, which
//! is what a program reading a dictionary or a tool inspecting an automaton
//! needs.

const std = @import("std");
const ascii = std.ascii;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const math = std.math;
const ArenaAllocator = std.heap.ArenaAllocator;

const bit_set = @import("bit_set.zig");
const Match = @import("Match.zig");
const Matcher = @import("matcher.zig").Matcher;
const MatchKind = @import("Options.zig").MatchKind;
const Options = @import("Options.zig").Options;
const Searcher = @import("Search.zig").Searcher;
const Tables = @import("Tables.zig").Tables;

const Automaton = @This();

const no_id: u32 = math.maxInt(u32);
const none: u32 = math.maxInt(u32);

pub const State = u32;

/// The state before any byte has been read.
pub const start_state: State = 0;
const Mask = bit_set.StateMask(256);
const TablesImpl = Tables(State, Mask);
const Search = Searcher(TablesImpl);

pub const Error = error{
    NoPatterns,
    TooManyPatterns,
    EmptyPattern,
    DuplicatePattern,
    PatternTooLong,
    OutOfMemory,
};

arena: ArenaAllocator,
tables: TablesImpl,
pattern_bytes: []const u8,
pattern_starts: []const u32,

/// Builds the automaton for `patterns`. The automaton copies the pattern
/// bytes, so the caller can free its own copy after this returns.
pub fn init(
    gpa: Allocator,
    patterns: []const []const u8,
    options: Options,
) Error!Automaton {
    if (patterns.len == 0) return error.NoPatterns;
    if (patterns.len > math.maxInt(u32) - 1) return error.TooManyPatterns;

    var total: usize = 0;
    for (patterns) |bytes| {
        if (bytes.len == 0) return error.EmptyPattern;
        if (bytes.len > math.maxInt(u16)) return error.PatternTooLong;
        total = math.add(usize, total, bytes.len) catch return error.PatternTooLong;
    }
    if (total >= math.maxInt(u32)) return error.PatternTooLong;

    var arena: ArenaAllocator = .init(gpa);
    errdefer arena.deinit();
    const allocator = arena.allocator();

    const pattern_bytes = try allocator.alloc(u8, total);
    const pattern_starts = try allocator.alloc(u32, patterns.len + 1);
    const pattern_lens = try allocator.alloc(u32, patterns.len);
    {
        var at: usize = 0;
        for (patterns, 0..) |bytes, id| {
            pattern_starts[id] = @intCast(at);
            pattern_lens[id] = @intCast(bytes.len);
            @memcpy(pattern_bytes[at..][0..bytes.len], bytes);
            at += bytes.len;
        }
        pattern_starts[patterns.len] = @intCast(at);
    }

    const Fold = struct {
        fn byte(opts: Options, raw: u8) u8 {
            return if (opts.ascii_case_insensitive and ascii.isAlphabetic(raw))
                ascii.toLower(raw)
            else
                raw;
        }
    };

    // The trie is a sibling list per node. It is scratch: the tables below
    // are the compact form the searcher reads.
    const BuildNode = struct {
        first_child: u32 = none,
        next_sibling: u32 = none,
        parent: u32 = 0,
        in_byte: u8 = 0,
        depth: u16 = 0,
        own_id: u32 = no_id,
    };
    const BuildEdge = struct {
        byte: u8,
        to: u32,
        next: u32,
    };
    const Walk = struct {
        fn child(nodes: []const BuildNode, edges: []const BuildEdge, node: u32, byte: u8) u32 {
            var edge = nodes[node].first_child;
            while (edge != none and edges[edge].byte != byte) : (edge = edges[edge].next) {}
            return if (edge == none) none else edges[edge].to;
        }
    };

    var nodes: std.ArrayList(BuildNode) = .empty;
    var edges: std.ArrayList(BuildEdge) = .empty;
    try nodes.append(allocator, .{});

    for (patterns, 0..) |bytes, id| {
        var node: u32 = 0;
        for (bytes) |raw| {
            const byte = Fold.byte(options, raw);
            var edge = nodes.items[node].first_child;
            while (edge != none and edges.items[edge].byte != byte) {
                edge = edges.items[edge].next;
            }
            if (edge == none) {
                const child: u32 = @intCast(nodes.items.len);
                try nodes.append(allocator, .{
                    .parent = node,
                    .in_byte = byte,
                    .depth = nodes.items[node].depth + 1,
                });
                const index: u32 = @intCast(edges.items.len);
                try edges.append(allocator, .{
                    .byte = byte,
                    .to = child,
                    .next = nodes.items[node].first_child,
                });
                nodes.items[node].first_child = index;
                node = child;
            } else {
                node = edges.items[edge].to;
            }
        }
        if (nodes.items[node].own_id != no_id) return error.DuplicatePattern;
        nodes.items[node].own_id = @intCast(id);
    }

    const state_count = nodes.items.len;
    const failure = try allocator.alloc(u32, state_count);
    @memset(failure, 0);
    const queue = try allocator.alloc(u32, state_count);
    var head: usize = 0;
    var tail: usize = 0;
    {
        var edge = nodes.items[0].first_child;
        while (edge != none) : (edge = edges.items[edge].next) {
            queue[tail] = edges.items[edge].to;
            tail += 1;
        }
    }
    while (head < tail) : (head += 1) {
        const node = queue[head];
        var edge = nodes.items[node].first_child;
        while (edge != none) : (edge = edges.items[edge].next) {
            const child = edges.items[edge].to;
            const byte = edges.items[edge].byte;
            var f = failure[node];
            while (true) {
                const target = Walk.child(nodes.items, edges.items, f, byte);
                if (target != none) {
                    failure[child] = target;
                    break;
                }
                if (f == 0) {
                    failure[child] = 0;
                    break;
                }
                f = failure[f];
            }
            queue[tail] = child;
            tail += 1;
        }
    }

    const links = try allocator.alloc(u32, state_count);
    @memset(links, none);
    for (queue[0..tail]) |node| {
        const f = failure[node];
        links[node] = if (nodes.items[f].own_id != no_id) f else links[f];
    }

    var seen: [256]bool = @splat(false);
    for (edges.items) |edge| seen[edge.byte] = true;
    var alphabet_len: usize = 0;
    for (seen) |used| {
        if (used) alphabet_len += 1;
    }
    const alphabet_bytes = try allocator.alloc(u8, alphabet_len);
    {
        var index: usize = 0;
        for (seen, 0..) |used, byte| {
            if (used) {
                alphabet_bytes[index] = @intCast(byte);
                index += 1;
            }
        }
    }

    var classes: [256]u16 = @splat(@as(u16, @intCast(alphabet_len)));
    for (&classes, 0..) |*class, raw| {
        const byte = Fold.byte(options, @intCast(raw));
        for (alphabet_bytes, 0..) |candidate, index| {
            if (candidate == byte) {
                class.* = @intCast(index);
                break;
            }
        }
    }

    const masks = try allocator.alloc(Mask, state_count);
    const offsets = try allocator.alloc(u32, state_count);
    const children = try allocator.alloc(u32, edges.items.len);
    const depths = try allocator.alloc(u16, state_count);
    const own_id = try allocator.alloc(u32, state_count);
    var packed_len: usize = 0;
    for (nodes.items, 0..) |node, state| {
        var mask = bit_set.empty(Mask);
        var edge = node.first_child;
        while (edge != none) : (edge = edges.items[edge].next) {
            mask.set(classes[edges.items[edge].byte]);
        }
        masks[state] = mask;
        offsets[state] = @intCast(packed_len);

        edge = node.first_child;
        while (edge != none) : (edge = edges.items[edge].next) {
            const class = classes[edges.items[edge].byte];
            children[packed_len + TablesImpl.rank(mask, class)] = edges.items[edge].to;
        }
        packed_len += mask.count();
        depths[state] = node.depth;
        own_id[state] = node.own_id;
    }

    const root = try allocator.alloc(u32, 256);
    for (0..256) |byte| {
        const class = classes[byte];
        root[byte] = if (class == alphabet_len or !masks[0].isSet(class))
            0
        else
            children[TablesImpl.rank(masks[0], class)];
    }

    const tables: TablesImpl = .{
        .failure = failure,
        .links = links,
        .masks = masks,
        .offsets = offsets,
        .children = children,
        .depths = depths,
        .own_id = own_id,
        .classes = classes,
        .alphabet = alphabet_bytes,
        .root = root,
        .pattern_lens = pattern_lens,
        .match_kind = options.match_kind,
        .no_id = no_id,
        .none = none,
    };

    return .{
        .arena = arena,
        .tables = tables,
        .pattern_bytes = pattern_bytes,
        .pattern_starts = pattern_starts,
    };
}

pub fn deinit(self: *Automaton) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn pattern(self: *const Automaton, id: u32) []const u8 {
    return self.pattern_bytes[self.pattern_starts[id]..self.pattern_starts[id + 1]];
}

pub fn patternCount(self: *const Automaton) usize {
    return self.tables.pattern_lens.len;
}

pub fn patternLen(self: *const Automaton, id: u32) usize {
    return self.tables.patternLen(id);
}

pub fn minPatternLen(self: *const Automaton) usize {
    var min: usize = math.maxInt(usize);
    for (self.tables.pattern_lens) |len| min = @min(min, len);
    return min;
}

pub fn maxPatternLen(self: *const Automaton) usize {
    var max: usize = 0;
    for (self.tables.pattern_lens) |len| max = @max(max, len);
    return max;
}

pub fn matchKind(self: *const Automaton) MatchKind {
    return self.tables.match_kind;
}

pub fn stateCount(self: *const Automaton) usize {
    return self.tables.stateCount();
}

pub fn transitionCount(self: *const Automaton) usize {
    return self.tables.children.len;
}

pub fn alphabet(self: *const Automaton) []const u8 {
    return self.tables.alphabet;
}

pub fn stateDepth(self: *const Automaton, state: State) usize {
    return self.tables.stateDepth(state);
}

pub fn stateFailure(self: *const Automaton, state: State) State {
    return self.tables.stateFailure(state);
}

pub fn stateOutput(self: *const Automaton, state: State) ?u32 {
    return self.tables.stateOutput(state);
}

pub fn transitions(self: *const Automaton, state: State) Search.Transitions {
    return Search.transitions(&self.tables, state);
}

pub fn matchesAt(self: *const Automaton, state: State, end: usize) Search.Matches {
    return Search.matchesAt(&self.tables, state, end);
}

pub fn firstMatch(self: *const Automaton, state: State, end: usize) ?Match {
    return Search.firstMatch(&self.tables, state, end);
}

pub inline fn nextState(self: *const Automaton, state: State, byte: u8) State {
    return self.tables.nextState(state, byte);
}

pub fn isMatchState(self: *const Automaton, state: State) bool {
    return self.tables.own_id[state] != no_id or self.tables.links[state] != none;
}

pub fn find(self: *const Automaton, haystack: []const u8) ?Match {
    return Search.find(&self.tables, haystack);
}

pub fn isMatch(self: *const Automaton, haystack: []const u8) bool {
    return Search.isMatch(&self.tables, haystack);
}

pub fn findIter(self: *const Automaton, haystack: []const u8) Search.Iterator {
    return Search.findIter(&self.tables, haystack);
}

pub fn findOverlapping(self: *const Automaton, haystack: []const u8) ?Match {
    return Search.findOverlapping(&self.tables, haystack);
}

pub fn findOverlappingIter(
    self: *const Automaton,
    haystack: []const u8,
) Search.OverlappingIterator {
    return Search.findOverlappingIter(&self.tables, haystack);
}

pub fn whichMatches(
    self: *const Automaton,
    gpa: Allocator,
    haystack: []const u8,
) !bit_set.RuntimeSet {
    var set: bit_set.RuntimeSet = try .initEmpty(gpa, self.patternCount());
    errdefer set.deinit(gpa);
    var iter = self.findOverlappingIter(haystack);
    while (iter.next()) |m| set.set(m.pattern);
    return set;
}

pub fn replaceAll(
    self: *const Automaton,
    writer: anytype,
    haystack: []const u8,
    replacements: []const []const u8,
) !void {
    return Search.replaceAll(&self.tables, writer, haystack, replacements);
}

/// Bytes allocated for the tables and the pattern copy. The arena may hold
/// more than this: the build's scratch lists live until `deinit`.
pub fn memoryUsage(self: *const Automaton) usize {
    return self.tables.failure.len * @sizeOf(u32) +
        self.tables.links.len * @sizeOf(u32) +
        self.tables.masks.len * @sizeOf(Mask) +
        self.tables.offsets.len * @sizeOf(u32) +
        self.tables.children.len * @sizeOf(u32) +
        self.tables.depths.len * @sizeOf(u16) +
        self.tables.own_id.len * @sizeOf(u32) +
        @sizeOf(@TypeOf(self.tables.classes)) +
        self.tables.alphabet.len +
        self.pattern_bytes.len +
        self.pattern_starts.len * @sizeOf(u32);
}

/// A dense DFA built from the runtime NFA.
///
/// The NFA follows failure links on a transition miss. This type precomputes
/// every transition for every state and alphabet class, so a byte is one
/// table lookup. It keeps the NFA for the outputs, the pattern bytes, and the
/// introspection methods; the search reads the dense table.
pub const Dfa = struct {
    const DfaTables = struct {
        pub const StateType = u32;

        goto: []const u32,
        alphabet: []const u8,
        classes: [256]u16,
        own_id: []const u32,
        links: []const u32,
        depths: []const u16,
        pattern_lens: []const u32,
        match_kind: MatchKind,
        no_id: u32,
        none: u32,

        pub fn nextState(self: *const DfaTables, state: u32, byte: u8) u32 {
            const class = self.classes[byte];
            if (class == self.alphabet.len) return 0;
            return self.goto[@as(usize, state) * self.alphabet.len + class];
        }

        pub fn stateCount(self: *const DfaTables) usize {
            return self.own_id.len;
        }

        pub fn alphabetLen(self: *const DfaTables) usize {
            return self.alphabet.len;
        }

        pub fn patternLen(self: *const DfaTables, id: u32) usize {
            return self.pattern_lens[id];
        }

        pub fn stateDepth(self: *const DfaTables, state: u32) usize {
            return self.depths[state];
        }
    };

    const DfaSearch = Searcher(DfaTables);

    nfa: Automaton,
    goto: []u32,
    tables: DfaTables,
    gpa: Allocator,

    pub fn init(
        gpa: Allocator,
        patterns: []const []const u8,
        options: Options,
    ) Error!Dfa {
        var nfa = try Automaton.init(gpa, patterns, options);
        errdefer nfa.deinit();

        const alphabet_bytes = nfa.alphabet();
        const state_count = nfa.stateCount();
        const goto = try gpa.alloc(u32, state_count * alphabet_bytes.len);
        for (0..state_count) |state| {
            for (alphabet_bytes, 0..) |byte, class| {
                goto[state * alphabet_bytes.len + class] = nfa.nextState(@intCast(state), byte);
            }
        }

        const tables: DfaTables = .{
            .goto = goto,
            .alphabet = alphabet_bytes,
            .classes = nfa.tables.classes,
            .own_id = nfa.tables.own_id,
            .links = nfa.tables.links,
            .depths = nfa.tables.depths,
            .pattern_lens = nfa.tables.pattern_lens,
            .match_kind = nfa.tables.match_kind,
            .no_id = nfa.tables.no_id,
            .none = nfa.tables.none,
        };
        return .{ .nfa = nfa, .goto = goto, .tables = tables, .gpa = gpa };
    }

    pub fn deinit(self: *Dfa) void {
        self.gpa.free(self.goto);
        self.nfa.deinit();
        self.* = undefined;
    }

    pub fn pattern(self: *const Dfa, id: u32) []const u8 {
        return self.nfa.pattern(id);
    }

    pub fn patternCount(self: *const Dfa) usize {
        return self.nfa.patternCount();
    }

    pub fn patternLen(self: *const Dfa, id: u32) usize {
        return self.tables.patternLen(id);
    }

    pub fn minPatternLen(self: *const Dfa) usize {
        return self.nfa.minPatternLen();
    }

    pub fn maxPatternLen(self: *const Dfa) usize {
        return self.nfa.maxPatternLen();
    }

    pub fn matchKind(self: *const Dfa) MatchKind {
        return self.tables.match_kind;
    }

    pub fn stateCount(self: *const Dfa) usize {
        return self.tables.stateCount();
    }

    pub fn alphabet(self: *const Dfa) []const u8 {
        return self.tables.alphabet;
    }

    pub fn stateDepth(self: *const Dfa, state: State) usize {
        return self.tables.stateDepth(state);
    }

    pub fn stateOutput(self: *const Dfa, state: State) ?u32 {
        const id = self.tables.own_id[state];
        return if (id == self.tables.no_id) null else id;
    }

    pub fn matchesAt(self: *const Dfa, state: State, end: usize) DfaSearch.Matches {
        return DfaSearch.matchesAt(&self.tables, state, end);
    }

    pub fn firstMatch(self: *const Dfa, state: State, end: usize) ?Match {
        return DfaSearch.firstMatch(&self.tables, state, end);
    }

    pub fn find(self: *const Dfa, haystack: []const u8) ?Match {
        return DfaSearch.find(&self.tables, haystack);
    }

    pub fn isMatch(self: *const Dfa, haystack: []const u8) bool {
        return DfaSearch.isMatch(&self.tables, haystack);
    }

    pub fn findIter(self: *const Dfa, haystack: []const u8) DfaSearch.Iterator {
        return DfaSearch.findIter(&self.tables, haystack);
    }

    pub fn findOverlapping(self: *const Dfa, haystack: []const u8) ?Match {
        return DfaSearch.findOverlapping(&self.tables, haystack);
    }

    pub fn findOverlappingIter(
        self: *const Dfa,
        haystack: []const u8,
    ) DfaSearch.OverlappingIterator {
        return DfaSearch.findOverlappingIter(&self.tables, haystack);
    }

    pub fn whichMatches(
        self: *const Dfa,
        gpa: Allocator,
        haystack: []const u8,
    ) !bit_set.RuntimeSet {
        var set: bit_set.RuntimeSet = try .initEmpty(gpa, self.patternCount());
        errdefer set.deinit(gpa);
        var iter = self.findOverlappingIter(haystack);
        while (iter.next()) |m| set.set(m.pattern);
        return set;
    }

    pub fn replaceAll(
        self: *const Dfa,
        writer: anytype,
        haystack: []const u8,
        replacements: []const []const u8,
    ) !void {
        return DfaSearch.replaceAll(&self.tables, writer, haystack, replacements);
    }

    /// The NFA's tables plus the dense transition table.
    pub fn memoryUsage(self: *const Dfa) usize {
        return self.nfa.memoryUsage() + self.goto.len * @sizeOf(u32) + @sizeOf(Dfa);
    }
};

test "runtime finds a pattern and its span" {
    var automaton: Automaton = try .init(testing.allocator, &.{ "apple", "maple" }, .{});
    defer automaton.deinit();

    const m = automaton.find("a maple leaf").?;
    try testing.expectEqual(1, m.pattern);
    try testing.expectEqual(2, m.start);
    try testing.expectEqual(7, m.end);
    try testing.expect(automaton.isMatch("apple"));
    try testing.expect(!automaton.isMatch("banana"));
    try testing.expectEqualStrings("maple", automaton.pattern(1));
}

test "runtime iteration matches the comptime matcher" {
    const patterns = &.{ "append", "appendage", "app" };
    const haystack = "append the app to the appendage";

    const opt: Options = .{ .match_kind = .leftmost_longest };
    const Static = Matcher(patterns, opt);
    var automaton: Automaton = try .init(testing.allocator, patterns, opt);
    defer automaton.deinit();

    var want = Static.findIter(haystack);
    var got = automaton.findIter(haystack);
    while (want.next()) |expected| {
        const actual = got.next().?;
        try testing.expectEqual(expected.pattern, actual.pattern);
        try testing.expectEqual(expected.start, actual.start);
        try testing.expectEqual(expected.end, actual.end);
    }
    try testing.expect(got.next() == null);
}

test "runtime overlapping matches" {
    var automaton: Automaton = try .init(testing.allocator, &.{ "he", "she", "hers" }, .{});
    defer automaton.deinit();

    var iter = automaton.findOverlappingIter("ushers");
    const expected = [_]struct { pattern: u32, start: usize, end: usize }{
        .{ .pattern = 1, .start = 1, .end = 4 },
        .{ .pattern = 0, .start = 2, .end = 4 },
        .{ .pattern = 2, .start = 2, .end = 6 },
    };
    for (expected) |want| {
        const got = iter.next().?;
        try testing.expectEqual(want.pattern, got.pattern);
        try testing.expectEqual(want.start, got.start);
        try testing.expectEqual(want.end, got.end);
    }
    try testing.expect(iter.next() == null);
}

test "runtime rejects the pattern lists the comptime builder rejects" {
    try testing.expectError(error.NoPatterns, Automaton.init(testing.allocator, &.{}, .{}));
    try testing.expectError(error.EmptyPattern, Automaton.init(testing.allocator, &.{""}, .{}));
    try testing.expectError(
        error.DuplicatePattern,
        Automaton.init(testing.allocator, &.{ "she", "she" }, .{}),
    );
    try testing.expectError(
        error.DuplicatePattern,
        Automaton.init(testing.allocator, &.{ "She", "she" }, .{ .ascii_case_insensitive = true }),
    );
}

test "runtime case folding" {
    var automaton: Automaton = try .init(
        testing.allocator,
        &.{"WaRnInG"},
        .{ .ascii_case_insensitive = true },
    );
    defer automaton.deinit();

    const m = automaton.find("a warning sign").?;
    try testing.expectEqual(2, m.start);
    try testing.expectEqual(9, m.end);
}

test "runtime inspection" {
    var automaton: Automaton = try .init(testing.allocator, &.{ "she", "he", "hers" }, .{});
    defer automaton.deinit();

    var state: Automaton.State = 0;
    for ("she") |byte| state = automaton.nextState(state, byte);
    try testing.expectEqual(@as(u32, 0), automaton.stateOutput(state).?);
    try testing.expect(automaton.stateDepth(state) == 3);

    var found_she = false;
    var found_he = false;
    var matches = automaton.matchesAt(state, 3);
    while (matches.next()) |m| {
        if (m.pattern == 0) found_she = true;
        if (m.pattern == 1) found_he = true;
    }
    try testing.expect(found_she and found_he);
}
