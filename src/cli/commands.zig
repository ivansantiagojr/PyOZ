const std = @import("std");
const builtin = @import("builtin");
const version = @import("version");

const project = @import("project.zig");
const builder = @import("builder.zig");
const wheel = @import("wheel.zig");
const symreader = @import("symreader.zig");
const sys = @import("sys.zig");
const target_mod = @import("target.zig");

pub const Ctx = sys.Ctx;

/// Initialize a new PyOZ project
pub fn init(ctx: Ctx, args: []const []const u8) !void {
    var project_name: ?[]const u8 = null;
    var show_help = false;
    var in_current_dir = false;
    var local_pyoz_path: ?[]const u8 = null;
    var package_layout = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--path") or std.mem.eql(u8, arg, "-p")) {
            in_current_dir = true;
        } else if (std.mem.eql(u8, arg, "--package") or std.mem.eql(u8, arg, "-k")) {
            package_layout = true;
        } else if (std.mem.eql(u8, arg, "--local") or std.mem.eql(u8, arg, "-l")) {
            // Next arg must be the path
            if (i + 1 < args.len and !std.mem.startsWith(u8, args[i + 1], "-")) {
                i += 1;
                local_pyoz_path = args[i];
            } else {
                std.debug.print("Error: --local requires a path argument\n", .{});
                std.debug.print("  pyoz init --local /path/to/PyOZ myproject\n", .{});
                return error.MissingLocalPath;
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            project_name = arg;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: pyoz init [options] [name]
            \\
            \\Create a new PyOZ project.
            \\
            \\Arguments:
            \\  name                Project name (required unless using --path)
            \\
            \\Options:
            \\  -p, --path          Initialize in current directory instead of creating new one
            \\  -k, --package       Create a Python package layout (recommended for larger projects)
            \\  -l, --local <path>  Use local PyOZ path instead of fetching from URL
            \\  -h, --help          Show this help message
            \\
            \\Examples:
            \\  pyoz init myproject                        # Create with URL dependency (flat layout)
            \\  pyoz init --package myproject              # Create with package directory layout
            \\  pyoz init --local /path/to/PyOZ myproject  # Use local PyOZ path
            \\  pyoz init --path                           # Initialize in current directory
            \\  pyoz init --path mymod                     # Initialize in current dir with name 'mymod'
            \\
        , .{});
        return;
    }

    try project.create(ctx, project_name, in_current_dir, local_pyoz_path, package_layout);
}

/// Build the extension module and create a wheel
pub fn build(ctx: Ctx, args: []const []const u8) !void {
    const allocator = ctx.gpa;
    var opts: wheel.WheelOptions = .{};
    var show_help = false;
    var targets: std.ArrayList(target_mod.Target) = .empty;
    defer targets.deinit(allocator);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--release") or std.mem.eql(u8, arg, "-r")) {
            opts.release = true;
        } else if (std.mem.eql(u8, arg, "--debug") or std.mem.eql(u8, arg, "-d")) {
            opts.release = false;
        } else if (std.mem.eql(u8, arg, "--no-stubs")) {
            opts.stubs = false;
        } else if (std.mem.eql(u8, arg, "--stubs")) {
            opts.stubs = true;
        } else if (std.mem.eql(u8, arg, "--native")) {
            opts.native = true;
        } else if (optionValue(args, &i, "--target")) |value| {
            try parseTargets(allocator, &targets, value orelse return error.MissingTarget);
        } else if (optionValue(args, &i, "--python")) |value| {
            const v = value orelse return error.MissingPython;
            opts.python = target_mod.Python.parse(v) catch |err| {
                std.debug.print("Error: invalid --python '{s}' (expected e.g. 3.12 or 3.14t, 3.10 or newer)\n", .{v});
                return err;
            };
        } else {
            std.debug.print("Error: unknown option '{s}' (see pyoz build --help)\n", .{arg});
            return error.UnknownOption;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: pyoz build [options]
            \\
            \\Build the extension module and create a wheel package.
            \\
            \\Wheels are portable: built for a baseline CPU, glibc 2.17 on Linux
            \\(manylinux_2_17) and macOS 13.0, with the platform tag read from the
            \\built binary.
            \\
            \\Options:
            \\  -d, --debug          Build in debug mode (default)
            \\  -r, --release        Build in release mode (optimized)
            \\  --target <targets>   Build for other platforms: comma-separated
            \\                       x86_64-linux, aarch64-linux, x86_64-macos,
            \\                       aarch64-macos, x86_64-windows, aarch64-windows,
            \\                       or "all" (default: this machine's platform)
            \\  --python <version>   CPython to build for, e.g. 3.12 or 3.14t
            \\                       (default: the python3 on PATH)
            \\  --native             Build for this machine's CPU only (not for
            \\                       distribution)
            \\  --stubs              Generate .pyi type stub file (default)
            \\  --no-stubs           Do not generate .pyi type stub file
            \\  -h, --help           Show this help message
            \\
            \\Headers for other platforms or Python versions are downloaded once
            \\(python-build-standalone) and cached.
            \\The wheels are placed in the dist/ directory.
            \\
        , .{});
        return;
    }

    opts.targets = targets.items;
    const paths = try wheel.buildWheels(ctx, opts);
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
}

