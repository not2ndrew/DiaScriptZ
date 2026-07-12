const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const Ast = @import("ast.zig").Ast;
const diag = @import("diagnostic.zig");

const Allocator = std.mem.Allocator;

const Token = tok.Token;
const Tokens = std.MultiArrayList(Token);
const TokenIndex = tok.TokenIndex;

const Node = zig_node.Node;
const Nodes = std.MultiArrayList(Node);
const NodeIndex = zig_node.NodeIndex;
const Tag = zig_node.NodeTag;
const invalid_node = zig_node.invalid_node;

const AstError = diag.Error;
const ErrorTag = diag.Error.Tag;

const SymbolTable = std.array_hash_map.String(void);

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
    ast: *Ast,
    errors: *std.ArrayList(AstError),

    table: SymbolTable,
    symbols: std.ArrayList(Symbol),

    pub fn init(
        allocator: Allocator, source: []const u8,
        ast: *Ast, errors: *std.ArrayList(AstError)
    ) Semantic {
        return .{
            .allocator = allocator,
            .source = source,
            .ast = ast,
            .errors = errors,
            .table = .empty,
            .symbols = .empty,
        };
    }

    pub fn deinit(self: *Semantic) void {
        self.table.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
    }

    // Semantic analysis has different types of errors.
    fn report(self: *Semantic, token_pos: TokenIndex, tag: ErrorTag) !void {
        try self.errors.append(self.allocator, .{
            .token_pos = token_pos,
            .tag = tag,
            .extra = .{ .none = {} },
        });
    }

    fn tokenPosToStr(self: *Semantic, token_pos: TokenIndex) []const u8 {
        const token = self.ast.tokens.get(token_pos);
        return self.source[token.start..token.end];
    }

    // The last node of a post-traversal list
    // is the root node.
    pub fn analyze(
        allocator: Allocator,
        source: []const u8,
        ast: *Ast,
        errors: *std.ArrayList(AstError)
    ) !void {
        var semantic: Semantic = .{
            .allocator = allocator,
            .source = source,
            .ast = ast,
            .errors = errors,
            .tables = std.ArrayList(SymbolTable).empty,
        };
        defer semantic.deinit();

        const root_node = ast.nodes.get(ast.nodes.len - 1);
        const range = root_node.data.range;
        try semantic.analyzeBlock(range.start, range.len);
    }

    fn analyzeBlock(self: *Semantic, start: u32, len: u32) Error!void {
        const end = start + len;
        try self.addScope();
        for (start..end) |idx| {
            const node_index = self.ast.extra_data[idx];
            try self.analyzeStmt(node_index);
        }
        try self.endScope();
    }

    fn analyzeStmt(self: *Semantic, node_idx: NodeIndex) void {
        const node = self.ast.nodes.get(node_idx);
        switch (node.tag) {
            .declar_stmt => try self.analyzeDecl(node),
            else => {},
        }
    }

    fn analyzeDecl(self: *Semantic, node: Node) !void {
        const decl = node.data.node_and_node;
        const ident_node = self.ast.nodes.get(decl.@"0");
        const value_node = self.ast.nodes.get(decl.@"1");

        const name = self.tokenPosToStr(ident_node.token_pos);

        const entity = try self.table.getOrPut(self.allocator, name);
        if (entity.found_existing) {
            try self.report(ident_node.token_pos, .duplicate_var);
        }
    }

    fn checkExpr(self: *Semantic, node: Node) !void {
        const token_pos = node.token_pos;
        switch (node.tag) {
            .number => {
                const str = self.tokenPosToStr(token_pos);
                // Parse str to u8 in base 10 format
                const num = std.fmt.parseInt(u8, str, 10) catch |err| {
                    if (err == std.fmt.ParseIntError.Overflow) {
                        try self.report(token_pos, .int_overflow);
                    }
                };
            },
            else => try self.report(token_pos, .unexpected_token),
        }
    }
};
