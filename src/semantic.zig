const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const diagnostic = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;

const NodeIndex = zig_node.NodeIndex;
const TokenIndex = tok.TokenIndex;

const Token = tok.Token;

const Node = zig_node.Node;
const invalid_node = zig_node.invalid_node;

const DiagnosticSink = diagnostic.DiagnosticSink;
const DiagnosticError = diagnostic.DiagnosticError;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);

const MAX_NUM_CHOICES = 4;

pub const Symbol = struct {
    token_pos: TokenIndex,
    extra_index: u32,

    const Mutability = enum {
        keyword_const,
        keyword_var,
    };
};

pub const Semantic = struct {
    diag_sink: *DiagnosticSink,
    stmts: []const NodeIndex,
    nodes: *const Nodes,
    tokens: *const Tokens,

    program_vars: std.StringArrayHashMap(Symbol),
    dialogue_vars: std.StringArrayHashMap(Symbol),

    // Mutabilities is a one-to-one relationship with
    // program vars.
    mutabilities: std.ArrayList(Symbol.Mutability),

    pub fn init(
        diag_sink: *DiagnosticSink, stmts: []const NodeIndex,
        nodes: *const Nodes, tokens: *const Tokens
    ) Semantic {
        return .{
            .diag_sink = diag_sink,
            .stmts = stmts,
            .nodes = nodes,
            .tokens = tokens,
            .program_vars = std.StringArrayHashMap(Symbol).init(diag_sink.allocator),
            .dialogue_vars = std.StringArrayHashMap(Symbol).init(diag_sink.allocator),
            .mutabilities = .{},
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.program_vars.deinit();
        self.dialogue_vars.deinit();
        self.mutabilities.deinit(self.diag_sink.allocator);
    }

    fn report(self: *Semantic, diag_err: DiagnosticError, node_index: NodeIndex) !void {
        const node = self.nodes.get(node_index);
        const token = self.tokens.get(node.token_pos);

        try self.diag_sink.report(.{
            .severity = .err,
            .err = diag_err,
            .start = @intCast(token.start),
            .end = @intCast(token.start),
            .node_index = node_index,
        });
    }

    fn getNameFromNode(self: *Semantic, node: Node) []const u8 {
        const token = self.tokens.get(node.token_pos);
        return self.diag_sink.source[token.start..token.end];
    }

    pub fn analyze(self: *Semantic) !void {
        // PASS 1: Scan for all declared names
        for (self.stmts) |i| {
            const node_index: u32 = @intCast(i);
            try self.analyzeName(node_index);
        }

        // PASS 2: Semantic Analysis
        // for (self.stmts) |i| {
        //     const node_index: u32 = @intCast(i);
        //     try self.analyzeStmt(node_index);
        // }
    }

    // ───────────────────────────────
    //             PASS 1
    // ───────────────────────────────
    fn analyzeName(self: *Semantic, node_index: NodeIndex) !void {
        const node = self.nodes.get(node_index);

        switch (node.tag) {
            .declar_stmt => try self.storeDeclar(node),
            .label => try self.storeLabel(node_index),
            else => {},
        }
    }

    fn storeDeclar(self: *Semantic, node: Node) !void {
        const ident_pos = node.data.decl.name;
        const ident_node = self.nodes.get(ident_pos);
        const name = self.getNameFromNode(ident_node);

        const decl = self.getNameFromNode(node);
        const is_const = std.mem.eql(u8, decl, "const");
        var decl_type: Symbol.Mutability = .keyword_var;

        if (self.program_vars.contains(name)) {
            try self.report(.duplicate_var, ident_pos);
            return;
        }

        if (is_const) decl_type = .keyword_const;

        try self.mutabilities.append(self.diag_sink.allocator, decl_type);
        try self.program_vars.putNoClobber(name, .{
            .token_pos = ident_node.token_pos,
            .extra_index = @intCast(self.mutabilities.items.len),
        });
    }

    fn storeLabel(self: *Semantic, node_index: NodeIndex) !void {
        const node = self.nodes.get(node_index);
        const name = self.getNameFromNode(node);

        if (self.program_vars.contains(name)) {
            try self.report(.duplicate_var, node_index);
            return;
        }

        if (self.dialogue_vars.contains(name)) {
            try self.report(.duplicate_dialogue, node_index);
            return;
        }

        // self.dialogue_vars.put(name, .{
        //     .token_pos = node.token_pos,
        //     .extra_index = invalid_node,
        // });

        // TODO: Replace invalid_node with void.
        // No reason to store extra index.
        try self.dialogue_vars.putNoClobber(name, .{
            .token_pos = node.token_pos,
            .extra_index = invalid_node,
        });
    }
    // ───────────────────────────────
    //             PASS 2
    // ───────────────────────────────
};
