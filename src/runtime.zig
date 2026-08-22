const std = @import("std");
const ir = @import("dia_ir.zig");
const SymbolId = @import("semantic.zig").SymbolId;

const Inst = ir.Inst;
const InstId = ir.InstId;

// ───────────────────────────────
//            RUNTIME
// ───────────────────────────────
//
// Runtime TODO:
// 1) Merge all dialogue parts into a singular string.
// 2) Calculate all runtime variables.
// 3) Simplify branches (if possible.)
// 4) Use I/O interface for controls. (handle here or code generation)
//    Control options are:
//       1) Print dialogue line all at once.
//       2) Print based on text appearance speed.
//
//
// Finalized result should be sent to code generation.

pub const Runtime = @This();

instructions: []Inst,
extra: []InstId,

variables: std.array_hash_map.Auto(SymbolId, u8) = .empty,
