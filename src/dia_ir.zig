const std = @import("std");
const frontend = @import("frontend");
const zig_node = @import("node.zig");
const sym = @import("semantic.zig");
const in = @import("interner.zig");
const Ast = @import("ast.zig").Ast;
const Lower = @import("lower.zig").Lower;

const Allocator = std.mem.Allocator;

const TokenIndex = frontend.TokenIndex;

const Node = zig_node.Node;
const NodeIndex = zig_node.NodeIndex;
const NodeTag = zig_node.NodeTag;
const invalid_node = zig_node.invalid_node;

const Symbol = sym.Symbol;
const SymbolId = sym.SymbolId;

const IdentId = in.IdentId;
const InternPool = in.InternPool;
const Span = in.Span;

const Error = Allocator.Error;

pub const InstId = u32;
pub const invalid_inst = std.math.maxInt(u32);

pub const Inst = struct {
    tag: Tag,
    token_pos: TokenIndex,
    data: Data,

    pub const Tag = enum {
        // Value-producing
        constant,
        // load identifiers
        load,

        // Store
        // declaration statements such as "const" and "var"
        // are handled in Semantic.
        store,
        block,
        label_block,
        choice_block,

        // Arithmetic
        add,
        sub,
        mul,
        div,

        // comparison
        eql,
        not_eql,
        less,
        less_or_eql,
        greater,
        greater_or_eql,
        bool_or,
        bool_and,

        // Dialogue
        dialogue,
        choice,
        speaker,
        label,
        text,

        // Control flow
        jump,
        branch,
    };

    pub const Data = union {
        boolean: bool,
        uint: u8,
        load: SymbolId,
        label: IdentId,
        jump: IdentId,
        store: struct {
            symbol_id: SymbolId,
            value: InstId,
        },
        binary: struct {
            lhs: InstId,
            rhs: InstId,
        },
        range: Span,
    };
};

/// DiaIR is Intermediate Representation for DiascriptZ.
pub const DiaIR = @This();

allocator: Allocator,
ast: *const Ast,
lower: *const Lower,

instructions: std.ArrayList(Inst) = .empty,
extra: std.ArrayList(InstId) = .empty,
symbol_ref: SymbolId = 0,
label_ref: IdentId = 0,
jump_ref: IdentId = 0,
text_id_ref: u32 = 0,

pub fn deinit(ir: *DiaIR) void {
    const allocator = ir.allocator;
    ir.instructions.deinit(allocator);
    ir.extra.deinit(allocator);
}

pub fn generate(ir: *DiaIR) Error!void {
    const allocator = ir.allocator;
    // We expect as many diaIR instructions and extra as nodes and extra_data.
    try ir.instructions.ensureTotalCapacity(allocator, ir.ast.nodes.len);
    try ir.extra.ensureTotalCapacity(allocator, ir.ast.extra_data.len);

    // Root node in a post-traversal order is the last node.
    const root_node = ir.ast.nodes.get(ir.ast.nodes.len - 1);
    const range = root_node.data.range;
    _ = try ir.reduceBlock(range.start, range.len);

    try ir.instructions.shrinkToLen(allocator);
    try ir.extra.shrinkToLen(allocator);
}

fn appendInst(ir: *DiaIR, comptime tag: Inst.Tag, token_pos: TokenIndex, data: Inst.Data) InstId {
    const len: InstId = @intCast(ir.instructions.items.len);
    ir.instructions.appendAssumeCapacity(.{
        .tag = tag,
        .token_pos = token_pos,
        .data = data,
    });

    return len;
}

fn appendSpan(ir: *DiaIR, items: []const InstId) Span {
    const start: u32 = @intCast(ir.extra.items.len);
    ir.extra.appendSliceAssumeCapacity(items);

    return .{ .start = start, .len = @intCast(items.len) };
}

fn nextSymbol(ir: *DiaIR) SymbolId {
    const id = ir.lower.symbol_refs[ir.symbol_ref];
    ir.symbol_ref += 1;
    return id;
}

