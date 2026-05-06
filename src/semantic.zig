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

const SymbolTable = std.array_hash_map.String(Symbol);

pub const Symbol = struct {
    token_pos: TokenIndex,
    kind: Kind,

    pub const Kind = enum {
        keyword_const,
        keyword_var,
        label,
        name,
        none,
    };
};

pub const SemanticError = error {
    OutOfMemory,
    NoTableCreated,
};

const Error = SemanticError || Allocator.Error;

pub const Semantic = struct {
    allocator: Allocator,
    source: []const u8,
    nodes: Nodes.Slice,
    tokens: Tokens.Slice,
    errors: *Diagnostics,

    symbols: std.ArrayList(SymbolTable),

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
            .symbols = std.ArrayList(SymbolTable).empty,
        };
    }

    pub fn deinit(self: *Semantic) void {
        const len = self.symbols.items.len;
        for (0..len) |i| {
            const table = &self.symbols.items[len - 1 - i];
            table.deinit(self.allocator);
        }
        self.symbols.deinit(self.allocator);
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

    fn addScope(self: *Semantic) Error!void {
        try self.symbols.append(self.allocator, .empty);
    }

    fn endScope(self: *Semantic) Error!void {
        if (self.symbols.items.len == 0) return Error.NoTableCreated;

        const table = &self.symbols.items[self.symbols.items.len - 1];
        table.deinit(self.allocator);
        _ = self.symbols.pop();
    }

    // Scan backwards (inner -> outer)
    fn lookUp(self: *Semantic, name: []const u8) ?*Symbol {
        var i: usize = self.symbols.items.len;

        while (i > 0) {
            i -= 1;
            const table = self.symbols.items[i];
            if (table.getPtr(name)) |symbol| {
                return symbol;
            }
        }

        return null;
    }

    fn currentScope(self: *Semantic) Error!*SymbolTable {
        if (self.symbols.items.len == 0) return Error.NoTableCreated;

        return &self.symbols.items[self.symbols.items.len - 1];
    }

    fn analyzeIdent(self: *Semantic, tag: Tag, token_pos: TokenIndex) !void {
        const name = self.identName(token_pos);

        if (self.lookUp(name)) |symbol| {
            const kind = symbol.kind;
            switch (tag) {
                .number => {
                    _ = std.fmt.parseInt(u8, name, 10) catch {
                        try self.report(.{ .simple = .int_overflow }, token_pos);
                    };
                },
                .var_ident => {
                    if (kind != .keyword_var and kind != .keyword_const) {
                        try self.report(.{ .simple = .ident_mismatch }, token_pos);
                    }
                },
                .label_ident => {
                    if (kind != .label) {
                        try self.report(.{ .simple = .ident_mismatch }, token_pos);
                    }
                },
                else => {},
            }
        } else {
            switch (tag) {
                .var_ident => try self.report(.{ .simple = .undeclared_var }, token_pos),
                .label_ident => try self.report(.{ .simple = .undeclared_label }, token_pos),
                else => {},
            }
        }
    }

    fn analyzeValue(self: *Semantic, node_index: NodeIndex) Error!void {
        const node = self.nodes.get(node_index);

        switch (node.tag) {
            .plus, .minus, .mult, .div => {
                const binary = node.data.binary;
                try self.analyzeValue(binary.lhs);
                try self.analyzeValue(binary.rhs);
            },
            .plus_equal, .minus_equal,
            .mult_equal, .div_equal => {
                const assign = node.data.assign;
                try self.analyzeValue(assign.value);
            },
            else => try self.analyzeIdent(node.tag, node.token_pos),
        }
    }

    // The last node of a post-traversal list
    // is the root node.
    pub fn analyze(self: *Semantic) Error!void {
        try self.symbols.append(self.allocator, SymbolTable.empty);
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
        const id_token_pos = ident_node.token_pos;
        const name = self.identName(id_token_pos);

        const mut_type = self.tokens.get(node.token_pos).tag;
        const mutability: Symbol.Kind = if (mut_type == .keyword_const)
            .keyword_const else .keyword_var;

        try self.analyzeValue(value_index);

        const table = try self.currentScope();
        const entry = try table.getOrPut(self.allocator, name);

        if (entry.found_existing) {
            return switch (entry.value_ptr.kind) {
                .keyword_var, .keyword_const => {
                    try self.report(.{ .simple = .duplicate_var }, id_token_pos);
                },
                else => try self.report(.{ .simple = .ident_mismatch }, id_token_pos),
            };
        }

        entry.value_ptr.* = .{
            .token_pos = id_token_pos,
            .kind = mutability,
        };
    }

    fn analyzeLabel(self: *Semantic, node: Node) Error!void {
        const token_pos = node.token_pos;
        const name = self.identName(token_pos);
        const table = try self.currentScope();
        const entry = try table.getOrPut(self.allocator, name);

        if (entry.found_existing) {
            return switch (entry.value_ptr.kind) {
                .label => try self.report(.{ .simple = .duplicate_label }, token_pos),
                else => try self.report(.{ .simple = .ident_mismatch }, token_pos),
            };
        }

        entry.value_ptr.* = .{
            .token_pos = token_pos,
            .kind = .label,
        };
    }

    fn analyzeName(self: *Semantic, node: Node) Error!void {
        const token_pos = node.token_pos;
        const name = self.identName(token_pos);
        const table = try self.currentScope();
        const entry = try table.getOrPut(self.allocator, name);

        if (entry.found_existing) {
            return switch (entry.value_ptr.kind) {
                .name => {},
                else => try self.report(.{ .simple = .ident_mismatch }, token_pos),
            };
        }

        entry.value_ptr.* = .{
            .token_pos = token_pos,
            .kind = .name,
        };
    }

    fn analyzeAssign(self: *Semantic, node: Node) Error!void {
        const assign = node.data.assign;
        const ident_index = assign.target;
        const value_index = assign.value;

        const ident_node = self.nodes.get(ident_index);
        const id_token_pos = ident_node.token_pos;

        try self.analyzeValue(value_index);

        const ident_name = self.identName(id_token_pos);

        if (self.lookUp(ident_name)) |symbol| {
            return switch (symbol.kind) {
                .label, .name => try self.report(.{ .simple = .ident_mismatch }, id_token_pos),
                .none => try self.report(.{ .simple = .undeclared_var }, id_token_pos),
                .keyword_const => try self.report(.{ .simple = .modified_const }, id_token_pos),
                else => {},
            };
        } else {
            try self.report(.{ .simple = .undeclared_var }, id_token_pos);
        }
    }

    fn analyzeIfStmt(self: *Semantic, node: Node) Error!void {
        const if_stmt = node.data.if_stmt;
        const cond_index = if_stmt.condition;

        const cond_node = self.nodes.get(cond_index);
        try self.analyzeCompare(cond_node);

        const then_block = self.nodes.get(if_stmt.then_block);
        const block = then_block.data.block;

        try self.addScope();
        try self.analyzeBlock(block);
        try self.endScope();
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

        // Every dialogue line must start with a named node
        // followed by the dialogue node itself.
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
