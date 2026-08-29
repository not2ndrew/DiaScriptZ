const std = @import("std");
const zig_node = @import("node.zig");
const tok = @import("token.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;
const diag = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Node = zig_node.Node;
const Nodes = std.MultiArrayList(Node);
const NodeIndex = zig_node.NodeIndex;

const Token = tok.Token;
const Tokens = std.MultiArrayList(Token);
const TokenIndex = tok.TokenIndex;
const TokenTag = tok.Tag;

const SourceFile = diag.SourceFile;
const Error = diag.Error;

pub const Ast = struct {
    source: []const u8,
    allocator: Allocator,
    tokens: std.MultiArrayList(Token).Slice,
    nodes: std.MultiArrayList(Node).Slice,
    // extra_data holds:
    // 1) Variable-length AST payload storage
    // 2) Stores continuous ranges of NodeIndex values referenced by nodes.
    extra_data: []u32,

    pub fn deinit(ast: *Ast) void {
        ast.nodes.deinit(ast.allocator);
        ast.tokens.deinit(ast.allocator);
        ast.allocator.free(ast.extra_data);
    }

    pub fn tokenSlice(ast: *const Ast, token_pos: TokenIndex) []const u8 {
        const token = ast.tokens.get(token_pos);
        return ast.source[token.start..token.end];
    }
};

pub const ParseResult = struct {
    ast: Ast,
    source_file: SourceFile,

    pub fn deinit(p: *ParseResult, allocator: Allocator) void {
        allocator.free(p.source_file.newline_bytes);
        p.ast.deinit();
    }
};

/// Make sure to deinit() nodes, stmts, and tokens
pub fn parse(allocator: Allocator, buf: []const u8, file_name: []const u8) !ParseResult {
    var tokens: Tokens = .empty;
    defer tokens.deinit(allocator);

    // For error diagnostics, we store the byte positions
    // of ALL newline characters.
    // https://www.reddit.com/r/Compilers/comments/1bg5r9m/how_do_you_propagate_line_number_information_for/
    var newline_bytes: std.ArrayList(usize) = .empty;
    defer newline_bytes.deinit(allocator);

    // lines -> tokens
    var tokenizer: Tokenizer = .{
        .allocator = allocator,
        .newline_bytes = &newline_bytes,
        .buffer = buf,
    };

    while (true) {
        const token = try tokenizer.next();
        try tokens.append(allocator, token);

        if (token.tag == .EOF) break;
    }

    const newline_slice = try newline_bytes.toOwnedSlice(allocator);
    var token_slice = tokens.toOwnedSlice();

    errdefer {
        allocator.free(newline_slice);
        token_slice.deinit(allocator);
    }

    const source_file: SourceFile = .{
        .newline_bytes = newline_slice,
        .source = buf,
    };

    return parseFromTokens(allocator, source_file, token_slice, file_name);
}

fn parseFromTokens(allocator: Allocator, source_file: SourceFile, tokens: Tokens.Slice, file_name: []const u8) !ParseResult {
    var parser: Parser = .{
        .allocator = allocator,
        .tokens = tokens,
    };
    errdefer parser.deinit();

    // tokens -> AST
    try parser.parseAll();

    if (parser.errors.items.len > 0) {
        const renderer: diag.DiagRenderer = .{
            .source_file = source_file,
            .tokens = tokens,
        };

        // Diagnostics
        try renderer.printErrors(&parser.errors, allocator, file_name);
        return error.ParseError;
    }

    // Converting to slice removes all excess memory in nodes and stmts.
    // This also means you own the memory. So call deinit on ast when finished.
    const ast: Ast = .{
        .source = source_file.source,
        .allocator = allocator,
        .tokens = tokens,
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = try parser.extra_data.toOwnedSlice(allocator),
    };

    return .{
        .ast = ast,
        .source_file = source_file,
    };
}
