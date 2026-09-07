const std = @import("std");
const frontend = @import("frontend");
const middle = @import("middle");
const backend = @import("backend");

const Allocator = std.mem.Allocator;

const Ast = frontend.ast.Ast;

const Semantic = middle.semantic.Semantic;
const DecoratedAst = middle.semantic.DecoratedAst;

const DiaIR = backend.ir.DiaIR;
const Optimize = backend.optimize.Optimize;

// pub const Lower = @This();
//
// allocator: Allocator,
//
// instructions: []Inst,
// extra: []InstId,
//
// constants: std.array_hash_map.Auto(SymbolId, u8) = .empty,
// // KV pair is condition id -> block id
// branch_result: std.array_hash_map.Auto(InstId, InstId) = .empty,
//
// live: std.array_hash_map.Auto(InstId, void) = .empty,
//
// errors: std.ArrayList(Semantic.Error) = .empty,

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

    // IR -> Optimized IR
    var opt: Optimize = .{
        .allocator = allocator,
        .instructions = try diaIR.instructions.toOwnedSlice(allocator),
        .extra = try diaIR.extra.toOwnedSlice(allocator),
        .decorated = decorated,
    };
    defer opt.deinit();
    try opt.optimizeRoot();
}
