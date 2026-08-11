const std = @import("std");
const tree = @import("ast.zig");
const sem = @import("semantic.zig");
const diag = @import("diagnostic.zig");
const ir = @import("dia_ir.zig");
const op = @import("optimize.zig");

const Allocator = std.mem.Allocator;

const Ast = tree.Ast;
const ParseResult = tree.ParseResult;

const Semantic = sem.Semantic;

const Symbol = sem.Symbol;
const Symbols = std.MultiArrayList(Symbol);

const AstError = diag.Error;
const Errors = std.ArrayList(AstError);
const DiagRenderer = diag.DiagRenderer;

const DiaIR = ir.DiaIR;
const Inst = ir.Inst;

const Optimize = op.Optimize;

pub const Lower = @This();

symbols: []Symbol,

pub fn deinit(low: *Lower, allocator: Allocator) void {
    allocator.free(low.symbols);
}

// TODO: Reduce the amount of parameters this takes.
// Also, make sure that after parsing, AST can no longer be modified.
// The reason why I use *const AST is using a local AST copies ALOT of values.
pub fn lower(allocator: Allocator, source: []const u8,
            parse_tree: *ParseResult, ast: *const Ast, errors: *Errors, file_name: []const u8) !void {
    // Analyze AST
    // TODO: If we need something from semantic, return a struct.
    // Otherwise, delete this comment.
    var low = try sem.analyze(allocator, source, ast, errors);
    defer low.deinit(allocator);

    // The AST -> IR lowering process assumes an AST
    // does not have any parse or syntax errors.
    // If there is exist an error,
    // we halt the entire program and return all errors found.
    if (errors.items.len > 0)
        return printErrors(parse_tree, allocator, file_name);

    var diaIR: DiaIR = .{
        .allocator = allocator,
        .ast = ast,
        .source = source,
        // .symbols = low.symbols
    };
    defer diaIR.deinit();

    // AST -> IR
    try diaIR.generate();

    // Optimization IR here
    // TODO: Decide whether I should use toOwnSlice() on extra.
    // var opt: Optimize = .{
    //     .instructions = &diaIR.instructions,
    //     .extra = &diaIR.extra,
    //     .string_bytes = try diaIR.string_bytes.toOwnedSlice(allocator),
    //     .text_bytes = try diaIR.text_bytes.toOwnedSlice(allocator),
    // };
    // defer opt.deinit(allocator);
    //
    // opt.optimizeRoot();
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
