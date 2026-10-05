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
pub const VariableId = u32;

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
        store,
        load,

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

        store: struct {
            variable: VariableId,
            value: InstId,
        },

        load: VariableId,

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

        range: Span,
    };
};

pub const GenTac = struct {
    blocks: std.MultiArrayList(Block).Slice,
    instructions: []const Inst,
    extra: []const u32,

    pub fn deinit(tac: *GenTac, allocator: Allocator) void {
        tac.blocks.deinit(allocator);
        allocator.free(tac.instructions);
        allocator.free(tac.extra);
    }
};

pub const Tac = @This();

allocator: Allocator,
ast: *const Ast,
decorated: *const Decorated,

blocks: std.MultiArrayList(Block) = .empty,
instructions: std.ArrayList(Inst) = .empty,
extra: std.ArrayList(u32) = .empty,

variables: std.array_hash_map.Auto(IdentId, VariableId) = .empty,
jump_blocks: std.array_hash_map.Auto(IdentId, BlockId) = .empty,

unresolved_jumps: std.ArrayList(UnresolvedJump) = .empty,

current_block: u32 = 0,

ident_ref: IdentId = 0,
jump_ref: IdentId = 0,
text_ref: u32 = 0,

pub fn deinit(tac: *Tac) void {
    tac.blocks.deinit(tac.allocator);
    tac.instructions.deinit(tac.allocator);
    tac.extra.deinit(tac.allocator);
    tac.variables.deinit(tac.allocator);
    tac.jump_blocks.deinit(tac.allocator);
    tac.unresolved_jumps.deinit(tac.allocator);
}

pub fn generate(tac: *Tac) Error!GenTac {
    // Root node in a post-traversal order is the last node.
    const root_node = tac.ast.nodes.get(tac.ast.nodes.len - 1);
    const range = root_node.data.range;

    const block_id = try tac.createBlock();
    try tac.buildBlock(block_id, range.start, range.len);

    for (tac.unresolved_jumps.items) |unresolved| {
        const target = tac.jump_blocks.get(unresolved.ident_id) orelse unreachable;
        tac.instructions.items[unresolved.jump_id].data.jump = target;
    }

    return .{
        .blocks = tac.blocks.toOwnedSlice(),
        .instructions = try tac.instructions.toOwnedSlice(tac.allocator),
        .extra = try tac.extra.toOwnedSlice(tac.allocator),
    };
}

fn nextIdent(tac: *Tac) IdentId {
    const id = tac.decorated.symbols[tac.ident_ref];
    tac.ident_ref += 1;
    return id;
}

fn nextJump(tac: *Tac) IdentId {
    const id = tac.decorated.jump_labels[tac.jump_ref];
    tac.jump_ref += 1;
    return id;
}

fn nextText(tac: *Tac) u32 {
    const len = tac.text_ref;
    tac.text_ref += 1;
    return len;
}

fn switchBlock(tac: *Tac, block: BlockId) void {
    tac.current_block = block;
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

fn emit(tac: *Tac, tag: Inst.Tag, data: Inst.Data) Error!InstId {
    const block = tac.current_block; 

    const inst_id: InstId = @intCast(tac.instructions.items.len);
    try tac.instructions.append(tac.allocator, .{
        .tag = tag,
        .data = data,
    });

    tac.blocks.items(.inst_count)[block] += 1;
    return inst_id;
}

fn emitJump(tac: *Tac) Error!InstId {
    const from = tac.current_block;
    const ident_id = tac.nextJump();

    const jump_id = try tac.emit(.jump, .{
        .jump = invalid_block,
    });

    if (tac.jump_blocks.get(ident_id)) |label_block| {
        tac.instructions.items[jump_id].data.jump = label_block;
    } else {
        try tac.unresolved_jumps.append(tac.allocator, .{
            .ident_id = ident_id,
            .jump_id = jump_id,
            .from_block = from,
        });
    }

    return jump_id;
}

fn evalValue(tac: *Tac, node: Node) Error!InstId {
    const token_pos = node.token_pos;
    switch (node.tag) {
        .number => {
            const text = tac.ast.source_file.tokenSlice(token_pos);
            const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

            return tac.emit(.constant, .{ .uint = num });
        },
        .var_ident => {
            const ident = tac.nextIdent();
            const variable = try tac.getVariable(ident);

            return tac.emit(.load, .{ .load = variable });
            // return tac.variables.get(ident) orelse unreachable;
        },
        .string => {
            const text_id = tac.nextText();
            const span = tac.decorated.pool.text_spans[text_id];
            return tac.emit(.text, .{
                .range = .{ .start = span.start, .len = span.len }
            });
        },

        else => {},
    }

    const tag = toInstTag(node.tag);
    return tac.evalBinary(tag, node);
}

fn evalBinary(tac: *Tac, tag: Inst.Tag, node: Node) Error!InstId {
    const children = node.data.node_and_node;

    const left_node = tac.ast.nodes.get(children.@"0");
    const right_node = tac.ast.nodes.get(children.@"1");
    const lhs = try tac.evalValue(left_node);
    const rhs = try tac.evalValue(right_node);

    return tac.emit(tag, .{
        .binary = .{
            .token = node.token_pos,
            .lhs = lhs,
            .rhs = rhs,
        }
    });
}

fn getVariable(tac: *Tac, ident: IdentId) Error!VariableId {
    if (tac.variables.get(ident)) |id|
        return id;

    const id: VariableId = @intCast(tac.variables.count());
    try tac.variables.putNoClobber(tac.allocator, ident, id);
    return id;
}

fn createBlock(tac: *Tac) Error!BlockId {
    const block_id: BlockId = @intCast(tac.blocks.len);

    try tac.blocks.append(tac.allocator, .{
        // first_inst may be modified depending on the Tac.
        .first_inst = @intCast(tac.instructions.items.len),
        .inst_count = 0,
    });

    return block_id;
}

fn buildBlock(tac: *Tac, block_id: BlockId, start: u32, len: u32) Error!void {
    tac.switchBlock(block_id);
    tac.blocks.items(.first_inst)[block_id] = @intCast(tac.instructions.items.len);

    try tac.stmtList(start, len);
}

fn stmtList(tac: *Tac, start: u32, len: u32) Error!void {
    for (start .. start + len) |idx| {
        const extra = tac.ast.extra_data[idx];
        const node = tac.ast.nodes.get(extra);
        try tac.addStmt(node);
    }
}

fn addStmt(tac: *Tac, node: Node) Error!void {
    try switch (node.tag) {
        // Non-block stmts 
        .declar_stmt => tac.addDeclar(node),
        .assign => tac.addAssign(node),

        .exit => {},

        .plus_equal => tac.addArith(node, .add),
        .minus_equal => tac.addArith(node, .sub),
        .mult_equal => tac.addArith(node, .mul),
        .div_equal => tac.addArith(node, .div),

        .dialogue => tac.addDialogue(node),

        // Blocks
        .label => tac.addLabel(node),

        .if_stmt => tac.addBranch(node),
        else => unreachable,
    };
}

fn addDeclar(tac: *Tac, node: Node) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = tac.ast.nodes.get(value_idx);

    const ident = tac.nextIdent();
    const value = try tac.evalValue(value_node);

    _ = try tac.emit(.store, .{
        .store = .{ .variable = ident, .value = value }
    });

    // try tac.variables.put(tac.allocator, ident, value);
}

