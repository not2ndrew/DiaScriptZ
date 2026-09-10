const std = @import("std");
const frontend = @import("frontend");
const dir = @import("dia_ir.zig");
const Optimize = @import("optimize.zig").Optimize;

const Allocator = std.mem.Allocator;

const TokenIndex = frontend.token.TokenIndex;

const Inst = dir.Inst;
const InstId = dir.InstId;
const invalid_inst = dir.invalid_inst;

const Error = Allocator.Error;

// ───────────────────────────────
//            REMAPPING
// ───────────────────────────────
//
// Remapping is a section of the optimizer that takes in the modified instructions from DCE
// and maps them to a new instruction and extra arraylist.

pub const NewIR = struct {
    instructions: []const Inst,
    extra: []const InstId,
    num_of_declar: u32,

    pub fn deinit(ir: *NewIR, allocator: Allocator) void {
        allocator.free(ir.instructions);
        allocator.free(ir.extra);
    }
};

pub const Remap = @This();

allocator: Allocator,
instructions: []const Inst,
extra: []const InstId,
// KV pair is condition id -> block id
branch_result: *std.array_hash_map.Auto(InstId, InstId),

live: *std.array_hash_map.Auto(InstId, void),

new_instructions: std.ArrayList(Inst) = .empty,
new_extra: std.ArrayList(InstId) = .empty,

old_to_new_inst: std.ArrayList(InstId) = .empty,

/// Number of variable or label declarations.
num_of_declar: u32 = 0,

fn deinit(re: *Remap) void {
    re.new_instructions.deinit(re.allocator);
    re.new_extra.deinit(re.allocator);
    re.old_to_new_inst.deinit(re.allocator);
}

pub fn remapOldToNewInsts(opt: *Optimize, root_idx: InstId) Error!NewIR {
    var remap: Remap = .{
        .allocator = opt.allocator,
        .instructions = opt.instructions,
        .extra = opt.extra,
        .branch_result = &opt.branch_result,
        .live = &opt.live,
    };
    defer remap.deinit();

    // After constant folding and propagation, we can assume
    // the number of new instructions will be less or equal than
    // the number of old instructions.
    try remap.new_instructions.ensureTotalCapacityPrecise(
        opt.allocator, opt.instructions.len
    );

    try remap.new_extra.ensureTotalCapacityPrecise(
        opt.allocator, opt.extra.len
    );

    try remap.old_to_new_inst.ensureTotalCapacityPrecise(
        opt.allocator, opt.instructions.len
    );

    // To avoid out of bound errors, we need to insert invalid_inst.
    remap.old_to_new_inst.appendNTimesAssumeCapacity(
        invalid_inst, remap.old_to_new_inst.capacity
    );

    _ = try remap.rebuildBlock(
        root_idx,
        .block,
    );

    // MAKE SURE TO FREE INSTRUCTIONS AND EXTRA AFTERWARDS.
    return .{
        .instructions = try remap.new_instructions.toOwnedSlice(opt.allocator),
        .extra = try remap.new_extra.toOwnedSlice(opt.allocator),
        .num_of_declar = remap.num_of_declar,
    };
}

fn rebuildExpr(re: *Remap, old_id: InstId) InstId {
    const old_expr = re.instructions[old_id];
    var new_inst = old_expr;

    switch (old_expr.tag) {
        .load => {},
        .add, .sub, .mul, .div,
        .eql, .not_eql,
        .less, .less_or_eql,
        .greater, .greater_or_eql,
        .bool_and, .bool_or => {
            const binary = old_expr.data.binary;
            new_inst.data.binary.lhs = re.rebuildExpr(binary.lhs);
            new_inst.data.binary.rhs = re.rebuildExpr(binary.rhs);
        },
        .constant, .text, .label => {},
        else => unreachable,
    }

    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(new_inst);
    return new_id;
}

