const std = @import("std");
const frontend = @import("frontend");
const middle = @import("middle");

const Allocator = std.mem.Allocator;

const TokenIndex = frontend.token.TokenIndex;

const nod = frontend.node;
const Node = nod.Node;
const NodeIndex = nod.NodeIndex;
const invalid_node = nod.invalid_node;

const Ast = frontend.ast.Ast;

const sem = middle.semantic;
const Decorated = sem.DecoratedAst.Decorated;

const in = middle.interner;
const IdentId = in.IdentId;
const InternPool = in.InternPool;
const Span = in.Span;

const Error = Allocator.Error;

pub const InstId = u32;
pub const invalid_inst = std.math.maxInt(InstId);

pub const BlockId = u32;
pub const invalid_block = std.math.maxInt(BlockId);

// Every basic block has zero or more ordinary instructions
// followed by exactly one terminator, except an unterminated
// block while CFG construction is in progress.
pub const Block = struct {
    first_inst: InstId,
    inst_count: u32,
};

pub const UnresolvedJump = struct {
    ident_id: IdentId,
    jump_id: InstId,
};

// Not every Instruction needs to store TokenIndex
// for reporting errors.
// For every union data that can fail, insert TokenIndex.
pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        // Constant
        constant,
        phi,

        // Escape Scope
        exit, // Terminates Program

        // Arithmetic
        add,
        sub,
        mul,
        div,

        // Inequalities
        eql,
        not_eql,
        less,
        less_or_eql,
        greater,
        greater_or_eql,
        bool_or,
        bool_and,

        // Terminators
        jump,
        branch,

        // Dialogue
        speaker,
        label,
        text,

        // Choices
        choice_option,
        choice,
    };

    pub const Data = union(enum) {
        none: void,
        boolean: bool,
        uint: u8,
        ident: IdentId,
        jump: BlockId,

        phi: struct {
            start: u32,
            len: u32,
        },

        // payload identifier are variable identifiers.
        pl_ident: struct {
            token: TokenIndex,
            ident: IdentId,
        },

        binary: struct {
            token: TokenIndex,
            lhs: InstId,
            rhs: InstId,
        },

        // Indexes into extra.
        branch: struct {
            cond: InstId,
            then_block: BlockId,
            else_block: BlockId,
        },

        range: Span,
    };
};

pub const GenSSA = struct {
    blocks: std.MultiArrayList(Block).Slice,
    instructions: []const Inst,
    extra: []const u32,

    pub fn deinit(ssa: *GenSSA, allocator: Allocator) void {
        ssa.blocks.deinit(allocator);
        allocator.free(ssa.instructions);
        allocator.free(ssa.extra);
    }
};

pub const Ssa = @This();

allocator: Allocator,
ast: *const Ast,
decorated: *const Decorated,

blocks: std.MultiArrayList(Block) = .empty,
instructions: std.ArrayList(Inst) = .empty,
extra: std.ArrayList(u32) = .empty,

values: std.array_hash_map.Auto(IdentId, InstId) = .empty,
jump_blocks: std.array_hash_map.Auto(IdentId, BlockId) = .empty,

unresolved_jumps: std.ArrayList(UnresolvedJump) = .empty,

current_block: u32 = 0,

ident_ref: IdentId = 0,
jump_ref: IdentId = 0,
text_ref: u32 = 0,

pub fn deinit(ssa: *Ssa) void {
    ssa.blocks.deinit(ssa.allocator);
    ssa.instructions.deinit(ssa.allocator);
    ssa.extra.deinit(ssa.allocator);
    ssa.values.deinit(ssa.allocator);
    ssa.jump_blocks.deinit(ssa.allocator);
    ssa.unresolved_jumps.deinit(ssa.allocator);
}

pub fn generate(ssa: *Ssa) Error!GenSSA {
    // Root node in a post-traversal order is the last node.
    const root_node = ssa.ast.nodes.get(ssa.ast.nodes.len - 1);
    const range = root_node.data.range;

    // Start program.
    const block_id = try ssa.createBlock();
    try ssa.buildBlock(block_id, range.start, range.len);

    // Terminate program.
    _ = try ssa.emit(.exit, .none);

    for (ssa.unresolved_jumps.items) |unresolved| {
        const target = ssa.jump_blocks.get(unresolved.ident_id) orelse unreachable;
        ssa.instructions.items[unresolved.jump_id].data.jump = target;
    }

    return .{
        .blocks = ssa.blocks.toOwnedSlice(),
        .instructions = try ssa.instructions.toOwnedSlice(ssa.allocator),
        .extra = try ssa.extra.toOwnedSlice(ssa.allocator),
    };
}