fn addAssign(tac: *Tac, node: Node) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = tac.ast.nodes.get(value_idx);

    const ident = tac.nextIdent();
    const value = try tac.evalValue(value_node);
    const variable = try tac.getVariable(ident);

    _ = try tac.emit(.store, .{
        .store = .{ .variable = variable, .value = value }
    });
}

fn addArith(tac: *Tac, node: Node, comptime tag: Inst.Tag) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = tac.ast.nodes.get(value_idx);

    const ident = tac.nextIdent();
    const variable = try tac.getVariable(ident);

    const lhs = tac.variables.get(ident) orelse unreachable;
    const rhs = try tac.evalValue(value_node);

    const result = try tac.emit(tag, .{
        .binary = .{
            .token = node.token_pos,
            .lhs = lhs,
            .rhs = rhs
        }
    });

    _ = try tac.emit(.store, .{
        .store = .{
            .variable = variable,
            .value = result,
        },
    });
}

fn addDialogue(tac: *Tac, node: Node) Error!void {
    const range = node.data.range;

    const speaker_node = tac.ast.nodes.get(tac.ast.extra_data[range.start]);
    var speaker: InstId = invalid_inst;

    if (speaker_node.tag != .anonymous) {
        const ident_id = tac.nextIdent();
        speaker = try tac.emit(.speaker, .{
            .ident = ident_id,
        });
    }

    return try tac.addDialogueParts(range.start, range.len);
}

fn addDialogueParts(tac: *Tac, start: u32, len: u32) Error!void {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = tac.ast.extra_data[idx];
        const text_node = tac.ast.nodes.get(text_idx);
        _ = try tac.evalValue(text_node);
    }

    const jump_idx = tac.ast.extra_data[end - 1];

    if (jump_idx == invalid_inst)
        return;

    _ = try tac.emitJump();

    const new_block = try tac.createBlock();
    tac.switchBlock(new_block);
}

fn addLabel(tac: *Tac, node: Node) Error!void {
    const label = tac.nextIdent();
    try tac.jump_blocks.putNoClobber(tac.allocator, label, tac.current_block);

    const range = node.data.range;
    try tac.buildBlock(tac.current_block, range.start, range.len);
}

fn addBranch(tac: *Tac, node: Node) Error!void {
    const range = node.data.range;
    const start = range.start;
    
    const cond_extra = tac.ast.extra_data[start];
    const then_extra = tac.ast.extra_data[start + 1];
    const else_extra = tac.ast.extra_data[start + 2];

    const cond_node = tac.ast.nodes.get(cond_extra);
    const cond = try tac.evalValue(cond_node);

    const then_block = try tac.createBlock();

    const has_else = else_extra != invalid_inst;
    const else_block = if (has_else)
        try tac.createBlock()
    else
        invalid_block;

    const merge_block = try tac.createBlock();

    // Current block branches to then / else blocks
    _ = try tac.emit(.branch, .{
        .branch = .{
            .cond = cond,
            .then_block = then_block,
            .else_block = if (has_else) else_block else merge_block,
        }
    });

    // === THEN BLOCK ===
    try tac.buildBranchBlock(then_extra, then_block, merge_block);

    // === ELSE BLOCK ===
    if (has_else)
        try tac.buildBranchBlock(else_extra, else_block, merge_block);

    // === MERGE ===
    tac.switchBlock(merge_block);
    tac.blocks.items(.first_inst)[merge_block] = @intCast(tac.instructions.items.len);
}

fn buildBranchBlock(tac: *Tac, extra_idx: u32, block: BlockId, jump_block: BlockId) Error!void {
    const node = tac.ast.nodes.get(extra_idx);
    const range = node.data.range;
    try tac.buildBlock(block, range.start, range.len);

    _ = try tac.emit(.jump, .{ .jump = jump_block });
}
