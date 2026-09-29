<div align="center">

<img src="docs/assets/logo.svg" alt="PyOZ Logo" width="150">

# PyOZ

**Zig's power meets Python's simplicity.**

Build blazing-fast Python extensions with zero boilerplate and zero Python C API headaches.

[![GitHub Stars](https://img.shields.io/github/stars/pyozig/PyOZ?style=flat)](https://github.com/pyozig/PyOZ)
[![Python](https://img.shields.io/badge/python-3.10--3.14-blue)](https://www.python.org/)
[![Zig](https://img.shields.io/badge/zig-0.16-orange)](https://ziglang.org/)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

[Documentation](https://pyoz.dev) | [Getting Started](https://pyoz.dev/quickstart/) | [Examples](https://pyoz.dev/examples/complete-module/)

</div>

---

## Quick Example

```zig
const pyoz = @import("PyOZ");

fn add(a: i64, b: i64) i64 {
    return a + b;
}

pub const Module = pyoz.module(.{
    .name = "mymodule",
    .funcs = &.{
        pyoz.func("add", add, "Add two numbers"),
    },
});
```

```python
import mymodule
print(mymodule.add(2, 3))  # 5
```

## Features

- **Declarative API** - Define modules, functions, and classes with simple struct literals
- **Automatic Type Conversion** - Zig types map naturally to Python types
- **Full Class Support** - Magic methods, operators, properties, inheritance
- **NumPy Integration** - Zero-copy array access
- **Error Handling** - Zig errors become Python exceptions
- **Async** - `await` Zig functions from asyncio, built on Zig's `std.Io`, with real cancellation
- **Free-Threading** - Runs without the GIL on free-threaded CPython (3.14t), with per-object locking
- **Type Stubs** - Automatic `.pyi` generation for IDE support
- **Simple Tooling** - `pyoz init`, `pyoz build`, `pyoz publish`

## Installation

```bash
pip install pyoz
```

Or download a prebuilt binary from [GitHub Releases](https://github.com/pyozig/PyOZ/releases), or build from source:

```bash
git clone https://github.com/pyozig/PyOZ.git
cd PyOZ
zig build cli
```

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

Full documentation available at **[pyoz.dev](https://pyoz.dev)**

- [Installation](https://pyoz.dev/installation/)
- [Quickstart](https://pyoz.dev/quickstart/)
- [Functions](https://pyoz.dev/guide/functions/)
- [Classes](https://pyoz.dev/guide/classes/)
- [NumPy Integration](https://pyoz.dev/guide/numpy/)
- [Error Handling](https://pyoz.dev/guide/errors/)
- [Async](https://pyoz.dev/guide/async/)
- [Free-Threading](https://pyoz.dev/guide/free-threading/)
- [CLI Reference](https://pyoz.dev/cli/build/)

## Upgrading

Coming from PyOZ 0.12? See [Upgrading to 0.13](https://pyoz.dev/upgrading/): Zig 0.16, Python 3.10+, and a few `build.zig` edits.

## Requirements

- Zig 0.16.x (Zig changes incompatibly between minor releases)
- Python 3.10 - 3.14

## License

MIT License - see [LICENSE](LICENSE) for details.

## Contributing

Contributions welcome! Please open an issue or submit a PR.
