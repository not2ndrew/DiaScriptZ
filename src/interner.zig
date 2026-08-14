const std = @import("std");

const Allocator = std.mem.Allocator;

pub const IdentId = u32;

pub const Span = struct {
    start: u32,
    len: u32,
};

// Inst in DiaIR will be responsible for ownership of IdentIds.
// To get the id, we need the Interner table.
pub const InternPool = struct {
    bytes: []const u8,
    ident_spans: []Span,
    texts: []const u8,
    text_spans: []Span,

    pub fn deinit(self: *InternPool, allocator: Allocator) void {
        allocator.free(self.bytes);
        allocator.free(self.ident_spans);
        allocator.free(self.texts);
        allocator.free(self.text_spans);
    }

    pub fn getIdent(self: *InternPool, id: IdentId) []const u8 {
        const span = self.ident_spans[id];
        return self.bytes[span.start .. span.start + span.len];
    }

    pub fn getText(self: *InternPool, id: IdentId) []const u8 {
        const span = self.text_spans[id];
        return self.texts[span.start .. span.start + span.len];
    }
};

pub const Interner = @This();

// Ident_table is global hashmap for all identifiers such as:
// 1) declaration variables
// 2) dialogue speakers
// 3) label names
table: std.array_hash_map.String(IdentId) = .empty,
bytes: std.ArrayList(u8) = .empty,
ident_spans: std.ArrayList(Span) = .empty,

// texts is for dialogue lines.
texts: std.ArrayList(u8) = .empty,
text_spans: std.ArrayList(Span) = .empty,

pub fn deinit(self: *Interner, allocator: Allocator) void {
    self.table.deinit(allocator);
    self.bytes.deinit(allocator);
    self.ident_spans.deinit(allocator);
    self.texts.deinit(allocator);
    self.text_spans.deinit(allocator);
}

pub fn finalize(self: *Interner, allocator: Allocator) !InternPool {
    return .{
        .bytes = try self.bytes.toOwnedSlice(allocator),
        .ident_spans = try self.ident_spans.toOwnedSlice(allocator),
        .texts = try self.texts.toOwnedSlice(allocator),
        .text_spans = try self.text_spans.toOwnedSlice(allocator),
    };
}

pub fn intern(self: *Interner, allocator: Allocator, name: []const u8) !IdentId {
    const result = try self.table.getOrPut(allocator, name);

    if (result.found_existing)
    return result.value_ptr.*;

    const id: IdentId = @intCast(self.ident_spans.items.len);
    result.value_ptr.* = id;

    const start: u32 = @intCast(self.bytes.items.len);
    const len: u32 = @intCast(name.len);

    try self.ident_spans.append(allocator, .{
        .start = start,
        .len = len,
    });
    try self.bytes.appendSlice(allocator, name);

    return id;
}

// TODO: Change IdentId to textId.
pub fn appendText(self: *Interner, allocator: Allocator, text: []const u8) !void {
    const start: IdentId = @intCast(self.texts.items.len);
    const len: IdentId = @intCast(text.len);
    const span: Span = .{ .start = start, .len = len };

    try self.text_spans.append(allocator, span);
    try self.texts.appendSlice(allocator, text);
}

pub fn getIdent(self: *Interner, id: IdentId) []const u8 {
    const span = self.ident_spans.items[id];
    return self.bytes.items[span.start .. span.start + span.len];
}

pub fn getText(self: *Interner, id: IdentId) []const u8 {
    const span = self.text_spans.items[id];
    return self.texts.items[span.start .. span.start + span.len];
}
