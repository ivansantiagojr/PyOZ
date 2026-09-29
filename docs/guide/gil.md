# GIL Management

Python's Global Interpreter Lock (GIL) prevents multiple threads from executing Python bytecode simultaneously. PyOZ provides utilities to release the GIL during CPU-intensive Zig code, allowing other Python threads to run concurrently.

## When to Release the GIL

**DO release** when:
- Performing CPU-intensive computations
- Doing I/O operations (file, network)
- Calling external C libraries that don't need Python
- Processing large arrays without Python object access

**DON'T release** when:
- Accessing Python objects (`*pyoz.PyObject`)
- Calling Python C API functions
- Using PyOZ conversion functions
- The operation is very short (overhead not worth it)

## Releasing the GIL

Use `pyoz.releaseGIL()` with defer for automatic reacquisition:

```zig
fn heavy_compute(n: i64) i64 {
    const gil = pyoz.releaseGIL();
    defer gil.acquire();  // Always reacquire before returning
    
    // Computation runs without GIL
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        sum +%= @mod(i *% i, 1000000007);
    }
    return sum;
}
```

## Ergonomic GIL Release

For the common pattern of "release GIL, call a function, reacquire", use `allowThreads`:

```zig
fn process(data: pyoz.BufferView(f64)) f64 {
    return pyoz.allowThreads(heavyCompute, .{data.data});
}

fn heavyCompute(slice: []const f64) f64 {
    var sum: f64 = 0;
    for (slice) |v| sum += @sqrt(v);
    return sum;
}
```

`allowThreads` handles release/reacquire automatically. For functions that return errors, use `allowThreadsTry` which uses `defer` for safe GIL restoration:

```zig
fn tryProcess(data: []const u8) !usize {
    return pyoz.allowThreadsTry(parseData, .{data});
}
```

## API Reference

### Ergonomic (recommended)

| Function | Description |
|----------|-------------|
| `pyoz.allowThreads(func, args)` | Call `func(args...)` without the GIL, return its result |
| `pyoz.allowThreadsTry(func, args)` | Same, but uses `defer` for error-safe GIL restoration |

### Manual (from Python threads)

| Function | Description |
|----------|-------------|
| `pyoz.releaseGIL()` | Release GIL, returns `GILGuard` |
| `GILGuard.acquire()` | Reacquire GIL (call before returning) |

### From Non-Python Threads

| Function | Description |
|----------|-------------|
| `pyoz.acquireGIL()` | Acquire GIL from a Zig thread, returns `GILState` |
| `GILState.release()` | Release GIL when done |

## Signal Handling (Ctrl+C Support)

Long-running Zig code blocks Python's signal handling. Without intervention, users can't Ctrl+C to interrupt a stuck computation. Use `checkSignals()` to cooperatively check for pending signals:

```zig
fn compute(n: i64) !i64 {
    var sum: i64 = 0;
    var i: i64 = 0;
    while (i < n) : (i += 1) {
        if (@mod(i, 100000) == 0) try pyoz.checkSignals();
        sum +%= i;
    }
    return sum;
}
```

`checkSignals()` returns normally if no signal is pending. If a signal was received (e.g., SIGINT from Ctrl+C), it returns `error.Interrupted` and the corresponding Python exception (`KeyboardInterrupt`) is already set — it propagates automatically through the `!T` error union return.

**Frequency:** Call it every ~100K iterations or every few milliseconds. Too frequent adds overhead; too rare makes Ctrl+C feel unresponsive.

| Function | Description |
|----------|-------------|
| `pyoz.checkSignals()` | Returns `!void` — error if signal pending |
| `pyoz.SignalError` | The error set: `error{Interrupted}` |

## Best Practices

### 1. Always Use `defer`

```zig
const gil = pyoz.releaseGIL();
defer gil.acquire();  // Guaranteed reacquisition even on errors
```

### 2. Extract Data Before Releasing

```zig
fn process(obj: *pyoz.PyObject) void {
    // Extract data while holding GIL
    const value = pyoz.Conversions.fromPy(i64, obj) catch return;
    
    const gil = pyoz.releaseGIL();
    defer gil.acquire();
    
    // Use extracted value, NOT the Python object
    _ = process_value(value);
}
```

### 3. Keep GIL-Free Sections Focused

```zig
fn process(data: pyoz.BufferView(f64), callback: *pyoz.PyObject) ?f64 {
    // Phase 1: Computation without GIL
    var result: f64 = 0;
    {
        const gil = pyoz.releaseGIL();
        defer gil.acquire();
        for (data.data) |v| result += expensive_math(v);
    }
    
    // Phase 2: Python callback (needs GIL - already reacquired)
    return call_python_callback(callback, result);
}
```

## Common Mistake

**Never hold Python references across GIL release:**

```zig
// WRONG - obj may be garbage collected!
fn bad(obj: *pyoz.PyObject) void {
    const gil = pyoz.releaseGIL();
    _ = obj;  // Dangerous!
    gil.acquire();
}
```

## Free-Threaded Python

On free-threaded CPython (3.13t/3.14t) with a module that declares
`.gil_used = false`, there is no GIL: other threads already run in parallel.
`pyoz.releaseGIL()` remains valid and cheap, and still matters for one reason:
it detaches the thread state, which **suspends the per-object lock** PyOZ holds
while a class method runs. Only release around work that does not touch `self`,
or copy what you need first (see "Extract Data Before Releasing" above). See
[Free-Threading](free-threading.md).

For work you want to `await` from asyncio instead of blocking a thread, see
[Async](async.md).

## Next Steps

- [NumPy](numpy.md) - NumPy array integration
- [Functions](functions.md) - Function definitions