/// `--name value` or `--name=value`: returns null if `args[i.*]` is another
/// option, `.{null}` if the value is missing.
fn optionValue(args: []const []const u8, i: *usize, comptime name: []const u8) ??[]const u8 {
    const arg = args[i.*];
    if (std.mem.startsWith(u8, arg, name ++ "=")) return arg[name.len + 1 ..];
    if (!std.mem.eql(u8, arg, name)) return null;
    if (i.* + 1 >= args.len) {
        std.debug.print("Error: {s} needs a value\n", .{name});
        return @as(?[]const u8, null);
    }
    i.* += 1;
    return args[i.*];
}

/// Comma-separated targets or "all"; duplicates are ignored.
pub fn parseTargets(allocator: std.mem.Allocator, out: *std.ArrayList(target_mod.Target), value: []const u8) !void {
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |raw| {
        const name = std.mem.trim(u8, raw, " ");
        if (name.len == 0) continue;
        const parsed: []const target_mod.Target = if (std.mem.eql(u8, name, "all"))
            &target_mod.Target.all
        else
            &.{target_mod.Target.parse(name) catch |err| {
                std.debug.print("Error: unknown target '{s}' (e.g. x86_64-linux, aarch64-macos, x86_64-windows, all)\n", .{name});
                return err;
            }};
        for (parsed) |t| {
            for (out.items) |existing| {
                if (existing.eql(t)) break;
            } else try out.append(allocator, t);
        }
    }
}

/// Build and install in development mode
pub fn develop(ctx: Ctx, args: []const []const u8) !void {
    var show_help = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: pyoz develop
            \\
            \\Build the module and install it in development mode.
            \\Creates a symlink so changes are reflected after rebuilding.
            \\
            \\Options:
            \\  -h, --help  Show this help message
            \\
        , .{});
        return;
    }

    try builder.developMode(ctx);
}

/// Publish wheel(s) to PyPI
pub fn publish(ctx: Ctx, args: []const []const u8) !void {
    var show_help = false;
    var test_pypi = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--test") or std.mem.eql(u8, arg, "-t")) {
            test_pypi = true;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: pyoz publish [options]
            \\
            \\Publish wheel(s) from dist/ to PyPI.
            \\
            \\Options:
            \\  -t, --test  Upload to TestPyPI instead of PyPI
            \\  -h, --help  Show this help message
            \\
            \\Authentication:
            \\  Set PYPI_TOKEN environment variable with your API token.
            \\  For TestPyPI, use TEST_PYPI_TOKEN instead.
            \\
            \\  Generate tokens at:
            \\    PyPI:     https://pypi.org/manage/account/token/
            \\    TestPyPI: https://test.pypi.org/manage/account/token/
            \\
        , .{});
        return;
    }

    try wheel.publish(ctx, test_pypi);
}

/// Run embedded tests
pub fn runTests(ctx: Ctx, args: []const []const u8) !void {
    var release = false;
    var show_help = false;
    var verbose = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, arg, "--release") or std.mem.eql(u8, arg, "-r")) {
            release = true;
        } else if (std.mem.eql(u8, arg, "--verbose") or std.mem.eql(u8, arg, "-v")) {
            verbose = true;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: pyoz test [options]
            \\
            \\Run tests embedded in the module via pyoz.test() definitions.
            \\
            \\Options:
            \\  -r, --release  Build in release mode before testing
            \\  -v, --verbose  Verbose test output
            \\  -h, --help     Show this help message
            \\
        , .{});
        return;
    }

    try runEmbedded(ctx, .@"test", release, verbose);
}

/// Run embedded benchmarks
pub fn runBench(ctx: Ctx, args: []const []const u8) !void {
    var show_help = false;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            show_help = true;
        }
    }

    if (show_help) {
        std.debug.print(
            \\Usage: pyoz bench [options]
            \\
            \\Run benchmarks embedded in the module via pyoz.bench() definitions.
            \\Always builds in release mode.
            \\
            \\Options:
            \\  -h, --help  Show this help message
            \\
        , .{});
        return;
    }

    // Always build in release mode for benchmarks
    try runEmbedded(ctx, .bench, true, false);
}

