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

const Symbol = sem.Symbol;
const SymbolId = sem.SymbolId;

pub const Value = union(enum) {
    unknown,
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

pub fn optimizeRoot(opt: *Optimize) !void {
    const root_inst = opt.instructions.items[opt.instructions.items.len - 1];
    const range = root_inst.data.range;

    try opt.block(range.start, range.len);

    try opt.instructions.shrinkToLen(opt.allocator);
    try opt.instructions.shrinkToLen(opt.allocator);
}

fn block(opt: *Optimize, start: u32, len: u32) !void {
    const end = start + len;
    for (start..end) |idx| {
        const idx_cast: u32 = @intCast(idx);
        const stmt_idx = opt.extra.items[idx_cast];
        const inst = opt.instructions.items[stmt_idx];
        try opt.stmt(inst);
    }
}

fn stmt(opt: *Optimize, inst: Inst) !void {
    try switch (inst.tag) {
        .store => opt.storeVar(inst),
        else => {},
    };
}

// To perform comptime declaration,
// 1) Variable must be "const"
// 2) Variable must be assigned a number.
// Anything else is a runtime variable.
fn storeVar(opt: *Optimize, inst: Inst) !void {
    const store = inst.data.store;
    const symbol_id = store.symbol;
    const symbol = opt.lower.symbols[symbol_id];

    if (symbol.kind != .constant) return;

    const value = opt.evalExpr(store.value);
    switch (value) {
        .uint => {
            try opt.constants.putNoClobber(opt.allocator, symbol_id, value);
        },
        .unknown => {
            // It is const, but not comptime known.
            // Don't put it in the constant environment.
        },
    }
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

fn evalExpr(opt: *Optimize, inst_idx: InstId) Value {
    const inst = opt.instructions.items[inst_idx];
    return switch (inst.tag) {
        .constant => .{ .uint = inst.data.uint },
        .add, .sub,
        .mul, .div => opt.evalBinary(inst) catch .unknown,
        .load => opt.constants.get(inst.data.load) orelse return .unknown,
        else => .unknown,
    };
}

// There are 4 possible combinations of binary
// 1) uint and uint
// 2) ident and uint
// 3) uint and ident
// 4) ident and ident
fn evalBinary(opt: *Optimize, inst: Inst) !Value {
    const binary = inst.data.binary;
    const lhs = opt.evalExpr(binary.lhs);
    const rhs = opt.evalExpr(binary.rhs);

    if (lhs == .uint and rhs == .uint) {
        const num = fold(inst.tag, lhs.uint, rhs.uint) catch return .unknown;
        return .{ .uint = num };
    }

    return .unknown;
}
