const std = @import("std");
const zig_node = @import("node.zig");
const tok = @import("token.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const Nodes = std.MultiArrayList(Node);
const NodeIndex = zig_node.NodeIndex;

const Token = tok.Token;
const Tokens = std.MultiArrayList(Token);
const TokenIndex = tok.TokenIndex;
const TokenTag = tok.Tag;

pub const Error = struct {
    token_pos: TokenIndex,
    tag: Tag,
    extra: Extra = .{ .none = {} },

    pub const Tag = enum {
        // Parsing Errors
        expected_expr,
        expected_arith_op,
        expected_compar_op,
        expected_dialogue,

        // Semantic Errors
        int_overflow,
        ident_mismatch,
        duplicate_var,
        duplicate_label,
        undeclared_var,
        undeclared_label,
        modified_const,
    };

    pub const Extra = union {
        none: void,
        expected_tag: TokenTag,
    };
};

pub const Ast = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: std.MultiArrayList(Token).Slice,
    nodes: std.MultiArrayList(Node).Slice,

    errors: std.ArrayList(Error),
    line_starts: []usize,

    /// It is best to deinitalize at the end of semantic analysis.
    pub fn deinit(self: *Ast) void {
        for (0..self.nodes.len) |i| {
            const node = self.nodes.get(i);
            switch (node.tag) {
                .block => self.allocator.free(node.data.block),
                else => {},
            }
        }

        self.nodes.deinit(self.allocator);
        self.tokens.deinit(self.allocator);
        self.errors.deinit(self.allocator);
        self.allocator.free(self.line_starts);
    }

    pub fn printErrors(self: *Ast, file_name: []const u8) void {
        for (self.errors.items) |err| {
            const token = self.tokens.get(err.token_pos);
            const msg = errorMessage(err.tag);
            const pos = self.getLineCol(token.start);
            const line_slice = getLineSlice(self.source, token.start);

            // Caret indicator for error
            var buf: [30]u8 = undefined;
            const spaces = buf[0..@min(pos.col, buf.len)];
            @memset(spaces, ' ');

            std.debug.print(
                \\{s}:{d}:{d} error: {s}
                \\     |
                \\{d: >4} | {s}
                \\     |{s}^
                \\
                ,
                .{
                    file_name, pos.line, pos.col, msg, 
                    pos.line, line_slice,
                    spaces
                }
            );
        }
    }

    // TODO: this is O(n)
    // where n = num_of_errs * source_size
    //
    // Store an array of line_starts
    // then binary search containing byte_pos.
    // Compute columns as byte_pos - line_start.
    // Should become O(log n)
    //
    // line_start is a byte_pos after a newline.
    fn getLineCol(self: *Ast, byte_pos: usize) struct { line: usize, col: usize } {
        const source = self.source;
        var line: usize = 1;
        var col: usize = 1;

        var i: usize = 0;
        while (i < byte_pos and i < source.len) {
            if (source[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }

            i += 1;
        }

        return .{ .line = line, .col = col };
    }
};

/// Make sure to deinit() nodes, stmts, and tokens
pub fn parse(allocator: Allocator, buf: []const u8) !Ast {
    var tokens: Tokens = .empty;
    defer tokens.deinit(allocator);

    // lines => tokens
    var tokenizer = Tokenizer.init(buf, allocator);

    while (true) {
        const token = tokenizer.next();
        try tokens.append(allocator, token);
        if (token.tag == .EOF) break;
    }

    const line_starts = try tokenizer.line_starts.toOwnedSlice(allocator);

    return parseFromTokens(allocator, buf, tokens.toOwnedSlice(), line_starts);
}

fn parseFromTokens(allocator: Allocator, buf: []const u8, tokens: Tokens.Slice, line_starts: []usize) !Ast {
    var parser = try Parser.init(allocator, tokens);

    // tokens => AST of stmt nodes
    try parser.parseAll();

    // Converting to slice removes all excess memory in nodes and stmts.
    return .{
        .allocator = allocator,
        .source = buf,
        .tokens = tokens,
        .nodes = parser.nodes.toOwnedSlice(),
        .errors = parser.errors,
        .line_starts = line_starts,
    };
}

fn getLineSlice(source: []const u8, byte_pos: usize) []const u8 {
    var pos = byte_pos;

    if (pos >= source.len and source.len > 0) {
        pos = source.len - 1;
    }

    var start = pos;
    var end = pos;

    while (start > 0 and source[start - 1] != '\n') {
        start -= 1;
    }

    while (end < source.len and source[end] != '\n') {
        end += 1;
    }

    return source[start..end];
}

fn errorMessage(tag: Error.Tag) []const u8 {
    return switch(tag) {
        // Parsing Errors
        .expected_expr => "Expected expression",
        .expected_arith_op => "Expected arithmetic operator",
        .expected_compar_op => "Expected comparison operator",
        .expected_dialogue => "Expected dialogue",

        // Semantic Errors
        .int_overflow => "Integer overflow",
        .ident_mismatch => "Identifier mismatch",
        .duplicate_var => "Duplicate variable",
        .duplicate_label => "Duplicate label",
        .undeclared_label => "Label not declared",
        .undeclared_var => "Variable not declared",
        .modified_const => "Modified const",
    };
}
