const std = @import("std");
const tokenizer = @import("tokenizer.zig");

const Timer = std.time.Timer;

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
    var tokenStream = tokenizer.Tokenizer.init(line);

    while (tokenStream.index < tokenStream.buffer.len) {
        const token = tokenStream.next();

        std.debug.print("Token: {s}\n", .{@tagName(token.tag)});
    }
}
