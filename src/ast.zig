const std = @import("std");
const Node = @import("node.zig").Node;
const Token = @import("token.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;
const Diagnostic = @import("diagnostic.zig").Diagnostic;

const Allocator = std.mem.Allocator;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);

const TOKEN_RATIO = 8;
const NODE_RATIO = 2;
const STMT_RATIO = 2;

pub const Ast = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: std.MultiArrayList(Token).Slice,
    nodes: std.MultiArrayList(Node).Slice,
    stmts: std.MultiArrayList(Node).Slice,
    errors: std.ArrayList(Diagnostic),

    /// This method deinitialize nodes, stmts, and tokens.
    /// It is best to deinitalize them at the end of semantic analysis.
    pub fn deinit(self: *Ast) void {
        self.nodes.deinit(self.allocator);
        self.stmts.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
    }
};

/// Make sure to deinit() nodes, stmts, and tokens
pub fn parse(allocator: Allocator, buf: []const u8) !Ast {
    var tokens: std.MultiArrayList(Token) = .empty;
    defer tokens.deinit(allocator);

    // TODO: It may not be 8 : 1 ratio. Experiment
    // https://ziggit.dev/t/make-zig-tokenizer-faster-using-only-one-ensuretotalcapacity-malloc/11009/5
    const estimated_token_count = buf.len / TOKEN_RATIO;
    try tokens.ensureTotalCapacity(allocator, estimated_token_count);

    // lines => tokens
    var tokenizer = Tokenizer.init(buf);

    while (true) {
        const token = tokenizer.next();
        // tokens.appendAssumeCapacity(token);
        try tokens.append(allocator, token);
        if (token.tag == .EOF) break;
    }

    return parseFromTokens(allocator, buf, tokens.toOwnedSlice());
}

fn parseFromTokens(allocator: Allocator, buf: []const u8, tokens: Tokens.Slice) !Ast {
    var parser = try Parser.init(allocator, tokens);
    defer parser.deinit();

    // TODO: This is too much memory, find a better ratio.
    // Empirically, there is a 1 : 2 ratio
    // of tokens to nodes.
    const estimated_node_count = tokens.len * NODE_RATIO;

    // Empirically, there is a 2 : 1 ratio
    // of nodes to stmt nodes.
    const estimated_stmt_count = (estimated_node_count + 2) / STMT_RATIO;

    try parser.nodes.ensureTotalCapacity(allocator, estimated_node_count);
    try parser.stmts.ensureTotalCapacity(allocator, estimated_stmt_count);

    // tokens => AST of stmt nodes
    try parser.parseAll();

    // Converting to slice removes all excess memory in nodes and stmts.
    return .{
        .allocator = allocator,
        .source = buf,
        .tokens = tokens,
        .nodes = parser.nodes.toOwnedSlice(),
        .stmts = parser.stmts.toOwnedSlice(),
        .errors = parser.errors
    };
}
