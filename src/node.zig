const std = @import("std");
const token = @import("token.zig");

const Tag = token.Tag;
const TokenIndex = token.TokenIndex;

pub const NodeIndex = u32;

// invalid_node represents an invalid subtree
// AST consumer must handle it explicitly.
pub const invalid_node = std.math.maxInt(NodeIndex);

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
    assign, // =

    // Comparison
    equals, // ==
    not_equal, // !=
    less, // <
    greater, // >
    less_or_equal, // <=
    greater_or_equal, // >=

    // Combination Assign
    plus_equal, // +=
    minus_equal, // -=
    mult_equal, // *=
    div_equal, // /=

    // binary operations
    add,
    sub,
    mult,
    div,

    // Variable Names
    identifier,
    number,
    string,
    choice,
};

pub fn nodeTagFromAssign(token_tag: Tag) NodeTag {
    return switch (token_tag) {
        .assign => .assign,
        .plus_equal => .plus_equal,
        .minus_equal => .minus_equal,
        .asterisk_equal => .mult_equal,
        .slash_equal => .div_equal,
        else => unreachable,
    };
}

pub fn nodeTagFromCompare(token_tag: Tag) NodeTag {
    return switch (token_tag) {
        .equals => .equals,
        .not_equal => .not_equal,
        .greater => .greater,
        .less => .less,
        .greater_or_equal => .greater_or_equal,
        .less_or_equal => .less_or_equal,
        else => unreachable,
    };
}

pub fn nodeTagFromBinary(token_tag: Tag) NodeTag {
    return switch (token_tag) {
        .plus => .add,
        .minus => .sub,
        .asterisk => .mult,
        .slash => .div,
        else => unreachable,
    };
}

pub fn nodeTagFromScene(token_tag: Tag) NodeTag {
    return switch (token_tag) {
        .hash => .scene,
        .tilde => .label,
        else => unreachable,
    };
}

pub const Node = struct {
    tag: NodeTag,
    token_pos: TokenIndex,
    data: NodeData,
};

pub const NodeRange = struct {
    start: u32,
    len: u32,
};

pub const NodeData = union {
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
        name: NodeIndex,
        value: NodeIndex = invalid_node,
    },
    if_stmt: struct {
        condition: NodeIndex,
        then_block: NodeIndex = invalid_node,
        else_block: NodeIndex = invalid_node,
    },
    block: NodeRange,
    dialogue: struct {
        str: NodeRange,
        branch: union(enum) {
            none,
            goto: NodeIndex,
        },
    },
};
