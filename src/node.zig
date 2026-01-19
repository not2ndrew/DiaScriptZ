const std = @import("std");
const token = @import("token.zig");

const Tag = token.Tag;
const TokenIndex = token.TokenIndex;

pub const NodeIndex = u32;

// Instead of null, we assign maxInt of NodeIndex as invalid
pub const invalid_node = std.math.maxInt(NodeIndex);

// TODO: Use a different tag for Nodes.
// Tags from Token and Nodes are slightly different.
pub const NodeTag = enum {
    // Stmts
    declar_stmt,
    compound_stmt,
    if_stmt,
    label,
    dialogue,
    scene,
    
    // choices
    choice_marker,
    choice_list,

    // If stmts
    block,
    then_block,
    else_block,

    // Single characters
    assign,

    // Comparison
    equals, // ==
    not_equal, // !=
    kess, // <
    greater, // >
    less_or_equal, // <=
    greater_or_equal, // >=

    // Combination Assign
    plus_equal, // +=
    minus_equal, // -=
    asterisk_equal, // *=
    slash_equal, // /=

    // Variable Names
    identifier,
    number,
};
// TODO: Reduce size of node. It is currently 64 bytes
//
// 1) Not every dialogue will contain a choiceList.
// Maybe try using AutoHashMap as sparse data.
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
        name: TokenIndex,
        value: NodeIndex = invalid_node,
    },
    if_stmt: struct {
        condition: NodeIndex,
        then_block: NodeIndex = invalid_node,
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
