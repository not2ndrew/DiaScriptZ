const std = @import("std");
const frontend = @import("frontend");
const Parser = @import("parser.zig").Parser;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Tokenizer = frontend.Tokenizer;
const Token = frontend.token.Token;
const TokenIndex = frontend.token.TokenIndex;
const lexeme = frontend.token.lexeme;

const Tokens = std.MultiArrayList(Token);

const Node = frontend.node.Node;
const Nodes = std.MultiArrayList(Node);
const NodeIndex = frontend.node.NodeIndex;

pub const Error = struct {
    token_pos: TokenIndex,
    tag: Tag,
    data: Data = .{ .none = {} },

    pub const Tag = enum {
        // Parsing Errors
        unexpected_EOF,
        expected_token,
        expected_ident,
        expected_expr,
        expected_arith_op,
        expected_compar_op,
        expected_dialogue,
    };

    pub const Data = union {
        none: void,
        expected: Token.Tag,
    };
};

pub const Ast = @This();

source: []const u8,
allocator: Allocator,
tokens: Tokens.Slice,
nodes: Nodes.Slice,
// extra_data holds:
// 1) Variable-length AST payload storage
// 2) Stores continuous ranges of NodeIndex values referenced by nodes.
extra_data: []u32,

pub fn deinit(ast: *Ast) void {
    ast.nodes.deinit(ast.allocator);
    ast.tokens.deinit(ast.allocator);
    ast.allocator.free(ast.extra_data);
}

fn tokenSlice(ast: Ast, token_pos: TokenIndex) []const u8 {
    const token = ast.tokens.get(token_pos);
    if (lexeme(token.tag)) |slice| {
        return slice;
    }

    return ast.source[token.start .. token.end];
}

pub const ParseResult = struct {
    ast: Ast,
    errors: []Error,

    pub fn deinit(p: *ParseResult, allocator: Allocator) void {
        allocator.free(p.errors);
        p.ast.deinit();
    }
};

/// Make sure to deinit() nodes, stmts, and tokens
pub fn parse(allocator: Allocator, buf: []const u8) !ParseResult {
    var tokens: Tokens = .empty;
    defer tokens.deinit(allocator);

    // lines -> tokens
    var tokenizer: Tokenizer = .{
        .allocator = allocator,
        .buffer = buf,
    };

    while (true) {
        const token = try tokenizer.next();
        try tokens.append(allocator, token);

        if (token.tag == .EOF) break;
    }

    var token_slice = tokens.toOwnedSlice();

    errdefer token_slice.deinit(allocator);

    return parseFromTokens(allocator, buf, token_slice);
}

fn parseFromTokens(allocator: Allocator, source: []const u8, tokens: Tokens.Slice) !ParseResult {
    var parser: Parser = .{
        .allocator = allocator,
        .tokens = tokens,
    };
    errdefer parser.deinit();

    // tokens -> AST
    try parser.parseAll();

    // Converting to slice removes all excess memory in nodes and stmts.
    // This also means you own the memory. So call deinit on ast when finished.
    const ast: Ast = .{
        .source = source,
        .allocator = allocator,
        .tokens = tokens,
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = try parser.extra_data.toOwnedSlice(allocator),
    };

    return .{
        .ast = ast,
        .errors = try parser.errors.toOwnedSlice(allocator),
    };
}

// DIAGNOSTICS
pub fn errorMessage(ast: Ast, w: *std.Io.Writer, err: Error) std.Io.Writer.Error!void {
    const found = ast.tokenSlice(err.token_pos);

    switch (err.tag) {
        // Parsing Errors
        .unexpected_EOF => {
            return w.writeAll("Expected expression, found EOF");
        },
        .expected_token => {
            const expected_token = ast.tokens.get(err.token_pos);
            const expected = lexeme(err.data.expected)
                orelse ast.source[expected_token.start .. expected_token.end];
            return w.print("Expected '{s}', found '{s}'", .{expected, found});
        },
        .expected_ident => {
            return w.print("Expected identifier, found '{s}'", .{found});
        },
        .expected_expr => {
            return w.writeAll("Expected number or identifier");
        },
        .expected_arith_op => {
            return w.print("Expected arithmetic operator, found '{s}'", .{found});
        },
        .expected_compar_op => {
            return w.print("Expected comparison operator, found '{s}'", .{found});
        },
        .expected_dialogue => {
            return w.print("Expected dialogue, found '{s}'", .{found});
        },
    }
}
