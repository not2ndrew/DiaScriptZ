const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const AstError = @import("diagnostic.zig").Error;

const Allocator = std.mem.Allocator;

const Node = zig_node.Node;
const Tag = zig_node.NodeTag;
const NodeIndex = zig_node.NodeIndex;
const invalid_node = zig_node.invalid_node;

const Token = tok.Token;
const TokenTag = tok.Tag;
const TokenIndex = tok.TokenIndex;

const nodeTagFromArithmetic = zig_node.nodeTagFromArithmetic;
const nodeTagFromCompare = zig_node.nodeTagFromCompare;
const nodeTagFromBinary = zig_node.nodeTagFromBinary;
const nodeTagFromScene = zig_node.nodeTagFromScene;

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

fn reportUnexpected(self: *Parser, tag: AstError.Tag) !void {
    try self.errors.append(self.allocator, .{
        .token_pos = self.token_pos,
        .tag = tag,
    });
}

fn synchronize(self: *Parser) void {
    // Force the parser to advance to next token_pos.
    self.token_pos += 1;

    while (self.token_pos < self.tokens.len) {
        switch (self.peekTag()) {
            .keyword_const, .keyword_var,
            .keyword_if, .keyword_else,
            .keyword_end, .choice_marker,
            .underscore, .close_brace,
            .EOF => return,
            else => self.token_pos += 1,
        }
    }
}

fn peekToken(self: *Parser) Token {
    return self.tokens.get(self.token_pos);
}

fn peekTag(self: *Parser) TokenTag {
    return self.tokens.get(self.token_pos).tag;
}

fn next(self: *Parser) void {
    self.token_pos += 1;
}

fn expect(self: *Parser, expected: TokenTag) Error!TokenIndex {
    const idx = self.token_pos;
    const found = self.peekTag();

    if (found != expected) {
        try self.errors.append(self.allocator, .{
            .token_pos = idx,
            .tag = .unexpected_token,
        });

        return Error.ParseError;
    }

    self.next();
    return idx;
}

fn addNode(self: *Parser, tag: Tag, token_pos: TokenIndex, data: Node.Data) !NodeIndex {
    try self.nodes.append(self.allocator, .{
        .tag = tag,
        .token_pos = token_pos,
        .data = data,
    });

    const idx: u32 = @intCast(self.nodes.len - 1);
    return idx;
}

