const std = @import("std");
const Node = @import("node.zig").Node;
const tok = @import("token.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;

const Allocator = std.mem.Allocator;

const Nodes = std.MultiArrayList(Node);
const NodeIndex = u32;

const Token = tok.Token;
const Tokens = std.MultiArrayList(Token);
const TokenIndex = tok.TokenIndex;
const TokenTag = tok.Tag;

pub const Ast = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: std.MultiArrayList(Token).Slice,
    nodes: std.MultiArrayList(Node).Slice,
    errors: std.ArrayList(Error),

    pub const Error = struct {
        start: TokenIndex,
        end: TokenIndex,
        tag: Tag,
        extra: Extra = .{ .none = {} },

        pub const Tag = enum {
            expected_expr,

            // Operators
            expected_arith_op,
            expected_compar_op,

            expected_dialogue,
        };

        pub const Extra = union {
            none: void,
            expected_tag: TokenTag,
            offset: usize,
        };
    };

    /// It is best to deinitalize at the end of semantic analysis.
    pub fn deinit(self: *Ast) void {
        for (0..self.nodes.len) |i| {
            const node = self.nodes.get(i);
            switch (node.data) {
                .block => self.allocator.free(node.data.block),
                else => {},
            }
        }

        self.nodes.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
        self.errors.deinit(self.allocator);
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

    pub fn printErrors(self: *Ast, file_name: []const u8) void {
        for (self.errors.items) |err| {
            const msg = errorMessage(err.tag);
            const pos = getLineCol(self.source, err.start);
            const line_slice = getLineSlice(self.source, err.start);

            std.debug.print(
                \\{s}:{d}:{d} error: {s}
                \\     |
                \\{d:4} | {s}
                ,
                .{ file_name, pos.line, pos.col, msg, pos.line, line_slice }
            );

            // Assume some amount of memory
            var buf: [100]u8 = undefined;
            const spaces = buf[0..@min(pos.col, buf.len)];
            @memset(spaces, ' ');

            switch (err.tag) {
                .expected_expr => {
                    std.debug.print(
                        "{s}\n --> Expected {t}, Found {t}\n\n",
                        .{ spaces, err.extra.expected_tag, err.tag }
                    );
                },
                .expected_arith_op => {
                    std.debug.print(
                        "{s}\n --> Expected Arithmetic Operator\n\n",
                        .{ spaces }
                    );
                },
                .expected_compar_op => {
                    std.debug.print(
                        "{s}\n --> Expected Comparison Operator\n\n",
                        .{ spaces }
                    );
                },
                .expected_dialogue => {
                    std.debug.print(
                        "{s}\n --> Expected Dialogue Line\n\n",
                        .{ spaces }
                    );
                },
            }
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
