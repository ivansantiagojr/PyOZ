"""PEP 517 / PEP 660 build backend for PyOZ projects.

This module implements the PEP 517 build backend interface so that
``pip install .`` works for projects using PyOZ, and the PEP 660 hooks so
that ``pip install -e .`` produces an editable install. Set the following
in your ``pyproject.toml``:

.. code-block:: toml

    [build-system]
    requires = ["pyoz"]
    build-backend = "pyoz.backend"
"""

import glob
import os
import re
import shutil
import subprocess
import sys
import tarfile

# Zig release this PyOZ version builds with. Zig has no compatibility
# guarantee between minor releases, so a different `zig` on PATH won't do.
ZIG_SERIES = "0.16."
ZIGLANG_REQUIREMENT = "ziglang>=0.16.0,<0.17"


def _system_zig_ok():
    """True if `zig` on PATH is the Zig release PyOZ needs."""
    zig = shutil.which("zig")
    if not zig:
        return False
    try:
        out = subprocess.run([zig, "version"], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return False
    return out.returncode == 0 and out.stdout.strip().startswith(ZIG_SERIES)


def _zig_requires():
    # pip's isolated build environment has no Zig compiler; the `ziglang`
    # package provides one, so building from source needs nothing preinstalled.
    return [] if _system_zig_ok() else [ZIGLANG_REQUIREMENT]


def _use_ziglang_if_needed():
    """Put the `ziglang` package's compiler first on PATH when the system one
    is missing or the wrong version."""
    if _system_zig_ok():
        return
    try:
        import ziglang
    except ImportError:
        raise RuntimeError(
            "PyOZ needs Zig " + ZIG_SERIES + "x to build this project. Install it "
            "(https://ziglang.org/download/) or `pip install '" + ZIGLANG_REQUIREMENT + "'`."
        ) from None
    zig_dir = os.path.dirname(ziglang.__file__)
    if not any(os.path.isfile(os.path.join(zig_dir, exe)) for exe in ("zig", "zig.exe")):
        raise RuntimeError("the installed ziglang package has no zig executable in " + zig_dir)
    os.environ["PATH"] = zig_dir + os.pathsep + os.environ.get("PATH", "")
    print(f"pyoz.backend: building with Zig {_ziglang_version()} from the ziglang package ({zig_dir})", file=sys.stderr)


def _ziglang_version():
    try:
        from importlib.metadata import version

        return version("ziglang")
    except Exception:
        return "?"


def get_requires_for_build_wheel(config_settings=None):
    return _zig_requires()


def get_requires_for_build_sdist(config_settings=None):
    return []


def get_requires_for_build_editable(config_settings=None):
    return _zig_requires()


def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    # The native module ships inside the package (pyoz/_pyoz.so); the previous
    # absolute `from _pyoz import build` raised ModuleNotFoundError.
    from pyoz._pyoz import build

    _use_ziglang_if_needed()

    release = True
    stubs = True
    if config_settings:
        release = config_settings.get("--release", "true").lower() != "false"
        stubs = config_settings.get("--stubs", "true").lower() != "false"

    wheel_path = build(release, stubs)
    filename = os.path.basename(wheel_path)
    dest = os.path.join(wheel_directory, filename)
    shutil.copy2(wheel_path, dest)
    return filename


def build_editable(wheel_directory, config_settings=None, metadata_directory=None):
    """PEP 660: build an editable wheel pointing at the project's build output."""
    from pyoz._pyoz import build_editable as _build_editable

    _use_ziglang_if_needed()

    wheel_path = _build_editable(os.path.abspath(wheel_directory))
    return os.path.basename(wheel_path)


def build_sdist(sdist_directory, config_settings=None):
    name = _get_project_field("name")
    version = _get_project_field("version")
    # PEP 625: normalized name in the file name
    sdist_name = f"{re.sub(r'[-_.]+', '_', name).lower()}-{version}"
    sdist_filename = f"{sdist_name}.tar.gz"
    sdist_path = os.path.join(sdist_directory, sdist_filename)

    paths = ["pyproject.toml", "build.zig", "build.zig.zon", "src"]
    # Flat-layout Python packages (src/ layout ones are already under src/)
    paths += _get_project_list("py-packages")
    # README and license files, which the wheel's metadata refers to
    for pattern in ("README*", "LICEN[CS]E*", "COPYING*", "NOTICE*", "AUTHORS*"):
        paths += sorted(glob.glob(pattern))

    added = set()
    with tarfile.open(sdist_path, "w:gz") as tar:
        for path in paths:
            if path in added or not os.path.exists(path):
                continue
            added.add(path)
            tar.add(path, arcname=os.path.join(sdist_name, path), filter=_skip_build_output)
    return sdist_filename


def _skip_build_output(info):
    if any(p in ("zig-out", ".zig-cache", "__pycache__") for p in info.name.split("/")):
        return None
    return info


def _get_project_list(field):
    """A one-line TOML string array such as ``py-packages = ["a", "b"]``."""
    try:
        with open("pyproject.toml") as f:
            for line in f:
                m = re.match(rf"^{re.escape(field)}\s*=\s*\[(.*)\]", line.strip())
                if m:
                    return [a or b for a, b in re.findall(r'"([^"]+)"|\'([^\']+)\'', m.group(1))]
    except FileNotFoundError:
        pass
    return []


def _get_project_field(field):
    try:
        with open("pyproject.toml") as f:
            for line in f:
                m = re.match(rf'^{field}\s*=\s*"(.+)"', line)
                if m:
                    return m.group(1)
    except FileNotFoundError:
        pass
    return "unknown" if field == "name" else "0.0.0"
