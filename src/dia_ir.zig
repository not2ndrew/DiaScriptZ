const std = @import("std");
const zig_node = @import("node.zig");
const Ast = @import("ast.zig").Ast;
const TokenIndex = @import("token.zig").TokenIndex;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const NodeIndex = zig_node.NodeIndex;
const NodeTag = zig_node.NodeTag;

const Nodes = std.MultiArrayList(Node).Slice;

const EvalResult = union(enum) {
    constant: u8,
    non_constant,
};

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        // arithmetic
        constant,
        var_decl,
        plus,
        minus,
        mult,
        div,

        // dialogue
        load,
        jump,
        branch,
        text,
    };

    pub const Data = union {
        none: void,
        uint: u8,
        token_pos: u32,
    };
};


pub const DiaIR = struct {
    ast: *Ast,
    source: []const u8,
    instructions: std.ArrayList(Inst),

    pub fn deinit(self: *DiaIR, allocator: Allocator) void {
        self.instructions.deinit(allocator);
    }

    pub fn generate(allocator: Allocator, ast: *Ast, source: []const u8) !void {
        var diaIR: DiaIR = .{
            .ast = ast,
            .source = source,
            .instructions = .empty,
        };
        defer diaIR.deinit(allocator);

        // We expect as many diaIR instructions as nodes.
        try diaIR.instructions.ensureTotalCapacity(allocator, ast.nodes.len);

        // Root node in a post-traversal order is the last node.
        const root_node = ast.nodes.get(ast.nodes.len - 1);
        const range = root_node.data.range;
        diaIR.analyzeBlock(range.start, range.len);
    }

    fn identName(self: *DiaIR, token_pos: TokenIndex) []const u8 {
        const token = self.ast.tokens.get(token_pos);
        return self.source[token.start..token.end];
    }

    fn appendConstant(self: *DiaIR, constant: u8) void {
        self.instructions.appendAssumeCapacity(.{
            .tag = .constant,
            .data = .{ .uint = constant }
        });
    }

    fn analyzeBlock(self: *DiaIR, start: u32, len: u32) void {
        const end = start + len;
        for (start..end) |idx| {
            const node_idx = self.ast.extra_data[idx];
            self.analyzeNode(node_idx);
        }
    }

    fn analyzeNode(self: *DiaIR, node_idx: NodeIndex) void {
        const node = self.ast.nodes.get(node_idx);
        switch (node.tag) {
            // Arithmetic IR
            .declar_stmt, .assign,
            .plus_equal, .minus_equal,
            .mult_equal, .div_equal => self.analyzeDecl(node),
            
            .equals, .not_equal, .less,
            .less_or_equal, .greater,
            .greater_or_equal => self.analyzeCompare(node),

            // Dialogue IR
            else => {},
        }
    }

    fn analyzeDecl(self: *DiaIR, node: Node) void {
        const value_idx = node.data.node_and_node.@"1";
        const result = self.evalConst(value_idx);

        if (result == .constant)
            self.appendConstant(result.constant);
    }

    fn analyzeCompare(self: *DiaIR, node: Node) void {
        const children = node.data.node_and_node;
        const left = self.evalConst(children.@"0");
        const right = self.evalConst(children.@"1");

        if (left == .constant)
            self.appendConstant(left.constant);

        if (right == .constant)
            self.appendConstant(right.constant);
    }

    fn evalConst(self: *DiaIR, node_idx: NodeIndex) EvalResult {
        const node = self.ast.nodes.get(node_idx);

        switch (node.tag) {
            .number => {
                const token = self.ast.tokens.get(node.token_pos);
                const text = self.source[token.start..token.end];
                const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

                return EvalResult{ .constant = num };
            },
            .var_ident => {
                self.instructions.appendAssumeCapacity(.{
                    .tag = .var_decl,
                    .data = .{ .token_pos = node.token_pos }
                });

                return .non_constant;
            },
            .plus, .minus, .mult, .div => {
                const children = node.data.node_and_node;
                const lhs = self.evalConst(children.@"0");
                const rhs = self.evalConst(children.@"1");

                // TODO: Find an easier way to fold children.
                // Too many nests of code.
                return switch (lhs) {
                    .constant => |l| switch (rhs) {
                        .constant => |r| EvalResult{ .constant = fold(node.tag, l, r) },
                        else => .non_constant,
                    },
                    else => .non_constant,
                };
            },
            else => return .non_constant,
        }
    }
};


fn fold(tag: NodeTag, left: u8, right: u8) u8 {
    switch (tag) {
        .plus => {
            return left + right;
        },
        .minus => {
            return left - right;
        },
        .mult => {
            return left * right;
        },
        .div => {
            // Never divide by 0
            if (right == 0) return 0;
            return left / right;
        },
        else => return 0,
    }
}
