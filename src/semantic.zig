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
const invalid_node = zig_node.invalid_node;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);

const SemanticError = error {
    IntOverflow,
    IntUnderflow,
    UndeclaredVar,
    DuplicateVar,
};

const Error = error{SemanticError} || Allocator.Error;

pub const Symbol = struct {
    token_pos: TokenIndex,
    is_const: bool,
    initialized: bool,
};

pub const Semantic = struct {
    allocator: Allocator,
    source: []const u8,
    nodes: *const Nodes,
    tokens: *const Tokens,
    symbols: std.StringArrayHashMap(Symbol),

    pub fn init(allocator: Allocator, source: []const u8,
                nodes: *const Nodes, tokens: *const Tokens) Semantic {
        return .{
            .allocator = allocator,
            .source = source,
            .nodes = nodes,
            .tokens = tokens,
            .symbols = std.StringArrayHashMap(Symbol).init(allocator),
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.symbols.deinit();
    }

    pub fn analyze(self: *Semantic, idx: NodeIndex) Error!void {
        const node = self.nodes.get(idx);

        switch (node.tag) {
            .Number, .String => {},
            .Const, .Var => try self.analyzeDeclar(node),
            else => return {},
        }
    }

    fn analyzeDeclar(self: *Semantic, node: Node) Error!void {
        const is_const = node.tag == .Const;
        const tok_pos = node.token_pos;
        const token = self.tokens.get(tok_pos);
        const name = self.source[token.start..token.end];
        const value = node.data.decl.value;

        if (self.symbols.contains(name)) return Error.SemanticError;

        try self.symbols.put(name, .{
            .token_pos = tok_pos,
            .is_const = is_const,
            .initialized = false,
        });

        if (value != invalid_node) {
            try self.analyze(value);
            self.symbols.getPtr(name).?.initialized = true;
        }
    }
};
