const std = @import("std");
const compileFile = @import("compile.zig").compileFile;

const Allocator = std.mem.Allocator;
const FILE_NAME = "script.txt";

pub fn main() !void {
    var debugAlloc = std.heap.DebugAllocator(.{}){};
    defer _ = debugAlloc.deinit();
    const allocator = debugAlloc.allocator();

    try compileFile(allocator, FILE_NAME);
}
