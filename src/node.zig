const std = @import("std");
const token = @import("token.zig");

const Tag = token.Tag;
const TokenIndex = token.TokenIndex;

pub const NodeIndex = u32;

// Instead of null, we assign maxInt of NodeIndex as invalid
pub const invalid_node = std.math.maxInt(NodeIndex);

pub const Node = struct {
    tag: Tag,
    token_pos: TokenIndex,
    data: NodeData,
};

// ChoiceList has a MAX of 5 choices
// u3 = 0..7
pub const ChoiceList = struct {
    len: u3 = 0,
    items: [5]NodeIndex = undefined,
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
    // Statements
    assign: struct {
        target: NodeIndex,
        value: NodeIndex,
    },
    decl: struct {
        kind: Tag, // Only for Var and Const
        name: TokenIndex,
        value: NodeIndex = invalid_node,
    },
    if_stmt: struct {
        condition: NodeIndex,
        then_block: NodeIndex,
        else_block: NodeIndex = invalid_node,
    },
    block: struct {
        stmts: []NodeIndex,
    },
    choice_list: struct {
        string: []NodeIndex,
        goto: NodeIndex = invalid_node,
    },
    dialogue: struct {
        string: []NodeIndex,
        goto: NodeIndex = invalid_node,
        choices: ChoiceList = ChoiceList{},
    },
};
