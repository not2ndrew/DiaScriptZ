const std = @import("std");
const ir = @import("dia_ir.zig");
const in = @import("interner.zig");
const sem = @import("semantic.zig");
const Lower = @import("lower.zig").Lower;
const rebuildBlocksAndExtra = @import("remap.zig").rebuildBlocksAndExtra;

const Allocator = std.mem.Allocator;

const InstId = ir.InstId;
const DiaIR = ir.DiaIR;
const Inst = ir.Inst;
const Insts = std.ArrayList(Inst);

const IdentId = in.IdentId;
const invalid_inst = ir.invalid_inst;

const Symbol = sem.Symbol;
const SymbolId = sem.SymbolId;

const IntError = error {
    Overflow,
    DivisionByZero,
};

const Error = Allocator.Error || IntError;

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
lower: *const Lower,

instructions: []Inst,
extra: []InstId,

// TODO:
// 1) Fix the parser such that "true" and "false" are allowed.
//    Then, allow the KV pair to be SymbolId -> Value.
constants: std.array_hash_map.Auto(SymbolId, u8) = .empty,
// KV pair is condition id -> block id
branch_result: std.array_hash_map.Auto(InstId, InstId) = .empty,

live: std.array_hash_map.Auto(InstId, void) = .empty,

pub fn deinit(opt: *Optimize) void {
    opt.allocator.free(opt.instructions);
    opt.allocator.free(opt.extra);
    opt.constants.deinit(opt.allocator);
    opt.branch_result.deinit(opt.allocator);
    opt.live.deinit(opt.allocator);
}

