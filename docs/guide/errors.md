# Errors and Exceptions

PyOZ provides comprehensive error handling: returning Zig errors as Python exceptions, raising exceptions directly, catching exceptions, and defining custom exception types.

## Returning Zig Errors

Functions returning error unions (`!T`) automatically raise Python exceptions:

```zig
fn divide(a: f64, b: f64) !f64 {
    if (b == 0.0) return error.DivisionByZero;
    return a / b;
}
```

PyOZ automatically maps well-known error names to the correct Python exception type. For example, `error.TypeError` becomes `TypeError`, `error.DivisionByZero` becomes `ZeroDivisionError`, and `error.KeyNotFound` becomes `KeyError`. Unrecognized errors fall back to `RuntimeError` with the error name as message.

### Automatic Error Mapping

The following Zig error names are automatically mapped without any configuration:

| Zig Error Name | Python Exception |
|----------------|------------------|
| `error.TypeError` | `TypeError` |
| `error.ValueError` | `ValueError` |
| `error.IndexError` | `IndexError` |
| `error.KeyError` | `KeyError` |
| `error.AttributeError` | `AttributeError` |
| `error.RuntimeError` | `RuntimeError` |
| `error.StopIteration` | `StopIteration` |
| `error.OverflowError` | `OverflowError` |
| `error.ZeroDivisionError` | `ZeroDivisionError` |
| `error.FileNotFoundError` | `FileNotFoundError` |
| `error.PermissionError` | `PermissionError` |
| `error.NotImplementedError` | `NotImplementedError` |
| `error.MemoryError` | `MemoryError` |
| `error.TimeoutError` | `TimeoutError` |
| `error.ConnectionError` | `ConnectionError` |
| `error.IOError` | `OSError` |
| `error.ImportError` | `ImportError` |
| Any `ExcBase` variant | Matching Python exception |

Common Zig-idiomatic names are also recognized:

| Zig Error Name | Python Exception |
|----------------|------------------|
| `error.DivisionByZero` | `ZeroDivisionError` |
| `error.Overflow` | `OverflowError` |
| `error.OutOfMemory` | `MemoryError` |
| `error.IndexOutOfBounds` | `IndexError` |
| `error.KeyNotFound` | `KeyError` |
| `error.FileNotFound` | `FileNotFoundError` |
| `error.PermissionDenied` | `PermissionError` |
| `error.AttributeNotFound` | `AttributeError` |
| `error.NotImplemented` | `NotImplementedError` |
| `error.ConnectionRefused` | `ConnectionRefusedError` |
| `error.ConnectionReset` | `ConnectionResetError` |
| `error.BrokenPipe` | `BrokenPipeError` |
| `error.TimedOut`, `error.Timeout` | `TimeoutError` |
| `error.NegativeValue`, `error.InvalidValue` | `ValueError` |

This means simple cases just work:

```zig
fn get_item(index: i64) ![]const u8 {
    if (index < 0) return error.IndexOutOfBounds;
    if (index >= items.len) return error.IndexOutOfBounds;
    return items[@intCast(index)];
}
```

```python
try:
    get_item(-1)
except IndexError as e:
    print(e)  # IndexOutOfBounds
```

## Explicit Error Mapping

For custom error names or custom messages, use explicit error mappings at the module level:

```zig
.error_mappings = &.{
    pyoz.mapError("InvalidInput", .ValueError),
    pyoz.mapError("NotFound", .KeyError),
    pyoz.mapErrorMsg("TooBig", .ValueError, "Value exceeds limit"),
},
```

| Function | Description |
|----------|-------------|
| `pyoz.mapError(name, exc)` | Map error to exception type, uses error name as message |
| `pyoz.mapErrorMsg(name, exc, msg)` | Map error with custom message |

Explicit mappings take precedence over automatic mapping. Use them when:

- Your error name doesn't match a Python exception name (e.g., `error.InvalidInput`)
- You want a custom message instead of the error name
- You want to map to a different exception than the automatic mapping would choose

### Available Exception Types

All `ExcBase` variants are available: `.Exception`, `.ValueError`, `.TypeError`, `.RuntimeError`, `.IndexError`, `.KeyError`, `.AttributeError`, `.StopIteration`, `.ZeroDivisionError`, `.OverflowError`, `.MemoryError`, `.FileNotFoundError`, `.PermissionError`, `.NotImplementedError`, `.TimeoutError`, `.ConnectionError`, `.OSError`, `.ImportError`, `.ArithmeticError`, `.LookupError`, `.EOFError`, `.SyntaxError`, `.UnicodeError`, and many more.

