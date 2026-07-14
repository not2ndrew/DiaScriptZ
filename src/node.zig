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
    
    // Block
    block,

    // Single characters
    assign, // =

    // Comparison
    equal_equal, // ==
    not_equal, // !=
    less, // <
    greater, // >
    less_or_equal, // <=
    greater_or_equal, // >=
    bool_and,
    bool_or,

    // Combination Arithmetic
    plus_equal, // +=
    minus_equal, // -=
    mult_equal, // *=
    div_equal, // /=

    // Arithmetic operations
    plus,
    minus,
    mult,
    div,

    // Identifiers
    var_ident,
    label_ident,
    name_ident,

    // Variable Names
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
        .equal_equal => .equal_equal,
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
        .plus => .plus,
        .minus => .minus,
        .asterisk => .mult,
        .slash => .div,
        else => null,
    };
}

pub fn nodeTagFromScene(token_tag: Tag) ?NodeTag {
    return switch (token_tag) {
        .tilde => .label,
        else => null,
    };
}

pub const Node = struct {
    tag: NodeTag,
    token_pos: TokenIndex,
    data: Data,

    pub const Data = union {
        none: void,
        node_and_node: struct { NodeIndex, NodeIndex },
        range: Range,
    };

    // Start is the starting position of extra
    // rather than the index of extra.
    pub const Range = struct {
        start: u32,
        len: u32,
    };
};
