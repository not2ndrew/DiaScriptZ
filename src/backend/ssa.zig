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
    from_block: BlockId,
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

    pub const Data = union(enum) {
        none: void,
        boolean: bool,
        uint: u8,
        ident: IdentId,
        jump: BlockId,

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
            cond: u32,
            then_block: u32,
            else_block: u32,
        },

        phi: Span,
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

// TODO: Rename Ssa to DiaIR later on.
// DiaIR converts the given AST and Decorated into IR
// in Matthias Braun's SSA format.
pub const Ssa = @This();

allocator: Allocator,
ast: *const Ast,
decorated: *const Decorated,

blocks: std.MultiArrayList(Block) = .empty,
// For blocks with ranges.
edges: std.ArrayList(BlockEdge) = .empty,
instructions: std.ArrayList(Inst) = .empty,
extra: std.ArrayList(u32) = .empty,

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

pub fn generate(ir: *Ssa) Error!GenSSA {
    // Root node in a post-traversal order is the last node.
    const root_node = ir.ast.nodes.get(ir.ast.nodes.len - 1);
    const range = root_node.data.range;

    const block_id = try ir.createBlock();
    try ir.buildBlock(block_id, range.start, range.len);

    for (ir.unresolved_jumps.items) |unresolved| {
        const block = ir.jump_blocks.get(unresolved.ident_id) orelse unreachable;
        try ir.addEdge(unresolved.from_block, block);
    }

    return .{
        .blocks = ir.blocks.toOwnedSlice(),
        .instructions = try ir.instructions.toOwnedSlice(ir.allocator),
        .extra = try ir.extra.toOwnedSlice(ir.allocator),
    };
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

fn addEdge(ir: *Ssa, from: BlockId, to: BlockId) Error!void {
    try ir.edges.append(ir.allocator, .{ .from = from, .to = to });
}

fn isTerminator(tag: Inst.Tag) bool {
    return switch (tag) {
        .jump, .branch, .choice => true,
        else => false,
    };
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

fn emit(ir: *Ssa, tag: Inst.Tag, data: Inst.Data) Error!InstId {
    const block = ir.current_block; 

    const inst_id: InstId = @intCast(ir.instructions.items.len);
    try ir.instructions.append(ir.allocator, .{
        .tag = tag,
        .data = data,
    });

    ir.blocks.items(.inst_count)[block] += 1;
    return inst_id;
}

fn emitJump(ir: *Ssa) Error!InstId {
    const from = ir.current_block;
    const ident_id = ir.nextJump();

    const jump_id = try ir.emit(.jump, .{
        .jump = invalid_block,
    });

    if (ir.jump_blocks.get(ident_id)) |label_block| {
        ir.instructions.items[jump_id].data.jump = label_block;
        try ir.addEdge(from, label_block);
    } else {
        try ir.unresolved_jumps.append(ir.allocator, .{
            .ident_id = ident_id,
            .jump_id = jump_id,
            .from_block = from,
        });
    }

    return jump_id;
}

fn evalValue(ir: *Ssa, node: Node) Error!InstId {
    const token_pos = node.token_pos;
    switch (node.tag) {
        .number => {
            const text = ir.ast.source_file.tokenSlice(token_pos);
            const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

            return ir.emit(.constant, .{ .uint = num });
        },
        .var_ident => {
            const ident = ir.nextIdent();
            return ir.values.get(ident) orelse unreachable;
        },
        .string => {
            const text_id = ir.nextText();
            const span = ir.decorated.pool.text_spans[text_id];
            return ir.emit(.text, .{
                .range = .{ .start = span.start, .len = span.len }
            });
        },

        else => {},
    }

    const tag = toInstTag(node.tag);
    return ir.evalBinary(tag, node);
}

fn evalBinary(ir: *Ssa, tag: Inst.Tag, node: Node) Error!InstId {
    const children = node.data.node_and_node;

    const left_node = ir.ast.nodes.get(children.@"0");
    const right_node = ir.ast.nodes.get(children.@"1");
    const lhs = try ir.evalValue(left_node);
    const rhs = try ir.evalValue(right_node);

    return ir.emit(tag, .{
        .binary = .{
            .token = node.token_pos,
            .lhs = lhs,
            .rhs = rhs,
        }
    });
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

fn buildBlock(ir: *Ssa, block_id: BlockId, start: u32, len: u32) Error!void {
    ir.switchBlock(block_id);
    ir.blocks.items(.first_inst)[block_id] = @intCast(ir.instructions.items.len);

    try ir.stmtList(start, len);
}

fn stmtList(ir: *Ssa, start: u32, len: u32) Error!void {
    for (start .. start + len) |idx| {
        const extra = ir.ast.extra_data[idx];
        const node = ir.ast.nodes.get(extra);
        const terminated = try ir.addStmt(node);

        if (terminated) {
            // If there are more stmts after this one, create a new block
            if (idx + 1 < start + len) {
                const new_block = try ir.createBlock();
                ir.switchBlock(new_block);
            }
        }
    }
}

// TODO: For addArith, we need to create a phi function.
// The problem is writing variables in values hashmap is global.
//
// We must create local variables for each block.
// If a block does not have the requested variable,
// then we search recursively in every other block.
//
// Searching recursively must travel from child to parent to root.
//
// Our semantic guarantees there is at least one match.
// So we can assume that searching will never fail.
fn addStmt(ir: *Ssa, node: Node) Error!bool {
    try switch (node.tag) {
        // Non-block stmts 
        .declar_stmt => ir.addDeclar(node),
        .assign => ir.addAssign(node),

        .exit => {},

        .plus_equal => ir.addArith(node, .add),
        .minus_equal => ir.addArith(node, .sub),
        .mult_equal => ir.addArith(node, .mul),
        .div_equal => ir.addArith(node, .div),

        .dialogue => return ir.addDialogue(node),

        // Blocks
        .label => ir.addLabel(node),

        .if_stmt => return ir.addBranch(node),
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

    const result = try ir.emit(tag, .{
        .binary = .{
            .token = node.token_pos,
            .lhs = lhs,
            .rhs = rhs
        }
    });

    try ir.values.put(ir.allocator, ident, result);
}

fn addDialogue(ir: *Ssa, node: Node) Error!bool {
    const range = node.data.range;

    const speaker_node = ir.ast.nodes.get(ir.ast.extra_data[range.start]);
    var speaker: InstId = invalid_inst;

    if (speaker_node.tag != .anonymous) {
        const ident_id = ir.nextIdent();
        speaker = try ir.emit(.speaker, .{
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

    _ = try ir.emitJump();

    return true;
}

fn addLabel(ir: *Ssa, node: Node) Error!void {
    const label = ir.nextIdent();
    try ir.jump_blocks.putNoClobber(ir.allocator, label, ir.current_block);

    const range = node.data.range;
    try ir.buildBlock(ir.current_block, range.start, range.len);
}

fn addBranch(ir: *Ssa, node: Node) Error!bool {
    const range = node.data.range;
    const start = range.start;
    
    const cond_extra = ir.ast.extra_data[start];
    const then_extra = ir.ast.extra_data[start + 1];
    const else_extra = ir.ast.extra_data[start + 2];

    const cond_node = ir.ast.nodes.get(cond_extra);
    const cond = try ir.evalValue(cond_node);

    const then_block = try ir.createBlock();
    var else_block: BlockId = invalid_block;

    const else_valid = else_extra != invalid_inst;
    if (else_valid)
        else_block = try ir.createBlock();

    _ = try ir.emit(.branch, .{
        .branch = .{
            .cond = cond,
            .then_block = then_block,
            .else_block = else_block,
        }
    });

    const then_node = ir.ast.nodes.get(then_extra);
    const t_range = then_node.data.range;
    try ir.buildBlock(then_block, t_range.start, t_range.len);

    if (else_valid) {
        const else_node = ir.ast.nodes.get(else_extra);
        const e_range = else_node.data.range;
        try ir.buildBlock(else_block, e_range.start, e_range.len);
    }
    
    return true;
}
