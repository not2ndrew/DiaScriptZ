const std = @import("std");
const frontend = @import("frontend");
const inter = @import("interner.zig");
const LowerResult = @import("lower.zig").LowerResult;

const Allocator = std.mem.Allocator;

const Token = frontend.token.Token;
const TokenIndex = frontend.token.TokenIndex;
const Tokens = std.MultiArrayList(Token);

const Node = frontend.node.Node;
const invalid_node = frontend.node.invalid_node;
const NodeIndex = frontend.node.NodeIndex;
const Nodes = std.MultiArrayList(Node);

const Ast = frontend.ast.Ast;
const ParseResult = frontend.ast.ParseResult;

const InternPool = inter.InternPool;
const Interner = inter.Interner;
const IdentId = inter.IdentId;
const Span = inter.Span;

const MAX_NUM_SCOPES = 3;
pub const MAX_NUM_CHOICES = 4;
const SymbolTable = std.array_hash_map.Auto(IdentId, SymbolId);
const LabelTable = std.array_hash_map.Auto(IdentId, void);

const binaryOp = *const fn (*Semantic, NodeIndex) anyerror!void;

pub const SymbolId = u32;
pub const Symbol = struct {
    ident_id: IdentId,
    kind: Kind,

    // TODO: Label is rarely used. It is only there because
    // error diagnostics.
    pub const Kind = enum {
        constant,
        variable,
        speaker,
        label,
    };
};

pub const UnresolvedJump = struct {
    ident_id: IdentId,
    token_pos: TokenIndex,
};

pub const Error = struct {
    token_pos: TokenIndex,
    tag: Tag,
    data: Data = .{ .none = {} },

    pub const Tag = enum {
        // Semantic Errors
        int_overflow,
        // TODO: Create a note to where the ident is used
        // Note: Previous declaration here:
        ident_mismatch,
        duplicate_var,
        duplicate_label,
        undeclared_var,
        unknown_jump,
        modified_const,
        too_many_scopes,
        invalid_label_scope,
        too_many_choices,
    };

    pub const Data = union {
        none: void,
        note: u32,
        initialized: Symbol.Kind,
    };
};

pub const DecoratedAst = struct {
    symbols: []Symbol,
    labels: []IdentId,
    symbol_refs: []SymbolId,
    jumps: []IdentId,
    pool: InternPool,
    errors: []Error,

    pub fn deinit(ast: *DecoratedAst, allocator: Allocator) void {
        allocator.free(ast.symbols);
        allocator.free(ast.labels);
        allocator.free(ast.symbol_refs);
        allocator.free(ast.jumps);
        ast.pool.deinit(allocator);
        allocator.free(ast.errors);
    }
};

pub fn errorMessage(tokens: *std.MultiArrayList(Token).Slice, w: *std.Io.Writer, err: Error) std.Io.Writer.Error!void {
    const slice = tokens.get(err.token_pos);

    switch (err.tag) {
        .int_overflow => {
            return w.writeAll("Integer cannot go beyond 256");
        },
        // TODO: This requires additional note to show where it is already initialized at.
        .ident_mismatch => {
            return w.print("'{s}' is already defined as {s}", .{slice, @tagName(err.data.initialized)});
        },
        .duplicate_var => {
            return w.print("Variable '{s}' already exist", .{slice});
        },
        .undeclared_var => {
            return w.print("Variable '{s}' not declared", .{slice});
        },
        .duplicate_label => {
            return w.print("Label '{s}' already exist", .{slice});
        },
        .unknown_jump => {
            return w.print("Jump target '{s}' does not exist.", .{slice});
        },
        .modified_const => {
            return w.print("Cannot modify constant '{s}'", .{slice});
        },
        .too_many_scopes => {
            return w.writeAll("Cannot generate more than 3 scopes");
        },
        .invalid_label_scope => {
            return w.print("Label '{s}' must be placed in GLOBAL scope", .{slice});
        },
        .too_many_choices => {
            return w.writeAll("Too many choices in a block");
        },
    }
}

