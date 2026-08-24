const std = @import("std");
const tree = @import("ast.zig");
const lower_ir = @import("lower.zig");
const diag = @import("diagnostic.zig");

const Io = std.Io;
const Init = std.process.Init;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const DelimiterError = std.Io.Reader.DelimiterError;

const ParseResult = tree.ParseResult;
const DiagRenderer = diag.DiagRenderer;

pub fn compileFile(init: Init, allocator: Allocator, file_name: []const u8) !void {
    const source = try readFile(init, allocator, file_name);
    defer allocator.free(source);

    // Generate AST from source
    // TODO: Make sure to free parse_tree AFTER code optimization is complete.
    var parse_tree = try tree.parse(allocator, source);
    defer parse_tree.deinit(allocator);

    if (parse_tree.errors.items.len > 0)
        return printErrors(&parse_tree, allocator, file_name);

    try lower_ir.lower(allocator, &parse_tree, &parse_tree.ast, &parse_tree.errors, file_name);

    try printErrors(&parse_tree, allocator, file_name);
}

/// Make sure to free the []const u8 result!!!
fn readFile(init: Init, allocator: Allocator, file_name: []const u8) ![]const u8 {
    const io = init.io;
    var source: []u8 = undefined;

    const file = try Io.Dir.cwd().openFile(io, file_name, .{});
    defer file.close(io);

    const length = try file.length(io);
    if (length == 0) return DelimiterError.ReadFailed;

    source = try allocator.alloc(u8, length);

    var reader = Io.File.Reader.init(file, io, source);
    const reader_inter: *Io.Reader = &reader.interface;
    const EndOfStream = DelimiterError.EndOfStream;

    while (reader_inter.takeDelimiterInclusive('\n')) |_| {} else |err| {
        if (err != EndOfStream) {
            std.debug.print("An Error has occurred {}", .{err});
        }
    }

    return source;
}

fn printErrors(parse_tree: *ParseResult, allocator: Allocator, file_name: []const u8) !void {
    const errors = try parse_tree.errors.toOwnedSlice(allocator);
    defer allocator.free(errors);

    var renderer: DiagRenderer = .{
        .source_file = parse_tree.source_file,
        .tokens = parse_tree.ast.tokens,
    };

    // Diagnostics
    try renderer.printErrors(errors, allocator, file_name);
}
