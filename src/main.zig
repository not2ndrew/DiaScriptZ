const std = @import("std");
const tok = @import("token.zig");
const tokenizer = @import("tokenizer.zig");
const par = @import("parser.zig");

const Token = tok.Token;

const FILE_NAME = "script.txt";
var write_buf: []u8 = undefined;

pub fn main() !void {
    var debugAlloc = std.heap.DebugAllocator(.{}){};
    defer _ = debugAlloc.deinit();

    const allocator = debugAlloc.allocator();

    write_buf = try allocator.alloc(u8, 100);
    defer allocator.free(write_buf);

    // Start lexer
    const file = try std.fs.cwd().openFile(FILE_NAME, .{});
    defer file.close();

    var reader = std.fs.File.Reader.init(file, write_buf);

    const line = try reader.interface.takeDelimiterInclusive('\n');
    var tokenStream = tokenizer.Tokenizer.init(allocator, line);
    defer tokenStream.deinit();

    try tokenStream.tokenize();

    var parser = par.Parser.init(allocator, line, tokenStream.tokenList);
    defer parser.deinit();

    try parser.parse();
    parser.printAllNodeTags();
}
