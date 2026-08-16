const std = @import("std");
const ir = @import("dia_ir.zig");
const in = @import("interner.zig");
const sem = @import("semantic.zig");
const Lower = @import("lower.zig").Lower;

const Allocator = std.mem.Allocator;

const InstId = ir.InstId;
const DiaIR = ir.DiaIR;
const Inst = ir.Inst;
const Insts = std.ArrayList(Inst);

const IdentId = in.IdentId;
const invalid_inst = in.invalid_inst;

const Symbol = sem.Symbol;
const SymbolId = sem.SymbolId;

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

pub const Optimize = @This();

allocator: Allocator,
instructions: *Insts,
extra: *std.ArrayList(u32),
lower: *const Lower,

constants: std.array_hash_map.Auto(SymbolId, Value) = .empty,

pub fn deinit(opt: *Optimize) void {
    opt.constants.deinit(opt.allocator);
}

// TODO: Optimizer needs diagnostics.
fn fold(tag: Inst.Tag, lhs: u8, rhs: u8) !u8 {
    return switch (tag) {
        .add => std.math.add(u8, lhs, rhs),
        .sub => std.math.sub(u8, lhs, rhs),
        .mul => std.math.mul(u8, lhs, rhs),
        .div => std.math.divTrunc(u8, lhs, rhs),
        else => unreachable,
    };
}

fn foldBool(tag: Inst.Tag, lhs: u8, rhs: u8) bool {
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

fn foldLogicalOp(tag: Inst.Tag, lhs: bool, rhs: bool) bool {
    return switch (tag) {
        .bool_and => lhs and rhs,
        .bool_or => lhs or rhs,
        else => unreachable,
    };
}

pub fn optimizeRoot(opt: *Optimize) !void {
    const root_inst = opt.instructions.items[opt.instructions.items.len - 1];
    const range = root_inst.data.range;

    try opt.block(range.start, range.len);

    try opt.instructions.shrinkToLen(opt.allocator);
    try opt.extra.shrinkToLen(opt.allocator);
}

fn block(opt: *Optimize, start: u32, len: u32) !void {
    const end = start + len;
    for (start..end) |idx| {
        const idx_cast: u32 = @intCast(idx);
        const stmt_idx = opt.extra.items[idx_cast];
        try opt.stmt(stmt_idx);
    }
}

fn stmt(opt: *Optimize, inst_idx: InstId) !void {
    const inst = opt.instructions.items[inst_idx];
    try switch (inst.tag) {
        .store => opt.storeVar(inst),
        .branch => opt.foldBranch(inst),
        .dialogue => opt.foldDialogue(inst),
        else => {},
    };
}

// To perform comptime declaration,
// 1) Variable must be "const"
// 2) Variable must be assigned a number.
// Anything else is a runtime variable.
fn storeVar(opt: *Optimize, inst: Inst) !void {
    const store = inst.data.store;
    const symbol_id = store.symbol_id;
    const symbol = opt.lower.symbols[symbol_id];

    const value = opt.evalFold(store.value);
    switch (value) {
        .uint => {
            if (symbol.kind == .constant)
                return try opt.constants.putNoClobber(opt.allocator, symbol_id, value);

        },
        // It is const, but not comptime known.
        // Don't put it in the constant environment.
        .unknown => {},
        .boolean => {},
    }
}

fn evalFold(opt: *Optimize, inst_idx: InstId) Value {
    const inst = opt.instructions.items[inst_idx];
    return switch (inst.tag) {
        .constant => .{ .uint = inst.data.uint },
        .add, .sub,
        .mul, .div => {
            const binary = inst.data.binary;
            const lhs = opt.evalFold(binary.lhs);
            const rhs = opt.evalFold(binary.rhs);

            if (lhs == .uint and rhs == .uint) {
                const num = fold(inst.tag, lhs.uint, rhs.uint) catch return .unknown;
                const constant: Inst.Data = .{ .uint = num };

                opt.instructions.items[inst_idx].data = constant;

                return .{ .uint = num };
            }

            return .unknown;
        },
        .load => opt.constants.get(inst.data.load) orelse return .unknown,
        else => .unknown,
    };
}

fn foldBranch(opt: *Optimize, inst: Inst) !void {
    const range = inst.data.range;
    const start = range.start;

    const cond_id = opt.extra.items[start];
    const value = opt.foldCondition(cond_id);

    const then_idx = opt.extra.items[start + 1];
    try opt.stmt(then_idx);

    const else_idx = opt.extra.items[start + 2];
    if (else_idx != invalid_inst) {
        const else_block = opt.instructions[else_idx];
        try opt.stmt(else_block);
    }

    // TODO: Need a way to store the comptime op.
    switch (value) {
        .boolean => std.debug.print("Value: {}\n", .{value.boolean}),
        else => {},
    }
}

fn foldCondition(opt: *Optimize, inst_idx: InstId) Value {
    const inst = opt.instructions.items[inst_idx];
    return switch (inst.tag) {
        .bool_and, .bool_or => opt.foldConjunction(inst_idx),
        else => opt.foldCompare(inst_idx),
    };
}

fn foldCompare(opt: *Optimize, inst_idx: InstId) Value {
    const inst = opt.instructions.items[inst_idx];
    return switch (inst.tag) {
        .eql, .not_eql,
        .less, .less_or_eql,
        .greater, .greater_or_eql => {
            const children = inst.data.binary;
            const lhs = opt.evalFold(children.lhs);
            const rhs = opt.evalFold(children.rhs);

            if (lhs == .uint and rhs == .uint) {
                // TODO: Constant fold and propagate boolean.
                const flag = foldBool(inst.tag, lhs.uint, rhs.uint);
                return .{ .boolean = flag };
            }

            return .unknown;
        },
        else => .unknown,
    };
}

fn foldConjunction(opt: *Optimize, inst_idx: InstId) Value {
    const inst = opt.instructions.items[inst_idx];
    const children = inst.data.binary;
    const lhs = opt.foldCondition(children.lhs);
    const rhs = opt.foldCondition(children.rhs);

    if (lhs == .boolean and rhs == .boolean) {
        const op = foldLogicalOp(inst.tag, lhs.boolean, rhs.boolean);
        return .{ .boolean = op };
    }

    return .unknown;
}

// ───────────────────────────────
//           DIALOGUE
// ───────────────────────────────

// Dialogue lines and dialogue branches contains
// the same format:
// [ speaker, dia_part_0, dia_part_1, ..., goto ]
fn foldDialogue(opt: *Optimize, inst: Inst) !void {
    const range = inst.data.range;
    const start = range.start;
    const end = start + range.len;

    // We can skip the speaker since we already know from Semantic
    // that speaker is valid. The last idx of the range is always the jump.
    // From Semantic, is also valid.
    // TODO: Suppose there is a comptime expr in between strings.
    // I need to merge the strings and interpolation together.
    // Example:
    //
    // A: There are { 4 } apples here.
    // 
    // This can be converted to
    // A: There are 4 apples here.
    //
    // A solution is to allocate memory and all of them together.
    // That new slice could be placed in the old text span and adjust the textId.
    for (start + 1.. end - 1) |idx| {
        const str_idx = opt.extra.items[idx];
        const str = opt.instructions.items[str_idx];

        switch (str.tag) {
            .string => {},
            else => _ = opt.evalFold(idx),
        }
    }
}
