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
    Normal,
    String,
    Interpolation,
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
            .mode = .Normal,
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
                    self.mode = .Normal;
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
            self.mode = .Interpolation;
        } else {
            self.mode = .Normal;
        }

        return .{
            .tag = .String,
            .start = start,
            .end = self.index,
        };
    }

    pub fn next(self: *Tokenizer) Token {
        const buffer = self.buffer;
        const len = buffer.len;

        self.skipWhiteSpace();

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

        if (self.mode == .String and buffer[self.index] != '{') return self.findStr();
        
        switch (buffer[self.index]) {
            '+' => {
                self.index += 1;
                result.tag = if (self.match('=')) .Plus_Equal else .Plus;
            },
            '-' => {
                result.start = self.index;
                self.index += 1;

                if (self.match('=')) {
                    self.index += 1;
                    result.tag = .Minus_Equal;
                } else if (self.match('>')) {
                    self.index += 1;
                    result.tag = .Goto;
                } else {
                    result.tag = .Minus;
                }
            }, 
            '*' => {
                if (self.line_start) {
                    self.mode = .String;
                    self.line_start = false;
                    self.index += 1;
                    result.tag = .Choice_Marker;
                } else {
                    self.index += 1;
                    result.tag = if (self.match('=')) .Asterisk_Equal else .Asterisk;
                }
            },
            '/' => {
                result.start = self.index;
                self.index += 1;

                if (self.match('=')) {
                    self.index += 1;
                    result.tag = .Slash_Equal;
                } else if (self.match('/')) {
                    self.index += 1; // Consume second '/'
                    while (self.index < len and buffer[self.index] != '\n') {
                        self.index += 1;
                    }

                    return self.next();
                } else {
                    result.tag = .Slash;
                }
            },
            '=' => {
                self.index += 1;
                result.tag = if (self.match('=')) .Equals else .Assign;
            },
            '!' => {
                self.index += 1;
                result.tag = if (self.match('=')) .Not_Equal else .Exclamation;
            },
            '<' => {
                self.index += 1;
                result.tag = if (self.match('=')) .Less_or_Equal else .Less;
            },
            '>' => {
                self.index += 1;
                result.tag = if (self.match('=')) .Greater_or_Equal else .Greater;
            },
            '(' => {
                self.index += 1;
                result.tag = .Open_Paren;
            },
            ')' => {
                self.index += 1;
                result.tag = .Close_Paren;
            },
            '{' => {
                switch (self.mode) {
                    .Interpolation => {
                        self.index += 1;
                        result.tag = .Inter_Open;
                    },
                    else => {
                        self.index += 1;
                        result.tag = .Open_Brace;
                    }
                }
            },
            '}' => {
                switch (self.mode) {
                    .Interpolation => {
                        self.index += 1;
                        self.mode = .String;
                        result.tag = .Inter_Close;
                    },
                    else => {
                        self.index += 1;
                        result.tag = .Close_Brace;
                    }
                }
            },
            ':' => {
                self.index += 1;
                result.tag = .Colon;
                self.mode = .String;
            },
            '~' => {
                self.index += 1;
                result.tag = .Tilde;
            },
            '#' => {
                self.index += 1;
                result.tag = .Hash;
            },
            '_' => {
                self.index += 1;
                result.tag = .Underscore;
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
                result.tag = .Number;
            },
            else => {
                self.index += 1;
                result.tag = .Invalid;
            }
        }

        self.line_start = false;
        result.end = self.index;
        return result;
    }
};