// Program variables and jump variables are handled differently.
// Program variables must be declared first before using it.
// Jump variables are forward declarations and must require a label block to connect.
//
// Variable identifiers are never allowed to shadow identifiers from an outer scope
// Label blocks can only be placed in global scope.
pub const Semantic = @This();

allocator: Allocator,
ast: *const Ast,
errors: std.ArrayList(Error) = .empty,

// symbol_table is local hashmap for declaration variables and dialogue speakers.
symbol_table: SymbolTable = .empty,
// label_table is global hashmap for label names.
label_table: LabelTable = .empty,

interner: Interner = .{},

symbols: std.ArrayList(Symbol) = .empty,
labels: std.ArrayList(IdentId) = .empty,

// For any symbol declared, insert a symbolId associated with the symbol.
symbol_refs: std.ArrayList(SymbolId) = .empty,

scope_stack: std.ArrayList(u32) = .empty,
unresolved_jumps: std.ArrayList(UnresolvedJump) = .empty,
resolved_jumps: std.ArrayList(IdentId) = .empty,
initializing_symbol: ?SymbolId = null,

pub fn deinit(sem: *Semantic) void {
    sem.errors.deinit(sem.allocator);
    sem.symbol_table.deinit(sem.allocator);
    sem.label_table.deinit(sem.allocator);
    sem.interner.deinit(sem.allocator);
    sem.symbols.deinit(sem.allocator);
    sem.labels.deinit(sem.allocator);
    sem.symbol_refs.deinit(sem.allocator);
    sem.scope_stack.deinit(sem.allocator);
    sem.unresolved_jumps.deinit(sem.allocator);
    sem.resolved_jumps.deinit(sem.allocator);
}

// TODO: Conversion from Symbol Kind to Error Kind feels
// uncomfortable, this is done because diagnostic.zig should
// NOT be dependent on the import of semantic.zig.
// We can guarantee that it is NOT speaker based on the switch case.
// Therefore, it is either constant or variable.
fn reportSymbolTaken(sem: *Semantic, symbol_id: SymbolId, token_pos: TokenIndex) !void {
    const symbol = sem.symbols.items[symbol_id];
    // const num = @intFromEnum(symbol.kind);
    // const kind: diag.Error.Kind = @enumFromInt(num);
    try sem.errors.append(sem.allocator, .{
        .tag = .ident_mismatch,
        .token_pos = token_pos,
        .data = .{ .initialized = symbol.kind },
    });
}

fn addScope(sem: *Semantic, token_pos: TokenIndex) !void {
    if (sem.scope_stack.items.len >= MAX_NUM_SCOPES) {
        return try sem.errors.append(sem.allocator, .{
            .tag = .too_many_scopes,
            .token_pos = token_pos,
        });
    }

    sem.scope_stack.appendAssumeCapacity(0);
}

fn endScope(sem: *Semantic) void {
    const count = sem.scope_stack.pop() orelse return;

    for (0..count) |i| {
        const symbol = sem.symbols.items[sem.symbols.items.len - i - 1];
        _ = sem.symbol_table.swapRemove(symbol.ident_id);
    }
}

fn addSymbol(sem: *Semantic, symbol: Symbol) !SymbolId {
    const idx: u32 = @intCast(sem.symbols.items.len);
    try sem.symbols.append(sem.allocator, symbol);
    return idx;
}

