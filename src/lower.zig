const std = @import("std");
const frontend = @import("frontend");
const middle = @import("middle");
const backend = @import("backend");

const Allocator = std.mem.Allocator;

const Ast = frontend.ast.Ast;

const sem = middle.semantic;
const Semantic = sem.Semantic;
const Symbol = sem.Symbol;
const Symbols = std.MultiArrayList(Symbol);
const SymbolId = sem.SymbolId;
const DecoratedAst = sem.DecoratedAst;

const ir = backend.ir;
const DiaIR = ir.DiaIR;

const op = backend.optimize;
const Optimize = op.Optimize;

pub fn lower(allocator: Allocator, ast: *const Ast, decorated: *const DecoratedAst.Decorated) !void {
    // The AST -> IR lowering process assumes an AST
    // does not have any parse or syntax errors.
    // If there is exist an error,
    // we halt the entire program and return all errors found.

    var diaIR: DiaIR = .{
        .allocator = allocator,
        .ast = ast,
        .decorated = decorated,
    };
    defer diaIR.deinit();

    // AST -> IR
    try diaIR.generate();

    // Optimization IR here
    var opt: Optimize = .{
        .allocator = allocator,
        .instructions = try diaIR.instructions.toOwnedSlice(allocator),
        .extra = try diaIR.extra.toOwnedSlice(allocator),
        .decorated = decorated,
    };
    defer opt.deinit();
    try opt.optimizeRoot();
}
