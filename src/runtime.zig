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
io: Io,
instructions: []const Inst,
extra: []const InstId,

declarations: std.array_hash_map.Auto(SymbolId, u8) = .empty,

pub fn runProgram(io: Io, allocator: Allocator, ir: NewIR) !void {
    var runtime: Runtime = .{
        .allocator = allocator,
        .io = io,
        .instructions = ir.instructions,
        .extra = ir.extra,
    };
    defer runtime.deinit();

    try runtime.declarations.ensureTotalCapacity(allocator, ir.num_of_declar);
    
    try runtime.run();
}

pub fn deinit(ru: *Runtime) void {
    ru.declarations.deinit(ru.allocator);
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

fn run(ru: *Runtime) !void {
    const root_inst = ru.instructions[ru.instructions.len - 1];
    const range = root_inst.data.range;

    try ru.block(range.start, range.len);
}

fn block(ru: *Runtime, start: u32, len: u32) !void {
    const end = start + len;
    for (start .. end) |idx| {
        const stmt_idx = ru.extra[idx];
        try ru.stmt(stmt_idx);
    }
}

fn stmt(ru: *Runtime, inst_idx: InstId) !void {
    const inst = ru.instructions[inst_idx];
    std.debug.print("Inst tag: {t}\n", .{inst.tag});
    return switch (inst.tag) {
        .declaration => ru.declaration(inst),
        .store => ru.storeValue(inst),
        else => unreachable,
    };
}

fn declaration(ru: *Runtime, inst: Inst) !void {
    const store = inst.data.store;
    const value = try ru.eval(store.value);
    ru.declarations.putAssumeCapacityNoClobber(store.symbol_id, value);
}

fn storeValue(ru: *Runtime, inst: Inst) !void {
    const store = inst.data.store;
    const value = try ru.eval(store.value);

    const entry = ru.declarations.getEntry(store.symbol_id) orelse unreachable;
    entry.value_ptr.* = value;

    std.debug.print("The value is: {d}\n", .{value});
}

fn eval(ru: *Runtime, inst_idx: InstId) !u8 {
    const inst = ru.instructions[inst_idx];
    return switch (inst.tag) {
        .constant => inst.data.uint,
        .load => {
            const symbol_id = inst.data.load;
            return ru.declarations.get(symbol_id) orelse unreachable;
        },
        .add, .sub, .mul, .div => {
            const b = inst.data.binary;
            const lhs = try ru.eval(b.lhs);
            const rhs = try ru.eval(b.rhs);

            return fold(inst.tag, lhs, rhs) catch |err| return err;
        },
        else => unreachable,
    };
}
