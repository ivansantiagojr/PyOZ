//! Path operations for Python C API (pathlib.Path)

const types = @import("types.zig");
const c = types.c;
const PyObject = types.PyObject;
const Py_ssize_t = types.Py_ssize_t;
const refcount = @import("refcount.zig");
const Py_DecRef = refcount.Py_DecRef;
const string = @import("string.zig");
const PyUnicode_FromStringAndSize = string.PyUnicode_FromStringAndSize;
const PyUnicode_AsUTF8AndSize = string.PyUnicode_AsUTF8AndSize;
const tuple = @import("tuple.zig");
const PyTuple_Pack = tuple.PyTuple_Pack;
const typecheck = @import("typecheck.zig");
const PyUnicode_Check = typecheck.PyUnicode_Check;
const lazy = @import("lazy.zig");

// ============================================================================
// Path operations (pathlib.Path)
// ============================================================================

var pathlib_path_type: lazy.LazyObject = .{};

/// Get the pathlib.Path type (lazily imported; free-threading safe)
fn getPathType() ?*PyObject {
    if (pathlib_path_type.get()) |t| return t;
    const pathlib = c.PyImport_ImportModule("pathlib") orelse return null;
    defer Py_DecRef(pathlib);
    const t = c.PyObject_GetAttrString(pathlib, "Path") orelse return null;
    return pathlib_path_type.publish(t);
}

/// Create a pathlib.Path from a string
pub fn PyPath_FromString(path: []const u8) ?*PyObject {
    const path_type = getPathType() orelse return null;
    const py_str = PyUnicode_FromStringAndSize(path.ptr, @intCast(path.len)) orelse return null;
    defer Py_DecRef(py_str);

    // Call Path(str)
    const args = PyTuple_Pack(.{py_str}) orelse return null;
    defer Py_DecRef(args);

    return c.PyObject_CallObject(path_type, args);
}

/// Check if an object is a pathlib.Path (or os.PathLike)
pub fn PyPath_Check(obj: *PyObject) bool {
    // Check for __fspath__ method (os.PathLike protocol)
    return c.PyObject_HasAttrString(obj, "__fspath__") != 0;
}

/// Result from PyPath_AsStringWithRef - contains both the string and the owning PyObject
pub const PathStringResult = struct {
    path: []const u8,
    py_str: *PyObject,
};

/// Get string from a path-like object using os.fspath()
/// Returns both the string slice and the owning PyObject.
/// The caller is responsible for calling Py_DecRef on py_str when done.
pub fn PyPath_AsStringWithRef(obj: *PyObject) ?PathStringResult {
    // Call os.fspath() on the object to get the string representation
    const fspath_result = c.PyOS_FSPath(obj) orelse return null;
    // NOTE: We do NOT decref here - caller takes ownership

    // Convert to string
    if (PyUnicode_Check(fspath_result)) {
        var size: Py_ssize_t = 0;
        const ptr = PyUnicode_AsUTF8AndSize(fspath_result, &size) orelse {
            Py_DecRef(fspath_result);
            return null;
        };
        return PathStringResult{
            .path = ptr[0..@intCast(size)],
            .py_str = fspath_result,
        };
    }
    Py_DecRef(fspath_result);
    return null;
}

/// Get string from a path-like object using os.fspath()
/// DEPRECATED: This function has a use-after-free bug when used with pathlib.Path.
/// Use PyPath_AsStringWithRef instead which properly manages lifetime.
pub fn PyPath_AsString(obj: *PyObject) ?[]const u8 {
    // For plain strings, we can return directly since the string is owned by the input object
    if (PyUnicode_Check(obj)) {
        var size: Py_ssize_t = 0;
        const ptr = PyUnicode_AsUTF8AndSize(obj, &size) orelse return null;
        return ptr[0..@intCast(size)];
    }
    // For pathlib.Path, this would be unsafe - use PyPath_AsStringWithRef instead
    return null;
}
