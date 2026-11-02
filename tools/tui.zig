//! The libvaxis view for acviz: browse the trie and step through a haystack.

const std = @import("std");
const vaxis = @import("vaxis");
const ac = @import("aho-corasick");

const Cell = vaxis.Cell;
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
};

const Row = struct {
    state: ac.Automaton.State,
    parent: ?usize,
    incoming: ?u8,
    depth: usize,
    text: []const u8,
};

const App = struct {
    automaton: *const ac.Automaton,
    rows: []const Row,
    state_row: []const usize,
    selected: usize = 0,
    offset: usize = 0,
    body_height: usize = 0,
    haystack: ?[]const u8,
    pos: usize = 0,
    walk_state: ac.Automaton.State = 0,
    follow: bool = true,
    header: [256]u8 = undefined,
    details: [512]u8 = undefined,
    walk: [512]u8 = undefined,
    matches: [512]u8 = undefined,

    fn move(self: *App, delta: isize) void {
        if (self.rows.len == 0) return;
        if (delta < 0) {
            self.selected -|= @intCast(-delta);
        } else {
            self.selected = @min(self.selected + @as(usize, @intCast(delta)), self.rows.len - 1);
        }
    }

    fn selectState(self: *App, state: ac.Automaton.State) void {
        self.selected = self.state_row[state];
    }

    fn advance(self: *App) void {
        const haystack = self.haystack orelse return;
        if (self.pos >= haystack.len) return;
        self.walk_state = self.automaton.nextState(self.walk_state, haystack[self.pos]);
        self.pos += 1;
        if (self.follow) self.selectState(self.walk_state);
    }

    fn reset(self: *App) void {
        self.pos = 0;
        self.walk_state = 0;
        if (self.follow) self.selectState(0);
    }

    fn clampOffset(self: *App) void {
        if (self.body_height == 0) return;
        if (self.selected < self.offset) self.offset = self.selected;
        if (self.selected >= self.offset + self.body_height) {
            self.offset = self.selected + 1 - self.body_height;
        }
        if (self.rows.len > self.body_height) {
            self.offset = @min(self.offset, self.rows.len - self.body_height);
        } else {
            self.offset = 0;
        }
    }

    fn draw(self: *App, win: vaxis.Window) void {
        win.clear();
        const height: usize = win.height;
        if (height < 4) return;

        const header = std.fmt.bufPrint(
            &self.header,
            "acviz  {d} patterns  {d} states  {d} transitions  {d} B  {s}",
            .{
                self.automaton.patternCount(),
                self.automaton.stateCount(),
                self.automaton.transitionCount(),
                self.automaton.memoryUsage(),
                kindName(self.automaton.matchKind()),
            },
        ) catch self.header[0..0];
        _ = win.printSegment(
            .{ .text = header, .style = .{ .bold = true } },
            .{ .row_offset = 0, .col_offset = 0, .wrap = .none },
        );

        self.drawDetails(win);

        const walk_lines: usize = if (self.haystack != null) 2 else 0;
        const body_top: usize = 3;
        const body_bottom = height - 1 - walk_lines;
        self.body_height = if (body_bottom > body_top) body_bottom - body_top else 0;
        self.clampOffset();
        self.drawRows(win, body_top);

        if (self.haystack) |haystack| {
            self.drawWalk(win, height, haystack);
        }

        const controls = if (self.haystack != null)
            "q quit  j/k move  space step  r reset  f follow"
        else
            "q quit  j/k move  (-t <text> steps a haystack)";
        _ = win.printSegment(
            .{ .text = controls, .style = .{ .dim = true } },
            .{ .row_offset = @intCast(height - 1), .col_offset = 0, .wrap = .none },
        );
    }

    fn drawDetails(self: *App, win: vaxis.Window) void {
        if (self.rows.len == 0) return;
        const row = self.rows[self.selected];

        var writer: Io.Writer = .fixed(&self.details);
        writer.print("[{d}] depth {d}", .{ row.state, row.depth }) catch return;
        if (row.state != 0) {
            writer.print("  fail {d}", .{self.automaton.stateFailure(row.state)}) catch return;
        }
        if (self.automaton.stateOutput(row.state)) |id| {
            writer.writeAll("  output \"") catch return;
            writeEscaped(&writer, self.automaton.pattern(id)) catch return;
            writer.print("\" ({d})", .{id}) catch return;
        }
        var path_buffer: [128]u8 = undefined;
        const path = self.pathOf(self.selected, &path_buffer);
        writer.writeAll("  path \"") catch return;
        writeEscaped(&writer, path) catch return;
        writer.writeAll("\"") catch return;

        _ = win.printSegment(
            .{ .text = writer.buffered() },
            .{ .row_offset = 1, .col_offset = 0, .wrap = .none },
        );
    }

    fn drawRows(self: *App, win: vaxis.Window, top: usize) void {
        var i: usize = 0;
        while (i < self.body_height) : (i += 1) {
            const index = self.offset + i;
            if (index >= self.rows.len) break;
            const row = self.rows[index];

            const style: Cell.Style = if (index == self.selected)
                .{ .reverse = true }
            else if (self.haystack != null and row.state == self.walk_state)
                .{ .fg = .{ .index = 3 }, .bold = true }
            else if (self.automaton.stateOutput(row.state) != null)
                .{ .fg = .{ .index = 2 } }
            else
                .{};

            _ = win.printSegment(
                .{ .text = row.text, .style = style },
                .{
                    .row_offset = @intCast(top + i),
                    .col_offset = 0,
                    .wrap = .none,
                },
            );
        }
    }

    fn drawWalk(self: *App, win: vaxis.Window, height: usize, haystack: []const u8) void {
        var writer: Io.Writer = .fixed(&self.walk);
        writer.writeAll("walk \"") catch return;
        writeEscaped(&writer, haystack) catch return;
        writer.print("\"  pos {d}/{d}  state {d}", .{
            self.pos,
            haystack.len,
            self.walk_state,
        }) catch return;
        _ = win.printSegment(
            .{ .text = writer.buffered(), .style = .{ .fg = .{ .index = 3 } } },
            .{ .row_offset = @intCast(height - 2), .col_offset = 0, .wrap = .none },
        );

        var match_line: [512]u8 = undefined;
        var match_writer: Io.Writer = .fixed(&match_line);
        match_writer.writeAll("matches:") catch return;
        var matches = self.automaton.matchesAt(self.walk_state, self.pos);
        var count: usize = 0;
        while (matches.next()) |m| {
            count += 1;
            match_writer.writeAll(" \"") catch return;
            writeEscaped(&match_writer, self.automaton.pattern(m.pattern)) catch return;
            match_writer.print("\" {d}..{d}", .{ m.start, m.end }) catch return;
        }
        if (count == 0) match_writer.writeAll(" none") catch return;
        _ = win.printSegment(
            .{ .text = match_writer.buffered() },
            .{ .row_offset = @intCast(height - 3), .col_offset = 0, .wrap = .none },
        );
    }

    fn pathOf(self: *App, index: usize, buffer: []u8) []const u8 {
        var length: usize = 0;
        var cursor = index;
        while (self.rows[cursor].parent) |parent| {
            if (length == buffer.len) break;
            buffer[length] = self.rows[cursor].incoming.?;
            length += 1;
            cursor = parent;
        }
        std.mem.reverse(u8, buffer[0..length]);
        return buffer[0..length];
    }
};

