# pyoz build

Build your PyOZ module into a Python wheel package.

## Usage

```bash
pyoz build [options]
```

## Options

| Option | Description |
|--------|-------------|
| `-d, --debug` | Build in debug mode (default) |
| `-r, --release` | Build in release mode (optimized) |
| `--target <targets>` | Build for other platforms: comma-separated `x86_64-linux`, `aarch64-linux`, `x86_64-macos`, `aarch64-macos`, `x86_64-windows`, `aarch64-windows`, or `all` (default: this machine's platform) |
| `--python <version>` | CPython to build for, e.g. `3.12` or `3.14t` (default: the `python3` on `PATH`) |
| `--native` | Build for this machine's CPU and libc only; not for distribution |
| `--stubs` | Generate `.pyi` type stub file (default) |
| `--no-stubs` | Skip type stub generation |
| `-h, --help` | Show help message |

## Build Modes

| Mode | Use Case |
|------|----------|
| Debug (default) | Fast compilation, debug symbols, safety checks - best for development |
| Release | Optimized, smaller binary - best for distribution |

## Portable wheels

Wheels run on other machines, not just the one that built them:

- **Baseline CPU.** No instructions only the build machine has (AVX-512 and
  the like), which would crash older CPUs with an illegal instruction.
- **Linux:** built against glibc 2.17, tagged `manylinux_2_17_<arch>`
  (manylinux2014), which PyPI accepts and every current distribution can
  install. Set `linux-platform-tag = "manylinux_2_28_x86_64"` in
  `[tool.pyoz]` to require a newer glibc instead.
- **macOS:** built for macOS 13.0, the oldest version Zig 0.16 targets
  (`macosx_13_0_<arch>`).
- **Windows:** `win_amd64` / `win_arm64`.

The platform tag is **read from the built binary** (the highest glibc symbol
version it references, its minimum macOS version, its architecture), the way
auditwheel and delocate check wheels, so it is correct however the module was
built. A Linux module that links a library outside the manylinux set (for
example a system `libfoo.so`) is tagged `linux_<arch>` with a warning: PyPI
rejects those, so link such libraries statically.

`--native` skips all of this and builds for the exact machine (native CPU,
installed glibc); Linux native wheels are tagged `linux_<arch>`. `pyoz develop`
and `pip install -e .` always build natively.

## Other platforms and Python versions

Zig cross-compiles, so one machine can build every wheel:

```bash
pyoz build --release --target all                    # six platforms, this Python
pyoz build --release --target aarch64-linux,x86_64-windows --python 3.13
pyoz build --release --python 3.14t                  # free-threaded, this platform
```

When the target or Python version differs from the build machine's, PyOZ
downloads that CPython's headers (and, for Windows, its import libraries) from
[python-build-standalone](https://github.com/astral-sh/python-build-standalone),
verifies them against the release's SHA256SUMS, and caches them (only
`include/` and `libs/` are kept) in `$PYOZ_CACHE_DIR`, or by default
`~/.cache/pyoz` (Linux), `~/Library/Caches/pyoz` (macOS) or
`%LOCALAPPDATA%\pyoz` (Windows). CPython 3.10 to 3.14 are available, plus
free-threaded 3.13t and 3.14t; 3.10 has no Windows ARM64 build, so
`--target all` skips it there.

## Output

```
dist/
└── mymodule-0.1.0-cp312-cp312-manylinux_2_17_x86_64.whl
```

Wheel tags follow the Python the module was built for:

| Build | Tag |
|---|---|
| Regular CPython 3.12 | `cp312-cp312-<platform>` |
| Free-threaded CPython 3.14t | `cp314-cp314t-<platform>` |
| `abi3 = true` | `cp310-abi3-<platform>` (works on 3.10+) |

`abi3 = true` is rejected when building with a free-threaded interpreter: the
Stable ABI does not cover free-threaded builds.

### Wheel Contents

The wheel includes:

- Compiled Zig extension (`.so` / `.pyd`)
- Type stubs (`.pyi`) — unless `--no-stubs` is passed
- Python packages listed in `py-packages` (see [configuration](configuration.md))
- dist-info: WHEEL, METADATA, RECORD, `licenses/` and `entry_points.txt`

METADATA comes from the `[project]` table (PEP 621): `description`, `readme`
(a path, or a table with `file`/`text` and `content-type`), `license` (an SPDX
expression such as `"MIT"`, or a legacy `{ text = ... }` / `{ file = ... }`
table), `license-files`, `authors`, `maintainers`, `keywords`, `classifiers`,
`urls`, `requires-python`, `dependencies` and `optional-dependencies`.
`[project.scripts]`, `[project.gui-scripts]` and `[project.entry-points]`
become `entry_points.txt`.

License files are shipped in `<name>.dist-info/licenses/` (PEP 639): those
matching `license-files`, or by default any top-level `LICEN[CS]E*`,
`COPYING*`, `NOTICE*` and `AUTHORS*` files. An SPDX `license` cannot be
combined with `License ::` classifiers (PyPI rejects that), so the build
stops with an error if both are present.

---

# pyoz develop

Build the extension and install the project in **editable** mode (PEP 660).

## Usage

```bash
pyoz develop
```

`pyoz develop` builds a standard editable wheel and installs it with pip into
the active environment. The wheel contains a `__editable__.<name>-<version>.pth`
file that points at the build output (`zig-out/lib`, or `zig-out/bin` on
Windows); for package layouts the extension is linked into the package
directory and the package's parent directory is added instead. A `.pyi` stub is
written next to the built module for IDEs.

- Rebuilds are picked up without reinstalling: run `zig build` or `pyoz develop`.
- It is a normal install: `pip list` shows it, `pip uninstall <name>` removes it.
- `pip install -e .` does the same through the `pyoz.backend` build backend.

# pyoz publish

Publish wheel packages to PyPI.

## Usage

```bash
pyoz publish [options]
```

## Options

Only wheels in `dist/` for the **current** project name and version are
uploaded; wheels left over from other versions are skipped (and reported),
since PyPI rejects re-uploads.

The upload carries the same metadata as the wheel's METADATA, so PyPI shows
the classifiers, license, links and readme from `pyproject.toml`. If PyPI
rejects a wheel, its explanation is printed, with a hint for common causes
(version already uploaded, non-portable platform tag, unknown classifier).

| Option | Description |
|--------|-------------|
| `-t, --test` | Upload to TestPyPI instead of PyPI |
| `-h, --help` | Show help message |

## Authentication

Set your API token as an environment variable:

| Variable | Description |
|----------|-------------|
| `PYPI_TOKEN` | API token for PyPI |
| `TEST_PYPI_TOKEN` | API token for TestPyPI |

Generate tokens at [pypi.org](https://pypi.org/manage/account/token/) or [test.pypi.org](https://test.pypi.org/manage/account/token/).

## Typical Workflow

```bash
# 1. Build release wheel
pyoz build --release

# 2. Test on TestPyPI first (optional)
export TEST_PYPI_TOKEN="pypi-..."
pyoz publish --test

# 3. Publish to PyPI
export PYPI_TOKEN="pypi-..."
pyoz publish
```
