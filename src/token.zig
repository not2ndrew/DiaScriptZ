const std = @import("std");

pub const TokenError = error {
    InvalidString,
};

pub const Token = struct {
    tag: Tag,
    start: usize,
    end: usize,
};

pub const TokenData = struct {
    tag: Tag,
    start: u32,
};

pub const Tag = enum {
    // Unique keywords
    Const,
    Var,
    Label,
    Scene,
    Choice,
    End,
    Boolean, // true, false

    // Single Character
    Colon, // :
    Assignment, // =
    Equals, // ==
    Not_Equals, // !=
    Open_Paren, // (
    Close_Paren, // )
    Plus, // +
    Minus, // -
    Asterisk, // *
    Slash, // /

    // Variable Names
    Identifier, // Variable Name
    String, // ""
    Number, // unsigned 8-bit int (1 => 255)

    Plus_Equals, // +=
    Minus_Equals, // -=
    Asterisk_Equals, // *=
    Slash_Equals, // /=

    // Invalid Format
    Invalid, // Anything that is not in here
    EOF, // End Of File

};

pub const keywords = std.StaticStringMap(Tag).initComptime(.{
    .{ "const", .Const },
    .{ "var", .Var },
    .{ "label", .Label },
    .{ "scene", .Scene },
    .{ "choice", .Choice },
    .{ "end", .End },
    .{ "true", .Boolean },
    .{ "false", .Boolean },
});