// TODO: Optimizer needs diagnostics.
fn fold(tag: Inst.Tag, lhs: u8, rhs: u8) IntError!u8 {
    return switch (tag) {
        .add => std.math.add(u8, lhs, rhs) catch IntError.Overflow,
        .sub => std.math.sub(u8, lhs, rhs) catch IntError.Overflow,
        .mul => std.math.mul(u8, lhs, rhs) catch IntError.Overflow,
        .div => {
            if (rhs == 0) return IntError.DivisionByZero;
            return std.math.divTrunc(u8, lhs, rhs) catch IntError.Overflow;
        },
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

fn rewriteValue(opt: *Optimize, inst_idx: InstId, value: Value) void {
    const old = opt.instructions[inst_idx];

    switch (value) {
        .uint => |v| {
            opt.instructions[inst_idx] = .{
                .tag = .constant,
                .token_pos = old.token_pos,
                .data = .{ .uint = v },
            };
        },
        .boolean => |v| {
            opt.instructions[inst_idx] = .{
                .tag = .constant,
                .token_pos = old.token_pos,
                .data = .{ .boolean = v },
            };
        },
        .unknown => {},
    }
}

pub fn optimizeRoot(opt: *Optimize) Error!void {
    const root_idx: u32 = @intCast(opt.instructions.len - 1);
    const root_inst = opt.instructions[root_idx];
    const range = root_inst.data.range;

    // Pass 1: Constant fold and propagate.
    try opt.block(range.start, range.len);

    // Pass 2: Dead Code elimination
    // 1) Determine reachable instructions.
    //    Live blocks,
    //    Live instructions,
    //    Which branch is selected.
    var dce: DCE = .{ .opt = opt };
    defer dce.deinit();

    try dce.run(root_idx);

    // Pass 3: Recreate Instructions.
    const new_set = try opt.rebuildBlocksAndExtra(root_idx);

    for (new_set.instructions) |inst| {
        std.debug.print("Tag: {t}\n", .{inst.tag});
    }
    // leave this for now.
    opt.allocator.free(new_set.instructions);
    opt.allocator.free(new_set.extra);
}

fn block(opt: *Optimize, start: u32, len: u32) Error!void {
    const end = start + len;
    for (start..end) |idx| {
        const idx_cast: u32 = @intCast(idx);
        const stmt_idx = opt.extra[idx_cast];
        try opt.stmt(stmt_idx);
    }
}

fn stmt(opt: *Optimize, inst_idx: InstId) Error!void {
    const inst = opt.instructions[inst_idx];
    return switch (inst.tag) {
        .store => opt.storeVar(inst_idx),
        .branch => opt.foldBranch(inst_idx),
        .dialogue => opt.foldDialogue(inst),
        .label => opt.foldLabel(inst),
        else => {},
    };
}

// To perform comptime declaration,
// 1) Variable must be "const"
// 2) Variable must be assigned a number.
// Anything else is a runtime variable.
fn storeVar(opt: *Optimize, inst_idx: InstId) Error!void {
    const inst = opt.instructions[inst_idx];
    const store = inst.data.store;
    const symbol_id = store.symbol_id;
    const symbol = opt.lower.symbols[symbol_id];

    const value = try opt.eval(store.value);
    if (symbol.kind == .constant and value == .uint)
        try opt.constants.put(opt.allocator, symbol_id, value.uint);
}

fn eval(opt: *Optimize, inst_idx: InstId) IntError!Value {
    const inst = opt.instructions[inst_idx];

    return switch (inst.tag) {
        .constant => .{ .uint = inst.data.uint },
        .load => {
            const v = opt.constants.get(inst.data.load)
                orelse return .unknown;

            const value: Value = .{ .uint = v };
            opt.rewriteValue(inst_idx, value);
            return .{ .uint = v };
        },

        .add, .sub, .mul, .div => {
            const b = inst.data.binary;
            const lhs = try opt.eval(b.lhs);
            const rhs = try opt.eval(b.rhs);

            if (lhs == .uint and rhs == .uint) {
                const result = try fold(inst.tag, lhs.uint, rhs.uint);
                const value: Value = .{ .uint = result };
                opt.rewriteValue(inst_idx, value);

                return .{ .uint = result };
            }

            return .unknown;
        },

        .eql, .not_eql,
        .less, .less_or_eql,
        .greater, .greater_or_eql => {
            const b = inst.data.binary;
            const lhs = try opt.eval(b.lhs);
            const rhs = try opt.eval(b.rhs);

            if (lhs == .uint and rhs == .uint) {
                const result = compare(inst.tag, lhs.uint, rhs.uint);
                const value: Value = .{ .boolean = result };
                opt.rewriteValue(inst_idx, value);

                return .{ .boolean = result };
            }

            return .unknown;
        },

        .bool_and, .bool_or => {
            const b = inst.data.binary;
            const lhs = try opt.eval(b.lhs);

            switch (lhs) {
                .boolean => |v| {
                    const value: Value = .{ .boolean = v };
                    // Using logical equivalance, we can simply op immediately.
                    // false and ??? -> false
                    if (!v and inst.tag == .bool_and) {
                        opt.rewriteValue(inst_idx, value);
                        return .{ .boolean = false };
                    }

                    // true or ??? -> true
                    if (v and inst.tag == .bool_or) {
                        opt.rewriteValue(inst_idx, value);
                        return .{ .boolean = true };
                    }
                },
                else => {},
            }

            const rhs = try opt.eval(b.rhs);
            if (lhs == .boolean and rhs == .boolean) {
                const result = logicalOp(inst.tag, lhs.boolean, rhs.boolean);
                const value: Value = .{ .boolean = result };
                opt.rewriteValue(inst_idx, value);
                return .{ .boolean = result };
            }

            return .unknown;
        },
        else => .unknown,
    };
}

// branch range:
// extra[start + 0] = condition InstId
// extra[start + 1] = then Block InstId
// extra[start + 2] = else Block InstId or invalid_inst
fn foldBranch(opt: *Optimize, inst_idx: InstId) Error!void {
    const inst = opt.instructions[inst_idx];
    const range = inst.data.range;
    const start = range.start;

    const cond_id = opt.extra[start];
    const then_id = opt.extra[start + 1];
    const else_id = opt.extra[start + 2];

    const value = try opt.eval(cond_id);
    switch (value) {
        // Given a comptime op, we can optimize one branch
        // without check both branches.
        .boolean => |v| {
            const block_id = if (v)
                then_id
            else
                else_id;

            if (block_id == invalid_inst)
                return;

            const b = opt.instructions[block_id];
            const b_range = b.data.range;

            try opt.branch_result.putNoClobber(opt.allocator, inst_idx, block_id);
            try opt.block(b_range.start, b_range.len);
        },
        .unknown => {},
        else => unreachable,
    }
}

// ───────────────────────────────
//           DIALOGUE
// ───────────────────────────────

// Dialogue lines and dialogue branches contains
// the same format:
// [ speaker, dia_part_0, dia_part_1, ..., goto ]
fn foldDialogue(opt: *Optimize, inst: Inst) Error!void {
    const range = inst.data.range;
    const start = range.start;
    const end = start + range.len;

    // We can skip the speaker since we already know from Semantic
    // that speaker is valid. The last idx of the range is always the jump.
    // From Semantic, is also valid.
    //
    // Merging dialogue parts will be done at runtime regardless of
    // a variable's declaration type.
    for (start + 1.. end - 1) |idx| {
        const part_idx = opt.extra[idx];
        const part = opt.instructions[part_idx];

        switch (part.tag) {
            .text => {},
            else => _ = try opt.eval(part_idx),
        }
    }
}

// label extra_data layout:
// [ label_pos, stmt_1, stmt_2, stmt_3, ... , stmt_n ]
fn foldLabel(opt: *Optimize, inst: Inst) Error!void {
    const range = inst.data.range;
    const start = range.start;
    const end = start + range.len;

    // Increment 1 to avoid label ident.
    for (start + 1 .. end) |idx| {
        const stmt_idx = opt.extra[idx];
        try opt.stmt(stmt_idx);
    }
}

// ───────────────────────────────
//      DEAD CODE ELIMINATION
// ───────────────────────────────
// Dead Code Elimination (DCE) marks all instructions that will be used
// in the instructions. Any instruction that is NOT marked will be ignored.

const DCE = struct {
    opt: *Optimize,
    used_symbols: std.array_hash_map.Auto(SymbolId, void) = .empty,
    used_labels: std.array_hash_map.Auto(IdentId, void) = .empty,

    pub fn deinit(dce: *DCE) void {
        dce.used_symbols.deinit(dce.opt.allocator);
        dce.used_labels.deinit(dce.opt.allocator);
    }

    pub fn run(dce: *DCE, root_idx: InstId) Allocator.Error!void {
        const root_block = dce.opt.instructions[root_idx];
        const range = root_block.data.range;
        const start = range.start;
        const end = start + range.len;

        // Phase 1: Collect all uses
        for (start .. end) |idx| {
            const stmt_idx = dce.opt.extra[idx];
            try dce.collectStmtUses(stmt_idx);
        }

        // Phase 2: Mark all uses
        for (start .. end) |idx| {
            const stmt_idx = dce.opt.extra[idx];
            try dce.markInst(stmt_idx);
        }
    }

    // ───────────────────────────────
    //            PHASE 1
    // ───────────────────────────────

    fn collectStmtUses(dce: *DCE, inst_idx: InstId) Allocator.Error!void {
        const inst = dce.opt.instructions[inst_idx];

        switch (inst.tag) {
            .store => try dce.collectUses(inst.data.store.value),
            .branch => {
                // Comptime branch: Only 1 block needs to be marked.
                if (dce.opt.branch_result.get(inst_idx)) |block_id| {
                    if (block_id != invalid_inst)
                        try dce.collectBlockUses(block_id);
                } else {
                    // Runtime branch: Check condition, and two branches
                    const range = inst.data.range;
                    try dce.collectUses(dce.opt.extra[range.start]);

                    try dce.collectBlockUses(dce.opt.extra[range.start + 1]);

                    const else_id = dce.opt.extra[range.start + 2];
                    if (else_id != invalid_inst)
                        try dce.collectBlockUses(else_id);
                }
            },
            .dialogue => {
                const range = inst.data.range;
                const start = range.start;
                const end = start + range.len;
                const jump = dce.opt.extra[end];

                if (jump != invalid_inst)
                    try dce.used_labels.put(dce.opt.allocator, jump, {});

                for (start + 1 .. end - 1) |idx| {
                    const str_idx = dce.opt.extra[idx];
                    try dce.collectUses(str_idx);
                }
            },
            .label => {
                const range = inst.data.range;
                const start = range.start;
                const end = start + range.len;
                for (start + 1 .. end) |idx| {
                    const stmt_idx: InstId = @intCast(idx);
                    try dce.collectStmtUses(stmt_idx);
                }
            },
            else => {},
        }
    }

    fn collectUses(dce: *DCE, inst_idx: InstId) Allocator.Error!void {
        const inst = dce.opt.instructions[inst_idx];

        switch (inst.tag) {
            .load => try dce.used_symbols.put(dce.opt.allocator, inst.data.load, {}),

            .add, .sub, .mul, .div,
            .eql, .not_eql,
            .less, .less_or_eql,
            .greater, .greater_or_eql,
            .bool_and, .bool_or => {
                const binary = inst.data.binary;
                try dce.collectUses(binary.lhs);
                try dce.collectUses(binary.rhs);
            },
            else => {},
        }
    }

    fn collectBlockUses(dce: *DCE, block_idx: InstId) Allocator.Error!void {
        const block_inst = dce.opt.instructions[block_idx];
        const range = block_inst.data.range;
        const start = range.start;
        const end = start + range.len;

        for (start .. end) |idx| {
            const stmt_idx = dce.opt.extra[idx];
            try dce.collectStmtUses(stmt_idx);
        }
    }

    // ───────────────────────────────
    //            PHASE 2
    // ───────────────────────────────

    fn markInst(dce: *DCE, inst_idx: InstId) Allocator.Error!void {
        const inst = dce.opt.instructions[inst_idx];
        switch (inst.tag) {
            .store => {
                const store = inst.data.store;
                if (dce.used_symbols.contains(store.symbol_id))
                    try dce.opt.live.putNoClobber(dce.opt.allocator, inst_idx, {});
            },
            .branch => {
                const range = inst.data.range;
                try dce.opt.live.putNoClobber(dce.opt.allocator, inst_idx, {});
                try dce.markBlock(range.start, range.len);
            },
            .block => {
                const range = inst.data.range;
                try dce.markBlock(range.start, range.len);
            },
            .dialogue => {
                try dce.opt.live.putNoClobber(dce.opt.allocator, inst_idx, {});
            },
            .label => {
                const range = inst.data.range;
                const label_id = dce.opt.extra[range.start];

                if (dce.used_symbols.contains(label_id))
                    try dce.opt.live.putNoClobber(dce.opt.allocator, inst_idx, {})
                else
                    return;

                for (range.start + 1 .. range.start + range.len) |idx| {
                    const stmt_idx = dce.opt.extra[idx];
                    try dce.markInst(stmt_idx);
                }
            },
            else => {},
        }
    }

    fn markBlock(dce: *DCE, start: InstId, len: InstId) Allocator.Error!void {
        for (start .. start + len) |idx| {
            const stmt_idx = dce.opt.extra[idx];
            try dce.markInst(stmt_idx);
        }
    }
};
