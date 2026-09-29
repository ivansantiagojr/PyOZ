# PyOZ

**Zig's power meets Python's simplicity.** Build blazing-fast Python extensions with zero boilerplate and zero Python C API headaches.

[Documentation](https://pyoz.dev) | [Getting Started](https://pyoz.dev/quickstart/) | [Examples](https://pyoz.dev/examples/complete-module/) | [GitHub](https://github.com/pyozig/PyOZ)

## Quick Example

Write normal Zig code -- PyOZ handles all the Python integration automatically:

```zig
const pyoz = @import("PyOZ");

const Point = struct {
    x: f64,
    y: f64,

    pub fn magnitude(self: *const Point) f64 {
        return @sqrt(self.x * self.x + self.y * self.y);
    }
};

fn add(a: i64, b: i64) i64 {
    return a + b;
}

pub const Module = pyoz.module(.{
    .name = "mymodule",
    .funcs = &.{
        pyoz.func("add", add, "Add two numbers"),
    },
    .classes = &.{
        pyoz.class("Point", Point),
    },
});
```

```python
import mymodule

print(mymodule.add(2, 3))  # 5

p = mymodule.Point(3.0, 4.0)
print(p.magnitude())  # 5.0
print(p.x, p.y)       # 3.0 4.0
```

## Features

- **Declarative API** -- Define modules, functions, and classes with simple struct literals
- **Automatic type conversion** -- Zig `i64`, `f64`, `[]const u8`, structs, optionals, error unions all map to Python types automatically
- **Full class support** -- `__init__`, `__repr__`, `__add__`, `__iter__`, `__getitem__`, properties, static/class methods, inheritance
- **NumPy integration** -- Zero-copy array access via buffer protocol
- **Error handling** -- Zig errors become Python exceptions; custom exception types supported
- **Type stubs** -- Automatic `.pyi` generation for IDE autocomplete and type checking
- **GIL management** -- Release the GIL for CPU-bound Zig code with `pyoz.releaseGIL()`
- **Async** -- `await` Zig functions and methods from asyncio (built on Zig's `std.Io`), with cancellation that reaches the Zig task
- **Free-threading** -- Runs without the GIL on free-threaded CPython (3.14t); class instances get per-object locking automatically
- **Cross-class references** -- Methods can accept/return instances of other classes in the same module
- **Simple tooling** -- `pyoz init`, `pyoz build`, `pyoz develop`, `pyoz publish`

## Installation

```bash
pip install pyoz
```

Requires **Zig 0.16.0+** and **Python 3.10--3.14**.

## Getting Started

```bash
# Create a new project
pyoz init myproject
cd myproject

# Build and install for development
pyoz develop

# Test it
python -c "import myproject; print(myproject.add(1, 2))"
```

## Documentation

Full documentation at **[pyoz.dev](https://pyoz.dev)**:

- [Installation](https://pyoz.dev/installation/) -- Setup and requirements
- [Quickstart](https://pyoz.dev/quickstart/) -- Your first PyOZ module in 5 minutes
- [Functions](https://pyoz.dev/guide/functions/) -- Module-level functions, keyword arguments
- [Classes](https://pyoz.dev/guide/classes/) -- Full class support with magic methods
- [Types](https://pyoz.dev/guide/types/) -- Type conversion reference
- [Properties](https://pyoz.dev/guide/properties/) -- Computed properties and getters/setters
- [Error Handling](https://pyoz.dev/guide/errors/) -- Zig errors to Python exceptions
- [NumPy](https://pyoz.dev/guide/numpy/) -- Zero-copy buffer protocol
- [GIL](https://pyoz.dev/guide/gil/) -- Releasing the GIL for parallelism
- [CLI Reference](https://pyoz.dev/cli/build/) -- Build, develop, publish commands
- [Complete Example](https://pyoz.dev/examples/complete-module/) -- Full-featured module walkthrough

## License

MIT
