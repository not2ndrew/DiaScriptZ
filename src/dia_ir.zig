const std = @import("std");
const zig_node = @import("node.zig");
const Ast = @import("ast.zig").Ast;
const TokenIndex = @import("token.zig").TokenIndex;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const NodeIndex = zig_node.NodeIndex;
const NodeTag = zig_node.NodeTag;
const invalid_node = zig_node.invalid_node;

const Nodes = std.MultiArrayList(Node).Slice;

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
        // TODO: block is too vague.
        // There are many types of blocks:
        // 1) blocks in if_stmt,
        // 2) blocks in labels
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
        text,

        // Control flow
        jump,
        branch,
    };

    pub const Data = union {
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
pub const DiaIR = struct {
    allocator: Allocator,
    ast: *Ast,
    source: []const u8,
    instructions: std.ArrayList(Inst),
    extra: std.ArrayList(u32),

    pub fn deinit(self: *DiaIR) void {
        self.instructions.deinit(self.allocator);
        self.extra.deinit(self.allocator);
    }

    pub fn generate(allocator: Allocator, ast: *Ast, source: []const u8) !void {
        var diaIR: DiaIR = .{
            .allocator = allocator,
            .ast = ast,
            .source = source,
            .instructions = .empty,
            .extra = .empty,
        };
        defer diaIR.deinit();

        // We expect as many diaIR instructions and extra as nodes and extra_data.
        try diaIR.instructions.ensureTotalCapacity(allocator, ast.nodes.len);
        try diaIR.extra.ensureTotalCapacity(allocator, ast.extra_data.len);

        // Root node in a post-traversal order is the last node.
        const root_node = ast.nodes.get(ast.nodes.len - 1);
        const range = root_node.data.range;
        _ = try diaIR.analyzeBlock(range.start, range.len);

        for (ast.nodes.items(.tag)) |tag| {
            std.debug.print("Node tag: {t}\n", .{tag});
        }

        for (diaIR.instructions.items) |inst| {
            std.debug.print("Instruction Tag: {t}\n", .{inst.tag});
        }
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

    fn analyzeBlock(self: *DiaIR, start: u32, len: u32) !u32 {
        var stmts: std.ArrayList(u32) = .empty;
        defer stmts.deinit(self.allocator);

        try stmts.ensureTotalCapacityPrecise(self.allocator, len);
        const end = start + len;

        for (start..end) |idx| {
            const idx_cast: u32 = @intCast(idx);
            const stmt_idx = self.ast.extra_data[idx_cast];
            const inst_idx = self.analyzeNode(stmt_idx);
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

    fn analyzeNode(self: *DiaIR, node_idx: NodeIndex) u32 {
        const node = self.ast.nodes.get(node_idx);
        return switch (node.tag) {
            // Arithmetic IR
            .declar_stmt, .assign => self.analyzeDecl(node),
            .plus_equal => self.analyzeArith(node, .plus),
            .minus_equal => self.analyzeArith(node, .minus),
            .mult_equal => self.analyzeArith(node, .mult),
            .div_equal => self.analyzeArith(node, .div),
            
            // Comparison IR
            .if_stmt => self.analyzeIfStmt(node),

            .block, .label => {
                const range = node.data.range;
                return self.analyzeBlock(range.start, range.len) catch unreachable;
            },
            // Dialogue IR
            else => invalid_node,
        };
    }

    fn analyzeDecl(self: *DiaIR, node: Node) u32 {
        const assign = node.data.node_and_node;
        const ident_idx = assign.@"0";
        const value_idx = assign.@"1";

        const ident = self.ast.nodes.get(ident_idx);
        const ident_pos = self.appendInst(.load, .{ .token_pos = ident.token_pos });
        const value = self.evalExpr(value_idx);

        return self.appendInst(.store, .{
            .binary = .{ .lhs = ident_pos, .rhs = value }
        });
    }

    // Convert combinational arithmetic to singular arithmetic
    fn analyzeArith(self: *DiaIR, node: Node, comptime tag: Inst.Tag) u32 {
        const operand = node.data.node_and_node;
        const ident_idx = operand.@"0";
        const value_idx = operand.@"1";

        const ident = self.ast.nodes.get(ident_idx);
        const ident_pos = self.appendInst(.load, .{ .token_pos = ident.token_pos });

        const ident_pos_2 = self.appendInst(.load, .{ .token_pos = ident.token_pos });
        const expr = self.evalExpr(value_idx);
        const combine = self.appendInst(tag, .{
            .binary = .{ .lhs = ident_pos_2, .rhs = expr }
        });

        return self.appendInst(.store, .{
            .binary = .{ .lhs = ident_pos, .rhs = combine }
        });
    }

    fn analyzeIfStmt(self: *DiaIR, node: Node) u32 {
        const range = node.data.range;
        const start = range.start;
        const len = range.len;

        var stmts: std.ArrayList(u32) = .empty;
        defer stmts.deinit(self.allocator);

        stmts.ensureTotalCapacity(self.allocator, len) catch unreachable;

        const condition_idx = self.ast.extra_data[start];
        const condition = self.analyzeCondition(condition_idx);

        stmts.appendAssumeCapacity(condition);

        const then_idx = self.ast.extra_data[start + 1];
        const then_block = self.analyzeNode(then_idx);

        stmts.appendAssumeCapacity(then_block);

        const else_idx = self.ast.extra_data[start + 2];
        var else_block: u32 = invalid_node;
        if (else_idx != invalid_node) {
            else_block = self.analyzeNode(else_idx);
        }

        stmts.appendAssumeCapacity(else_block);

        const extra_start: u32 = @intCast(self.extra.items.len);
        self.extra.appendSliceAssumeCapacity(stmts.items);

        return self.appendInst(.branch, .{
            .range = .{ .start = extra_start, .len = len }
        });
    }

    fn analyzeCondition(self: *DiaIR, node_idx: NodeIndex) u32 {
        const node = self.ast.nodes.get(node_idx);

        return switch (node.tag) {
            .bool_and => self.evalConjunction(.bool_and, node),
            .bool_or => self.evalConjunction(.bool_or, node),
            else => self.evalCompare(node_idx),
        };
    }

    fn evalExpr(self: *DiaIR, node_idx: NodeIndex) u32 {
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

    fn evalBinary(self: *DiaIR, comptime tag: Inst.Tag, node: Node) u32 {
        const children = node.data.node_and_node;
        const lhs = self.evalExpr(children.@"0");
        const rhs = self.evalExpr(children.@"1");

        return self.appendInst(tag, .{
            .binary = .{ .lhs = lhs, .rhs = rhs }
        });
    }

    fn evalConjunction(self: *DiaIR, comptime tag: Inst.Tag, node: Node) u32 {
        const children = node.data.node_and_node;
        const lhs = self.analyzeCondition(children.@"0");
        const rhs = self.analyzeCondition(children.@"1");

        return self.appendInst(tag, .{
            .binary = .{ .lhs = lhs, .rhs = rhs }
        });
    }

    fn evalCompare(self: *DiaIR, node_idx: NodeIndex) u32 {
        const node = self.ast.nodes.get(node_idx);
        return switch (node.tag) {
            .equal_equal => self.evalBinary(.eql, node),
            .not_equal => self.evalBinary(.not_eql, node),
            .less => self.evalBinary(.less, node),
            .less_or_equal => self.evalBinary(.less_or_eql, node),
            .greater => self.evalBinary(.greater, node),
            .greater_or_equal => self.evalBinary(.greater_or_eql, node),
            else => invalid_node,
        };
    }
};
