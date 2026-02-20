const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");

const Tag = tok.Tag;

const NodeIndex = zig_node.NodeIndex;
const invalid_node = zig_node.invalid_node;

const Allocator = std.mem.Allocator;

pub const unexpected_token = struct {
    expected: Tag,
    found: Tag,
};

pub const DiagnosticError = union(enum) {
    unexpected_token: struct {
        expected: Tag,
        found: Tag,
    },
    undetermined_string,
    // Programming Errors
    int_overflow,
    int_underflow,
    undeclared_var,
    duplicate_var,
    modified_const,

    // Dialogue Errors
    duplicate_var_dialogue,
    undeclared_dialogue_block,
    ambiguous_jump,
};

pub const Severity = enum {
    err,
    warning,
    note,
};

pub const Diagnostic = struct {
    severity: Severity,
    err: DiagnosticError,
    start: u32,
    end: u32,
    node_index: NodeIndex = invalid_node,
};

pub const DiagnosticSink = struct {
    allocator: Allocator,
    source: []const u8,
    list: std.ArrayList(Diagnostic),

    pub fn init(allocator: Allocator, source: []const u8) DiagnosticSink {
        return .{
            .allocator = allocator,
            .source = source,
            .list = .{},
        };
    }

    pub fn deinit(self: *DiagnosticSink) void {
        self.list.deinit(self.allocator);
    }

    pub fn report(self: *DiagnosticSink, diag: Diagnostic) !void {
        try self.list.append(self.allocator, diag);
    }

    pub fn printErrors(self: *DiagnosticSink, file_name: []const u8) void {
        for (self.list.items) |diag| {
            const message = getErrorMessage(diag.err);
            const line_slice = self.getLineSlice(diag.start);
            const pos = self.getLineCol(diag.start);

            std.debug.print(
                \\error: {s}
                \\ --> {s}, line: {d}, col: {d}
                \\     |
                \\{d:4} | {s}
                \\     |
                ,
                .{
                    message,
                    file_name, pos.line, pos.col,
                    pos.line, line_slice
                }
            );
            // TODO: Repeatedly printing a singular space is bad.
            var i: usize = 0;
            while (i < pos.col) : (i += 1) {
                std.debug.print(" ", .{});
            }

            if (diag.severity == .note) {
                const token = diag.err.unexpected_token;
                std.debug.print(
                    "^\n --> Expected {t}, Found {t}\n\n",
                    .{token.expected, token.found}
                );
            } else {
                std.debug.print("^\n\n", .{});
            }

        }
    }

    fn getErrorMessage(err: DiagnosticError) []const u8 {
        return switch (err) {
            .undeclared_var => "use of undeclared variable",
            .duplicate_var => "duplicate variable declaration",
            .modified_const => "cannot modify constant",
            .int_overflow => "integer overflow",
            .int_underflow => "integer underflow",
            .undeclared_dialogue_block => "use of undeclared dialogue block",
            .ambiguous_jump => "dialogue jumps too ambiguous",
            .duplicate_var_dialogue => "duplicate dialogue and declaration",
            else => "unknown error",
        };
    }

    // TODO: Search for every '\n' during init,
    // then binary search line num,
    // then compute column = byte_pos - line num
    //
    // The reason is there are x * y total bytes to scan
    // where x is col and y is line
    fn getLineCol(self: *DiagnosticSink, byte_pos: usize) struct { line: usize, col: usize } {
        var line: usize = 0;
        var col: usize = 1;

        var i: usize = 0;
        while (i < byte_pos and i < self.source.len) {
            if (self.source[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }

            i += 1;
        }

        return .{ .line = line, .col = col };
    }

    fn getLineSlice(self: *DiagnosticSink, byte_pos: usize) []const u8 {
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
