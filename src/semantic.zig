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

const ProgramVarHashMap = std.StringArrayHashMapUnmanaged(ProgramSymbol);
const LabelVarHashMap = std.StringArrayHashMapUnmanaged(LabelSymbol);

// TODO: Create an arraylist Scope
// for variable and label declarations
// https://craftinginterpreters.com/local-variables.html
pub const ProgramSymbol = struct {
    token_pos: TokenIndex,
    depth: u8,
    mutability: Mutability,

    pub const Mutability = enum {
        keyword_const,
        keyword_var,
    };
};

pub const LabelSymbol = struct {
    token_pos: TokenIndex,
    depth: u8,
};

// If you will be accessing more than one field, it's
// better to get the slice of all the fields first, and then
// call 'items' on that. This provides better performance.
// https://www.youtube.com/watch?v=UCvASZT7ELU&t
pub const Semantic = struct {
    allocator: Allocator,
    source: []const u8,
    stmts: []NodeIndex,
    nodes: Nodes.Slice,
    tokens: Tokens.Slice,
    errors: *Diagnostics,

    program_vars: ProgramVarHashMap,
    label_vars: LabelVarHashMap,

    scope_depth: u8,

    pub fn init(
        allocator: Allocator, source: []const u8, 
        stmts: []NodeIndex, nodes: Nodes.Slice,
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
            .label_vars = LabelVarHashMap.empty,
            .scope_depth = 0,
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.program_vars.deinit(self.allocator);
        self.label_vars.deinit(self.allocator);
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

    fn identName(self: *Semantic, token_pos: TokenIndex) []const u8 {
        const token = self.tokens.get(token_pos);
        return self.source[token.start..token.end];
    }

    fn beginScope(self: *Semantic) void {
        self.scope_depth += 1;
    }

    fn endScope(self: *Semantic) void {
        self.scope_depth -= 1;
    }

    fn analyzeExpr(self: *Semantic, node_index: NodeIndex) !void {
        const node = self.nodes.get(node_index);
        switch (node.tag) {
            .number => try self.analyzeNumber(node),
            .identifier => try self.analyzeIdent(node),
            else => unreachable,
        }
    }

    /// By default, the maximum will be u8 (256).
    fn analyzeNumber(self: *Semantic, node: Node) !void {
        const name = self.identName(node.token_pos);

        // 10 is the default base for parseInt.
        _ = std.fmt.parseInt(u8, name, 10) catch {
            try self.report(.{ .simple = .int_overflow }, node);
            return;
        };
    }

    fn analyzeIdent(self: *Semantic, node: Node) !void {
        const value_name = self.identName(node.token_pos);

        if (!self.program_vars.contains(value_name)) {
            try self.report(.{ .simple = .undeclared_var }, node);
            return;
        }

        if (self.label_vars.contains(value_name)) {
            try self.report(.{ .simple = .duplicate_var }, node);
            return;
        }
    }

    pub fn analyze(self: *Semantic) !void {
        for (self.stmts) |stmt_index| {
            const stmt_node = self.nodes.get(stmt_index);
            try self.analyzeStmt(stmt_node);
        }
    }

    fn analyzeStmt(self: *Semantic, node: Node) !void {
        switch (node.tag) {
            // Collect declarations
            .declar_stmt => try self.analyzeDeclar(node),
            .label => try self.analyzeLabel(node),

            // Analyze stmts
            .assign, .plus_equal, .minus_equal,
            .mult_equal, .div_equal => try self.analyzeAssign(node),
            .if_stmt => try self.analyzeIfStmt(node),
            else => {},
        }
    }

    fn analyzeDeclar(self: *Semantic, node: Node) !void {
        const decl = node.data.decl;
        const ident_index = decl.name;
        const value_index = decl.value;

        const ident_node = self.nodes.get(ident_index);
        const name = self.identName(ident_node.token_pos);

        const mut_type = self.tokens.get(node.token_pos).tag;
        var mutability: ProgramSymbol.Mutability = .keyword_var;
        if (mut_type == .keyword_const) mutability = .keyword_const;

        try self.analyzeExpr(value_index);

        const entry = try self.program_vars.getOrPut(self.allocator, name);
        if (entry.found_existing and entry.value_ptr.depth == self.scope_depth) {
            return try self.report(.{ .simple = .duplicate_var }, ident_node);
        }

        entry.value_ptr.* = .{
            .token_pos = ident_node.token_pos,
            .mutability = mutability,
            .depth = self.scope_depth,
        };
    }

    fn analyzeLabel(self: *Semantic, node: Node) !void {
        const name = self.identName(node.token_pos);
        const entry = try self.label_vars.getOrPut(self.allocator, name);

        if (entry.found_existing) {
            try self.report(.{ .simple = .duplicate_label }, node);
        } else {
            entry.value_ptr.* = .{
                .token_pos = node.token_pos,
                .depth = self.scope_depth,
            };
        }

        if (self.program_vars.contains(name)) {
            try self.report(.{ .simple = .duplicate_var }, node);
        }
    }

    fn analyzeAssign(self: *Semantic, node: Node) !void {
        const assign = node.data.assign;
        const ident_index = assign.target;
        const value_index = assign.value;

        const ident_node = self.nodes.get(ident_index);

        try self.analyzeExpr(value_index);

        const ident_name = self.identName(ident_node.token_pos);
        const symbol = self.program_vars.get(ident_name) orelse {
            return try self.report(.{ .simple = .undeclared_var }, ident_node);
        };

        if (self.label_vars.contains(ident_name)) {
            return try self.report(.{ .simple = .duplicate_var }, ident_node);
        }

        if (symbol.mutability == .keyword_const) {
            return try self.report(.{ .simple = .modified_const }, ident_node);
        }
    }

    fn analyzeIfStmt(self: *Semantic, node: Node) !void {
        const if_stmt = node.data.if_stmt;
        const cond_index = if_stmt.condition;

        const cond_node = self.nodes.get(cond_index);
        try self.analyzeCompare(cond_node);

        // TODO: How to connect from then_block to other stmt indexes.
        // Block only stores the start and len of the stmts.
        //
        // const then_block = self.nodes.get(if_stmt.then_block);
        // const block = then_block.data.block;
        //
        // for (block.start..block.len) |stmt_index| {
        //     const lower_level_node = self.nodes.get(stmt_index);
        //     self.analyzeStmt(lower_level_node);
        // }

    }

    fn analyzeCompare(self: *Semantic, node: Node) !void {
        const binary = node.data.binary;

        try self.analyzeExpr(binary.lhs);
        try self.analyzeExpr(binary.rhs);
    }
};
