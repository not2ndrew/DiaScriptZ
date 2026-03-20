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

const sink = diagnostic.DiagnosticSink;
const DiagnosticError = diagnostic.DiagnosticError;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);

const MAX_NUM_CHOICES = 4;

pub const ProgramSymbol = struct {
    token_pos: TokenIndex,
    mutability: Mutability,

    pub const Mutability = enum {
        keyword_const,
        keyword_var,
    };
};

pub const DialogueSymbol = struct {
    token_pos: TokenIndex,
};

pub const Semantic = struct {
    diag_sink: *sink,
    stmts: []const NodeIndex,
    nodes: *const Nodes,
    tokens: *const Tokens,

    program_vars: std.StringArrayHashMap(ProgramSymbol),
    dialogue_vars: std.StringArrayHashMap(DialogueSymbol),

    pub fn init(
        diag_sink: *sink, stmts: []const NodeIndex,
        nodes: *const Nodes, tokens: *const Tokens
    ) Semantic {
        return .{
            .diag_sink = diag_sink,
            .stmts = stmts,
            .nodes = nodes,
            .tokens = tokens,
            .program_vars = std.StringArrayHashMap(ProgramSymbol).init(diag_sink.allocator),
            .dialogue_vars = std.StringArrayHashMap(DialogueSymbol).init(diag_sink.allocator),
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.program_vars.deinit();
        self.dialogue_vars.deinit();
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

    fn getName(self: *Semantic, node_index: NodeIndex) []const u8 {
        const node = self.nodes.get(node_index);
        return self.identName(node);
    }

    fn identName(self: *Semantic, node: Node) []const u8 {
        const token = self.tokens.get(node.token_pos);
        return self.diag_sink.source[token.start..token.end];
    }

    fn findProgramVar(self: *Semantic, node_index: NodeIndex) !void {
        const ident_node = self.nodes.get(node_index);
        const node_name = self.identName(ident_node);

        if (!self.program_vars.contains(node_name)) {
            try self.report(.undeclared_var, node_index);
            return;
        }
    }

    /// By default, the maximum will be u8 (256).
    fn analyzeNumber(self: *Semantic, node_index: NodeIndex) !void {
        const node = self.nodes.get(node_index);
        const name = self.identName(node);

        // 10 is the default base for parseInt.
        _ = std.fmt.parseInt(u8, name, 10) catch {
            try self.report(.int_overflow, node_index);
            return;
        };
    }

    /// The function uses two scan appraoch:
    /// 1) Collecting Declaration Names
    /// 2) Validation analysis.
    pub fn analyze(self: *Semantic) !void {
        // PASS 1: Scan for all declared names
        for (self.stmts) |node_index| {
            try self.collectDeclName(node_index);
        }

        // PASS 2: Semantic Analysis
        // for (self.stmts) |node_index| {
        //     try self.analyzeStmt(node_index);
        // }
    }

    // ───────────────────────────────
    //             PASS 1
    // ───────────────────────────────
    fn collectDeclName(self: *Semantic, node_index: NodeIndex) !void {
        const node = self.nodes.get(node_index);

        switch (node.tag) {
            .declar_stmt => try self.storeDeclar(node),
            .label => try self.storeLabel(node_index),
            else => {},
        }
    }

    fn storeDeclar(self: *Semantic, node: Node) !void {
        const ident_index = node.data.decl.name;
        const ident_node = self.nodes.get(ident_index);
        const name = self.identName(ident_node);

        const mut_type = self.tokens.get(node.token_pos).tag;
        var mutability: ProgramSymbol.Mutability = .keyword_var;
        if (mut_type == .keyword_const) mutability = .keyword_const;

        const entry = try self.program_vars.getOrPut(name);

        if (entry.found_existing) {
            try self.report(.duplicate_var, ident_index);
            return;
        }

        entry.value_ptr.* = .{
            .token_pos = ident_node.token_pos,
            .mutability = mutability,
        };
    }

    fn storeLabel(self: *Semantic, node_index: NodeIndex) !void {
        const label_node = self.nodes.get(node_index);
        const name = self.identName(label_node);

        if (self.program_vars.contains(name)) {
            try self.report(.duplicate_var, node_index);
            return;
        }

        const entry = try self.dialogue_vars.getOrPut(name);

        if (entry.found_existing) {
            try self.report(.duplicate_dialogue, node_index);
            return;
        }

        entry.value_ptr.* = .{
            .token_pos = label_node.token_pos,
        };
    }

    // ───────────────────────────────
    //             PASS 2
    // ───────────────────────────────
};
