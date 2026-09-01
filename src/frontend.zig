pub const Tokenizer = @import("frontend/tokenizer.zig").Tokenizer;
pub const token = @import("frontend/token.zig");
pub const node = @import("frontend/node.zig");

// TODO: Add Parser here.
// The issue is Parser requires diagnostic.zig
// But, creating a module for diagnostic will create a circular dependency
// since diagnostic also requires token inside frontend. Thus, we end up with
// diagnostic -> frontend and frontend -> diagnostic.
//
// Two solutions:
// 1) Create a common.zig file and insert diagnostic inside. Then each folder gets a diagnostic.zig
// 2) Make diagnostic not dependent on token import.
//
// I think I want to lean on 2.
//
// For 2, I should create a SourceLocation struct. It contains:
// 1) Error message
// 2) Span
// 3) Row position
// 4) Col position
