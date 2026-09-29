const std = @import("std");
const builtin = @import("builtin");
const project = @import("project.zig");
const symreader = @import("symreader.zig");
const sys = @import("sys.zig");
const version = @import("version");
const target_mod = @import("target.zig");
const pyheaders = @import("pyheaders.zig");
const Target = target_mod.Target;
const Python = target_mod.Python;
const Ctx = sys.Ctx;
const Io = std.Io;

/// Python configuration detected from the system
pub const PythonConfig = struct {
    version_major: u8,
    version_minor: u8,
    version_str: []const u8,
    include_dir: []const u8,
    lib_dir: ?[]const u8,
    lib_name: []const u8,
    /// Free-threaded (PEP 703) interpreter, e.g. python3.14t
    gil_disabled: bool = false,

    pub fn deinit(self: *PythonConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.version_str);
        allocator.free(self.include_dir);
        if (self.lib_dir) |ld| allocator.free(ld);
        allocator.free(self.lib_name);
    }

    /// Get Python tag for wheel (e.g., "cp310")
    pub fn pythonTag(self: PythonConfig) [8]u8 {
        var buf: [8]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "cp{d}{d}", .{ self.version_major, self.version_minor }) catch unreachable;
        return buf;
    }
};

/// Get the Python executable name for the current platform
pub fn getPythonCommand() []const u8 {
    return if (builtin.os.tag == .windows) "python" else "python3";
}

/// Detect Python configuration using sysconfig (cross-platform)
pub fn detectPython(allocator: std.mem.Allocator, io: Io) !PythonConfig {
    const python_cmd = getPythonCommand();

    // Get Python version
    const version_result = try runCommand(allocator, io, &.{
        python_cmd, "-c", "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')",
    });
    defer allocator.free(version_result);
    const version_trimmed = std.mem.trim(u8, version_result, &std.ascii.whitespace);

    // Parse version
    var version_major: u8 = 3;
    var version_minor: u8 = 0;
    if (std.mem.indexOf(u8, version_trimmed, ".")) |dot| {
        version_major = std.fmt.parseInt(u8, version_trimmed[0..dot], 10) catch 3;
        version_minor = std.fmt.parseInt(u8, version_trimmed[dot + 1 ..], 10) catch 0;
    }

    const version_str = try allocator.dupe(u8, version_trimmed);
    errdefer allocator.free(version_str);

    // Get include directory using sysconfig (cross-platform)
    const include_result = try runCommand(allocator, io, &.{
        python_cmd, "-c", "import sysconfig; print(sysconfig.get_path('include'))",
    });
    defer allocator.free(include_result);
    const include_trimmed = std.mem.trim(u8, include_result, &std.ascii.whitespace);

    // (errdefer above already frees version_str; freeing it here too was a double free)
    if (include_trimmed.len == 0) return error.PythonNotFound;

    const include_dir = try allocator.dupe(u8, include_trimmed);
    errdefer allocator.free(include_dir);

    // Get library directory using sysconfig (cross-platform)
    var lib_dir: ?[]const u8 = null;
    if (runCommand(allocator, io, &.{
        python_cmd,
        "-c",
        "import sysconfig,sys,os;d=sysconfig.get_config_var('LIBDIR');print(d if d else os.path.join(sys.prefix,'libs' if sys.platform=='win32' else 'lib'))",
    })) |libdir_result| {
        defer allocator.free(libdir_result);
        const libdir_trimmed = std.mem.trim(u8, libdir_result, &std.ascii.whitespace);
        if (libdir_trimmed.len > 0) {
            lib_dir = try allocator.dupe(u8, libdir_trimmed);
        }
    } else |_| {}

    // Free-threaded builds (PEP 703) use a "t" ABI flag: libpython3.14t, cp314t wheels
    const gil_disabled = blk: {
        const r = runCommand(allocator, io, &.{
            python_cmd, "-c", "import sysconfig;print(1 if sysconfig.get_config_var('Py_GIL_DISABLED') else 0)",
        }) catch break :blk false;
        defer allocator.free(r);
        break :blk std.mem.eql(u8, std.mem.trim(u8, r, &std.ascii.whitespace), "1");
    };
    const t_flag: []const u8 = if (gil_disabled) "t" else "";

    // Construct library name based on platform
    const lib_name = if (builtin.os.tag == .windows)
        // Windows uses python<major><minor>[t] (no dot), e.g., python313, python314t
        try std.fmt.allocPrint(allocator, "python{d}{d}{s}", .{ version_major, version_minor, t_flag })
    else
        // Unix uses python<major>.<minor>[t], e.g., python3.13, python3.14t
        try std.fmt.allocPrint(allocator, "python{s}{s}", .{ version_str, t_flag });

    return PythonConfig{
        .version_major = version_major,
        .version_minor = version_minor,
        .version_str = version_str,
        .include_dir = include_dir,
        .lib_dir = lib_dir,
        .lib_name = lib_name,
        .gil_disabled = gil_disabled,
    };
}

