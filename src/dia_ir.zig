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
        plus,
        minus,
        mult,
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
    // every execution has to perform
    // token_pos -> token -> source slice -> symbol lookup -> symbol
    //
    // Instead, store an index to where the symbol is stored.
    // This requires symbol hashset from Semantic.
    //
    // That way, it is easier to extract
    // symbolID -> symbol lookup -> symbol
    //
    // If we ever need the name of the symbol, then store token_pos.
    //
    // TODO: Don't do parseInt() and name look up in evalExpr().
    // Both operations are done in Semantic.
    //
    // So, Symbol should store uint in its extra union data.
    pub const Data = union {
        uint: u8,
        token_pos: u32,
        // symbolID: u32,
        // labelID: u32,
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

pub fn deinit(self: *DiaIR) void {
    self.instructions.deinit(self.allocator);
    self.extra.deinit(self.allocator);
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

    // for (ast.nodes.items(.tag)) |tag| {
    //     std.debug.print("Node tag: {t}\n", .{tag});
    // }
    //
    // for (diaIR.instructions.items) |inst| {
    //     std.debug.print("Instruction Tag: {t}\n", .{inst.tag});
    // }
}

fn identName(self: *DiaIR, token_pos: TokenIndex) []const u8 {
    const token = self.ast.tokens.get(token_pos);
    return self.source[token.start..token.end];
}

fn appendInst(self: *DiaIR, comptime tag: Inst.Tag, data: Inst.Data) u32 {
    self.instructions.appendAssumeCapacity(.{
        .tag = tag,
        .data = data,
    });

    const len: u32 = @intCast(self.instructions.items.len);
    return len - 1;
}

fn reduceBlock(self: *DiaIR, start: u32, len: u32) Error!u32 {
    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(self.allocator);

    try stmts.ensureTotalCapacityPrecise(self.allocator, len);
    const end = start + len;

    for (start..end) |idx| {
        const idx_cast: u32 = @intCast(idx);
        const stmt_idx = self.ast.extra_data[idx_cast];
        const inst_idx = try self.reduceStmt(stmt_idx);
        stmts.appendAssumeCapacity(inst_idx);
    }

    self.extra.appendSliceAssumeCapacity(stmts.items);

    const range_start: u32 = @intCast(self.extra.items.len);
    return self.appendInst(.block, .{
        .range = .{
            .start = range_start,
            .len = len,
        }
    });
}

fn reduceStmt(self: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = self.ast.nodes.get(node_idx);
    return switch (node.tag) {
        // Arithmetic IR
        .declar_stmt, .assign => self.reduceDecl(node),
        .plus_equal => self.reduceArith(node, .plus),
        .minus_equal => self.reduceArith(node, .minus),
        .mult_equal => self.reduceArith(node, .mult),
        .div_equal => self.reduceArith(node, .div),

        // Comparison IR
        .if_stmt => try self.reduceIfStmt(node),

        .block, => {
            const range = node.data.range;
            return try self.reduceBlock(range.start, range.len);
        },
        // Dialogue IR
        .dialogue => self.reduceDialogue(node),
        .choice => self.reduceChoice(node),

        // TODO: label also has a label_ident.
        // Append Inst for label.
        .label => invalid_node,
        else => invalid_node,
    };
}

fn reduceDecl(self: *DiaIR, node: Node) Error!u32 {
    const assign = node.data.node_and_node;
    const ident_idx = assign.@"0";
    const value_idx = assign.@"1";

    const ident = self.ast.nodes.get(ident_idx);
    const ident_pos = self.appendInst(.load, .{ .token_pos = ident.token_pos });
    const value = try self.evalExpr(value_idx);

    return self.appendInst(.store, .{
        .binary = .{ .lhs = ident_pos, .rhs = value }
    });
}

// Convert combinational arithmetic to singular arithmetic
fn reduceArith(self: *DiaIR, node: Node, comptime tag: Inst.Tag) Error!u32 {
    const operand = node.data.node_and_node;
    const ident_idx = operand.@"0";
    const value_idx = operand.@"1";

    const ident = self.ast.nodes.get(ident_idx);
    const ident_pos = self.appendInst(.load, .{ .token_pos = ident.token_pos });

    const ident_pos_2 = self.appendInst(.load, .{ .token_pos = ident.token_pos });
    const expr = try self.evalExpr(value_idx);
    const combine = self.appendInst(tag, .{
        .binary = .{ .lhs = ident_pos_2, .rhs = expr }
    });

    return self.appendInst(.store, .{
        .binary = .{ .lhs = ident_pos, .rhs = combine }
    });
}

fn reduceIfStmt(self: *DiaIR, node: Node) Error!u32 {
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(self.allocator);

    try stmts.ensureTotalCapacity(self.allocator, len);

    const condition_idx = self.ast.extra_data[start];
    const condition = try self.reduceCondition(condition_idx);

    const then_idx = self.ast.extra_data[start + 1];
    const then_block = try self.reduceStmt(then_idx);

    const else_idx = self.ast.extra_data[start + 2];
    var else_block: u32 = invalid_node;
    if (else_idx != invalid_node) {
        else_block = try self.reduceStmt(else_idx);
    }

    stmts.appendAssumeCapacity(condition);
    stmts.appendAssumeCapacity(then_block);
    stmts.appendAssumeCapacity(else_block);

    const extra_start: u32 = @intCast(self.extra.items.len);
    self.extra.appendSliceAssumeCapacity(stmts.items);

    return self.appendInst(.branch, .{
        .range = .{ .start = extra_start, .len = len }
    });
}

fn reduceDialogue(self: *DiaIR, node: Node) Error!u32 {
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    var parts: std.ArrayList(u32) = .empty;
    defer parts.deinit(self.allocator);

    try parts.ensureTotalCapacityPrecise(self.allocator, len);

    const speaker = self.appendInst(.speaker, .{
        .token_pos = node.token_pos,
    });
    parts.appendAssumeCapacity(speaker);

    try self.reduceDialogueParts(&parts, start, len);

    const extra_start: u32 = @intCast(self.extra.items.len);
    self.extra.appendSliceAssumeCapacity(parts.items);

    return self.appendInst(.block, .{
        .range = .{ .start = extra_start, .len = len }
    });
}

fn reduceChoice(self: *DiaIR, node: Node) Error!u32 {
    const range = node.data.range;
    const len = range.len;

    var parts: std.ArrayList(u32) = .empty;
    defer parts.deinit(self.allocator);

    try parts.ensureTotalCapacityPrecise(self.allocator, len);

    // Choice is the same as dialogue except
    // speaker is an invalid node.
    parts.appendAssumeCapacity(invalid_node);

    try self.reduceDialogueParts(&parts, range.start, len);

    const extra_start: u32 = @intCast(self.extra.items.len);
    self.extra.appendSliceAssumeCapacity(parts.items);

    return self.appendInst(.block, .{
        .range = .{ .start = extra_start, .len = len }
    });
}

// Dialogue parts scans the line and jump. NOT the speaker.
fn reduceDialogueParts(self: *DiaIR, parts: *std.ArrayList(u32), start: u32, len: u32) Error!void {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = self.ast.extra_data[idx];
        const text = try self.evalText(text_idx);
        parts.appendAssumeCapacity(text);
    }

    const jump_idx = self.ast.extra_data[end - 1];
    var jump: u32 = invalid_node;
    if (jump_idx != invalid_node) {
        const jump_node = self.ast.nodes.get(jump_idx);
        jump = self.appendInst(.jump, .{
            .token_pos = jump_node.token_pos,
        });
    }

    parts.appendAssumeCapacity(jump);
}

