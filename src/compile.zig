const std = @import("std");
const Token = @import("token.zig").Token;
const Node = @import("node.zig").Node;
const DiagnosticSink = @import("diagnostic.zig").DiagnosticSink;
const tokenizer = @import("tokenizer.zig");
const Parser = @import("parser.zig").Parser;
const Semantic = @import("semantic.zig").Semantic;

const Allocator = std.mem.Allocator;

pub fn compileFile(allocator: Allocator, file_name: []const u8) !void {
    const lines = try readFile(allocator, file_name);
    defer allocator.free(lines);

    var diag_sink = DiagnosticSink.init(allocator, lines);
    defer diag_sink.deinit();

    // lines => tokens
    var tokenList = try tokenize(allocator, lines);
    defer tokenList.deinit(allocator);

    // tokens => AST of stmt nodes
    var parser = try Parser.init(&tokenList, &diag_sink);
    defer parser.deinit();

    const parsed_list = try parser.parse();
    defer allocator.free(parsed_list);

    // AST => proper AST
    var semantic = Semantic.init(
        &diag_sink, parsed_list,
        &parser.nodes, &tokenList
    );
    defer semantic.deinit();

    try semantic.analyze();

    diag_sink.printErrors(file_name);
}

/// Make sure to free memory from the string!!!
fn readFile(allocator: Allocator, file_name: []const u8) ![]const u8 {
    var read_buf: []u8 = undefined;

    const file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();

    const stat = try file.stat();
    const size = stat.size;
    read_buf = try allocator.alloc(u8, size);

    var reader = std.fs.File.Reader.init(file, read_buf);
    const reader_inter: *std.Io.Reader = &reader.interface;

    while (reader_inter.takeDelimiterInclusive('\n')) |_| {} else |err| {
        if (err != std.Io.Reader.DelimiterError.EndOfStream) {
            std.debug.print("An Error has occurred {}", .{err});
        }
    }

    return read_buf[0..reader.pos];
}

fn tokenize(allocator: Allocator, buf: []const u8) !std.MultiArrayList(Token) {
    var tokenList: std.MultiArrayList(Token) = .{};
    errdefer tokenList.deinit(allocator);

    var tokens = tokenizer.Tokenizer.init(buf);

    while (true) {
        const token = tokens.next();
        try tokenList.append(allocator, token);
        if (token.tag == .EOF) break;
    }

    return tokenList;
}