// The last node of a post-traversal list
// is the root node.
pub fn analyze(allocator: Allocator, ast: *const Ast) !DecoratedAst {
    var sem: Semantic = .{
        .allocator = allocator,
        .ast = ast,
    };
    defer sem.deinit();

    const root_node = ast.nodes.get(ast.nodes.len - 1);
    const range = root_node.data.range;

    // Put a limit to how many scopes can be generated
    try sem.scope_stack.ensureTotalCapacityPrecise(allocator, MAX_NUM_SCOPES);

    try sem.visitStmtList(range.start, range.len);

    try sem.resolved_jumps.ensureTotalCapacityPrecise(sem.allocator, sem.unresolved_jumps.items.len);

    for (sem.unresolved_jumps.items) |jump| {
        const ident_id = jump.ident_id;
        const token_pos = jump.token_pos;
        sem.label_table.get(jump.ident_id) orelse {
            try sem.errors.append(allocator, .{
                .tag = .unknown_jump,
                .token_pos = token_pos,
            });
            continue;
        };

        if (sem.symbol_table.get(ident_id)) |symbol_id| {
            try sem.reportSymbolTaken(symbol_id, token_pos);
            continue;
        }

        sem.resolved_jumps.appendAssumeCapacity(ident_id);
    }

    return .{
        .symbols = try sem.symbols.toOwnedSlice(allocator),
        .labels = try sem.labels.toOwnedSlice(allocator),
        .symbol_refs = try sem.symbol_refs.toOwnedSlice(allocator),
        .jumps = try sem.resolved_jumps.toOwnedSlice(allocator),
        .pool = try sem.interner.finalize(allocator),
        .errors = try sem.errors.toOwnedSlice(allocator),
    };
}

fn visitBlock(sem: *Semantic, token_pos: TokenIndex, start: u32, len: u32) !void {
    try sem.addScope(token_pos);
    try sem.visitStmtList(start, len);
    sem.endScope();
}

fn visitStmtList(sem: *Semantic, start: u32, len: u32) !void {
    const end = start + len;
    var i: u32 = start;
    while (i < end) {
        const node_idx = sem.ast.extra_data[i];
        const node = sem.ast.nodes.get(node_idx);

        if (node.tag != .choice) {
            try sem.visitStmt(node_idx);
            i += 1;
            continue;
        }

        var count: u32 = 0;
        var last_choice_pos: TokenIndex = 0;

        // Handle choice blocks here
        while (i < end) : (i += 1) {
            const choice_idx = sem.ast.extra_data[i];
            const choice_node = sem.ast.nodes.get(choice_idx);

            if (choice_node.tag != .choice)
                break;

            count += 1;
            last_choice_pos = choice_node.token_pos;

            try sem.visitChoice(choice_node);
        }

        if (count > MAX_NUM_CHOICES) {
            try sem.errors.append(sem.allocator, .{
                .tag = .too_many_choices,
                .token_pos = last_choice_pos,
            });
        }
    }
}

fn visitStmt(sem: *Semantic, node_idx: NodeIndex) !void {
    const node = sem.ast.nodes.get(node_idx);
    // Choice is handled in visitStmtList
    return switch (node.tag) {
        .declar_stmt => sem.visitVarDecl(node),
        .assign, .plus_equal, .minus_equal, .mult_equal, .div_equal
        => sem.visitAssign(node),
        .if_stmt => sem.visitIfStmt(node),
        .dialogue => sem.visitDialogue(node),
        .label => sem.visitLabel(node),
        else => unreachable,
    };
}

