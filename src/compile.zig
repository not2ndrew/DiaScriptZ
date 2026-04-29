const std = @import("std");
const Ast = @import("ast.zig");
const Semantic = @import("semantic.zig").Semantic;
const Sink = @import("diagnostic.zig").DiagnosticSink;

const Io = std.Io;
const Init = std.process.Init;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const DelimiterError = std.Io.Reader.DelimiterError;

pub fn compileFile(init: Init, allocator: Allocator, file_name: []const u8) !void {
    var arena = Arena.init(allocator);
    defer arena.deinit();

    var a = arena.allocator();

    // ===== READ FILE =====
    const io = init.io;
    var lines: []u8 = undefined;

    const file = try Io.Dir.cwd().openFile(io, file_name, .{});
    defer file.close(io);

    const length = try file.length(io);
    if (length == 0) return DelimiterError.ReadFailed;

    lines = try a.alloc(u8, length);

    var reader = Io.File.Reader.init(file, io, lines);
    const reader_inter: *Io.Reader = &reader.interface;

    while (reader_inter.takeDelimiterInclusive('\n')) |_| {} else |err| {
        if (err != DelimiterError.EndOfStream) {
            std.debug.print("An Error has occurred {}", .{err});
        }
    }

    // ===== PHASES =====
    const ast = try Ast.parse(a, lines);

    // var semantic = Semantic.init(
    //     allocator, lines, ast.nodes,
    //     ast.tokens, &ast.errors
    // );
    // defer semantic.deinit();
    //
    // try semantic.analyze();

    var sink = Sink.init(lines, ast.errors.items);
    sink.printErrors(file_name);
}

