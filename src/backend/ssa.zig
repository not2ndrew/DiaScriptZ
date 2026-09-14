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
pub const invalid_inst = std.math.maxInt(u32);

pub const BlockId = u32;
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
        dialogue,
        speaker,
        label,
        text,
    };

    pub const Data = union {
        none: void,

        boolean: bool,
        uint: u8,

        binary: struct {
            lhs: InstId,
            rhs: InstId,
        },

        phi: Span,

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
// extra_blocks: std.ArrayList(BlockEdge) = .empty,
instructions: std.ArrayList(Inst) = .empty,
extra: std.ArrayList(InstId) = .empty,

values: std.array_hash_map.Auto(IdentId, ValueId) = .empty,

current_block: u32 = 0,

ident_ref: IdentId = 0,
jump_ref: IdentId = 0,
text_ref: u32 = 0,

pub fn deinit(ir: *Ssa) void {
    ir.blocks.deinit(ir.allocator);
    ir.instructions.deinit(ir.allocator);
    ir.extra.deinit(ir.allocator);
    ir.values.deinit(ir.allocator);
}

pub fn generate(ir: *Ssa) Error!void {
    const allocator = ir.allocator;
    // We expect as many diaIR instructions and extra as nodes and extra_data.
    try ir.instructions.ensureTotalCapacity(allocator, ir.ast.nodes.len);
    try ir.extra.ensureTotalCapacity(allocator, ir.ast.extra_data.len);

    // Root node in a post-traversal order is the last node.
    const root_node = ir.ast.nodes.get(ir.ast.nodes.len - 1);
    const range = root_node.data.range;
    const block_id = try ir.createBlock();
    try ir.buildBlock(block_id, range.start, range.len);

    try ir.instructions.shrinkToLen(allocator);
    try ir.extra.shrinkToLen(allocator);

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
        .jump, .branch => true,
        else => false,
    };
}

fn emit(ir: *Ssa, tag: Inst.Tag, token_pos: TokenIndex, data: Inst.Data) Error!ValueId {
    const block = ir.current_block; 

    const inst_id: InstId = @intCast(ir.instructions.items.len);
    ir.instructions.appendAssumeCapacity(.{
        .tag = tag,
        .token_pos = token_pos,
        .data = data,
    });

    ir.blocks.items(.inst_count)[block] += 1;
    return inst_id;
}

// fn terminate(ir: *Ssa, inst: Inst) Error!void {}

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
    var i: u32 = start;
    const end = start + len;

    while (i < end) {
        const node_idx = ir.ast.extra_data[i];
        const node = ir.ast.nodes.get(node_idx);

        if (node.tag != .choice) {
            _ = try ir.addStmt(node);

            i += 1;
            continue;
        }

        // Handle choices
        // const choice_count = ir.countChoices(i, end);
        // if (choice_count != 1) {
        //     const choice_block = try ir.reduceChoiceBlock(i, choice_count);
        //     // try stmts.append(ir.allocator, choice_block);
        // } else {
        //     const choice = try ir.reduceChoice(node);
        //     // try stmts.append(ir.allocator, choice);
        // }
        //
        // i += choice_count;
    }
}

fn addStmt(ir: *Ssa, node: Node) Error!InstId {
    return switch (node.tag) {
        .declar_stmt => ir.addDeclar(node),
        .assign => ir.addAssign(node),

        // The rest is done later on.
        else => unreachable,
    };
}

fn addDeclar(ir: *Ssa, node: Node) Error!InstId {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = ir.ast.nodes.get(value_idx);

    const ident = ir.nextIdent();
    const value = try ir.evalValue(value_node);

    try ir.values.put(ir.allocator, ident, value);
    return value;
}

fn addAssign(ir: *Ssa, node: Node) Error!InstId {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = ir.ast.nodes.get(value_idx);

    const ident = ir.nextIdent();
    const value = try ir.evalValue(value_node);

    const current = ir.values.getPtr(ident) orelse unreachable;
    current.* = value;

    return value;
}
