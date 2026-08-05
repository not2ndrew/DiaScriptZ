const std = @import("std");
const ir = @import("dia_ir.zig");
const Local = @import("semantic.zig").Local;

const DiaIR = ir.DiaIR;
const Inst = ir.Inst;

const Instructions = std.ArrayList(Inst);

// Optimization includes:
// 1) Constant folding
// 2) Constant propagation
// 3) Dead code elimination (unreachable if stmts, unreachable dialogue, unused variables)
// 4) Opcode compliation
//
// For all of these optimization, unneeded Inst are converted to nop tag.
// Later on, we can remove dead code.
// We first build a new mapping of the Inst indexes. Then remove them the nop.
//
// For constant folding, we need an array of Constant variables.
// Since we know they are constant, we can compute arithmetic with constant
// variables at comptime.

const Optimize = @This();

instructions: *Instructions,
extra: *std.ArrayList(u32),
// TODO: I may need Semantic Locals here
// By getting locals, I can determine variable states without going through token slices.
// The issue is how to map from Semantic -> Optimize.

pub fn optimizeRoot(diaIR: *DiaIR) void {
    var opt: Optimize = .{
        .instructions = diaIR.instructions,
        .extra = diaIR.extra,
    };

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
        // .plus, .minus, .mult, .div => opt.arithmetic(inst),
        else => {},
    }
}

// TODO: Not quite sure on if I need this.
// All I'm doing is code optimization.
fn store(opt: *Optimize, inst: Inst) void {
    const binary = inst.data.binary;
    const decl = opt.instructions.items[binary.lhs];
    _ = decl;
}

fn arithmetic(opt: *Optimize, inst: Inst) void {
    const binary = inst.data.binary;
    const lhs = binary.lhs;
    const rhs = binary.rhs;

    const lhs_inst = opt.instructions.items[lhs];
    const rhs_inst = opt.instructions.items[rhs];

    if (lhs_inst.tag == .constant and rhs_inst.tag == .constant) {
        fold(Inst.tag, lhs_inst.data.uint, rhs_inst.data.uint);
    }
}

// TODO: Figure out how to perform constant folding on flattened instructions.
fn fold(tag: Inst.Tag, lhs: u8, rhs: u8) !void {
    return switch (tag) {
        .plus => std.math.add(u8, lhs, rhs),
        .minus => std.math.sub(u8, lhs, rhs),
        .mult => std.math.mul(u8, lhs, rhs),
        .div => std.math.divTrunc(u8, lhs, rhs),
        else => {},
    };
}
