const std = @import("std");
const token = @import("token.zig");

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

    pub fn isSpace(char: u8) bool {
        return char == ' ' or char == '\r' or char == '\n';
    }

    pub fn isEqualAssignment(self: *Tokenizer, current_tag: Tag, statement: Tag) Tag {
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

        if (self.index >= len) return result;

        const char = buffer[self.index];

        switch (char) {
            '+' => result.tag = self.isEqualAssignment(.Plus, .Plus_Equals),
            '-' => result.tag = self.isEqualAssignment(.Minus, .Minus_Equals),
            '*' => result.tag = self.isEqualAssignment(.Asterisk, .Asterisk_Equals),
            '/' => result.tag = self.isEqualAssignment(.Slash, .Slash_Equals),
            ':' => {
                self.index += 1;
                result.tag = .Colon;
            },
            '=' => result.tag = self.isEqualAssignment(.Assignment, .Equals),
            '!' => result.tag = self.isEqualAssignment(.Invalid, .Not_Equals),
            '(' => {
                self.index += 1;
                result.tag = .Open_Paren;
            },
            ')' => {
                self.index += 1;
                result.tag = .Close_Paren;
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
