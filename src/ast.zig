const std = @import("std");
const zig_node = @import("node.zig");
const tok = @import("token.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const Nodes = std.MultiArrayList(Node);
const NodeIndex = zig_node.NodeIndex;

const Token = tok.Token;
const Tokens = std.MultiArrayList(Token);
const TokenIndex = tok.TokenIndex;
const TokenTag = tok.Tag;

pub const Error = struct {
    token_pos: TokenIndex,
    tag: Tag,
    extra: Extra = .{ .none = {} },

    pub const Tag = enum {
        expected_expr,
        expected_arith_op,
        expected_compar_op,
        expected_dialogue,
    };

    pub const Extra = union {
        none: void,
        expected_tag: TokenTag,
    };
};

pub const Ast = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: std.MultiArrayList(Token).Slice,
    nodes: std.MultiArrayList(Node).Slice,
    errors: std.ArrayList(Error),

    /// It is best to deinitalize at the end of semantic analysis.
    pub fn deinit(self: *Ast) void {
        for (0..self.nodes.len) |i| {
            const node = self.nodes.get(i);
            switch (node.tag) {
                .block => self.allocator.free(node.data.block),
                else => {},
            }
        }

        self.nodes.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    pub fn printErrors(self: *Ast, file_name: []const u8) void {
        for (self.errors.items) |err| {
            const token = self.tokens.get(err.token_pos);
            const msg = errorMessage(err.tag);
            const pos = getLineCol(self.source, token.start);
            const line_slice = getLineSlice(self.source, token.start);

            std.debug.print(
                \\{s}:{d}:{d} error: {s}
                \\     |
                \\{d:4}| {s}
                ,
                .{ file_name, pos.line, pos.col, msg, pos.col, line_slice }
            );

            printError(err, pos.col, token.tag);
        }
    }
};

/// Make sure to deinit() nodes, stmts, and tokens
pub fn parse(allocator: Allocator, buf: []const u8) !Ast {
    var tokens: Tokens = .empty;
    defer tokens.deinit(allocator);

    // lines => tokens
    var tokenizer = Tokenizer.init(buf);

    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .EOF) break;
    }

    return parseFromTokens(allocator, buf, tokens.toOwnedSlice());
}

fn parseFromTokens(allocator: Allocator, buf: []const u8, tokens: Tokens.Slice) !Ast {
    var parser = try Parser.init(allocator, tokens);

    // tokens => AST of stmt nodes
    try parser.parseAll();

    // Converting to slice removes all excess memory in nodes and stmts.
    return .{
        .allocator = allocator,
        .source = buf,
        .tokens = tokens,
        .nodes = parser.nodes.toOwnedSlice(),
        .errors = parser.errors
    };
}

// TODO: Search for every '\n' during init.
// Get an array of '\n' from tokenizer.
// Then binary search line num,
// then compute column = byte_pos - line num
//
// The reason is there are x * y total bytes to scan
// where x is col and y is line
//
// We can trade an array of 8 bytes for performance.
fn getLineCol(source: []const u8, byte_pos: usize) struct { line: usize, col: usize } {
    var line: usize = 1;
    var col: usize = 1;

    var i: usize = 0;
    while (i < byte_pos and i < source.len) {
        if (source[i] == '\n') {
            line += 1;
            col = 1;
        } else {
            col += 1;
        }

        i += 1;
    }

    return .{ .line = line, .col = col };
}

fn getLineSlice(source: []const u8, byte_pos: usize) []const u8 {
    var pos = byte_pos;

    if (pos >= source.len and source.len > 0) {
        pos = source.len - 1;
    }

    var start = pos;
    var end = pos;

    while (start > 0 and source[start - 1] != '\n') {
        start -= 1;
    }

    while (end < source.len and source[end] != '\n') {
        end += 1;
    }

    return source[start..end];
}

fn errorMessage(tag: Error.Tag) []const u8 {
    return switch(tag) {
        .expected_expr => "Expected expression",
        .expected_arith_op => "Expected Arithmetic Operator",
        .expected_compar_op => "Expected Comparison Operator",
        .expected_dialogue => "Expected Dialogue",
    };
}

// TODO: Convert token tags to actual strings.
fn printError(err: Error, col: usize, tag: TokenTag) void {
    // Assume some amount of memory
    var buf: [100]u8 = undefined;
    const spaces = buf[0..@min(col, buf.len)];
    @memset(spaces, ' ');

    switch (err.tag) {
        .expected_expr => {
            std.debug.print(
                "{s}\n --> Expected {t}, Found {t}\n\n",
                .{ spaces, err.extra.expected_tag, tag }
            );
        },
        .expected_arith_op => {
            std.debug.print(
                "{s}\n --> Expected arithmetic operator, found {t}\n\n",
                .{ spaces, tag }
            );
        },
        .expected_compar_op => {
            std.debug.print(
                "{s}\n --> Expected comparison operator, found {t}\n\n",
                .{ spaces, tag }
            );
        },
        .expected_dialogue => {
            std.debug.print(
                "{s}\n --> Dialogue is empty\n\n",
                .{ spaces }
            );
        },
    }
}
