const std = @import("std");
const frontend = @import("frontend");
const zig_node = @import("node.zig");
const AstError = @import("diagnostic.zig").Error;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const Tag = zig_node.NodeTag;
const NodeIndex = zig_node.NodeIndex;
const invalid_node = zig_node.invalid_node;

const Token = frontend.Token;
const TokenIndex = frontend.TokenIndex;

const nodeTagFromArithmetic = zig_node.nodeTagFromArithmetic;
const nodeTagFromCompare = zig_node.nodeTagFromCompare;
const nodeTagFromBinary = zig_node.nodeTagFromBinary;

const Tokens = std.MultiArrayList(Token);

const ParserError = error { ParseError };
const Error = ParserError || Allocator.Error;

pub const Parser = @This();

allocator: Allocator,
tokens: std.MultiArrayList(Token).Slice,
nodes: std.MultiArrayList(Node) = .empty,
extra_data: std.ArrayList(u32) = .empty,
errors: std.ArrayList(AstError) = .empty,
token_pos: u32 = 0,

pub fn deinit(p: *Parser) void {
    p.nodes.deinit(p.allocator);
    p.extra_data.deinit(p.allocator);
    p.errors.deinit(p.allocator);
}

fn synchronize(p: *Parser) void {
    // Force the parser to advance to next token_pos.
    p.token_pos += 1;

    while (p.token_pos < p.tokens.len) {
        switch (p.peekTag()) {
            .keyword_const, .keyword_var,
            .keyword_if, .choice_marker,
            .underscore => return,
            .semi_colon => {
                p.token_pos += 1;
                return;
            },
            .EOF => return,
            else => p.token_pos += 1,
        }
    }
}

fn peekToken(p: *Parser) Token {
    return p.tokens.get(p.token_pos);
}

fn peekTag(p: *Parser) Token.Tag {
    return p.tokens.get(p.token_pos).tag;
}

fn next(p: *Parser) void {
    p.token_pos += 1;
}

fn expect(p: *Parser, expected: Token.Tag) Error!TokenIndex {
    const idx = p.token_pos;
    const found = p.peekTag();

    if (found != expected) {
        try p.errors.append(p.allocator, .{
            .tag = .expected_token,
            .token_pos = idx,
            .data = .{ .expected = expected }
        });

        return Error.ParseError;
    }

    p.next();
    return idx;
}

fn addNodeRange(p: *Parser, parts: []const u32) Error!Node.Range {
    const start: u32 = @intCast(p.extra_data.items.len);
    try p.extra_data.appendSlice(p.allocator, parts);

    return .{ .start = start, .len = @intCast(parts.len) };
}


fn addNode(p: *Parser, tag: Tag, token_pos: TokenIndex, data: Node.Data) !NodeIndex {
    try p.nodes.append(p.allocator, .{
        .tag = tag,
        .token_pos = token_pos,
        .data = data,
    });

    const idx: u32 = @intCast(p.nodes.len - 1);
    return idx;
}

// program = { stmt } ;
pub fn parseAll(p: *Parser) Error!void {
    const root_token_pos: u32 = 0;

    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(p.allocator);

    while (p.token_pos < p.tokens.len and p.peekTag() != .EOF) {
        const stmt_index = p.parseStmt() catch {
            p.synchronize();
            continue;
        };

        try stmts.append(p.allocator, stmt_index);
    }

    _ = try p.addNode(.stmt_block, root_token_pos, .{
        .range = try p.addNodeRange(stmts.items),
    });
}


// ───────────────────────────────
//           STATEMENTS
// ───────────────────────────────

// stmt =
//   declar_stmt
// | compound_stmt
// | if_stmt
// | label
// | dialogue
// | choices 
fn parseStmt(p: *Parser) Error!NodeIndex {
    return try switch (p.peekTag()) {
        .keyword_const, .keyword_var => p.parseDeclar(),
        .identifier => p.parseIdentStmt(),
        .keyword_if => p.parseIfStmt(),
        .choice_marker => p.parseChoice(),
        .tilde => p.parseLabel(),
        .underscore => p.parseAnonymousDialogue(),
        else => {
            p.next();
            // TODO: Expected stmt starter.
            try p.errors.append(p.allocator, .{
                .tag = .expected_token,
                .token_pos = p.token_pos,
            });
            return Error.ParseError;
        }
    };
}

