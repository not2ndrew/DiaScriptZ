const std = @import("std");
const token = @import("token.zig");

const Allocator = std.mem.Allocator;

const Token = token.Token;
const Tag = token.Tag;
const TokenError = token.TokenError;
const keywords = token.keywords;

const isAlphabetic = std.ascii.isAlphabetic;
const isDigit = std.ascii.isDigit;

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize,
    str_mode: bool,

    pub fn init(buffer: []const u8) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
            .str_mode = false,
        };
    }

    fn isSpace(char: u8) bool {
        return char == ' ' or char == '\r' or char == '\t';
    }

    fn isIdentChar(c: u8) bool {
        return isAlphabetic(c) or isDigit(c) or c == '_';
    }

    fn isNotDialogueEnd(c: u8) bool {
        return c != '\n' and c != '-' and c != '{';
    }

    // Some characters require an equal character
    // ==, !=, +=, -=, *=, /=
    fn matchEquals(self: *Tokenizer, single: Tag, double: Tag) Tag {
        self.index += 1;
        if (self.index < self.buffer.len and self.buffer[self.index] == '=') {
            self.index += 1;
            return double;
        }

        return single;
    }

    fn findStr(self: *Tokenizer) Token {
        const start = self.index;
        const buffer = self.buffer;
        const len = buffer.len;

        self.str_mode = false;

        while (self.index < len and isNotDialogueEnd(buffer[self.index])) {
            self.index += 1;
        }

        return .{
            .tag = .String,
            .start = start,
            .end = self.index,
        };
    }

    // TODO: Add punctuations
    pub fn next(self: *Tokenizer) Token {
        const buffer = self.buffer;
        const len = buffer.len;

        // Skip white space
        while (self.index < len and isSpace(buffer[self.index])) {
            self.index += 1;
        }

        if (buffer[self.index] == '\n') {
            self.index += 1;
            self.str_mode = false;
        }

        var result: Token = .{
            .tag = .Invalid,
            .start = self.index,
            .end = self.index,
        };

        if (self.index >= len) {
            return .{
                .tag = .EOF,
                .start = self.index,
                .end = self.index,
            };
        }

        if (self.str_mode) return self.findStr();

        switch (buffer[self.index]) {
            '+' => result.tag = self.matchEquals(.Plus, .Plus_Equals),
            '-' => {
                result.start = self.index;
                self.index += 1;

                const next_char = buffer[self.index];

                if (next_char == '=') {
                    self.index += 1;
                    result.tag = .Minus_Equals;
                } else if (next_char == '>') {
                    self.index += 1;
                    result.tag = .Goto;
                } else {
                    result.tag = .Minus;
                }
            }, 
            '*' => result.tag = self.matchEquals(.Asterisk, .Asterisk_Equals),
            '/' => {
                result.start = self.index;
                self.index += 1;

                const next_char = buffer[self.index];

                if (next_char == '=') {
                    self.index += 1; // Consume '='
                    result.tag = .Slash_Equals;
                } else if (next_char == '/') {
                    self.index += 1; // Consume second '/'

                    while (self.index < len and buffer[self.index] != '\n') {
                        self.index += 1;
                    }

                    result.tag = .Comment;
                } else {
                    result.tag = .Slash;
                }
            },
            '=' => result.tag = self.matchEquals(.Assign, .Equals),
            // TODO: "!" is either logical NOT ( "!=" ) or a singleton (!bool)
            '!' => result.tag = self.matchEquals(.Invalid, .Not_Equals),
            '<' => result.tag = self.matchEquals(.Less, .Less_or_Equal),
            '>' => result.tag = self.matchEquals(.Greater, .Greater_or_Equal),
            '(' => {
                self.index += 1;
                result.tag = .Open_Paren;
            },
            ')' => {
                self.index += 1;
                result.tag = .Close_Paren;
            },
            '{' => {
                self.index += 1;
                result.tag = .Open_Brace;
            },
            '}' => {
                self.index += 1;
                result.tag = .Close_Brace;
                self.str_mode = true;
            },
            ':' => {
                self.index += 1;
                result.tag = .Colon;
                self.str_mode = true;
            },
            'a' ... 'z', 'A' ... 'Z' => {
                while (self.index < len and isIdentChar(self.buffer[self.index])) {
                    self.index += 1;
                }

                // Check for unique keywords
                if (keywords.get(buffer[result.start..self.index])) |uniqueId| {
                    result.tag = uniqueId;
                } else {
                    result.tag = .Identifier;
                }
            },
            '0' ... '9' => {
                while (self.index < len and isDigit(buffer[self.index])) {
                    self.index += 1;
                }
                // TODO: Make sure the Number does not go beyond u8.
                result.tag = .Number;
            },
            else => {
                self.index += 1;
                result.tag = .Invalid;
            }
        }

        result.end = self.index;
        return result;
    }
};
