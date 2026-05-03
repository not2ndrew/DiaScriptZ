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
const Tag = zig_node.NodeTag;

const Diagnostic = diagnostic.Diagnostic;
const DiagnosticError = diagnostic.DiagnosticError;
const Diagnostics = std.ArrayList(Diagnostic);

const VarHashMap = std.hash_map.StringHashMap(ProgramSymbol);
const LabelHashMap = std.hash_map.StringHashMap(LabelSymbol);
const NameHashMap = std.hash_map.StringHashMap(void);

pub const Error = error {
    SemanticError,
    OutOfMemory,
};

pub const NameKind = enum {
    vars,
    label,
    name,
    none,
};

pub const ProgramSymbol = struct {
    token_pos: TokenIndex,
    mutability: Mutability,

    pub const Mutability = enum {
        keyword_const,
        keyword_var,
    };
};

pub const LabelSymbol = struct {
    token_pos: TokenIndex,
};

pub const Semantic = struct {
    allocator: Allocator,
    source: []const u8,
    nodes: Nodes.Slice,
    tokens: Tokens.Slice,
    errors: *Diagnostics,

    vars: VarHashMap,
    labels: LabelHashMap,
    names: NameHashMap,

    pub fn init(
        allocator: Allocator, source: []const u8, 
        nodes: Nodes.Slice,
        tokens: Tokens.Slice, errors: *Diagnostics,
    ) Semantic {
        return .{
            .allocator = allocator,
            .source = source,
            .nodes = nodes,
            .tokens = tokens,
            .errors = errors,
            .vars = VarHashMap.init(allocator),
            .labels = LabelHashMap.init(allocator),
            .names = NameHashMap.init(allocator),
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.vars.deinit();
        self.labels.deinit();
        self.names.deinit();
    }

    fn report(self: *Semantic, diag_err: DiagnosticError, token_pos: TokenIndex) !void {
        const token = self.tokens.get(token_pos);

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

    fn lookUpName(self: *Semantic, name: []const u8) NameKind {
        if (self.vars.contains(name)) return .vars;
        if (self.labels.contains(name)) return .label;
        if (self.names.contains(name)) return .name;
        return .none;
    }

    fn checkNameConflict(self: *Semantic, name: []const u8, token_pos: TokenIndex) !void {
        return switch(self.lookUpName(name)) {
            .vars => try self.report(.{ .simple = .duplicate_var }, token_pos),
            .labels => try self.report(.{ .simple = .duplicate_label }, token_pos),
            .name => try self.report(.{ .simple = .ident_mismatch }, token_pos),
            .none => {},
        };
    }

    fn analyzeIdent(self: *Semantic, tag: Tag, token_pos: TokenIndex) !void {
        const name = self.identName(token_pos);

        const has_var = self.vars.contains(name);
        const has_label = self.labels.contains(name);

        switch (tag) {
            .number => {
                _ = std.fmt.parseInt(u8, name, 10) catch {
                    try self.report(.{ .simple = .int_overflow }, token_pos);
                    return;
                };
            },
            .var_ident => {
                if (!has_var) {
                    try self.report(.{ .simple = .undeclared_var }, token_pos);
                    return;
                }

                if (has_label) {
                    try self.report(.{ .simple = .ident_mismatch }, token_pos);
                    return;
                }
            },
            .label_ident => {
                if (!has_label) {
                    try self.report(.{ .simple = .undeclared_label }, token_pos);
                    return;
                }

                if (has_var) {
                    try self.report(.{ .simple = .ident_mismatch }, token_pos);
                    return;
                }
            },
            else => {},
        }
    }

    // The last node of a post-traversal list
    // is the root node.
    pub fn analyze(self: *Semantic) Error!void {
        const root_node = self.nodes.get(self.nodes.len - 1);

        for (root_node.data.block) |stmt_index| {
            try self.analyzeStmt(stmt_index);
        }
    }

    fn analyzeBlock(self: *Semantic, stmts: []NodeIndex) Error!void {
        for (stmts) |stmt_index| {
            try self.analyzeStmt(stmt_index);
        }
    }

    fn analyzeStmt(self: *Semantic, node_index: NodeIndex) Error!void {
        const node = self.nodes.get(node_index);
        switch (node.tag) {
            // Collect declarations
            .declar_stmt => try self.analyzeDeclar(node),
            .label => try self.analyzeLabel(node),

            // Analyze stmts
            .assign, .plus_equal, .minus_equal,
            .mult_equal, .div_equal => try self.analyzeAssign(node),
            .if_stmt => try self.analyzeIfStmt(node),
            .dialogue, .choice => try self.analyzeDialogue(node),
            else => {},
        }
    }

    fn analyzeDeclar(self: *Semantic, node: Node) Error!void {
        const decl = node.data.decl;
        const ident_index = decl.name;
        const value_index = decl.value;

        const ident_node = self.nodes.get(ident_index);
        const token_pos = ident_node.token_pos;
        const name = self.identName(token_pos);

        const value_node = self.nodes.get(value_index);

        const mut_type = self.tokens.get(node.token_pos).tag;
        const mutability: ProgramSymbol.Mutability = if (mut_type == .keyword_const)
            .keyword_const else .keyword_var;

        try self.analyzeIdent(value_node.tag, value_node.token_pos);

        const kind = self.lookUpName(name);

        if (kind != .none) {
            return switch (kind) {
                .vars => try self.report(.{ .simple = .duplicate_var }, token_pos),
                else => try self.report(.{ .simple = .ident_mismatch }, token_pos),
            };
        }

        const entry = try self.vars.getOrPut(name);
        entry.value_ptr.* = .{
            .token_pos = token_pos,
            .mutability = mutability,
        };
    }

    fn analyzeLabel(self: *Semantic, node: Node) Error!void {
        const token_pos = node.token_pos;
        const name = self.identName(token_pos);
        const kind = self.lookUpName(name);

        if (kind != .none) {
            return switch (kind) {
                .label => try self.report(.{ .simple = .duplicate_label }, token_pos),
                else => try self.report(.{ .simple = .ident_mismatch }, token_pos),
            };
        }

        const entry = try self.labels.getOrPut(name);
        entry.value_ptr.* = .{
            .token_pos = token_pos,
        };
    }

    fn analyzeName(self: *Semantic, node: Node) Error!void {
        const token_pos = node.token_pos;
        const name = self.identName(token_pos);
        const kind = self.lookUpName(name);

        if (kind != .none) {
            return switch (kind) {
                .name => {},
                else => try self.report(.{ .simple = .ident_mismatch }, token_pos),
            };
        }

        // Avoid scanning the same name repeatedly
        // by storing into string hashmap.
        try self.names.put(name, {});
    }

    fn analyzeAssign(self: *Semantic, node: Node) Error!void {
        const assign = node.data.assign;
        const ident_index = assign.target;
        const value_index = assign.value;

        const ident_node = self.nodes.get(ident_index);
        const value_node = self.nodes.get(value_index);

        try self.analyzeIdent(value_node.tag, value_node.token_pos);

        // TODO: Simplify this code of block.
        const ident_name = self.identName(ident_node.token_pos);
        const symbol = self.vars.get(ident_name) orelse {
            return try self.report(.{ .simple = .undeclared_var }, ident_node.token_pos);
        };

        if (self.labels.contains(ident_name)) {
            return try self.report(.{ .simple = .ident_mismatch }, ident_node.token_pos);
        }

        if (symbol.mutability == .keyword_const) {
            return try self.report(.{ .simple = .modified_const }, ident_node.token_pos);
        }
    }

    fn analyzeIfStmt(self: *Semantic, node: Node) Error!void {
        const if_stmt = node.data.if_stmt;
        const cond_index = if_stmt.condition;

        const cond_node = self.nodes.get(cond_index);
        try self.analyzeCompare(cond_node);

        const then_block = self.nodes.get(if_stmt.then_block);
        const block = then_block.data.block;

        try self.analyzeBlock(block);
    }

    fn analyzeCompare(self: *Semantic, node: Node) Error!void {
        const binary = node.data.binary;
        const left_node = self.nodes.get(binary.lhs);
        const right_node = self.nodes.get(binary.rhs);

        try self.analyzeIdent(left_node.tag, left_node.token_pos);
        try self.analyzeIdent(right_node.tag, right_node.token_pos);
    }

    fn analyzeDialogue(self: *Semantic, node: Node) Error!void {
        const dialogue = node.data.dialogue;
        const start = dialogue.str.start;
        const len = start + dialogue.str.len;

        const ident = start - 1;
        const ident_node = self.nodes.get(ident);
        try self.analyzeName(ident_node);

        for (start..len) |i| {
            const str_node = self.nodes.get(i);

            try self.analyzeIdent(str_node.tag, str_node.token_pos);
        }

        if (dialogue.branch == .goto) {
            const goto_node = self.nodes.get(dialogue.branch.goto);
            try self.analyzeIdent(goto_node.tag, goto_node.token_pos);
        }
    }
};
