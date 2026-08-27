const std = @import("std");
const ir = @import("dia_ir.zig");
const Optimize = @import("optimize.zig").Optimize;
const TokenIndex = @import("token.zig").TokenIndex;

const Inst = ir.Inst;
const InstId = ir.InstId;
const invalid_inst = ir.invalid_inst;

// ───────────────────────────────
//            REMAPPING
// ───────────────────────────────
//
// Remapping is a section of the optimizer that takes in the modified instructions from DCE
// and maps them to a new instruction and extra arraylist.

pub const NewInsts = struct {
    instructions: []Inst,
    extra: []InstId,
};

pub const Remap = @This();

opt: *Optimize,

new_instructions: std.ArrayList(Inst) = .empty,
new_extra: std.ArrayList(InstId) = .empty,

old_to_new_inst: std.ArrayList(InstId) = .empty,

fn deinit(re: *Remap) void {
    re.new_instructions.deinit(re.opt.allocator);
    re.new_extra.deinit(re.opt.allocator);
    re.old_to_new_inst.deinit(re.opt.allocator);
}

pub fn rebuildBlocksAndExtra(opt: *Optimize, root_idx: InstId) !NewInsts {
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
        opt.allocator, opt.extra.len
    );

    try remap.old_to_new_inst.ensureTotalCapacityPrecise(
        opt.allocator, opt.instructions.len
    );

    // To avoid out of bound errors, we need to insert invalid_inst.
    remap.old_to_new_inst.appendNTimesAssumeCapacity(
        invalid_inst, remap.old_to_new_inst.capacity
    );
    const root_block = opt.instructions[root_idx];
    const range = root_block.data.range;

    _ = remap.rebuildBlock(
        root_idx,
        .block,
        root_block.token_pos,
        range.start,
        range.start + range.len
    );

    // MAKE SURE TO FREE INSTRUCTIONS AND EXTRA AFTERWARDS.
    return .{
        .instructions = try remap.new_instructions.toOwnedSlice(opt.allocator),
        .extra = try remap.new_extra.toOwnedSlice(opt.allocator),
    };
}

fn rebuildBlock(re: *Remap, old_id: InstId, comptime tag: Inst.Tag, token_pos: TokenIndex, old_start: u32, old_end: u32) InstId {
    const new_start: InstId = @intCast(re.new_extra.items.len);

    for (old_start .. old_end) |idx| {
        const stmt_idx = re.opt.extra[idx];

        if (!re.opt.live.contains(stmt_idx))
            continue;

        const new_stmt = re.rebuildStmt(stmt_idx);
        re.new_extra.appendAssumeCapacity(new_stmt);
    }

    const new_len: u32 = @intCast(re.new_extra.items.len - new_start);
    const new_block: Inst = .{
        .tag = tag,
        .token_pos = token_pos,
        .data = .{
            .range = .{
                .start = new_start,
                .len = new_len,
            }
        }
    };

    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(new_block);

    return new_id;
}

fn rebuildStmt(re: *Remap, old_id: InstId) InstId {
    const new_id: InstId = @intCast(re.new_instructions.items.len);

    const inst = re.opt.instructions[old_id];

    switch (inst.tag) {
        .store => re.rebuildStore(old_id),
        .branch => re.rebuildBranch(old_id),
        .dialogue, .choice => re.rebuildDialogue(old_id),
        .label_block => re.rebuildLabel(old_id),
        else => unreachable,
    }

    re.old_to_new_inst.items[old_id] = new_id;
    return new_id;
}

// No need to remap symbol since Symbols is stored separately
fn rebuildStore(re: *Remap, old_id: InstId) void {
    const inst = re.opt.instructions[old_id];
    re.opt.instructions[old_id].data.store.value = re.rebuildExpr(inst.data.store.value);

    re.new_instructions.appendAssumeCapacity(re.opt.instructions[old_id]);
}

fn rebuildExpr(re: *Remap, expr: InstId) InstId {
    const old_expr = re.opt.instructions[expr];
    const new_expr: InstId = @intCast(re.new_instructions.items.len);

    switch (old_expr.tag) {
        .load => re.opt.instructions[expr].data.load = new_expr,
        .add, .sub, .mul, .div,
        .eql, .not_eql,
        .less, .less_or_eql,
        .greater, .greater_or_eql,
        .bool_and, .bool_or => {
            const binary = old_expr.data.binary;
            re.opt.instructions[expr].data.binary.lhs = re.rebuildExpr(binary.lhs);
            re.opt.instructions[expr].data.binary.rhs = re.rebuildExpr(binary.rhs);
        },
        .constant, .text, .label => {},
        else => unreachable,
    }

    re.old_to_new_inst.items[expr] = new_expr;
    re.new_instructions.appendAssumeCapacity(re.opt.instructions[expr]);
    return new_expr;
}