fn nextIdent(ssa: *Ssa) IdentId {
    const id = ssa.decorated.symbols[ssa.ident_ref];
    ssa.ident_ref += 1;
    return id;
}

fn nextJump(ssa: *Ssa) IdentId {
    const id = ssa.decorated.jump_labels[ssa.jump_ref];
    ssa.jump_ref += 1;
    return id;
}

fn nextText(ssa: *Ssa) u32 {
    const len = ssa.text_ref;
    ssa.text_ref += 1;
    return len;
}

fn toInstTag(tag: Node.Tag) Inst.Tag {
    return switch (tag) {
        .plus => .add,
        .minus => .sub,
        .mult => .mul,
        .div => .div,

        .plus_equal => .add,
        .minus_equal => .sub,
        .mult_equal => .mul,
        .div_equal => .div,

        .equal_equal => .eql,
        .not_equal => .not_eql,
        .less => .less,
        .less_or_equal => .less_or_eql,
        .greater => .greater,
        .greater_or_equal => .greater_or_eql,

        .bool_and => .bool_and,
        .bool_or => .bool_or,
        else => unreachable,
    };
}

fn emit(ssa: *Ssa, tag: Inst.Tag, data: Inst.Data) Error!InstId {
    const inst_id: InstId = @intCast(ssa.instructions.items.len);

    try ssa.instructions.append(ssa.allocator, .{
        .tag = tag,
        .data = data,
    });

    ssa.blocks.items(.inst_count)[ssa.current_block] += 1;
    return inst_id;
}

fn emitJump(ssa: *Ssa) Error!InstId {
    const ident_id = ssa.nextJump();

    const jump_id = try ssa.emit(.jump, .{
        .jump = invalid_block,
    });

    if (ssa.jump_blocks.get(ident_id)) |label_block| {
        ssa.instructions.items[jump_id].data.jump = label_block;
    } else {
        try ssa.unresolved_jumps.append(ssa.allocator, .{
            .ident_id = ident_id,
            .jump_id = jump_id,
        });
    }

    return jump_id;
}

fn evalValue(ssa: *Ssa, node: Node) Error!InstId {
    const token_pos = node.token_pos;
    switch (node.tag) {
        .number => {
            const text = ssa.ast.source_file.tokenSlice(token_pos);
            const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

            return ssa.emit(.constant, .{ .uint = num });
        },
        .var_ident => {
            const ident = ssa.nextIdent();
            return ssa.values.get(ident) orelse unreachable;
        },
        .string => {
            const text_id = ssa.nextText();
            const span = ssa.decorated.pool.text_spans[text_id];
            return ssa.emit(.text, .{
                .range = .{ .start = span.start, .len = span.len }
            });
        },

        else => {},
    }

    const tag = toInstTag(node.tag);
    return ssa.evalBinary(tag, node);
}

fn evalBinary(ssa: *Ssa, tag: Inst.Tag, node: Node) Error!InstId {
    const children = node.data.node_and_node;

    const left_node = ssa.ast.nodes.get(children.@"0");
    const right_node = ssa.ast.nodes.get(children.@"1");
    const lhs = try ssa.evalValue(left_node);
    const rhs = try ssa.evalValue(right_node);

    return ssa.emit(tag, .{
        .binary = .{
            .token = node.token_pos,
            .lhs = lhs,
            .rhs = rhs,
        }
    });
}

fn createBlock(ssa: *Ssa) Error!BlockId {
    const block_id: BlockId = @intCast(ssa.blocks.len);

    try ssa.blocks.append(ssa.allocator, .{
        // first_inst may be modified depending on the ssa.
        .first_inst = @intCast(ssa.instructions.items.len),
        .inst_count = 0,
    });

    return block_id;
}

fn beginBlock(ssa: *Ssa, block: BlockId) void {
    ssa.current_block = block;
    ssa.blocks.items(.first_inst)[block] = @intCast(ssa.instructions.items.len);
    ssa.blocks.items(.inst_count)[block] = 0;
}

fn buildBlock(ssa: *Ssa, block: BlockId, start: u32, len: u32) Error!void {
    ssa.beginBlock(block);

    try ssa.stmtList(start, len);
}