fn rebuildOptionalExpr(re: *Remap, old_id: InstId) void {
    if (old_id == invalid_inst) {
        re.new_extra.appendAssumeCapacity(invalid_inst);
        return;
    }

    const old_inst = re.instructions[old_id];
    const new_id: InstId = @intCast(re.new_instructions.items.len);

    switch (old_inst.tag) {
        .speaker => {},
        .jump => {},
        else => unreachable,
    }

    re.old_to_new_inst.items[old_id] = new_id;

    re.new_instructions.appendAssumeCapacity(old_inst);
    re.new_extra.appendAssumeCapacity(new_id);
}


fn rebuildBlock(re: *Remap, old_id: InstId, comptime tag: Inst.Tag) Error!InstId {
    var new_inst = re.instructions[old_id];

    const range = new_inst.data.range;
    const old_start = range.start;
    const old_end = old_start + range.len;

    var stmt_list: std.ArrayList(InstId) = .empty;
    defer stmt_list.deinit(re.allocator);

    try stmt_list.ensureTotalCapacityPrecise(re.allocator, range.len);

    for (old_start .. old_end) |idx| {
        const stmt_idx = re.extra[idx];

        if (!re.live.contains(stmt_idx))
            continue;

        const new_stmt = try re.rebuildStmt(stmt_idx);
        stmt_list.appendAssumeCapacity(new_stmt);
    }

    const new_start: InstId = @intCast(re.new_extra.items.len);

    re.new_extra.appendSliceAssumeCapacity(stmt_list.items);

    const new_len: u32 = @intCast(re.new_extra.items.len - new_start);

    new_inst.tag = tag;
    new_inst.data.range.start = new_start;
    new_inst.data.range.len = new_len;

    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(new_inst);

    return new_id;
}

fn rebuildStmt(re: *Remap, old_id: InstId) Error!InstId {
    const inst = re.instructions[old_id];

    return switch (inst.tag) {
        .declaration => re.rebuildDeclar(old_id),
        .store => re.rebuildStore(old_id),
        .branch => re.rebuildBranch(old_id),
        // .dialogue, .choice => re.rebuildDialogue(old_id),
        // .label_block => re.rebuildLabel(old_id),
        // .choice_block => re.rebuildChoiceBlock(old_id),
        else => unreachable,
    };
}

fn rebuildDeclar(re: *Remap, old_id: InstId) InstId {
    re.num_of_declar += 1;
    return re.rebuildStore(old_id);
}

// No need to remap symbol since Symbols is stored separately
fn rebuildStore(re: *Remap, old_id: InstId) InstId {
    var new_inst = re.instructions[old_id];

    new_inst.data.store.value = re.rebuildExpr(new_inst.data.store.value);

    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.new_instructions.appendAssumeCapacity(new_inst);

    re.old_to_new_inst.items[old_id] = new_id;
    return new_id;
}

fn rebuildBranch(re: *Remap, old_id: InstId) Error!InstId {
    if (re.branch_result.get(old_id)) |block_id| {
        try re.rebuildBlockContents(block_id);

        // Decrease new_id by 1 because we do NOT append the current block inst.
        // Only consider statements of instructions rather than a block of instructions.
        const new_id: InstId = @intCast(re.new_instructions.items.len - 1);

        re.old_to_new_inst.items[old_id] = new_id;
        return new_id;
    }

    // This is for runtime branch.
    var new_inst = re.instructions[old_id];
    const range = new_inst.data.range;
    const old_start = range.start;

    const cond_id = re.extra[old_start];
    const then_id = re.extra[old_start + 1];
    const else_id = re.extra[old_start + 2];

    const new_cond = re.rebuildExpr(cond_id);

    const new_then = try re.rebuildBlock(then_id, .block);

    var new_else: InstId = invalid_inst;
    if (else_id != invalid_inst) {
        new_else = try re.rebuildBlock(else_id, .block);
    }

    const new_start: InstId = @intCast(re.new_extra.items.len);

    re.new_extra.appendSliceAssumeCapacity(&[_]InstId{
        new_cond, new_then, new_else
    });

    // A branch's length is always 3. No need to get a new len.
    new_inst.data.range.start = new_start;

    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(new_inst);

    return new_id;
}

