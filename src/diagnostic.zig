const std = @import("std");
const zig_node = @import("node.zig");
const tok = @import("token.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Token = tok.Token;
const TokenTag = tok.Tag;
const TokenIndex = tok.TokenIndex;
const Tokens = std.MultiArrayList(Token);

// TODO:
// 1) Move diagnostics into AST errors
// Rather than a single diagnostic covers all types of errors.
// We split the errors into two different types:
//     1. Comptime (syntax, parsing) errors
//     2. Runtime errors.
// 2) Add extra union field to AstError (formerly Error)
// Since we are moving diagnostics to AST, might as well call it AstError.
// And, create a separate diagnostics for runtime.
//
// The concern I had was the union field was
// 1) Wasted space when continuing to use void as union for Semantic errors.
// 2) More clarity.
pub const Error = struct {
    token_pos: TokenIndex,
    tag: Tag,

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
        // TODO: Create a note to where the ident is used
        // Note: Previous declaration here:
        ident_mismatch,
        duplicate_var,
        duplicate_label,
        undeclared_var,
        unknown_jump,
        modified_const,
        too_many_scopes,
    };
};

pub const SourceFile = struct {
    source: []const u8,
    offsets: []usize,

    pub fn getLineCol(self: *SourceFile, byte_pos: usize) struct { line: usize, col: usize } {
        const offsets = self.offsets;
        var low: usize = 0;
        var high: usize = offsets.len;

        // Since the array of offset bytes is sorted, we can do binary search.
        while (low < high) {
            // Avoid overflow
            const mid = low + (high - low) / 2;
            const value = offsets[mid];

            if (value < byte_pos) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }

        // Start the line at 1
        const line = low + 1;
        const line_start_offset = if (low == 0)
            0
        else
            offsets[low - 1] + 1;
        const col = byte_pos - line_start_offset + 1;

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

    // TODO: Sometimes, the spaces are not included.
    // Maybe this is due to the zig build?
    //
    // Code:
    // ---------
    // var x = 1
    // if (x > 1) {
    //    var x = 2
    // }
    // ---------
    // Diagnostics:
    // script.txt:3:5 error: Variable 'x' already exist
    //      |
    //    3 | var x = 2
    //      | ^
    //
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

    // TODO: Create a lexeme function for token
    // Many tokens can be determined entirely by their tag.
    // Then use that []const u8 value and print it out.
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
                return w.writeAll("Integer cannot go beyond 256");
            },
            .ident_mismatch => {
                return w.print("'{s}' is already defined as a INSERT_TYPE", .{str});
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
            .unknown_jump => {
                return w.print("Jump target '{s}' does not exist.", .{str});
            },
            .modified_const => {
                return w.print("Cannot modify constant '{s}'", .{str});
            },
            .too_many_scopes => {
                return w.writeAll("Cannot generate more than 3 scopes");
            }
        }
    }
};
