const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const ast = @import("ast.zig");

const Allocator = std.mem.Allocator;

const Token = tok.Token;
const Tokens = std.MultiArrayList(Token);
const TokenIndex = tok.TokenIndex;

const Node = zig_node.Node;
const Nodes = std.MultiArrayList(Node);
const NodeIndex = zig_node.NodeIndex;
const Tag = zig_node.NodeTag;
const invalid_node = zig_node.invalid_node;

const AstError = ast.Error;
const ErrorTag = ast.Error.Tag;

const SymbolTable = std.array_hash_map.String(Symbol);
const UnresolvedLabels = std.ArrayList(TokenIndex);

pub const Symbol = struct {
    token_pos: TokenIndex,
    kind: Kind,

    pub const Kind = enum {
        keyword_const,
        keyword_var,
        label,
        name,
    };
};

pub const SemanticError = error {
    OutOfMemory,
    NoTableCreated,
};

const Error = SemanticError || Allocator.Error;

// Program variables and label variables are handled differently.
// Program variables must be declared first before using it.
// Label variables must contain a label block in the same scope.
pub const Semantic = struct {
    allocator: Allocator,
    source: []const u8,
    nodes: Nodes.Slice,
    tokens: Tokens.Slice,
    extra_data: []u32,
    errors: *std.ArrayList(AstError),

    tables: std.ArrayList(SymbolTable),
    unresolved_labels: UnresolvedLabels,

    pub fn init(
        allocator: Allocator, source: []const u8, 
        nodes: Nodes.Slice, tokens: Tokens.Slice,
        extra_data: []u32, errors: *std.ArrayList(AstError),
    ) Semantic {
        return .{
            .allocator = allocator,
            .source = source,
            .nodes = nodes,
            .tokens = tokens,
            .extra_data = extra_data,
            .errors = errors,
            .tables = std.ArrayList(SymbolTable).empty,
            .unresolved_labels = UnresolvedLabels.empty,
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.tables.deinit(self.allocator);
        self.unresolved_labels.deinit(self.allocator);
    }

    // Semantic analysis has different types of errors.
    fn report(self: *Semantic, token_pos: TokenIndex, tag: ErrorTag) !void {
        try self.errors.append(self.allocator, .{
            .token_pos = token_pos,
            .tag = tag,
            .extra = .{ .none = {} },
        });
    }

    fn identName(self: *Semantic, token_pos: TokenIndex) []const u8 {
        const token = self.tokens.get(token_pos);
        return self.source[token.start..token.end];
    }

    fn addScope(self: *Semantic) Error!void {
        try self.tables.append(self.allocator, .empty);
    }

    fn endScope(self: *Semantic) Error!void {
        if (self.tables.items.len == 0) return Error.NoTableCreated;

        const table = try self.currentScope();

        var i: usize = 0;
        while (i < self.unresolved_labels.items.len) {
            const token_pos = self.unresolved_labels.items[i];
            const name = self.identName(token_pos);

            if (table.contains(name)) {
                _ = self.unresolved_labels.orderedRemove(i);
            } else {
                try self.report(token_pos, .undeclared_label);
                i += 1;
            }
        }

        table.deinit(self.allocator);
        _ = self.tables.pop();
    }

    // Scan backwards (inner -> outer)
    fn lookUp(self: *Semantic, name: []const u8) ?*Symbol {
        var i: usize = self.tables.items.len;

        while (i > 0) {
            i -= 1;
            const table = &self.tables.items[i];
            if (table.getPtr(name)) |symbol| {
                return symbol;
            }
        }

        return null;
    }

    fn currentScope(self: *Semantic) Error!*SymbolTable {
        if (self.tables.items.len == 0) return Error.NoTableCreated;

        return &self.tables.items[self.tables.items.len - 1];
    }

    fn analyzeIdent(self: *Semantic, tag: Tag, token_pos: TokenIndex) !void {
        const name = self.identName(token_pos);

        if (self.lookUp(name)) |symbol| {
            const kind = symbol.kind;
            switch (tag) {
                .var_ident => {
                    if (kind != .keyword_var and kind != .keyword_const) {
                        try self.report(token_pos, .ident_mismatch);
                    }
                },
                .label_ident => {
                    if (kind != .label) {
                        try self.report(token_pos, .ident_mismatch);
                    }
                },
                else => {},
            }
        } else {
            switch (tag) {
                .number => {
                    _ = std.fmt.parseInt(u8, name, 10) catch |err| {
                        if (err == std.fmt.ParseIntError.Overflow)
                            try self.report(token_pos, .int_overflow);
                    };
                },
                .var_ident => try self.report(token_pos, .undeclared_var),
                .label_ident => {
                    try self.unresolved_labels.append(self.allocator, token_pos);
                },
                else => {},
            }
        }
    }

    fn analyzeValue(self: *Semantic, node_index: NodeIndex) Error!void {
        const node = self.nodes.get(node_index);

        switch (node.tag) {
            .plus, .minus, .mult, .div => {
                const binary = node.data.node_and_node;
                try self.analyzeValue(binary.@"0");
                try self.analyzeValue(binary.@"1");
            },
            .plus_equal, .minus_equal,
            .mult_equal, .div_equal => {
                const assign = node.data.node_and_node;
                try self.analyzeValue(assign.@"1");
            },
            else => try self.analyzeIdent(node.tag, node.token_pos),
        }
    }

    // The last node of a post-traversal list
    // is the root node.
    pub fn analyze(self: *Semantic) Error!void {
        const root_node = self.nodes.get(self.nodes.len - 1);
        const range = root_node.data.range;
        try self.analyzeBlock(range.start, range.len);
    }

    fn analyzeBlock(self: *Semantic, start: u32, len: u32) Error!void {
        const end = start + len;
        try self.addScope();
        for (start..end) |idx| {
            const node_index = self.extra_data[idx];
            try self.analyzeStmt(node_index);
        }
        try self.endScope();
    }

    fn analyzeStmt(self: *Semantic, node_index: NodeIndex) Error!void {
        const node = self.nodes.get(node_index);
        try switch (node.tag) {
            // Collect declarations
            .declar_stmt => self.analyzeDeclar(node),
            .label => self.analyzeLabel(node),

            // Analyze stmts
            .assign, .plus_equal, .minus_equal,
            .mult_equal, .div_equal => self.analyzeAssign(node),
            .equals, .not_equal, .less, .greater,
            .less_or_equal, .greater_or_equal => self.analyzeCompare(node),
            .if_stmt => self.analyzeIfStmt(node),
            .dialogue, .choice => self.analyzeDialogue(node),
            else => {},
        };
    }

    // TODO: The following should fail.
    // const i = i
    fn analyzeDeclar(self: *Semantic, node: Node) Error!void {
        const decl = node.data.node_and_node;
        const ident_index = decl.@"0";
        const value_index = decl.@"1";

        const ident_node = self.nodes.get(ident_index);
        const id_token_pos = ident_node.token_pos;
        const name = self.identName(id_token_pos);

        const mut_type = self.tokens.get(node.token_pos).tag;
        const mutability: Symbol.Kind = if (mut_type == .keyword_const)
            .keyword_const else .keyword_var;

        const table = try self.currentScope();
        const entry = try table.getOrPut(self.allocator, name);

        if (entry.found_existing) {
            return switch (entry.value_ptr.kind) {
                .keyword_var, .keyword_const => {
                    try self.report(id_token_pos, .duplicate_var);
                },
                else => try self.report(id_token_pos, .ident_mismatch),
            };
        }

        entry.value_ptr.* = .{
            .token_pos = id_token_pos,
            .kind = mutability,
        };

        try self.analyzeValue(value_index);
    }

    fn analyzeLabel(self: *Semantic, node: Node) Error!void {
        const token_pos = node.token_pos;
        const name = self.identName(token_pos);
        const table = try self.currentScope();
        const entry = try table.getOrPut(self.allocator, name);

        if (entry.found_existing) {
            return switch (entry.value_ptr.kind) {
                .label => try self.report(token_pos, .duplicate_label),
                else => try self.report(token_pos, .ident_mismatch),
            };
        }

        const range = node.data.range;
        try self.analyzeBlock(range.start, range.len);

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
                else => try self.report(token_pos, .ident_mismatch),
            };
        }

        entry.value_ptr.* = .{
            .token_pos = token_pos,
            .kind = .name,
        };
    }

    fn analyzeAssign(self: *Semantic, node: Node) Error!void {
        const assign = node.data.node_and_node;
        const ident_index = assign.@"0";
        const value_index = assign.@"1";

        const ident_node = self.nodes.get(ident_index);
        const id_token_pos = ident_node.token_pos;

        try self.analyzeValue(value_index);

        const ident_name = self.identName(id_token_pos);

        if (self.lookUp(ident_name)) |symbol| {
            return switch (symbol.kind) {
                .label, .name => try self.report(id_token_pos, .ident_mismatch),
                .keyword_const => try self.report(id_token_pos, .modified_const),
                else => {},
            };
        } else {
            try self.report(id_token_pos, .undeclared_var);
        }
    }

    // In the parser, if_stmt is stored as follows:
    // [ cond, then_block, else_block ]
    fn analyzeIfStmt(self: *Semantic, node: Node) Error!void {
        const range = node.data.range;
        const start = range.start;
        const end = start + range.len;

        try self.addScope();

        for (start..end) |idx| {
            const node_index = self.extra_data[idx];
            if (node_index != invalid_node) {
                try self.analyzeStmt(node_index);
            }
        }

        try self.endScope();
    }

    fn analyzeCompare(self: *Semantic, node: Node) Error!void {
        const binary = node.data.node_and_node;
        const left_node = self.nodes.get(binary.@"0");
        const right_node = self.nodes.get(binary.@"1");

        try self.analyzeIdent(left_node.tag, left_node.token_pos);
        try self.analyzeIdent(right_node.tag, right_node.token_pos);
    }

    // From the dialogue format in Parser, the first and last element
    // is always the speaker and goto index respectively.
    // [ speaker, dia_part_1, dia_part_2, ..., goto ]
    fn analyzeDialogue(self: *Semantic, node: Node) Error!void {
        const dialogue = node.data.range;
        const start = dialogue.start;
        const end = start + dialogue.len;
        const new_start = start + 1;
        const goto = end - 1;

        const speaker = self.extra_data[start];
        if (speaker != invalid_node) {
            const ident_node = self.nodes.get(speaker);
            try self.analyzeName(ident_node);
        }

        for (new_start..goto) |i| {
            const dia_pos = self.extra_data[i];
            const dia_node = self.nodes.get(dia_pos);
            try self.analyzeIdent(dia_node.tag, dia_node.token_pos);
        }

        const goto_pos = self.extra_data[goto];
        if (goto_pos != invalid_node) {
            const ident_node = self.nodes.get(goto_pos);
            try self.analyzeIdent(ident_node.tag, ident_node.token_pos);
        }
    }
};
