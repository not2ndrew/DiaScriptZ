const std = @import("std");
const frontend = @import("frontend");
const sem = @import("semantic.zig");
// const ir = @import("dia_ir.zig");
// const op = @import("optimize.zig");
const in = @import("interner.zig");

const Allocator = std.mem.Allocator;

const Ast = frontend.ast.Ast;
const ParseResult = frontend.ast.ParseResult;

const Semantic = sem.Semantic;

const Symbol = sem.Symbol;
const Symbols = std.MultiArrayList(Symbol);
const SymbolId = sem.SymbolId;

const Errors = std.ArrayList(frontend.ast.Ast.Error);

// const DiaIR = ir.DiaIR;
// const Inst = ir.Inst;
//
// const Optimize = op.Optimize;

const IdentId = in.IdentId;
const InternPool = in.InternPool;

pub const Lower = @This();

symbols: []Symbol,
labels: []IdentId,
symbol_refs: []SymbolId,
jumps: []IdentId,
pool: InternPool,

pub fn deinit(low: *Lower, allocator: Allocator) void {
    allocator.free(low.symbols);
    allocator.free(low.labels);
    allocator.free(low.symbol_refs);
    allocator.free(low.jumps);
    low.pool.deinit(allocator);
}

pub fn lower(allocator: Allocator, ast: *const Ast) !void {
    var low = try sem.analyze(allocator, ast);
    defer low.deinit(allocator);

    // The AST -> IR lowering process assumes an AST
    // does not have any parse or syntax errors.
    // If there is exist an error,
    // we halt the entire program and return all errors found.

    // var diaIR: DiaIR = .{
    //     .allocator = allocator,
    //     .ast = &parse_tree.ast,
    //     .lower = &low,
    // };
    // defer diaIR.deinit();
    //
    // // AST -> IR
    // try diaIR.generate();
    //
    // // Optimization IR here
    // // TODO: Decide whether I should use toOwnSlice() on extra.
    // var opt: Optimize = .{
    //     .allocator = allocator,
    //     .instructions = try diaIR.instructions.toOwnedSlice(allocator),
    //     .extra = try diaIR.extra.toOwnedSlice(allocator),
    //     .lower = &low,
    // };
    // defer opt.deinit();
    // try opt.optimizeRoot();
}
