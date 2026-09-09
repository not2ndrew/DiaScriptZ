const std = @import("std");
const frontend = @import("frontend");
const sem = @import("middle").semantic;
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
pub fn compileFile(init: Init, source: []const u8, file_name: []const u8) !void {
    // Generate AST from source
    var parse_tree = tree.parse(init.gpa, source) catch |err| {
        if (err == error.ParseError) return;
        return err;
    };
    defer parse_tree.deinit(init.gpa);

    const source_file = parse_tree.ast.source_file;

    if (parse_tree.errors.len > 0)
        return try printAstErrorsToStderr(init, source_file, parse_tree.errors, file_name);

    var decorated_ast = sem.analyze(init.gpa, &parse_tree.ast) catch |err| {
        if (err == error.SemanticError) return;
        return err;
    };
    defer decorated_ast.deinit(init.gpa);

    if (decorated_ast.errors.len > 0)
        return try printSemanticErrorsToStderr(init, source_file, decorated_ast.errors, file_name);

    var new_ir = low.lower(init.gpa, &parse_tree.ast, &decorated_ast.decorated) catch |err| {
        if (err == error.OptimizeError) return;
        return err;
    };
    defer new_ir.deinit(init.gpa);

    if (new_ir.errors.len > 0)
        return try printSemanticErrorsToStderr(init, source_file, new_ir.errors, file_name);
}

fn printAstErrorsToStderr(init: Init, source_file: SourceFile, errors: []const Ast.Error, file_path: []const u8) !void {
    var error_bundle: ErrorBundle = .{
        .allocator = init.gpa,
        .source_file = source_file,
    };
    defer error_bundle.deinit();

    try error_bundle.addAstErrorMessages(errors);
    return error_bundle.renderToStderr(init.io, file_path);
}

fn printSemanticErrorsToStderr(init: Init, source_file: SourceFile, errors: []const sem.Error, file_path: []const u8) !void {
    var error_bundle: ErrorBundle = .{
        .allocator = init.gpa,
        .source_file = source_file,
    };
    defer error_bundle.deinit();

    try error_bundle.addSemanticErrorMessages(errors);
    return error_bundle.renderToStderr(init.io, file_path);
}