// program = { stmt } ;
pub fn parseAll(self: *Parser) Error!void {
    const root_token_pos: u32 = 0;

    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(self.allocator);

    while (self.token_pos < self.tokens.len and self.peekTag() != .EOF) {
        const stmt_index = self.parseStmt() catch {
            self.synchronize();
            continue;
        };

        try stmts.append(self.allocator, stmt_index);
    }

    const start: u32 = @intCast(self.extra_data.items.len);
    const len: u32 = @intCast(stmts.items.len);
    try self.extra_data.appendSlice(
    self.allocator,
    stmts.items
);

    _ = try self.addNode(.block, root_token_pos, .{
        .range = .{ .start = start, .len = len }
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
fn parseStmt(self: *Parser) Error!NodeIndex {
    return try switch (self.peekTag()) {
        .keyword_const, .keyword_var => self.parseDeclar(),
        .identifier => self.parseIdentStmt(),
        .keyword_if => self.parseIfStmt(),
        .choice_marker => self.parseChoice(),
        .tilde => self.parseLabel(),
        .underscore => self.parseAnonymousDialogue(),
        else => {
            self.next();
            try self.errors.append(self.allocator, .{
                .tag = .unexpected_token,
                .token_pos = self.token_pos,
            });
            return Error.ParseError;
        }
    };
}

// declar_stmt = ( "const" | "var" ) ident "=" expr ;
fn parseDeclar(self: *Parser) Error!NodeIndex {
    const decl_pos = self.token_pos;
    self.next();

    const ident = try self.parseGenericIdent(.var_ident);
    _ = try self.expect(.assign);
    const value = try self.parseExpr();

    _ = try self.expect(.semi_colon);

    return try self.addNode(.declar_stmt, decl_pos, .{
        .node_and_node = .{ ident, value }
    });
}

// Determine which type of stmt it is by searching the next
// token after the identifier.
fn parseIdentStmt(self: *Parser) Error!NodeIndex {
    const is_within = self.token_pos + 1 < self.tokens.len;
    if (is_within and self.tokens.get(self.token_pos + 1).tag == .colon) {
        return try self.parseDialogue();
    }

    const ident_pos = try self.parseGenericIdent(.var_ident);
    const next_tag = self.peekTag();

    return switch (next_tag) {
        .assign, .plus_equal, .minus_equal,
        .asterisk_equal, .slash_equal => self.parseAssignStmt(next_tag, ident_pos),
        else => {
            try self.reportUnexpected(.expected_arith_op);
            return Error.ParseError;
        }
    };
}

// compound_stmt = ident ( "=" | "+=" | "-=" | "*=" | "/=" ) expr ;
fn parseAssignStmt(self: *Parser, assign_tag: TokenTag, ident_pos: NodeIndex) Error!NodeIndex {
    const assign_pos = try self.expect(assign_tag);
    const expr = try self.parseExpr();

    _ = try self.expect(.semi_colon);

    const node_tag = nodeTagFromArithmetic(assign_tag) orelse {
        try self.reportUnexpected(.expected_arith_op);
        return ParserError.ParseError;
    };

    return try self.addNode(node_tag, assign_pos, .{
        .node_and_node = .{ ident_pos, expr }
    });
}

// if_stmt = "if" "(" condition ")" stmt_block [ else_block ] ;
// else_block = "else" stmt_block ;
fn parseIfStmt(self: *Parser) Error!NodeIndex {
    const if_pos = try self.expect(.keyword_if);

    _ = try self.expect(.open_paren);
    const condition = try self.parseCondition();
    _ = try self.expect(.close_paren);

    const then_block = try self.parseStmtBlock(.open_brace, .close_brace);

    var else_block: u32 = invalid_node;
    if (self.peekTag() == .keyword_else) {
        _ = try self.expect(.keyword_else);
        else_block = try self.parseStmtBlock(.open_brace, .close_brace);
    }

    const start: u32 = @intCast(self.extra_data.items.len);
    try self.extra_data.appendSlice(self.allocator, &[_]u32{
        condition, then_block, else_block,
    });

    // if_stmt extra_data layout:
    // [ condition, then_block, else_block ]
    return self.addNode(.if_stmt, if_pos, .{
        .range = .{ .start = start, .len = 3 }
    });
}

// condition  = conjunction { "or" conjunction } ;
fn parseCondition(self: *Parser) Error!NodeIndex {
    var node = try self.parseConjunction();

    while (self.peekTag() == .keyword_or) {
        const op_tok = self.token_pos;
        self.next();

        const rhs = try self.parseConjunction();
        node = try self.addNode(.bool_or, op_tok, .{
            .node_and_node = .{ node, rhs }
        });
    }

    return node;
}

// conjunction = boolean_factor { "and" boolean_factor } ;
fn parseConjunction(self: *Parser) Error!NodeIndex {
    var node = try self.parseBoolFactor();

    while (self.peekTag() == .keyword_and) {
        const op_tok = self.token_pos;
        self.next();

        const rhs = try self.parseBoolFactor();
        node = try self.addNode(.bool_and, op_tok, .{
            .node_and_node = .{ node, rhs }
        });
    }

    return node;
}

// boolean_factor = "(" condition ")" | compar_expr ;
fn parseBoolFactor(self: *Parser) Error!NodeIndex {
    if (self.peekTag() == .open_paren) {
        self.next();
        const node = try self.parseCondition();
        _ = try self.expect(.close_paren);

        return node;
    }

    return try self.parseCompareExpr();
}

// compar_expr = expr compar_op expr ;
// compar_op = "==" | "!=" | "<" | ">" | "<=" | ">=" ;
fn parseCompareExpr(self: *Parser) Error!NodeIndex {
    const left_expr = try self.parseExpr();

    const op_tag = self.peekTag();

    const compare_tag = nodeTagFromCompare(op_tag) orelse {
        try self.reportUnexpected(.expected_compar_op);
        return Error.ParseError;
    };

    const compare_token = self.token_pos;
    self.next();

    const right_expr = try self.parseExpr();

    return self.addNode(compare_tag, compare_token, .{
        .node_and_node = .{ left_expr, right_expr }
    });
}

// stmt_block = "{" { stmt } "}" ;
fn parseStmtBlock(self: *Parser, comptime start_tag: TokenTag, comptime end_tag: TokenTag) Error!NodeIndex {
    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(self.allocator);

    const block_pos = try self.expect(start_tag);
    const range = try self.collectStmtUntil(end_tag, &stmts);

    return try self.addNode(.block, block_pos, .{
        .range = .{ .start = range.start, .len = range.len }
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
fn parseDialogue(self: *Parser) Error!NodeIndex {
    const token_pos = self.token_pos;
    const speaker = try self.parseGenericIdent(.name_ident);
    _ = try self.expect(.colon);

    return self.parseDialogueBody(.dialogue, token_pos, speaker);
}

fn parseAnonymousDialogue(self: *Parser) Error!NodeIndex {
    const token_pos = self.token_pos;
    const speaker = try self.parseAnonymousIdent();
    _ = try self.expect(.colon);

    return self.parseDialogueBody(.dialogue, token_pos, speaker);
}

// choice = { "*" string }
fn parseChoice(self: *Parser) Error!NodeIndex {
    const token_pos = self.token_pos;
    self.next();

    return self.parseDialogueBody(.choice, token_pos, invalid_node);
}

// string = string_part { string_part } [ goto ] ;
fn parseDialogueBody(self: *Parser, comptime tag: Tag,
token_pos: TokenIndex, speaker: NodeIndex) Error!NodeIndex {
    var dia_parts: std.ArrayList(u32) = .empty;
    defer dia_parts.deinit(self.allocator);

    try dia_parts.append(self.allocator, speaker);

    try self.parseDialogueParts(&dia_parts);

    const goto = try self.parseDialogueGoto();
    try dia_parts.append(self.allocator, goto);

    _ = try self.expect(.semi_colon);

    const range = try self.commitDialogueData(dia_parts.items);
    return try self.addNode(tag, token_pos, .{
        .range = .{ .start = range.start, .len = range.len }
    });
}

// string = content_part | interpolation ;
// content_part = content { content } ;
// interpolation = "{" ident "}" ;
// content = any_character_except("{", "}", "\n") ;
fn parseDialogueParts(self: *Parser, dialogue: *std.ArrayList(u32)) Error!void {
    while (self.peekTag() != .semi_colon and self.peekTag() != .EOF) {
        switch (self.peekTag()) {
            .string => {
                const str_index = try self.addNode(.string, self.token_pos, .{ .none = {} });
                try dialogue.append(self.allocator, str_index);
                self.next();
            },
            .inter_open => {
                self.next();
                const expr = try self.parseExpr();
                _ = try self.expect(.inter_close);
                try dialogue.append(self.allocator, expr);
            },
            else => break,
        }
    }

    // The name is already inserted.
    // So, use 1 instead of 0.
    if (dialogue.items.len == 1) {
        try self.reportUnexpected(.expected_dialogue);
        return Error.ParseError;
    }
}

// goto = "->" ident
fn parseDialogueGoto(self: *Parser) Error!NodeIndex {
    if (self.peekTag() == .goto) {
        self.next();
        return try self.parseGenericIdent(.label_ident);
    }

    return invalid_node;
}

fn commitDialogueData(self: *Parser, dia_parts: []u32) Error!Node.Range {
    const start: u32 = @intCast(self.extra_data.items.len);
    const len: u32 = @intCast(dia_parts.len);
    try self.extra_data.appendSlice(self.allocator, dia_parts);

    return .{ .start = start, .len = len };
}

// label = “~” ident stmt_block “end” ;
fn parseLabel(self: *Parser) Error!NodeIndex {
    var stmts: std.ArrayList(u32) = .empty;
    defer stmts.deinit(self.allocator);

    _ = try self.expect(.tilde);

    const ident_pos = self.token_pos;
    const label = try self.parseGenericIdent(.label_ident);
    try stmts.append(self.allocator, label);

    _ = try self.expect(.semi_colon);

    const range = try self.collectStmtUntil(.keyword_end, &stmts);

    // label extra_data layout:
    // [ label_pos, stmt_1, stmt_2, stmt_3, ... , stmt_n ]
    return self.addNode(.label, ident_pos, .{
        .range = .{ .start = range.start, .len = range.len }
    });
}

// ───────────────────────────────
//           EXPRESSIONS
// ───────────────────────────────

fn collectStmtUntil(self: *Parser, end_tag: TokenTag, stmts: *std.ArrayList(u32)) !Node.Range {
    while (self.peekTag() != end_tag and self.peekTag() != .EOF) {
        const stmt_index = self.parseStmt() catch {
            self.synchronize();
            continue;
        };

        try stmts.append(self.allocator, stmt_index);
    }

    _ = try self.expect(end_tag);
    // To allow complex statements to occupy a single line,
    // a semicolon may be omitted before a closing ")" or "}".
    if (self.peekTag() == .semi_colon) self.token_pos += 1;

    const start: u32 = @intCast(self.extra_data.items.len);
    const len: u32 = @intCast(stmts.items.len);
    try self.extra_data.appendSlice(
        self.allocator,
        stmts.items
    );

    return .{ .start = start, .len = len };
}

fn parseGenericIdent(self: *Parser, comptime tag: Tag) Error!NodeIndex {
    const ident_pos = try self.expect(.identifier);

    return switch (tag) {
        .var_ident, .label_ident,
        .name_ident => try self.addNode(tag, ident_pos, .{ .none = {} }),
        else => unreachable,
    };
}

fn parseAnonymousIdent(self: *Parser) Error!NodeIndex {
    const ident_pos = try self.expect(.underscore);
    return try self.addNode(.anonymous, ident_pos, .{ .none = {} });
}

// expr = term { ( "+" | "-" ) term } ;
fn parseExpr(self: *Parser) Error!NodeIndex {
    var node = try self.parseTerm();

    while (true) {
        const tag = self.peekTag();
        if (tag != .plus and tag != .minus) break;

        const binary_tag = nodeTagFromBinary(tag) orelse {
            try self.reportUnexpected(.expected_arith_op);
            return ParserError.ParseError;
        };
        const op_tok = self.token_pos;
        self.next();

        const rhs = try self.parseTerm();

        node = try self.addNode(binary_tag, op_tok, .{
            .node_and_node = .{ node, rhs }
        });
    }

    return node;
}

// term = factor { ( "*" | "/" ) factor } ;
fn parseTerm(self: *Parser) Error!NodeIndex {
    var node = try self.parseFactor();

    while (true) {
        const tag = self.peekTag();
        if (tag != .asterisk and tag != .slash) break;

        const binary_tag = nodeTagFromBinary(tag) orelse {
            try self.reportUnexpected(.expected_arith_op);
            return ParserError.ParseError;
        };
        const op_tok = self.token_pos;
        self.next();

        const rhs = try self.parseFactor();

        node = try self.addNode(binary_tag, op_tok, .{
            .node_and_node = .{ node, rhs }
        });
    }

    return node;
}

// factor = number | ident | "(" expr ")" ;
fn parseFactor(self: *Parser) Error!NodeIndex {
    const idx = self.token_pos;

    switch (self.peekTag()) {
        .number => {
            self.next();
            return self.addNode(.number, idx, .{ .none = {} });
        },
        .identifier => {
            return self.parseGenericIdent(.var_ident);
        },
        .open_paren => {
            self.next();
            const expr = try self.parseExpr();

            _ = try self.expect(.close_paren);

            return expr;
        },
        else => {
            try self.errors.append(self.allocator, .{
                .token_pos = idx,
                .tag = .unexpected_token,
            });
            return Error.ParseError;
        },
    }
}