/// Build result with path to the compiled module
pub const BuildResult = struct {
    module_path: []const u8,
    module_name: []const u8,
    /// CPython the module was built for
    python: Python,
    /// Portable build target, or null for a native build of this machine
    target: ?Target,

    pub fn deinit(self: *BuildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.module_path);
        allocator.free(self.module_name);
    }
};

pub const BuildOptions = struct {
    release: bool = false,
    /// Build a portable module for this target (wheels). null builds for this
    /// machine exactly (native CPU and libc), for development and tests.
    target: ?Target = null,
    /// CPython version to build for; null means the `python3` on PATH.
    python: ?Python = null,
    /// Oldest glibc a Linux build may require
    glibc: target_mod.Glibc = .{},
};

/// Build the extension module (shared library)
/// Returns the path to the built .so/.pyd file
pub fn buildModule(ctx: Ctx, opts: BuildOptions) !BuildResult {
    const allocator = ctx.gpa;
    const io = ctx.io;
    // Load project configuration
    var config = project.toml.loadPyProject(allocator, io) catch |err| {
        if (err == error.PyProjectNotFound) {
            std.debug.print("Error: pyproject.toml not found. Run 'pyoz init' first.\n", .{});
            return err;
        }
        std.debug.print("Error: Failed to parse pyproject.toml\n", .{});
        return err;
    };
    defer config.deinit(allocator);

    const release = opts.release;
    const host = Target.host() orelse return error.UnsupportedHost;
    const target = opts.target orelse host;
    var target_buf: [32]u8 = undefined;

    // Determine build type display string
    const optimize_setting = config.getOptimize();
    const build_type = if (release) "Release" else if (optimize_setting.len > 0) optimize_setting else "Debug";
    std.debug.print("Building {s} v{s} ({s}, {s}{s})...\n", .{ config.name, config.getVersion(), build_type, target.name(&target_buf), if (opts.target == null) ", native" else "" });

    // The host interpreter supplies the default Python version and, when it
    // matches the build, its own headers; it is optional when both are given.
    var host_python: ?PythonConfig = detectPython(allocator, io) catch null;
    defer if (host_python) |*p| p.deinit(allocator);
    const host_spec: ?Python = if (host_python) |p| .{ .minor = p.version_minor, .freethreaded = p.gil_disabled } else null;

    const py: Python = opts.python orelse host_spec orelse {
        std.debug.print("Error: Could not detect Python. Make sure {s} is in PATH, or pass --python.\n", .{getPythonCommand()});
        return error.PythonNotFound;
    };
    var py_buf: [16]u8 = undefined;
    std.debug.print("  Python {s}\n", .{py.name(&py_buf)});
    std.debug.print("  Module: {s}\n", .{config.getModulePath()});

    // Headers: the host's if they match, otherwise python-build-standalone's
    const use_host_headers = target.isHost() and host_spec != null and host_spec.?.eql(py);
    var downloaded: ?pyheaders.Headers = null;
    defer if (downloaded) |*h| h.deinit(allocator);
    if (!use_host_headers) downloaded = try pyheaders.get(ctx, target, py);

    if (!sys.exists(io, "build.zig")) {
        std.debug.print("Error: build.zig not found. Please create a build.zig file.\n", .{});
        std.debug.print("Run 'pyoz init --path' to generate one in the current directory.\n", .{});
        return error.NoBuildZig;
    }
    std.debug.print("  Using build.zig\n", .{});
    try checkZig(allocator, io);

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    var owned_args: std.ArrayList([]u8) = .empty;
    defer {
        for (owned_args.items) |a| allocator.free(a);
        owned_args.deinit(allocator);
    }
    try argv.appendSlice(allocator, &.{ "zig", "build" });

    // - If --release flag is passed, always use ReleaseFast
    // - Otherwise, use the optimize setting from pyproject.toml (empty = debug)
    const optimize_value = if (release) "ReleaseFast" else config.getOptimize();
    if (optimize_value.len > 0) {
        try owned_args.append(allocator, try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{optimize_value}));
        try argv.append(allocator, owned_args.getLast());
    }

    // Pass strip option if enabled in pyproject.toml
    if (config.strip) {
        std.debug.print("  Strip: enabled\n", .{});
        try argv.append(allocator, "-Dstrip=true");
    }

    // Portable build: explicit target (libc/OS floor) and baseline CPU, so
    // the module runs on machines other than this one.
    if (opts.target != null) {
        var triple_buf: [64]u8 = undefined;
        const triple = target.zigTriple(&triple_buf, opts.glibc);
        std.debug.print("  Target: {s}, baseline CPU\n", .{triple});
        try owned_args.append(allocator, try std.fmt.allocPrint(allocator, "-Dtarget={s}", .{triple}));
        try argv.append(allocator, owned_args.getLast());
        try argv.append(allocator, "-Dcpu=baseline");
    }

    // Windows links against the Python import library (python3.lib for the
    // Stable ABI, python3XY[t].lib otherwise); Unix resolves symbols at load time.
    if (target.os == .windows) {
        const lib_dir: ?[]const u8 = if (downloaded) |h| h.lib_dir else if (host_python) |p| p.lib_dir else null;
        if (lib_dir) |d| {
            try owned_args.append(allocator, try std.fmt.allocPrint(allocator, "-Dpython-lib-dir={s}", .{d}));
            try argv.append(allocator, owned_args.getLast());
        }
        try owned_args.append(allocator, if (config.getAbi3())
            try allocator.dupe(u8, "-Dpython-lib-name=python3")
        else
            try std.fmt.allocPrint(allocator, "-Dpython-lib-name=python3{d}{s}", .{ py.minor, if (py.freethreaded) "t" else "" }));
        try argv.append(allocator, owned_args.getLast());
    }

    // Headers reach PyOZ's build.zig through the environment (a dependency
    // does not see the project's -D options).
    var env: ?std.process.Environ.Map = null;
    defer if (env) |*e| e.deinit();
    if (downloaded) |h| {
        env = try ctx.environ.clone(allocator);
        try env.?.put("PYOZ_PYTHON_INCLUDE", h.include_dir);
    }

    if (!try sys.runInherit(io, argv.items, .{ .environ_map = if (env) |*e| e else null })) {
        std.debug.print("\nBuild failed!\n", .{});
        return error.BuildFailed;
    }

    const module_name = try std.fmt.allocPrint(allocator, "{s}{s}", .{ config.getModuleName(), target.extension() });
    errdefer allocator.free(module_name);
    const module_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ target.outDir(), module_name });
    errdefer allocator.free(module_path);

    // Validate that the compiled module exports the correct PyInit_ function.
    // Catches mismatches between module-name in pyproject.toml and the Zig export function.
    const mod_name = config.getModuleName();
    const expected_init = try std.fmt.allocPrint(allocator, "PyInit_{s}", .{mod_name});
    defer allocator.free(expected_init);

    if (!symreader.hasExportSymbol(io, allocator, module_path, expected_init)) {
        std.debug.print("\nWarning: Module '{s}' does not export '{s}'.\n", .{ module_path, expected_init });
        std.debug.print("Python will fail with: ImportError: dynamic module does not define module export function ({s})\n", .{expected_init});
        std.debug.print("\nTo fix, ensure your Zig source has:\n", .{});
        std.debug.print("  pub export fn {s}() ?*pyoz.PyObject {{\n", .{expected_init});
        std.debug.print("      return Module.init();\n  }}\n\n", .{});
        std.debug.print("And that .name in pyoz.module() matches: .name = \"{s}\"\n", .{mod_name});
    }

    return BuildResult{
        .module_path = module_path,
        .module_name = module_name,
        .python = py,
        .target = opts.target,
    };
}