// declar_stmt = ( "const" | "var" ) ident "=" expr ;
fn parseDeclar(p: *Parser) Error!NodeIndex {
    const decl_pos = p.token_pos;
    p.next();

    const ident = try p.parseGenericIdent(.var_ident);
    _ = try p.expect(.assign);
    const value = try p.parseExpr();

    _ = try p.expect(.semi_colon);

    return try p.addNode(.declar_stmt, decl_pos, .{
        .node_and_node = .{ ident, value }
    });
}

// Determine which type of stmt it is by searching the next
// token after the identifier.
fn parseIdentStmt(p: *Parser) Error!NodeIndex {
    const is_within = p.token_pos + 1 < p.tokens.len;
    if (is_within and p.tokens.get(p.token_pos + 1).tag == .colon) {
        return try p.parseDialogue();
    }

    const ident_pos = try p.parseGenericIdent(.var_ident);
    const next_tag = p.peekTag();

    return switch (next_tag) {
        .assign, .plus_equal, .minus_equal,
        .asterisk_equal, .slash_equal => p.parseAssignStmt(next_tag, ident_pos),
        else => {
            try p.errors.append(p.allocator, .{
                .token_pos = p.token_pos,
                .tag = .expected_arith_op,
            });
            return Error.ParseError;
        }
    };
}

// compound_stmt = ident ( "=" | "+=" | "-=" | "*=" | "/=" ) expr ;
fn parseAssignStmt(p: *Parser, assign_tag: Token.Tag, ident_pos: NodeIndex) Error!NodeIndex {
    const assign_pos = try p.expect(assign_tag);
    const expr = try p.parseExpr();

    _ = try p.expect(.semi_colon);

    const node_tag = nodeTagFromArithmetic(assign_tag) orelse {
        try p.errors.append(p.allocator, .{
            .token_pos = assign_pos,
            .tag = .expected_arith_op,
        });
        return ParserError.ParseError;
    };

    return try p.addNode(node_tag, assign_pos, .{
        .node_and_node = .{ ident_pos, expr }
    });
}

// if_stmt = "if" "(" condition ")" stmt_block [ else_block ] ;
// else_block = "else" stmt_block ;
fn parseIfStmt(p: *Parser) Error!NodeIndex {
    const if_pos = try p.expect(.keyword_if);

    _ = try p.expect(.open_paren);
    const condition = try p.parseCondition();
    _ = try p.expect(.close_paren);

    const then_block = try p.parseStmtBlock(.open_brace, .close_brace);

    var else_block: u32 = invalid_node;
    if (p.peekTag() == .keyword_else) {
        _ = try p.expect(.keyword_else);
        else_block = try p.parseStmtBlock(.open_brace, .close_brace);
    }

    // if_stmt extra_data layout:
    // [ condition, then_block, else_block ]
    return p.addNode(.if_stmt, if_pos, .{
        .range = try p.addNodeRange(&[_]NodeIndex{ condition, then_block, else_block })
    });
}

// condition  = conjunction { "or" conjunction } ;
fn parseCondition(p: *Parser) Error!NodeIndex {
    var node = try p.parseConjunction();

    while (p.peekTag() == .keyword_or) {
        const op_tok = p.token_pos;
        p.next();

        const rhs = try p.parseConjunction();
        node = try p.addNode(.bool_or, op_tok, .{
            .node_and_node = .{ node, rhs }
        });
    }

    return node;
}

// conjunction = boolean_factor { "and" boolean_factor } ;
fn parseConjunction(p: *Parser) Error!NodeIndex {
    var node = try p.parseBoolFactor();

    while (p.peekTag() == .keyword_and) {
        const op_tok = p.token_pos;
        p.next();

        const rhs = try p.parseBoolFactor();
        node = try p.addNode(.bool_and, op_tok, .{
            .node_and_node = .{ node, rhs }
        });
    }

    return node;
}

// boolean_factor = "(" condition ")" | compar_expr ;
fn parseBoolFactor(p: *Parser) Error!NodeIndex {
    if (p.peekTag() == .open_paren) {
        p.next();
        const node = try p.parseCondition();
        _ = try p.expect(.close_paren);

        return node;
    }

    return try p.parseCompareExpr();
}