fn nextLabel(ir: *DiaIR) IdentId {
    const id = ir.lower.labels[ir.label_ref];
    ir.label_ref += 1;
    return id;
}

fn nextJump(ir: *DiaIR) IdentId {
    const id = ir.lower.jumps[ir.jump_ref];
    ir.jump_ref += 1;
    return id;
}

fn nextText(ir: *DiaIR) u32 {
    const len = ir.text_id_ref;
    ir.text_id_ref += 1;
    return len;
}

fn reduceBlock(ir: *DiaIR, start: u32, len: u32) Error!InstId {
    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(ir.allocator);

    try ir.reduceStmtList(&stmts, start, len);

    return ir.appendInst(.block, 0, .{
        .range = ir.appendSpan(stmts.items),
    });
}

fn reduceStmtList(ir: *DiaIR, stmts: *std.ArrayList(InstId), start: u32, len: u32) Error!void {
    var i: u32 = start;
    const end = start + len;

    while (i < end) {
        const node_idx = ir.ast.extra_data[i];
        const node = ir.ast.nodes.get(node_idx);

        if (node.tag != .choice) {
            const inst = try ir.reduceStmt(node);
            try stmts.append(ir.allocator, inst);

            i += 1;
            continue;
        }

        // Handle choices
        const choice_count = ir.countChoices(i, end);
        if (choice_count != 1) {
            const choice_block = try ir.reduceChoiceBlock(i, choice_count);
            try stmts.append(ir.allocator, choice_block);
        } else {
            const choice = try ir.reduceChoice(node);
            try stmts.append(ir.allocator, choice);
        }

        i += choice_count;
    }
}

fn countChoices(ir: *DiaIR, start: u32, end: u32) InstId {
    var i = start;
    while (i < end) : (i += 1) {
        const node_idx = ir.ast.extra_data[i];
        const node = ir.ast.nodes.get(node_idx);

        if (node.tag != .choice) break;
    }

    return i - start;
}

fn reduceChoiceBlock(ir: *DiaIR, start: u32, len: u32) !InstId {
    var choices: std.ArrayList(InstId) = .empty;
    defer choices.deinit(ir.allocator);

    try choices.ensureTotalCapacityPrecise(ir.allocator, len);

    const first_choice = ir.ast.nodes.get(ir.ast.extra_data[start]);

    const end = start + len;
    for (start .. end) |idx| {
        const choice_idx = ir.ast.extra_data[idx];
        const choice_node = ir.ast.nodes.get(choice_idx);
        const choice = try ir.reduceChoice(choice_node);

        choices.appendAssumeCapacity(choice);
    }

    return ir.appendInst(.choice_block, first_choice.token_pos, .{
        .range = ir.appendSpan(choices.items)
    });
}

fn reduceStmt(ir: *DiaIR, node: Node) Error!InstId {
    return switch (node.tag) {
        // Arithmetic IR
        .declar_stmt, .assign => ir.reduceDecl(node),
        .plus_equal => ir.reduceArith(node, .add),
        .minus_equal => ir.reduceArith(node, .sub),
        .mult_equal => ir.reduceArith(node, .mul),
        .div_equal => ir.reduceArith(node, .div),

        // Comparison IR
        .if_stmt => try ir.reduceIfStmt(node),

        // Dialogue IR
        .dialogue => ir.reduceDialogue(node),
        .choice => ir.reduceChoice(node),

        .label => ir.reduceLabel(node),
        else => unreachable,
    };
}

fn reduceDecl(ir: *DiaIR, node: Node) Error!InstId {
    const assign = node.data.node_and_node;
    const value_idx = assign.@"1";
    const value_node = ir.ast.nodes.get(value_idx);

    const symbol_id = ir.nextSymbol();

    const value = try ir.evalValue(value_node);

    return ir.appendInst(.store, node.token_pos, .{
        .store = .{ .symbol_id = symbol_id, .value = value }
    });
}

