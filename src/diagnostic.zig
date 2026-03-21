const std = @import("std");
const zig_node = @import("node.zig");
const Tag = @import("token.zig").Tag;

const NodeIndex = zig_node.NodeIndex;
const invalid_node = zig_node.invalid_node;

const Allocator = std.mem.Allocator;

pub const DiagnosticError = union(enum) {
    unexpected_token: UnexpectedToken,
    simple: SimpleError,

    pub const UnexpectedToken = struct {
        expected: Tag,
        found: Tag,
    };

    pub const SimpleError = enum {
        undetermined_string,
        // Programming Errors
        int_overflow,
        int_underflow,
        undeclared_var,
        duplicate_var,
        modified_const,

        // Dialogue Errors
        duplicate_dialogue,
        undeclared_dialogue,
        ambiguous_jump,
    };

    pub fn message(err: DiagnosticError) []const u8 {
        return switch (err) {
            .unexpected_token => "unexpected token",
            .simple => |e| switch (e) {
                .undeclared_var => "use of undeclared variable",
                .duplicate_var => "duplicate variable name",
                .modified_const => "cannot modify constant",
                .int_overflow => "integer overflow",
                .int_underflow => "integer underflow",
                .undeclared_dialogue => "use of undeclared dialogue block",
                .ambiguous_jump => "dialogue jumps too ambiguous",
                .duplicate_dialogue => "duplicate dialogue struct name",
                .undetermined_string => "undetermined string",
            },
        };
    }

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
    list: []DiagnosticError,

    pub fn init(allocator: Allocator, source: []const u8, list: []Diagnostic) DiagnosticSink {
        return .{
            .allocator = allocator,
            .source = source,
            .list = list,
        };
    }

    pub fn report(self: *DiagnosticSink, diag: Diagnostic) !void {
        try self.list.append(self.allocator, diag);
    }

    pub fn printErrors(self: *DiagnosticSink, file_name: []const u8) void {
        for (self.list) |diag| {
            const line_slice = self.getLineSlice(diag.start);
            const pos = self.getLineCol(diag.start);

            std.debug.print(
                \\{s}:{d}:{d} error: {s}
                \\     |
                \\{d:4} | {s}
                \\     |
                ,
                .{
                    // message,
                    file_name, pos.line, pos.col, diag.err.message(),
                    pos.line, line_slice
                }
            );

            // Assume some amount of spaces in empty line
            var buf: [100]u8 = undefined;
            const spaces = buf[0..@min(pos.col, buf.len)];
            @memset(spaces, ' ');

            switch (diag.severity) {
                .note => {
                    const token = diag.err.unexpected_token;
                    std.debug.print(
                        "{s}^\n --> Expected {t}, Found {t}\n\n",
                        .{spaces, token.expected, token.found}
                    );
                },
                .warning => std.debug.print("{s}^\n", .{spaces}),
                .err => {},
            }
        }
    }

    // TODO: Search for every '\n' during init,
    // then binary search line num,
    // then compute column = byte_pos - line num
    //
    // The reason is there are x * y total bytes to scan
    // where x is col and y is line
    fn getLineCol(self: *DiagnosticSink, byte_pos: usize) struct { line: usize, col: usize } {
        var line: usize = 1;
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
