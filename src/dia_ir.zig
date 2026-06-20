const std = @import("std");
const zig_node = @import("node.zig");
const Ast = @import("ast.zig").Ast;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const NodeIndex = zig_node.NodeIndex;
const NodeTag = zig_node.NodeTag;

const Nodes = std.MultiArrayList(Node).Slice;

pub const Inst = struct {
    tag: Tag,
    data: Data,

    pub const Tag = enum {
        plus,
        minus,
        mult,
        div,
    };

    pub const Data = union {
        uint: u8,
        extra_idx: u32,
    };
};


pub const DiaIR = struct {
    instructions: std.ArrayList(Inst),
    extra: std.ArrayList(u32),

    pub fn deinit(self: *DiaIR, allocator: Allocator) void {
        self.instructions.deinit(allocator);
        self.extra.deinit(allocator);
    }

    pub fn generate(allocator: Allocator, nodes: Nodes) !void {
        var diaIR: DiaIR = .{
            .instructions = .empty,
            .extra = .empty,
        };
        defer diaIR.deinit(allocator);

        // We expect as many diaIR instructions and extra data items
        // as nodes.
        try diaIR.instructions.ensureTotalCapacity(allocator, nodes.len);
        try diaIR.extra.ensureTotalCapacity(allocator, nodes.len);
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

// pub fn fold(self: *Ast) void {
//     const root_node = self.nodes.get(self.nodes.len - 1);
//     const range = root_node.data.range;
//     self.analyzeBlock(range.start, range.len);
// }
//
// fn analyzeBlock(self: *Ast, start: u32, len: u32) void {
//     const end = start + len;
//     for (start..end) |idx| {
//         const node_index = self.extra_data[idx];
//         analyzeNode(node_index);
//     }
// }
//
// fn analyzeNode(self: *Ast, node_index: NodeIndex) void {
//     const node = self.nodes.get(node_index);
//     switch (node.tag) {
//         .declare_stmt, .assign,
//         .plus_equal, .minus_equal,
//         .mult_equal, .div_equal => self.analyzeDecl(node),
//         // .equals, .not_equals,
//         // .less, .greater, .less_or_equal,
//         // .greater_or_equal => self.analyzeCompare(node),
//         else => {},
//     }
// }
//
// fn analyzeDecl(self: *Ast, node: Node) void {
//     const value_idx = node.data.node_and_node.@"1";
//     _ = self.evalConst(value_idx);
// }