fn stmtList(ssa: *Ssa, start: u32, len: u32) Error!void {
    var i: u32 = start;
    const end = start + len;

    while (i < end) {
        const node_idx = ssa.ast.extra_data[i];
        const node = ssa.ast.nodes.get(node_idx);

        if (node.tag != .choice) {
            if (node.tag == .label) {
                try ssa.addLabel(node, i + 1 < end);
            } else {
                try ssa.addStmt(node);
            }

            i += 1;
            continue;
        }

        const choice_len = ssa.choiceGroupLen(i, end);

        if (choice_len > 1) {
            try ssa.addChoiceGroup(i, choice_len);
        }

        i += choice_len;
    }
}

// Choice group is guaranteed to be less than 5 choices.
fn choiceGroupLen(ssa: *Ssa, start: u32, end: u32) u32 {
    var i: u32 = start;
    while (i < end) {
        const extra_idx = ssa.ast.extra_data[i];
        const node = ssa.ast.nodes.get(extra_idx);

        if (node.tag != .choice)
            break;

        i += 1;
    }

    return i - start;
}

fn addStmt(ssa: *Ssa, node: Node) Error!void {
    try switch (node.tag) {
        // Non-block stmts 
        .declar_stmt, .assign => ssa.addStore(node),

        .exit => _ = try ssa.emit(.exit, .none),

        .plus_equal => ssa.addArith(node, .add),
        .minus_equal => ssa.addArith(node, .sub),
        .mult_equal => ssa.addArith(node, .mul),
        .div_equal => ssa.addArith(node, .div),

        .dialogue => ssa.addDialogue(node),

        // Blocks
        // .label => ssa.addLabel(node),

        .if_stmt => ssa.addBranch(node),
        else => unreachable,
    };
}

fn addStore(ssa: *Ssa, node: Node) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const ident = ssa.nextIdent();

    const value_node = ssa.ast.nodes.get(value_idx);
    const value = try ssa.evalValue(value_node);

    try ssa.values.put(ssa.allocator, ident, value);
}

fn addArith(ssa: *Ssa, node: Node, comptime tag: Inst.Tag) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = ssa.ast.nodes.get(value_idx);

    const ident = ssa.nextIdent();

    const lhs = ssa.values.get(ident) orelse unreachable;
    const rhs = try ssa.evalValue(value_node);

    _ = try ssa.emit(tag, .{
        .binary = .{
            .token = node.token_pos,
            .lhs = lhs,
            .rhs = rhs
        }
    });
}

fn addDialogue(ssa: *Ssa, node: Node) Error!void {
    const range = node.data.range;

    const speaker_node = ssa.ast.nodes.get(ssa.ast.extra_data[range.start]);
    var speaker: InstId = invalid_inst;

    if (speaker_node.tag != .anonymous) {
        const ident_id = ssa.nextIdent();
        speaker = try ssa.emit(.speaker, .{
            .ident = ident_id,
        });
    }

    return try ssa.addDialogueParts(range.start, range.len);
}

fn addDialogueParts(ssa: *Ssa, start: u32, len: u32) Error!void {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = ssa.ast.extra_data[idx];
        const text_node = ssa.ast.nodes.get(text_idx);
        _ = try ssa.evalValue(text_node);
    }

    const jump_idx = ssa.ast.extra_data[end - 1];

    if (jump_idx == invalid_inst)
        return;

    _ = try ssa.emitJump();

    const new_block = try ssa.createBlock();
    ssa.beginBlock(new_block);
}

// TODO:
// Ideally, jump instruction should only append if there is a block
// in between the basic instructions.
// Jump on every label is redundant.
// I think I can optimize it.
// Input:
//
// ~ A
//    var i = 0
// end
//
// var j = 1 
//
// Output:
// block0:
//     jump block1
// block1:
//     %3 = constant 1
//     store v2, %3
// block2:
//     %1 = constant 0
//     store v1, %1
//
fn addLabel(ssa: *Ssa, node: Node, has_more: bool) Error!void {
    const continuation = if (has_more)
        try ssa.createBlock()
    else
        invalid_block;

    if (has_more) {
        _ = try ssa.emit(.jump, .{ .jump = continuation });
    }

    const label = ssa.nextIdent();
    const block = try ssa.createBlock();
    try ssa.jump_blocks.putNoClobber(ssa.allocator, label, block);

    const range = node.data.range;
    try ssa.buildBlock(block, range.start, range.len);

    if (has_more) {
        ssa.beginBlock(continuation);
    }
}

