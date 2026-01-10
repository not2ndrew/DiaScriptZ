const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");

const Allocator = std.mem.Allocator;

const NodeIndex = zig_node.NodeIndex;
const TokenIndex = tok.TokenIndex;

const Token = tok.Token;
const Tag = tok.Tag;

const Node = zig_node.Node;
const NodeData = zig_node.NodeData;
const ChoiceList = zig_node.ChoiceList;

pub const ParserError = error {
    EndOfTokens,
    UnexpectedToken,
};

const Error = error{ParserError} || Allocator.Error;

// Extended Backus Naur Form:
pub const Parser = struct {
    allocator: Allocator,
    tokens: *const std.MultiArrayList(Token),
    nodes: std.MultiArrayList(Node),
    token_pos: u32,

    pub fn init(allocator: Allocator, tokens: *const std.MultiArrayList(Token)) Parser {
        return Parser{
            .allocator = allocator,
            .tokens = tokens,
            .nodes = .{},
            .token_pos = 0,
        };
    }

    pub fn deinit(self: *Parser) void {
        for (0..self.nodes.len) |i| {
            self.deinitNode(self.nodes.get(i));
        }
        self.nodes.deinit(self.allocator);
    }

    fn deinitNode(self: *Parser, node: Node) void {
        switch (node.data) {
            .block => |b| {
                self.allocator.free(b.stmts);
            },
            .dialogue => |d| {
                self.allocator.free(d.string);
                if (d.choices) |choices| {
                    for (choices.items[0..choices.len]) |choice_pos| {
                        const choice = self.nodes.get(choice_pos);
                        self.deinitNode(choice);
                    }
                }
            },
            .choice_list => |c| {
                self.allocator.free(c.string);
            },
            else => {},
        }
    }

    inline fn peek(self: *Parser) Token {
        const pos = self.token_pos;

        if (pos >= self.tokens.len) {
            return .{ .tag = .EOF, .start = pos, .end = pos };
        }

        return self.tokens.get(pos);
    }

    /// Move to the next token. Does not check for tag.
    inline fn next(self: *Parser) void {
        if (self.token_pos < self.tokens.len) self.token_pos += 1;
    }

    inline fn expect(self: *Parser, tag: Tag) Error!TokenIndex {
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

    pub fn parse(self: *Parser) !std.MultiArrayList(Node) {
        while (self.token_pos < self.tokens.len and self.peek().tag != .EOF) {
            _ = try self.parseStmt();
        }

        return self.nodes;
    }


    // ───────────────────────────────
    //           STATEMENTS
    // ───────────────────────────────

    fn parseStmt(self: *Parser) Error!NodeIndex {
        return switch (self.peek().tag) {
            .Const, .Var => self.parseDeclar(),
            .Identifier, .Underscore => self.parseIdentStmt(),
            .If => self.parseIfStmt(),
            .Tilde => self.parseLabel(),
            .Hash => self.parseScene(),
            else => return Error.ParserError,
        };
    }

    // const_stmt = "const" ident "=" expr
    // var_stmt = "var" ident "=" expr
    fn parseDeclar(self: *Parser) Error!NodeIndex {
        const decl = self.peek().tag;
        var decl_type: NodeData = undefined;
        self.next();

        const ident = try self.parseIdent();
        _ = try self.parseAssignStmt(.Assign, ident);

        if (decl == .Const) {
            decl_type = .{
                .const_decl = .{ .name = self.token_pos, .value = ident }
            };
        } else {
            decl_type = .{
                .var_decl = .{ .name = self.token_pos, .value = ident }
            };
        }

        return try self.addNode(decl, self.token_pos, decl_type);
    }

    // compound_stmt = ident ( "=" | "+=" | "-=" | "*=" | "/=" ) expr ;
    fn parseIdentStmt(self: *Parser) Error!NodeIndex {
        const ident_pos = try self.parseIdent();

        const next_tag = self.peek().tag;

        return switch (next_tag) {
            .Assign, .Plus_Equal, .Minus_Equal,
            .Asterisk_Equal, .Slash_Equal => self.parseAssignStmt(next_tag, ident_pos),
            .Colon => try self.parseDialogue(ident_pos),
            else => return Error.ParserError,
        };
    }

    fn parseAssignStmt(self: *Parser, assign_tag: Tag, ident_pos: NodeIndex) Error!NodeIndex {
        const assign_pos = try self.expect(assign_tag);
        const expr = try self.parseExpr();

        return try self.addNode(assign_tag, assign_pos, .{
            .assign = .{
                .target = ident_pos,
                .value = expr,
            }
        });
    }

    // if_stmt = "if" "(" compar_expr ")" "{" block "}" [ else_block ] ;
    fn parseIfStmt(self: *Parser) Error!NodeIndex {
        const if_pos = try self.expect(.If);
        var else_block: ?NodeIndex = null;

        _ = try self.expect(.Open_Paren);

        const condition = try self.parseCompareExpr();

        _ = try self.expect(.Close_Paren);
        _ = try self.expect(.Open_Brace);

        const then_pos = self.token_pos;

        const then = try self.parseStmts();

        _ = try self.expect(.Close_Brace);

        const then_block = try self.addNode(.Then_Block, then_pos, .{
            .block = .{ .stmts = then }
        });

        if (self.peek().tag == .Else) {
            const else_pos = self.token_pos;
            const else_stmts = try self.parseElseBlock();

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

    // compar_expr = expr compar_op expr ;
    // compar_op = "==" | "!=" | "<" | ">" | "<=" | ">=" ;
    fn parseCompareExpr(self: *Parser) Error!NodeIndex {
        const left_expr = try self.parseExpr();

        const op_tag = self.peek().tag;

        const compare_tag: Error!Tag = switch (op_tag) {
            .Equals, .Not_Equal, .Less,
            .Greater, .Less_or_Equal,
            .Greater_or_Equal => op_tag,
            else => Error.ParserError,
        };

        const compare_token = self.token_pos;
        self.next();

        const right_expr = try self.parseExpr();

        return self.addNode(try compare_tag, compare_token, .{
            .binary = .{ .lhs = left_expr, .rhs = right_expr },
        });
    }

    // else_block = "else" "{" stmts "}";
    fn parseElseBlock(self: *Parser) Error![]NodeIndex {
        _ = try self.expect(.Else);
        _ = try self.expect(.Open_Brace);
        const else_block = try self.parseStmts();
        _ = try self.expect(.Close_Brace);
        return else_block;
    }

    // stmts = { stmt } ;
    fn parseStmts(self: *Parser) Error![]NodeIndex {
        var stmts = try std.ArrayList(NodeIndex).initCapacity(self.allocator, 5);

        while (self.token_pos < self.tokens.len) {
            switch (self.peek().tag) {
                .Close_Brace, .End, .Hash => break,
                else => {
                    const stmt = try self.parseStmt();
                    try stmts.append(self.allocator, stmt);
                }
            }
        }

        return try stmts.toOwnedSlice(self.allocator);
    }

    // ───────────────────────────────
    //           DIALOGUE
    // ───────────────────────────────

    // dialogue = identifier ":" string ;
    // string = string_part { string_part } [ "->" ident ] ;
    fn parseDialogue(self: *Parser, ident_pos: TokenIndex) Error!NodeIndex {
        _ = try self.expect(.Colon);

        const str_part = try self.parseStrPart();

        var goto: ?NodeIndex = null;
        var choices: ?ChoiceList = null;

        if (self.peek().tag == .Goto) {
            self.next();

            goto = try self.parseIdent();
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
    // interpolation = "{" ident "}" ;
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
                    const ident = try self.parseIdent();

                    _ = try self.expect(.Inter_Close);

                    try str_list.append(self.allocator, ident);
                },
                else => break,
            }
        }

        return try str_list.toOwnedSlice(self.allocator);
    }

    // choice = { "*" string } (MIN = 2, MAX = 5)
    fn parseChoices(self: *Parser) Error!ChoiceList {
        var list = ChoiceList{};

        while (list.len < 5 and self.peek().tag == .Choice_Marker) {
            const marker = self.token_pos;
            self.next();

            const str = try self.parseStrPart();

            var goto: ?NodeIndex = null;

            if (self.peek().tag == .Goto) {
                self.next();
                goto = try self.parseIdent();
            }

            const choice = try self.addNode(.Choice, marker, .{
                .choice_list = .{ .string = str, .goto = goto }
            });

            list.items[list.len] = choice;
            list.len += 1;
        }

        return list;
    }

    // label = “~” ident block “end”
    fn parseLabel(self: *Parser) Error!NodeIndex {
        _ = try self.expect(.Tilde);
        const label = try self.parseBlock(.Label);
        _ = try self.expect(.End);

        return label;
    }

    // scene = "#" ident block
    fn parseScene(self: *Parser) Error!NodeIndex {
        _ = try self.expect(.Hash);
        return try self.parseBlock(.Scene);
    }

    // block = { stmt } ;
    fn parseBlock(self: *Parser, tag: Tag) Error!NodeIndex {
        const ident_pos = try self.expect(.Identifier);
        _ = try self.addNode(.Identifier, ident_pos, .{
            .identifier = .{ .token = ident_pos }
        });

        const stmts = try self.parseStmts();

        return try self.addNode(tag, ident_pos, .{
            .block = .{ .stmts = stmts },
        });
    }

    // ───────────────────────────────
    //           EXPRESSIONS
    // ───────────────────────────────

    fn parseIdent(self: *Parser) Error!NodeIndex {
        const ident_pos = try self.expect(.Identifier);
        return try self.addNode(.Identifier, ident_pos, .{
            .identifier = .{ .token = ident_pos }
        });
    }

    // expr = term { ( "+" | "-" ) term } ;
    fn parseExpr(self: *Parser) Error!NodeIndex {
        var node = try self.parseTerm();

        while (true) {
            const tag = self.peek().tag;

            if (tag != .Plus and tag != .Minus) break;

            const op_tok = self.token_pos;
            self.next();

            const rhs = try self.parseTerm();

            node = try self.addNode(tag, op_tok, .{
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

            if (tag != .Asterisk and tag != .Slash) break;

            const op_tok = self.token_pos;
            self.next();

            const rhs = try self.parseFactor();

            node = try self.addNode(tag, op_tok, .{
                .binary = .{ .lhs = node, .rhs = rhs }
            });
        }

        return node;
    }

    // factor = number | ident | "(" expr ")" ;
    fn parseFactor(self: *Parser) Error!NodeIndex {
        const idx = self.token_pos;

        switch (self.peek().tag) {
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
