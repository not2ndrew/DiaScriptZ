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

const MAX_NUM_SCOPES = 3;
const LocalTable = std.array_hash_map.String(u32);
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

pub fn deinit(sem: *Semantic) void {
    sem.scope_stack.deinit(sem.allocator);
    sem.local_table.deinit(sem.allocator);
    sem.label_table.deinit(sem.allocator);
    sem.locals.deinit(sem.allocator);
    sem.unresolved_jumps.deinit(sem.allocator);
}

fn report(sem: *Semantic, token_pos: TokenIndex, tag: ErrorTag) !void {
    try sem.errors.append(sem.allocator, .{
        .token_pos = token_pos,
        .tag = tag,
    });
}

fn addScope(sem: *Semantic, token_pos: TokenIndex) !void {
    if (sem.scope_stack.items.len >= MAX_NUM_SCOPES) {
        return sem.report(token_pos, .too_many_scopes);
    }
    sem.scope_stack.appendAssumeCapacity(0);
}

fn endScope(sem: *Semantic) void {
    const count = sem.scope_stack.pop() orelse return;

    for (0..count) |i| {
        const local = sem.locals.items[sem.locals.items.len - i - 1];
        const name = sem.tokenSlice(local.token_pos);

        _ = sem.local_table.swapRemove(name);
    }
}

fn tokenSlice(sem: *Semantic, token_pos: TokenIndex) []const u8 {
    const token = sem.ast.tokens.get(token_pos);
    return sem.source[token.start..token.end];
}

