const std = @import("std");
const frontend = @import("frontend");
const sem = @import("semantic.zig");
const low = @import("lower.zig");
const bundle = @import("error_bundle.zig");

const Io = std.Io;
const Init = std.process.Init;
const Allocator = std.mem.Allocator;
const Arena = std.heap.ArenaAllocator;
const DelimiterError = std.Io.Reader.DelimiterError;

const tree = frontend.ast;
const ParseResult = tree.ParseResult;
const Ast = tree.Ast;

const SourceFile = frontend.source_file.SourceFile;

const ErrorBundle = bundle.ErrorBundle;

// TODO: Get file_path instead of file_name.
pub fn compileFile(init: Init, allocator: Allocator, file_name: []const u8) !void {
    const source = try readFile(init, allocator, file_name);
    defer allocator.free(source);

    // Generate AST from source
    // TODO: Make sure to free parse_tree AFTER code optimization is complete.
    var parse_tree = tree.parse(allocator, source) catch |err| {
        if (err == error.ParseError) return;
        return err;
    };
    defer parse_tree.deinit(allocator);

    if (parse_tree.errors.len > 0)
        try printAstErrorsToStderr(init.io, allocator, parse_tree.ast.source_file, parse_tree.errors, file_name);

    var decorated_ast = sem.analyze(allocator, &parse_tree.ast) catch |err| {
        if (err == error.SemanticError) return;
        return err;
    };
    defer decorated_ast.deinit(allocator);

    if (decorated_ast.errors.len > 0)
        try printSemanticErrorsToStderr(init.io, allocator, parse_tree.ast.source_file, decorated_ast.errors, file_name);
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

// TODO: Maybe create a struct containing source and tokens.
// That's all Stderr really needs.
fn printAstErrorsToStderr(io: Io, allocator: Allocator, source_file: SourceFile, errors: []Ast.Error, file_path: []const u8) !void {
    var error_bundle: ErrorBundle = .{
        .allocator = allocator,
        .source_file = source_file,
    };
    defer error_bundle.deinit();

    try error_bundle.addAstErrorMessages(errors);

    return error_bundle.renderToStderr(io, file_path);
}

fn printSemanticErrorsToStderr(io: Io, allocator: Allocator, source_file: SourceFile, errors: []sem.Error, file_name: []const u8) !void {
    var error_bundle: ErrorBundle = .{
        .allocator = allocator,
        .source_file = source_file,
    };
    defer error_bundle.deinit();

    try error_bundle.addSemanticErrorMessages(errors);
    return error_bundle.renderToStderr(io, file_name);
}
