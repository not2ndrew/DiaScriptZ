const std = @import("std");
const frontend = @import("frontend");
const middle = @import("middle");
const backend = @import("backend");

const Allocator = std.mem.Allocator;

const Ast = frontend.ast.Ast;

const Semantic = middle.semantic.Semantic;
const DecoratedAst = middle.semantic.DecoratedAst;

const dir = backend.ir;
const DiaIR = dir.DiaIR;
const InstId = dir.InstId;

const Optimize = backend.optimize.Optimize;

const remap = backend.remap;
const NewIR = remap.NewIR;
const remapOldToNewInsts = remap.remapOldToNewInsts;

pub const Lower = @This();

ir: NewIR,
errors: []Semantic.Error,

pub fn lower(allocator: Allocator, ast: *const Ast, decorated: *const DecoratedAst.Decorated) !Lower {
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

    const root_idx: InstId = @intCast(opt.instructions.len - 1);
    const new_ir = try remapOldToNewInsts(&opt, root_idx);

    return .{
        .ir = new_ir,
        .errors = try opt.errors.toOwnedSlice(allocator),
    };
}

pub fn deinit(low: *Lower, allocator: Allocator) void {
    allocator.free(low.ir.instructions);
    allocator.free(low.ir.extra);
    allocator.free(low.errors);
}
