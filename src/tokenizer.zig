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

    pub fn init(buffer: []const u8) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
        };
    }

    fn isSpace(char: u8) bool {
        return char == ' ' or char == '\r' or char == '\n' or char == '\t';
    }

    // Some characters require an equal character
    // ==, !=, +=, -=, *=, /=
    fn isAugmentedAssign(self: *Tokenizer, current_tag: Tag, statement: Tag) Tag {
        self.index += 1;
        if (self.buffer[self.index] == '=') {
            self.index += 1;
            return statement;
        }

        return current_tag;
    }


    pub fn next(self: *Tokenizer) Token {
        const buffer = self.buffer;
        const len = buffer.len;

        while (self.index < len and isSpace(buffer[self.index])) {
            self.index += 1;
        }

        var result: Token = .{
            .tag = .EOF,
            .start = self.index,
            .end = self.index,
        };

        if (self.index >= len) {
            self.index += 1;
            return .{
                .tag = .EOF,
                .start = self.index,
                .end = self.index,
            };
        }

        switch (buffer[self.index]) {
            '+' => result.tag = self.isAugmentedAssign(.Plus, .Plus_Equals),
            '-' => result.tag = self.isAugmentedAssign(.Minus, .Minus_Equals),
            '*' => result.tag = self.isAugmentedAssign(.Asterisk, .Asterisk_Equals),
            '/' => result.tag = self.isAugmentedAssign(.Slash, .Slash_Equals),
            '=' => result.tag = self.isAugmentedAssign(.Assign, .Equals),
            '!' => result.tag = self.isAugmentedAssign(.Invalid, .Not_Equals),
            '<' => result.tag = self.isAugmentedAssign(.Less, .Less_or_Equal),
            '>' => result.tag = self.isAugmentedAssign(.Greater, .Greater_or_Equal),
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
            },
            ':' => {
                self.index += 1;
                result.tag = .Colon;
            },
            'a' ... 'z', 'A' ... 'Z' => {
                while (self.index < len and isAlphabetic(buffer[self.index])) {
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
                // TODO: Make sure the Number does not go beyond u32.
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
