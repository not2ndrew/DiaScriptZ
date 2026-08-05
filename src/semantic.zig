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

const MAX_NUM_SCOPES = 3;
const LocalTable = std.array_hash_map.String(SymbolID);
const LabelTable = std.array_hash_map.String(void);

const binaryOp = *const fn (*Semantic, NodeIndex) anyerror!void;

pub const Local = struct {
    token_pos: TokenIndex,
    kind: Kind,

    pub const Kind = enum {
        keyword_const,
        keyword_var,
        name,
    };
};

// Program variables and jump variables are handled differently.
// Program variables must be declared first before using it.
// Jump variables are forward declarations and must require a label block to connect.
//
// Variable identifiers are never allowed to shadow identifiers from an outer scope
// Label blocks are global blocks.
pub const Semantic = @This();

allocator: Allocator,
source: []const u8,
ast: *Ast,
errors: *std.ArrayList(AstError),

scope_stack: std.ArrayList(u32) = .empty,
local_table: LocalTable = .empty,
label_table: LabelTable = .empty,
locals: std.ArrayList(Local) = .empty,
unresolved_jumps: std.ArrayList(TokenIndex) = .empty,
is_initializing: bool = false,

pub fn deinit(self: *Semantic) void {
    self.scope_stack.deinit(self.allocator);
    self.local_table.deinit(self.allocator);
    self.label_table.deinit(self.allocator);
    self.locals.deinit(self.allocator);
    self.unresolved_jumps.deinit(self.allocator);
}

fn report(self: *Semantic, token_pos: TokenIndex, tag: ErrorTag) !void {
    try self.errors.append(self.allocator, .{
        .token_pos = token_pos,
        .tag = tag,
    });
}

fn addScope(self: *Semantic, token_pos: TokenIndex) !void {
    if (self.scope_stack.items.len >= MAX_NUM_SCOPES) {
        return self.report(token_pos, .too_many_scopes);
    }
    self.scope_stack.appendAssumeCapacity(0);
}

fn endScope(self: *Semantic) void {
    const count = self.scope_stack.pop() orelse return;

    for (0..count) |i| {
        const local = self.locals.items[self.locals.items.len - i - 1];
        const name = self.tokenSlice(local.token_pos);

        _ = self.local_table.swapRemove(name);
    }
}

fn tokenSlice(self: *Semantic, token_pos: TokenIndex) []const u8 {
    const token = self.ast.tokens.get(token_pos);
    return self.source[token.start..token.end];
}

fn addLocal(self: *Semantic, local: Local) !u32 {
    try self.locals.append(self.allocator, local);
    return @intCast(self.locals.items.len - 1);
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
    };
    defer semantic.deinit();

    try semantic.visitRoot();
}

fn visitRoot(self: *Semantic) !void {
    const root_node = self.ast.nodes.get(self.ast.nodes.len - 1);
    const range = root_node.data.range;
    const start = range.start;
    const end = range.start + range.len;

    // Put a limit to how many scopes can be generated
    try self.scope_stack.ensureTotalCapacityPrecise(self.allocator, MAX_NUM_SCOPES);

    for (start..end) |idx| {
        const node_idx = self.ast.extra_data[idx];
        try self.visitStmt(node_idx);
    }

    for (self.unresolved_jumps.items) |token_pos| {
        const name = self.tokenSlice(token_pos);
        self.label_table.get(name) orelse {
            try self.report(token_pos, .unknown_jump);
            continue;
        };

        if (self.local_table.contains(name))
            try self.report(token_pos, .ident_mismatch);
    }
}

fn visitBlock(self: *Semantic, token_pos: TokenIndex, start: u32, len: u32) !void {
    const end = start + len;

    try self.addScope(token_pos);
    for (start..end) |idx| {
        const node_index = self.ast.extra_data[idx];
        try self.visitStmt(node_index);
    }
    self.endScope();
}