// Convert combinational arithmetic to singular arithmetic
fn reduceArith(ir: *DiaIR, node: Node, comptime tag: Inst.Tag) Error!InstId {
    const operand = node.data.node_and_node;
    const ident_idx = operand.@"0";
    const value_idx = operand.@"1";

    const value_node = ir.ast.nodes.get(value_idx);

    const ident = ir.ast.nodes.get(ident_idx);
    const symbol_id = ir.nextSymbol();

    const lhs = ir.appendInst(.load, ident.token_pos, .{
        .load = symbol_id,
    });
    const rhs = try ir.evalValue(value_node);

    const result = ir.appendInst(tag, node.token_pos, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
    return ir.appendInst(.store, node.token_pos, .{
        .store = .{ .symbol_id = symbol_id, .value = result }
    });
}

fn reduceIfStmt(ir: *DiaIR, node: Node) Error!InstId {
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(ir.allocator);

    try stmts.ensureTotalCapacity(ir.allocator, len);

    const cond_idx = ir.ast.extra_data[start];
    const cond_node = ir.ast.nodes.get(cond_idx);
    const cond = try ir.reduceCondition(cond_node);

    const then_idx = ir.ast.extra_data[start + 1];
    const then_node = ir.ast.nodes.get(then_idx);
    const t_range = then_node.data.range;
    const then_block = try ir.reduceBlock(t_range.start, t_range.len);

    const else_idx = ir.ast.extra_data[start + 2];
    var else_block: u32 = invalid_node;
    if (else_idx != invalid_node) {
        const else_node = ir.ast.nodes.get(else_idx);
        const e_range = else_node.data.range;
        else_block = try ir.reduceBlock(e_range.start, e_range.len);
    }

    stmts.appendAssumeCapacity(cond);
    stmts.appendAssumeCapacity(then_block);
    stmts.appendAssumeCapacity(else_block);

    return ir.appendInst(.branch, node.token_pos, .{
        .range = ir.appendSpan(stmts.items),
    });
}

fn reduceDialogue(ir: *DiaIR, node: Node) Error!InstId {
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    var parts: std.ArrayList(u32) = .empty;
    defer parts.deinit(ir.allocator);

    try parts.ensureTotalCapacityPrecise(ir.allocator, len);
    const speaker_node = ir.ast.nodes.get(ir.ast.extra_data[range.start]);

    var speaker: InstId = invalid_inst;
    if (speaker_node.tag != .anonymous) {
        const speaker_id = ir.nextSymbol();
        speaker = ir.appendInst(.speaker, node.token_pos, .{
            .load = speaker_id,
        });
    }

    parts.appendAssumeCapacity(speaker);

    const block_range = try ir.reduceDialogueParts(&parts, start, len);

    return ir.appendInst(.dialogue, node.token_pos, block_range);
}

fn reduceChoice(ir: *DiaIR, node: Node) Error!InstId {
    const range = node.data.range;
    const len = range.len;

    var parts: std.ArrayList(u32) = .empty;
    defer parts.deinit(ir.allocator);

    try parts.ensureTotalCapacityPrecise(ir.allocator, len);

    // Choice is the same as dialogue except
    // speaker is an invalid node.
    parts.appendAssumeCapacity(invalid_inst);

    const block_range = try ir.reduceDialogueParts(&parts, range.start, len);

    return ir.appendInst(.choice, node.token_pos, block_range);
}

// Dialogue parts scans the line and jump. NOT the speaker.
fn reduceDialogueParts(ir: *DiaIR, parts: *std.ArrayList(u32), start: u32, len: u32) Error!Inst.Data {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = ir.ast.extra_data[idx];
        const text_node = ir.ast.nodes.get(text_idx);
        const text = try ir.evalValue(text_node);
        parts.appendAssumeCapacity(text);
    }

    const jump_idx = ir.ast.extra_data[end - 1];
    var jump: u32 = invalid_inst;
    if (jump_idx != invalid_inst) {
        const jump_node = ir.ast.nodes.get(jump_idx);
        const ident_id = ir.nextJump();
        jump = ir.appendInst(.jump, jump_node.token_pos, .{
            .jump = ident_id,
        });
    }

    parts.appendAssumeCapacity(jump);

    return .{ .range = ir.appendSpan(parts.items)};
}

