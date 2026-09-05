const std = @import("std");
const tok = @import("token.zig");
const nod = @import("node.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;

const SourceFile = @import("source_file.zig").SourceFile;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Token = tok.Token;
const TokenIndex = tok.TokenIndex;

const Tokens = std.MultiArrayList(Token);

const Node = nod.Node;
const Nodes = std.MultiArrayList(Node);
const NodeIndex = nod.NodeIndex;

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

// source: []const u8,
allocator: Allocator,
// tokens: Tokens.Slice,
source_file: SourceFile,
nodes: Nodes.Slice,
// extra_data holds:
// 1) Variable-length AST payload storage
// 2) Stores continuous ranges of NodeIndex values referenced by nodes.
extra_data: []u32,

pub fn deinit(ast: *Ast) void {
    ast.nodes.deinit(ast.allocator);
    ast.source_file.tokens.deinit(ast.allocator);
    ast.allocator.free(ast.extra_data);
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
        .source_file = .{
            .source = source,
            .tokens = tokens,
        },
        .allocator = allocator,
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = try parser.extra_data.toOwnedSlice(allocator),
    };

    return .{
        .ast = ast,
        .errors = try parser.errors.toOwnedSlice(allocator),
    };
}
