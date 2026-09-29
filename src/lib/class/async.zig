//! Async protocol for class generation
//!
//! Implements __await__, __aiter__, __anext__ (the tp_as_async slots).
//! __aenter__ / __aexit__ have no slot; they are regular methods whose results
//! methods.zig routes through awaitable.toAwaitable.

const std = @import("std");
const py = @import("../python.zig");
const conversion = @import("../conversion.zig");
const slots = @import("../python/slots.zig");
const ft = @import("threading.zig");
const awaitable = @import("../awaitable.zig");
const errors_mod = @import("../errors.zig");

const root = @import("../root.zig");
const unwrapSignature = root.unwrapSignature;
const unwrapSignatureValue = root.unwrapSignatureValue;

const class_mod = @import("mod.zig");
const ClassInfo = class_mod.ClassInfo;

/// Dunders wired to tp_as_async slots (excluded from the method table).
pub const slot_dunders = [_][]const u8{ "__await__", "__aiter__", "__anext__" };

/// Async dunders without a slot: regular methods returning awaitables.
pub fn isAsyncMethodDunder(comptime name: []const u8) bool {
    return comptime std.mem.eql(u8, name, "__aenter__") or std.mem.eql(u8, name, "__aexit__");
}

/// Build async protocol for a given type
pub fn AsyncProtocol(comptime T: type, comptime Parent: type, comptime class_infos: []const ClassInfo) type {
    const Conv = conversion.Converter(class_infos);

    return struct {
        pub fn hasAsyncMethods() bool {
            return @hasDecl(T, "__await__") or @hasDecl(T, "__aiter__") or @hasDecl(T, "__anext__");
        }

        /// Call a zero-argument dunder with `self` as *T, *const T or T.
        fn callSelf(comptime name: []const u8, data: *T) ReturnOf(name) {
            const f = @field(T, name);
            const params = @typeInfo(@TypeOf(f)).@"fn".params;
            if (params.len != 1) @compileError(name ++ " on " ++ @typeName(T) ++ " must take only `self`");
            const Self = params[0].type.?;
            return if (Self == T) f(data.*) else f(data);
        }

        fn ReturnOf(comptime name: []const u8) type {
            return @typeInfo(@TypeOf(@field(T, name))).@"fn".return_type.?;
        }

        fn dunderAwaitable(comptime name: []const u8, comptime mode: awaitable.Mode, self_obj: *py.PyObject) ?*py.PyObject {
            const self: *Parent.PyWrapper = @ptrCast(@alignCast(self_obj));
            const Raw = ReturnOf(name);
            const result = unwrapSignatureValue(Raw, callSelf(name, self.getData()));
            return awaitable.toAwaitable(Conv, T, unwrapSignature(Raw), result, mode, self_obj, self.getData());
        }

        pub fn py_await(self_obj: ?*py.PyObject) callconv(.c) ?*py.PyObject {
            const aw = dunderAwaitable("__await__", .value, self_obj orelse return null) orelse return null;
            return awaitable.awaitIterator(aw);
        }

        pub fn py_anext(self_obj: ?*py.PyObject) callconv(.c) ?*py.PyObject {
            return dunderAwaitable("__anext__", .anext, self_obj orelse return null);
        }

        /// __aiter__ is synchronous: it returns the async iterator itself.
        pub fn py_aiter(self_obj: ?*py.PyObject) callconv(.c) ?*py.PyObject {
            const obj = self_obj orelse return null;
            const self: *Parent.PyWrapper = @ptrCast(@alignCast(obj));
            const Raw = ReturnOf("__aiter__");
            return convertAiter(unwrapSignature(Raw), unwrapSignatureValue(Raw, callSelf("__aiter__", self.getData())), obj, self.getData());
        }

        fn convertAiter(comptime R: type, result: R, self_obj: *py.PyObject, self_data: *const T) ?*py.PyObject {
            switch (@typeInfo(R)) {
                .error_union => |eu| {
                    const value = result catch |err| {
                        if (py.PyErr_Occurred() == null) {
                            const msg = @errorName(err);
                            py.PyErr_SetString(errors_mod.mapWellKnownError(msg), msg.ptr);
                        }
                        return null;
                    };
                    return convertAiter(eu.payload, value, self_obj, self_data);
                },
                .pointer => |p| if (p.size == .one and p.child == T) {
                    if (result == self_data) {
                        py.Py_IncRef(self_obj);
                        return self_obj;
                    }
                },
                else => {},
            }
            return Conv.toPy(R, result);
        }

        pub var async_methods: py.c.PyAsyncMethods = makeAsyncMethods();

        fn makeAsyncMethods() py.c.PyAsyncMethods {
            var am: py.c.PyAsyncMethods = std.mem.zeroes(py.c.PyAsyncMethods);
            if (@hasDecl(T, "__await__")) am.am_await = @ptrCast(ft.locked(T, py_await));
            if (@hasDecl(T, "__aiter__")) am.am_aiter = @ptrCast(ft.locked(T, py_aiter));
            if (@hasDecl(T, "__anext__")) am.am_anext = @ptrCast(ft.locked(T, py_anext));
            return am;
        }

        pub fn slotCount() usize {
            var count: usize = 0;
            if (@hasDecl(T, "__await__")) count += 1;
            if (@hasDecl(T, "__aiter__")) count += 1;
            if (@hasDecl(T, "__anext__")) count += 1;
            return count;
        }

        pub fn addSlots(slot_array: []py.PyType_Slot, start_idx: usize) usize {
            var idx = start_idx;
            if (@hasDecl(T, "__await__")) {
                slot_array[idx] = .{ .slot = slots.am_await, .pfunc = @ptrCast(@constCast(ft.locked(T, py_await))) };
                idx += 1;
            }
            if (@hasDecl(T, "__aiter__")) {
                slot_array[idx] = .{ .slot = slots.am_aiter, .pfunc = @ptrCast(@constCast(ft.locked(T, py_aiter))) };
                idx += 1;
            }
            if (@hasDecl(T, "__anext__")) {
                slot_array[idx] = .{ .slot = slots.am_anext, .pfunc = @ptrCast(@constCast(ft.locked(T, py_anext))) };
                idx += 1;
            }
            return idx - start_idx;
        }
    };
}
