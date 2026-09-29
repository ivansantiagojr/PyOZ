# Free-Threading (PEP 703)

PyOZ supports free-threaded CPython builds (`python3.13t`, `python3.14t`).

## Declaring GIL-free support

```zig
pub const Module = pyoz.module(.{
    .name = "mymod",
    .gil_used = false, // this module is safe without the GIL
    // ...
});
```

Without `.gil_used = false`, importing the module on a free-threaded
interpreter **re-enables the GIL for the whole process** (CPython prints a
`RuntimeWarning`). The option is opt-in because it is a promise that your
module's own code is thread-safe. It has no effect on regular builds.

## What PyOZ does for you

- **Per-object locking.** On free-threaded builds every method, property
  getter/setter and protocol slot of a PyOZ class runs inside a CPython
  *critical section* on `self` (binary operators and comparisons lock both
  operands, deadlock-free). Two threads calling into the same object can no
  longer corrupt its Zig state. As with CPython's own objects, the lock protects
  one operation, and it is suspended while the thread blocks or releases the GIL
  (`pyoz.releaseGIL`).
- **Cost:** about 9–10 ns per call on free-threaded builds; exactly zero on
  regular builds, where the wrapper is removed at compile time.
- Internal caches (datetime, decimal, pathlib) use lock-free initialization.
- `__freelist__` is ignored on free-threaded builds (the per-thread allocator
  of free-threaded CPython plays that role).

## Testing

PyOZ's own suite includes free-threading stress tests (many threads mutating
one object, parallel event loops running async jobs). They run on multi-core CI
runners against 3.14t in Debug and ReleaseSafe. Test your own classes the same
way: build against a free-threaded interpreter, check
`sys._is_gil_enabled()` is `False` after import, and hammer shared objects from
several threads.

## Opting out of locking

Immutable classes, or classes that synchronize internally, can skip the lock:

```zig
const Point = struct {
    pub const __lock__ = false;
    x: f64,
    y: f64,
};
```

Module-level functions are not locked: shared global state they touch must be
synchronized by you (e.g. with `std.atomic` or a mutex).

## Building and packaging

`pyoz build` detects a free-threaded interpreter and produces a
`cpXY-cpXYt` wheel (e.g. `cp314-cp314t`). `abi3 = true` is rejected there: the
Stable ABI does not cover free-threaded builds.

## Next Steps

- [Async](async.md) - Awaitable Zig functions and methods
- [GIL Management](gil.md) - Releasing the GIL and its interaction with object locks
- [Classes](classes.md) - Frozen classes and class options
