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
        nop,
        constant,
        load,

        // Store
        // declaration statements such as "const" and "var"
        // are handled in Semantic.
        store,

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

        // We expect as many diaIR instructions and extra as nodes.
        try diaIR.instructions.ensureTotalCapacity(allocator, ast.nodes.len);
        try diaIR.extra.ensureTotalCapacity(allocator, ast.nodes.len);

        var stmts: std.ArrayList(u32) = .empty;
        defer stmts.deinit(allocator);

        // Root node in a post-traversal order is the last node.
        const root_node = ast.nodes.get(ast.nodes.len - 1);
        const range = root_node.data.range;
        diaIR.analyzeBlock(range.start, range.len);

        const start: u32 = @intCast(diaIR.extra.items.len);
        const len: u32 = @intCast(diaIR.stmts.items.len);
        diaIR.extra.appendSliceAssumeCapacity(stmts.items);

        // TODO: load tag should only be used for loading variables.
        diaIR.instructions.appendAssumeCapacity(.{
            .tag = .load,
            .data = .{
                .range = .{ .start = start, .len = len }
            }
        });
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
            
            // Comparison IR
            .equals => self.evalBinary(.eql, node),
            .not_equal => self.evalBinary(.not_eql, node),
            .less => self.evalBinary(.less, node),
            .less_or_equal => self.evalBinary(.less_or_eql, node),
            .greater => self.evalBinary(.greater, node),
            .greater_or_equal => self.evalBinary(.greater_or_eql, node),

            // Dialogue IR
            else => {},
        }
    }

    fn analyzeDecl(self: *DiaIR, node: Node) void {
        const decl = node.data.node_and_node;
        const ident_idx = decl.@"0";
        const value_idx = decl.@"1";

        const ident = self.ast.nodes.get(ident_idx);
        const value = self.evalExpr(value_idx);

        self.instructions.appendAssumeCapacity(.{
            .tag = .store,
            .data = .{
                .binary = .{ ident.token_pos, value }
            }
        });
    }

    fn analyzeCompare(self: *DiaIR, node: Node) void {
        const children = node.data.node_and_node;
        _ = self.evalExpr(children.@"0");
        _ = self.evalExpr(children.@"1");
    }

    fn evalExpr(self: *DiaIR, node_idx: NodeIndex) u32 {
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
                self.instructions.appendAssumeCapacity(.{
                    .tag = .load,
                    .data = .{ .token_pos = token_pos }
                });
            },
            .plus => self.evalBinary(.plus, node),
            .minus => self.evalBinary(.minus, node),
            .mult => self.evalBinary(.mult, node),
            .div => self.evalBinary(.div, node),
            else => {},
        }

        const len: u32 = @intCast(self.instructions.items.len);
        return len;
    }

    fn evalBinary(self: *DiaIR, comptime tag: Inst.Tag, node: Node) void {
        const children = node.data.node_and_node;
        const lhs = self.evalExpr(children.@"0");
        const rhs = self.evalExpr(children.@"1");

        self.instructions.appendAssumeCapacity(.{
            .tag = tag,
            .data = .{ .binary = .{
                .lhs = lhs,
                .rhs = rhs,
            }}
        });
    }
};
