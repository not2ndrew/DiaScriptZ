const std = @import("std");
const tok = @import("token.zig");

const Token = tok.Token;
const TokenIndex = tok.TokenIndex;

pub const SourceFile = @This();

source: []const u8,
tokens: std.MultiArrayList(Token).Slice,

pub fn tokenSlice(sf: *const SourceFile, index: TokenIndex) []const u8 {
    const token = sf.tokens.get(index);
    return sf.source[token.start .. token.end];
}
