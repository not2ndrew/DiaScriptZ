const std = @import("std");
const frontend = @import("frontend");

const SourceFile = frontend.source_file.SourceFile;

const tok = frontend.token;

const Token = tok.Token;
const TokenIndex = tok.Token;
const lexeme = tok.lexeme;
const Ast = frontend.ast.Ast;

const Tokens = std.MultiArrayList(Token).Slice;

const Allocator = std.mem.Allocator;

pub const String = u32;
// TESTING ERROR DIAGNOSTICS HERE.
// We can't rely on TokenIndex for diagnostic. So handle the token span and
// error message in AST. Then take those values and convert them to SourceLocation.
// SourceLocation should be stored independently. Therefore, it must be a module.
//
// Instead of using std.debug.print() to create my format,
// I could simply build my format using std.Io.Writer.
pub const ErrorMessage = struct {
    source_idx: String,
    error_idx: String,
    line: u32,
    col: u32,
};

pub const LineInfo = struct {
    line: u32,
    col: u32,
    slice: []const u8,
};

pub const ErrorBundle = @This();

allocator: Allocator,
source_file: SourceFile,
// String bytes store the source string line.
string_bytes: std.ArrayList(u8) = .empty,
// err bytes store the error message
err_bytes: std.ArrayList(u8) = .empty,
// TODO: notes is used as indices for error message notes.
// notes: std.ArrayList(u8) = .empty,
errors: std.ArrayList(ErrorMessage) = .empty,

pub fn deinit(eb: *ErrorBundle) void {
    eb.string_bytes.deinit(eb.allocator);
    eb.err_bytes.deinit(eb.allocator);
    eb.errors.deinit(eb.allocator);
}

fn addSourceString(eb: *ErrorBundle, slice: []const u8) !String {
    const len: String = @intCast(eb.string_bytes.items.len);
    // Use len + 1 to ensure 0 is added to the end of every slice.
    try eb.string_bytes.ensureUnusedCapacity(eb.allocator, len + 1);
    eb.string_bytes.appendSliceAssumeCapacity(slice);
    eb.string_bytes.appendAssumeCapacity(0);

    return len;
}

fn addErrorString(eb: *ErrorBundle, slice: []const u8) !String {
    const len: String = @intCast(eb.err_bytes.items.len);

    // Use len + 1 to ensure 0 is added to the end of every slice.
    try eb.err_bytes.ensureUnusedCapacity(eb.allocator, slice.len + 1);
    eb.err_bytes.appendSliceAssumeCapacity(slice);
    eb.err_bytes.appendAssumeCapacity(0);

    return len;
}

fn getLineInfo(eb: *ErrorBundle, byte_pos: usize) LineInfo {
    const source = eb.source_file.source;
    var line: u32 = 1;
    var line_start: u32 = 0;

    var i: u32 = 0;
    while (i < byte_pos and i < source.len) : (i += 1) {
        if (source[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }

    const line_end = std.mem.findScalarPos(u8, source, line_start, '\n')
        orelse source.len;

    return .{
        .line = @intCast(line),
        .col = @intCast(byte_pos - line_start + 1),
        .slice = source[line_start .. line_end],
    };
}

pub fn addAstErrorMessages(eb: *ErrorBundle, errors: []Ast.Error) !void {
    var msg: std.Io.Writer.Allocating = .init(eb.allocator);
    defer msg.deinit();

    const msg_w = &msg.writer;

    for (errors) |err| {
        try astErrorMessage(&eb.source_file, msg_w, err);
        const err_idx = try eb.addErrorString(msg.written());

        const token = eb.source_file.tokens.get(err.token_pos);
        const line_info = eb.getLineInfo(token.start);

        const source_idx = try eb.addSourceString(line_info.slice);
        try eb.errors.append(eb.allocator, .{
            .source_idx = source_idx,
            .error_idx = err_idx,
            .line = line_info.line,
            .col = line_info.col,
        });

        msg.clearRetainingCapacity();
    }
}

// This is where I actually print errors.
// Note that Parsing and Semantic Errors are handled separately.
// So we need two different functions to handle both of them.
// Use this function to converge both of them.
pub fn renderToStderr(eb: *ErrorBundle, io: std.Io, file_path: []const u8) !void {
    var diagnostic = try eb.toOwnDiagnostic();
    defer diagnostic.deinit(eb.allocator);

    var buffer: [100]u8 = undefined;
    const stderr = try io.lockStderr(&buffer, std.zig.Color.terminalMode(.off));
    defer io.unlockStderr();

    const writer = stderr.terminal().writer;

    for (diagnostic.errors) |err| {
        const message = diagnostic.getErrorString(err.error_idx);
        try writer.print("{s}:{d}:{d} error: {s}\n", .{ file_path, err.line, err.col, message});
        try writer.writeAll("    |\n");

        const source_line = diagnostic.getSourceString(err.source_idx);
        try writer.print("{d: >3} | {s}\n", .{ err.line, source_line });

        const before_caret = err.col;
        try writer.writeAll("    |");
        try writer.splatByteAll(' ', before_caret);
        try writer.writeByte('^');
        try writer.writeByte('\n');
    }

    try writer.flush();
}

// Convert ErrorBundle to Diagnostic and render error message from there.
fn toOwnDiagnostic(eb: *ErrorBundle) !Diagnostic {
    return .{
        .string_bytes = try eb.string_bytes.toOwnedSlice(eb.allocator),
        .err_bytes = try eb.err_bytes.toOwnedSlice(eb.allocator),
        .errors = try eb.errors.toOwnedSlice(eb.allocator),
    };
}

pub const Diagnostic = struct {
    string_bytes: []const u8,
    err_bytes: []const u8,
    errors: []ErrorMessage,

    fn deinit(dia: *Diagnostic, allocator: Allocator) void {
        allocator.free(dia.string_bytes);
        allocator.free(dia.err_bytes);
        allocator.free(dia.errors);
    }

    fn getSourceString(dia: *Diagnostic, start: String) []const u8 {
        const string_bytes = dia.string_bytes;
        var end: String = start;

        while (end < string_bytes.len and string_bytes[end] != 0) {
            end += 1;
        }

        return dia.string_bytes[start .. end];
    }

    fn getErrorString(dia: *Diagnostic, start: String) []const u8 {
        const err_bytes = dia.err_bytes;
        var end: String = start;

        while (end < err_bytes.len and err_bytes[end] != 0) {
            end += 1;
        }

        return dia.err_bytes[start .. end];
    }
};

pub fn astErrorMessage(sf: *SourceFile, w: *std.Io.Writer, err: Ast.Error) std.Io.Writer.Error!void {
    const found = sf.tokenSlice(err.token_pos);
    switch (err.tag) {
        .unexpected_EOF => {
            return w.writeAll("Expected expression, found EOF");
        },
        .expected_token => {
            const expected_token = sf.tokens.get(err.token_pos);
            const expected = lexeme(err.data.expected)
                orelse sf.source[expected_token.start .. expected_token.end];
            return w.print("Expected '{s}', found '{s}'", .{expected, found});
        },
        .expected_ident => {
            return w.print("Expected identifier, found '{s}'", .{found});
        },
        .expected_expr => {
            return w.writeAll("Expected number or identifier");
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
    }
}
