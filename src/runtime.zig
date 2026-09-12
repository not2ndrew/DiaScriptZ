const std = @import("std");
const middle = @import("middle");
const backend = @import("backend");
const Compile = @import("compile.zig").Compile;

const Allocator = std.mem.Allocator;
const Io = std.Io;

const sem = middle.semantic;

const interner = middle.interner;
const InternPool = interner.InternPool;
const IdentId = interner.IdentId;

const dir = backend.ir;
const Inst = dir.Inst;
const InstId = dir.InstId;
const invalid_inst = dir.invalid_inst;

pub const IoError = Io.Cancelable || Io.Writer.Error;
pub const RunTimeError = Allocator.Error || IoError || error { Overflow, DivisionByZero, NoSpaceLeft };

pub const DIALOGUE_SIZE = 100;
// For an u8 integer, the maximum value is 255. Thus, the max digits is 3.
const MAX_DIGITS = 3;

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
// io: Io,
instructions: []const Inst,
extra: []const InstId,
pool: InternPool,

declarations: std.array_hash_map.Auto(IdentId, u8) = .empty,

pub fn runProgram(io: Io, allocator: Allocator, comp: Compile) RunTimeError!void {
    var runtime: Runtime = .{
        .allocator = allocator,
        // .io = io,
        .instructions = comp.instructions,
        .extra = comp.extra,
        .pool = comp.pool,
    };
    defer runtime.deinit();

    try runtime.declarations.ensureTotalCapacity(allocator, comp.num_of_declar);
    
    try runtime.run(io);
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
            return ru.declarations.get(inst.data.ident) orelse unreachable;
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

fn run(ru: *Runtime, io: Io) RunTimeError!void {
    const root_inst = ru.instructions[ru.instructions.len - 1];
    const range = root_inst.data.range;

    try ru.block(io, range.start, range.len);
}

fn block(ru: *Runtime, io: Io, start: u32, len: u32) RunTimeError!void {
    const end = start + len;
    for (start .. end) |idx| {
        const stmt_idx = ru.extra[idx];
        try ru.stmt(io, stmt_idx);
    }
}

fn stmt(ru: *Runtime, io: Io, inst_idx: InstId) RunTimeError!void {
    const inst = ru.instructions[inst_idx];
    return switch (inst.tag) {
        .declaration => ru.declaration(inst),
        .store => ru.storeValue(inst),
        .branch =>ru.branch(io, inst),
        .dialogue => ru.dialogue(io, inst),
        else => unreachable,
    };
}

fn declaration(ru: *Runtime, inst: Inst) RunTimeError!void {
    const store = inst.data.store;
    const value = try ru.eval(store.value);
    ru.declarations.putAssumeCapacityNoClobber(store.ident, value);
}

fn storeValue(ru: *Runtime, inst: Inst) RunTimeError!void {
    const store = inst.data.store;
    const value = try ru.eval(store.value);

    const entry = ru.declarations.getEntry(store.ident) orelse unreachable;
    entry.value_ptr.* = value;
}

fn branch(ru: *Runtime, io: Io, inst: Inst) RunTimeError!void {
    const range = inst.data.range;
    const cond = ru.extra[range.start];
    const then_block = ru.extra[range.start + 1];
    const else_block = ru.extra[range.start + 2];

    const branch_result = try ru.condition(cond);

    if (branch_result) {
        const then_inst = ru.instructions[then_block];
        const t_range = then_inst.data.range;
        try ru.block(io, t_range.start, t_range.len);
    } else {
        const else_inst = ru.instructions[else_block];
        const e_range = else_inst.data.range;
        try ru.block(io, e_range.start, e_range.len);
    }
}

fn dialogue(ru: *Runtime, io: Io, inst: Inst) RunTimeError!void {
    var buffer: [DIALOGUE_SIZE]u8 = undefined;
    var len: usize = 0;

    const range = inst.data.range;

    const speaker = ru.extra[range.start];

    if (speaker != invalid_inst) {
        const speaker_inst = ru.instructions[speaker];
        const name = ru.pool.getIdent(speaker_inst.data.ident);

        // TODO: This is inefficient. Using @memcpy twice.
        try appendSlice(&buffer, &len, name);
        try appendSlice(&buffer, &len, ": ");

        try ru.dialogueParts(&buffer, &len, range.start + 1, range.start + range.len - 1);

        try printDialogue(io, &buffer, len);
    }
}

fn appendSlice(buffer: []u8, pos: *usize, text: []const u8) RunTimeError!void {
    if (pos.* + text.len > buffer.len)
        return RunTimeError.OutOfMemory;

    @memcpy(buffer[pos.* .. pos.* + text.len], text);
    pos.* += text.len;
}

fn dialogueParts(ru: *Runtime, buffer: []u8, len: *usize, start: u32, end: u32) RunTimeError!void {
    for (start .. end) |idx| {
        const extra = ru.extra[idx];
        const inst = ru.instructions[extra];

        switch (inst.tag) {
            .text => {
                const span = inst.data.range;
                const text = ru.pool.texts[span.start .. span.start + span.len];
                try appendSlice(buffer, len, text);
            },
            .constant => {
                var buf: [MAX_DIGITS]u8 = undefined;
                const str = try std.fmt.bufPrint(&buf, "{d}", .{ inst.data.uint });
                try appendSlice(buffer, len, str);
            },
            .load => {
                var buf: [MAX_DIGITS]u8 = undefined;
                const num = ru.declarations.get(inst.data.ident) orelse unreachable;
                const str = try std.fmt.bufPrint(&buf, "{d}", .{ num });
                try appendSlice(buffer, len, str);
            },
            else => unreachable,
        }
    }
}

fn printDialogue(io: Io, text: []u8, len: usize) RunTimeError!void {
    // TODO: Depending on the Operating System (Windows, Linux),
    // there may be additional characters
    // For example:
    //    Windows has \r\n
    //    Linux only has \n
    //
    // Best solution is to create a customizer for dialogue system.
    // Do +1 for '\n'
    var buffer: [DIALOGUE_SIZE + 1]u8 = undefined;
    const stderr = try io.lockStderr(&buffer, std.zig.Color.terminalMode(.off));
    defer io.unlockStderr();

    const writer = stderr.terminal().writer;

    for (0 .. len) |i| {
        try writer.print("{c}", .{text[i]});
        try io.sleep(.fromMilliseconds(100), .awake);

        try writer.flush();
    }

    try writer.writeByte('\n');
    try writer.flush();
}