fn visitVarDecl(sem: *Semantic, node: Node) !void {
    const decl = node.data.node_and_node;
    const ident_node = sem.ast.nodes.get(decl.@"0");
    const pos = ident_node.token_pos;

    const mut_type = sem.ast.tokens.get(node.token_pos).tag;
    var mutability: Symbol.Kind = .variable;

    if (mut_type == .keyword_const)
        mutability = .constant;

    const name = sem.ast.tokenSlice(pos);
    const ident_id = try sem.interner.intern(sem.allocator, name);

    if (sem.label_table.contains(ident_id)) {
        return sem.errors.append(sem.allocator, .{
            .tag = .ident_mismatch,
            .token_pos = pos,
            .data = .{ .initialized = .label }
        });
    }

    const entity = try sem.symbol_table.getOrPut(sem.allocator, ident_id);
    if (entity.found_existing) {
        const found = sem.symbols.items[entity.value_ptr.*];
        return switch (found.kind) {
            .speaker => {
                try sem.errors.append(sem.allocator, .{
                    .tag = .ident_mismatch,
                    .token_pos = pos,
                    .data = .{ .initialized = .speaker }
                });
            },
            .variable, .constant => {
                try sem.errors.append(sem.allocator, .{
                    .tag = .duplicate_var,
                    .token_pos = pos,
                });
            },
            else => unreachable,
        };
    }

    const idx = try sem.addSymbol(.{
        .ident_id = ident_id,
        .kind = mutability,
    });
    entity.value_ptr.* = idx;

    try sem.symbol_refs.append(sem.allocator, idx);

    sem.initializing_symbol = idx;
    defer sem.initializing_symbol = null;

    try sem.visitValue(decl.@"1");

    const scope_depth = sem.scope_stack.items.len;
    if (scope_depth != 0)
        sem.scope_stack.items[scope_depth - 1] += 1;
}

fn visitAssign(sem: *Semantic, node: Node) !void {
    const assign = node.data.node_and_node;
    const ident_node = sem.ast.nodes.get(assign.@"0");
    const pos = ident_node.token_pos;
    const ident_name = sem.ast.tokenSlice(pos);

    const ident_id = try sem.interner.intern(sem.allocator, ident_name);
    const symbol_id = sem.symbol_table.get(ident_id) orelse {
        return sem.errors.append(sem.allocator, .{
            .tag = .undeclared_var,
            .token_pos = pos,
        });
    };

    try sem.symbol_refs.append(sem.allocator, symbol_id);
    const symbol = sem.symbols.items[symbol_id];

    switch (symbol.kind) {
        .speaker => {
            return sem.errors.append(sem.allocator, .{
                .tag = .ident_mismatch,
                .token_pos = pos,
                .data = .{ .initialized = .speaker }
            });
        },
        .constant => {
            return sem.errors.append(sem.allocator, .{
                .tag = .modified_const,
                .token_pos = pos,
            });
        },
        else => {},
    }

    try sem.visitValue(assign.@"1");
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
        .greater_or_equal => sem.visitBinary(node.data, visitValue),
        else => unreachable,
    };
}

fn visitBinary(sem: *Semantic, data: Node.Data, comptime binOp: binaryOp) !void {
    const binary = data.node_and_node;
    const lhs = binary.@"0";
    const rhs = binary.@"1";

    try binOp(sem, lhs);
    try binOp(sem, rhs);
}

