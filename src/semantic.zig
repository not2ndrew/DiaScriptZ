const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const diagnostic = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;

const NodeIndex = zig_node.NodeIndex;
const TokenIndex = tok.TokenIndex;

const Token = tok.Token;
const Tokens = std.MultiArrayList(Token);

const Node = zig_node.Node;
const Nodes = std.MultiArrayList(Node);

const Diagnostic = diagnostic.Diagnostic;
const DiagnosticError = diagnostic.DiagnosticError;
const Diagnostics = std.ArrayList(Diagnostic);

const MAX_NUM_CHOICES = 4;

const ProgramVarHashMap = std.StringArrayHashMapUnmanaged(ProgramSymbol);
const DialogueVarHashMap = std.StringArrayHashMapUnmanaged(DialogueSymbol);

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

// If you will be accessing more than one field, it's
// better to get the slice of all the fields first, and then
// call 'items' on that. This provides better performance.
// https://www.youtube.com/watch?v=UCvASZT7ELU&t
pub const Semantic = struct {
    allocator: Allocator,
    source: []const u8,
    stmts: Nodes.Slice,
    nodes: Nodes.Slice,
    tokens: Tokens.Slice,
    errors: *Diagnostics,

    program_vars: ProgramVarHashMap,
    dialogue_vars: DialogueVarHashMap,

    pub fn init(
        allocator: Allocator, source: []const u8, 
        stmts: Nodes.Slice, nodes: Nodes.Slice,
        tokens: Tokens.Slice, errors: *Diagnostics,
    ) Semantic {
        return .{
            .allocator = allocator,
            .source = source,
            .stmts = stmts,
            .nodes = nodes,
            .tokens = tokens,
            .errors = errors,
            .program_vars = ProgramVarHashMap.empty,
            .dialogue_vars = DialogueVarHashMap.empty,
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.program_vars.deinit(self.allocator);
        self.dialogue_vars.deinit(self.allocator);
    }

    fn report(self: *Semantic, diag_err: DiagnosticError, node: Node) !void {
        const token = self.tokens.get(node.token_pos);

        try self.errors.append(self.allocator, .{
            .severity = .err,
            .err = diag_err,
            .start = @intCast(token.start),
            .end = @intCast(token.end),
        });
    }

    fn identName(self: *Semantic, node: Node) []const u8 {
        const token = self.tokens.get(node.token_pos);
        return self.source[token.start..token.end];
    }

    fn findProgramVar(self: *Semantic, node_index: NodeIndex) !void {
        const ident_node = self.nodes.get(node_index);
        const node_name = self.identName(ident_node);

        if (!self.program_vars.contains(node_name)) {
            try self.report(.undeclared_var, node_index);
            return;
        }
    }

    fn analyzeExpr(self: *Semantic, node: Node) !void {
        switch (node.tag) {
            .number => try self.analyzeNumber(node),
            .identifier => try self.analyzeIdent(node),
            .string => {},
            else => unreachable,
        }
    }

    /// By default, the maximum will be u8 (256).
    fn analyzeNumber(self: *Semantic, node: Node) !void {
        const name = self.identName(node);

        // 10 is the default base for parseInt.
        _ = std.fmt.parseInt(u8, name, 10) catch {
            try self.report(.{ .simple = .int_overflow }, node);
            return;
        };
    }

    fn analyzeIdent(self: *Semantic, node: Node) !void {
        const value_name = self.identName(node);

        if (!self.program_vars.contains(value_name)) {
            try self.report(.{ .simple = .undeclared_var }, node);
            return;
        }

        if (self.dialogue_vars.contains(value_name)) {
            try self.report(.{ .simple = .duplicate_var }, node);
            return;
        }
    }

    /// The function uses two scan appraoch:
    /// 1) Collecting Declaration Names
    /// 2) Validation analysis.
    pub fn analyze(self: *Semantic) !void {
        // PASS 1: Scan for all declared names
        for (0..self.stmts.len) |i| {
            const stmt_node = self.stmts.get(i);
            try self.collectDeclName(stmt_node);
        }
        // PASS 2: Semantic Analysis
        for (0..self.stmts.len) |i| {
            const stmt_node = self.stmts.get(i);
            try self.analyzeStmt(stmt_node);
        }
    }

    // ───────────────────────────────
    //             PASS 1
    // ───────────────────────────────

    fn collectDeclName(self: *Semantic, node: Node) !void {
        switch (node.tag) {
            .declar_stmt => try self.storeDeclar(node),
            .label => try self.storeLabel(node),
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

        const entry = self.program_vars.getOrPutAssumeCapacity(name);
        if (!entry.found_existing) {
            entry.value_ptr.* = .{
                .token_pos = ident_node.token_pos,
                .mutability = mutability,
            };
        } else {
            try self.report(.{ .simple = .duplicate_var }, ident_node);
        }

    }

    fn storeLabel(self: *Semantic, node: Node) !void {
        const name = self.identName(node);
        const entry = self.dialogue_vars.getOrPutAssumeCapacity(name);

        if (entry.found_existing) {
            try self.report(.{ .simple = .duplicate_dialogue }, node);
        } else {
            entry.value_ptr.* = .{ .token_pos = node.token_pos };
        }

        if (self.program_vars.get(name) != null) {
            try self.report(.{ .simple = .duplicate_var }, node);
        }
    }

    // ───────────────────────────────
    //             PASS 2
    // ───────────────────────────────
    fn analyzeStmt(self: *Semantic, node: Node) !void {
        switch (node.tag) {
            .declar_stmt => try self.analyzeDeclar(node),
            .assign, .plus_equal, .minus_equal,
            .mult_equal, .div_equal => try self.analyzeAssign(node),
            else => {},
        }
    }

    fn analyzeDeclar(self: *Semantic, node: Node) !void {
        const value_index = node.data.decl.value;
        const value_node = self.nodes.get(value_index);
        try self.analyzeExpr(value_node);
    }

    fn analyzeAssign(self: *Semantic, node: Node) !void {
        const assign = node.data.assign;
        const ident_index = assign.target;
        const value_index = assign.value;

        const ident_node = self.nodes.get(ident_index);
        const value_node = self.nodes.get(value_index);
        try self.analyzeIdent(ident_node);
        try self.analyzeExpr(value_node);

        const ident_name = self.identName(ident_node);
        const symbol = self.program_vars.get(ident_name) orelse {
            try self.report(.{ .simple = .undeclared_var }, ident_node);
            return;
        };

        if (symbol.mutability == .keyword_const) {
            try self.report(.{ .simple = .modified_const }, ident_node);
        }
    }
};