fn rebuildOptionalExpr(re: *Remap, extra_inst: InstId) void {
    const new_expr: InstId = @intCast(re.new_instructions.items.len);

    if (extra_inst != invalid_inst) {
        const old_expr = re.opt.instructions[extra_inst];

        switch (old_expr.tag) {
            .speaker => re.opt.instructions[extra_inst].data.load = new_expr,
            .jump => {},
            else => unreachable,
        }

        re.new_extra.appendAssumeCapacity(new_expr);
        re.new_instructions.appendAssumeCapacity(re.opt.instructions[extra_inst]);
    } else {
        re.new_extra.appendAssumeCapacity(invalid_inst);
    }
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

    const new_cond = re.rebuildStmt(cond_id);

    const then_block = re.opt.instructions[then_id];
    const t_range = then_block.data.range;
    const new_then = re.rebuildBlock(
        then_id,
        .block,
        then_block.token_pos,
        t_range.start,
        t_range.start + t_range.len
    );

    var new_else: InstId = invalid_inst;
    if (else_id != invalid_inst) {
        const else_block = re.opt.instructions[else_id];
        const e_range = else_block.data.range;
        new_else = re.rebuildBlock(
            else_id,
            .block,
            else_block.token_pos,
            e_range.start,
            e_range.start + e_range.len
        );
    }

    re.new_extra.appendSliceAssumeCapacity(&[_]InstId{
        new_cond, new_then, new_else
    });

    // A branch's length is always 3. No need to get a new len.
    re.opt.instructions[old_id].data.range.start = new_start;

    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(re.opt.instructions[old_id]);
}

fn rebuildDialogue(re: *Remap, old_id: InstId) void {
    const old = re.opt.instructions[old_id];
    const range = old.data.range;
    const old_start = range.start;
    const old_end = old_start + range.len;
    const new_start: InstId = @intCast(re.new_extra.items.len);

    const old_speaker = re.opt.extra[range.start];
    re.rebuildOptionalExpr(old_speaker);

    for (old_start + 1 .. old_end - 1) |idx| {
        const stmt_idx = re.opt.extra[idx];

        const new_stmt = re.rebuildExpr(stmt_idx);
        re.new_extra.appendAssumeCapacity(new_stmt);
    }

    const old_jump = re.opt.extra[old_end - 1];
    re.rebuildOptionalExpr(old_jump);

    const new_len: InstId = @intCast(re.new_extra.items.len - new_start);
    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.opt.instructions[old_id].data.range.start = new_start;
    re.opt.instructions[old_id].data.range.len = new_len;

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(re.opt.instructions[old_id]);
}

fn rebuildLabel(re: *Remap, old_id: InstId) void {
    const old = re.opt.instructions[old_id];
    const range = old.data.range;
    const new_start: InstId = @intCast(re.new_extra.items.len);

    const label_id = re.opt.extra[range.start];
    const label = re.rebuildExpr(label_id);

    re.new_extra.appendAssumeCapacity(label);

    // Skip the first
    for (range.start + 1 .. range.start + range.len) |i| {
        const stmt_id = re.opt.extra[i];

        if (!re.opt.live.contains(stmt_id))
            continue;

        const new_stmt = re.rebuildStmt(stmt_id);
        re.new_extra.appendAssumeCapacity(new_stmt);
    }

    const new_len: InstId = @intCast(re.new_extra.items.len - new_start);
    const new_id: InstId = @intCast(re.new_instructions.items.len);

    re.opt.instructions[old_id].data.range.start = new_start;
    re.opt.instructions[old_id].data.range.len = new_len;

    re.old_to_new_inst.items[old_id] = new_id;
    re.new_instructions.appendAssumeCapacity(re.opt.instructions[old_id]);
}

fn rebuildBlockContents(re: *Remap, block_id: InstId) void {
    const block_inst = re.opt.instructions[block_id];
    const range = block_inst.data.range;

    for (range.start..range.start + range.len) |i| {
        const stmt_id = re.opt.extra[i];

        if (!re.opt.live.contains(stmt_id))
            continue;

        const new_stmt = re.rebuildStmt(stmt_id);
        re.new_extra.appendAssumeCapacity(new_stmt);
    }
}
