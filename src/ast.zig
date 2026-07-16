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
    allocator: Allocator,
    tokens: std.MultiArrayList(Token).Slice,
    nodes: std.MultiArrayList(Node).Slice,
    // extra_data holds:
    // 1) Variable-length AST payload storage
    // 2) Stores continuous ranges of NodeIndex values referenced by nodes.
    extra_data: []u32,

    pub fn deinit(self: *Ast) void {
        self.nodes.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
        self.allocator.free(self.extra_data);
    }
};

pub const ParseResult = struct {
    ast: Ast,
    source_file: SourceFile,
    errors: std.ArrayList(Error),

    pub fn deinit(self: *ParseResult, allocator: Allocator) void {
        allocator.free(self.source_file.line_starts);
        self.ast.deinit();
    }
};

/// Make sure to deinit() nodes, stmts, and tokens
pub fn parse(allocator: Allocator, buf: []const u8) !ParseResult {
    var tokens: Tokens = .empty;

    var line_starts: std.ArrayList(usize) = .empty;
    defer line_starts.deinit(allocator);

    // line starts at index 0.
    try line_starts.append(allocator, 0);

    // lines -> tokens
    var tokenizer = Tokenizer.init(buf);

    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);

        if (token.tag == .newline)
            try line_starts.append(allocator, tokenizer.index);

        if (token.tag == .EOF) break;
    }

    const source_file: SourceFile = .{
        .line_starts = try line_starts.toOwnedSlice(allocator),
        .source = buf,
    };

    return parseFromTokens(allocator, source_file, tokens.toOwnedSlice());
}

fn parseFromTokens(allocator: Allocator, source_file: SourceFile, tokens: Tokens.Slice) !ParseResult {
    var parser = try Parser.init(allocator, tokens);

    // tokens -> AST
    try parser.parseAll();

    // Converting to slice removes all excess memory in nodes and stmts.
    // This also means you own the memory. So call deinit on ast when finished.
    const ast: Ast = .{
        .allocator = allocator,
        .tokens = tokens,
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = try parser.extra_data.toOwnedSlice(allocator),
    };

    return .{
        .ast = ast,
        .source_file = source_file,
        .errors = parser.errors,
    };
}
