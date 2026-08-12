const std = @import("std");
const ir = @import("dia_ir.zig");
const Symbol = @import("semantic.zig").Symbol;

const Allocator = std.mem.Allocator;

const DiaIR = ir.DiaIR;
const Inst = ir.Inst;

const Instructions = std.ArrayList(Inst);

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

instructions: *Instructions,
extra: *std.ArrayList(u32),
string_bytes: []const u8,
text_bytes: []const u8,

pub fn deinit(opt: *Optimize, allocator: Allocator) void {
    allocator.free(opt.string_bytes);
    allocator.free(opt.text_bytes);
}

pub fn optimizeRoot(opt: *Optimize) void {
    const root_inst = opt.instructions.items[opt.instructions.items.len - 1];
    const range = root_inst.data.range;

    opt.block(range.start, range.len);
}

fn block(opt: *Optimize, start: u32, len: u32) void {
    const end = start + len;
    for (start..end) |idx| {
        const idx_cast: u32 = @intCast(idx);
        const stmt_idx = opt.extra.items[idx_cast];
        const inst = opt.instructions.items[stmt_idx];
        opt.stmt(inst);
    }
}

fn stmt(opt: *Optimize, inst: Inst) void {
    switch (inst.tag) {
        .store => opt.store(inst),
        else => {},
    }
}

// To perform comptime declaration,
// 1) Variable must be "const"
// 2) Variable must be assigned a number.
// Anything else is a runtime variable.
fn store(opt: *Optimize, inst: Inst) void {
    const binary = inst.data.binary;
    const decl = opt.instructions.items[binary.lhs];
    _ = decl;
}

// lhs is the declaration variable
// rhs is the value
fn arithmetic(opt: *Optimize, inst: Inst) void {
    const binary = inst.data.binary;
    const rhs = binary.rhs;

    const rhs_inst = opt.instructions.items[rhs];

    opt.expr(rhs_inst);

    // if (lhs_inst.tag == .constant and rhs_inst.tag == .constant) {
    //     const num = fold(Inst.tag, lhs_inst.data.uint, rhs_inst.data.uint);
    //     lhs_inst.data.uint = num;
    //     rhs_inst.data = .{ .none = {} };
    // }
}

// TODO: Figure out how to perform constant folding on flattened instructions.
fn fold(tag: Inst.Tag, lhs: u8, rhs: u8) !u8 {
    return switch (tag) {
        .plus => std.math.add(u8, lhs, rhs),
        .minus => std.math.sub(u8, lhs, rhs),
        .mult => std.math.mul(u8, lhs, rhs),
        .div => std.math.divTrunc(u8, lhs, rhs),
        else => unreachable,
    };
}

fn expr(opt: *Optimize, inst: Inst) void {
    switch (inst.tag) {
        .plus => opt.evalBinary(inst),
        .sub => opt.evalBinary(inst),
        .mul => opt.evalBinary(inst),
        .div => opt.evalBinary(inst),
        .constant => {},
        .load => {},
        else => {},
    }
}

fn evalBinary(opt: *Optimize, inst: Inst) void {
    const binary = inst.data.binary;
    opt.expr(binary.lhs);
    opt.expr(binary.rhs);
}
