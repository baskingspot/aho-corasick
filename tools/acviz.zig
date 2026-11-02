//! acviz: inspect an Aho-Corasick automaton.
//!
//! Reads a pattern file, builds the runtime automaton, and prints its stats,
//! its trie, Graphviz DOT, or a walk over a haystack.

const std = @import("std");
const cli = @import("cli");
const ac = @import("aho-corasick");
const tui = @import("tui.zig");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const print = std.debug.print;

const Format = enum { tree, dot, stats, walk, matches, tui };

const usage_text =
    \\acviz: inspect an Aho-Corasick automaton.
    \\
    \\usage: acviz <patterns-file> [options]
    \\
    \\  -f, --format <format>    tree, dot, stats, walk, matches, or tui (default: tree)
    \\  -t, --haystack <text>    the text to walk; required by -f walk
    \\  -m, --match-kind <kind>  standard, leftmost-first, or leftmost-longest
    \\  -i, --ignore-case        fold ASCII case
    \\  -p, --patterns <file>    the pattern file, if it is not positional
    \\  -h, --help               this text
    \\
    \\The pattern file has one pattern per line. Blank lines and lines that
    \\start with # are skipped.
    \\
;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var parser = try cli.Args.initAllocator(init.minimal.args, arena);

    var pattern_path: ?[]const u8 = null;
    var format: Format = .tree;
    var haystack: []const u8 = "";
    var kind: ac.MatchKind = .standard;
    var fold = false;
    var help = false;

    while (parser.next()) |token| switch (token) {
        .positional => |value| {
            if (pattern_path != null) fail("more than one pattern file");
            pattern_path = value;
        },
        .option => |opt| {
            if (opt.is("patterns", 'p')) {
                pattern_path = parser.takeValue(opt) orelse fail("-p needs a file");
            } else if (opt.is("format", 'f')) {
                format = parseFormat(parser.takeValue(opt) orelse fail("-f needs a format")) orelse
                    fail("unknown format; use tree, dot, stats, walk, matches, or tui");
            } else if (opt.is("haystack", 't')) {
                haystack = parser.takeValue(opt) orelse fail("-t needs text");
            } else if (opt.is("match-kind", 'm')) {
                kind = parseKind(parser.takeValue(opt) orelse fail("-m needs a kind")) orelse
                    fail("unknown match kind; use standard, leftmost-first, or leftmost-longest");
            } else if (opt.isSwitch("ignore-case", 'i')) {
                fold = true;
            } else if (opt.isSwitch("help", 'h')) {
                help = true;
            } else {
                fail("unknown option");
            }
        },
    };

    var stdout_buffer: [8192]u8 = undefined;
    var stdout: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const writer = &stdout.interface;
    defer writer.flush() catch {};

    if (help) {
        try writer.writeAll(usage_text);
        return;
    }

    const path = pattern_path orelse {
        try writer.writeAll(usage_text);
        return;
    };
    if ((format == .walk or format == .matches) and haystack.len == 0) {
        fail("walk and matches need a haystack: -t <text>");
    }

    const text = Io.Dir.cwd().readFileAlloc(
        init.io,
        path,
        arena,
        .limited(16 * 1024 * 1024),
    ) catch |err| {
        print("acviz: cannot read {s}: {s}\n", .{ path, @errorName(err) });
        std.process.exit(1);
    };
    const patterns = try readPatterns(arena, text);
    if (patterns.len == 0) {
        print("acviz: {s} has no patterns\n", .{path});
        std.process.exit(1);
    }

    var automaton = ac.Automaton.init(init.gpa, patterns, .{
        .match_kind = kind,
        .ascii_case_insensitive = fold,
    }) catch |err| {
        print("acviz: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer automaton.deinit();

    switch (format) {
        .stats => try writeStats(writer, &automaton, path),
        .tree => try writeTree(writer, &automaton),
        .dot => try writeDot(writer, &automaton),
        .walk => try writeWalk(writer, &automaton, haystack),
        .matches => try writeMatches(writer, &automaton, haystack),
        .tui => try tui.run(init, &automaton, if (haystack.len != 0) haystack else null),
    }
}

fn fail(comptime message: []const u8) noreturn {
    print("acviz: {s}\n", .{message});
    std.process.exit(2);
}

fn parseFormat(raw: []const u8) ?Format {
    if (std.mem.eql(u8, raw, "tree")) return .tree;
    if (std.mem.eql(u8, raw, "dot")) return .dot;
    if (std.mem.eql(u8, raw, "stats")) return .stats;
    if (std.mem.eql(u8, raw, "walk")) return .walk;
    if (std.mem.eql(u8, raw, "matches")) return .matches;
    if (std.mem.eql(u8, raw, "tui")) return .tui;
    return null;
}

fn kindName(kind: ac.MatchKind) []const u8 {
    return switch (kind) {
        .standard => "standard",
        .leftmost_first => "leftmost-first",
        .leftmost_longest => "leftmost-longest",
    };
}

fn parseKind(raw: []const u8) ?ac.MatchKind {
    if (std.mem.eql(u8, raw, "standard")) return .standard;
    if (std.mem.eql(u8, raw, "leftmost-first")) return .leftmost_first;
    if (std.mem.eql(u8, raw, "leftmost-longest")) return .leftmost_longest;
    return null;
}

fn readPatterns(arena: Allocator, text: []const u8) ![]const []const u8 {
    var patterns: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;
        try patterns.append(arena, trimmed);
    }
    return patterns.toOwnedSlice(arena);
}

