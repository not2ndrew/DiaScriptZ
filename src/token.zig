const std = @import("std");

pub const TokenIndex = u32;

pub const TokenList = std.MultiArrayList(Token);

pub const TokenError = error {
    InvalidString,
};

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,
};

pub const Tag = enum {
    // Unique keywords
    keyword_const,
    keyword_var,
    keyword_if,
    keyword_else,
    keyword_end,
    label,
    scene,
    choice,

    // If Statement
    then_block,
    else_block,

    // Single Character
    colon, // :
    assign, // =
    open_paren, // (
    close_paren, // )
    plus, // +
    minus, // -
    asterisk, // *
    slash, // /
    underscore, // _
    exclamation, // !
    open_brace, // {
    close_brace, // }
    tilde, // ~

    // Comparison
    equals, // ==
    not_equal, // !=
    less, // <
    greater, // >
    less_or_equal, // <=
    greater_or_equal, // >=

    // Variable Names
    identifier, // letter { letter | digit | "_" } 
    number, // unsigned 8-bit int (1 => 255)

    // Combination Assign
    plus_equal, // +=
    minus_equal, // -=
    asterisk_equal, // *=
    slash_equal, // /=

    // Dialogue Parsing
    string, // { content }
    dialogue,
    choice_marker, // "*" at the beginning of a newline
    choice_list,
    label_list,
    goto, // ->
    inter_open, // string interpolation {
    inter_close, // string interpolation }

    // Invalid Format
    invalid, // Anything that is not in here
    EOF, // End Of File
};

pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "const", .keyword_const },
    .{ "var", .keyword_var },
    .{ "if", .keyword_if },
    .{ "else", .keyword_else },
    .{ "end", .keyword_end },
});
