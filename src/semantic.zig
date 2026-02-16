const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");

const Allocator = std.mem.Allocator;

const NodeIndex = zig_node.NodeIndex;
const TokenIndex = tok.TokenIndex;

const Token = tok.Token;
const Tag = tok.Tag;

const Node = zig_node.Node;
const NodeData = zig_node.NodeData;
const ChoiceList = zig_node.ChoiceList;
const invalid_node = zig_node.invalid_node;

const Nodes = std.MultiArrayList(Node);
const Tokens = std.MultiArrayList(Token);

const SemanticError = struct {
    kind: Kind,
    token_pos: TokenIndex,

};

pub const Kind = error {
    int_overflow,
    int_underflow,
    undeclared_var,
    duplicate_var,
    modified_const,
};

const Error = Allocator.Error;

pub const Symbol = struct {
    token_pos: TokenIndex,
    is_const: bool,
};

pub const Semantic = struct {
    allocator: Allocator,
    source: []const u8,
    stmt_nodes: []const NodeIndex,
    nodes: *const Nodes,
    tokens: *const Tokens,
    symbols: std.StringArrayHashMap(Symbol),

    errors: std.ArrayList(SemanticError),

    pub fn init(allocator: Allocator, source: []const u8,
                stmt_nodes: []const NodeIndex, nodes: *const Nodes, tokens: *const Tokens) Semantic {
        return .{
            .allocator = allocator,
            .source = source,
            .stmt_nodes = stmt_nodes,
            .nodes = nodes,
            .tokens = tokens,
            .symbols = std.StringArrayHashMap(Symbol).init(allocator),
            .errors = .{},
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.symbols.deinit();
        self.errors.deinit(self.allocator);
    }

    fn getTokenName(self: *Semantic, token_pos: TokenIndex) []const u8 {
        const token = self.tokens.get(token_pos);
        return self.source[token.start..token.end];
    }

    fn report(self: *Semantic, kind: Kind, token_pos: TokenIndex) !void {
        try self.errors.append(self.allocator, .{
            .kind = kind, .token_pos = token_pos 
        });
    }

    fn getLineCol(self: *Semantic, byte_pos: usize) struct { line: usize, col: usize } {
        var line: usize = 1;
        var col: usize = 1;

        var i: usize = 0;
        while (i < byte_pos and i < self.source.len) {
            if (self.source[i] == '\n') {
                line += 1;
                col = 1;
            } else {
                col += 1;
            }

            i += 1;
        }

        return .{ .line = line, .col = col };
    }

    fn getLineSlice(self: *Semantic, byte_pos: usize) []const u8 {
        var start = byte_pos;
        var end = byte_pos;

        while (start > 0 and self.source[start - 1] != '\n') {
            start -= 1;
        }

        while (end < self.source.len and self.source[end] != '\n') {
            end += 1;
        }

        return self.source[start..end];
    }

    fn printErrorMessage(kind: Kind) []const u8 {
        return switch (kind) {
            Kind.undeclared_var => "use of undeclared variable",
            Kind.duplicate_var => "duplicate variable declaration",
            Kind.modified_const => "cannot modify constant",
            Kind.int_overflow => "integer overflow",
            Kind.int_underflow => "integer underflow",
        };
    }

    /// The format of the printing should look like:
    ///
    /// error: message
    /// --> FILE_NAME : line_num : col_num
    ///      |
    /// line | line_slice
    ///      | ^
    ///
    pub fn printAllSemanticError(self: *Semantic, file_name: []const u8) void {
        for (self.errors.items) |sem_err| {
            const token = self.tokens.get(sem_err.token_pos);

            const pos = self.getLineCol(token.start);
            const line_slice = self.getLineSlice(token.start);
            const message = printErrorMessage(sem_err.kind);

            std.debug.print("error: {s}\n", .{message});
            std.debug.print(
                " --> {s} : {d} : {d}\n",
                .{ file_name, pos.line, pos.col }
            );

            std.debug.print("     |\n", .{});
            std.debug.print("{d:4} | {s}\n", .{pos.line, line_slice});

            // Print caret
            std.debug.print("     | ", .{});
            var i: usize = 1;
            while (i < pos.col) : (i += 1) {
                std.debug.print(" ", .{});
            }
            std.debug.print("^\n\n", .{});
        }
    }

    pub fn analyze(self: *Semantic, idx: NodeIndex) Error!void {
        const node = self.nodes.get(idx);

        switch (node.tag) {
            .number, .string => {},
            .identifier => try self.analyzeIdent(node),
            .declar_stmt => try self.analyzeDeclar(node),
            .if_stmt => try self.analyzeIfStmt(node),
            .assign, .plus_equal, .minus_equal,
            .mult_equal, .div_equal => try self.analyzeAssign(node),
            else => return {},
        }
    }

    fn analyzeIdent(self: *Semantic, node: Node) Error!void {
        const token_pos = node.data.identifier.token;
        const name = self.getTokenName(token_pos);

        if (self.symbols.get(name) == null) {
            try self.report(Kind.undeclared_var, token_pos);
        }
    }

    fn analyzeDeclar(self: *Semantic, node: Node) Error!void {
        const ident_pos = node.data.decl.name;
        const ident_name = self.getTokenName(ident_pos);
        const value = node.data.decl.value;

        const decl_pos = node.token_pos;
        const decl_type = self.getTokenName(decl_pos);
        const is_const: bool = std.mem.eql(u8, decl_type, "const");

        if (self.symbols.contains(ident_name)) {
            try self.report(Kind.duplicate_var, decl_pos);
            return;
        } 

        try self.symbols.put(ident_name, .{
            .token_pos = ident_pos,
            .is_const = is_const,
        });

        if (value != invalid_node) try self.analyze(value);
    }

    fn analyzeAssign(self: *Semantic, node: Node) Error!void {
        const assign = node.data.assign;
        const ident_pos = assign.target;
        const ident_node = self.nodes.get(ident_pos);

        const name = self.getTokenName(ident_node.token_pos);
        const sym = self.symbols.getPtr(name) orelse {
            try self.report(Kind.undeclared_var, ident_node.token_pos);
            return;
        };

        if (sym.is_const) {
            try self.report(Kind.modified_const, ident_node.token_pos);
        }

        _ = try self.analyze(assign.value);
    }

    fn analyzeIfStmt(self: *Semantic, node: Node) Error!void {
        const compar_pos = node.data.if_stmt.condition;
        const compar_node = self.nodes.get(compar_pos);

        // Semantic analyze the nodes inside the compare_node.
        _ = try self.analyze(compar_node.data.binary.lhs);
        _ = try self.analyze(compar_node.data.binary.rhs);
    }
};
