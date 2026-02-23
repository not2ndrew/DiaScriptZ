const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const diagnostic = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;

const NodeIndex = zig_node.NodeIndex;
const TokenIndex = tok.TokenIndex;

const Token = tok.Token;
const Tag = tok.Tag;

const Node = zig_node.Node;
const NodeData = zig_node.NodeData;
const ChoiceList = zig_node.ChoiceList;
const invalid_node = zig_node.invalid_node;

const DiagnosticSink = diagnostic.DiagnosticSink;
const DiagnosticError = diagnostic.DiagnosticError;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);
const NodeList = std.ArrayList(NodeIndex);

const MAX_NUM_CHOICES = 4;

const Error = Allocator.Error;

pub const Symbol = struct {
    token_pos: TokenIndex,
    is_const: bool,
};

pub const Semantic = struct {
    diag_sink: *DiagnosticSink,
    stmts: []const NodeIndex,
    nodes: *const Nodes,
    tokens: *const Tokens,

    symbols: std.StringArrayHashMap(Symbol),

    pub fn init(
        diag_sink: *DiagnosticSink, stmts: []const NodeIndex,
        nodes: *const Nodes, tokens: *const Tokens
    ) Semantic {
        return .{
            .diag_sink = diag_sink,
            .stmts = stmts,
            .nodes = nodes,
            .tokens = tokens,
            .symbols = std.StringArrayHashMap(Symbol).init(diag_sink.allocator)
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.symbols.deinit();
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
            // .label => try self.storeLabel(node),
            else => {},
        }
    }

    fn storeDeclar(self: *Semantic, node: Node) !void {
        const ident_pos = node.data.decl.name;
        const ident_node = self.nodes.get(ident_pos);
        const name = self.getNameFromNode(ident_node);

        const decl = self.getNameFromNode(node);
        const is_const = std.mem.eql(u8, decl, "const");

        std.debug.print("Name: {s}\n", .{name});
        std.debug.print("decl type: {s}\n", .{decl});

        if (self.symbols.contains(name)) {
            try self.report(.duplicate_var, ident_pos);
            return;
        }

        try self.symbols.put(name, .{
            .token_pos = ident_node.token_pos,
            .is_const = is_const,
        });
    }

    fn storeLabel(self: *Semantic, node: Node) !void {
        const name = self.getNameFromNode(node);

        std.debug.print("Name: {s}\n", .{name});

        // Suggestion: Instead of creating two separate lists
        // for dialogue var and regular var, join them together
        // and use union(enum) to determine the type.
        if (self.symbols.contains(name)) {
            // TODO: Replace invalid_node with node index
            try self.report(.duplicate_var_dialogue, invalid_node);
            return;
        }
    }
    // ───────────────────────────────
    //             PASS 2
    // ───────────────────────────────
};
