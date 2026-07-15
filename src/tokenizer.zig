const std = @import("std");
const token = @import("token.zig");

const Token = token.Token;
const Tag = token.Tag;
const TokenError = token.TokenError;
const keywords = token.keywords;

const isAlphabetic = std.ascii.isAlphabetic;
const isDigit = std.ascii.isDigit;

const Mode = enum {
    normal,
    string,
    interpolation,
};

fn isIdentChar(c: u8) bool {
    return isAlphabetic(c) or isDigit(c) or c == '_';
}

// Newline is added to the end of every statement
// if the previous tag was:
// 1) identifier
// 2) number
// 3) close brace
// 4) close paren
// 5) string
//
// Look at Go Language scanner:
// https://go.dev/ref/spec#Semicolons
fn isImplicitSemiColon(prev: Tag) bool {
    return switch (prev) {
        .identifier, .number,
        .close_paren, .close_brace,
        .string => true,
        else => false,
    };
}

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize,
    mode: Mode,
    // line_start is used for dialogue choice marker.
    line_start: bool,
    prev_tag: Tag,

    pub fn init(buffer: []const u8) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
            .mode = .normal,
            .line_start = true,
            .prev_tag = .EOF,
        };
    }

    fn skipWhiteSpace(self: *Tokenizer) void {
        while (self.index < self.buffer.len) {
            switch (self.buffer[self.index]) {
                ' ', '\r', '\t' => self.index += 1,
                '\n' => {
                    if (isImplicitSemiColon(self.prev_tag)) return;
                    self.index += 1;
                    self.line_start = true;
                    self.mode = .normal;
                },
                else => return,
            }
        }
    }

    fn nextNonWsChar(self: *Tokenizer) void {
        while (self.index < self.buffer.len) {
            const c = self.buffer[self.index];
            switch (c) {
                ' ', '\r', '\t', '\n' => self.index += 1,
                else => return, 
            }
        }
    }

    /// Checks if the next character matches c.\n
    /// Increment token_pos if true. Otherwise, return false.
    fn matchNext(self: *Tokenizer, comptime c: u8) bool {
        if (self.index < self.buffer.len and self.buffer[self.index] == c) {
            self.index += 1;
            return true;
        }

        return false;
    }

    fn findStr(self: *Tokenizer) Token {
        const start = self.index;
        const buffer = self.buffer;

        while (self.index < buffer.len) {
            switch (buffer[self.index]) {
                '{' => {
                    self.mode = .interpolation;
                    break;
                },
                '-' => {
                    if (self.index + 1 < buffer.len and buffer[self.index + 1] == '>') {
                        self.mode = .normal;
                        break;
                    } else {
                        self.index += 1;
                    }
                },
                '\n' => {
                    self.mode = .normal;
                    self.line_start = true;
                    break;
                },
                else => self.index += 1,
            }
        }

        self.prev_tag = .string;
        return .{
            .tag = .string,
            .start = start,
            .end = self.index,
        };
    }

    pub fn next(self: *Tokenizer) Token {
        const buffer = self.buffer;
        const len = buffer.len;

        self.skipWhiteSpace();

        var result: Token = .{
            .tag = .invalid,
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

        const ch = self.buffer[self.index];
        self.index += 1;

        if (self.mode == .string) return self.findStr();
        
        switch (ch) {
            '\n' => {
                // We only reach here if the condition is fulfilled
                // is true
                result.tag = .newline;
                // Turn off line_starts for now.
                // Sometimes, line_starts goes outside the maximum
                // rows.
                self.nextNonWsChar();
            },
            '+' => {
                // self.insert_semi = false;
                result.tag = if (self.matchNext('=')) .plus_equal else .plus;
            },
            '-' => {

                if (self.matchNext('=')) {
                    result.tag = .minus_equal;
                } else if (self.matchNext('>')) {
                    result.tag = .goto;
                } else {
                    result.tag = .minus;
                }
            }, 
            '*' => {
                if (self.line_start) {
                    self.mode = .string;
                    self.line_start = false;
                    result.tag = .choice_marker;
                } else {
                    result.tag = if (self.matchNext('=')) .asterisk_equal else .asterisk;
                }
            },
            '/' => {
                if (self.matchNext('=')) {
                    result.tag = .slash_equal;
                } else if (self.matchNext('/')) {
                    while (self.index < len and buffer[self.index] != '\n') {
                        self.index += 1;
                    }

                    return self.next();
                } else {
                    result.tag = .slash;
                }
            },
            '=' => {
                result.tag = if (self.matchNext('=')) .equal_equal else .assign;
            },
            '!' => {
                result.tag = if (self.matchNext('=')) .not_equal else .exclamation;
            },
            '<' => {
                result.tag = if (self.matchNext('=')) .less_or_equal else .less;
            },
            '>' => {
                result.tag = if (self.matchNext('=')) .greater_or_equal else .greater;
            },
            '(' => {
                result.tag = .open_paren;
            },
            ')' => {
                result.tag = .close_paren;
            },
            '{' => {
                switch (self.mode) {
                    .interpolation => {
                        result.tag = .inter_open;
                    },
                    else => {
                        result.tag = .open_brace;
                    }
                }
            },
            '}' => {
                switch (self.mode) {
                    .interpolation => {
                        self.mode = .string;
                        result.tag = .inter_close;
                    },
                    else => {
                        result.tag = .close_brace;
                    }
                }
            },
            ':' => {
                result.tag = .colon;
                self.mode = .string;
            },
            '~' => {
                result.tag = .tilde;
            },
            '_' => {
                result.tag = .underscore;
            },
            'a' ... 'z', 'A' ... 'Z' => {
                while (self.index < len and isIdentChar(buffer[self.index])) {
                    self.index += 1;
                }

                // Check for unique keywords
                if (keywords.get(buffer[result.start..self.index])) |uniqueId| {
                    result.tag = uniqueId;
                } else {
                    result.tag = .identifier;
                }
            },
            '0' ... '9' => {
                while (self.index < len and isDigit(buffer[self.index])) {
                    self.index += 1;
                }
                result.tag = .number;
            },
            else => {
                result.tag = .invalid;
            }
        }

        self.prev_tag = result.tag;
        if (result.tag != .newline) self.line_start = false;
        result.end = self.index;
        return result;
    }
};
