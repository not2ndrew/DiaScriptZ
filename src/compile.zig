const std = @import("std");
const Ast = @import("ast.zig");
const Semantic = @import("semantic.zig").Semantic;
const Sink = @import("diagnostic.zig").DiagnosticSink;

const Allocator = std.mem.Allocator;
const DelimiterError = std.Io.Reader.DelimiterError;

pub fn compileFile(allocator: Allocator, file_name: []const u8) !void {
    const lines = try readFile(allocator, file_name);
    defer allocator.free(lines);

    var ast = try Ast.parse(allocator, lines);
    defer ast.deinit();
    defer ast.errors.deinit(allocator);

    var semantic = Semantic.init(
        allocator, lines, ast.stmts,
        ast.nodes, ast.tokens, &ast.errors
    );
    defer semantic.deinit();

    try semantic.analyze();

    var sink = Sink.init(lines, ast.errors.items);
    sink.printErrors(file_name);
}

/// Make sure to free memory from the string!!!
fn readFile(allocator: Allocator, file_name: []const u8) ![]const u8 {
    var read_buf: []u8 = undefined;

    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;

    if (size == 0) return DelimiterError.ReadFailed;

    read_buf = try allocator.alloc(u8, size);

    var reader = std.fs.File.Reader.init(file, read_buf);
    const reader_inter: *std.Io.Reader = &reader.interface;

    while (reader_inter.takeDelimiterInclusive('\n')) |_| {} else |err| {
        if (err != DelimiterError.EndOfStream) {
            std.debug.print("An Error has occurred {}", .{err});
        }
    }

    return read_buf[0..reader.pos];
}
