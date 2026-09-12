const std = @import("std");
const frontend = @import("frontend");
const middle = @import("middle");
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

const sem = middle.semantic;

const interner = middle.interner;
const InternPool = interner.InternPool;
const Span = interner.Span;

const ErrorBundle = bundle.ErrorBundle;

const dir = backend.ir;
const Inst = dir.Inst;
const InstId = dir.InstId;

const remap = backend.remap;
const NewIR = remap.NewIR;

pub const Compile = @This();

instructions: []const Inst,
extra: []const InstId,
pool: InternPool,

num_of_declar: u32,

pub fn deinit(comp: *Compile, allocator: Allocator) void {
    allocator.free(comp.instructions);
    allocator.free(comp.extra);
    comp.pool.deinit(allocator);
}

// TODO: Get file_path instead of file_name.
pub fn compileFile(init: Init, source: []const u8, file_name: []const u8) !Compile {
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

    // var diaIR: dir.DiaIR = .{
    //     .allocator = init.gpa,
    //     .ast = &parse_tree.ast,
    //     .decorated = &decorated_ast.decorated,
    // };
    // defer diaIR.deinit();
    //
    // try diaIR.generate();
    //
    // for (diaIR.instructions.items) |inst| {
    //     std.debug.print("tag: {t}\n", .{inst.tag});
    // }

    var lower_result = try low.lower(init.gpa, &parse_tree.ast, &decorated_ast.decorated);
    defer lower_result.deinit(init.gpa);

    if (lower_result.errors.len > 0) {
        try printSemanticErrorsToStderr(init, source_file, lower_result.errors, file_name);
        return error.SemanticError;
    }

    return createCompile(init.gpa, &lower_result.ir, &decorated_ast.decorated);
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

pub fn createCompile(gpa: Allocator, ir: *const NewIR, decorated: *const sem.DecoratedAst.Decorated) !Compile {
    const instructions = try gpa.alloc(Inst, ir.instructions.len);
    @memcpy(instructions, ir.instructions);

    const extra = try gpa.alloc(InstId, ir.extra.len);
    @memcpy(extra, ir.extra);

    const bytes = try gpa.alloc(u8, decorated.pool.bytes.len);
    @memcpy(bytes, decorated.pool.bytes);

    const texts = try gpa.alloc(u8, decorated.pool.texts.len);
    @memcpy(texts, decorated.pool.texts);

    const text_spans = try gpa.alloc(Span, decorated.pool.text_spans.len);
    @memcpy(text_spans, decorated.pool.text_spans);

    const ident_spans = try gpa.alloc(Span, decorated.pool.ident_spans.len);
    @memcpy(ident_spans, decorated.pool.ident_spans);

    return .{
        .instructions = instructions,
        .extra = extra,
        .num_of_declar = ir.num_of_declar,
        .pool = .{
            .bytes = bytes,
            .ident_spans = ident_spans,
            .texts = texts,
            .text_spans = text_spans,
        }
    };
}
