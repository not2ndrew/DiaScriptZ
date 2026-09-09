const std = @import("std");
const compileFile = @import("compile.zig").compileFile;
const runProgram = @import("runtime.zig").runProgram;

const Allocator = std.mem.Allocator;
const Init = std.process.Init;

const Io = std.Io;
const DelimiterError = Io.Reader.DelimiterError;

const FILE_NAME = "script.txt";

pub fn main(init: Init) !void {
    const source = try readFile(init, FILE_NAME);
    defer init.gpa.free(source);

    var ir = compileFile(init, source, FILE_NAME) catch |err| switch (err) {
        error.ParseError, error.SemanticError => return,
        else => return err,
    };
    defer ir.deinit(init.gpa);

    // Based on ir, we can assume there are no compile time errors.
    // However, there can exist runtime errors. If we do encounter
    // a single runtime error, then we must abort the program immediately.
    // runProgram(init.io, init.gpa, ir);
}

/// Make sure to free the []const u8 result!!!
fn readFile(init: Init, file_name: []const u8) ![]const u8 {
    const io = init.io;
    var source: []u8 = undefined;

    const file = try Io.Dir.cwd().openFile(io, file_name, .{});
    defer file.close(io);

    const length = try file.length(io);
    if (length == 0) return DelimiterError.ReadFailed;

    source = try init.gpa.alloc(u8, length);

    var reader = Io.File.Reader.init(file, io, source);
    const reader_inter: *Io.Reader = &reader.interface;
    const EndOfStream = DelimiterError.EndOfStream;

    while (reader_inter.takeDelimiterInclusive('\n')) |_| {} else |err| {
        if (err != EndOfStream) {
            std.debug.print("An Error has occurred {}", .{err});
        }
    }

    return source;
}