fn visitValue(sem: *Semantic, node_idx: NodeIndex) !void {
    const node = sem.ast.nodes.get(node_idx);
    const token_pos = node.token_pos;
    const name = sem.ast.tokenSlice(token_pos);
    const ident_id = try sem.interner.intern(sem.allocator, name);
    switch (node.tag) {
        .number => {
            // Base 10
            _ = std.fmt.parseInt(u8, name, 10) catch |err| {
                if (err == std.fmt.ParseIntError.Overflow) {
                    return sem.errors.append(sem.allocator, .{
                        .tag = .int_overflow,
                        .token_pos = token_pos,
                    });
                }
            };
        },
        .var_ident => {
            const symbol_id = sem.symbol_table.get(ident_id) orelse {
                return sem.errors.append(sem.allocator, .{
                    .tag = .undeclared_var,
                    .token_pos = token_pos,
                });
            };

            if (symbol_id == sem.initializing_symbol) {
                return sem.errors.append(sem.allocator, .{
                    .tag = .undeclared_var,
                    .token_pos = token_pos,
                });
            }

            try sem.symbol_refs.append(sem.allocator, symbol_id);
        },
        .string => {
            const text = sem.ast.tokenSlice(node.token_pos);
            try sem.interner.appendText(sem.allocator, text);
        },
        // TODO: Check for math errors
        // 1) Integer overflow (0 and 256)
        // 2) Division by 0
        // Create a union field to hold uint.
        .plus, .minus, .mult, .div => try sem.visitBinary(node.data, visitValue),
        else => unreachable,
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
    const token_pos = speaker.token_pos;
    const name = sem.ast.tokenSlice(token_pos);

    if (speaker.tag == .anonymous) {
        try sem.visitDialogueParts(start, range.len);
        return;
    }

    const ident_id = try sem.interner.intern(sem.allocator, name);
    if (sem.label_table.contains(ident_id)) {
        return sem.errors.append(sem.allocator, .{
            .tag = .ident_mismatch,
            .token_pos = token_pos,
            .data = .{ .initialized = .label },
        });
    }

    var symbol_id: SymbolId = undefined;

    const entity = try sem.symbol_table.getOrPut(sem.allocator, ident_id);
    if (entity.found_existing) {
        symbol_id = entity.value_ptr.*;
        const found = sem.symbols.items[symbol_id];
        switch (found.kind) {
            .speaker => {},
            else => |symbol_kind| {
                // const num = @intFromEnum(symbol_kind);
                // const kind: diag.Error.Kind = @enumFromInt(num);
                return sem.errors.append(sem.allocator, .{
                    .tag = .ident_mismatch,
                    .token_pos = token_pos,
                    .data = .{ .initialized = symbol_kind },
                });
            }
        }
    } else {
        symbol_id = try sem.addSymbol(.{
            .ident_id = ident_id,
            .kind = .speaker,
        });
        entity.value_ptr.* = symbol_id;
    }

    try sem.symbol_refs.append(sem.allocator, symbol_id);

    try sem.visitDialogueParts(start, range.len);
}

// TODO: Choices can exist by themselves. You can group up choices to a maximum of 4.
fn visitChoice(sem: *Semantic, node: Node) !void {
    const range = node.data.range;
    const start = range.start;

    try sem.visitDialogueParts(start, range.len);
}

fn visitDialogueParts(sem: *Semantic, start: u32, len: u32) !void {
    const end = start + len;
    for (start + 1 .. end - 1) |idx| {
        const text_idx = sem.ast.extra_data[idx];
        try sem.visitValue(text_idx);
    }

    const jump = sem.ast.extra_data[end - 1];
    if (jump != invalid_node) {
        const jump_node = sem.ast.nodes.get(jump);
        const token_pos = jump_node.token_pos;
        const jump_name = sem.ast.tokenSlice(token_pos);
        const ident_id = try sem.interner.intern(sem.allocator, jump_name);

        if (!sem.label_table.contains(ident_id)) {
            return sem.unresolved_jumps.append(sem.allocator, .{
                .ident_id = ident_id,
                .token_pos = token_pos,
            });
        }
    }
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

    const label_name = sem.ast.tokenSlice(token_pos);
    const ident_id = try sem.interner.intern(sem.allocator, label_name);

    if (sem.scope_stack.items.len != 0) {
        return sem.errors.append(sem.allocator, .{
            .tag = .invalid_label_scope,
            .token_pos = token_pos,
        });
    }

    if (sem.symbol_table.get(ident_id)) |symbol_id| {
        return sem.reportSymbolTaken(symbol_id, token_pos);
    }

    const entity = try sem.label_table.getOrPut(sem.allocator, ident_id);
    if (entity.found_existing) {
        return sem.errors.append(sem.allocator, .{
            .tag = .duplicate_label,
            .token_pos = token_pos,
        });
    }

    try sem.labels.append(sem.allocator, ident_id);

    // We have already scanned the first idx.
    // So skip the first idx and reduce len by 1.
    try sem.visitBlock(node.token_pos, start + 1, len - 1);
}
