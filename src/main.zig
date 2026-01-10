const std = @import("std");
const tok = @import("token.zig");
const tokenizer = @import("tokenizer.zig");
const par = @import("parser.zig");
const sem = @import("semantic.zig");

const Token = tok.Token;
const Tag = tok.Tag;

const FILE_NAME = "script.txt";

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

    // lines => tokens
    var tokenList = try tokenize(allocator, lines);
    defer tokenList.deinit(allocator);

    var parser = par.Parser.init(allocator, &tokenList);
    defer parser.deinit();

    // tokens => AST
    _ = try parser.parse();
    // const parsedList = try parser.parse();
    parser.printAllNodeTags();

    // AST => proper AST
    // var semantic = sem.Semantic.init(allocator, lines, &parsedList, &tokenList);
    // defer semantic.deinit();
    //
    // semantic.analyze();
}

fn tokenize(allocator: std.mem.Allocator, buf: []const u8) !std.MultiArrayList(Token) {
    var tokenList: std.MultiArrayList(Token) = .{};
    var tokenStream = tokenizer.Tokenizer.init(buf);

    while (tokenStream.index < tokenStream.buffer.len) {
        const token = tokenStream.next();
        if (token.tag == .EOF) break;
        try tokenList.append(allocator, token);
        std.debug.print("Token: {s} \n", .{@tagName(token.tag)});
    }

    return tokenList;
}
