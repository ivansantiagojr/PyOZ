//! Lock-free, free-threading-safe lazy caches for Python objects.
//!
//! Fast path is a single acquire load. On first use several threads may race
//! to initialize; each builds its own value and tries to publish it with a
//! compare-and-swap. Losers drop their reference and use the winner's, so no
//! lock is held across Python calls (which could deadlock against the GIL on
//! regular builds, or against other critical sections on free-threaded ones).

const std = @import("std");
const types = @import("types.zig");
const refcount = @import("refcount.zig");
const PyObject = types.PyObject;

pub const LazyObject = struct {
    ptr: ?*PyObject = null,

    pub inline fn get(self: *LazyObject) ?*PyObject {
        return @atomicLoad(?*PyObject, &self.ptr, .acquire);
    }

    /// Publish `value` (an owned reference). Returns the object that won.
    pub fn publish(self: *LazyObject, value: *PyObject) *PyObject {
        if (@cmpxchgStrong(?*PyObject, &self.ptr, null, value, .acq_rel, .acquire)) |winner| {
            refcount.Py_DecRef(value);
            return winner.?;
        }
        return value;
    }
};

/// A flag set (with release ordering) after a group of LazyObjects is published.
pub const ReadyFlag = struct {
    ready: bool = false,

    pub inline fn isSet(self: *ReadyFlag) bool {
        return @atomicLoad(bool, &self.ready, .acquire);
    }

    pub inline fn set(self: *ReadyFlag) void {
        @atomicStore(bool, &self.ready, true, .release);
    }
};