## Custom Exceptions

Define module-specific exception types:

```zig
.exceptions = &.{
    // Full syntax with documentation
    pyoz.exception("ValidationError", .{ .doc = "Raised when validation fails", .base = .ValueError }),
    // Shorthand syntax
    pyoz.exception("MyError", .RuntimeError),
},
```

Custom exceptions are importable and work like any Python exception:

```python
from mymodule import ValidationError
raise ValidationError("Invalid input")
```

### Raising Custom Exceptions from Zig

Use `getException()` with the index from the `.exceptions` array:

```zig
fn validate(n: i64) ?i64 {
    if (n < 0) {
        MyModule.getException(0).raise("Value must be non-negative");
        return null;
    }
    return n;
}
```

## Raising Built-in Exceptions

Raise Python exceptions directly using helper functions:

| Function | Exception Type |
|----------|----------------|
| `pyoz.raiseValueError(msg)` | `ValueError` |
| `pyoz.raiseTypeError(msg)` | `TypeError` |
| `pyoz.raiseRuntimeError(msg)` | `RuntimeError` |
| `pyoz.raiseKeyError(msg)` | `KeyError` |
| `pyoz.raiseIndexError(msg)` | `IndexError` |
| `pyoz.raiseException(type, msg)` | Custom type |

Return `null` from a `?T` function after raising an exception to propagate it to Python.

## Formatted Error Messages

Use `pyoz.fmt()` to build dynamic error messages with Zig's `std.fmt` syntax:

```zig
fn set_port(self: *Server, port: u16) ?void {
    if (port < 1024) return pyoz.raiseValueError(
        pyoz.fmt("port {d} is reserved (must be >= 1024)", .{port}),
    );
    self.port = port;
}
```

`pyoz.fmt()` is lazy: it captures the arguments by value and the message is
rendered by the raise function itself, on its own stack (up to 512 bytes, with
no heap allocation) or in one exact-size heap buffer for longer messages, which
are never truncated.

It works with any raise function:

```zig
return pyoz.raiseTypeError(pyoz.fmt("expected {s}, got {s}", .{ expected, actual }));
return pyoz.raiseIndexError(pyoz.fmt("index {d} out of range [0, {d})", .{ idx, len }));
```

