//! String operations for Python C API
//!
//! PyUnicode_AsUTF8AndSize is in the Limited API since Python 3.10 (PyOZ's
//! minimum), so it is used in both modes. PyUnicode_AsUTF8 only joined the
//! Limited API in 3.13 and stays unavailable in ABI3 mode.

const types = @import("types.zig");
const c = types.c;
const PyObject = types.PyObject;
const Py_ssize_t = types.Py_ssize_t;

/// Whether we're in ABI3 mode
const abi3_enabled = types.abi3_enabled;

// ============================================================================
// String creation
// ============================================================================

pub inline fn PyUnicode_FromString(s: [*:0]const u8) ?*PyObject {
    return c.PyUnicode_FromString(s);
}

pub inline fn PyUnicode_FromStringAndSize(s: [*]const u8, size: Py_ssize_t) ?*PyObject {
    return c.PyUnicode_FromStringAndSize(s, size);
}

// ============================================================================
// String extraction
// ============================================================================

/// Get UTF-8 string from a Python unicode object.
/// Returns null in ABI3 mode (not in the 3.10 Limited API); use
/// PyUnicode_AsUTF8AndSize there.
pub inline fn PyUnicode_AsUTF8(obj: *PyObject) ?[*:0]const u8 {
    if (abi3_enabled) return null;
    return c.PyUnicode_AsUTF8(obj);
}

/// Get UTF-8 data and size of a Python str. The buffer is cached on the str
/// object and stays valid as long as the object does; nothing to free.
pub inline fn PyUnicode_AsUTF8AndSize(obj: *PyObject, size: *Py_ssize_t) ?[*]const u8 {
    return c.PyUnicode_AsUTF8AndSize(obj, size);
}

// ============================================================================
// String operations
// ============================================================================

/// Concatenate two unicode strings, returning a new string.
/// Caller owns the returned reference.
pub inline fn PyUnicode_Concat(left: *PyObject, right: *PyObject) ?*PyObject {
    return c.PyUnicode_Concat(left, right);
}

// ============================================================================
// String formatting
// ============================================================================

pub inline fn PyUnicode_FromFormat(format: [*:0]const u8, args: anytype) ?*PyObject {
    return @call(.auto, c.PyUnicode_FromFormat, .{format} ++ args);
}
