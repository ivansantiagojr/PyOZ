"""PyOZ - Python extension modules in Zig, made easy."""

import shutil
import sys

from ._pyoz import (
    build,
    cli_build,
    develop,
    init,
    publish,
    run_bench,
    run_tests,
    version,
)


def _check_zig():
    """Check that Zig is installed and available in PATH."""
    if shutil.which("zig") is None:
        print("Error: Zig compiler not found in PATH.")
        print()
        print("PyOZ requires Zig to build extensions. Install it from:")
        print("  https://ziglang.org/download/")
        print()
        print("Or via a package manager:")
        print("  brew install zig        # macOS")
        print("  snap install zig        # Linux")
        print("  scoop install zig       # Windows")
        sys.exit(1)


def _print_usage():
    ver = version()
    print(f"""pyoz {ver} - Build and package Zig Python extensions

Usage: pyoz <command> [options]

Commands:
  init          Create a new PyOZ project
  build         Build the extension module and create wheel
  develop       Build and install in development mode
  publish       Publish to PyPI
  test          Run embedded tests
  bench         Run embedded benchmarks

Options:
  -h, --help     Show this help message
  -V, --version  Show version information

Run 'pyoz <command> --help' for more information on a command.""")


def _cmd_init(args):
    name = None
    in_current_dir = False
    local_pyoz_path = None
    package_layout = False

    i = 0
    while i < len(args):
        arg = args[i]
        if arg in ("-h", "--help"):
            print("""Usage: pyoz init [options] [name]

Create a new PyOZ project.

Arguments:
  name                Project name (required unless using --path)

Options:
  -p, --path          Initialize in current directory instead of creating new one
  -k, --package       Create a Python package layout (recommended for larger projects)
  -l, --local <path>  Use local PyOZ path instead of fetching from URL
  -h, --help          Show this help message""")
            return
        elif arg in ("-p", "--path"):
            in_current_dir = True
        elif arg in ("-k", "--package"):
            package_layout = True
        elif arg in ("-l", "--local"):
            if i + 1 < len(args) and not args[i + 1].startswith("-"):
                i += 1
                local_pyoz_path = args[i]
            else:
                print("Error: --local requires a path argument")
                sys.exit(1)
        elif not arg.startswith("-"):
            name = arg
        i += 1

    _check_zig()
    init(name, in_current_dir, local_pyoz_path, package_layout)


def _cmd_build(args):
    # Same options as the native CLI (--release, --target, --python, --native, ...)
    if not any(a in ("-h", "--help") for a in args):
        _check_zig()
    cli_build(list(args))

def _cmd_develop(args):
    for arg in args:
        if arg in ("-h", "--help"):
            print("""Usage: pyoz develop

Build the module and install it in development mode.

Options:
  -h, --help  Show this help message""")
            return

    _check_zig()
    develop()


def _cmd_publish(args):
    test_pypi = False

    for arg in args:
        if arg in ("-h", "--help"):
            print("""Usage: pyoz publish [options]

Publish wheel(s) from dist/ to PyPI.

Options:
  -t, --test  Upload to TestPyPI instead of PyPI
  -h, --help  Show this help message""")
            return
        elif arg in ("-t", "--test"):
            test_pypi = True

    publish(test_pypi)


def _cmd_test(args):
    release = False
    verbose = False

    for arg in args:
        if arg in ("-h", "--help"):
            print("""Usage: pyoz test [options]

Run tests embedded in the module via pyoz.test() definitions.

Options:
  -r, --release  Build in release mode before testing
  -v, --verbose  Verbose test output
  -h, --help     Show this help message""")
            return
        elif arg in ("-r", "--release"):
            release = True
        elif arg in ("-v", "--verbose"):
            verbose = True

    _check_zig()
    run_tests(release, verbose)


def _cmd_bench(args):
    for arg in args:
        if arg in ("-h", "--help"):
            print("""Usage: pyoz bench

Run benchmarks embedded in the module via pyoz.bench() definitions.
Always builds in release mode.

Options:
  -h, --help  Show this help message""")
            return

    _check_zig()
    run_bench()


def main():
    """Entry point for the pyoz CLI."""
    args = sys.argv[1:]

    if not args or args[0] in ("-h", "--help"):
        _print_usage()
        return

    if args[0] in ("-V", "--version"):
        print(f"pyoz {version()}")
        return

    cmd = args[0]
    cmd_args = args[1:]

    try:
        _dispatch(cmd, cmd_args)
    except RuntimeError as e:
        # The native CLI already printed what went wrong; the exception only
        # carries the Zig error name, so exit without a traceback.
        print(f"pyoz {cmd} failed ({e})", file=sys.stderr)
        sys.exit(1)


def _dispatch(cmd, cmd_args):
    if cmd == "init":
        _cmd_init(cmd_args)
    elif cmd == "build":
        _cmd_build(cmd_args)
    elif cmd == "develop":
        _cmd_develop(cmd_args)
    elif cmd == "publish":
        _cmd_publish(cmd_args)
    elif cmd == "test":
        _cmd_test(cmd_args)
    elif cmd == "bench":
        _cmd_bench(cmd_args)
    else:
        print(f"Unknown command: {cmd}\n")
        _print_usage()
        sys.exit(1)
