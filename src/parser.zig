const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");

const Allocator = std.mem.Allocator;

const NodeIndex = zig_node.NodeIndex;

const Token = tok.Token;
const Tag = tok.Tag;
const TokenList = tok.TokenList;
const TokenIndex = tok.TokenIndex;

const Node = zig_node.Node;
const NodeData = zig_node.NodeData;
const NodeList = zig_node.NodeList;

pub const ParserError = error {
    EndOfTokens,
    UnexpectedToken,
};

const Error = error{ParserError} || Allocator.Error;

// Extended Backus Naur Form:
pub const Parser = struct {
    allocator: Allocator,
    tokens: TokenList,
    nodes: NodeList,
    token_pos: u32,

    pub fn init(allocator: Allocator, tokens: TokenList) Parser {
        return Parser{
            .allocator = allocator,
            .tokens = tokens,
            .nodes = .{},
            .token_pos = 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.nodes.deinit(self.allocator);
    }

    fn peek(self: *Parser) Token {
        const pos = self.token_pos;

        if (pos >= self.tokens.len) {
            return .{ .tag = .EOF, .start = pos, .end = pos };
        }

        return self.tokens.get(pos);
    }

    /// Move to the next token. Does not check for tag.
    fn next(self: *Parser) void {
        if (self.token_pos < self.tokens.len) self.token_pos += 1;
    }

    fn expect(self: *Parser, tag: Tag) Error!TokenIndex {
        const token = self.peek();
        if (token.tag != tag) return Error.ParserError;

        const idx = self.token_pos;
        self.token_pos += 1;
        return idx;
    }

    fn addNode(self: *Parser, tag: Tag, main_token: TokenIndex, data: NodeData) !NodeIndex {
        try self.nodes.append(self.allocator, .{
            .tag = tag,
            .main_token = main_token,
            .data = data,
        });

        const idx: u32 = @intCast(self.nodes.len - 1);
        return idx;
    }

    pub fn printAllNodeTags(self: *Parser) void {
        for (0..self.nodes.len) |i| {
            std.debug.print("Node Tag: {s}\n", .{@tagName(self.nodes.get(i).tag)});
        }
    }

    pub fn parse(self: *Parser) !void {
        while (self.token_pos < self.tokens.len and self.peek().tag != .EOF) {
            _ = try self.parseStmt();
        }
    }


    // ───────────────────────────────
    //           STATEMENTS
    // ───────────────────────────────

    fn parseStmt(self: *Parser) Error!NodeIndex {
        return switch (self.peek().tag) {
            .Identifier => self.parseIdentStmt(),
            .If => self.parseIfStmt(),
            else => return Error.ParserError,
        };
    }

    // assign_stmt = ident “=” expr ;
    // compound_stmt = ident ( "+=" | "-=" | "*=" | "/=" ) expr ;
    fn parseIdentStmt(self: *Parser) Error!NodeIndex {
        const ident_pos = self.token_pos;
        self.next();

        const next_tag = self.peek().tag;

        return switch (next_tag) {
            .Assign, .Plus_Equal, .Minus_Equal,
            .Asterisk_Equal, .Slash_Equal => self.parseAssignStmt(next_tag, ident_pos),
            .Colon => try self.parseDialogue(ident_pos),
            else => return Error.ParserError,
        };
    }

    fn parseAssignStmt(self: *Parser, assign_tag: Tag, ident_pos: NodeIndex) Error!NodeIndex {
        const assign_pos = self.token_pos;
        self.next();

        const expr = try self.parseExpr();

        const ident_node = try self.addNode(.Identifier, ident_pos, .{
            .identifier = .{ .token = ident_pos },
        });

        return try self.addNode(assign_tag, assign_pos, .{
            .assign = .{
                .target = ident_node,
                .value = expr,
            }
        });
    }

    // if_stmt = if compar_expr block [ else_block ] ;
    fn parseIfStmt(self: *Parser) Error!NodeIndex {
        const if_pos = try self.expect(.If);
        _ = try self.expect(.Open_Paren);

        const condition = try self.parseCompareExpr();

        _ = try self.expect(.Close_Paren);

        const then_pos = self.token_pos;

        const then = try self.parseBlock();
        defer self.allocator.free(then);

        const then_block = try self.addNode(.Then_Block, then_pos, .{
            .block = .{ .stmts = then }
        });

        var else_block: ?NodeIndex = null;

        if (self.peek().tag == .Else) {
            const else_pos = self.token_pos;
            const else_stmts = try self.parseElseBlock();
            defer self.allocator.free(else_stmts);

            else_block = try self.addNode(.Else_Block, else_pos, .{
                .block = .{ .stmts = else_stmts }
            });
        }

        return self.addNode(.If, if_pos, .{
            .if_stmt = .{
                .condition = condition,
                .then_block = then_block,
                .else_block = else_block,
            }
        });
    }

    // compar_expr = "(" expr compar_op expr ")" ;
    // compar_op = "==" | "!=" | "<" | ">" | "<=" | ">=" | “(” boolean “)” ;
    fn parseCompareExpr(self: *Parser) Error!NodeIndex {
        const left_expr = try self.parseExpr();

        const compare_tag: Error!Tag = switch (self.peek().tag) {
            .Equals => .Equals,
            .Not_Equal => .Not_Equal,
            .Less => .Less,
            .Greater => .Greater,
            .Less_or_Equal => .Less_or_Equal,
            .Greater_or_Equal => .Greater_or_Equal,
            else => Error.ParserError,
        };
        const compare_token = self.token_pos;
        self.next();

        const right_expr = try self.parseExpr();

        return self.addNode(try compare_tag, compare_token, .{
            .binary = .{ .lhs = left_expr, .rhs = right_expr },
        });
    }

    // block = "{" stmt_list "}" ;
    // stmt_list = { scene_stmt } ;
    fn parseBlock(self: *Parser) Error![]NodeIndex {
        _ = try self.expect(.Open_Brace);

        var stmts = try std.ArrayList(NodeIndex).initCapacity(self.allocator, 5);

        while (self.peek().tag != .Close_Brace and self.peek().tag != .EOF) {
            const stmt = try self.parseStmt();
            try stmts.append(self.allocator, stmt);
        }

        _ = try self.expect(.Close_Brace);

        return try stmts.toOwnedSlice(self.allocator);
    }

    // else_block = "else" block ;
    fn parseElseBlock(self: *Parser) Error![]NodeIndex {
        _ = try self.expect(.Else);
        return try self.parseBlock();
    }

    // ───────────────────────────────
    //           DIALOGUE
    // ───────────────────────────────

    // dialogue = identifier ":" string ;
    // string = string_part { string_part } [ "->" ident ] ;
    fn parseDialogue(self: *Parser, ident_pos: TokenIndex) Error!NodeIndex {
        _ = try self.expect(.Colon);

        const str_part = try self.parseStrPart();
        defer self.allocator.free(str_part);

        var goto: ?TokenIndex = null;
        var choices: ?[]NodeIndex = null;

        if (self.peek().tag == .Goto) {
            self.next();
            goto = try self.expect(.Identifier);
        }

        if (self.peek().tag == .Choice_Marker) {
            choices = try self.parseChoices();
        }

        return try self.addNode(.Dialogue, ident_pos, .{
            .dialogue = .{ .string = str_part, .goto = goto, .choices = choices },
        });
    }

    // string_part = content_part | interpolation ;
    // content_part = content { content } ;
    // interpolation = "{" expr "}" ;
    // content = any_character_except("{", "}", "\n") ;
    fn parseStrPart(self: *Parser) Error![]NodeIndex {
        var str_list = try std.ArrayList(NodeIndex).initCapacity(self.allocator, 4);

        while (true) {
            const tag = self.peek().tag;

            switch (tag) {
                .String => {
                    const str = try self.addNode(.String, self.token_pos, .{
                        .string = .{ .token = self.token_pos },
                    });

                    try str_list.append(self.allocator, str);
                    self.next();
                },
                .Inter_Open => {
                    self.next();
                    const ident = try self.addNode(.Identifier, self.token_pos, .{
                        .identifier = .{ .token = self.token_pos }
                    });

                    self.next();
                    _ = try self.expect(.Inter_Close);

                    try str_list.append(self.allocator, ident);
                },
                else => break,
            }
        }

        return try str_list.toOwnedSlice(self.allocator);
    }

    // choice = { "*" string } (MIN = 2, MAX = 5)
    fn parseChoices(self: *Parser) Error![]NodeIndex {
        const MAX_CHOICES_SIZE = 5;
        var i: usize = 0;
        var goto: ?NodeIndex = null;
        var choices: [MAX_CHOICES_SIZE]NodeIndex = undefined;

        while (i < MAX_CHOICES_SIZE and self.peek().tag == .Choice_Marker) : (i += 1) {
            const marker = self.token_pos;
            self.next();

            const str = try self.parseStrPart();
            defer self.allocator.free(str);

            goto = null;

            if (self.peek().tag == .Goto) {
                self.next();
                goto = try self.expect(.Identifier);
            }

            const choice = try self.addNode(.Choice, marker, .{
                .choice_list = .{ .string = str, .goto = goto }
            });

            choices[i] = choice;
        }

        return &choices;
    }

    // ───────────────────────────────
    //           EXPRESSIONS
    // ───────────────────────────────

    // expr = term { ( "+" | "-" ) term } ;
    fn parseExpr(self: *Parser) Error!NodeIndex {
        var node = try self.parseTerm();

        while (true) {
            switch (self.peek().tag) {
                .Plus, .Minus => {
                    const tag = self.peek().tag;
                    const op_tok = self.token_pos;
                    self.next();

                    const rhs = try self.parseTerm();

                    node = try self.addNode(tag, op_tok, .{
                        .binary = .{
                            .lhs = node,
                            .rhs = rhs,
                        }
                    });
                },
                else => break,
            }
        }

        return node;
    }

    // term = factor { ( "*" | "/" ) factor } ;
    fn parseTerm(self: *Parser) Error!NodeIndex {
        var node = try self.parseFactor();

        while (true) {
            switch (self.peek().tag) {
                .Asterisk, .Slash => {
                    const tag = self.peek().tag;
                    const op_tok = self.token_pos;
                    self.next();

                    const rhs = try self.parseFactor();

                    node = try self.addNode(tag, op_tok, .{
                        .binary = .{
                            .lhs = node,
                            .rhs = rhs,
                        }
                    });
                },
                else => break,
            }
        }

        return node;
    }

    // factor = number | ident | "(" expr ")" ;
    fn parseFactor(self: *Parser) Error!NodeIndex {
        const token = self.peek();
        const idx = self.token_pos;

        switch (token.tag) {
            // TODO: Make sure the number is not larger than u8
            .Number => {
                self.next();
                return self.addNode(.Number, idx, .{
                    .number = .{ .token = idx }
                });
            },
            .Identifier => {
                self.next();
                return self.addNode(.Identifier, idx, .{
                    .identifier = .{ .token = idx }
                });
            },
            .Open_Paren => {
                self.next();
                const expr = try self.parseExpr();

                _ = try self.expect(.Close_Paren);

                return expr;
            },
            else => return Error.ParserError,
        }
    }
};
