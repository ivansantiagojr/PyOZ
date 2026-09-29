//! Lazy, lifetime-safe string formatting for Python-facing messages.
//!
//! `pyoz.fmt(format, args)` does no work: it captures the comptime format
//! string and the arguments *by value*. The string is rendered only by the
//! consumer (an exception raiser, `toPy`, a `__repr__` return, ...), into a
//! stack buffer in the consumer's own frame. This replaces the previous design,
//! which returned a pointer into a stack buffer whose frame had already ended.
//!
//! Performance: messages up to `stack_capacity` bytes cost one formatting pass
//! and no heap allocation. Longer messages cost one extra `std.fmt.count` pass
//! and one exact-size `PyMem_Malloc`; they are never truncated.
//!
//! Argument lifetime: values are copied, but slices/pointers inside `args` must
//! still be valid when the consumer runs (e.g. slices into `self` are fine;
//! slices into a local buffer of a function that returns the `Formatted` are not).

const std = @import("std");
const py = @import("python.zig");
const PyObject = py.PyObject;

pub const stack_capacity = 512;

pub fn Formatted(comptime format: []const u8, comptime Args: type) type {
    return struct {
        args: Args,

        pub const _is_pyoz_fmt = {};
        const Self = @This();

        /// Render into a caller-provided buffer.
        pub fn bufPrint(self: Self, buf: []u8) std.fmt.BufPrintError![]u8 {
            return std.fmt.bufPrint(buf, format, self.args);
        }

        /// Exact length of the rendered message in bytes.
        pub fn len(self: Self) u64 {
            return std.fmt.count(format, self.args);
        }

        /// Render to a new Python `str` (invalid UTF-8 is replaced, never raised).
        /// Returns null with a Python exception set on allocation failure.
        pub fn toPyStr(self: Self) ?*PyObject {
            var stack_buf: [stack_capacity]u8 = undefined;
            if (std.fmt.bufPrint(&stack_buf, format, self.args)) |s| {
                return decode(s);
            } else |_| {}

            // Slow path: exact-size heap buffer, formatted once more.
            const n: usize = @intCast(std.fmt.count(format, self.args));
            const mem: [*]u8 = @ptrCast(py.c.PyMem_Malloc(n) orelse {
                _ = py.c.PyErr_NoMemory();
                return null;
            });
            defer py.c.PyMem_Free(mem);
            const s = std.fmt.bufPrint(mem[0..n], format, self.args) catch unreachable;
            return decode(s);
        }

        /// Set `exc_type` as the current Python exception with this message.
        pub fn raise(self: Self, exc_type: *PyObject) void {
            const msg = self.toPyStr() orelse return; // MemoryError already set
            py.PyErr_SetObject(exc_type, msg);
            py.Py_DecRef(msg);
        }
    };
}

fn decode(s: []const u8) ?*PyObject {
    return py.c.PyUnicode_DecodeUTF8(s.ptr, @intCast(s.len), "replace");
}

/// Build a lazily-formatted message. See the module documentation.
///
///   return pyoz.raiseValueError(pyoz.fmt("value {d} exceeds {d}", .{ v, max }));
///   pub fn __repr__(self: *const Vec) pyoz.Formatted("Vec({d}, {d})", struct { f64, f64 }) { ... }
///   // or simply: fn __repr__(self: *const Vec) @TypeOf(pyoz.fmt("Vec({d})", .{@as(f64, 0)}))
pub inline fn fmt(comptime format: []const u8, args: anytype) Formatted(format, @TypeOf(args)) {
    return .{ .args = args };
}

pub fn isFormatted(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "_is_pyoz_fmt");
}

/// Set a Python exception from any supported message type: a string literal,
/// `[*:0]const u8`, `[:0]const u8`, or a `pyoz.fmt(...)` value.
pub inline fn setError(exc_type: *PyObject, message: anytype) void {
    if (comptime isFormatted(@TypeOf(message))) {
        message.raise(exc_type);
    } else {
        py.PyErr_SetString(exc_type, message);
    }
}
