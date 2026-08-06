const std = @import("std");
const zig_node = @import("node.zig");
const Ast = @import("ast.zig").Ast;
const TokenIndex = @import("token.zig").TokenIndex;
const Local = @import("semantic.zig").Local;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const NodeIndex = zig_node.NodeIndex;
const NodeTag = zig_node.NodeTag;
const invalid_node = zig_node.invalid_node;

const Nodes = std.MultiArrayList(Node).Slice;
const Insts = std.ArrayList(Inst);
const Locals = std.ArrayList(Local);

const Error = Allocator.Error;

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        // Value-producing
        nop,
        constant,
        load,

        // Store
        // declaration statements such as "const" and "var"
        // are handled in Semantic.
        store,
        block,

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
        speaker,
        text,

        // Control flow
        jump,
        branch,
    };

    // TODO: Maybe don't store token_pos
    // IR and Sem both have token_pos. When we enter code optimization,
    // it is redundant to store both of them.
    // Every execution has to perform
    // token_pos -> token -> source slice -> symbol lookup -> symbol
    // or
    // symbol -> token_pos -> token -> source slice -> symbol lookup
    pub const Data = union {
        none: void,
        uint: u8,
        token_pos: u32,
        binary: struct {
            lhs: u32,
            rhs: u32,
        },
        range: struct {
            start: u32,
            len: u32,
        },
    };
};

/// DiaIR is Intermediate Representation for DiascriptZ.
pub const DiaIR = @This();

allocator: Allocator,
ast: *Ast,
source: []const u8,

instructions: Insts = .empty,
extra: std.ArrayList(u32) = .empty,

pub fn deinit(ir: *DiaIR) void {
    ir.instructions.deinit(ir.allocator);
    ir.extra.deinit(ir.allocator);
}

pub fn generate(allocator: Allocator, ast: *Ast, source: []const u8) Error!void {
    var diaIR: DiaIR = .{
        .allocator = allocator,
        .ast = ast,
        .source = source,
    };
    defer diaIR.deinit();

    // We expect as many diaIR instructions and extra as nodes and extra_data.
    try diaIR.instructions.ensureTotalCapacity(allocator, ast.nodes.len);
    try diaIR.extra.ensureTotalCapacity(allocator, ast.extra_data.len);

    // Root node in a post-traversal order is the last node.
    const root_node = ast.nodes.get(ast.nodes.len - 1);
    const range = root_node.data.range;
    _ = try diaIR.reduceBlock(range.start, range.len);
}

fn identName(ir: *DiaIR, token_pos: TokenIndex) []const u8 {
    const token = ir.ast.tokens.get(token_pos);
    return ir.source[token.start..token.end];
}

fn appendInst(ir: *DiaIR, comptime tag: Inst.Tag, data: Inst.Data) u32 {
    ir.instructions.appendAssumeCapacity(.{
        .tag = tag,
        .data = data,
    });

    const len: u32 = @intCast(ir.instructions.items.len);
    return len - 1;
}

fn reduceBlock(ir: *DiaIR, start: u32, len: u32) Error!u32 {
    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(ir.allocator);

    try stmts.ensureTotalCapacityPrecise(ir.allocator, len);
    const end = start + len;

    for (start..end) |idx| {
        const idx_cast: u32 = @intCast(idx);
        const stmt_idx = ir.ast.extra_data[idx_cast];
        const inst_idx = try ir.reduceStmt(stmt_idx);
        stmts.appendAssumeCapacity(inst_idx);
    }

    const range_start: u32 = @intCast(ir.extra.items.len);
    ir.extra.appendSliceAssumeCapacity(stmts.items);

    return ir.appendInst(.block, .{
        .range = .{
            .start = range_start,
            .len = len,
        }
    });
}