// TODO: If the only difference between ssa and SSA is the phi node
// for my interpreter, then it is a waste of time copying almost all
// instructions from ssa to SSA and making slight or no changes.
//
// It is more efficient to generate the phi node here.
//
// Remove the "store" and "load" instruction for pure SSA registers
// and phi nodes.
//
// Solution?
//
// According to LLVM source code, it does not "look backwards" to find values.
// Phi nodes represents values as flat list of pairs.
//
// Then they use addIncoming(Value *V, BasicBlock *BB),
// getIncomingValue(unsigned i), and getIncomingBlock(unsigned i)
// to retrieve the pair.
fn addBranch(ssa: *Ssa, node: Node) Error!void {
    const range = node.data.range;
    const start = range.start;
    
    const cond_extra = ssa.ast.extra_data[start];
    const then_extra = ssa.ast.extra_data[start + 1];
    const else_extra = ssa.ast.extra_data[start + 2];

    const cond_node = ssa.ast.nodes.get(cond_extra);
    const cond = try ssa.evalValue(cond_node);

    const then_block = try ssa.createBlock();

    const has_else = else_extra != invalid_inst;
    const else_block = if (has_else)
        try ssa.createBlock()
    else
        invalid_block;

    const merge_block = try ssa.createBlock();

    // Current block branches to then / else blocks
    _ = try ssa.emit(.branch, .{
        .branch = .{
            .cond = cond,
            .then_block = then_block,
            .else_block = if (has_else) else_block else merge_block,
        }
    });

    // === THEN BLOCK ===
    try ssa.buildBranchBlock(then_extra, then_block, merge_block);

    // === ELSE BLOCK ===
    if (has_else)
        try ssa.buildBranchBlock(else_extra, else_block, merge_block);

    // === MERGE ===
    ssa.beginBlock(merge_block);
}

fn buildBranchBlock(ssa: *Ssa, extra_idx: u32, block: BlockId, jump_block: BlockId) Error!void {
    const node = ssa.ast.nodes.get(extra_idx);
    const range = node.data.range;
    try ssa.buildBlock(block, range.start, range.len);

    _ = try ssa.emit(.jump, .{ .jump = jump_block });
}

fn addChoiceGroup(ssa: *Ssa, start: u32, len: u32) Error!void {
    const end = start + len;
    const choice_blocks = try ssa.allocator.alloc(BlockId, len);
    defer ssa.allocator.free(choice_blocks);

    const continuation = try ssa.createBlock();

    for (choice_blocks) |*block| {
        block.* = try ssa.createBlock();
    }

    // === MENU CONTENT ===
    for (start .. end) |i| {
        const extra_idx = ssa.ast.extra_data[i];
        const node = ssa.ast.nodes.get(extra_idx);
        const range = node.data.range;

        // Mark the beginning of a new option
        _ = try ssa.emit(.choice_option, .none);
        try ssa.handleChoiceText(range.start, range.len);
    }

    // Display the options and wait for a valid selection.
    const selected = try ssa.emit(.choice, .{
        .uint = @intCast(len)
    });

    // === DISPATCH ===
    for (0 .. len - 1) |i| {
        const expected = try ssa.emit(.constant, .{
            .uint = @intCast(i + 1)
        });

        const choice_node_idx = ssa.ast.extra_data[start + i];
        const choice_node = ssa.ast.nodes.get(choice_node_idx);

        const matches = try ssa.emit(.eql, .{
            .binary = .{
                .token = choice_node.token_pos,
                .lhs = selected,
                .rhs = expected,
            }
        });

        const next_check = try ssa.createBlock();

        _ = try ssa.emit(.branch, .{
            .branch = .{
                .cond = matches,
                .then_block = choice_blocks[i],
                .else_block = next_check,
            }
        });

        ssa.beginBlock(next_check);
    }

    // The final option is the remaining valid selection.
    _ = try ssa.emit(.jump, .{
        .jump = choice_blocks[len - 1],
    });

    // === OPTION DESTINATIONS ===
    for (0 .. len) |i| {
        const node_idx = ssa.ast.extra_data[start + i];
        const node = ssa.ast.nodes.get(node_idx);
        const range = node.data.range;

        const goto_idx = ssa.ast.extra_data[
            range.start + range.len - 1
        ];

        ssa.beginBlock(choice_blocks[i]);

        if (goto_idx != invalid_node) {
            _ = try ssa.emitJump();
        } else {
            _ = try ssa.emit(.jump, .{
                .jump = continuation,
            });
        }
    }

    // Continue generating subsequent statements here.
    ssa.beginBlock(continuation);
}

fn handleChoiceText(ssa: *Ssa, start: u33, len: u32) Error!void {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = ssa.ast.extra_data[idx];
        const text_node = ssa.ast.nodes.get(text_idx);
        _ = try ssa.evalValue(text_node);
    }
}
