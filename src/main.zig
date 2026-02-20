const std = @import("std");
const tok = @import("token.zig");
const zig_node = @import("node.zig");
const diagnostic = @import("diagnostic.zig");
const tokenizer = @import("tokenizer.zig");
const par = @import("parser.zig");
const sem = @import("semantic.zig");

const Token = tok.Token;
const Tag = tok.Tag;

const Node = zig_node.Node;
const NodeIndex = zig_node.NodeIndex;

const DiagnosticSink = diagnostic.DiagnosticSink;

const Allocator = std.mem.Allocator;
const FILE_NAME = "script.txt";

const TokenList = std.MultiArrayList(Token);

pub fn main() !void {
    var debugAlloc = std.heap.DebugAllocator(.{}){};
    defer _ = debugAlloc.deinit();

    const allocator = debugAlloc.allocator();

    var read_buf: []u8 = undefined;
    read_buf = try allocator.alloc(u8, 200);
    defer allocator.free(read_buf);

    const file = try std.fs.cwd().openFile(FILE_NAME, .{});
    defer file.close();

    var reader = std.fs.File.Reader.init(file, read_buf);
    const reader_inter: *std.Io.Reader = &reader.interface;

    while (reader_inter.takeDelimiterInclusive('\n')) |_| {} else |err| {
        if (err != std.Io.Reader.DelimiterError.EndOfStream) {
            std.debug.print("An Error has occurred {}", .{err});
        }
    }

    const lines = read_buf[0..reader.pos];

    var diag_sink = DiagnosticSink.init(allocator, lines);
    defer diag_sink.deinit();

    // lines => tokens
    var tokenList = try tokenize(allocator, lines);
    defer tokenList.deinit(allocator);

    // tokens => AST of stmt nodes
    var parser = par.Parser.init(&tokenList, &diag_sink);
    defer parser.deinit();

    const parsed_list = try parser.parse();
    defer allocator.free(parsed_list);
    //
    // parser.printStmtNodeTags(parsed_list);
    // parser.printNodeErrors();
    //
    // // AST => proper AST
    // var semantic = sem.Semantic.init(
    //     allocator, lines, parsed_list, 
    //     &parser.nodes, &parser.str_parts, 
    //     &tokenList
    // );
    // defer semantic.deinit();
    //
    // try semantic.analyze();
    // semantic.printAllSemanticError(FILE_NAME);

    diag_sink.printErrors(FILE_NAME);
}

fn tokenize(allocator: Allocator, buf: []const u8) !TokenList {
    var tokenList: std.MultiArrayList(Token) = .{};
    var tokenStream = tokenizer.Tokenizer.init(buf);

    while (tokenStream.index < tokenStream.buffer.len) {
        const token = tokenStream.next();
        if (token.tag == .EOF) break;
        try tokenList.append(allocator, token);
    }

    return tokenList;
}