// compar_expr = expr compar_op expr ;
// compar_op = "==" | "!=" | "<" | ">" | "<=" | ">=" ;
fn parseCompareExpr(p: *Parser) Error!NodeIndex {
    const left_expr = try p.parseExpr();

    const op_tag = p.peekTag();

    const compare_tag = nodeTagFromCompare(op_tag) orelse {
        try p.errors.append(p.allocator, .{
            .token_pos = p.token_pos,
            .tag = .expected_compar_op,
        });
        return Error.ParseError;
    };

    const compare_token = p.token_pos;
    p.next();

    const right_expr = try p.parseExpr();

    return p.addNode(compare_tag, compare_token, .{
        .node_and_node = .{ left_expr, right_expr }
    });
}

// stmt_block = "{" { stmt } "}" ;
fn parseStmtBlock(p: *Parser, comptime start_tag: Token.Tag, comptime end_tag: Token.Tag) Error!NodeIndex {
    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(p.allocator);

    const block_pos = try p.expect(start_tag);

    return try p.addNode(.stmt_block, block_pos, .{
        .range = try p.collectStmtUntil(end_tag, &stmts),
    });
}

// ───────────────────────────────
//           DIALOGUE
// ───────────────────────────────

// Dialogue lines and dialogue branches contains
// the same format:
// [ speaker, dia_part_0, dia_part_1, ..., goto ]
//
// Both dialogue and anon_dialogue will have a speaker.
// Whereas the speaker for choice is denoted by invalid_node.
//
// goto is either a node index OR invalid_node for all
// dialogue and choices.

// dialogue = ( "_" | identifier ) ":" string ;
fn parseDialogue(p: *Parser) Error!NodeIndex {
    const token_pos = p.token_pos;
    const speaker = try p.parseGenericIdent(.name_ident);
    _ = try p.expect(.colon);

    return p.parseDialogueBody(.dialogue, token_pos, speaker);
}

fn parseAnonymousDialogue(p: *Parser) Error!NodeIndex {
    const token_pos = p.token_pos;
    const speaker = try p.parseAnonymousIdent();
    _ = try p.expect(.colon);

    return p.parseDialogueBody(.dialogue, token_pos, speaker);
}

// choice = { "*" string }
fn parseChoice(p: *Parser) Error!NodeIndex {
    const token_pos = p.token_pos;
    p.next();

    return p.parseDialogueBody(.choice, token_pos, invalid_node);
}

// string = string_part { string_part } [ goto ] ;
fn parseDialogueBody(p: *Parser, comptime tag: Tag,
token_pos: TokenIndex, speaker: NodeIndex) Error!NodeIndex {
    var dia_parts: std.ArrayList(u32) = .empty;
    defer dia_parts.deinit(p.allocator);

    try dia_parts.append(p.allocator, speaker);

    try p.parseDialogueParts(&dia_parts);

    const goto = try p.parseDialogueGoto();
    try dia_parts.append(p.allocator, goto);

    _ = try p.expect(.semi_colon);

    return try p.addNode(tag, token_pos, .{
        .range = try p.addNodeRange(dia_parts.items),
    });
}

// string = content_part | interpolation ;
// content_part = content { content } ;
// interpolation = "{" ident "}" ;
// content = any_character_except("{", "}", "\n") ;
fn parseDialogueParts(p: *Parser, dialogue: *std.ArrayList(u32)) Error!void {
    while (p.peekTag() != .semi_colon and p.peekTag() != .EOF) {
        switch (p.peekTag()) {
            .string => {
                const str_index = try p.addNode(.string, p.token_pos, undefined);
                try dialogue.append(p.allocator, str_index);
                p.next();
            },
            .inter_open => {
                p.next();
                const expr = try p.parseExpr();
                _ = try p.expect(.inter_close);
                try dialogue.append(p.allocator, expr);
            },
            else => break,
        }
    }

    // The name is already inserted.
    // So, use 1 instead of 0.
    if (dialogue.items.len == 1) {
        try p.errors.append(p.allocator, .{
            .tag = .expected_dialogue,
            .token_pos = p.token_pos,
        });
        return Error.ParseError;
    }
}

