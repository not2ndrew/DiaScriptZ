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

pub const SymbolID = u32;
const SymbolTable = std.array_hash_map.String(SymbolID);

// TODO: Debating on whether I should include
// token_pos in Local struct.
pub const Local = struct {
    scope: u32,
    kind: Kind,
    state: State,

    pub const Kind = enum {
        keyword_const,
        keyword_var,
        label,
        name,
    };

    pub const State = enum {
        declaring,
        defined,
    };
};

// Program variables and label variables are handled differently.
// Program variables must be declared first before using it.
// Label variables must contain a label block in the same scope.
//
// Global variable identifiers are never allowed to shadow identifiers from an outer scope
// Ex:
// const num = 10
//
// ~ some_label
//    // Compiler Error: Duplicate variable.
//    const num = 1
// end
pub const Semantic = struct {
    allocator: Allocator,
    source: []const u8,
    ast: *Ast,
    errors: *std.ArrayList(AstError),

    table: SymbolTable,
    // https://www.reddit.com/r/Compilers/comments/rzbfs0/what_is_the_purpose_of_symbol_tables_what_are/
    // Read Nuoji's comment under "onlyonequickquest" post
    locals: std.ArrayList(Local),
    scope_depth: u32,

    pub fn deinit(self: *Semantic) void {
        self.table.deinit(self.allocator);
        self.locals.deinit(self.allocator);
    }

    // Semantic analysis has different types of errors.
    fn report(self: *Semantic, token_pos: TokenIndex, tag: ErrorTag) !void {
        try self.errors.append(self.allocator, .{
            .token_pos = token_pos,
            .tag = tag,
            .extra = .{ .none = {} },
        });
    }

    fn tokenSlice(self: *Semantic, token_pos: TokenIndex) []const u8 {
        const token = self.ast.tokens.get(token_pos);
        return self.source[token.start..token.end];
    }

    fn addLocal(self: *Semantic, local: Local) !void {
        try self.locals.append(self.allocator, local);
        self.scope_depth = local.scope;
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
            .table = .empty,
            .locals = .empty,
            .scope_depth = 0,
        };
        defer semantic.deinit();

        const root_node = ast.nodes.get(ast.nodes.len - 1);
        const range = root_node.data.range;
        try semantic.visitBlock(range.start, range.len);
    }

    fn visitBlock(self: *Semantic, start: u32, len: u32) !void {
        const end = start + len;
        for (start..end) |idx| {
            const node_index = self.ast.extra_data[idx];
            try self.visitStmt(node_index);
        }
    }

    fn visitStmt(self: *Semantic, node_idx: NodeIndex) !void {
        const node = self.ast.nodes.get(node_idx);
        return switch (node.tag) {
            .declar_stmt => self.visitVarDecl(node),
            .plus_equal, .minus_equal, .mult_equal, .div_equal
                => self.visitAssign(node),
            else => self.report(node.token_pos, .unexpected_token),
        };
    }

    fn visitVarDecl(self: *Semantic, node: Node) !void {
        const decl = node.data.node_and_node;
        const ident_node = self.ast.nodes.get(decl.@"0");
        const pos = ident_node.token_pos;

        const mut_type = self.ast.tokens.get(node.token_pos).tag;
        var mutability: Local.Kind = .keyword_var;

        if (mut_type == .keyword_const)
            mutability = .keyword_const;

        const name = self.tokenSlice(pos);
        const idx = self.locals.items.len;

        try self.addLocal(.{
            .scope = self.scope_depth,
            .kind = mutability,
            .state = .declaring,
        });

        const entity = try self.table.getOrPut(self.allocator, name);
        if (entity.found_existing) {
            return switch (node.tag) {
                .name_ident, .label_ident => self.report(pos, .ident_mismatch),
                .var_ident => self.report(pos, .duplicate_var),
                else => self.report(pos, .unexpected_token),
            };
        }

        entity.value_ptr.* = @intCast(idx);

        try self.visitExpr(decl.@"1");

        self.locals.items[idx].state = .defined;
    }

    fn visitAssign(self: *Semantic, node: Node) !void {
        const assign = node.data.node_and_node;
        const ident_node = self.ast.nodes.get(assign.@"0");
        const pos = ident_node.token_pos;
        const ident_name = self.tokenSlice(pos);

        const idx = self.table.get(ident_name) orelse
            return self.report(pos, .undeclared_var);

        switch (ident_node.tag) {
            .var_ident => {
                const local = self.locals.items[idx];
                if (local.kind == .keyword_const)
                    return self.report(pos, .modified_const);
            },
            .name_ident, .label_ident => return self.report(pos, .ident_mismatch),
            else => return self.report(pos, .unexpected_token),
        }

        try self.visitExpr(assign.@"1");
    }

    fn visitExpr(self: *Semantic, node_idx: NodeIndex) !void {
        const node = self.ast.nodes.get(node_idx);
        const token_pos = node.token_pos;
        switch (node.tag) {
            .number => {},
            .var_ident => {
                const name = self.tokenSlice(token_pos);
                const idx = self.table.get(name) orelse
                    return self.report(token_pos, .undeclared_var);

                const sym = &self.locals.items[idx];

                if (sym.state == .declaring)
                    return self.report(token_pos, .undeclared_var);
            },
            .plus, .minus, .mult, .div => {
                const binary = node.data.node_and_node;
                const lhs = binary.@"0";
                const rhs = binary.@"1";

                try self.visitExpr(lhs);
                try self.visitExpr(rhs);
            },
            else => try self.report(token_pos, .unexpected_token),
        }
    }
};