pub fn run(init: std.process.Init, automaton: *const ac.Automaton, haystack: ?[]const u8) !void {
    const allocator = init.arena.allocator();
    const state_row = try allocator.alloc(usize, automaton.stateCount());
    @memset(state_row, 0);
    const rows = try buildRows(allocator, automaton, state_row);

    var app: App = .{
        .automaton = automaton,
        .rows = rows,
        .state_row = state_row,
        .haystack = haystack,
    };
    if (haystack != null) app.selectState(0);

    var buffer: [1024]u8 = undefined;
    var tty: vaxis.Tty = try .init(init.io, &buffer);
    defer tty.deinit();
    const writer = tty.writer();

    var vx = try vaxis.init(init.io, init.gpa, init.environ_map, .{});
    defer vx.deinit(init.gpa, writer);
    var loop: vaxis.Loop(Event) = .init(init.io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(writer);
    try writer.flush();
    try vx.queryTerminal(writer, .fromSeconds(1));

    while (true) {
        const event = try loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                if (key.matches('q', .{}) or key.matches('c', .{ .ctrl = true })) break;
                if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) app.move(-1);
                if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) app.move(1);
                if (key.matches(' ', .{}) or key.matches(vaxis.Key.right, .{})) app.advance();
                if (key.matches('r', .{})) app.reset();
                if (key.matches('f', .{})) app.follow = !app.follow;
            },
            .winsize => |winsize| try vx.resize(init.gpa, writer, winsize),
        }
        app.draw(vx.window());
        try vx.render(writer);
        try writer.flush();
    }
}

fn buildRows(
    allocator: Allocator,
    automaton: *const ac.Automaton,
    state_row: []usize,
) ![]Row {
    var rows: std.ArrayList(Row) = .empty;
    try appendRows(allocator, automaton, state_row, &rows, 0, null, null, 0);
    return rows.toOwnedSlice(allocator);
}

fn appendRows(
    allocator: Allocator,
    automaton: *const ac.Automaton,
    state_row: []usize,
    rows: *std.ArrayList(Row),
    state: ac.Automaton.State,
    parent: ?usize,
    incoming: ?u8,
    depth: usize,
) !void {
    const index = rows.items.len;
    try rows.append(allocator, .{
        .state = state,
        .parent = parent,
        .incoming = incoming,
        .depth = depth,
        .text = try formatRow(allocator, automaton, state, incoming, depth),
    });
    state_row[state] = index;

    var transitions = automaton.transitions(state);
    while (transitions.next()) |transition| {
        try appendRows(
            allocator,
            automaton,
            state_row,
            rows,
            transition.state,
            index,
            transition.byte,
            depth + 1,
        );
    }
}

fn formatRow(
    allocator: Allocator,
    automaton: *const ac.Automaton,
    state: ac.Automaton.State,
    incoming: ?u8,
    depth: usize,
) ![]const u8 {
    var out: Io.Writer.Allocating = .init(allocator);
    const writer = &out.writer;
    for (0..depth) |_| try writer.writeAll("  ");
    if (incoming) |byte| {
        if (std.ascii.isPrint(byte)) {
            try writer.print("'{c}' -> ", .{byte});
        } else {
            try writer.print("0x{X:0>2} -> ", .{byte});
        }
    } else {
        try writer.writeAll("root ");
    }
    try writer.print("[{d}]", .{state});
    if (automaton.stateOutput(state)) |id| {
        try writer.writeAll("  output=\"");
        try writeEscaped(writer, automaton.pattern(id));
        try writer.print("\" ({d})", .{id});
    }
    if (state != 0) try writer.print("  fail={d}", .{automaton.stateFailure(state)});
    return out.written();
}

fn kindName(kind: ac.MatchKind) []const u8 {
    return switch (kind) {
        .standard => "standard",
        .leftmost_first => "leftmost-first",
        .leftmost_longest => "leftmost-longest",
    };
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