// goto = "->" ident
fn parseDialogueGoto(p: *Parser) Error!NodeIndex {
    if (p.peekTag() == .goto) {
        p.next();
        return try p.parseGenericIdent(.label_ident);
    }

    return invalid_node;
}

// label = “~” ident stmt_block “end” ;
fn parseLabel(p: *Parser) Error!NodeIndex {
    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(p.allocator);

    _ = try p.expect(.tilde);

    const ident_pos = p.token_pos;
    const label = try p.parseGenericIdent(.label_ident);
    try stmts.append(p.allocator, label);

    _ = try p.expect(.semi_colon);

    // label extra_data layout:
    // [ label_pos, stmt_1, stmt_2, stmt_3, ... , stmt_n ]
    return p.addNode(.label, ident_pos, .{
        .range = try p.collectStmtUntil(.keyword_end, &stmts),
    });
}

// ───────────────────────────────
//           EXPRESSIONS
// ───────────────────────────────

fn collectStmtUntil(p: *Parser, end_tag: Token.Tag, stmts: *std.ArrayList(u32)) !Node.Range {
    while (p.peekTag() != end_tag and p.peekTag() != .EOF) {
        const stmt_index = p.parseStmt() catch {
            p.synchronize();
            continue;
        };

        try stmts.append(p.allocator, stmt_index);
    }

    _ = try p.expect(end_tag);
    // To allow complex statements to occupy a single line,
    // a semicolon may be omitted before a closing ")" or "}".
    if (p.peekTag() == .semi_colon) p.token_pos += 1;

    return try p.addNodeRange(stmts.items);
}

fn parseGenericIdent(p: *Parser, comptime tag: Tag) Error!NodeIndex {
    const ident_pos = try p.expect(.identifier);

    return switch (tag) {
        .var_ident, .label_ident,
        .name_ident => try p.addNode(tag, ident_pos, undefined),
        else => unreachable,
    };
}

fn parseAnonymousIdent(p: *Parser) Error!NodeIndex {
    const ident_pos = try p.expect(.underscore);
    return try p.addNode(.anonymous, ident_pos, undefined);
}

// expr = term { ( "+" | "-" ) term } ;
fn parseExpr(p: *Parser) Error!NodeIndex {
    var node = try p.parseTerm();

    while (true) {
        const tag = p.peekTag();
        if (tag != .plus and tag != .minus) break;

        const binary_tag = nodeTagFromBinary(tag) orelse {
            try p.errors.append(p.allocator, .{
                .tag = .expected_arith_op,
                .token_pos = p.token_pos,
            });
            return ParserError.ParseError;
        };
        const op_tok = p.token_pos;
        p.next();

        const rhs = try p.parseTerm();

        node = try p.addNode(binary_tag, op_tok, .{
            .node_and_node = .{ node, rhs }
        });
    }

    return node;
}

// term = factor { ( "*" | "/" ) factor } ;
fn parseTerm(p: *Parser) Error!NodeIndex {
    var node = try p.parseFactor();

    while (true) {
        const tag = p.peekTag();
        if (tag != .asterisk and tag != .slash) break;

        const binary_tag = nodeTagFromBinary(tag) orelse {
            try p.errors.append(p.allocator, .{
                .tag = .expected_arith_op,
                .token_pos = p.token_pos,
            });
            return ParserError.ParseError;
        };
        const op_tok = p.token_pos;
        p.next();

        const rhs = try p.parseFactor();

        node = try p.addNode(binary_tag, op_tok, .{
            .node_and_node = .{ node, rhs }
        });
    }

    return node;
}

// factor = number | ident | "(" expr ")" ;
fn parseFactor(p: *Parser) Error!NodeIndex {
    const idx = p.token_pos;

    switch (p.peekTag()) {
        .number => {
            p.next();
            return p.addNode(.number, idx, undefined);
        },
        .identifier => {
            return p.parseGenericIdent(.var_ident);
        },
        .open_paren => {
            p.next();
            const expr = try p.parseExpr();

            _ = try p.expect(.close_paren);

            return expr;
        },
        else => {
            // TODO: Expected expression
            // expr such as number, identifier, (MAYBE bool)
            try p.errors.append(p.allocator, .{
                .tag = .expected_ident,
                .token_pos = idx,
            });
            return Error.ParseError;
        },
    }
}
