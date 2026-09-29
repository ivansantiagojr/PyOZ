//! Per-object locking for PyOZ classes on free-threaded CPython (PEP 703).
//!
//! Without the GIL, two threads can call into the same PyOZ object at once,
//! and Zig methods mutate `self` freely (e.g. an ArrayList append that
//! reallocates), so unsynchronized access is memory corruption, not just a
//! logic race. CPython protects its own objects with per-object *critical
//! sections*; PyOZ does the same for every slot that reaches user code.
//!
//! `locked(T, f)` returns a C-ABI function with the same signature as `f` that
//! enters a critical section on `self` before calling `f`. `locked2` locks the
//! first two arguments (binary operators, rich comparison) with
//! PyCriticalSection2, CPython's deadlock-free two-object variant.
//!
//! Semantics match CPython's builtins: sections are reentrant, and they are
//! suspended while the thread blocks or releases the GIL (`pyoz.releaseGIL`),
//! so they protect a single operation, not a sequence of calls.
//!
//! Cost: on GIL builds `locked` returns `f` unchanged at comptime, so the
//! generated code is identical to not using it. On free-threaded builds an
//! uncontended section is one atomic compare-and-swap on the object's
//! built-in `ob_mutex`. Classes that are immutable or synchronize themselves
//! can opt out with `pub const __lock__ = false;`.

const py = @import("../python.zig");
const abi = @import("../abi.zig");

pub const enabled = py.types.gil_disabled and !abi.abi3_enabled;

pub fn wantsLock(comptime T: type) bool {
    if (!enabled) return false;
    if (@hasDecl(T, "__lock__")) return T.__lock__;
    return true;
}

fn Unopt(comptime F: type) type {
    return if (@typeInfo(F) == .optional) @typeInfo(F).optional.child else F;
}

fn Body(comptime F: type) type {
    const G = Unopt(F);
    return if (@typeInfo(G) == .pointer) @typeInfo(G).pointer.child else G;
}

/// `*const fn` for fn bodies/pointers; `?*const fn` for optional pointers
/// (e.g. a property setter generator returns null when there is no setter).
fn Result(comptime F: type) type {
    return if (@typeInfo(F) == .optional) ?*const Body(F) else *const Body(F);
}

fn lockWith(comptime T: type, comptime f: anytype, comptime want: u2) Result(@TypeOf(f)) {
    const F = @TypeOf(f);
    if (@typeInfo(F) == .optional) {
        const p = f orelse return null;
        return lockWith(T, p, want);
    }
    const body: Body(F) = if (@typeInfo(F) == .pointer) f.* else f;
    if (comptime !wantsLock(T)) return &body;
    return wrap(body, want);
}

/// Lock `self` (the first argument) around `f`.
pub fn locked(comptime T: type, comptime f: anytype) Result(@TypeOf(f)) {
    return lockWith(T, f, 1);
}

/// Lock the first two arguments around `f` (binary operators, comparisons).
pub fn locked2(comptime T: type, comptime f: anytype) Result(@TypeOf(f)) {
    return lockWith(T, f, 2);
}

inline fn asObj(p: anytype) ?*py.c.PyObject {
    return @ptrCast(@alignCast(p));
}

const Section = struct {
    one: py.c.PyCriticalSection = undefined,
    two: py.c.PyCriticalSection2 = undefined,
    n: u2 = 0,

    inline fn begin(s: *Section, a: ?*py.c.PyObject, b: ?*py.c.PyObject, comptime want: u2) void {
        if (want == 2 and a != null and b != null) {
            py.c.PyCriticalSection2_Begin(&s.two, a, b);
            s.n = 2;
        } else if (a) |obj| {
            py.c.PyCriticalSection_Begin(&s.one, obj);
            s.n = 1;
        }
    }

    inline fn end(s: *Section) void {
        switch (s.n) {
            2 => py.c.PyCriticalSection2_End(&s.two),
            1 => py.c.PyCriticalSection_End(&s.one),
            else => {},
        }
    }
};

fn wrap(comptime f: anytype, comptime want: u2) *const @TypeOf(f) {
    const info = @typeInfo(@TypeOf(f)).@"fn";
    const P = info.params;
    const R = info.return_type.?;
    const cc = info.calling_convention;
    return switch (P.len) {
        1 => &struct {
            fn call(a: P[0].type.?) callconv(cc) R {
                var s: Section = .{};
                s.begin(asObj(a), null, 1);
                defer s.end();
                return f(a);
            }
        }.call,
        2 => &struct {
            fn call(a: P[0].type.?, b: P[1].type.?) callconv(cc) R {
                var s: Section = .{};
                s.begin(asObj(a), if (want == 2) asObj(b) else null, want);
                defer s.end();
                return f(a, b);
            }
        }.call,
        3 => &struct {
            fn call(a: P[0].type.?, b: P[1].type.?, c: P[2].type.?) callconv(cc) R {
                var s: Section = .{};
                s.begin(asObj(a), if (want == 2) asObj(b) else null, want);
                defer s.end();
                return f(a, b, c);
            }
        }.call,
        4 => &struct {
            fn call(a: P[0].type.?, b: P[1].type.?, c: P[2].type.?, d: P[3].type.?) callconv(cc) R {
                var s: Section = .{};
                s.begin(asObj(a), if (want == 2) asObj(b) else null, want);
                defer s.end();
                return f(a, b, c, d);
            }
        }.call,
        else => @compileError("pyoz: unsupported slot arity for locking"),
    };
}
