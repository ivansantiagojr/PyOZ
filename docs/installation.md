# Installation

## Installing PyOZ CLI

The easiest way to get the `pyoz` CLI:

```bash
pip install pyoz
```

This installs prebuilt binaries for Linux (x86_64/aarch64), macOS (x86_64/arm64), and Windows (x86_64/arm64). No compilation needed.

Alternatively, download a binary from [GitHub Releases](https://github.com/pyozig/PyOZ/releases) or build from source with `zig build cli`.

## Requirements

- **Zig** 0.16.0 (any 0.16.x release). Zig changes incompatibly between minor
  releases, so newer versions such as 0.17 do not work with PyOZ 0.13.
- **Python** 3.10 or later (with development headers)

!!! note "Python Version Support"
    PyOZ supports Python 3.10 through 3.14, including the free-threaded 3.14t build. All of them are tested in CI.

## Installing Zig

### Linux

```bash
# Download from ziglang.org
wget https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
tar xf zig-x86_64-linux-0.16.0.tar.xz
export PATH=$PATH:$(pwd)/zig-x86_64-linux-0.16.0
```

Or use your package manager:

```bash
# Check the version: distribution packages often lag behind
sudo apt install zig   # Ubuntu/Debian
zig version            # must print 0.16.x

# Arch Linux
sudo pacman -S zig
```

### macOS

```bash
# Homebrew (check that `zig version` prints 0.16.x)
brew install zig

# Or download from ziglang.org
```

### Windows

Download from [ziglang.org](https://ziglang.org/download/) and add to PATH.

!!! note "Installing PyOZ-based packages from source"
    People who `pip install` a PyOZ project from source (an sdist or a git URL)
    don't need Zig: when no Zig 0.16 is on `PATH`, the `pyoz.backend` build
    backend installs the [`ziglang`](https://pypi.org/project/ziglang/) package
    into pip's build environment and uses its compiler.

## Installing Python Development Headers

### Linux

```bash
# Ubuntu/Debian
sudo apt install python3-dev

# Fedora
sudo dnf install python3-devel

# Arch Linux
sudo pacman -S python
```

### macOS

Python development headers are included with the system Python or Homebrew Python.

### Windows

Install Python from [python.org](https://python.org) with the "Install development files" option.

## Setting Up a PyOZ Project

### Option 1: Use the CLI (Recommended)

The `pyoz` CLI handles all project setup, build configuration, and Python embedding automatically:

```bash
pyoz init mymodule
cd mymodule
pyoz build
```

This generates the correct `build.zig`, `build.zig.zon`, and `pyproject.toml` — no manual configuration needed. See the [Quick Start](quickstart.md) for a full walkthrough.

### Option 2: Clone the Repository

```bash
git clone https://github.com/pyozig/PyOZ.git
cd PyOZ
zig build example  # Build the example module
```

## Verifying Installation

After building with `pyoz build`, install and test:

```bash
pip install dist/mymodule-*.whl
python3 -c "import mymodule; print(mymodule.add(2, 3))"
```

## Next Steps

Continue to the [Quick Start](quickstart.md) guide to build your first PyOZ module.