fn visitStmt(self: *Semantic, node_idx: NodeIndex) !void {
    const node = self.ast.nodes.get(node_idx);
    return switch (node.tag) {
        .declar_stmt => self.visitVarDecl(node),
        .assign, .plus_equal, .minus_equal, .mult_equal, .div_equal
        => self.visitAssign(node),
        .if_stmt => self.visitIfStmt(node),
        .dialogue => self.visitDialogue(node),
        .label => self.visitLabel(node),
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

    const entity = try self.local_table.getOrPut(self.allocator, name);
    if (entity.found_existing) {
        const found = self.locals.items[entity.value_ptr.*];
        return switch (found.kind) {
            .name => self.report(pos, .ident_mismatch),
            .keyword_var, .keyword_const => self.report(pos, .duplicate_var),
        };
    }

    const idx = try self.addLocal(.{
        .token_pos = pos,
        .kind = mutability,
    });

    self.is_initializing = true;

    entity.value_ptr.* = idx;
    try self.visitExpr(decl.@"1");
    self.is_initializing = false;

    const scope_depth = self.scope_stack.items.len;
    if (scope_depth != 0) {
        self.scope_stack.items[scope_depth - 1] += 1;
    }
}

fn visitAssign(self: *Semantic, node: Node) !void {
    const assign = node.data.node_and_node;
    const ident_node = self.ast.nodes.get(assign.@"0");
    const pos = ident_node.token_pos;
    const ident_name = self.tokenSlice(pos);

    const idx = self.local_table.get(ident_name) orelse
        return self.report(pos, .undeclared_var);

    self.is_initializing = true;
    const local = self.locals.items[idx];

    switch (local.kind) {
        .name => return self.report(pos, .ident_mismatch),
        .keyword_const => return self.report(pos, .modified_const),
        else => {},
    }

    try self.visitExpr(assign.@"1");
    self.is_initializing = false;
}

// if_stmt extra_data layout:
// [ condition, then_block, else_block ]
fn visitIfStmt(self: *Semantic, node: Node) !void {
    const start = node.data.range.start;

    const condition = self.ast.extra_data[start];
    try self.visitCondition(condition);

    const then_idx = self.ast.extra_data[start + 1];
    const then_node = self.ast.nodes.get(then_idx);
    const then_range = then_node.data.range;
    try self.visitBlock(then_node.token_pos, then_range.start, then_range.len);

    const else_idx = self.ast.extra_data[start + 2];
    if (else_idx != invalid_node) {
        const else_block = self.ast.nodes.get(else_idx);
        const else_range = else_block.data.range;
        try self.visitBlock(else_block.token_pos, else_range.start, else_range.len);
    }
}

fn visitCondition(self: *Semantic, node_idx: NodeIndex) !void {
    const node = self.ast.nodes.get(node_idx);
    return switch (node.tag) {
        .bool_and, .bool_or => self.visitBinary(node.data, visitCondition),
        else => self.visitCompare(node_idx),
    };
}

fn visitCompare(self: *Semantic, node_idx: NodeIndex) !void {
    const node = self.ast.nodes.get(node_idx);
    return switch (node.tag) {
        .equal_equal, .not_equal, .less,
        .less_or_equal, .greater,
        .greater_or_equal => self.visitBinary(node.data, visitExpr),
        else => self.report(node.token_pos, .unexpected_token),
    };
}

fn visitBinary(self: *Semantic, data: Node.Data, comptime binOp: binaryOp) !void {
    const binary = data.node_and_node;
    const lhs = binary.@"0";
    const rhs = binary.@"1";

    try binOp(self, lhs);
    try binOp(self, rhs);
}

fn visitExpr(self: *Semantic, node_idx: NodeIndex) !void {
    const node = self.ast.nodes.get(node_idx);
    const token_pos = node.token_pos;
    const name = self.tokenSlice(token_pos);
    switch (node.tag) {
        .number => {
            // Base 10
            _ = std.fmt.parseInt(u8, name, 10) catch |err| {
                if (err == std.fmt.ParseIntError.Overflow)
                    return self.report(token_pos, .int_overflow);
            };
        },
        .var_ident => {
            _ = self.local_table.get(name) orelse
                return self.report(token_pos, .undeclared_var);

            if (self.is_initializing)
                return self.report(token_pos, .undeclared_var);
        },
        // TODO: Check for math errors
        // 1) Integer overflow (0 and 256)
        // 2) Division by 0
        // Create a union field to hold uint.
        .plus, .minus, .mult, .div => try self.visitBinary(node.data, visitExpr),
        else => try self.report(token_pos, .unexpected_token),
    }
}

// ───────────────────────────────
//           DIALOGUE
// ───────────────────────────────

// Dialogue lines and dialogue branches contains
// the same format:
// [ speaker, dia_part_0, dia_part_1, ..., goto ]
fn visitDialogue(self: *Semantic, node: Node) !void {
    const range = node.data.range;
    const start = range.start;
    const speaker_idx = self.ast.extra_data[start];
    const speaker = self.ast.nodes.get(speaker_idx);
    const name = self.tokenSlice(speaker.token_pos);

    const entity = try self.local_table.getOrPut(self.allocator, name);

    if (entity.found_existing) {
        const found = self.locals.items[entity.value_ptr.*];
        switch (found.kind) {
            .name => {},
            .keyword_var, .keyword_const
            => return self.report(speaker.token_pos, .ident_mismatch),
        }
    } else {
        const idx = try self.addLocal(.{
            .token_pos = speaker.token_pos,
            .kind = .name,
        });
        entity.value_ptr.* = idx;
    }

    try self.visitDialogueParts(start, range.len);
}

fn visitDialogueParts(self: *Semantic, start: u32, len: u32) !void {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = self.ast.extra_data[idx];
        try self.visitText(text_idx);
    }

    const jump = self.ast.extra_data[end - 1];
    if (jump != invalid_node) {
        const jump_node = self.ast.nodes.get(jump);
        const token_pos = jump_node.token_pos;
        const jump_name = self.tokenSlice(token_pos);

        if (!self.label_table.contains(jump_name))
            try self.unresolved_jumps.append(self.allocator, token_pos);
    }
}

fn visitText(self: *Semantic, node_idx: NodeIndex) !void {
    const node = self.ast.nodes.get(node_idx);
    return switch (node.tag) {
        .string => {},
        else => self.visitExpr(node_idx),
    };
}

// label extra_data layout:
// [ label_pos, stmt_1, stmt_2, stmt_3, ... , stmt_n ]
fn visitLabel(self: *Semantic, node: Node) !void {
    // First index of a label block is always the label_ident
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    const label_idx = self.ast.extra_data[start];
    const label = self.ast.nodes.get(label_idx);
    const token_pos = label.token_pos;
    const label_name = self.tokenSlice(token_pos);

    const entity = try self.label_table.getOrPut(self.allocator, label_name);
    if (entity.found_existing)
        return self.report(token_pos, .duplicate_label);

    // We have already scanned the first idx.
    // So skip the first idx and reduce len by 1.
    try self.visitBlock(node.token_pos, start + 1, len - 1);
}
