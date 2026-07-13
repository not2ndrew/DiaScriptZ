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
const SymbolTable = std.array_hash_map.String(u32);

pub const Symbol = struct {
    id: SymbolID,
    kind: Kind,
    data: Data,

    pub const Kind = enum {
        keyword_const,
        keyword_var,
        label,
        name,
    };

    pub const Data = union {
        none: void,
        num: u8,
    };
};

// Program variables and label variables are handled differently.
// Program variables must be declared first before using it.
// Label variables must contain a label block in the same scope.
//
// Variable identifiers are never allowed to shadow identifiers from an outer scope
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
    symbols: std.ArrayList(Symbol),
    // https://www.reddit.com/r/Compilers/comments/rzbfs0/what_is_the_purpose_of_symbol_tables_what_are/
    // Read Nuoji's comment under "onlyonequickquest" post
    local_vars: std.ArrayList(u32),

    pub fn deinit(self: *Semantic) void {
        self.table.deinit(self.allocator);
        self.symbols.deinit(self.allocator);
        self.local_vars.deinit(self.allocator);
    }

    // Semantic analysis has different types of errors.
    fn report(self: *Semantic, token_pos: TokenIndex, tag: ErrorTag) !void {
        try self.errors.append(self.allocator, .{
            .token_pos = token_pos,
            .tag = tag,
            .extra = .{ .none = {} },
        });
    }

    fn getSymbolID(self: *Semantic) u32 {
        // Keep track of the variable's index NOT the length
        // TODO: Maybe throw an error?
        if (self.table.count() == 0) return 0;

        const idx: u32 = @intCast(self.table.count() - 1);
        return idx;
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
            .table = .empty,
            .symbols = .empty,
            .local_vars = .empty,
        };
        defer semantic.deinit();

        const root_node = ast.nodes.get(ast.nodes.len - 1);
        const range = root_node.data.range;
        try semantic.analyzeBlock(range.start, range.len);
    }

    fn analyzeBlock(self: *Semantic, start: u32, len: u32) !void {
        const end = start + len;
        for (start..end) |idx| {
            const node_index = self.ast.extra_data[idx];
            try self.analyzeStmt(node_index);
        }
    }

    fn analyzeStmt(self: *Semantic, node_idx: NodeIndex) !void {
        const node = self.ast.nodes.get(node_idx);
        return switch (node.tag) {
            .declar_stmt => self.analyzeDecl(node),
            else => self.report(node.token_pos, .unexpected_token),
        };
    }

    // TODO: Fix self-referencing declaration error
    // const i = i
    fn analyzeDecl(self: *Semantic, node: Node) !void {
        const decl = node.data.node_and_node;
        const ident_node = self.ast.nodes.get(decl.@"0");
        const value_node = self.ast.nodes.get(decl.@"1");
        const pos = ident_node.token_pos;

        const mut_type = self.ast.tokens.get(node.token_pos).tag;
        var mutability: Symbol.Kind = .keyword_var;

        if (mut_type == .keyword_const) {
            mutability = .keyword_const;
        }

        const name = self.tokenPosToStr(pos);

        const entity = try self.table.getOrPut(self.allocator, name);
        if (entity.found_existing) {
            return switch (node.tag) {
                .name_ident, .label_ident => try self.report(pos, .ident_mismatch),
                .var_ident => self.report(pos, .duplicate_var),
                else => self.report(pos, .unexpected_token),
            };
        }

        entity.value_ptr.* = self.getSymbolID();

        try self.checkExpr(value_node, mutability);
    }

    // TODO: Depending on my code, take the node_idx instead of node directly.
    fn checkExpr(self: *Semantic, node: Node, kind: Symbol.Kind) !void {
        const token_pos = node.token_pos;
        switch (node.tag) {
            .number => {
                const str = self.tokenPosToStr(token_pos);
                // Parse str to u8 in base 10 format
                const num = std.fmt.parseInt(u8, str, 10) catch |err| {
                    if (err == error.Overflow) {
                        try self.report(token_pos, .int_overflow);
                    }

                    return err;
                };

                try self.symbols.append(self.allocator, .{
                    .id = self.getSymbolID(),
                    .kind = kind,
                    .data = .{ .num = num },
                });
            },
            .var_ident => {
                try self.symbols.append(self.allocator, .{
                    .id = self.getSymbolID(),
                    .kind = kind,
                    .data = .{ .none = {} },
                });
            },
            else => try self.report(token_pos, .unexpected_token),
        }
    }
};
