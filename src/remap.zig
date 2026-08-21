const std = @import("std");
const Optimize = @import("optimize.zig").Optimize;
const in = @import("dia_ir.zig");

const Inst = in.Inst;
const InstId = in.InstId;
const invalid_inst = in.invalid_inst;

// ───────────────────────────────
//            REMAPPING
// ───────────────────────────────
//
// Remapping is a section of the optimizer that takes in the modified instructions from DCE
// and maps them to a new instruction and extra arraylist.

pub const Remap = @This();

opt: *Optimize,

new_instructions: std.ArrayList(Inst) = .empty,
new_extra: std.ArrayList(InstId) = .empty,

old_to_new_inst: std.ArrayList(InstId) = .empty,
old_to_new_extra: std.ArrayList(InstId) = .empty,

fn deinit(re: *Remap) void {
    re.new_instructions.deinit(re.opt.allocator);
    re.new_extra.deinit(re.opt.allocator);
    re.old_to_new_inst.deinit(re.opt.allocator);
    re.old_to_new_extra.deinit(re.opt.allocator);
}

// TODO: After remapping to new instructions and extra, we should
// use toOwnSlice() and return it in a struct.
pub fn rebuildBlocksAndExtra(opt: *Optimize, root_idx: InstId) !void {
    var remap: Remap = .{
        .opt = opt,
    };
    defer remap.deinit();

    // After constant folding and propagation, we can assume
    // the number of new instructions will be less or equal than
    // the number of old instructions.
    try remap.new_instructions.ensureTotalCapacityPrecise(
        opt.allocator, opt.instructions.len
    );
    try remap.new_extra.ensureTotalCapacityPrecise(
        opt.allocator, opt.instructions.len
    );

    try remap.old_to_new_inst.ensureTotalCapacityPrecise(
        opt.allocator, opt.instructions.len
    );
    try remap.old_to_new_extra.ensureTotalCapacityPrecise(
        opt.allocator, opt.instructions.len
    );

    remap.old_to_new_inst.appendNTimesAssumeCapacity(
        invalid_inst, remap.old_to_new_inst.capacity
    );

    remap.old_to_new_extra.appendNTimesAssumeCapacity(
        invalid_inst, remap.old_to_new_extra.capacity
    );

    const root_block = opt.instructions[root_idx];
    const range = root_block.data.range;
    const start = range.start;
    const end = start + range.len;

    const new_start: InstId = @intCast(remap.new_extra.items.len);

    for (start .. end) |idx| {
        const stmt_id = opt.extra[idx];

        if (!opt.live.contains(stmt_id)) continue;
        const new_id = remap.rebuildInst(stmt_id);

        remap.new_extra.appendAssumeCapacity(new_id);
    }

    const new_len: InstId = @intCast(remap.new_extra.items.len - new_start);

    var new_block: Inst = root_block;
    new_block.data.range = .{
        .start = new_start,
        .len = new_len,
    };

    const new_id: InstId = @intCast(remap.new_instructions.items.len);

    remap.old_to_new_inst.items[root_idx] = new_id;
    remap.new_instructions.appendAssumeCapacity(new_block);

    try remap.new_instructions.shrinkToLen(opt.allocator);
    try remap.new_extra.shrinkToLen(opt.allocator);
}

fn rebuildInst(re: *Remap, old_id: InstId) InstId {
    const new_id: InstId = @intCast(re.new_instructions.items.len);
    re.old_to_new_inst.items[old_id] = new_id;

    var inst = re.opt.instructions[old_id];

    switch (inst.tag) {
        .store => inst.data.store.value = re.rebuildInst(inst.data.store.value),
        // TODO: Handle label since it contains blocks as well.
        .branch => re.rebuildBranch(old_id),
        .dialogue => re.rebuildDialogue(old_id),

        .add, .sub, .mul, .div,
        .eql, .not_eql,
        .less, .less_or_eql,
        .greater, .greater_or_eql,
        .bool_and, .bool_or => {
            inst.data.binary.lhs = re.rebuildInst(inst.data.binary.lhs);
            inst.data.binary.rhs = re.rebuildInst(inst.data.binary.rhs);
        },
        else => {},
    }

    re.new_instructions.appendAssumeCapacity(inst);

    return new_id;
}

