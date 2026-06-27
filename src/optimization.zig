const std = @import("std");
const ir = @import("dia_ir.zig");

const DiaIR = ir.DiaIR;
const Inst = ir.Inst;

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
