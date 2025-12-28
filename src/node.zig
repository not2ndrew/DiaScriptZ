const std = @import("std");
const token = @import("token.zig");

const Tag = token.Tag;
const TokenIndex = token.TokenIndex;

pub const NodeIndex = u32;

pub const NodeList = std.MultiArrayList(Node);

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: NodeData,
};

pub const NodeData = union(enum) {
    // Literals
    number: struct { token: TokenIndex },
    string: struct { token: TokenIndex },
    identifier: struct { token: TokenIndex },

    // Expressions
    binary: struct {
        lhs: NodeIndex,
        rhs: NodeIndex,
    },
    unary: struct {
        op_token: TokenIndex, // operation tokens (+, -, *, /)
        rhs: NodeIndex,
    },

    // Statements
    assign: struct {
        target: NodeIndex,
        value: NodeIndex,
    },
    declar: struct {
        kind: Tag,
        assign: NodeIndex,
    },
    if_stmt: struct {
        condition: NodeIndex,
        then_blck: NodeIndex,
        else_blck: ?NodeIndex,
    },
    block: struct {
        statements: []NodeIndex,
    },
    dialogue: struct {
        string: NodeIndex,
        target: ?NodeIndex,
    },
};