fn rebuildBranch(re: *Remap, old_id: InstId) void {
    // This is for compile time branch.
    if (re.opt.branch_result.get(old_id)) |block_id| {
        re.rebuildBlockContents(block_id);
        return;
    }

    // This is for runtime branch.
    const old = re.opt.instructions[old_id];
    const range = old.data.range;
    const old_start = range.start;

    const new_start: InstId = @intCast(re.new_extra.items.len);
    const cond_id = re.opt.extra[old_start];
    const then_id = re.opt.extra[old_start + 1];
    const else_id = re.opt.extra[old_start + 2];

    const new_cond = re.rebuildInst(cond_id);
    const new_then = re.rebuildBlock(then_id);

    re.new_extra.appendAssumeCapacity(new_cond);
    re.new_extra.appendAssumeCapacity(new_then);

    if (else_id != invalid_inst) {
        const new_else = re.rebuildBlock(else_id);
        re.new_extra.appendAssumeCapacity(new_else);
    } else {
        re.new_extra.appendAssumeCapacity(invalid_inst);
    }

    var new_branch: Inst = old;
    new_branch.data.range.start = new_start;

    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(new_branch);
}

fn rebuildDialogue(re: *Remap, old_id: InstId) void {
    const old = re.opt.instructions[old_id];
    const range = old.data.range;
    const old_start = range.start;
    const old_end = old_start + range.len;
    const new_start: InstId = @intCast(re.new_extra.items.len);

    for (old_start + 1 .. old_end - 1) |idx| {
        const stmt_idx = re.opt.extra[idx];
        
        if (!re.opt.live.contains(stmt_idx))
            continue;

        const new_stmt = re.rebuildInst(stmt_idx);
        re.new_extra.appendAssumeCapacity(new_stmt);
    }

    const jump_id = re.opt.extra[old_end - 1];
    if (jump_id != invalid_inst) {
        const jump = re.opt.instructions[jump_id];
        const new_id = re.rebuildInst(jump.data.jump);
        re.new_extra.appendAssumeCapacity(new_id);
    } else {
        re.new_extra.appendAssumeCapacity(invalid_inst);
    }

    const new_len: InstId = @intCast(re.new_extra.items.len - new_start);
    var new_dialogue: Inst = old;
    new_dialogue.data.range = .{
        .start = new_start,
        .len = new_len,
    };
    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(new_dialogue);
}

fn rebuildBlock(re: *Remap, old_id: InstId) InstId {
    const old = re.opt.instructions[old_id];

    const range = old.data.range;
    const old_start = range.start;
    const old_end = old_start + range.len;
    const new_start: InstId = @intCast(re.new_extra.items.len);

    for (old_start .. old_end) |idx| {
        const stmt_idx = re.opt.extra[idx];
        
        if (!re.opt.live.contains(stmt_idx))
            continue;

        const new_stmt = re.rebuildInst(stmt_idx);
        re.new_extra.appendAssumeCapacity(new_stmt);
    }

    const new_len: u32 = @intCast(re.new_extra.items.len - new_start);
    var new_block: Inst = old;
    new_block.data.range = .{
        .start = new_start,
        .len = new_len,
    };
    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(new_block);

    return new_id;
}

fn rebuildBlockContents(re: *Remap, block_id: InstId) void {
    const block_inst = re.opt.instructions[block_id];
    const range = block_inst.data.range;

    for (range.start..range.start + range.len) |i| {
        const stmt_id = re.opt.extra[i];

        if (!re.opt.live.contains(stmt_id))
            continue;

        _ = re.rebuildInst(stmt_id);
    }
}