fn reduceStmt(ir: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = ir.ast.nodes.get(node_idx);
    return switch (node.tag) {
        // Arithmetic IR
        .declar_stmt, .assign => ir.reduceDecl(node),
        .plus_equal => ir.reduceArith(node, .add),
        .minus_equal => ir.reduceArith(node, .sub),
        .mult_equal => ir.reduceArith(node, .mul),
        .div_equal => ir.reduceArith(node, .div),

        // Comparison IR
        .if_stmt => try ir.reduceIfStmt(node),

        .block, => {
            const range = node.data.range;
            return try ir.reduceBlock(range.start, range.len);
        },
        // Dialogue IR
        .dialogue => ir.reduceDialogue(node),
        .choice => ir.reduceChoice(node),

        // TODO: label also has a label_ident.
        // Append Inst for label.
        .label => invalid_node,
        else => invalid_node,
    };
}

fn reduceDecl(ir: *DiaIR, node: Node) Error!u32 {
    const assign = node.data.node_and_node;
    const ident_idx = assign.@"0";
    const value_idx = assign.@"1";

    const ident = ir.ast.nodes.get(ident_idx);
    const ident_pos = ir.appendInst(.load, .{ .token_pos = ident.token_pos });
    const value = try ir.evalExpr(value_idx);

    return ir.appendInst(.store, .{
        .binary = .{ .lhs = ident_pos, .rhs = value }
    });
}

// Convert combinational arithmetic to singular arithmetic
fn reduceArith(ir: *DiaIR, node: Node, comptime tag: Inst.Tag) Error!u32 {
    const operand = node.data.node_and_node;
    const ident_idx = operand.@"0";
    const value_idx = operand.@"1";

    const ident = ir.ast.nodes.get(ident_idx);
    const ident_pos = ir.appendInst(.load, .{ .token_pos = ident.token_pos });

    const ident_pos_2 = ir.appendInst(.load, .{ .token_pos = ident.token_pos });
    const expr = try ir.evalExpr(value_idx);
    const combine = ir.appendInst(tag, .{
        .binary = .{ .lhs = ident_pos_2, .rhs = expr }
    });

    return ir.appendInst(.store, .{
        .binary = .{ .lhs = ident_pos, .rhs = combine }
    });
}

fn reduceIfStmt(ir: *DiaIR, node: Node) Error!u32 {
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(ir.allocator);

    try stmts.ensureTotalCapacity(ir.allocator, len);

    const condition_idx = ir.ast.extra_data[start];
    const condition = try ir.reduceCondition(condition_idx);

    const then_idx = ir.ast.extra_data[start + 1];
    const then_block = try ir.reduceStmt(then_idx);

    const else_idx = ir.ast.extra_data[start + 2];
    var else_block: u32 = invalid_node;
    if (else_idx != invalid_node) {
        else_block = try ir.reduceStmt(else_idx);
    }

    stmts.appendAssumeCapacity(condition);
    stmts.appendAssumeCapacity(then_block);
    stmts.appendAssumeCapacity(else_block);

    const extra_start: u32 = @intCast(ir.extra.items.len);
    ir.extra.appendSliceAssumeCapacity(stmts.items);

    return ir.appendInst(.branch, .{
        .range = .{ .start = extra_start, .len = len }
    });
}

fn reduceDialogue(ir: *DiaIR, node: Node) Error!u32 {
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    var parts: std.ArrayList(u32) = .empty;
    defer parts.deinit(ir.allocator);

    try parts.ensureTotalCapacityPrecise(ir.allocator, len);

    const speaker = ir.appendInst(.speaker, .{
        .token_pos = node.token_pos,
    });
    parts.appendAssumeCapacity(speaker);

    try ir.reduceDialogueParts(&parts, start, len);

    const extra_start: u32 = @intCast(ir.extra.items.len);
    ir.extra.appendSliceAssumeCapacity(parts.items);

    return ir.appendInst(.block, .{
        .range = .{ .start = extra_start, .len = len }
    });
}

fn reduceChoice(ir: *DiaIR, node: Node) Error!u32 {
    const range = node.data.range;
    const len = range.len;

    var parts: std.ArrayList(u32) = .empty;
    defer parts.deinit(ir.allocator);

    try parts.ensureTotalCapacityPrecise(ir.allocator, len);

    // Choice is the same as dialogue except
    // speaker is an invalid node.
    parts.appendAssumeCapacity(invalid_node);

    try ir.reduceDialogueParts(&parts, range.start, len);

    const extra_start: u32 = @intCast(ir.extra.items.len);
    ir.extra.appendSliceAssumeCapacity(parts.items);

    return ir.appendInst(.block, .{
        .range = .{ .start = extra_start, .len = len }
    });
}

