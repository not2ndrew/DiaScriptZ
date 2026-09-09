const std = @import("std");
const backend = @import("backend");
const SymbolId = @import("middle").semantic.SymbolId;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const Inst = backend.ir.Inst;
const InstId = backend.ir.InstId;

const NewIR = backend.remap.NewIR;

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
//
// TODO: Handle merging dialogue parts at runtime rather than comptime.
//
// BIG CHANGE SOLUTION:
// Make all dialogue text runtime. For dialogue with interpolation, merge all parts
// into a singular string regardless of comptime or runtime.
//
// We don't want to allocate memory in comptime and then runtime; it's too inefficient in performance.
// It's better to allocate one huge memory and then insert all characters all at once.
//
// However, comptime interpolation variables MUST still be optimized using constant propagation.
//
// Since this is runtime, I do require I/O from Init in compile.zig.
// A single error encountered during runtime will immediately abort program and return the error.

pub const Runtime = @This();

allocator: Allocator,
instructions: []Inst,
extra: []InstId,

declarations: std.array_hash_map.Auto(SymbolId, u8) = .empty,

// TODO: Determine if I should insert Io in the struct or as a fn parameter.
pub fn runProgram(io: Io, allocator: Allocator, ir: NewIR) !void {
    _ = io;
    var runtime: Runtime = .{
        .allocator = allocator,
        .instructions = ir.instructions,
        .extra = ir.extra,
    };

    try runtime.declarations.ensureTotalCapacity(allocator, ir.num_of_declar);
}

pub fn deinit(ru: *Runtime) void {
    ru.declarations.deinit(ru.allocator);
}
