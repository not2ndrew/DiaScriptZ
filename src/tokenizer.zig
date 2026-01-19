const std = @import("std");
const token = @import("token.zig");

const Allocator = std.mem.Allocator;

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

pub const Tokenizer = struct {
    buffer: []const u8,
    index: usize,
    mode: Mode,
    line_start: bool,

    pub fn init(buffer: []const u8) Tokenizer {
        return .{
            .buffer = buffer,
            .index = 0,
            .mode = .normal,
            .line_start = true,
        };
    }

    fn isIdentChar(c: u8) bool {
        return isAlphabetic(c) or isDigit(c) or c == '_';
    }

    fn skipWhiteSpace(self: *Tokenizer) void {
        const buffer = self.buffer;

        while (self.index < buffer.len) {
            switch (buffer[self.index]) {
                ' ', '\r', '\t' => self.index += 1,
                '\n' => {
                    self.index += 1;
                    self.mode = .normal;
                    self.line_start = true;
                },
                else => return,
            }
        }
    }

    fn match(self: *Tokenizer, c: u8) bool {
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
                '\n', '-', '{' => break,
                else => self.index += 1,
            }
        }

        if (self.buffer[self.index] == '{') {
            self.mode = .interpolation;
        } else {
            self.mode = .normal;
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

        if (self.mode == .string and buffer[self.index] != '{') return self.findStr();
        
        switch (buffer[self.index]) {
            '+' => {
                self.index += 1;
                result.tag = if (self.match('=')) .plus_equal else .plus;
            },
            '-' => {
                result.start = self.index;
                self.index += 1;

                if (self.match('=')) {
                    self.index += 1;
                    result.tag = .minus_equal;
                } else if (self.match('>')) {
                    self.index += 1;
                    result.tag = .goto;
                } else {
                    result.tag = .minus;
                }
            }, 
            '*' => {
                if (self.line_start) {
                    self.mode = .string;
                    self.line_start = false;
                    self.index += 1;
                    result.tag = .choice_marker;
                } else {
                    self.index += 1;
                    result.tag = if (self.match('=')) .asterisk_equal else .asterisk;
                }
            },
            '/' => {
                result.start = self.index;
                self.index += 1;

                if (self.match('=')) {
                    self.index += 1;
                    result.tag = .slash_equal;
                } else if (self.match('/')) {
                    self.index += 1; // Consume second '/'
                    while (self.index < len and buffer[self.index] != '\n') {
                        self.index += 1;
                    }

                    return self.next();
                } else {
                    result.tag = .slash;
                }
            },
            '=' => {
                self.index += 1;
                result.tag = if (self.match('=')) .equals else .assign;
            },
            '!' => {
                self.index += 1;
                result.tag = if (self.match('=')) .not_equal else .exclamation;
            },
            '<' => {
                self.index += 1;
                result.tag = if (self.match('=')) .less_or_equal else .less;
            },
            '>' => {
                self.index += 1;
                result.tag = if (self.match('=')) .greater_or_equal else .greater;
            },
            '(' => {
                self.index += 1;
                result.tag = .open_paren;
            },
            ')' => {
                self.index += 1;
                result.tag = .close_paren;
            },
            '{' => {
                switch (self.mode) {
                    .interpolation => {
                        self.index += 1;
                        result.tag = .inter_open;
                    },
                    else => {
                        self.index += 1;
                        result.tag = .open_brace;
                    }
                }
            },
            '}' => {
                switch (self.mode) {
                    .interpolation => {
                        self.index += 1;
                        self.mode = .string;
                        result.tag = .inter_close;
                    },
                    else => {
                        self.index += 1;
                        result.tag = .close_brace;
                    }
                }
            },
            ':' => {
                self.index += 1;
                result.tag = .colon;
                self.mode = .string;
            },
            '~' => {
                self.index += 1;
                result.tag = .tilde;
            },
            '#' => {
                self.index += 1;
                result.tag = .hash;
            },
            '_' => {
                self.index += 1;
                result.tag = .underscore;
            },
            'a' ... 'z', 'A' ... 'Z' => {
                while (self.index < len and isIdentChar(self.buffer[self.index])) {
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
                self.index += 1;
                result.tag = .invalid;
            }
        }

        self.line_start = false;
        result.end = self.index;
        return result;
    }
};
