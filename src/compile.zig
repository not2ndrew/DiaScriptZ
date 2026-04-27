const std = @import("std");
const Ast = @import("ast.zig");
const Semantic = @import("semantic.zig").Semantic;
const Sink = @import("diagnostic.zig").DiagnosticSink;

const Io = std.Io;
const Init = std.process.Init;
const Allocator = std.mem.Allocator;
const DelimiterError = std.Io.Reader.DelimiterError;

pub fn compileFile(init: Init, allocator: Allocator, file_name: []const u8) !void {
    const lines = try readFile(init, allocator, file_name);
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
fn readFile(init: Init, allocator: Allocator, file_name: []const u8) ![]const u8 {
    const io = init.io;
    var read_buf: []u8 = undefined;

    const file = try Io.Dir.cwd().openFile(io, file_name, .{});
    defer file.close(io);

    const length = try file.length(io);
    if (length == 0) return DelimiterError.ReadFailed;

    read_buf = try allocator.alloc(u8, length);

    var reader = Io.File.Reader.init(file, io, read_buf);
    const reader_inter: *Io.Reader = &reader.interface;

    while (reader_inter.takeDelimiterInclusive('\n')) |_| {} else |err| {
        if (err != DelimiterError.EndOfStream) {
            std.debug.print("An Error has occurred {}", .{err});
        }
    }

    return read_buf[0..reader.pos];
}
