const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const Diagnostic = @import("diagnostic.zig").Diagnostic;
const Ast = @import("ast.zig").Ast;

const Allocator = std.mem.Allocator;

const NodeIndex = zig_node.NodeIndex;
const TokenIndex = tok.TokenIndex;

const Token = tok.Token;
const TokenTag = tok.Tag;

const Tag = zig_node.NodeTag;
const Node = zig_node.Node;
const NodeData = zig_node.NodeData;
const NodeRange = zig_node.NodeRange;
const invalid_node = zig_node.invalid_node;

const nodeTagFromArithmetic = zig_node.nodeTagFromArithmetic;
const nodeTagFromCompare = zig_node.nodeTagFromCompare;
const nodeTagFromBinary = zig_node.nodeTagFromBinary;
const nodeTagFromScene = zig_node.nodeTagFromScene;

const Tokens = std.MultiArrayList(Token);

const ParserError = error {
    ParseError,
};

const Error = ParserError || Allocator.Error;

pub const Parser = struct {
    allocator: Allocator,
    tokens: std.MultiArrayList(Token).Slice,
    nodes: std.MultiArrayList(Node),

    errors: std.ArrayList(Diagnostic),

    token_pos: u32,

    pub fn init(allocator: Allocator, tokens: Tokens.Slice) !Parser {
        return .{
            .allocator = allocator,
            .tokens = tokens,
            .nodes = .empty,
            .errors = .empty,
            .token_pos = 0,
        };
    }

    fn reportUnexpected(self: *Parser, expected: TokenTag) !void {
        var token = self.peekToken();

        // Prev only copies the token, it does not modify it
        if (token.tag == .EOF) {
            const prev = self.tokens.get(self.token_pos - 1);
            token.start = prev.end;
            token.end = prev.end;
        }

        try self.errors.append(self.allocator, .{
            .severity = .note,
            .err = .{
                .unexpected_token = .{
                    .expected = expected, .found = token.tag 
                } 
            },
            .start = @intCast(token.start),
            .end = @intCast(token.end),
        });
    }

    fn synchronize(self: *Parser) void {
        while (self.token_pos < self.tokens.len) {
            switch (self.peekTag()) {
                .keyword_const, .keyword_var,
                .keyword_if, .keyword_else,
                .keyword_end, .identifier, .EOF => return,
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

    fn expect(self: *Parser, tag: TokenTag) Error!TokenIndex {
        const idx = self.token_pos;

        if (self.peekTag() != tag) {
            try self.reportUnexpected(tag);
            return Error.ParseError;
        }

        self.next();
        return idx;
    }

    fn addNode(self: *Parser, tag: Tag, token_pos: TokenIndex, data: NodeData) !NodeIndex {
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
        // Allocate 10 for now.
        var stmts = try std.ArrayList(NodeIndex).initCapacity(self.allocator, 10);

        while (self.token_pos < self.tokens.len and self.peekTag() != .EOF) {
            const stmt_index = self.parseStmt() catch {
                self.synchronize();
                continue;
            };

            try stmts.append(self.allocator, stmt_index);
        }

        const slice = try stmts.toOwnedSlice(self.allocator);
        _ = try self.addNode(.block, 0, .{ .block = slice });
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
        return switch (self.peekTag()) {
            .keyword_const, .keyword_var => try self.parseDeclar(),
            .identifier, .underscore => try self.parseIdentStmt(),
            .keyword_if => try self.parseIfStmt(),
            .choice_marker => try self.parseChoice(),
            .tilde => try self.parseLabel(),
            else => {
                try self.reportUnexpected(.identifier);
                return Error.ParseError;
            }
        };
    }

    // declar_stmt = ( "const" | "var" ) ident "=" expr ;
    fn parseDeclar(self: *Parser) Error!NodeIndex {
        const decl_pos = self.token_pos;
        self.next();

        const ident = try self.parseIdent(.var_ident);
        _ = try self.expect(.assign);
        const value = try self.parseExpr();

        return try self.addNode(.declar_stmt, decl_pos, .{
            .decl = .{ .name = ident, .value = value }
        });
    }

    // Determine which type of stmt it is by searching the next
    // token after the identifier.
    fn parseIdentStmt(self: *Parser) Error!NodeIndex {
        // TODO: This is dangerous. Make sure to check if
        // the token pos is NOT beyond the length of slice.
        if (self.tokens.get(self.token_pos + 1).tag == .colon) {
            return try self.parseDialogue();
        }

        const ident_pos = try self.parseIdent(.var_ident);
        const next_tag = self.peekTag();

        return switch (next_tag) {
            .assign, .plus_equal, .minus_equal,
            .asterisk_equal, .slash_equal => self.parseAssignStmt(next_tag, ident_pos),
            else => try self.expect(.assign),
        };
    }

    // compound_stmt = ident ( "=" | "+=" | "-=" | "*=" | "/=" ) expr ;
    fn parseAssignStmt(self: *Parser, assign_tag: TokenTag, ident_pos: NodeIndex) Error!NodeIndex {
        const assign_pos = try self.expect(assign_tag);
        const expr = try self.parseExpr();

        const node_tag = nodeTagFromArithmetic(assign_tag) orelse {
            try self.reportUnexpected(.assign);
            return ParserError.ParseError;
        };

        return try self.addNode(node_tag, assign_pos, .{
            .assign = .{
                .target = ident_pos,
                .value = expr,
            }
        });
    }

    // if_stmt = "if" "(" compar_expr ")" block [ else_block ] ;
    fn parseIfStmt(self: *Parser) Error!NodeIndex {
        const if_pos = try self.expect(.keyword_if);
        var else_block: NodeIndex = invalid_node;

        _ = try self.expect(.open_paren);
        const condition = try self.parseCompareExpr();
        _ = try self.expect(.close_paren);

        const then_block = try self.parseStmtBlock();

        if (self.peekTag() == .keyword_else) {
            else_block = try self.parseElseBlock();
        }

        return self.addNode(.if_stmt, if_pos, .{
            .if_stmt = .{
                .condition = condition,
                .then_block = then_block,
                .else_block = else_block,
            }
        });
    }

    // else_block = "else" stmts ;
    fn parseElseBlock(self: *Parser) Error!NodeIndex {
        _ = try self.expect(.keyword_else);
        return try self.parseStmtBlock();
    }

    // compar_expr = expr compar_op expr ;
    // compar_op = "==" | "!=" | "<" | ">" | "<=" | ">=" ;
    fn parseCompareExpr(self: *Parser) Error!NodeIndex {
        const left_expr = try self.parseExpr();

        const op_tag = self.peekTag();

        const compare_tag = nodeTagFromCompare(op_tag) orelse {
            try self.reportUnexpected(.equals);
            return Error.ParseError;
        };

        const compare_token = self.token_pos;
        self.next();

        const right_expr = try self.parseExpr();

        return self.addNode(compare_tag, compare_token, .{
            .binary = .{ .lhs = left_expr, .rhs = right_expr },
        });
    }

    // stmt_block = "{" { stmt } "}" ;
    fn parseStmtBlock(self: *Parser) Error!NodeIndex {
        const block_pos = try self.expect(.open_brace);

        const slice = try self.parseStmtListUntil(.close_brace);

        _ = try self.expect(.close_brace);

        return try self.addNode(.block, block_pos, .{
            .block = slice
        });
    }

    fn parseStmtListUntil(self: *Parser, end_tag: TokenTag) Error![]NodeIndex {
        // Allocate 10 for now.
        var stmts = try std.ArrayList(NodeIndex).initCapacity(self.allocator, 10);

        while (self.peekTag() != end_tag and self.peekTag() != .EOF) {
            const stmt_index = self.parseStmt() catch {
                self.synchronize();
                continue;
            };

            try stmts.append(self.allocator, stmt_index);
        }

        return try stmts.toOwnedSlice(self.allocator);
    }

    // ───────────────────────────────
    //           DIALOGUE
    // ───────────────────────────────

    // dialogue = ( "_" | identifier ) ":" string ;
    fn parseDialogue(self: *Parser) Error!NodeIndex {
        const tag = self.peekTag();

        const ident_pos = if (tag == .underscore)
            try self.parseIdent(.anonymous)
        else
            try self.parseIdent(.name_ident);

        _ = try self.expect(.colon);

        return try self.parseGoto(ident_pos, .dialogue);
    }

    // choice = { "*" string }
    fn parseChoice(self: *Parser) Error!NodeIndex {
        const marker = self.token_pos;
        self.next();

        return try self.parseGoto(marker, .choice);
    }

    // string = content_part | interpolation ;
    // content_part = content { content } ;
    // interpolation = "{" ident "}" ;
    // content = any_character_except("{", "}", "\n") ;
    fn parseString(self: *Parser) Error!u32 {
        var i: u32 = 0;
        while (true) : (i += 1) {
            switch (self.peekTag()) {
                .string => {
                    _ = try self.addNode(.string, self.token_pos, .none);

                    self.next();
                },
                .inter_open => {
                    self.next();
                    const ident = try self.expect(.identifier);

                    _ = try self.expect(.inter_close);
                    _ = try self.addNode(.var_ident, ident, .none);
                },
                else => break,
            }
        }

        if (i == 0) {
            try self.reportUnexpected(.string);
            return Error.ParseError;
        }

        return i;
    }

    // string = string_part { string_part } [ "->" ident ] ;
    fn parseGoto(self: *Parser, ident_pos: TokenIndex, tag: Tag) Error!NodeIndex {
        const start: u32 = @intCast(self.nodes.len);
        const len: u32 = try self.parseString();

        if (self.peekTag() == .goto) {
            self.next();

            const goto = try self.parseIdent(.label_ident);

            return self.addNode(tag, ident_pos, .{
                .dialogue = .{
                    .str = .{ .start = start, .len = len },
                    .branch = .{ .goto = goto }
                }
            });
        } else {
            return self.addNode(tag, ident_pos, .{
                .dialogue = .{
                    .str = .{ .start = start, .len = len },
                    .branch = .none
                }
            });
        }
    }

    // label = “~” ident block “end” ;
    fn parseLabel(self: *Parser) Error!NodeIndex {
        _ = try self.expect(.tilde);

        const ident_pos = self.token_pos;
        _ = try self.parseIdent(.label_ident);

        const slice = try self.parseStmtListUntil(.keyword_end);

        _ = try self.expect(.keyword_end);

        return self.addNode(.label, ident_pos, .{
            .block = slice
        });
    }

    // ───────────────────────────────
    //           EXPRESSIONS
    // ───────────────────────────────

    fn parseIdent(self: *Parser, tag: Tag) Error!NodeIndex {
        const ident_pos = try self.expect(.identifier);
        
        return switch (tag) {
            .var_ident, .label_ident,
            .name_ident, .anonymous => try self.addNode(tag, ident_pos, .none),
            else => unreachable,
        };
    }

    // expr = term { ( "+" | "-" ) term } ;
    fn parseExpr(self: *Parser) Error!NodeIndex {
        var node = try self.parseTerm();

        while (true) {
            const tag = self.peekTag();
            if (tag != .plus and tag != .minus) break;

            const binary_tag = nodeTagFromBinary(tag) orelse {
                try self.reportUnexpected(.plus);
                return ParserError.ParseError;
            };
            const op_tok = self.token_pos;
            self.next();

            const rhs = try self.parseTerm();

            node = try self.addNode(binary_tag, op_tok, .{
                .binary = .{ .lhs = node, .rhs = rhs }
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
                try self.reportUnexpected(.asterisk);
                return ParserError.ParseError;
            };
            const op_tok = self.token_pos;
            self.next();

            const rhs = try self.parseFactor();

            node = try self.addNode(binary_tag, op_tok, .{
                .binary = .{ .lhs = node, .rhs = rhs }
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
                return self.addNode(.number, idx, .none);
            },
            .identifier => {
                self.next();
                return self.addNode(.var_ident, idx, .none);
            },
            .open_paren => {
                self.next();
                const expr = try self.parseExpr();

                _ = try self.expect(.close_paren);

                return expr;
            },
            else => {
                try self.reportUnexpected(.number);
                return Error.ParseError;
            },
        }
    }
};
