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
    Boolean, // true, false
    If,
    Else,
    Label,
    Scene,
    Choice,
    End,

    // If Statement
    Then_Block,
    Else_Block,

    // Single Character
    Colon, // :
    Assign, // =
    Open_Paren, // (
    Close_Paren, // )
    Plus, // +
    Minus, // -
    Asterisk, // *
    Slash, // /
    Open_Brace, // {
    Close_Brace, // }

    // Comparison
    Equals, // ==
    Not_Equal, // !=
    Less, // <
    Greater, // >
    Less_or_Equal, // <=
    Greater_or_Equal, // >=
    Comment, // "//"

    // Variable Names
    Identifier, // letter { letter | digit | "_" } 
    Number, // unsigned 8-bit int (1 => 255)

    // Combination Assign
    Plus_Equal, // +=
    Minus_Equal, // -=
    Asterisk_Equal, // *=
    Slash_Equal, // /=

    // Dialogue Parsing
    String, // { content }
    Dialogue,
    Choice_Marker, // "*" at the beginning of a newline
    Choice_List,
    Label_List,
    Goto, // ->
    Inter_Open, // string interpolation {
    Inter_Close, // string interpolation }

    // Invalid Format
    Invalid, // Anything that is not in here
    EOF, // End Of File
};

pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "true", .Boolean },
    .{ "false", .Boolean },
    .{ "if", .If },
    .{ "else", .Else },
    .{ "label", .Label },
    .{ "end", .End },
});
