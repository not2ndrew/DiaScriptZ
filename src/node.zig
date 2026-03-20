const std = @import("std");
const token = @import("token.zig");

pub const NodeIndex = u32;

// invalid_node represents an invalid subtree
// AST consumer must handle it explicitly.
pub const invalid_node = std.math.maxInt(NodeIndex);

const Tag = token.Tag;
const TokenIndex = token.TokenIndex;

pub const NodeTag = enum {
    // Stmts
    declar_stmt,
    compound_stmt, // TODO: I am not using this enum.
    if_stmt,
    label,
    dialogue,
    choice,
    
    // choices
    choice_marker,

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

    // Combination Arithmetic
    plus_equal, // +=
    minus_equal, // -=
    mult_equal, // *=
    div_equal, // /=

    // Arithmetic operations
    add,
    sub,
    mult,
    div,

    // Variable Names
    identifier,
    number,
    string,
};

pub fn nodeTagFromArithmetic(token_tag: Tag) ?NodeTag {
    return switch (token_tag) {
        .assign => .assign,
        .plus_equal => .plus_equal,
        .minus_equal => .minus_equal,
        .asterisk_equal => .mult_equal,
        .slash_equal => .div_equal,
        else => null,
    };
}

pub fn nodeTagFromCompare(token_tag: Tag) ?NodeTag {
    return switch (token_tag) {
        .equals => .equals,
        .not_equal => .not_equal,
        .greater => .greater,
        .less => .less,
        .greater_or_equal => .greater_or_equal,
        .less_or_equal => .less_or_equal,
        else => null,
    };
}

pub fn nodeTagFromBinary(token_tag: Tag) ?NodeTag {
    return switch (token_tag) {
        .plus => .add,
        .minus => .sub,
        .asterisk => .mult,
        .slash => .div,
        else => null,
    };
}

pub fn nodeTagFromScene(token_tag: Tag) ?NodeTag {
    return switch (token_tag) {
        .hash => .scene,
        .tilde => .label,
        else => null,
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

// TODO: Adjust numbers, string, and identifier
// These union fields pay the full price of an if_stmt.
// So it becomes very expensive the more nodes are created.
pub const NodeData = union {
    // Literals
    numbers: TokenIndex,
    string: TokenIndex,
    identifier: TokenIndex,

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
