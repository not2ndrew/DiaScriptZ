const std = @import("std");
const token = @import("token.zig");

const Allocator = std.mem.Allocator;

const Token = token.Token;
const keywords = token.keywords;

const isAlphabetic = std.ascii.isAlphabetic;
const isDigit = std.ascii.isDigit;

const Mode = enum {
    normal,
    string,
    interpolation,
};

pub const Tokenizer = @This();

allocator: Allocator,
newline_bytes: *std.ArrayList(usize),
buffer: []const u8,
index: usize = 0,
mode: Mode = .normal,
line_start: bool = true,
// implicit semi colons are handled similarly to Go's implicit semi colon rules.
// https://github.com/golang/go/blob/master/src/go/scanner/scanner.go
insert_semi: bool = false,

fn isIdentChar(c: u8) bool {
    return isAlphabetic(c) or isDigit(c) or c == '_';
}

fn consumeNewline(self: *Tokenizer) !void {
    try self.newline_bytes.append(self.allocator, self.index);

    self.index += 1;
    self.line_start = true;
    self.mode = .normal;
}

fn skipWhiteSpace(self: *Tokenizer) !void {
    while (self.index < self.buffer.len) {
        switch (self.buffer[self.index]) {
            ' ', '\r', '\t' => self.index += 1,

            '\n' => {
                // If this newline represents an implicit semicolon,
                // leave it for next() to emit as a token.
                if (self.insert_semi) return;

                try self.consumeNewline();
            },

            else => return,
        }
    }
}

fn findStr(self: *Tokenizer) !Token {
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
            // Record the string first, then find newline afterwards.
            '\n' => {
                self.mode = .normal;
                self.line_start = true;
                break;
            },
            else => self.index += 1,
        }
    }

    self.insert_semi = true;

    return .{
        .tag = .string,
        .start = start,
        .end = self.index,
    };
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

pub fn next(self: *Tokenizer) !Token {
    const buffer = self.buffer;
    const len = buffer.len;

    try self.skipWhiteSpace();

    var insert_semi = false;
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

    const start = self.index;
    const ch = self.buffer[start];

    if (self.mode == .string) return self.findStr();
    self.index += 1;
    switch (ch) {
        '\n' => {
            // Implicit semi_colon
            try self.newline_bytes.append(self.allocator, start);
            result.tag = .semi_colon;
            self.line_start = true;
            self.mode = .normal;
        },
        '+' => {
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
            insert_semi = true;
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
                    self.mode = .normal;
                    result.tag = .inter_close;
                },
                else => {
                    result.tag = .close_brace;
                }
            }

            insert_semi = true;
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

                // keyword "end" is required to have an implicit semi colon.
                if (uniqueId == .keyword_end) insert_semi = true;
            } else {
                result.tag = .identifier;
                insert_semi = true;
            }
        },
        '0' ... '9' => {
            while (self.index < len and isDigit(buffer[self.index])) {
                self.index += 1;
            }
            result.tag = .number;
            insert_semi = true;
        },
        else => {
            result.tag = .invalid;
        }
    }

    if (result.tag != .semi_colon) self.line_start = false;

    self.insert_semi = insert_semi; // Preserve self.insert_semi info.
    result.end = self.index;
    return result;
}
