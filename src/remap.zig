const std = @import("std");
const Optimize = @import("optimize.zig").Optimize;
const ir = @import("dia_ir.zig");

const InstId = ir.InstId;
const Inst = ir.Inst;
const invalid_inst = ir.invalid_inst;

// ───────────────────────────────
//            REMAPPING
// ───────────────────────────────
//
// Remapping is a section of the optimizer that takes in the modified instructions from DCE
// and maps them to a new instruction and extra arraylist.

pub fn rebuildBlocksAndExtra(opt: *Optimize, root_idx: InstId) void {
    const root_block = opt.instructions[root_idx];
    const range = root_block.data.range;
    const start = range.start;
    const end = start + range.len;

    const new_start: InstId = @intCast(opt.new_extra.items.len);

    for (start .. end) |idx| {
        const stmt_id = opt.extra[idx];

        if (!opt.live.contains(stmt_id)) continue;
        const new_id = opt.rebuildInst(stmt_id);

        opt.new_extra.appendAssumeCapacity(new_id);
    }

    const new_len: InstId = @intCast(opt.new_extra.items.len - new_start);

    var new_block: Inst = root_block;
    new_block.data.range = .{
        .start = new_start,
        .len = new_len,
    };

    const new_id: InstId = @intCast(opt.new_instructions.items.len);

    opt.old_to_new_inst.items[root_idx] = new_id;
    opt.new_instructions.appendAssumeCapacity(new_block);
}

fn rebuildInst(opt: *Optimize, old_id: InstId) InstId {
    const new_id: InstId = @intCast(opt.new_instructions.items.len);
    opt.old_to_new_inst.items[old_id] = new_id;

    var inst = opt.instructions[old_id];

    switch (inst.tag) {
        .store => inst.data.store.value = opt.rebuildInst(inst.data.store.value),
        // TODO: Handle label since it contains blocks as well.
        .branch => opt.rebuildBranch(old_id),
        .dialogue => opt.rebuildDialogue(old_id),

        .add, .sub, .mul, .div,
        .eql, .not_eql,
        .less, .less_or_eql,
        .greater, .greater_or_eql,
        .bool_and, .bool_or => {
            inst.data.binary.lhs = opt.rebuildInst(inst.data.binary.lhs);
            inst.data.binary.rhs = opt.rebuildInst(inst.data.binary.rhs);
        },
        else => {},
    }

    opt.new_instructions.appendAssumeCapacity(inst);

    return new_id;
}

fn rebuildBranch(opt: *Optimize, old_id: InstId) void {
    // This is for compile time branch.
    if (opt.branch_result.get(old_id)) |block_id| {
        opt.rebuildBlockContents(block_id);
        return;
    }

    // This is for runtime branch.
    const old = opt.instructions[old_id];
    const range = old.data.range;
    const old_start = range.start;

    const new_start: InstId = @intCast(opt.new_extra.items.len);
    const cond_id = opt.extra[old_start];
    const then_id = opt.extra[old_start + 1];
    const else_id = opt.extra[old_start + 2];

    const new_cond = opt.rebuildInst(cond_id);
    const new_then = opt.rebuildBlock(then_id);

    opt.new_extra.appendAssumeCapacity(new_cond);
    opt.new_extra.appendAssumeCapacity(new_then);

    if (else_id != invalid_inst) {
        const new_else = opt.rebuildBlock(else_id);
        opt.new_extra.appendAssumeCapacity(new_else);
    } else {
        opt.new_extra.appendAssumeCapacity(invalid_inst);
    }

    var new_branch: Inst = old;
    new_branch.data.range.start = new_start;

    const new_id: InstId = @intCast(opt.new_instructions.items.len);

    opt.old_to_new_inst.items[old_id] = new_id;
    opt.new_instructions.appendAssumeCapacity(new_branch);
}

fn rebuildDialogue(opt: *Optimize, old_id: InstId) void {
    const old = opt.instructions[old_id];
    const range = old.data.range;
    const old_start = range.start;
    const old_end = old_start + range.len;
    const new_start: InstId = @intCast(opt.new_extra.items.len);

    for (old_start + 1 .. old_end - 1) |idx| {
        const stmt_idx = opt.extra[idx];
        
        if (!opt.live.contains(stmt_idx))
            continue;

        const new_stmt = opt.rebuildInst(stmt_idx);
        opt.new_extra.appendAssumeCapacity(new_stmt);
    }

    const jump_id = opt.extra[old_end - 1];
    if (jump_id != invalid_inst) {
        const jump = opt.instructions[jump_id];
        const new_id = opt.rebuildInst(jump.data.jump);
        opt.new_extra.appendAssumeCapacity(new_id);
    } else {
        opt.new_extra.appendAssumeCapacity(invalid_inst);
    }

    const new_len: InstId = @intCast(opt.new_extra.items.len - new_start);
    var new_dialogue: Inst = old;
    new_dialogue.data.range = .{
        .start = new_start,
        .len = new_len,
    };
    const new_id: InstId = @intCast(opt.new_instructions.items.len);

    opt.old_to_new_inst.items[old_id] = new_id;
    opt.new_instructions.appendAssumeCapacity(new_dialogue);
}

fn rebuildBlock(opt: *Optimize, old_id: InstId) InstId {
    const old = opt.instructions[old_id];

    const range = old.data.range;
    const old_start = range.start;
    const old_end = old_start + range.len;
    const new_start: InstId = @intCast(opt.new_extra.items.len);

    for (old_start .. old_end) |idx| {
        const stmt_idx = opt.extra[idx];
        
        if (opt.live.contains(stmt_idx))
            continue;

        const new_stmt = opt.rebuildInst(stmt_idx);
        opt.new_extra.appendAssumeCapacity(new_stmt);
    }

    const new_len: u32 = @intCast(opt.new_extra.items.len - new_start);
    var new_block: Inst = old;
    new_block.data.range = .{
        .start = new_start,
        .len = new_len,
    };
    const new_id: InstId = @intCast(opt.new_instructions.items.len);

    opt.old_to_new_inst.items[old_id] = new_id;
    opt.new_instructions.appendAssumeCapacity(new_block);

    return new_id;
}

fn rebuildBlockContents(opt: *Optimize, block_id: InstId) void {
    const block_inst = opt.instructions[block_id];
    const range = block_inst.data.range;

    for (range.start..range.start + range.len) |i| {
        const stmt_id = opt.extra[i];

        if (!opt.live.contains(stmt_id))
            continue;

        _ = opt.rebuildInst(stmt_id);
    }
}
