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

pub const Tokenizer = @This();

allocator: Allocator,
offsets: *std.ArrayList(usize),
buffer: []const u8,
index: usize,
mode: Mode,
line_start: bool,

pub fn init(allocator: Allocator, offsets: *std.ArrayList(usize), buffer: []const u8) Tokenizer {
    return .{
        .allocator = allocator,
        .offsets = offsets,
        .buffer = buffer,
        .index = 0,
        .mode = .normal,
        .line_start = true,
    };
}

fn skipWhiteSpace(self: *Tokenizer) !void {
    while (self.index < self.buffer.len) {
        switch (self.buffer[self.index]) {
            ' ', '\r', '\t' => self.index += 1,
            '\n' => {
                try self.offsets.append(self.allocator, self.index);
                self.index += 1;
                self.line_start = true;
                self.mode = .normal;
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
            '\n' => {
                try self.offsets.append(self.allocator, self.index);
                self.mode = .normal;
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

    if (result.tag != .newline) self.line_start = false;
    result.end = self.index;
    return result;
}

fn isIdentChar(c: u8) bool {
    return isAlphabetic(c) or isDigit(c) or c == '_';
}
