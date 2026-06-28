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
    ast: *Ast,
    source: []const u8,
    instructions: std.ArrayList(Inst),
    extra: std.ArrayList(u32),

    pub fn deinit(self: *DiaIR, allocator: Allocator) void {
        self.instructions.deinit(allocator);
        self.extra.deinit(allocator);
    }

    pub fn generate(allocator: Allocator, ast: *Ast, source: []const u8) !void {
        var diaIR: DiaIR = .{
            .ast = ast,
            .source = source,
            .instructions = .empty,
            .extra = .empty,
        };
        defer diaIR.deinit(allocator);

        // We expect as many diaIR instructions and extra as nodes and extra_data.
        try diaIR.instructions.ensureTotalCapacityPrecise(allocator, ast.nodes.len);
        try diaIR.extra.ensureTotalCapacityPrecise(allocator, ast.extra_data.len);

        // Root node in a post-traversal order is the last node.
        const root_node = ast.nodes.get(ast.nodes.len - 1);
        const range = root_node.data.range;
        _ = try diaIR.analyzeBlock(allocator, range.start, range.len);
        
        std.debug.print("Extra capacity: {d}, len: {d}\n", .{diaIR.extra.capacity, diaIR.extra.items.len});
        std.debug.print("Inst capacity: {d}, len: {d}\n", .{diaIR.instructions.capacity, diaIR.instructions.items.len});
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

    fn analyzeBlock(self: *DiaIR, allocator: Allocator, start: u32, len: u32) !u32 {
        var stmts: std.ArrayList(u32) = .empty;
        defer stmts.deinit(allocator);

        try stmts.ensureTotalCapacity(allocator, len);
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
            .declar_stmt, .assign,
            .plus_equal, .minus_equal,
            .mult_equal, .div_equal => self.analyzeDecl(node),
            
            // Comparison IR
            // .if_stmt => self.analyzeIfStmt(node),
            // .equals => self.evalBinary(.eql, node),
            // .not_equal => self.evalBinary(.not_eql, node),
            // .less => self.evalBinary(.less, node),
            // .less_or_equal => self.evalBinary(.less_or_eql, node),
            // .greater => self.evalBinary(.greater, node),
            // .greater_or_equal => self.evalBinary(.greater_or_eql, node),

            // Dialogue IR
            else => invalid_node,
        };
    }

    fn analyzeDecl(self: *DiaIR, node: Node) u32 {
        const decl = node.data.node_and_node;
        const ident_idx = decl.@"0";
        const value_idx = decl.@"1";

        const ident = self.ast.nodes.get(ident_idx);
        const ident_pos = self.appendInst(.load, .{ .token_pos = ident.token_pos });
        const value = self.evalExpr(value_idx);

        return self.appendInst(.store, .{
            .binary = .{ .lhs = ident_pos, .rhs = value }
        });
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
            // .plus => self.evalBinary(.plus, node),
            // .minus => self.evalBinary(.minus, node),
            // .mult => self.evalBinary(.mult, node),
            // .div => self.evalBinary(.div, node),
            else => 0,
        };
    }

    fn evalBinary(self: *DiaIR, comptime tag: Inst.Tag, node: Node) void {
        const children = node.data.node_and_node;
        const lhs = self.evalExpr(children.@"0");
        const rhs = self.evalExpr(children.@"1");

        return self.appendInst(tag, .{
            .binary = .{ .lhs = lhs, .rhs = rhs }
        });
    }
};
