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

const Error = error{SemanticError} || Allocator.Error;

// TODO: Consider using a symbol table. Take in the nodes
// and convert them into an multiArrayList of Symbols.
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
            // .Assign => try analyzeNode(node),
            // .Identifier => try analyzeIdent(node),
            // .If => try analyzeIf(node),
            // .Block => try analyzeBlock(node),
            .Number, .String => {},
            else => return Error.SemanticError,
        }
    }
    // fn analyzeAssign(node: Node) !void {
    //     const name = tokenText(node.data.assign.target);
    //
    //     const symbol = symbols.get(name) orelse {
    //         return error.UndeclaredIdentifier;
    //     };
    //
    //     if (symbol.is_const) {
    //         return error.AssignToConst;
    //     }
    //
    //     try analyzeNode(node.data.assign.value);
    // }
};