const EmbeddedKind = enum {
    @"test",
    bench,

    fn noun(k: EmbeddedKind) []const u8 {
        return switch (k) {
            .@"test" => "test",
            .bench => "benchmark",
        };
    }

    fn scriptName(k: EmbeddedKind) []const u8 {
        return switch (k) {
            .@"test" => "__pyoz_test.py",
            .bench => "__pyoz_bench.py",
        };
    }

    fn printHowTo(k: EmbeddedKind) void {
        switch (k) {
            .@"test" => {
                std.debug.print("\nNo tests found in module.\n", .{});
                std.debug.print("Add .tests to your pyoz.module() config:\n\n", .{});
                std.debug.print("  .tests = &.{{\n", .{});
                std.debug.print("      pyoz.@\"test\"(\"my test\",\n", .{});
                std.debug.print("          \\\\assert mymod.add(2, 3) == 5\n", .{});
                std.debug.print("      ),\n", .{});
                std.debug.print("  }},\n", .{});
            },
            .bench => {
                std.debug.print("\nNo benchmarks found in module.\n", .{});
                std.debug.print("Add .benchmarks to your pyoz.module() config:\n\n", .{});
                std.debug.print("  .benchmarks = &.{{\n", .{});
                std.debug.print("      pyoz.bench(\"my benchmark\",\n", .{});
                std.debug.print("          \\\\mymod.add(100, 200)\n", .{});
                std.debug.print("      ),\n", .{});
                std.debug.print("  }},\n", .{});
            },
        }
    }
};

/// Shared pipeline for `pyoz test` and `pyoz bench`: build, extract the embedded
/// Python script from the module, syntax-check it, and run it with PYTHONPATH set.
fn runEmbedded(ctx: Ctx, kind: EmbeddedKind, release: bool, verbose: bool) !void {
    const allocator = ctx.gpa;
    const io = ctx.io;
    const cwd = std.Io.Dir.cwd();

    var config = project.toml.loadPyProject(allocator, io) catch |err| {
        if (err == error.PyProjectNotFound) {
            std.debug.print("Error: pyproject.toml not found. Run 'pyoz init' first.\n", .{});
        }
        return err;
    };
    defer config.deinit(allocator);

    // Package mode: py-packages contains the project name
    const is_package_mode = for (config.py_packages.items) |pkg| {
        if (std.mem.eql(u8, pkg, config.name)) break true;
    } else false;

    var build_result = try builder.buildModule(ctx, .{ .release = release });
    defer build_result.deinit(allocator);

    // In package mode, copy .pyd/.so into the package directory so `import pkg` works
    if (is_package_mode) {
        const pkg_module_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ config.name, build_result.module_name });
        defer allocator.free(pkg_module_path);
        cwd.copyFile(build_result.module_path, cwd, pkg_module_path, io, .{}) catch |err| {
            std.debug.print("Warning: Could not copy module into package directory: {s}\n", .{@errorName(err)});
        };
    }

    const extracted = switch (kind) {
        .@"test" => symreader.extractTests(io, allocator, build_result.module_path),
        .bench => symreader.extractBenchmarks(io, allocator, build_result.module_path),
    } catch |err| {
        std.debug.print("Error: Could not extract {s}s: {}\n", .{ kind.noun(), err });
        return err;
    };
    const content = extracted orelse "";
    if (content.len == 0) {
        kind.printHowTo();
        return;
    }
    defer allocator.free(content);

    // On Windows, Zig places DLLs (.pyd) in zig-out/bin/
    const out_dir = if (builtin.os.tag == .windows) "zig-out/bin" else "zig-out/lib";
    const script = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ out_dir, kind.scriptName() });
    defer allocator.free(script);

    cwd.writeFile(io, .{ .sub_path = script, .data = content }) catch |err| {
        std.debug.print("Error: Could not write {s} file: {s}\n", .{ kind.noun(), @errorName(err) });
        return err;
    };

    const python_cmd = builder.getPythonCommand();
    if (!try sys.runInherit(io, &.{ python_cmd, "-m", "py_compile", script }, .{ .stdout = .ignore })) {
        std.debug.print("\nSyntax error in generated {s} file.\n", .{kind.noun()});
        switch (kind) {
            .@"test" => std.debug.print("Check the Python code in your pyoz.@\"test\"() definitions.\n", .{}),
            .bench => std.debug.print("Check the Python code in your pyoz.bench() definitions.\n", .{}),
        }
        std.process.exit(1);
    }

    std.debug.print("\nRunning {s}s...\n\n", .{kind.noun()});

    // PYTHONPATH = [.:]<out_dir>[:<existing>]; package mode adds the project root
    const sep = if (builtin.os.tag == .windows) ";" else ":";
    var pp: std.ArrayList(u8) = .empty;
    defer pp.deinit(allocator);
    if (is_package_mode) try pp.appendSlice(allocator, "." ++ sep);
    try pp.appendSlice(allocator, out_dir);
    if (ctx.environ.get("PYTHONPATH")) |existing| {
        if (existing.len > 0) {
            try pp.appendSlice(allocator, sep);
            try pp.appendSlice(allocator, existing);
        }
    }

    var env_map = try ctx.environ.clone(allocator);
    defer env_map.deinit();
    try env_map.put("PYTHONPATH", pp.items);

    const ok = switch (kind) {
        .@"test" => blk: {
            const base = [_][]const u8{ python_cmd, "-m", "unittest", script, "-v" };
            const argv: []const []const u8 = if (verbose) &base else base[0..4];
            break :blk try sys.runInherit(io, argv, .{ .environ_map = &env_map });
        },
        .bench => try sys.runInherit(io, &.{ python_cmd, script }, .{ .environ_map = &env_map }),
    };
    if (!ok) std.process.exit(1);
}
