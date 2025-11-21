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
    allocator: Allocator,
    buffer: []const u8,
    index: usize,
    tokenList: std.MultiArrayList(Token),

    pub fn init(allocator: Allocator, buffer: []const u8) Tokenizer {
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .index = 0,
            .tokenList = .{},
        };
    }

    pub fn deinit(self: *Tokenizer) void {
        self.tokenList.deinit(self.allocator);
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

    pub fn tokenize(self: *Tokenizer) !void {
        while (self.index < self.buffer.len) {
            const tok = self.next();

            if (tok.tag == .EOF) return;

            try self.tokenList.append(self.allocator, tok);

            std.debug.print("Token: {s}\n", .{@tagName(tok.tag)});
        }
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

        const char = buffer[self.index];

        switch (char) {
            '+' => result.tag = self.isEqualAssignment(.Plus, .Plus_Equals),
            '-' => result.tag = self.isEqualAssignment(.Minus, .Minus_Equals),
            '*' => result.tag = self.isEqualAssignment(.Asterisk, .Asterisk_Equals),
            '/' => result.tag = self.isEqualAssignment(.Slash, .Slash_Equals),
            '=' => result.tag = self.isEqualAssignment(.Assign, .Equals),
            '!' => result.tag = self.isEqualAssignment(.Invalid, .Not_Equals),
            '(' => {
                self.index += 1;
                result.tag = .Open_Paren;
            },
            ')' => {
                self.index += 1;
                result.tag = .Close_Paren;
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
