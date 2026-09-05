const std = @import("std");
const tok = @import("token.zig");

const Token = tok.Token;
const TokenIndex = tok.TokenIndex;

pub const SourceFile = @This();

source: []const u8,
tokens: std.MultiArrayList(Token).Slice,

pub fn getToken(sf: *SourceFile, index: TokenIndex) Token {
    return sf.tokens.get(index);
}

pub fn tokenSlice(sf: *SourceFile, index: TokenIndex) []const u8 {
    const token = sf.tokens.get(index);
    return sf.source[token.start .. token.end];
}