`pyoz.fmt()` also works as a return value: returning a `pyoz.Formatted(...)` from any function or method (including `__repr__`/`__str__`) produces a Python `str`. See the [API reference](../reference/api.md#pyozfmtcomptime-format-args).

## Catching Python Exceptions

When calling Python code from Zig, catch exceptions with `pyoz.catchException()`:

```zig
if (pyoz.catchException()) |*exc| {
    defer @constCast(exc).deinit();  // Always required!
    
    if (exc.isValueError()) {
        // Handle ValueError
    } else {
        exc.reraise();  // Re-raise unknown exceptions
    }
}
```

### PythonException Methods

| Method | Description |
|--------|-------------|
| `.isValueError()`, `.isTypeError()`, etc. | Check exception type |
| `.matches(exc_type)` | Check against specific type |
| `.getMessage()` | Get exception message |
| `.reraise()` | Re-raise the exception |
| `.deinit()` | Clean up (required!) |

### Exception Utility Functions

| Function | Description |
|----------|-------------|
| `pyoz.catchException()` | Catch pending exception |
| `pyoz.exceptionPending()` | Check if exception pending |
| `pyoz.clearException()` | Clear pending exception |

## Optional Return Pattern

Return `?T` (optional) to indicate errors via `null`:

```zig
fn safe_sqrt(x: f64) ?f64 {
    if (x < 0) {
        _ = pyoz.raiseValueError("Cannot take sqrt of negative number");
        return null;
    }
    return @sqrt(x);
}
```

The raise functions return `Null` (Zig's null literal type), so you can combine them into a one-liner:

```zig
fn safe_sqrt(x: f64) ?f64 {
    if (x < 0) return pyoz.raiseValueError("Cannot take sqrt of negative number");
    return @sqrt(x);
}
```

This works with any optional return type (`?i64`, `?f64`, `?[]const u8`, `?*pyoz.PyObject`, etc.).

!!! warning "Always use optional return types with raise functions"
    PyOZ-wrapped functions must return `null` (via `?T`) to signal errors to Python. Setting an exception and returning a non-null value causes Python's `SystemError: returned a result with an exception set`.

**When returning `null`:**

- If an exception is set: exception propagates to Python
- If no exception: returns Python `None`

## Error Handling in Magic Methods

All dunder methods (magic methods) support the same three return conventions as regular functions:

### Error Unions (`!T`)

Return an error union to have Zig errors automatically become Python exceptions:

```zig
const Ring = struct {
    elements: ?*pyoz.PyObject,

    pub fn __new__(capacity: i64) !Ring {
        if (capacity <= 0) return error.InvalidCapacity;
        const list = pyoz.py.PyList_New(0) orelse return error.MemoryError;
        return .{ .elements = list };
    }

    pub fn __add__(self: *const Ring, other: *const Ring) !Ring {
        _ = other;
        if (self.elements == null) return error.EmptyRing;
        return self.*;
    }

    pub fn __len__(self: *const Ring) !usize {
        if (self.elements == null) return error.EmptyRing;
        return @intCast(pyoz.py.PyList_Size(self.elements.?));
    }
};
```

Well-known error names are [automatically mapped](#automatic-error-mapping) to the correct Python exception (e.g., `error.MemoryError` becomes `MemoryError`). For custom error names, use [explicit error mappings](#explicit-error-mapping):

```zig
.error_mappings = &.{
    pyoz.mapError("InvalidCapacity", .ValueError),
    pyoz.mapError("EmptyRing", .RuntimeError),
},
```

### Optional Returns (`?T`)

Use optional returns with explicit exception raising for more control:

```zig
pub fn __new__(capacity: i64) ?Ring {
    if (capacity <= 0) {
        return pyoz.raiseValueError("capacity must be positive");
    }
    const list = pyoz.py.PyList_New(0) orelse {
        return pyoz.raiseMemoryError("failed to allocate list");
    };
    return .{ .elements = list };
}
```

### Supported Methods

Every magic method supports `!T` and `?T` returns:

| Category | Methods |
|----------|---------|
| Constructor | `__new__` |
| Arithmetic | `__add__`, `__sub__`, `__mul__`, `__truediv__`, `__floordiv__`, `__mod__`, `__pow__`, `__matmul__`, `__neg__`, `__pos__`, `__abs__`, `__invert__` |
| In-place | `__iadd__`, `__isub__`, `__imul__`, etc. |
| Reflected | `__radd__`, `__rsub__`, `__rmul__`, etc. |
| Comparison | `__eq__`, `__ne__`, `__lt__`, `__le__`, `__gt__`, `__ge__` |
| Sequence | `__len__`, `__getitem__`, `__setitem__`, `__delitem__`, `__contains__` |
| String | `__repr__`, `__str__`, `__hash__` |
| Conversion | `__bool__`, `__int__`, `__float__`, `__index__` |
| Callable | `__call__` |
| Iterator | `__iter__`, `__next__` |
| Descriptor | `__get__`, `__set__`, `__delete__` |
| Attributes | `__getattr__`, `__setattr__`, `__delattr__` |

## Best Practices

1. **Use error unions for recoverable errors** - They're idiomatic Zig and map cleanly to Python exceptions
2. **Map domain-specific errors** - Makes your API more Pythonic
3. **Use custom exceptions for API clarity** - Helps users catch specific error types
4. **Always clean up caught exceptions** - Call `.deinit()` in a defer
5. **Re-raise unknown exceptions** - Don't silently swallow unexpected errors

## Exceptions and Error Maps in `.from` Namespaces

When using the [`.from` auto-scan API](from.md), you can define exceptions and error mappings inside your scanned namespaces using marker types:

```zig
const pyoz = @import("PyOZ");

// Exception markers — auto-detected and registered
pub const ValidationError = pyoz.Exception(.ValueError, "Raised when validation fails");
pub const NotFoundError = pyoz.Exception(.KeyError, null);

// Error mapping marker — merged with explicit .error_mappings
pub const __errors__ = pyoz.ErrorMap(.{
    .{ "InvalidInput", .ValueError },
    .{ "NotFound", .KeyError },
    .{ "TooBig", .ValueError, "Value exceeds limit" },
});
```

See [Auto-Scan (.from)](from.md) for the full guide.

## Next Steps

- [Auto-Scan (.from)](from.md) - Zero-boilerplate module definitions
- [Enums and Constants](enums.md) - Enums and module constants
- [Types](types.md) - Type conversion reference
