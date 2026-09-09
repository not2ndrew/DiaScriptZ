const std = @import("std");
const frontend = @import("frontend");
const sem = @import("middle").semantic;
const low = @import("lower.zig");
const bundle = @import("error_bundle.zig");
const backend = @import("backend");

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

const dir = backend.ir;
const Inst = dir.Inst;
const InstId = dir.InstId;

const remap = backend.remap;
const NewIR = remap.NewIR;

// TODO: Get file_path instead of file_name.
pub fn compileFile(init: Init, source: []const u8, file_name: []const u8) !NewIR {
    // Generate AST from source
    var parse_tree = try tree.parse(init.gpa, source);
    defer parse_tree.deinit(init.gpa);

    const source_file = parse_tree.ast.source_file;

    if (parse_tree.errors.len > 0) {
        try printAstErrorsToStderr(init, source_file, parse_tree.errors, file_name);
        return error.ParseError;
    }

    var decorated_ast = try sem.analyze(init.gpa, &parse_tree.ast);
    defer decorated_ast.deinit(init.gpa);

    if (decorated_ast.errors.len > 0) {
        try printSemanticErrorsToStderr(init, source_file, decorated_ast.errors, file_name);
        return error.SemanticError;
    }

    var lower_result = try low.lower(init.gpa, &parse_tree.ast, &decorated_ast.decorated);
    defer lower_result.deinit(init.gpa);

    if (lower_result.errors.len > 0) {
        try printSemanticErrorsToStderr(init, source_file, lower_result.errors, file_name);
        return error.SemanticError;
    }

    return try cloneNewIR(&lower_result.ir, init.gpa);
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

/// NewIR still requires user to free memory after usage.
pub fn cloneNewIR(ir: *NewIR, allocator: Allocator) !NewIR {
    const instructions = try allocator.alloc(Inst, ir.instructions.len);
    @memcpy(instructions, ir.instructions);

    const extra = try allocator.alloc(InstId, ir.extra.len);
    @memcpy(extra, ir.extra);

    return .{
        .instructions = instructions,
        .extra = extra,
        .num_of_declar = ir.num_of_declar
    };
}