// Dialogue parts scans the line and jump. NOT the speaker.
fn reduceDialogueParts(ir: *DiaIR, parts: *std.ArrayList(u32), start: u32, len: u32) Error!void {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = ir.ast.extra_data[idx];
        const text = try ir.evalText(text_idx);
        parts.appendAssumeCapacity(text);
    }

    const jump_idx = ir.ast.extra_data[end - 1];
    var jump: u32 = invalid_node;
    if (jump_idx != invalid_node) {
        const jump_node = ir.ast.nodes.get(jump_idx);
        jump = ir.appendInst(.jump, .{
            .token_pos = jump_node.token_pos,
        });
    }

    parts.appendAssumeCapacity(jump);
}

// label extra_data layout:
// [ label_pos, stmt_1, stmt_2, stmt_3, ... , stmt_n ]
fn reduceLabel(ir: *DiaIR, node: Node) Error!void {
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    const label_idx = ir.ast.extra_data.get(start);
    const label_node = ir.ast.nodes.get(label_idx);

    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(ir.allocator);

    try stmts.ensureTotalCapacityPrecise(ir.allocator, len);

    const label_inst = ir.appendInst(.load, .{
        .token_pos = label_node.token_pos,
    });

    stmts.appendAssumeCapacity(label_inst);

    const end = start + len - 1;
    for (start + 1..end) |idx| {
        const ast_stmt = ir.ast.extra_data[idx];
        const stmt_idx = ir.reduceStmt(ast_stmt);
        stmts.appendAssumeCapacity(stmt_idx);
    }
}

fn reduceCondition(ir: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = ir.ast.nodes.get(node_idx);

    return try switch (node.tag) {
        .bool_and => ir.evalConjunction(.bool_and, node),
        .bool_or => ir.evalConjunction(.bool_or, node),
        else => ir.evalCompare(node_idx),
    };
}

fn evalExpr(ir: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = ir.ast.nodes.get(node_idx);
    const token_pos = node.token_pos;
    return switch (node.tag) {
        .number => {
            const text = ir.identName(token_pos);
            const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

            return ir.appendInst(.constant, .{ .uint = num });
        },
        .var_ident => ir.appendInst(.load, .{ .token_pos = token_pos }),
        .plus => ir.evalBinary(.add, node),
        .minus => ir.evalBinary(.sub, node),
        .mult => ir.evalBinary(.mul, node),
        .div => ir.evalBinary(.div, node),
        else => invalid_node,
    };
}

fn evalBinary(ir: *DiaIR, comptime tag: Inst.Tag, node: Node) Error!u32 {
    const children = node.data.node_and_node;
    const lhs = try ir.evalExpr(children.@"0");
    const rhs = try ir.evalExpr(children.@"1");

    return ir.appendInst(tag, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
}

fn evalConjunction(ir: *DiaIR, comptime tag: Inst.Tag, node: Node) Error!u32 {
    const children = node.data.node_and_node;
    const lhs = try ir.reduceCondition(children.@"0");
    const rhs = try ir.reduceCondition(children.@"1");

    return ir.appendInst(tag, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
}

fn evalCompare(ir: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = ir.ast.nodes.get(node_idx);
    return try switch (node.tag) {
        .equal_equal => ir.evalBinary(.eql, node),
        .not_equal => ir.evalBinary(.not_eql, node),
        .less => ir.evalBinary(.less, node),
        .less_or_equal => ir.evalBinary(.less_or_eql, node),
        .greater => ir.evalBinary(.greater, node),
        .greater_or_equal => ir.evalBinary(.greater_or_eql, node),
        else => invalid_node,
    };
}

fn evalText(ir: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = ir.ast.nodes.get(node_idx);
    return try switch (node.tag) {
        .string => ir.appendInst(.text, .{ .token_pos = node.token_pos }),
        else => ir.evalExpr(node_idx),
    };
}
