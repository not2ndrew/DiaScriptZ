const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");

const Allocator = std.mem.Allocator;

const NodeIndex = zig_node.NodeIndex;
const TokenIndex = tok.TokenIndex;

const Token = tok.Token;
const Tag = tok.Tag;

const Node = zig_node.Node;
const NodeData = zig_node.NodeData;
const ChoiceList = zig_node.ChoiceList;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);

const SemanticError = error {
    IntOverflow,
    IntUnderflow,
    UndeclaredVar,
    DuplicateVar,
};

pub const Semantic = struct {
    allocator: Allocator,
    source: []const u8,
    nodes: *const Nodes,
    tokens: *const Tokens,
    variables: std.StringArrayHashMap(void),

    pub fn init(allocator: Allocator, source: []const u8,
                nodes: *const Nodes, tokens: *const Tokens) Semantic {
        return .{
            .allocator = allocator,
            .source = source,
            .nodes = nodes,
            .tokens = tokens,
            .variables = std.StringArrayHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.variables.deinit();
    }

    pub fn analyze(self: *Semantic) !void {}
};