// label extra_data layout:
// [ label_pos, stmt_1, stmt_2, stmt_3, ... , stmt_n ]
fn reduceLabel(self: *DiaIR, node: Node) Error!void {
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    const label_idx = self.ast.extra_data.get(start);
    const label_node = self.ast.nodes.get(label_idx);

    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(self.allocator);

    try stmts.ensureTotalCapacityPrecise(self.allocator, len);

    const label_inst = self.appendInst(.load, .{
        .token_pos = label_node.token_pos,
    });

    stmts.appendAssumeCapacity(label_inst);

    const end = start + len - 1;
    for (start + 1..end) |idx| {
        const stmt_idx = self.reduceStmt(idx);
        stmts.appendAssumeCapacity(stmt_idx);
    }
}

fn reduceCondition(self: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = self.ast.nodes.get(node_idx);

    return try switch (node.tag) {
        .bool_and => self.evalConjunction(.bool_and, node),
        .bool_or => self.evalConjunction(.bool_or, node),
        else => self.evalCompare(node_idx),
    };
}

fn evalExpr(self: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = self.ast.nodes.get(node_idx);
    const token_pos = node.token_pos;
    return switch (node.tag) {
        .number => {
            const text = self.identName(token_pos);
            const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

            return self.appendInst(.constant, .{ .uint = num });
        },
        .var_ident => self.appendInst(.load, .{ .token_pos = token_pos }),
        .plus => self.evalBinary(.plus, node),
        .minus => self.evalBinary(.minus, node),
        .mult => self.evalBinary(.mult, node),
        .div => self.evalBinary(.div, node),
        else => invalid_node,
    };
}

fn evalBinary(self: *DiaIR, comptime tag: Inst.Tag, node: Node) Error!u32 {
    const children = node.data.node_and_node;
    const lhs = try self.evalExpr(children.@"0");
    const rhs = try self.evalExpr(children.@"1");

    return self.appendInst(tag, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
}

fn evalConjunction(self: *DiaIR, comptime tag: Inst.Tag, node: Node) Error!u32 {
    const children = node.data.node_and_node;
    const lhs = try self.reduceCondition(children.@"0");
    const rhs = try self.reduceCondition(children.@"1");

    return self.appendInst(tag, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
}

fn evalCompare(self: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = self.ast.nodes.get(node_idx);
    return try switch (node.tag) {
        .equal_equal => self.evalBinary(.eql, node),
        .not_equal => self.evalBinary(.not_eql, node),
        .less => self.evalBinary(.less, node),
        .less_or_equal => self.evalBinary(.less_or_eql, node),
        .greater => self.evalBinary(.greater, node),
        .greater_or_equal => self.evalBinary(.greater_or_eql, node),
        else => invalid_node,
    };
}

fn evalText(self: *DiaIR, node_idx: NodeIndex) Error!u32 {
    const node = self.ast.nodes.get(node_idx);
    return try switch (node.tag) {
        .string => self.appendInst(.text, .{ .token_pos = node.token_pos }),
        else => self.evalExpr(node_idx),
    };
}
