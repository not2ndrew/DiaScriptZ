const std = @import("std");
const token = @import("token.zig");

const Tag = token.Tag;
const TokenIndex = token.TokenIndex;

pub const NodeIndex = u32;

pub const Node = struct {
    tag: Tag,
    main_token: TokenIndex,
    data: NodeData,
};

// ChoiceList has a MAX of 5 choices
// u3 = 0..7
pub const ChoiceList = struct {
    len: u3 = 0,
    items: [5]NodeIndex = undefined,
};

// TODO: Instead of using ?NodeIndex, assign std.math.maxInt()
// maxInt will represent as invalid nodeIndex.
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
        target: TokenIndex,
        value: NodeIndex,
    },
    const_decl: struct {
        name: TokenIndex,
        value: ?NodeIndex,
    },
    var_decl: struct {
        name: TokenIndex,
        value: ?NodeIndex,
    },
    if_stmt: struct {
        condition: NodeIndex,
        then_block: NodeIndex,
        else_block: ?NodeIndex,
    },
    block: struct {
        stmts: []NodeIndex,
    },
    choice_list: struct {
        string: []NodeIndex,
        goto: ?NodeIndex,
    },
    dialogue: struct {
        string: []NodeIndex,
        goto: ?NodeIndex,
        choices: ?ChoiceList,
    },
};
