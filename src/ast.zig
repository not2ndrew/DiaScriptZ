const std = @import("std");
const Node = @import("node.zig").Node;
const Token = @import("token.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;
const Diagnostic = @import("diagnostic.zig").Diagnostic;

const Allocator = std.mem.Allocator;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);

const NodeIndex = u32;

pub const Ast = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: std.MultiArrayList(Token).Slice,
    nodes: std.MultiArrayList(Node).Slice,
    errors: std.ArrayList(Diagnostic),

    /// This method deinitialize nodes, stmts, and tokens.
    /// It is best to deinitalize them at the end of semantic analysis.
    pub fn deinit(self: *Ast) void {
        self.nodes.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
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
    defer parser.deinit();

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
