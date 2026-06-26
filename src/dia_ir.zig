const std = @import("std");
const zig_node = @import("node.zig");
const Ast = @import("ast.zig").Ast;
const TokenIndex = @import("token.zig").TokenIndex;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const NodeIndex = zig_node.NodeIndex;
const NodeTag = zig_node.NodeTag;

const Nodes = std.MultiArrayList(Node).Slice;

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        // Value-producing
        constant,
        var_decl,
        load,

        // Store
        store,

        // Arithmetic
        plus,
        minus,
        mult,
        div,

        // Dialogue
        text,

        // Control flow
        jump,
        branch,
    };

    pub const Data = union {
        none: void,
        uint: u8,
        token_pos: u32,
        node_and_node: struct {
            u32, u32,
        },
    };
};


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
        };
        defer diaIR.deinit(allocator);

        // We expect as many diaIR instructions and extra as nodes.
        try diaIR.instructions.ensureTotalCapacity(allocator, ast.nodes.len);
        try diaIR.extra.ensureTotalCapacity(allocator, ast.nodes.len);

        // Root node in a post-traversal order is the last node.
        const root_node = ast.nodes.get(ast.nodes.len - 1);
        const range = root_node.data.range;
        diaIR.analyzeBlock(range.start, range.len);

        // Perform code optimization here 
        // self.folding();
    }

    fn identName(self: *DiaIR, token_pos: TokenIndex) []const u8 {
        const token = self.ast.tokens.get(token_pos);
        return self.source[token.start..token.end];
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
        self.evalExpr(value_idx);
    }

    fn analyzeCompare(self: *DiaIR, node: Node) void {
        const children = node.data.node_and_node;
        self.evalExpr(children.@"0");
        self.evalExpr(children.@"1");
    }

    fn evalExpr(self: *DiaIR, node_idx: NodeIndex) void {
        const node = self.ast.nodes.get(node_idx);
        const token_pos = node.token_pos;
        switch (node.tag) {
            .number => {
                const text = self.identName(token_pos);
                const num = std.fmt.parseInt(u8, text, 10) catch unreachable;

                self.instructions.appendAssumeCapacity(.{
                    .tag = .constant,
                    .data = .{ .uint = num }
                });
            },
            .var_ident => {
                const mutability = self.ast.tokens.get(token_pos);
                const tag = if (mutability.tag == .keyword_const)
                    .constant else .var_decl;

                self.instructions.appendAssumeCapacity(.{
                    .tag = tag,
                    .data = .{ .token_pos = token_pos }
                });
            },
            else => {},
        }
    }
};


// TODO: Move this into code optimization phase.
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
