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

// Newline is ignored if:
// 1) inside () [] {}
// 2) prev token is an operator
// 3) expression is syntactically incomplete.
//
// Look at Go Language scanner:
// https://github.com/golang/go/blob/master/src/go/scanner/scanner.go
pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize,
    mode: Mode,
    // line_start is used for dialogue choice marker.
    line_start: bool,
    insert_semi: bool,

    pub fn init(buffer: []const u8) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
            .mode = .normal,
            .line_start = true,
            .insert_semi = false,
        };
    }

    fn skipWhiteSpace(self: *Tokenizer) void {
        while (self.index < self.buffer.len) {
            switch (self.buffer[self.index]) {
                ' ', '\r', '\t' => self.index += 1,
                '\n' => {
                    if (self.insert_semi) return;
                    self.index += 1;
                    self.line_start = true;
                    self.mode = .normal;
                },
                else => return,
            }
        }
    }

    fn nextNonWsChar(self: *Tokenizer) void {
        var i = self.index;
        while (i < self.buffer.len) {
            const c = self.buffer[i];
            switch (c) {
                ' ', '\r', '\t', '\n' => i += 1,
                else => return i, 
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
                    self.insert_semi = true;
                    self.line_start = true;
                    break;
                },
                else => self.index += 1,
            }
        }

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
                // We only reach here if self.insert_semi
                // is true
                self.insert_semi = false;
                result.tag = .newline;
                // Turn off line_starts for now.
                // Sometimes, line_starts goes outside the maximum
                // rows.
                self.nextNonWsChar();
            },
            '+' => {
                self.insert_semi = false;
                result.tag = if (self.matchNext('=')) .plus_equal else .plus;
            },
            '-' => {
                self.insert_semi = false;

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
                    self.insert_semi = false;
                    result.tag = if (self.matchNext('=')) .asterisk_equal else .asterisk;
                }
            },
            '/' => {
                if (self.matchNext('=')) {
                    self.insert_semi = false;
                    result.tag = .slash_equal;
                } else if (self.matchNext('/')) {
                    while (self.index < len and buffer[self.index] != '\n') {
                        self.index += 1;
                    }

                    return self.next();
                } else {
                    self.insert_semi = false;
                    result.tag = .slash;
                }
            },
            '=' => {
                self.insert_semi = false;
                result.tag = if (self.matchNext('=')) .equals else .assign;
            },
            '!' => {
                self.insert_semi = false;
                result.tag = if (self.matchNext('=')) .not_equal else .exclamation;
            },
            '<' => {
                self.insert_semi = false;
                result.tag = if (self.matchNext('=')) .less_or_equal else .less;
            },
            '>' => {
                self.insert_semi = false;
                result.tag = if (self.matchNext('=')) .greater_or_equal else .greater;
            },
            '(' => {
                result.tag = .open_paren;
            },
            ')' => {
                self.insert_semi = true;
                result.tag = .close_paren;
            },
            '{' => {
                switch (self.mode) {
                    .interpolation => {
                        result.tag = .inter_open;
                    },
                    else => {
                        self.insert_semi = false;
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
                        self.insert_semi = false;
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
                self.insert_semi = true;
                result.tag = .number;
            },
            else => {
                self.insert_semi = true;
                result.tag = .invalid;
            }
        }

        if (result.tag != .newline) self.line_start = false;
        result.end = self.index;
        return result;
    }
};
