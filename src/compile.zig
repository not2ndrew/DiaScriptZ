const std = @import("std");
const Ast = @import("ast.zig");
const Semantic = @import("semantic.zig").Semantic;

const Io = std.Io;
const Init = std.process.Init;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const DelimiterError = std.Io.Reader.DelimiterError;

pub fn compileFile(init: Init, allocator: Allocator, file_name: []const u8) !void {
    // ===== ARENA ALLOCATOR =====

    // ===== GENERIC ALLOCATOR =====
    const lines = try readFile(init, allocator, file_name);
    defer allocator.free(lines);

    var ast = try Ast.parse(allocator, lines);
    defer ast.deinit();

    // for (ast.tokens.items(.tag)) |tag| {
    //     std.debug.print("Tag: {t}\n", .{tag});
    // }

    // TODO: The following lines cause an infinite loop:
    // ~ Name
    // foo: Hello World
    // end
    var semantic = Semantic.init(
        allocator, lines, ast.nodes,
        ast.tokens, ast.extra_data, &ast.errors
    );
    defer semantic.deinit();

    try semantic.analyze();

    try ast.printErrors(file_name);
}

/// Make sure to free memory!!!
fn readFile(init: Init, allocator: Allocator, file_name: []const u8) ![]const u8 {
    const io = init.io;
    var lines: []u8 = undefined;

    const file = try Io.Dir.cwd().openFile(io, file_name, .{});
    defer file.close(io);

    const length = try file.length(io);
    if (length == 0) return DelimiterError.ReadFailed;

    lines = try allocator.alloc(u8, length);

    var reader = Io.File.Reader.init(file, io, lines);
    const reader_inter: *Io.Reader = &reader.interface;
    const EndOfStream = DelimiterError.EndOfStream;

    while (reader_inter.takeDelimiterInclusive('\n')) |_| {} else |err| {
        if (err != EndOfStream) {
            std.debug.print("An Error has occurred {}", .{err});
        }
    }

    return lines;
}
