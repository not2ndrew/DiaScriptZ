const std = @import("std");
const zig_node = @import("node.zig");
const tok = @import("token.zig");
const Tokenizer = @import("tokenizer.zig").Tokenizer;
const Parser = @import("parser.zig").Parser;

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

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
        unexpected_EOF,
        unexpected_token,
        expected_ident,
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
    // extra_data holds:
    // 1) Variable-length AST payload storage
    // 2) Stores continuous ranges of NodeIndex values referenced by nodes.
    extra_data: []u32,

    errors: std.ArrayList(Error),
    line_starts: []usize,

    /// It is best to deinitalize at the end of semantic analysis.
    pub fn deinit(self: *Ast) void {
        self.tokens.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.errors.deinit(self.allocator);

        self.allocator.free(self.extra_data);
        self.allocator.free(self.line_starts);
    }

    pub fn printErrors(self: *Ast, file_name: []const u8) !void {
        var alloc_write = Writer.Allocating.init(self.allocator);
        defer alloc_write.deinit();
        const writer = &alloc_write.writer;

        for (self.errors.items) |err| {
            const token = self.tokens.get(err.token_pos);
            try self.errorMessage(writer, err);
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
                    file_name, pos.line, pos.col, writer.buffer, 
                    pos.line, line_slice,
                    spaces
                }
            );

            alloc_write.clearRetainingCapacity();
        }
    }

    fn getLineCol(self: *Ast, byte_pos: usize) struct { line: usize, col: usize } {
        const line_starts = self.line_starts;
        var low: usize = 0;
        var high: usize = line_starts.len;
        var line_idx: usize = 0;

        // Testing new binary search approach.
        while (low < high) {
            // Avoid overflow
            const mid = low + (high - low) / 2;
            const value = line_starts[mid];

            if (value <= byte_pos) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        line_idx = low - 1;
        const line = line_idx + 1;
        const col = byte_pos - line_starts[line_idx] + 1;

        return .{ .line = line, .col = col };
    }

    fn errorMessage(self: *Ast, w: *Writer, err: Error) Writer.Error!void {
        const token = self.tokens.get(err.token_pos);
        const str = self.source[token.start..token.end];
        switch (err.tag) {
            // Parsing Errors
            .unexpected_EOF => {
                return w.writeAll("Expected expression, found EOF");
            },
            .unexpected_token => {
                return w.print("Expected expression, found '{s}'", .{str});
            },
            .expected_ident => {
                return w.print("Expected identifier, found '{s}'", .{str});
            },
            .expected_arith_op => {
                return w.print("Expected arithmetic operator, found '{s}'", .{str});
            },
            .expected_compar_op => {
                return w.print("Expected comparison operator, found '{s}'", .{str});
            },
            .expected_dialogue => {
                return w.print("Expected dialogue, found '{s}'", .{str});
            },

            // Semantic Errors
            .int_overflow => {
                return w.writeAll("Integer overflow");
            },
            .ident_mismatch => {
                return w.print("TODO: Write error for '{s}'", .{str});
            },
            .duplicate_var => {
                return w.print("Variable '{s}' already exist", .{str});
            },
            .undeclared_var => {
                return w.print("Variable '{s}' not declared", .{str});
            },
            .duplicate_label => {
                return w.print("Label '{s}' already exist", .{str});
            },
            .undeclared_label => {
                return w.print("Label '{s}' not declared", .{str});
            },
            .modified_const => {
                return w.print("Cannot modify constant '{s}'", .{str});
            },
            // else => {
            //     return w.print("Test msg", .{});
            // }
        }
    }
};

/// Make sure to deinit() nodes, stmts, and tokens
pub fn parse(allocator: Allocator, buf: []const u8) !Ast {
    var tokens: Tokens = .empty;
    defer tokens.deinit(allocator);

    // lines => tokens
    var tokenizer = try Tokenizer.init(buf, allocator);

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
    _ = try parser.parseAll();

    // Converting to slice removes all excess memory in nodes and stmts.
    return .{
        .allocator = allocator,
        .source = buf,
        .tokens = tokens,
        .nodes = parser.nodes.toOwnedSlice(),
        .extra_data = try parser.extra_data.toOwnedSlice(allocator),
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
