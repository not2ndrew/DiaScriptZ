const std = @import("std");

pub const TokenIndex = u32;

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,

    pub const Tag = enum {
        // Unique keywords
        keyword_const,
        keyword_var,
        keyword_if,
        keyword_else,
        keyword_end,
        keyword_and,
        keyword_or,

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
        semi_colon, // ';' Note they are implicit

        // Comparison
        equal_equal, // ==
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
        choice_marker, // "*" at the beginning of a newline
        goto, // ->
        inter_open, // string interpolation {
        inter_close, // string interpolation }

        // Invalid Format
        invalid, // Anything that is not in here
        EOF, // End Of File
    };

};

pub fn lexeme(tag: Token.Tag) ?[]const u8 {
    return switch(tag) {
        .string, .invalid => null,

        .keyword_const => "const",
        .keyword_var => "var",
        .keyword_if => "if",
        .keyword_else => "else",
        .keyword_end => "end",
        .keyword_and => "and",
        .keyword_or => "or",

        .colon => ":",
        .assign => "=",
        .open_paren => "(",
        .close_paren => ")",
        .plus => "+",
        .minus => "-",
        .asterisk, .choice_marker => "*",
        .slash => "/",
        .underscore => "_",
        .exclamation => "!",
        .open_brace, .inter_open => "{",
        .close_brace, .inter_close => "}",
        .tilde => "~",
        // Note that semi colons are implicit.
        .semi_colon => "newline",

        .equal_equal => "==",
        .not_equal => "!=",
        .less => "<",
        .greater => ">",
        .less_or_equal => "<=",
        .greater_or_equal => ">=",

        .identifier => "identifier",
        .number => "number",

        .plus_equal => "+=",
        .minus_equal => "-=",
        .asterisk_equal => "*=",
        .slash_equal => "/=",

        // .string => "dialogue string",
        .goto => "->",

        // .invalid => "Invalid Character",
        .EOF => "End Of File"
    };
}

pub const keywords = std.StaticStringMap(Token.Tag).initComptime(.{
    .{ "const", .keyword_const },
    .{ "var", .keyword_var },
    .{ "if", .keyword_if },
    .{ "else", .keyword_else },
    .{ "end", .keyword_end },
    .{ "and", .keyword_and },
    .{ "or", .keyword_or },
});
