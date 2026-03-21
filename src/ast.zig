const std = @import("std");
const Node = @import("node.zig").Node;
const Token = @import("token.zig").Token;
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Sink = @import("diagnostic.zig").DiagnosticSink;
const Parser = @import("parser.zig").Parser;

const Allocator = std.mem.Allocator;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);

// TODO: Add an errors list
pub const Ast = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: std.MultiArrayList(Token).Slice,
    nodes: std.MultiArrayList(Node).Slice,
    stmts: std.MultiArrayList(Node).Slice,
};

/// Make sure to deinit() nodes, stmts
pub fn tokenize(allocator: Allocator, buf: []const u8) !Ast {
    var tokens: std.MultiArrayList(Token) = .empty;
    defer tokens.deinit(allocator);

    // Empirically, there is a 8 : 1 ratio
    // of source bytes to tokens.
    // TODO: It may not be 8 : 1 ratio. Experiment
    // https://ziggit.dev/t/make-zig-tokenizer-faster-using-only-one-ensuretotalcapacity-malloc/11009/5
    const estimated_token_count = buf.len / 8;
    try tokens.ensureTotalCapacity(allocator, estimated_token_count);

    // lines => tokens
    var tokenizer = Tokenizer.init(buf);

    while (true) {
        const token = tokenizer.next();
        // tokens.appendAssumeCapacity(token);
        try tokens.append(allocator, token);
        if (token.tag == .EOF) break;
    }

    var tokens_slice = tokens.toOwnedSlice();
    defer tokens_slice.deinit(allocator);

    return parseTokens(allocator, buf, tokens_slice);
}

fn parseTokens(allocator: Allocator, buf: []const u8, tokens: Tokens.Slice) !Ast {
    var parser = try Parser.init(allocator, tokens);
    defer parser.deinit();

    // TODO: This is too much memory, find a better ratio.
    // Empirically, there is a 1 : 2 ratio
    // of tokens to nodes.
    const estimated_node_count = tokens.len * 2;
    std.debug.print("Node Count: {d}\n", .{estimated_node_count});

    // Empirically, there is a 2 : 1 ratio
    // of nodes to stmt nodes.
    const estimated_stmt_count = (estimated_node_count + 2) / 2;

    try parser.nodes.ensureTotalCapacity(allocator, estimated_node_count);
    try parser.stmts.ensureTotalCapacity(allocator, estimated_stmt_count);

    // tokens => AST of stmt nodes
    try parser.parse();

    return .{
        .allocator = allocator,
        .source = buf,
        .tokens = tokens,
        .nodes = parser.nodes.toOwnedSlice(),
        .stmts = parser.stmts.toOwnedSlice(),
    };
}
