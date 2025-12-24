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

// Backus Naur Form:

// This Parser uses a Recursive Decent.
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
            .Const, .Var => self.parseDeclarStmt(),
            .Identifier => self.parseAssignStmt(),
            .If => self.parseIfStmt(),
            else => Error.ParserError,
        };
    }

    // <declar_stmt> ::= ("const" | "var") <ident> "=" <expr>
    fn parseDeclarStmt(self: *Parser) Error!NodeIndex {
        const declar_pos = self.token_pos;
        const declar_tag = self.tokens.get(declar_pos).tag;

        self.next(); // Consume const or var

        const ident_pos = self.token_pos;
        self.next(); // Consume Identifier

        const assign_pos = try self.expect(.Assign);
        const expr = try self.parseExpr();

        const ident_node = try self.addNode(.Identifier, ident_pos, .{
            .identifier = .{ .token = ident_pos },
        });

        const assign_node = try self.addNode(.Assign, assign_pos, .{
            .assign = .{
                .target = ident_node,
                .value = expr,
            }
        });

        return try self.addNode(declar_tag, declar_pos, .{
            .declar = .{
                .kind = declar_tag,
                .assign = assign_node,
            }
        });
    }

    // <assign_stmt> ::= <ident> "=" <expr>
    // <compound_stmt> ::= <ident> ( "+=" | "-=" | "*=" | "/=" ) <expr>
    fn parseAssignStmt(self: *Parser) Error!NodeIndex {
        const ident_pos = self.token_pos;
        self.next(); // Consume Identifier

        const assign_type: Error!Tag = switch (self.peek().tag) {
            .Assign => .Assign,
            .Plus_Equals => .Plus_Equals,
            .Minus_Equals => .Minus_Equals,
            .Asterisk_Equals => .Asterisk_Equals,
            .Slash_Equals => .Slash_Equals,
            else => return Error.ParserError,
        };

        const assign_pos = self.token_pos;
        self.next();// Consume assign

        const expr = try self.parseExpr();

        const ident_node = try self.addNode(.Identifier, ident_pos, .{
            .identifier = .{ .token = ident_pos },
        });

        return try self.addNode(try assign_type, assign_pos, .{
            .assign = .{
                .target = ident_node,
                .value = expr,
            }
        });
    }
    // <if_stmt> ::= if <compar_expr> <then_block> <else_blck>
    fn parseIfStmt(self: *Parser) Error!NodeIndex {
        const if_pos = try self.expect(.If); // Consume "if"
        _ = try self.expect(.Open_Paren); // Consume "("

        const condition = try self.parseCompareExpr();

        _ = try self.expect(.Close_Paren); // Consume ")"

        const then = try self.parseBlock(.Then_Block);

        var else_blck: ?NodeIndex = null;

        if (self.peek().tag == .Else) {
            else_blck = try self.parseElseBlock();
        }

        return self.addNode(.If, if_pos, .{
            .if_stmt = .{
                .condition = condition,
                .then_blck = then,
                .else_blck = else_blck,
            }
        });
    }

    // <compar_expr> ::= "(" <expr> <compar_op> <expr> ")"
    // <compar_op> ::= "==" | "!=" | "<" | ">" | "<=" | ">="
    fn parseCompareExpr(self: *Parser) Error!NodeIndex {
        const left_expr = try self.parseExpr();

        const compare_tag: Error!Tag = switch (self.peek().tag) {
            .Equals => .Equals,
            .Not_Equals => .Not_Equals,
            .Less => .Less,
            .Greater => .Greater,
            .Less_or_Equal => .Less_or_Equal,
            .Greater_or_Equal => .Greater_or_Equal,
            else => Error.ParserError,
        };
        const compare_token = self.token_pos;
        self.next(); // Consume <compar_op> 

        const right_expr = try self.parseExpr();

        return self.addNode(try compare_tag, compare_token, .{
            .binary = .{ .lhs = left_expr, .rhs = right_expr },
        });
    }

    // <block> ::= "{" <stmt_list> "}"
    // <stmt_list> ::= epsilon | <stmt> | <stmt> <stmt_list>
    fn parseBlock(self: *Parser, block: Tag) Error!NodeIndex {
        const open_brace = try self.expect(.Open_Brace);

        // No need deinit since we are freeing the slice created by allocator.
        var stmts: std.ArrayList(NodeIndex) = try std.ArrayList(NodeIndex).initCapacity(self.allocator, 5);
        // defer stmts.deinit(self.allocator);

        while (self.peek().tag != .Close_Brace and self.peek().tag != .EOF) {
            const stmt = try self.parseStmt();
            try stmts.append(self.allocator, stmt);
        }

        _ = try self.expect(.Close_Brace);

        const slice = try stmts.toOwnedSlice(self.allocator);
        defer self.allocator.free(slice);

        return try self.addNode(block, open_brace, .{ 
            .block = .{ .statements = slice },
        });
    }

    fn parseElseBlock(self: *Parser) Error!NodeIndex {
        _ = try self.expect(.Else);
        return try self.parseBlock(.Else_Block);
    }

    // ───────────────────────────────
    //           EXPRESSIONS
    // ───────────────────────────────

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

    // <Term> ::= <Factor> ('*' | '/') <Factor>
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

    // <Factor> ::= <Number> | <Identifier>
    fn parseFactor(self: *Parser) Error!NodeIndex {
        const token = self.peek();
        const idx = self.token_pos;

        switch (token.tag) {
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
