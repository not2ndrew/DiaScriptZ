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
        store,
        load,

        // Exit
        exit,

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
            ident: IdentId,
            value: InstId,
        },

        load: IdentId,

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
    const inst_id: InstId = @intCast(tac.instructions.items.len);

    try tac.instructions.append(tac.allocator, .{
        .tag = tag,
        .data = data,
    });

    tac.blocks.items(.inst_count)[tac.current_block] += 1;
    return inst_id;
}

fn emitJump(tac: *Tac) Error!InstId {
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

            return tac.emit(.load, .{ .load = ident });
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

fn createBlock(tac: *Tac) Error!BlockId {
    const block_id: BlockId = @intCast(tac.blocks.len);

    try tac.blocks.append(tac.allocator, .{
        // first_inst may be modified depending on the Tac.
        .first_inst = @intCast(tac.instructions.items.len),
        .inst_count = 0,
    });

    return block_id;
}

fn beginBlock(tac: *Tac, block: BlockId) void {
    tac.current_block = block;
    tac.blocks.items(.first_inst)[block] = @intCast(tac.instructions.items.len);
    tac.blocks.items(.inst_count)[block] = 0;
}

fn buildBlock(tac: *Tac, block: BlockId, start: u32, len: u32) Error!void {
    tac.beginBlock(block);

    try tac.stmtList(start, len);
}

fn stmtList(tac: *Tac, start: u32, len: u32) Error!void {
    var i: u32 = start;
    const end = start + len;

    while (i < end) {
        const node_idx = tac.ast.extra_data[i];
        const node = tac.ast.nodes.get(node_idx);

        if (node.tag != .choice) {
            try tac.addStmt(node);
            i += 1;

            continue;
        }

        const choice_len = tac.choiceGroupLen(i, end);

        // TODO: I need a way to find a TAC for multiple dialogue choices.
        // Since this is a terminal-based interpreter,
        // choices will be made by using 1, 2, 3, or 4.
        // So we can create a temp variable and perform
        // multiple if checks and jump to the desired block.
        // if (choice_len > 1) {
        //     try tac.addChoiceGroup(i, choice_len);
        // } else {
        //     try tac.addChoice(node);
        // }

        i += choice_len;
    }
}

// Choice group is guaranteed to be less than 5 choices.
fn choiceGroupLen(tac: *Tac, start: u32, end: u32) u32 {
    var i: u32 = start;
    while (i < end) {
        const extra_idx = tac.ast.extra_data[i];
        const node = tac.ast.nodes.get(extra_idx);

        if (node.tag != .choice)
            break;

        i += 1;
    }

    return i - start;
}

fn addStmt(tac: *Tac, node: Node) Error!void {
    try switch (node.tag) {
        // Non-block stmts 
        .declar_stmt, .assign => tac.addStore(node),

        .exit => _ = try tac.emit(.exit, .none),

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

fn addStore(tac: *Tac, node: Node) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const ident = tac.nextIdent();

    const value_node = tac.ast.nodes.get(value_idx);
    const value = try tac.evalValue(value_node);

    _ = try tac.emit(.store, .{
        .store = .{ .ident = ident, .value = value }
    });
}

fn addArith(tac: *Tac, node: Node, comptime tag: Inst.Tag) Error!void {
    const value_idx = node.data.node_and_node.@"1";
    const value_node = tac.ast.nodes.get(value_idx);

    const ident = tac.nextIdent();

    const lhs = try tac.emit(.load, .{
        .load = ident,
    });
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
            .ident = ident,
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
    tac.beginBlock(new_block);
}

fn addLabel(tac: *Tac, node: Node) Error!void {
    const label = tac.nextIdent();
    const block = try tac.createBlock();
    try tac.jump_blocks.putNoClobber(tac.allocator, label, block);

    const range = node.data.range;
    try tac.buildBlock(block, range.start, range.len);
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
    tac.beginBlock(merge_block);
}

fn buildBranchBlock(tac: *Tac, extra_idx: u32, block: BlockId, jump_block: BlockId) Error!void {
    const node = tac.ast.nodes.get(extra_idx);
    const range = node.data.range;
    try tac.buildBlock(block, range.start, range.len);

    _ = try tac.emit(.jump, .{ .jump = jump_block });
}

// Leave it for now.
fn handleChoiceText(tac: *Tac, start: u32, len: u32) Error!void {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = tac.ast.extra_data[idx];
        const text_node = tac.ast.nodes.get(text_idx);
        // TODO: Instead of emitting text, it should emit param
        // to represent choices.
        _ = try tac.evalValue(text_node);
    }
}
