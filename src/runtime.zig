const std = @import("std");
const middle = @import("middle");
const backend = @import("backend");
const Compile = @import("compile.zig").Compile;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const sem = middle.semantic;
const Symbol = sem.Symbol;
const SymbolId = sem.SymbolId;

const dir = backend.ir;
const Inst = dir.Inst;
const InstId = dir.InstId;
const invalid_inst = dir.invalid_inst;

pub const RunTimeError = Allocator.Error || error { Overflow, DivisionByZero };

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
symbols: []const Symbol,
bytes: []const u8,
texts: []const u8,

declarations: std.array_hash_map.Auto(SymbolId, u8) = .empty,

pub fn runProgram(io: Io, allocator: Allocator, comp: Compile) RunTimeError!void {
    var runtime: Runtime = .{
        .allocator = allocator,
        .io = io,
        .instructions = comp.instructions,
        .extra = comp.extra,
        .symbols = comp.symbols,
        .bytes = comp.bytes,
        .texts = comp.texts,
    };
    defer runtime.deinit();

    try runtime.declarations.ensureTotalCapacity(allocator, comp.num_of_declar);
    
    try runtime.run();
}

pub fn deinit(ru: *Runtime) void {
    ru.declarations.deinit(ru.allocator);
}

fn fold(tag: Inst.Tag, lhs: u8, rhs: u8) RunTimeError!u8 {
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

fn condition(ru: *Runtime, inst_idx: InstId) RunTimeError!bool {
    const inst = ru.instructions[inst_idx];

    return switch (inst.tag) {
        .bool_and, .bool_or => try ru.logicalCondition(inst),
        .eql, .not_eql,
        .less, .less_or_eql,
        .greater, .greater_or_eql => ru.compareCondition(inst),
        else => unreachable,
    };
}

fn logicalCondition(ru: *Runtime, inst: Inst) RunTimeError!bool {
    const binary = inst.data.binary;

    const lhs = try ru.condition(binary.lhs);
    const rhs = try ru.condition(binary.rhs);

    return switch (inst.tag) {
        .bool_and => lhs and rhs,
        .bool_or => lhs or rhs,
        else => unreachable,
    };
}

fn compareCondition(ru: *Runtime, inst: Inst) RunTimeError!bool {
    const binary = inst.data.binary;

    const lhs = try ru.eval(binary.lhs);
    const rhs = try ru.eval(binary.rhs);

    return compare(inst.tag, lhs, rhs);
}

fn eval(ru: *Runtime, inst_idx: InstId) RunTimeError!u8 {
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

            return try fold(inst.tag, lhs, rhs);
        },
        else => unreachable,
    };
}

fn run(ru: *Runtime) RunTimeError!void {
    const root_inst = ru.instructions[ru.instructions.len - 1];
    const range = root_inst.data.range;

    try ru.block(range.start, range.len);
}

fn block(ru: *Runtime, start: u32, len: u32) RunTimeError!void {
    const end = start + len;
    for (start .. end) |idx| {
        const stmt_idx = ru.extra[idx];
        try ru.stmt(stmt_idx);
    }
}

fn stmt(ru: *Runtime, inst_idx: InstId) RunTimeError!void {
    const inst = ru.instructions[inst_idx];
    std.debug.print("Inst tag: {t}\n", .{inst.tag});
    return switch (inst.tag) {
        .declaration => ru.declaration(inst),
        .store => ru.storeValue(inst),
        .branch =>ru.branch(inst),
        else => unreachable,
    };
}

fn declaration(ru: *Runtime, inst: Inst) RunTimeError!void {
    const store = inst.data.store;
    const value = try ru.eval(store.value);
    ru.declarations.putAssumeCapacityNoClobber(store.symbol_id, value);
}

fn storeValue(ru: *Runtime, inst: Inst) RunTimeError!void {
    const store = inst.data.store;
    const value = try ru.eval(store.value);

    const entry = ru.declarations.getEntry(store.symbol_id) orelse unreachable;
    entry.value_ptr.* = value;

    std.debug.print("The value is: {d}\n", .{value});
}

fn branch(ru: *Runtime, inst: Inst) RunTimeError!void {
    const range = inst.data.range;
    const cond = ru.extra[range.start];
    const then_block = ru.extra[range.start + 1];
    const else_block = ru.extra[range.start + 2];

    const branch_result = try ru.condition(cond);

    if (branch_result) {
        const then_inst = ru.instructions[then_block];
        const t_range = then_inst.data.range;
        try ru.block(t_range.start, t_range.len);
    } else {
        const else_inst = ru.instructions[else_block];
        const e_range = else_inst.data.range;
        try ru.block(e_range.start, e_range.len);
    }
}

// TODO: Using IO, run the dialogue char by char in the terminal.
// This can be done using io.sleep
// Using a loop, print one char at a time and sleep for x amount of milliseconds.
// fn dialogue(ru: *Runtime, inst: Inst) RunTimeError!void {
//     const range = inst.data.range;
//
//     const speaker = ru.extra[range.start];
//
//     if (speaker != invalid_inst) {
//         // TODO: I need a way to extract speaker name.
//         // Extract interner's bytes and text slice to this struct.
//         const speaker_inst = ru.instructions[speaker];
//     }
// }