/// Build and install in development mode: build a PEP 660 editable wheel
/// (see wheel.buildEditableWheel) and install it with pip. The result is a
/// standard install: `pip list` shows it and `pip uninstall` removes it.
pub fn developMode(ctx: Ctx) !void {
    const allocator = ctx.gpa;
    const io = ctx.io;
    const wheel = @import("wheel.zig");

    std.debug.print("Installing in development mode (editable)...\n", .{});
    const whl = try wheel.buildEditableWheel(ctx, "zig-out/editable");
    defer allocator.free(whl);

    const python_cmd = getPythonCommand();
    const ok = sys.runInherit(io, &.{ python_cmd, "-m", "pip", "install", "--force-reinstall", "--no-deps", "--quiet", whl }, .{}) catch false;
    if (!ok) {
        std.debug.print("\nError: '{s} -m pip install {s}' failed.\n", .{ python_cmd, whl });
        std.debug.print("Make sure pip is available in the active environment, or install the wheel manually.\n", .{});
        return error.PipInstallFailed;
    }
    std.debug.print("\nDevelopment install complete (editable). Rebuild with 'zig build' or 'pyoz develop';\n", .{});
    std.debug.print("remove with '{s} -m pip uninstall <name>'.\n", .{python_cmd});
}

/// Fail clearly if `zig` is missing, and warn if it is not the Zig release
/// this PyOZ targets (a different minor release usually fails to compile
/// build.zig with errors that don't mention the version).
fn checkZig(allocator: std.mem.Allocator, io: Io) !void {
    const out = sys.runCapture(allocator, io, &.{ "zig", "version" }) catch {
        std.debug.print("Error: `zig` not found on PATH. PyOZ {s} needs Zig {s}: https://ziglang.org/download/\n", .{ version.string, version.zig });
        return error.ZigNotFound;
    };
    defer allocator.free(out);
    const found = std.mem.trim(u8, out, &std.ascii.whitespace);
    if (!sameMinor(found, version.zig)) {
        std.debug.print("  Warning: PyOZ {s} is built for Zig {s}, but `zig` on PATH is {s}; the build may fail.\n", .{ version.string, version.zig, found });
    }
}

