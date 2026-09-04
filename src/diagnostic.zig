const std = @import("std");
const frontend = @import("frontend");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Token = frontend.token.Token;
const TokenIndex = frontend.token.TokenIndex;
const lexeme = frontend.token.lexeme;

const Tokens = std.MultiArrayList(Token);

pub const Error = struct {
    token_pos: TokenIndex,
    tag: Tag,
    data: Data = .{ .none = {} },

    pub const Tag = enum {
        // Parsing Errors
        unexpected_EOF,
        expected_token,
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
        invalid_label_scope,
        too_many_choices,
    };

    pub const Kind = enum {
        constant,
        variable,
        speaker,
        label,
    };

    pub const Data = union {
        none: void,
        expected: Token.Tag,
        initialized: Kind,
    };
};

pub fn reportErrors(allocator: Allocator, errors: *std.ArrayList(Error), source_file: SourceFile, tokens: Tokens.Slice, file_name: []const u8) !void {
    const renderer: DiagRenderer = .{
        .source_file = source_file,
        .tokens = tokens,
    };

    // Diagnostics
    try renderer.printErrors(errors, allocator, file_name);
}

pub const SourceFile = struct {
    source: []const u8,
    newline_bytes: []usize,

    pub fn getLineCol(self: *const SourceFile, byte_pos: usize) struct { line: usize, col: usize } {
        const newline_bytes = self.newline_bytes;
        var low: usize = 0;
        var high: usize = newline_bytes.len;

        // Since the array of offset bytes is sorted, we can do binary search.
        while (low < high) {
            // Avoid overflow
            const mid = low + (high - low) / 2;
            const value = newline_bytes[mid];

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
            newline_bytes[low - 1] + 1;
        const col = byte_pos - line_start_offset + 1;

        return .{ .line = line, .col = col };
    }

    pub fn getLineSlice(self: *const SourceFile, byte_pos: usize) []const u8 {
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
        self: *const DiagRenderer,
        errors: *std.ArrayList(Error),
        allocator: Allocator,
        file_name: []const u8,
    ) !void {
        var alloc_write = Writer.Allocating.init(allocator);
        defer alloc_write.deinit();
        const writer = &alloc_write.writer;

        for (errors.items) |err| {
            const token = self.tokens.get(err.token_pos);
            try self.errorMessage(writer, err);
            const pos = self.source_file.getLineCol(token.start);
            const line_slice = self.source_file.getLineSlice(token.start);

            // Caret indicator for error
            var buf: [20]u8 = undefined;
            const spaces = buf[0 .. @min(pos.col, buf.len)];
            @memset(spaces, ' ');

            // TODO: Maybe consider a "helper diagnostic line"
            // For example, if there is an ident_mismatch,
            // we can point to where the original identifier was used.
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

    // TODO: Split parsing and semantic errors into two different functions.
    // Only parsing requires lexeme and semantic uses slice.
    fn errorMessage(self: *const DiagRenderer, w: *Writer, err: Error) Writer.Error!void {
        const token = self.tokens.get(err.token_pos);
        const slice = self.source_file.source[token.start .. token.end];
        const found = lexeme(token.tag);

        switch (err.tag) {
            // Parsing Errors
            .unexpected_EOF => {
                return w.writeAll("Expected expression, found EOF");
            },
            .expected_token => {
                const expected = lexeme(err.data.expected);
                return w.print("Expected '{s}', found '{s}'", .{expected, found});
            },
            .expected_ident => {
                return w.print("Expected identifier, found '{s}'", .{found});
            },
            .expected_arith_op => {
                return w.print("Expected arithmetic operator, found '{s}'", .{found});
            },
            .expected_compar_op => {
                return w.print("Expected comparison operator, found '{s}'", .{found});
            },
            .expected_dialogue => {
                return w.print("Expected dialogue, found '{s}'", .{found});
            },

            // Semantic Errors
            .int_overflow => {
                return w.writeAll("Integer cannot go beyond 256");
            },
            .ident_mismatch => {
                return w.print("'{s}' is already defined as {s}", .{slice, @tagName(err.data.initialized)});
            },
            .duplicate_var => {
                return w.print("Variable '{s}' already exist", .{slice});
            },
            .undeclared_var => {
                return w.print("Variable '{s}' not declared", .{slice});
            },
            .duplicate_label => {
                return w.print("Label '{s}' already exist", .{slice});
            },
            .unknown_jump => {
                return w.print("Jump target '{s}' does not exist.", .{slice});
            },
            .modified_const => {
                return w.print("Cannot modify constant '{s}'", .{slice});
            },
            .too_many_scopes => {
                return w.writeAll("Cannot generate more than 3 scopes");
            },
            .invalid_label_scope => {
                return w.print("Label '{s}' must be placed in GLOBAL scope", .{slice});
            },
            .too_many_choices => {
                return w.writeAll("Too many choices in a block");
            },
        }
    }
};
