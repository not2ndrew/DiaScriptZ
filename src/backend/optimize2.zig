const std = @import("std");
const middle = @import("middle");
const ssa_zig = @import("ssa.zig");

const Allocator = std.mem.Allocator;

const in = middle.interner;
const IdentId = in.IdentId;

const sem = middle.semantic;
const Decorated = sem.DecoratedAst.Decorated;

const InstId = ssa_zig.InstId;
const GenSSA = ssa_zig.GenSSA;
const Inst = ssa_zig.Inst;
const Insts = std.ArrayList(Inst);
const invalid_inst = ssa_zig.invalid_inst;

const IntError = error {
    Overflow,
    DivisionByZero,
};

const Error = Allocator.Error;

pub const Value = union(enum) {
    unknown,
    boolean: bool,
    uint: u8,
};

// Optimization includes:
// 1) Constant folding
// 2) Constant propagation
// 3) Dead code elimination (unreachable if stmts, unreachable dialogue, unused variables)
// 4) Opcode compliation
//
// A declaration is immutable if it is const.
// Its initializer is compile-time evaluable if
// its expression can be evaluated to a known value.

pub const Optimize2 = @This();

allocator: Allocator,
decorated: *const Decorated,

ssa: *GenSSA,

constants: std.array_hash_map.Auto(IdentId, u8) = .empty,
// KV pair is condition id -> block id
branch_result: std.array_hash_map.Auto(InstId, InstId) = .empty,

live: std.array_hash_map.Auto(InstId, void) = .empty,

errors: std.ArrayList(sem.Semantic.Error) = .empty,

kind_idx: u32 = 0,

pub fn deinit(opt: *Optimize2) void {
    opt.ssa.deinit(opt.allocator);
    opt.constants.deinit(opt.allocator);
    opt.branch_result.deinit(opt.allocator);
    opt.live.deinit(opt.allocator);
    opt.errors.deinit(opt.allocator);
}

fn fold(tag: Inst.Tag, lhs: u8, rhs: u8) !u8 {
    return switch (tag) {
        .add => std.math.add(u8, lhs, rhs),
        .sub => std.math.sub(u8, lhs, rhs),
        .mul => std.math.mul(u8, lhs, rhs),
        .div => std.math.divTrunc(u8, lhs, rhs),
        else => unreachable,
    };
}

fn compare(tag: Inst.Tag, lhs: u8, rhs: u8) bool {
    return switch (tag) {
        .eql => lhs == rhs,
        .not_eql => lhs != rhs,
        .less => lhs < rhs,
        .less_or_eql => lhs <= rhs,
        .greater => lhs > rhs,
        .greater_or_eql => lhs >= rhs,
        else => unreachable,
    };
}

fn logicalOp(tag: Inst.Tag, lhs: bool, rhs: bool) bool {
    return switch (tag) {
        .bool_and => lhs and rhs,
        .bool_or => lhs or rhs,
        else => unreachable,
    };
}


fn rewriteValue(opt: *Optimize2, inst_idx: InstId, value: Value) void {
    const old = opt.ssa.instructions[inst_idx];

    switch (value) {
        .uint => |v| {
            opt.ssa.instructions[inst_idx] = .{
                .tag = .constant,
                .token_pos = old.token_pos,
                .data = .{ .uint = v },
            };
        },
        .boolean => |v| {
            opt.ssa.instructions[inst_idx] = .{
                .tag = .constant,
                .token_pos = old.token_pos,
                .data = .{ .boolean = v },
            };
        },
        .unknown => {},
    }
}

fn nextKind(opt: *Optimize2) sem.SymbolKind {
    const kind = opt.decorated.kinds[opt.kind_idx];
    opt.kind_idx += 1;
    return kind;
}

pub fn optimizeRoot(opt: *Optimize2) Error!void {
    const root_idx: u32 = @intCast(opt.ssa.instructions.len - 1);
    const root_inst = opt.instructions[root_idx];
    const range = root_inst.data.range;

    // Pass 1: Constant fold and propagate.
    try opt.block(range.start, range.len);

    // Pass 2: Dead Code elimination
    // var dce: DCE = .{ .opt = opt };
    // defer dce.deinit();
    //
    // try dce.run(root_idx);
}

fn block(opt: *Optimize2, start: u32, len: u32) Error!void {
    const end = start + len;
    for (start..end) |idx| {
        const stmt_idx = opt.ssa.extra[idx];
        try opt.stmt(stmt_idx);
    }
}

fn stmt(opt: *Optimize2, inst_idx: InstId) Error!void {
    const inst = opt.instructions[inst_idx];
    _ = inst;
    // return switch (inst.tag) {
    //     .store => opt.storeValue(inst),
    //     .declaration => opt.declaration(inst_idx),
    //     .branch => opt.foldBranch(inst_idx),
    //     .dialogue, .choice => opt.foldDialogue(inst),
    //     .label_block => opt.foldLabel(inst),
    //     .choice_block => {
    //         const range = inst.data.range;
    //         try opt.block(range.start, range.len);
    //     },
    //     else => unreachable,
    // };
}
