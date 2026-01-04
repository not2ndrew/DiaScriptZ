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

pub const Semantic = struct {
    nodes: []Node,
};
