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
const NodeList = std.ArrayList(NodeIndex);

const SemanticError = struct {
    kind: Kind,
    token_pos: TokenIndex,
};

pub const Kind = error {
    // Programming Errors
    int_overflow,
    int_underflow,
    undeclared_var,
    duplicate_var,
    modified_const,
    // Dialogue Errors
    // undeclared dialogue vars
    // dialogue vars and programming vars have same name
    undeclared_dialogue,
    ambiguous_jump,
};

const MAX_NUM_CHOICES = 4;

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
    str_parts: *const std.ArrayList(NodeIndex),
    tokens: *const Tokens,
    symbols: std.StringArrayHashMap(Symbol),
    dia_syms: std.StringArrayHashMap(NodeIndex),

    errors: std.ArrayList(SemanticError),

    stmt_pos: u32 = 0,
    active_dialogue_choices: u32 = 0,
    last_dialogue_stmt: u32 = invalid_node,

    pub fn init(allocator: Allocator, source: []const u8,
                stmt_nodes: []const NodeIndex, nodes: *const Nodes, 
                str_parts: *const NodeList, tokens: *const Tokens) Semantic {
        return .{
            .allocator = allocator,
            .source = source,
            .stmt_nodes = stmt_nodes,
            .nodes = nodes,
            .str_parts = str_parts,
            .tokens = tokens,
            .symbols = std.StringArrayHashMap(Symbol).init(allocator),
            .dia_syms = std.StringArrayHashMap(NodeIndex).init(allocator),
            .errors = .{},
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.symbols.deinit();
        self.dia_syms.deinit();
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

    fn isValidDialogueIdent(self: *Semantic, goto_pos: NodeIndex) Error!void {
        const goto_node = self.nodes.get(goto_pos);
        const name = self.getTokenName(goto_node.token_pos);

        if (self.symbols.contains(name)) {
            try self.report(Kind.duplicate_var, goto_node.token_pos);
        }

        if (!self.dia_syms.contains(name)) {
            try self.report(Kind.undeclared_var, goto_node.token_pos);
        }
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
            Kind.undeclared_dialogue => "use of undeclared dialogue",
            Kind.ambiguous_jump => "cannot have multiple jumps",
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

            std.debug.print(
                \\error: {s}
                \\ --> {s}, line: {d}, col: {d}
                \\     |
                \\{d:4} | {s}
                \\     |
                ,
                .{
                    message,
                    file_name, pos.line, pos.col,
                    pos.line, line_slice
                }
            );
            var i: usize = 0;
            while (i < pos.col) : (i += 1) {
                std.debug.print(" ", .{});
            }

            std.debug.print("^\n\n", .{});
        }
    }

    pub fn analyze(self: *Semantic) Error!void {
        for (self.stmt_nodes, 0..self.stmt_nodes.len) |node_index, i| {
            try self.analyzeNode(node_index);
            self.stmt_pos = @intCast(i);

        }
    }

    fn analyzeNode(self: *Semantic, node_index: NodeIndex) Error!void {
        const node = self.nodes.get(node_index);
        switch (node.tag) {
            .number, .string => {},
            .identifier => try self.analyzeIdent(node),
            .declar_stmt => try self.analyzeDeclar(node),
            .if_stmt => try self.analyzeIfStmt(node),
            .assign, .plus_equal, .minus_equal,
            .mult_equal, .div_equal => try self.analyzeAssign(node),
            .dialogue => try self.analyzeDialogue(node),
            .choice => try self.analyzeChoice(node),
            else => {
                self.active_dialogue_choices = 0;
            },
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
        const ident_node = self.nodes.get(ident_pos);
        const name = self.getTokenName(ident_node.token_pos);
        const value = node.data.decl.value;

        const decl_pos = node.token_pos;
        const decl_type = self.getTokenName(decl_pos);
        const is_const: bool = std.mem.eql(u8, decl_type, "const");

        if (self.symbols.contains(name)) {
            try self.report(Kind.duplicate_var, decl_pos);
            return;
        } 

        try self.symbols.put(name, .{
            .token_pos = ident_pos,
            .is_const = is_const,
        });

        if (value != invalid_node) try self.analyzeNode(value);
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

        try self.analyzeNode(assign.value);
    }

    fn analyzeIfStmt(self: *Semantic, node: Node) Error!void {
        const if_stmt = node.data.if_stmt;
        const compar_pos = if_stmt.condition;

        const compar_node = self.nodes.get(compar_pos);

        // Semantic analyze the nodes inside the compare_node.
        try self.analyzeNode(compar_node.data.binary.lhs);
        try self.analyzeNode(compar_node.data.binary.rhs);

    }

    // DIALOGUES
    fn analyzeDialogue(self: *Semantic, node: Node) Error!void {
        // Each dialogue has the possibility of containing a choice node
        // A dialogue node can own up to 4 choices nodes.
        self.last_dialogue_stmt = self.stmt_pos;
        self.active_dialogue_choices = MAX_NUM_CHOICES;

        const dialogue = node.data.dialogue;

        if (dialogue.branch != .none) {
            try self.isValidDialogueIdent(dialogue.branch.goto);
        }

        // Handle str_parts
        if (dialogue.str.len != 0) {
            const start = dialogue.str.start;

            for (start..start + dialogue.str.len) |i| {
                try self.analyzeNode(self.str_parts.items[i]);
            }
        }
    }

    fn analyzeChoice(self: *Semantic, node: Node) Error!void {
        const dialogue_node = self.nodes.get(
            self.stmt_nodes[self.last_dialogue_stmt]
        );

        if (self.active_dialogue_choices == 0) {
            try self.report(Kind.undeclared_dialogue, node.token_pos);
            return;
        }

        if (node.data.dialogue.branch != .none and
            dialogue_node.data.dialogue.branch != .none) {
            try self.report(Kind.ambiguous_jump, node.token_pos);
            return;
        }

        try self.analyzeNode(node.data.dialogue.branch.goto);
        self.active_dialogue_choices -= 1;
    }
};
