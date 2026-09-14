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
pub const ValueId = InstId;

// Every basic block has zero or more ordinary instructions
// followed by exactly one terminator, except an unterminated
// block while CFG construction is in progress.
pub const Block = struct {
    first_inst: InstId,
    inst_count: u32,

    predecessors: Span,
    successors: Span,
};

pub const BlockEdge = struct {
    from: BlockId,
    to: BlockId,
};

pub const UnresolvedJump = struct {
    ident_id: IdentId,
    jump_id: InstId,
};

pub const Inst = struct {
    tag: Tag,
    token_pos: TokenIndex,
    data: Data,

    pub const Tag = enum {
        // Constant
        constant,

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

        // phi operands are indexed in exactly the
        // same order as the block's predecessor list.
        phi,

        // Terminators
        jump,
        branch,
        choice,

        // Dialogue
        speaker,
        label,
        text,
    };

    pub const Data = union {
        none: void,

        boolean: bool,
        uint: u8,
        // TODO: Idk if I should keep this or not.
        // I do need a way to extract the ident id from
        // string intern pool.
        ident: IdentId,

        binary: struct {
            lhs: InstId,
            rhs: InstId,
        },

        phi: Span,

        range: Span,

        jump: BlockId,

        // branch: Span,
        // branch: struct {
        //     condition: ValueId,
        //     then_block: BlockId,
        //     else_block: BlockId,
        // }
    };
};

// TODO: Rename Ssa to DiaIR later on.
// DiaIR converts the given AST and Decorated into IR
// in Matthias Braun's SSA format.
pub const Ssa = @This();

allocator: Allocator,
ast: *const Ast,
decorated: *const Decorated,

blocks: std.MultiArrayList(Block) = .empty,
// For blocks with ranges.
// edges: std.ArrayList(BlockEdge) = .empty,
instructions: std.ArrayList(Inst) = .empty,
extra: std.ArrayList(InstId) = .empty,

values: std.array_hash_map.Auto(IdentId, ValueId) = .empty,
jump_blocks: std.array_hash_map.Auto(IdentId, BlockId) = .empty,

unresolved_jumps: std.ArrayList(UnresolvedJump) = .empty,

current_block: u32 = 0,

ident_ref: IdentId = 0,
jump_ref: IdentId = 0,
text_ref: u32 = 0,

pub fn deinit(ir: *Ssa) void {
    ir.blocks.deinit(ir.allocator);
    ir.instructions.deinit(ir.allocator);
    ir.extra.deinit(ir.allocator);
    ir.values.deinit(ir.allocator);
    ir.jump_blocks.deinit(ir.allocator);
    ir.unresolved_jumps.deinit(ir.allocator);
}

pub fn generate(ir: *Ssa) Error!void {
    // Root node in a post-traversal order is the last node.
    const root_node = ir.ast.nodes.get(ir.ast.nodes.len - 1);
    const range = root_node.data.range;

    const block_id = try ir.createBlock();
    try ir.buildBlock(block_id, range.start, range.len);

    for (ir.unresolved_jumps.items) |unresolved| {
        const block = ir.jump_blocks.get(unresolved.ident_id) orelse unreachable;
        ir.instructions.items[unresolved.jump_id].data.jump = block;
    }
}

fn nextIdent(ir: *Ssa) IdentId {
    const id = ir.decorated.symbols[ir.ident_ref];
    ir.ident_ref += 1;
    return id;
}

fn nextJump(ir: *Ssa) IdentId {
    const id = ir.decorated.jump_labels[ir.jump_ref];
    ir.jump_ref += 1;
    return id;
}

fn nextText(ir: *Ssa) u32 {
    const len = ir.text_ref;
    ir.text_ref += 1;
    return len;
}


fn switchBlock(ir: *Ssa, block: BlockId) void {
    ir.current_block = block;
}

fn evalValue(ir: *Ssa, node: Node) Error!InstId {
    const token_pos = node.token_pos;
    return switch (node.tag) {
        .number => {
            const text = ir.ast.source_file.tokenSlice(token_pos);
            const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

            return ir.emit(.constant, token_pos, .{ .uint = num });
        },
        .var_ident => {
            const ident = ir.nextIdent();
            return ir.values.get(ident) orelse unreachable;
        },
        .string => {
            const text_id = ir.nextText();
            const span = ir.decorated.pool.text_spans[text_id];
            return ir.emit(.text, token_pos, .{
                .range = .{ .start = span.start, .len = span.len }
            });
        },

        .plus => ir.evalBinary(.add, node),
        .minus => ir.evalBinary(.sub, node),
        .mult => ir.evalBinary(.mul, node),
        .div => ir.evalBinary(.div, node),

        else => unreachable,
    };
}

