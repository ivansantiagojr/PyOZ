//! Owned type for allocator-backed return values
//!
//! Wraps a heap-allocated value with its allocator so PyOZ can free the
//! backing memory after converting the value to a Python object.

const std = @import("std");

/// A wrapper that pairs a heap-allocated value with the allocator that owns it.
/// When PyOZ converts an `Owned(T)` to a Python object, it first converts the
/// inner value via `toPy()`, then frees the backing memory with the stored allocator.
///
/// Usage:
///   fn generate(self: *const Report) !pyoz.Owned([]const u8) {
///       const alloc = std.heap.page_allocator;
///       const result = try std.fmt.allocPrint(alloc, "Report: {d} items", .{self.count});
///       return pyoz.owned(alloc, result); // []u8 auto-coerced to []const u8
///   }
pub fn Owned(comptime T: type) type {
    return struct {
        pub const _is_pyoz_owned = true;
        pub const InnerType = T;

        value: T,
        allocator: std.mem.Allocator,
    };
}

/// Create an Owned wrapper from an allocator and a value.
/// Automatically coerces mutable slices ([]u8) to const slices ([]const u8)
/// so users don't need explicit @as casts when using allocPrint, alloc, etc.
pub inline fn owned(allocator: std.mem.Allocator, value: anytype) Owned(CoerceConst(@TypeOf(value))) {
    return .{ .value = value, .allocator = allocator };
}

/// Coerce mutable slice types to their const equivalents ([]u8 → []const u8).
/// Non-slice types pass through unchanged.
fn CoerceConst(comptime T: type) type {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice and !info.pointer.is_const) {
        return []const info.pointer.child;
    }
    return T;
}

/// Free the backing memory of an owned value after conversion to Python.
pub fn freeOwnedValue(comptime T: type, value: T, allocator: std.mem.Allocator) void {
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .slice) {
        allocator.free(value);
    }
    // pyoz.Decimal wraps a string slice: Owned(Decimal) owns that string.
    if (info == .@"struct" and @hasDecl(T, "_is_pyoz_decimal")) {
        allocator.free(value.value);
    }
}
