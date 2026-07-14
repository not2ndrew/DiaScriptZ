const std = @import("std");
const zig_node = @import("node.zig");
const tok = @import("token.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Token = tok.Token;
const TokenTag = tok.Tag;
const TokenIndex = tok.TokenIndex;
const Tokens = std.MultiArrayList(Token);

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

pub const SourceFile = struct {
    source: []const u8,
    line_starts: []usize,

    pub fn getLineCol(self: *SourceFile, byte_pos: usize) struct { line: usize, col: usize } {
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

    pub fn getLineSlice(self: *SourceFile, byte_pos: usize) []const u8 {
        var pos = byte_pos;

        if (pos >= self.source.len and self.source.len > 0) {
            pos = self.source.len - 1;
        }

        var start = pos;
        var end = pos;

        while (start > 0 and self.source[start - 1] != '\n') {
            start -= 1;
        }

        while (end < self.source.len and self.source[end] != '\n') {
            end += 1;
        }

        return self.source[start..end];
    }
};

pub const DiagRenderer = struct {
    source_file: SourceFile,
    tokens: Tokens.Slice,

    pub fn printErrors(
        self: *DiagRenderer,
        errors: []const Error,
        allocator: Allocator,
        file_name: []const u8,
    ) !void {
        var alloc_write = Writer.Allocating.init(allocator);
        defer alloc_write.deinit();
        const writer = &alloc_write.writer;

        for (errors) |err| {
            const token = self.tokens.get(err.token_pos);
            try self.errorMessage(writer, err);
            const pos = self.source_file.getLineCol(token.start);
            const line_slice = self.source_file.getLineSlice(token.start);

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

    fn errorMessage(self: *DiagRenderer, w: *Writer, err: Error) Writer.Error!void {
        const token = self.tokens.get(err.token_pos);
        const str = self.source_file.source[token.start..token.end];
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
                return w.print("Identifer '{s}' already taken", .{str});
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
        }
    }
};