fn evalBinary(ir: *Ssa, comptime tag: Inst.Tag, node: Node) Error!InstId {
    const children = node.data.node_and_node;
    const lhs_node = ir.ast.nodes.get(children.@"0");
    const rhs_node = ir.ast.nodes.get(children.@"1");
    const lhs = try ir.evalValue(lhs_node);
    const rhs = try ir.evalValue(rhs_node);

    return ir.emit(tag, node.token_pos, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
}

fn isTerminator(tag: Inst.Tag) bool {
    return switch (tag) {
        .jump, .branch, .choice => true,
        else => false,
    };
}

fn emit(ir: *Ssa, tag: Inst.Tag, token_pos: TokenIndex, data: Inst.Data) Error!InstId {
    const block = ir.current_block; 

    const inst_id: InstId = @intCast(ir.instructions.items.len);
    try ir.instructions.append(ir.allocator, .{
        .tag = tag,
        .token_pos = token_pos,
        .data = data,
    });

    ir.blocks.items(.inst_count)[block] += 1;
    return inst_id;
}

fn emitJump(ir: *Ssa, node: Node) Error!InstId {
    const ident_id = ir.nextJump();

    const jump_id = try ir.emit(.jump, node.token_pos, .{
        .jump = invalid_block,
    });

    if (ir.jump_blocks.get(ident_id)) |label_block| {
        ir.instructions.items[jump_id].data.jump = label_block;
    } else {
        try ir.unresolved_jumps.append(ir.allocator, .{
            .ident_id = ident_id,
            .jump_id = jump_id,
        });
    }

    return jump_id;
}

// TODO: Still need to figure out how to implement this.
// fn addSuccessor(ir: *Ssa, from: BlockId, to: BlockId) Error!void {
//     const block = ir.current_block;
// }

fn buildBlock(ir: *Ssa, block_id: BlockId, start: u32, len: u32) Error!void {
    ir.switchBlock(block_id);
    const before = ir.instructions.items.len;

    try ir.stmtList(start, len);

    const after = ir.instructions.items.len;

    ir.blocks.items(.inst_count)[block_id] = @intCast(after - before);
}

fn createBlock(ir: *Ssa) Error!BlockId {
    const block_id: BlockId = @intCast(ir.blocks.len);

    try ir.blocks.append(ir.allocator, .{
        .first_inst = @intCast(ir.instructions.items.len),
        .inst_count = 0,
        .predecessors = .{ .start = 0, .len = 0 },
        .successors = .{ .start = 0, .len = 0 },
    });

    return block_id;
}

fn stmtList(ir: *Ssa, start: u32, len: u32) Error!void {
    for (start .. start + len) |idx| {
        const extra = ir.ast.extra_data[idx];
        const node = ir.ast.nodes.get(extra);
        const terminated = try ir.addStmt(node);

        if (terminated) {
            // If there are more stmts after this one, create a new block
            if (idx + 1 < start + len) {
                const next_block = try ir.createBlock();
                ir.switchBlock(next_block);
            }
        }
    }
}

fn addStmt(ir: *Ssa, node: Node) Error!bool {
    try switch (node.tag) {
        .declar_stmt => try ir.addDeclar(node),
        .assign => try ir.addAssign(node),

        .plus_equal => ir.addArith(node, .add),
        .minus_equal => ir.addArith(node, .sub),
        .mult_equal => ir.addArith(node, .mul),
        .div_equal => ir.addArith(node, .div),

        .dialogue => return ir.addDialogue(node),

        .label => ir.addLabel(node),
        else => unreachable,
    };

    return false;
}

fn addDeclar(ir: *Ssa, node: Node) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = ir.ast.nodes.get(value_idx);

    const ident = ir.nextIdent();
    const value = try ir.evalValue(value_node);

    try ir.values.put(ir.allocator, ident, value);
}

fn addAssign(ir: *Ssa, node: Node) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = ir.ast.nodes.get(value_idx);

    const ident = ir.nextIdent();
    const value = try ir.evalValue(value_node);

    const current = ir.values.getPtr(ident) orelse unreachable;
    current.* = value;
}

fn addArith(ir: *Ssa, node: Node, comptime tag: Inst.Tag) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = ir.ast.nodes.get(value_idx);

    const ident = ir.nextIdent();

    const lhs = ir.values.get(ident) orelse unreachable;
    const rhs = try ir.evalValue(value_node);

    const result = try ir.emit(tag, node.token_pos, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });

    try ir.values.put(ir.allocator, ident, result);
}

fn addDialogue(ir: *Ssa, node: Node) Error!bool {
    const range = node.data.range;

    const speaker_node = ir.ast.nodes.get(ir.ast.extra_data[range.start]);
    var speaker: InstId = invalid_inst;

    if (speaker_node.tag != .anonymous) {
        const ident_id = ir.nextIdent();
        speaker = try ir.emit(.speaker, node.token_pos, .{
            .ident = ident_id,
        });
    }

    return try ir.addDialogueParts(range.start, range.len);
}

fn addDialogueParts(ir: *Ssa, start: u32, len: u32) Error!bool {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = ir.ast.extra_data[idx];
        const text_node = ir.ast.nodes.get(text_idx);
        _ = try ir.evalValue(text_node);
    }

    const jump_idx = ir.ast.extra_data[end - 1];

    if (jump_idx == invalid_inst)
        return false;

    const jump_node = ir.ast.nodes.get(jump_idx);
    _ = try ir.emitJump(jump_node);

    return true;
}

fn addLabel(ir: *Ssa, node: Node) Error!void {
    const block = try ir.createBlock();
    ir.switchBlock(block);

    const label = ir.nextIdent();
    try ir.jump_blocks.putNoClobber(ir.allocator, label, block);

    const range = node.data.range;
    try ir.stmtList(range.start + 1, range.len - 1);
}
