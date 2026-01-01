const std = @import("std");
const tok = @import("token.zig");
const tokenizer = @import("tokenizer.zig");
const par = @import("parser.zig");

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

    var tokenList = try tokenize(allocator, read_buf[0..reader.pos]);
    defer tokenList.deinit(allocator);

    var parser = par.Parser.init(allocator, tokenList);
    defer parser.deinit();

    try parser.parse();
    parser.printAllNodeTags();
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
