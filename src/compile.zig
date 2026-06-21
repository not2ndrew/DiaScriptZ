const std = @import("std");
const tree = @import("ast.zig");
const Semantic = @import("semantic.zig").Semantic;
const diag = @import("diagnostic.zig");

const Io = std.Io;
const Init = std.process.Init;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const DelimiterError = std.Io.Reader.DelimiterError;

const DiagRenderer = diag.DiagRenderer;

pub fn compileFile(init: Init, allocator: Allocator, file_name: []const u8) !void {
    // ===== ARENA ALLOCATOR =====

    // ===== GENERIC ALLOCATOR =====
    const lines = try readFile(init, allocator, file_name);
    defer allocator.free(lines);

    // Generate AST from lines
    var parse_tree = try tree.parse(allocator, lines);
    defer parse_tree.deinit(allocator);

    // Analyze AST
    var semantic = Semantic.init(
        allocator, parse_tree.source_file.source,
        &parse_tree.ast, &parse_tree.errors
    );
    defer semantic.deinit();

    try semantic.analyze();

    // Diagnostics
    var renderer: DiagRenderer = .{
        .source_file = parse_tree.source_file,
        .tokens = parse_tree.ast.tokens,
    };

    const errors = try parse_tree.errors.toOwnedSlice(allocator);
    defer allocator.free(errors);
    try renderer.printErrors(errors, allocator, file_name);
}

/// Make sure to free the []const u8 result!!!
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
