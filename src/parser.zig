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

// Backus Naur Form:
// <if_stmt> ::= "if" "(" <expr>  <comparison> <expr> ")"
// <comparison> ::= "==", "!=", "<", ">", "<=", ">="
// <dialogue> ::= <ident> : <string_literal>

// This Parser uses a Recursive Decent.
// Not Pratt Parsing.
pub const Parser = struct {
    allocator: Allocator,
    // Source may not be needed.
    // No reason to get string when we already have indicies from Token.
    source: []const u8,
    tokens: TokenList,
    nodes: NodeList,
    token_pos: u32,

    pub fn init(allocator: Allocator, source: []const u8, tokens: TokenList) Parser {
        return Parser{
            .allocator = allocator,
            .source = source,
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

    fn expect(self: *Parser, tag: Tag) !TokenIndex {
        const token = self.peek();
        if (token.tag != tag) return ParserError.UnexpectedToken;

        self.token_pos += 1;
        return self.token_pos;
    }

    fn addNode(self: *Parser, tag: Tag, main_token: TokenIndex, data: NodeData) !NodeIndex {
        try self.nodes.append(self.allocator, .{
            .tag = tag,
            .main_token = main_token,
            .data = data,
        });

        const idx: u32 = @intCast(self.nodes.len);
        return idx;
    }

    pub fn printAllNodeTags(self: *Parser) void {
        for (0..self.nodes.len) |i| {
            std.debug.print("Node Tag: {s}\n", .{@tagName(self.nodes.get(i).tag)});
        }
    }

    pub fn parse(self: *Parser) !void {
        while (self.token_pos < self.tokens.len) {
            _ = try self.parseStmt();
        }
    }

    // ───────────────────────────────
    //           STATEMENTS
    // ───────────────────────────────

    fn parseStmt(self: *Parser) !NodeIndex {
        const tag = self.tokens.get(self.token_pos).tag;

        switch (tag) {
            .Const, .Var => return self.parseDeclarStmt(),
            else => return ParserError.UnexpectedToken,
        }
    }

    // <declar_stmt> ::= ("const" | "var") <ident> "=" <expr>
    fn parseDeclarStmt(self: *Parser) !NodeIndex {
        const decl_tok = self.token_pos;
        self.next(); // Consume const or var

        // Consume Identifier
        const ident_tok = try self.expect(.Identifier);

        // Consume "="
        _ = try self.expect(.Assign);

        const expr = try self.parseExpr();

        const ident_node = try self.addNode(.Identifier, ident_tok, .{
            .identifier = .{ .token = ident_tok },
        });

        return try self.addNode(.Assign, decl_tok, .{
            .assign = .{
                .target = ident_node,
                .value = expr,
            }
        });
    }

    // This is for the actual dialogue scripts.
    //
    // Example:
    //
    // Player: "I got a few choices here"
    //     "Take the risky route"
    //     "Take the safe route"
    fn parseChoice() !void {}

    // ───────────────────────────────
    //           EXPRESSIONS
    // ───────────────────────────────

    fn parseExpr(self: *Parser) !NodeIndex {
        var node = try self.parseTerm();
        while (true) {
            const tag = self.peek().tag;

            switch (tag) {
                .Plus, .Minus => {
                    const op_tok = self.token_pos; 
                    self.next();

                    const rhs = try self.parseTerm();

                    node = try self.addNode(.binary, op_tok, .{
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

    fn parseTerm(self: *Parser) !NodeIndex {
        var node = try self.parseFactor();

        while (true) {
            const tag = self.peek().tag;

            switch (tag) {
                .Asterisk, .Slash => {
                    const op_tok = self.token_pos;
                    self.next();

                    const rhs = try self.parseFactor();

                    node = try self.addNode(.binary, op_tok, .{
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

    fn parseFactor(self: *Parser) !NodeIndex {
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
            else => return ParserError.UnexpectedToken,
        }
    }

};