// TODO: reduceBlock and reduceLabel:
// Try to find a helper function to prevent duplicate code.
// label extra_data layout:
// [ label_pos, stmt_1, stmt_2, stmt_3, ... , stmt_n ]
fn reduceLabel(ir: *DiaIR, node: Node) Error!InstId {
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    const label_idx = ir.ast.extra_data[start];
    const label_node = ir.ast.nodes.get(label_idx);

    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(ir.allocator);

    const ident_id = ir.nextLabel();
    const label_inst = ir.appendInst(.label, label_node.token_pos, .{
        .label = ident_id,
    });

    try stmts.append(ir.allocator, label_inst);

    // Skip the label itself.
    try ir.reduceStmtList(&stmts, start + 1, len - 1);

    return ir.appendInst(.label_block, node.token_pos, .{
        .range = ir.appendSpan(stmts.items),
    });
}

fn reduceCondition(ir: *DiaIR, node: Node) Error!InstId {
    return try switch (node.tag) {
        .bool_and => ir.evalConjunction(.bool_and, node),
        .bool_or => ir.evalConjunction(.bool_or, node),
        else => ir.evalCompare(node),
    };
}

fn evalValue(ir: *DiaIR, node: Node) Error!InstId {
    const token_pos = node.token_pos;
    return switch (node.tag) {
        .number => {
            const text = ir.ast.tokenSlice(token_pos);
            const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

            return ir.appendInst(.constant, token_pos, .{ .uint = num });
        },
        .var_ident => {
            const symbol_id = ir.nextSymbol();
            return ir.appendInst(.load, token_pos, .{
                .load = symbol_id
            });
        },
        .string => {
            const text_id = ir.nextText();
            const span: Span = ir.lower.pool.text_spans[text_id];
            return ir.appendInst(.text, node.token_pos, .{ .range = span });
        },

        .plus => ir.evalBinary(.add, node),
        .minus => ir.evalBinary(.sub, node),
        .mult => ir.evalBinary(.mul, node),
        .div => ir.evalBinary(.div, node),

        else => unreachable,
    };
}

fn evalBinary(ir: *DiaIR, comptime tag: Inst.Tag, node: Node) Error!InstId {
    const children = node.data.node_and_node;
    const lhs_node = ir.ast.nodes.get(children.@"0");
    const rhs_node = ir.ast.nodes.get(children.@"1");
    const lhs = try ir.evalValue(lhs_node);
    const rhs = try ir.evalValue(rhs_node);

    return ir.appendInst(tag, node.token_pos, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
}

fn evalConjunction(ir: *DiaIR, comptime tag: Inst.Tag, node: Node) Error!InstId {
    const children = node.data.node_and_node;
    const lhs_node = ir.ast.nodes.get(children.@"0");
    const rhs_node = ir.ast.nodes.get(children.@"1");
    const lhs = try ir.reduceCondition(lhs_node);
    const rhs = try ir.reduceCondition(rhs_node);

    return ir.appendInst(tag, node.token_pos, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
}

fn evalCompare(ir: *DiaIR, node: Node) Error!InstId {
    return try switch (node.tag) {
        .equal_equal => ir.evalBinary(.eql, node),
        .not_equal => ir.evalBinary(.not_eql, node),
        .less => ir.evalBinary(.less, node),
        .less_or_equal => ir.evalBinary(.less_or_eql, node),
        .greater => ir.evalBinary(.greater, node),
        .greater_or_equal => ir.evalBinary(.greater_or_eql, node),
        else => unreachable,
    };
}