fn addLocal(sem: *Semantic, local: Local) !u32 {
    try sem.locals.append(sem.allocator, local);
    return @intCast(sem.locals.items.len - 1);
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

fn visitRoot(sem: *Semantic) !void {
    const root_node = sem.ast.nodes.get(sem.ast.nodes.len - 1);
    const range = root_node.data.range;
    const start = range.start;
    const end = range.start + range.len;

    // Put a limit to how many scopes can be generated
    try sem.scope_stack.ensureTotalCapacityPrecise(sem.allocator, MAX_NUM_SCOPES);

    for (start..end) |idx| {
        const node_idx = sem.ast.extra_data[idx];
        try sem.visitStmt(node_idx);
    }

    for (sem.unresolved_jumps.items) |token_pos| {
        const name = sem.tokenSlice(token_pos);
        sem.label_table.get(name) orelse {
            try sem.report(token_pos, .unknown_jump);
            continue;
        };

        if (sem.local_table.contains(name))
            try sem.report(token_pos, .ident_mismatch);
    }
}

fn visitBlock(sem: *Semantic, token_pos: TokenIndex, start: u32, len: u32) !void {
    const end = start + len;

    try sem.addScope(token_pos);
    for (start..end) |idx| {
        const node_index = sem.ast.extra_data[idx];
        try sem.visitStmt(node_index);
    }
    sem.endScope();
}

fn visitStmt(sem: *Semantic, node_idx: NodeIndex) !void {
    const node = sem.ast.nodes.get(node_idx);
    return switch (node.tag) {
        .declar_stmt => sem.visitVarDecl(node),
        .assign, .plus_equal, .minus_equal, .mult_equal, .div_equal
        => sem.visitAssign(node),
        .if_stmt => sem.visitIfStmt(node),
        .dialogue => sem.visitDialogue(node),
        .label => sem.visitLabel(node),
        else => sem.report(node.token_pos, .unexpected_token),
    };
}

fn visitVarDecl(sem: *Semantic, node: Node) !void {
    const decl = node.data.node_and_node;
    const ident_node = sem.ast.nodes.get(decl.@"0");
    const pos = ident_node.token_pos;

    const mut_type = sem.ast.tokens.get(node.token_pos).tag;
    var mutability: Local.Kind = .keyword_var;

    if (mut_type == .keyword_const)
        mutability = .keyword_const;

    const name = sem.tokenSlice(pos);

    const entity = try sem.local_table.getOrPut(sem.allocator, name);
    if (entity.found_existing) {
        const found = sem.locals.items[entity.value_ptr.*];
        return switch (found.kind) {
            .name => sem.report(pos, .ident_mismatch),
            .keyword_var, .keyword_const => sem.report(pos, .duplicate_var),
        };
    }

    const idx = try sem.addLocal(.{
        .token_pos = pos,
        .kind = mutability,
    });

    sem.is_initializing = true;

    entity.value_ptr.* = idx;
    try sem.visitExpr(decl.@"1");
    sem.is_initializing = false;

    const scope_depth = sem.scope_stack.items.len;
    if (scope_depth != 0)
        sem.scope_stack.items[scope_depth - 1] += 1;
}

fn visitAssign(sem: *Semantic, node: Node) !void {
    const assign = node.data.node_and_node;
    const ident_node = sem.ast.nodes.get(assign.@"0");
    const pos = ident_node.token_pos;
    const ident_name = sem.tokenSlice(pos);

    const idx = sem.local_table.get(ident_name) orelse
        return sem.report(pos, .undeclared_var);

    sem.is_initializing = true;
    const local = sem.locals.items[idx];

    switch (local.kind) {
        .name => return sem.report(pos, .ident_mismatch),
        .keyword_const => return sem.report(pos, .modified_const),
        else => {},
    }

    try sem.visitExpr(assign.@"1");
    sem.is_initializing = false;
}

// if_stmt extra_data layout:
// [ condition, then_block, else_block ]
fn visitIfStmt(sem: *Semantic, node: Node) !void {
    const start = node.data.range.start;

    const condition = sem.ast.extra_data[start];
    try sem.visitCondition(condition);

    const then_idx = sem.ast.extra_data[start + 1];
    const then_node = sem.ast.nodes.get(then_idx);
    const then_range = then_node.data.range;
    try sem.visitBlock(then_node.token_pos, then_range.start, then_range.len);

    const else_idx = sem.ast.extra_data[start + 2];
    if (else_idx != invalid_node) {
        const else_block = sem.ast.nodes.get(else_idx);
        const else_range = else_block.data.range;
        try sem.visitBlock(else_block.token_pos, else_range.start, else_range.len);
    }
}

fn visitCondition(sem: *Semantic, node_idx: NodeIndex) !void {
    const node = sem.ast.nodes.get(node_idx);
    return switch (node.tag) {
        .bool_and, .bool_or => sem.visitBinary(node.data, visitCondition),
        else => sem.visitCompare(node_idx),
    };
}

fn visitCompare(sem: *Semantic, node_idx: NodeIndex) !void {
    const node = sem.ast.nodes.get(node_idx);
    return switch (node.tag) {
        .equal_equal, .not_equal, .less,
        .less_or_equal, .greater,
        .greater_or_equal => sem.visitBinary(node.data, visitExpr),
        else => sem.report(node.token_pos, .unexpected_token),
    };
}

fn visitBinary(sem: *Semantic, data: Node.Data, comptime binOp: binaryOp) !void {
    const binary = data.node_and_node;
    const lhs = binary.@"0";
    const rhs = binary.@"1";

    try binOp(sem, lhs);
    try binOp(sem, rhs);
}

fn visitExpr(sem: *Semantic, node_idx: NodeIndex) !void {
    const node = sem.ast.nodes.get(node_idx);
    const token_pos = node.token_pos;
    const name = sem.tokenSlice(token_pos);
    switch (node.tag) {
        .number => {
            // Base 10
            _ = std.fmt.parseInt(u8, name, 10) catch |err| {
                if (err == std.fmt.ParseIntError.Overflow)
                    return sem.report(token_pos, .int_overflow);
            };
        },
        .var_ident => {
            _ = sem.local_table.get(name) orelse
                return sem.report(token_pos, .undeclared_var);

            if (sem.is_initializing)
                return sem.report(token_pos, .undeclared_var);
        },
        // TODO: Check for math errors
        // 1) Integer overflow (0 and 256)
        // 2) Division by 0
        // Create a union field to hold uint.
        .plus, .minus, .mult, .div => try sem.visitBinary(node.data, visitExpr),
        else => try sem.report(token_pos, .unexpected_token),
    }
}

// ───────────────────────────────
//           DIALOGUE
// ───────────────────────────────

// Dialogue lines and dialogue branches contains
// the same format:
// [ speaker, dia_part_0, dia_part_1, ..., goto ]
fn visitDialogue(sem: *Semantic, node: Node) !void {
    const range = node.data.range;
    const start = range.start;
    const speaker_idx = sem.ast.extra_data[start];
    const speaker = sem.ast.nodes.get(speaker_idx);
    const name = sem.tokenSlice(speaker.token_pos);

    const entity = try sem.local_table.getOrPut(sem.allocator, name);

    if (entity.found_existing) {
        const found = sem.locals.items[entity.value_ptr.*];
        switch (found.kind) {
            .name => {},
            .keyword_var, .keyword_const
            => return sem.report(speaker.token_pos, .ident_mismatch),
        }
    } else {
        const idx = try sem.addLocal(.{
            .token_pos = speaker.token_pos,
            .kind = .name,
        });
        entity.value_ptr.* = idx;
    }

    try sem.visitDialogueParts(start, range.len);
}

fn visitDialogueParts(sem: *Semantic, start: u32, len: u32) !void {
    const end = start + len;
    for (start + 1..end - 1) |idx| {
        const text_idx = sem.ast.extra_data[idx];
        try sem.visitText(text_idx);
    }

    const jump = sem.ast.extra_data[end - 1];
    if (jump != invalid_node) {
        const jump_node = sem.ast.nodes.get(jump);
        const token_pos = jump_node.token_pos;
        const jump_name = sem.tokenSlice(token_pos);

        if (!sem.label_table.contains(jump_name))
            try sem.unresolved_jumps.append(sem.allocator, token_pos);
    }
}

fn visitText(sem: *Semantic, node_idx: NodeIndex) !void {
    const node = sem.ast.nodes.get(node_idx);
    return switch (node.tag) {
        .string => {},
        else => sem.visitExpr(node_idx),
    };
}

// label extra_data layout:
// [ label_pos, stmt_1, stmt_2, stmt_3, ... , stmt_n ]
fn visitLabel(sem: *Semantic, node: Node) !void {
    // First index of a label block is always the label_ident
    const range = node.data.range;
    const start = range.start;
    const len = range.len;

    const label_idx = sem.ast.extra_data[start];
    const label = sem.ast.nodes.get(label_idx);
    const token_pos = label.token_pos;
    const label_name = sem.tokenSlice(token_pos);

    const entity = try sem.label_table.getOrPut(sem.allocator, label_name);
    if (entity.found_existing)
        return sem.report(token_pos, .duplicate_label);

    // We have already scanned the first idx.
    // So skip the first idx and reduce len by 1.
    try sem.visitBlock(node.token_pos, start + 1, len - 1);
}
