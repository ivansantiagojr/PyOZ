//! Decimal type for Python interop
//!
//! Provides Decimal type for working with Python decimal.Decimal objects
//! with exact precision (no floating point errors).

const std = @import("std");
const lazy = @import("../python/lazy.zig");
const py = @import("../python.zig");
const PyObject = py.PyObject;

/// A decimal type for accepting/returning decimal.Decimal objects
/// Stores the decimal as a string representation for exact precision
/// Usage:
///   fn process_money(amount: pyoz.Decimal) pyoz.Decimal {
///       // Parse and manipulate as needed
///       return pyoz.Decimal.init("99.99");
///   }
pub const Decimal = struct {
    pub const _is_pyoz_decimal = true;

    /// String representation of the decimal value
    value: []const u8,

    /// Create a Decimal from a string
    pub fn init(value: []const u8) Decimal {
        return .{ .value = value };
    }

    /// Parse as f64 (may lose precision - use with caution)
    pub fn toFloat(self: Decimal) ?f64 {
        return std.fmt.parseFloat(f64, self.value) catch null;
    }

    /// Parse as i64 (truncates decimal part)
    pub fn toInt(self: Decimal) ?i64 {
        // Find decimal point and parse integer part
        for (self.value, 0..) |c, i| {
            if (c == '.') {
                return std.fmt.parseInt(i64, self.value[0..i], 10) catch null;
            }
        }
        return std.fmt.parseInt(i64, self.value, 10) catch null;
    }
};

// Cached decimal.Decimal class (free-threading safe; see python/lazy.zig)
var decimal_class_cache: lazy.LazyObject = .{};

fn decimalClass() ?*PyObject {
    if (decimal_class_cache.get()) |cls| return cls;
    const module = py.PyImport_ImportModule("decimal") orelse return null;
    defer py.Py_DecRef(module);
    const cls = py.PyObject_GetAttrString(module, "Decimal") orelse return null;
    return decimal_class_cache.publish(cls);
}

/// Initialize the decimal module - call this in module init if using Decimal type
pub fn initDecimal() bool {
    return decimalClass() != null;
}

/// Check if an object is a decimal.Decimal instance
pub fn PyDecimal_Check(obj: *PyObject) bool {
    const cls = decimalClass() orelse return false;
    return py.PyObject_IsInstance(obj, cls) == 1;
}

/// Create a Python decimal.Decimal from a string
pub fn PyDecimal_FromString(value: []const u8) ?*PyObject {
    const cls = decimalClass() orelse return null;

    const py_str = py.PyUnicode_FromStringAndSize(value.ptr, @intCast(value.len)) orelse return null;
    defer py.Py_DecRef(py_str);

    const args = py.PyTuple_New(1) orelse return null;
    defer py.Py_DecRef(args);

    // PyTuple_SetItem steals reference, so we need to incref
    py.Py_IncRef(py_str);
    if (py.PyTuple_SetItem(args, 0, py_str) < 0) return null;

    return py.PyObject_Call(cls, args, null);
}

/// Get string representation of a Python decimal.Decimal
pub fn PyDecimal_AsString(obj: *PyObject) ?[]const u8 {
    const str_obj = py.PyObject_Str(obj) orelse return null;
    defer py.Py_DecRef(str_obj);

    var size: py.Py_ssize_t = 0;
    const ptr = py.PyUnicode_AsUTF8AndSize(str_obj, &size) orelse return null;
    return ptr[0..@intCast(size)];
}