/// True if both versions share major.minor ("0.16.1" vs "0.16.0").
fn sameMinor(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, majorMinor(a), majorMinor(b));
}

fn majorMinor(v: []const u8) []const u8 {
    const first = std.mem.indexOfScalar(u8, v, '.') orelse return v;
    const second = std.mem.indexOfScalarPos(u8, v, first + 1, '.') orelse return v;
    return v[0..second];
}

test sameMinor {
    try std.testing.expect(sameMinor("0.16.0", "0.16.0"));
    try std.testing.expect(sameMinor("0.16.1", "0.16.0"));
    try std.testing.expect(!sameMinor("0.17.0-dev.2329+1b7a78122", "0.16.0"));
    try std.testing.expect(!sameMinor("0.1.0", "0.16.0"));
}

test "Zig version pins agree with version.zig" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const cwd = Io.Dir.cwd();
    // pip backend: "0.16." prefix and ziglang>=0.16.0,<0.17
    const series = version.zig[0 .. majorMinor(version.zig).len + 1];
    const next_minor = try std.fmt.parseInt(u32, majorMinor(version.zig)[2..], 10) + 1;
    const backend_series = try std.fmt.allocPrint(gpa, "ZIG_SERIES = \"{s}\"", .{series});
    defer gpa.free(backend_series);
    const backend_req = try std.fmt.allocPrint(gpa, "ziglang>={s},<0.{d}", .{ version.zig, next_minor });
    defer gpa.free(backend_req);
    const zon_pin = "minimum_zig_version = \"" ++ version.zig ++ "\"";
    const ci_pin = "version: " ++ version.zig;

    const checks = [_]struct { path: []const u8, needles: []const []const u8 }{
        .{ .path = "build.zig.zon", .needles = &.{zon_pin} },
        .{ .path = "pypi/build.zig.zon", .needles = &.{zon_pin} },
        .{ .path = "pypi/pyoz/backend.py", .needles = &.{ backend_series, backend_req } },
        .{ .path = ".github/workflows/ci.yml", .needles = &.{ci_pin} },
        .{ .path = ".github/workflows/release.yml", .needles = &.{ci_pin} },
        .{ .path = "docs/installation.md", .needles = &.{"**Zig** " ++ version.zig} },
    };
    for (checks) |check| {
        const content = cwd.readFileAlloc(io, check.path, gpa, .limited(1 << 20)) catch |err| {
            std.debug.print("cannot read {s}: {}\n", .{ check.path, err });
            return err;
        };
        defer gpa.free(content);
        for (check.needles) |needle| {
            if (std.mem.indexOf(u8, content, needle) == null) {
                std.debug.print("{s} does not pin Zig {s} (expected `{s}`)\n", .{ check.path, version.zig, needle });
                return error.ZigPinMismatch;
            }
        }
        // Every setup-zig step, not just one of them
        if (std.mem.endsWith(u8, check.path, ".yml")) {
            var lines = std.mem.splitScalar(u8, content, '\n');
            while (lines.next()) |line| {
                const t = std.mem.trim(u8, line, " ");
                if (std.mem.startsWith(u8, t, "version: 0.") and !std.mem.eql(u8, t, ci_pin)) {
                    std.debug.print("{s}: `{s}` does not match Zig {s}\n", .{ check.path, t, version.zig });
                    return error.ZigPinMismatch;
                }
            }
        }
    }
}

pub fn runCommand(allocator: std.mem.Allocator, io: Io, argv: []const []const u8) ![]const u8 {
    return sys.runCapture(allocator, io, argv);
}
