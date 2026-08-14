const std = @import("std");
const zig_node = @import("node.zig");
const in = @import("interner.zig");
const Ast = @import("ast.zig").Ast;
const Symbol = @import("semantic.zig").Symbol;
const TokenIndex = @import("token.zig").TokenIndex;
const Lower = @import("lower.zig").Lower;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const NodeIndex = zig_node.NodeIndex;
const NodeTag = zig_node.NodeTag;
const invalid_node = zig_node.invalid_node;

const InternPool = in.InternPool;
const Span = in.Span;

const Nodes = std.MultiArrayList(Node).Slice;
const Insts = std.ArrayList(Inst);

const Error = Allocator.Error;

pub const SymbolId = u32;
pub const InstId = u32;

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

    pub const Data = union {
        uint: u8,
        load: SymbolId,
        store: struct {
            symbol: SymbolId,
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

instructions: Insts = .empty,
extra: std.ArrayList(u32) = .empty,

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
    try ir.text_bytes.shrinkToLen(allocator);
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

fn reduceBlock(ir: *DiaIR, start: u32, len: u32) Error!Inst.Data {
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

    return .{ .range = .{ .start = range_start, .len = len }};
}

fn reduceStmt(ir: *DiaIR, node_idx: NodeIndex) Error!InstId {
    const node = ir.ast.nodes.get(node_idx);
    return switch (node.tag) {
        // Arithmetic IR
        .declar_stmt, .assign => ir.reduceDecl(node),
        else => invalid_node,
    };
}

fn reduceDecl(ir: *DiaIR, node: Node) Error!InstId {
    const assign = node.data.node_and_node;
    const ident_idx = assign.@"0";
    const value_idx = assign.@"1";

    _ = ir.allocator;
    _ = ident_idx;
    _ = value_idx;
    return 0;
}

fn reduceCondition(ir: *DiaIR, node_idx: NodeIndex) Error!InstId {
    const node = ir.ast.nodes.get(node_idx);

    return try switch (node.tag) {
        .bool_and => ir.evalConjunction(.bool_and, node),
        .bool_or => ir.evalConjunction(.bool_or, node),
        else => ir.evalCompare(node_idx),
    };
}

fn evalExpr(ir: *DiaIR, node_idx: NodeIndex) Error!InstId {
    const node = ir.ast.nodes.get(node_idx);
    const token_pos = node.token_pos;
    return switch (node.tag) {
        .number => {
            const text = ir.ast.tokenSlice(token_pos);
            const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

            return ir.appendInst(.constant, token_pos, .{ .uint = num });
        },
        .var_ident => {
            const symbol_id = 0;
            return symbol_id;
        },
        .plus => ir.evalBinary(.add, node),
        .minus => ir.evalBinary(.sub, node),
        .mult => ir.evalBinary(.mul, node),
        .div => ir.evalBinary(.div, node),
        else => invalid_node,
    };
}

fn evalBinary(ir: *DiaIR, comptime tag: Inst.Tag, node: Node) Error!InstId {
    const children = node.data.node_and_node;
    const lhs = try ir.evalExpr(children.@"0");
    const rhs = try ir.evalExpr(children.@"1");

    return ir.appendInst(tag, node.token_pos, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
}

fn evalConjunction(ir: *DiaIR, comptime tag: Inst.Tag, node: Node) Error!InstId {
    const children = node.data.node_and_node;
    const lhs = try ir.reduceCondition(children.@"0");
    const rhs = try ir.reduceCondition(children.@"1");

    return ir.appendInst(tag, node.token_pos, .{
        .binary = .{ .lhs = lhs, .rhs = rhs }
    });
}

fn evalCompare(ir: *DiaIR, node_idx: NodeIndex) Error!InstId {
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

fn evalText(ir: *DiaIR, node_idx: NodeIndex) Error!InstId {
    const node = ir.ast.nodes.get(node_idx);
    return try switch (node.tag) {
        .string => {
            const span: Span = .{ .start = 0, .len = 0 };
            return ir.appendInst(.text, node.token_pos, .{ .range = span });
        },
        else => ir.evalExpr(node_idx),
    };
}
