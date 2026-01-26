const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");

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

const nodeTagFromAssign = zig_node.nodeTagFromAssign;
const nodeTagFromCompare = zig_node.nodeTagFromCompare;
const nodeTagFromBinary = zig_node.nodeTagFromBinary;

pub const ParseError = struct {
    expected: TokenTag,
    found: TokenTag,
    token_pos: TokenIndex,
};

const Error = Allocator.Error;

// Extended Backus Naur Form:
pub const Parser = struct {
    allocator: Allocator,
    tokens: *const std.MultiArrayList(Token),
    nodes: std.MultiArrayList(Node),
    stmts: std.ArrayList(NodeIndex),
    str_parts: std.ArrayList(NodeIndex),
    choices: std.ArrayList(NodeIndex),
    errors: std.ArrayList(ParseError),

    token_pos: u32,

    pub fn init(allocator: Allocator, tokens: *const std.MultiArrayList(Token)) Parser {
        return Parser{
            .allocator = allocator,
            .tokens = tokens,
            .nodes = .{},
            .stmts = .{},
            .str_parts = .{},
            .choices = .{},
            .errors = .{},
            .token_pos = 0,
        };
    }

    // No need to deinit stmts since that is done in parse().
    pub fn deinit(self: *Parser) void {
        self.nodes.deinit(self.allocator);
        self.str_parts.deinit(self.allocator);
        self.choices.deinit(self.allocator);
        self.errors.deinit(self.allocator);
    }

    fn reportError(self: *Parser, expected: TokenTag, found: TokenTag) void {
        self.errors.append(self.allocator, .{
            .expected = expected,
            .found = found,
            .token_pos = self.token_pos,
        }) catch {};
    }

    fn peek(self: *Parser) Token {
        const pos = self.token_pos;

        if (pos >= self.tokens.len) {
            return .{ .tag = .EOF, .start = pos, .end = pos };
        }

        return self.tokens.get(pos);
    }

    fn next(self: *Parser) void {
        if (self.token_pos < self.tokens.len) self.token_pos += 1;
    }

    fn expect(self: *Parser, tag: TokenTag) TokenIndex {
        const idx = self.token_pos;
        const token = self.peek();

        if (token.tag != tag) {
            self.reportError(tag, token.tag);
        }

        self.token_pos += 1;
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

    pub fn printStmtNodeTags(self: *Parser, stmts: []NodeIndex) void {
        for (stmts) |stmt_index| {
            const tag = self.nodes.get(stmt_index).tag;
            std.debug.print("Node Tag: {t}\n", .{tag});
        }
    }

    pub fn printNodeErrors(self: *Parser) void {
        for (self.errors.items) |err| {
            std.debug.print("Expected: {t}, Found: {t}, Token Position: {d}\n", .{
                err.expected, err.found, err.token_pos,
            });
        }
    }

    // program = { stmt }
    pub fn parse(self: *Parser) Error![]NodeIndex {
        while (self.token_pos < self.tokens.len and self.peek().tag != .EOF) {
            const stmt = try self.parseStmt();
            try self.stmts.append(self.allocator, stmt);
        }

        return self.stmts.toOwnedSlice(self.allocator);
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
            .tilde => self.parseLabel(),
            .hash => self.parseScene(),
            else => {
                self.reportError(.identifier, tag);
                self.next();
                return invalid_node;
            },
        };
    }

    // declar_stmt = ( "const" | "var" ) ident "=" expr
    fn parseDeclar(self: *Parser) Error!NodeIndex {
        // const decl = self.peek().tag;
        const decl_pos = self.token_pos;
        self.next();

        const ident_pos = self.token_pos;
        const ident = try self.parseIdent();
        _ = try self.parseAssignStmt(.assign, ident);

        return try self.addNode(.declar_stmt, decl_pos, .{
            .decl = .{ .name = ident_pos, .value = ident }
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
            else => {
                self.reportError(.assign, next_tag);
                self.next();
                return invalid_node;
            } 
        };
    }

    fn parseAssignStmt(self: *Parser, assign_tag: TokenTag, ident_pos: NodeIndex) Error!NodeIndex {
        const assign_pos = self.expect(assign_tag);
        const expr = try self.parseExpr();

        const node_tag = nodeTagFromAssign(assign_tag);

        return try self.addNode(node_tag, assign_pos, .{
            .assign = .{
                .target = ident_pos,
                .value = expr,
            }
        });
    }

    // if_stmt = "if" "(" compar_expr ")" "{" block "}" [ else_block ] ;
    fn parseIfStmt(self: *Parser) Error!NodeIndex {
        const if_pos = self.expect(.keyword_if);
        var then_block: NodeIndex = invalid_node;
        var else_block: NodeIndex = invalid_node;

        _ = self.expect(.open_paren);

        const condition = try self.parseCompareExpr();

        _ = self.expect(.close_paren);
        _ = self.expect(.open_brace);

        const then_pos = self.token_pos;

        const then_start: u32 = @intCast(self.stmts.items.len);
        const then_len = try self.parseStmts();

        _ = self.expect(.close_brace);

        then_block = try self.addNode(.then_block, then_pos, .{
            .block = .{ .start = then_start, .len = then_len }
        });

        if (self.peek().tag == .keyword_else) {
            const else_pos = self.token_pos;
            const else_start: u32 = @intCast(self.stmts.items.len);
            const else_len = try self.parseElseBlock();

            else_block = try self.addNode(.else_block, else_pos, .{
                .block = .{ .start = else_start, .len = else_len }
            });
        }

        return self.addNode(.if_stmt, if_pos, .{
            .if_stmt = .{
                .condition = condition,
                .then_block = then_block,
                .else_block = else_block,
            }
        });
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
            else => {
                self.reportError(.equals, op_tag);
                self.next();
                return invalid_node;
            },
        };

        const compare_token = self.token_pos;
        self.next();

        const right_expr = try self.parseExpr();

        return self.addNode(compare_tag, compare_token, .{
            .binary = .{ .lhs = left_expr, .rhs = right_expr },
        });
    }

    // else_block = "else" "{" stmts "}";
    fn parseElseBlock(self: *Parser) Error!u32 {
        _ = self.expect(.keyword_else);
        _ = self.expect(.open_brace);
        const else_block = try self.parseStmts();
        _ = self.expect(.close_brace);
        return else_block;
    }

    // stmts = { stmt } ;
    fn parseStmts(self: *Parser) Error!u32 {
        const start_len = self.stmts.items.len;

        while (self.token_pos < self.tokens.len) {
            switch (self.peek().tag) {
                .close_brace, .keyword_end, .hash => break,
                else => {
                    const stmt = try self.parseStmt();
                    try self.stmts.append(self.allocator, stmt);
                }
            }
        }

        const stmts_len: u32 = @intCast(self.stmts.items.len - start_len);
        return stmts_len;
    }

    // ───────────────────────────────
    //           DIALOGUE
    // ───────────────────────────────

    // dialogue = identifier ":" string ;
    // string = string_part { string_part } [ "->" ident ] ;
    fn parseDialogue(self: *Parser, ident_pos: TokenIndex) Error!NodeIndex {
        _ = self.expect(.colon);

        const str_start: u32 = @intCast(self.str_parts.items.len);
        const choice_start: u32 = @intCast(self.choices.items.len);

        const str_len = try self.parseStrPart();

        var goto: NodeIndex = invalid_node;
        var choices: NodeRange = .{
            .start = choice_start, .len = 0,
        };

        if (self.peek().tag == .goto) {
            self.next();

            goto = try self.parseIdent();
        }

        if (self.peek().tag == .choice_marker) {
            choices.len = try self.parseChoices();
        }

        return try self.addNode(.dialogue, ident_pos, .{
            .dialogue = .{
                .str = .{ .start = str_start, .len = str_len },
                .goto = goto,
                .choices = choices,
            }
        });
    }

    // string_part = content_part | interpolation ;
    // content_part = content { content } ;
    // interpolation = "{" ident "}" ;
    // content = any_character_except("{", "}", "\n") ;
    fn parseStrPart(self: *Parser) Error!u32 {
        const start = self.str_parts.items.len;
        while (true) {
            const tag = self.peek().tag;

            switch (tag) {
                .string => {
                    const str = try self.addNode(.string, self.token_pos, .{
                        .string = .{ .token = self.token_pos },
                    });

                    try self.str_parts.append(self.allocator, str);
                    self.next();
                },
                .inter_open => {
                    self.next();
                    const ident = try self.parseIdent();

                    _ = self.expect(.inter_close);

                    try self.str_parts.append(self.allocator, ident);
                },
                else => break,
            }
        }

        const str_len: u32 = @intCast(self.str_parts.items.len - start);

        if (str_len == 0) self.reportError(.string, self.peek().tag);

        return str_len;
    }

    // choice = { "*" string } (MIN = 2, MAX = 5)
    fn parseChoices(self: *Parser) !u32 {
        const choices_start = self.choices.items.len;
        var i: usize = 0;

        while (i < 5 and self.peek().tag == .choice_marker) {
            const marker = self.token_pos;
            self.next();

            const start: u32 = @intCast(self.str_parts.items.len);
            const len = try self.parseStrPart();

            var goto: NodeIndex = invalid_node;

            if (self.peek().tag == .goto) {
                self.next();
                goto = try self.parseIdent();
            }

            const choice = try self.addNode(.choice, marker, .{
                .choice_list = .{
                    .str = .{ .start = start, .len = len },
                    .goto = goto,
                }
            });

            try self.choices.append(self.allocator, choice);
            i += 1;
        }

        const choices_len: u32 = @intCast(self.choices.items.len - choices_start);
        return choices_len;
    }

    // label = “~” ident block “end”
    fn parseLabel(self: *Parser) Error!NodeIndex {
        _ = self.expect(.tilde);
        const label = try self.parseBlock(.label);
        _ = self.expect(.keyword_end);

        return label;
    }

    // scene = "#" ident block
    fn parseScene(self: *Parser) Error!NodeIndex {
        _ = self.expect(.hash);
        return try self.parseBlock(.scene);
    }

    // block = { stmt } ;
    fn parseBlock(self: *Parser, tag: Tag) Error!NodeIndex {
        const ident_pos = self.expect(.identifier);
        _ = try self.addNode(.identifier, ident_pos, .{
            .identifier = .{ .token = ident_pos }
        });

        const start: u32 = @intCast(self.stmts.items.len);
        const len = try self.parseStmts();

        return try self.addNode(tag, ident_pos, .{
            .block = .{ .start = start, .len = len },
        });
    }

    // ───────────────────────────────
    //           EXPRESSIONS
    // ───────────────────────────────

    fn parseIdent(self: *Parser) Error!NodeIndex {
        const ident_pos = self.expect(.identifier);
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

                _ = self.expect(.close_paren);

                return expr;
            },
            else => return {
                self.reportError(.number, self.peek().tag);
                self.next();
                return invalid_node;
            },
        }
    }
};
