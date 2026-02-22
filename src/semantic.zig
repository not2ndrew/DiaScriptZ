const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const diagnostic = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;

const NodeIndex = zig_node.NodeIndex;
const TokenIndex = tok.TokenIndex;

const Token = tok.Token;
const Tag = tok.Tag;

const Node = zig_node.Node;
const NodeData = zig_node.NodeData;
const ChoiceList = zig_node.ChoiceList;
const invalid_node = zig_node.invalid_node;

const DiagnosticSink = diagnostic.DiagnosticSink;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);
const NodeList = std.ArrayList(NodeIndex);

const MAX_NUM_CHOICES = 4;

const Error = Allocator.Error;

pub const Symbol = struct {
    token_pos: TokenIndex,
    is_const: bool,
};

pub const Semantic = struct {
    diag_sink: *DiagnosticSink,
    stmts: []const NodeIndex,
    nodes: *const Nodes,
    tokens: *const Tokens,

    symbols: std.StringArrayHashMap(Symbol),

    pub fn init(
        diag_sink: *DiagnosticSink, stmts: []const NodeIndex,
        nodes: *const Nodes, tokens: *const Tokens
    ) Semantic {
        return .{
            .diag_sink = diag_sink,
            .stmts = stmts,
            .nodes = nodes,
            .tokens = tokens,
            .symbols = std.StringArrayHashMap(Symbol).init(diag_sink.allocator)
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.symbols.deinit();
    }
};