// fn rebuildDialogue(re: *Remap, old_id: InstId) InstId {
//     var new_inst = re.instructions[old_id];
//     const range = new_inst.data.range;
//     const old_start = range.start;
//     const old_end = old_start + range.len;
//     const new_start: InstId = @intCast(re.new_extra.items.len);
//
//     const old_speaker = re.extra[range.start];
//     re.rebuildOptionalExpr(old_speaker);
//
//     for (old_start + 1 .. old_end - 1) |idx| {
//         const stmt_idx = re.extra[idx];
//
//         const new_stmt = re.rebuildExpr(stmt_idx);
//         re.new_extra.appendAssumeCapacity(new_stmt);
//     }
//
//     const old_jump = re.extra[old_end - 1];
//     re.rebuildOptionalExpr(old_jump);
//
//     const new_len: InstId = @intCast(re.new_extra.items.len - new_start);
//     const new_id: InstId = @intCast(re.new_instructions.items.len);
//
//     new_inst.data.range.start = new_start;
//     new_inst.data.range.len = new_len;
//
//     re.old_to_new_inst.items[old_id] = new_id;
//     re.new_instructions.appendAssumeCapacity(new_inst);
//
//     return new_id;
// }
//
// fn rebuildChoiceBlock(re: *Remap, old_id: InstId) InstId {
//     const old = re.instructions[old_id];
//     const range = old.data.range;
//     const old_start = range.start;
//     const old_end = old_start + range.len;
//     const new_start: InstId = @intCast(re.new_extra.items.len);
//
//     for (old_start .. old_end) |idx| {
//         const stmt_idx = re.extra[idx];
//
//         const new_stmt = re.rebuildDialogue(stmt_idx);
//         re.new_extra.appendAssumeCapacity(new_stmt);
//     }
//
//     const new_len: u32 = @intCast(re.new_extra.items.len - new_start);
//     const new_block: Inst = .{
//         .tag = .choice_block,
//         .token_pos = old.token_pos,
//         .data = .{
//             .range = .{
//                 .start = new_start,
//                 .len = new_len,
//             }
//         }
//     };
//
//     const new_id: InstId = @intCast(re.new_instructions.items.len);
//
//     re.old_to_new_inst.items[old_id] = new_id;
//     re.new_instructions.appendAssumeCapacity(new_block);
//
//     return new_id;
// }
//
// fn rebuildLabel(re: *Remap, old_id: InstId) Error!InstId {
//     var new_inst = re.instructions[old_id];
//     const range = new_inst.data.range;
//     const new_start: InstId = @intCast(re.new_extra.items.len);
//
//     const label_id = re.extra[range.start];
//     const label = re.rebuildExpr(label_id);
//
//     re.num_of_declar += 1;
//     re.new_extra.appendAssumeCapacity(label);
//
//     // Skip the first
//     for (range.start + 1 .. range.start + range.len) |i| {
//         const stmt_id = re.extra[i];
//
//         if (!re.live.contains(stmt_id))
//             continue;
//
//         const new_stmt = try re.rebuildStmt(stmt_id);
//         re.new_extra.appendAssumeCapacity(new_stmt);
//     }
//
//     const new_len: InstId = @intCast(re.new_extra.items.len - new_start);
//     const new_id: InstId = @intCast(re.new_instructions.items.len);
//
//     new_inst.data.range.start = new_start;
//     new_inst.data.range.len = new_len;
//
//     re.old_to_new_inst.items[old_id] = new_id;
//     re.new_instructions.appendAssumeCapacity(new_inst);
//
//     return new_id;
// }

fn rebuildBlockContents(re: *Remap, block_id: InstId) Error!void {
    const block_inst = re.instructions[block_id];
    const range = block_inst.data.range;

    for (range.start..range.start + range.len) |i| {
        const stmt_id = re.extra[i];

        if (!re.live.contains(stmt_id))
            continue;

        const new_stmt = try re.rebuildStmt(stmt_id);
        re.new_extra.appendAssumeCapacity(new_stmt);
    }
}
