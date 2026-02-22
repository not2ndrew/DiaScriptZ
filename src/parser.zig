const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const diagnostic = @import("diagnostic.zig");

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

const DiagnosticSink = diagnostic.DiagnosticSink;

const Tokens = std.MultiArrayList(Token);

const ParserError = error {
    ParseError,
};

const Error = ParserError || Allocator.Error;

// Extended Backus Naur Form:
pub const Parser = struct {
    diag_sink: *DiagnosticSink,
    tokens: *const std.MultiArrayList(Token),
    nodes: std.MultiArrayList(Node),
    
    stmts: std.ArrayList(NodeIndex),

    token_pos: u32,

    pub fn init(tokens: *const Tokens, diag_sink: *DiagnosticSink) Parser {
        return Parser{
            .diag_sink = diag_sink,
            .tokens = tokens,
            .nodes = .{},
            .stmts = .{},
            .token_pos = 0,
        };
    }

    // No need to deinit stmts since that is done in parse().
    pub fn deinit(self: *Parser) void {
        self.nodes.deinit(self.diag_sink.allocator);
    }

    fn reportUnexpected(self: *Parser, expected: TokenTag) !void {
        var token = self.peek();

        // Prev only copies the token, it does not modify it
        if (token.tag == .EOF) {
            const prev = self.tokens.get(self.token_pos - 1);
            token.start = prev.end;
            token.end = prev.end;
        }

        try self.diag_sink.report(.{
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
            switch (self.peek().tag) {
                .keyword_const, .keyword_var,
                .keyword_if, .keyword_else,
                .identifier, .EOF => return,
                else => self.token_pos += 1,
            }
        }
    }

    fn peek(self: *Parser) Token {
        const pos = self.token_pos;

        if (self.token_pos < self.tokens.len) {
            return self.tokens.get(pos);
        }

        return self.tokens.get(self.tokens.len - 1);
    }

    fn next(self: *Parser) void {
        self.token_pos += 1;
    }

    fn expect(self: *Parser, tag: TokenTag) Error!TokenIndex {
        const idx = self.token_pos;
        const token = self.peek();

        if (token.tag != tag) {
            try self.reportUnexpected(tag);
            return Error.ParseError;
        }

        self.next();
        return idx;
    }

    fn addNode(self: *Parser, tag: Tag, token_pos: TokenIndex, data: NodeData) !NodeIndex {
        try self.nodes.append(self.diag_sink.allocator, .{
            .tag = tag,
            .token_pos = token_pos,
            .data = data,
        });

        const idx: u32 = @intCast(self.nodes.len - 1);
        return idx;
    }

    pub fn printStmtNodeTags(self: *Parser, stmts: []NodeIndex) void {
        for (stmts) |stmt_index| {
            const tag = self.nodes.get(stmt_index).tag;
            std.debug.print("Node Tag: {t}\n", .{tag});
        }
    }

    // program = { stmt } ;
    pub fn parse(self: *Parser) Error![]NodeIndex {
        while (self.token_pos < self.tokens.len and self.peek().tag != .EOF) {
            const stmt = self.parseStmt() catch {
                self.synchronize();
                continue;
            };
            try self.stmts.append(self.diag_sink.allocator, stmt);
        }

        return self.stmts.toOwnedSlice(self.diag_sink.allocator);
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
    // | scene ;
    fn parseStmt(self: *Parser) Error!NodeIndex {
        const tag = self.peek().tag;
        return switch (tag) {
            .keyword_const, .keyword_var => self.parseDeclar(),
            .identifier, .underscore => self.parseIdentStmt(),
            .keyword_if => self.parseIfStmt(),
            .choice_marker => self.parseChoice(),
            .tilde => self.parseLabel(),
            .hash => self.parseScene(),
            else => return try self.expect(.identifier),
        };
    }

    // declar_stmt = ( "const" | "var" ) ident "=" expr ;
    fn parseDeclar(self: *Parser) Error!NodeIndex {
        const decl_pos = self.token_pos;
        self.next();

        const ident = try self.parseIdent();
        _ = try self.expect(.assign);
        const value = try self.parseExpr();

        return try self.addNode(.declar_stmt, decl_pos, .{
            .decl = .{ .name = ident, .value = value }
        });
    }

    // compound_stmt = ident ( "=" | "+=" | "-=" | "*=" | "/=" ) expr ;
    fn parseIdentStmt(self: *Parser) Error!NodeIndex {
        const ident_pos = try self.parseIdent();

        const next_tag = self.peek().tag;

        return switch (next_tag) {
            .assign, .plus_equal, .minus_equal,
            .asterisk_equal, .slash_equal => self.parseAssignStmt(next_tag, ident_pos),
            .colon => try self.parseDialogue(ident_pos),
            else => return try self.expect(.assign),
        };
    }

    fn parseAssignStmt(self: *Parser, assign_tag: TokenTag, ident_pos: NodeIndex) Error!NodeIndex {
        const assign_pos = try self.expect(assign_tag);
        const expr = try self.parseExpr();

        const node_tag = nodeTagFromArithmetic(assign_tag);

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

        if (self.peek().tag == .keyword_else) {
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

        const op_tag = self.peek().tag;

        const compare_tag = switch (op_tag) {
            .equals, .not_equal, .less,
            .greater, .less_or_equal,
            .greater_or_equal => nodeTagFromCompare(op_tag),
            else => return try self.expect(.equals),
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
        const start: u32 = @intCast(self.stmts.items.len);
        const block_pos = try self.expect(.open_brace);

        while (self.peek().tag != .close_brace and self.token_pos < self.tokens.len - 1) {
            const stmt = self.parseStmt() catch {
                self.synchronize();
                continue;
            };
            try self.stmts.append(self.diag_sink.allocator, stmt);
        }

        _ = try self.expect(.close_brace);
        const len: u32 = @intCast(self.stmts.items.len - start);

        return try self.addNode(.block, block_pos, .{
            .block = .{ .start = start, .len = len }
        });
    }

    // ───────────────────────────────
    //           DIALOGUE
    // ───────────────────────────────

    // dialogue = identifier ":" string ;
    fn parseDialogue(self: *Parser, ident_pos: TokenIndex) Error!NodeIndex {
        _ = try self.expect(.colon);

        return try self.parseGoto(ident_pos, .dialogue);
    }

    // choice = { "*" string }
    fn parseChoice(self: *Parser) Error!NodeIndex {
        const marker = self.token_pos;
        self.next();

        return try self.parseGoto(marker, .choice);
    }

    // string_part = content_part | interpolation ;
    // content_part = content { content } ;
    // interpolation = "{" ident "}" ;
    // content = any_character_except("{", "}", "\n") ;
    fn parseStrPart(self: *Parser) Error!u32 {
        const start = self.nodes.len;
        while (true) {
            const tag = self.peek().tag;

            switch (tag) {
                .string => {
                    _ = try self.addNode(.string, self.token_pos, .{
                        .string = .{ .token = self.token_pos }
                    });

                    self.next();
                },
                .inter_open => {
                    self.next();
                    const ident = try self.expect(.identifier);

                    _ = try self.expect(.inter_close);

                    _ = try self.addNode(.identifier, ident, .{
                        .identifier = .{ .token = ident }
                    });
                },
                else => break,
            }
        }

        const new_len: u32 = @intCast(self.nodes.len - start);
        if (new_len == 0) return try self.expect(.string);

        return new_len;
    }

    // string = string_part { string_part } [ "->" ident ] ;
    fn parseGoto(self: *Parser, ident_pos: TokenIndex, tag: Tag) Error!NodeIndex {
        const start: u32 = @intCast(self.nodes.len);
        const len: u32 = try self.parseStrPart();

        if (self.peek().tag == .goto) {
            self.next();

            const goto = try self.parseIdent();

            return try self.addNode(tag, ident_pos, .{
                .dialogue = .{
                    .str = .{ .start = start, .len = len },
                    .branch = .{ .goto = goto }
                }
            });
        }

        return try self.addNode(tag, ident_pos, .{
            .dialogue = .{
                .str = .{ .start = start, .len = len },
                .branch = .none,
            }
        });
    }

    // label = “~” ident block “end” ;
    fn parseLabel(self: *Parser) Error!NodeIndex {
        _ = try self.expect(.tilde);
        const label = try self.parseDialogueBody();

        return label;
    }

    // TODO: Scene also takes in a dialogue block,
    // but does not require a closing keyword.
    // It should be based on indentation.
    // scene = "#" ident block ;
    fn parseScene(self: *Parser) Error!NodeIndex {
        _ = try self.expect(.hash);
        return invalid_node;
    }

    fn parseDialogueBody(self: *Parser) Error!NodeIndex {
        const block_pos = self.token_pos;
        const start: u32 = @intCast(self.stmts.items.len);

        while (self.peek().tag != .keyword_end and self.token_pos < self.tokens.len) {
            const stmt = self.parseStmt() catch {
                self.synchronize();
                continue;
            };
            try self.stmts.append(self.diag_sink.allocator, stmt);
        }

        _ = try self.expect(.keyword_end);
        const len: u32 = @intCast(self.stmts.items.len - start);

        return try self.addNode(.block, block_pos, .{
            .block = .{ .start = start, .len = len }
        });

    }

    // ───────────────────────────────
    //           EXPRESSIONS
    // ───────────────────────────────

    fn parseIdent(self: *Parser) Error!NodeIndex {
        const ident_pos = try self.expect(.identifier);
        return try self.addNode(.identifier, ident_pos, .{
            .identifier = .{ .token = ident_pos }
        });
    }

    // expr = term { ( "+" | "-" ) term } ;
    fn parseExpr(self: *Parser) Error!NodeIndex {
        var node = try self.parseTerm();

        while (true) {
            const tag = self.peek().tag;
            if (tag != .plus and tag != .minus) break;

            const binary_tag = nodeTagFromCompare(tag);
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
            const tag = self.peek().tag;
            if (tag != .asterisk and tag != .slash) break;

            const binary_tag = nodeTagFromCompare(tag);
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

        switch (self.peek().tag) {
            .number => {
                self.next();
                return self.addNode(.number, idx, .{
                    .number = .{ .token = idx }
                });
            },
            .identifier => {
                self.next();
                return self.addNode(.identifier, idx, .{
                    .identifier = .{ .token = idx }
                });
            },
            .open_paren => {
                self.next();
                const expr = try self.parseExpr();

                _ = try self.expect(.close_paren);

                return expr;
            },
            else => return try self.expect(.number),
        }
    }
};