fn writeStats(w: *Io.Writer, automaton: *const ac.Automaton, source: []const u8) !void {
    var bytes: usize = 0;
    for (0..automaton.patternCount()) |id| bytes += automaton.patternLen(@intCast(id));
    const memory = automaton.memoryUsage();
    const states = @max(automaton.stateCount(), 1);

    try w.print("patterns: {d} from {s}\n", .{ automaton.patternCount(), source });
    try w.print("pattern bytes: {d}, lengths {d}..{d}\n", .{
        bytes,
        automaton.minPatternLen(),
        automaton.maxPatternLen(),
    });
    try w.print("states: {d}, transitions: {d}\n", .{
        automaton.stateCount(),
        automaton.transitionCount(),
    });
    try w.print("memory: {d} bytes ({d} per state)\n", .{ memory, memory / states });
    try w.print("alphabet: {d} distinct bytes\n", .{automaton.alphabet().len});
    try w.print("match kind: {s}\n", .{kindName(automaton.matchKind())});
}

fn writeTree(w: *Io.Writer, automaton: *const ac.Automaton) !void {
    try writeNode(w, automaton, 0, 0, null);
}

fn writeNode(
    w: *Io.Writer,
    automaton: *const ac.Automaton,
    state: ac.Automaton.State,
    depth: usize,
    incoming: ?u8,
) !void {
    try writeIndent(w, depth);
    if (incoming) |byte| {
        try writeChar(w, byte);
        try w.writeAll(" -> ");
    }
    try w.print("[{d}]", .{state});
    if (automaton.stateOutput(state)) |id| {
        try w.writeAll("  output=\"");
        try writeEscaped(w, automaton.pattern(id));
        try w.print("\" (id {d})", .{id});
    }
    if (state != 0) try w.print("  fail={d}", .{automaton.stateFailure(state)});
    try w.writeAll("\n");

    var transitions = automaton.transitions(state);
    while (transitions.next()) |transition| {
        try writeNode(w, automaton, transition.state, depth + 1, transition.byte);
    }
}

fn writeDot(w: *Io.Writer, automaton: *const ac.Automaton) !void {
    try w.writeAll("digraph aho_corasick {\n");
    try w.writeAll("  rankdir=LR;\n");
    try w.writeAll("  node [shape=circle, fontname=\"monospace\"];\n");

    for (0..automaton.stateCount()) |index| {
        const state: ac.Automaton.State = @intCast(index);
        if (automaton.stateOutput(state)) |id| {
            try w.print("  {d} [shape=doublecircle, label=\"", .{state});
            try writeEscaped(w, automaton.pattern(id));
            try w.writeAll("\"];\n");
        } else {
            try w.print("  {d};\n", .{state});
        }
    }

    for (0..automaton.stateCount()) |index| {
        const state: ac.Automaton.State = @intCast(index);
        var transitions = automaton.transitions(state);
        while (transitions.next()) |transition| {
            try w.print("  {d} -> {d} [label=\"", .{ state, transition.state });
            try writeEscaped(w, &[_]u8{transition.byte});
            try w.writeAll("\"];\n");
        }
        if (state != 0) {
            try w.print("  {d} -> {d} [style=dashed, color=\"#999999\", label=\"fail\"];\n", .{
                state,
                automaton.stateFailure(state),
            });
        }
    }
    try w.writeAll("}\n");
}

fn writeWalk(w: *Io.Writer, automaton: *const ac.Automaton, haystack: []const u8) !void {
    try w.writeAll("haystack: \"");
    try writeEscaped(w, haystack);
    try w.writeAll("\"\n");
    try w.writeAll("    0  start  state 0\n");

    var state: ac.Automaton.State = 0;
    var pos: usize = 0;
    for (haystack) |byte| {
        state = automaton.nextState(state, byte);
        pos += 1;
        try w.print("  {d:>3}  ", .{pos});
        try writeChar(w, byte);
        try w.print("  state {d}", .{state});
        if (automaton.stateOutput(state)) |id| {
            try w.writeAll("  own=\"");
            try writeEscaped(w, automaton.pattern(id));
            try w.writeAll("\"");
        }
        try w.writeAll("\n");

        var matches = automaton.matchesAt(state, pos);
        while (matches.next()) |m| {
            try w.writeAll("        match \"");
            try writeEscaped(w, automaton.pattern(m.pattern));
            try w.print("\" at {d}..{d}\n", .{ m.start, m.end });
        }
    }
}

fn writeMatches(w: *Io.Writer, automaton: *const ac.Automaton, haystack: []const u8) !void {
    try w.writeAll("haystack: \"");
    try writeEscaped(w, haystack);
    try w.print("\"\nkind: {s}\n", .{kindName(automaton.matchKind())});

    var iter = automaton.findIter(haystack);
    var count: usize = 0;
    while (iter.next()) |m| {
        count += 1;
        try w.print("  {d}: \"", .{count});
        try writeEscaped(w, automaton.pattern(m.pattern));
        try w.print("\" at {d}..{d}\n", .{ m.start, m.end });
    }
    if (count == 0) try w.writeAll("  no matches\n");
}

fn writeIndent(w: *Io.Writer, depth: usize) !void {
    var i: usize = 0;
    while (i < depth) : (i += 1) try w.writeAll("  ");
}

fn writeChar(w: *Io.Writer, byte: u8) !void {
    if (std.ascii.isPrint(byte)) {
        try w.print("'{c}'", .{byte});
    } else {
        try w.print("0x{X:0>2}", .{byte});
    }
}

fn writeEscaped(w: *Io.Writer, bytes: []const u8) !void {
    for (bytes) |byte| {
        if (byte == '"' or byte == '\\') {
            try w.print("\\{c}", .{byte});
        } else if (std.ascii.isPrint(byte)) {
            try w.writeAll(&[_]u8{byte});
        } else {
            try w.print("\\x{X:0>2}", .{byte});
        }
    }
}
