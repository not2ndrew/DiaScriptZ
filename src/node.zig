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
    if_stmt,
    label,
    dialogue,
    choice,
    
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

    // Identifiers
    var_ident,
    label_ident,
    name_ident,

    // Variable Names
    identifier,
    number,
    string,
    anonymous,
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

pub const Block = []NodeIndex;

pub const Range = struct {
    start: u32,
    len: u32,
};

// TODO: every data using none will pay the full cost of dialogue.
// Try to reduce the size of the largest field.
pub const NodeData = union(enum) {
    none,

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
    block: Block,
    dialogue: struct {
        str: Range,
        branch: union(enum) {
            none,
            goto: NodeIndex,
        },
    },
};
