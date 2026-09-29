const std = @import("std");
const builtin = @import("builtin");
const version = @import("version");
pub const toml = @import("toml.zig");
const sys = @import("sys.zig");
const Ctx = sys.Ctx;
const Io = std.Io;

/// Create a new PyOZ project
pub fn create(ctx: Ctx, name_opt: ?[]const u8, in_current_dir: bool, local_pyoz_path: ?[]const u8, package_layout: bool) !void {
    const allocator = ctx.gpa;
    const io = ctx.io;
    const cwd = Io.Dir.cwd();

    var name: []const u8 = undefined;
    var name_owned = false;
    defer if (name_owned) allocator.free(name);

    if (in_current_dir) {
        // Get name from argument or directory name
        if (name_opt) |n| {
            name = n;
        } else {
            var path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const len = try cwd.realPath(io, &path_buf);
            name = try allocator.dupe(u8, Io.Dir.path.basename(path_buf[0..len]));
            name_owned = true;
        }
    } else {
        name = name_opt orelse {
            std.debug.print("Error: Project name required when not using --path\n", .{});
            return error.MissingProjectName;
        };
    }

    // Validate *before* touching the filesystem, so a bad name doesn't leave
    // an empty directory behind.
    if (!isValidModuleName(name)) {
        std.debug.print("Error: '{s}' is not a valid Python module name\n", .{name});
        std.debug.print("Names must start with a letter and contain only letters, numbers, and underscores\n", .{});
        return error.InvalidModuleName;
    }

    var project_dir: Io.Dir = cwd;
    var created_dir = false;
    if (!in_current_dir) {
        cwd.createDir(io, name, .default_dir) catch |err| {
            if (err == error.PathAlreadyExists) {
                std.debug.print("Error: Directory '{s}' already exists\n", .{name});
                return error.DirectoryExists;
            }
            return err;
        };
        created_dir = true;
        project_dir = try cwd.openDir(io, name, .{});
    }
    defer if (created_dir) project_dir.close(io);

    std.debug.print("Creating PyOZ project: {s}\n", .{name});

    // Create directory structure
    try project_dir.createDir(io, "src", .default_dir);

    // Create pyproject.toml
    if (package_layout) {
        try writeTemplate(allocator, io, project_dir, "pyproject.toml", pyproject_package_template, name);
    } else {
        try writeTemplate(allocator, io, project_dir, "pyproject.toml", pyproject_template, name);
    }

    // Create src/lib.zig
    if (package_layout) {
        try writeTemplate(allocator, io, project_dir, "src/lib.zig", lib_zig_package_template, name);
    } else {
        try writeTemplate(allocator, io, project_dir, "src/lib.zig", lib_zig_template, name);
    }

    // Create build.zig (for users who want to use zig build directly)
    if (package_layout) {
        try writeTemplate(allocator, io, project_dir, "build.zig", build_zig_package_template, name);
    } else {
        try writeTemplate(allocator, io, project_dir, "build.zig", build_zig_template, name);
    }

    // Create Python package directory with __init__.py (package layout only)
    if (package_layout) {
        try project_dir.createDir(io, name, .default_dir);
        const init_py_content = try replaceInTemplate(allocator, init_py_template, name);
        defer allocator.free(init_py_content);
        const init_py_path = try std.fmt.allocPrint(allocator, "{s}/__init__.py", .{name});
        defer allocator.free(init_py_path);
        try project_dir.writeFile(io, .{ .sub_path = init_py_path, .data = init_py_content });
    }

    // Create build.zig.zon for dependency management
    var fp_buf: [18]u8 = undefined;
    const fingerprint = std.fmt.bufPrint(&fp_buf, "0x{x:0>16}", .{packageFingerprint(io, name)}) catch unreachable;

    if (local_pyoz_path) |local_path| {
        try writeLocalBuildZigZon(allocator, io, project_dir, name, fingerprint, local_path);
    } else {
        // `zig fetch --save` only records the hash when it adds the entry
        // itself (Zig 0.16 leaves an existing hash-less entry untouched), so
        // start with no dependencies and fall back to the URL-only entry.
        const zon = try replaceInTemplateExt(allocator, build_zig_zon_template, name, fingerprint);
        defer allocator.free(zon);
        const empty = try withoutPyOzDependency(allocator, zon);
        defer allocator.free(empty);
        try project_dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = empty });
        if (!fetchDependencyHash(allocator, io, project_dir)) {
            try project_dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = zon });
        }
    }

    // Create .gitignore
    try project_dir.writeFile(io, .{ .sub_path = ".gitignore", .data = gitignore_content });

    // Create README.md
    try writeTemplate(allocator, io, project_dir, "README.md", readme_template, name);

    if (package_layout) {
        std.debug.print(
            \\
            \\Project '{s}' created successfully! (package layout)
            \\
            \\Project structure:
            \\  {s}/
            \\  +-- pyproject.toml    # Project configuration
            \\  +-- build.zig         # Zig build script
            \\  +-- build.zig.zon     # Zig dependencies
            \\  +-- README.md
            \\  +-- .gitignore
            \\  +-- src/
            \\  |   +-- lib.zig       # Your Zig extension code
            \\  +-- {s}/
            \\      +-- __init__.py   # Python package entry point
            \\
            \\Next steps:
            \\
        , .{ name, name, name });
    } else {
        std.debug.print(
            \\
            \\Project '{s}' created successfully!
            \\
            \\Project structure:
            \\  {s}/
            \\  +-- pyproject.toml    # Project configuration
            \\  +-- build.zig         # Zig build script
            \\  +-- build.zig.zon     # Zig dependencies
            \\  +-- README.md
            \\  +-- .gitignore
            \\  +-- src/
            \\      +-- lib.zig       # Your module code
            \\
            \\Next steps:
            \\
        , .{ name, name });
    }

    if (!in_current_dir) {
        std.debug.print("  cd {s}\n", .{name});
    }

    std.debug.print(
        \\  pyoz build            # Build the extension
        \\  pyoz develop          # Install in development mode
        \\  python -c "import {s}; print({s}.add(2, 3))"
        \\
    , .{ name, name });
}

fn isValidModuleName(name: []const u8) bool {
    if (name.len == 0) return false;

    // Must start with letter or underscore
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;

    // Rest must be alphanumeric or underscore
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }

    // Check against Python keywords
    const keywords = [_][]const u8{
        "False",   "None",     "True",     "and",    "as",   "assert", "async",  "await",
        "break",   "class",    "continue", "def",    "del",  "elif",   "else",   "except",
        "finally", "for",      "from",     "global", "if",   "import", "in",     "is",
        "lambda",  "nonlocal", "not",      "or",     "pass", "raise",  "return", "try",
        "while",   "with",     "yield",
    };

    for (keywords) |kw| {
        if (std.mem.eql(u8, name, kw)) return false;
    }

    return true;
}

/// Zig package fingerprint: high 32 bits are crc32(name), low 32 bits a random id
/// (never 0 or 0xffffffff). Generating it here avoids running a whole
/// `zig build` just to scrape the compiler's suggestion from stderr.
fn packageFingerprint(io: std.Io, name: []const u8) u64 {
    var id_bytes: [4]u8 = undefined;
    io.random(&id_bytes);
    var id = std.mem.readInt(u32, &id_bytes, .little);
    if (id == 0 or id == 0xffffffff) id = 1;
    return (@as(u64, std.hash.Crc32.hash(name)) << 32) | id;
}

test packageFingerprint {
    // PyOZ's own build.zig.zon fingerprint shares the crc32("PyOZ") high half
    const fp = packageFingerprint(std.testing.io, "PyOZ");
    try std.testing.expectEqual(@as(u32, 0x4d366841), @as(u32, @truncate(fp >> 32)));
}

fn replaceInTemplate(allocator: std.mem.Allocator, template: []const u8, name: []const u8) ![]u8 {
    return replaceInTemplateExt(allocator, template, name, "");
}

fn replaceInTemplateExt(allocator: std.mem.Allocator, template: []const u8, name: []const u8, fingerprint: []const u8) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var i: usize = 0;
    while (i < template.len) {
        if (i + 9 <= template.len and std.mem.eql(u8, template[i .. i + 9], "{[name]s}")) {
            try result.appendSlice(allocator, name);
            i += 9;
        } else if (std.mem.startsWith(u8, template[i..], "{[fingerprint]s}")) {
            try result.appendSlice(allocator, fingerprint);
            i += "{[fingerprint]s}".len;
        } else if (i + 17 <= template.len and std.mem.eql(u8, template[i .. i + 17], "{[pyoz_version]s}")) {
            try result.appendSlice(allocator, version.string);
            i += 17;
        } else {
            try result.append(allocator, template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice(allocator);
}

fn writeTemplate(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    path: []const u8,
    template: []const u8,
    name: []const u8,
) !void {
    const content = try replaceInTemplate(allocator, template, name);
    defer allocator.free(content);
    try dir.writeFile(io, .{ .sub_path = path, .data = content });
}

/// Compute relative path from `from_path` to `to_path`
fn computeRelativePath(allocator: std.mem.Allocator, from_path: []const u8, to_path: []const u8) ![]const u8 {
    return relativePath(allocator, from_path, to_path, builtin.os.tag == .windows);
}

/// Relative path from `from_path` to `to_path` (both absolute), always with
/// '/' separators: build.zig.zon strings then need no escaping, and Zig
/// accepts '/' on Windows. Windows paths compare case-insensitively; on
/// different drives there is no relative path, so `to_path` is returned.
fn relativePath(allocator: std.mem.Allocator, from_path: []const u8, to_path: []const u8, windows: bool) ![]const u8 {
    const seps = if (windows) "/\\" else "/";
    var from_parts: std.ArrayList([]const u8) = .empty;
    defer from_parts.deinit(allocator);
    var to_parts: std.ArrayList([]const u8) = .empty;
    defer to_parts.deinit(allocator);

    var from_it = std.mem.tokenizeAny(u8, from_path, seps);
    while (from_it.next()) |part| try from_parts.append(allocator, part);
    var to_it = std.mem.tokenizeAny(u8, to_path, seps);
    while (to_it.next()) |part| try to_parts.append(allocator, part);

    const eql = struct {
        fn f(win: bool, a: []const u8, b: []const u8) bool {
            return if (win) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
        }
    }.f;

    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    // Different drives (D: vs C:): use the absolute path
    if (windows and (from_parts.items.len == 0 or to_parts.items.len == 0 or !eql(true, from_parts.items[0], to_parts.items[0]))) {
        for (to_path) |c| try result.append(allocator, if (c == '\\') '/' else c);
        return result.toOwnedSlice(allocator);
    }

    // Find common prefix length
    var common: usize = 0;
    while (common < from_parts.items.len and common < to_parts.items.len) {
        if (!eql(windows, from_parts.items[common], to_parts.items[common])) break;
        common += 1;
    }

    // Go up from `from`, then down to `to`
    for (0..from_parts.items.len - common) |_| try result.appendSlice(allocator, "../");
    for (to_parts.items[common..], 0..) |part, i| {
        if (i > 0) try result.append(allocator, '/');
        try result.appendSlice(allocator, part);
    }

    // Same directory
    if (result.items.len == 0) try result.append(allocator, '.');

    // Remove trailing slash if present
    if (result.items.len > 1 and result.items[result.items.len - 1] == '/') _ = result.pop();

    return result.toOwnedSlice(allocator);
}

test relativePath {
    const a = std.testing.allocator;
    const cases = [_]struct { from: []const u8, to: []const u8, win: bool, want: []const u8 }{
        .{ .from = "/home/u/proj/demo", .to = "/home/u/PyOZ", .win = false, .want = "../../PyOZ" },
        .{ .from = "/tmp/x", .to = "/home/y", .win = false, .want = "../../home/y" },
        .{ .from = "/a/b", .to = "/a/b", .win = false, .want = "." },
        // The CI failure: "../D:\\a\\PyOZ\\PyOZ" with unescaped backslashes
        .{ .from = "D:\\a\\PyOZ\\wheel-proj\\demo", .to = "D:\\a\\PyOZ\\PyOZ", .win = true, .want = "../../PyOZ" },
        .{ .from = "c:\\Users\\Me\\demo", .to = "C:\\users\\me\\PyOZ", .win = true, .want = "../PyOZ" },
        .{ .from = "C:\\work\\demo", .to = "D:\\src\\PyOZ", .win = true, .want = "D:/src/PyOZ" },
    };
    for (cases) |c| {
        const got = try relativePath(a, c.from, c.to, c.win);
        defer a.free(got);
        try std.testing.expectEqualStrings(c.want, got);
    }
}

/// Pin the PyOZ dependency hash with the official `zig fetch --save`, which
/// rewrites build.zig.zon in place. (Previously `zig build` was run twice and
/// the fingerprint/hash scraped from compiler error messages.)
fn fetchDependencyHash(allocator: std.mem.Allocator, io: Io, dir: Io.Dir) bool {
    const url = "https://github.com/pyozig/PyOZ/archive/refs/tags/v" ++ version.string ++ ".tar.gz";
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "fetch", "--save=PyOZ", url },
        .cwd = .{ .dir = dir },
    }) catch {
        std.debug.print("  Note: could not run 'zig fetch'; remove the PyOZ entry from build.zig.zon, then run:\n    zig fetch --save=PyOZ {s}\n", .{url});
        return false;
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!sys.exitedOk(result.term)) {
        std.debug.print("  Note: 'zig fetch' failed; once online, remove the PyOZ entry from build.zig.zon, then run:\n    zig fetch --save=PyOZ {s}\n", .{url});
        return false;
    }
    return true;
}

/// The rendered build.zig.zon template with `.dependencies = .{}`, for
/// `zig fetch --save` to fill in.
fn withoutPyOzDependency(allocator: std.mem.Allocator, zon: []const u8) ![]u8 {
    const start = std.mem.indexOf(u8, zon, "    .dependencies = .{\n") orelse return error.TemplateMismatch;
    const end_marker = "\n    },\n";
    const end = std.mem.indexOfPos(u8, zon, start, end_marker) orelse return error.TemplateMismatch;
    return std.mem.concat(allocator, u8, &.{ zon[0..start], "    .dependencies = .{},\n", zon[end + end_marker.len ..] });
}

test withoutPyOzDependency {
    const a = std.testing.allocator;
    const zon = try replaceInTemplateExt(a, build_zig_zon_template, "demo", "0x1");
    defer a.free(zon);
    const empty = try withoutPyOzDependency(a, zon);
    defer a.free(empty);
    try std.testing.expect(std.mem.indexOf(u8, empty, "    .dependencies = .{},\n    .paths = .{") != null);
    try std.testing.expect(std.mem.indexOf(u8, empty, ".PyOZ") == null);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".url = \"https://github.com/pyozig/PyOZ/archive/refs/tags/v") != null);
}

fn writeLocalBuildZigZon(
    allocator: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    name: []const u8,
    fingerprint: []const u8,
    local_path: []const u8,
) !void {
    // Get absolute path of project directory
    var proj_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const proj_abs_path = proj_path_buf[0..try dir.realPath(io, &proj_path_buf)];

    // Make local_path absolute if it isn't already
    var pyoz_path_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const pyoz_abs_path = if (Io.Dir.path.isAbsolute(local_path))
        local_path
    else
        pyoz_path_buf[0..try Io.Dir.cwd().realPathFile(io, local_path, &pyoz_path_buf)];

    // Compute relative path from project to PyOZ
    const relative_path = try computeRelativePath(allocator, proj_abs_path, pyoz_abs_path);
    defer allocator.free(relative_path);

    // Write build.zig.zon without fingerprint - zig build will generate it
    const content = try std.fmt.allocPrint(allocator,
        \\.{{
        \\    .name = .{s},
        \\    .version = "0.1.0",
        \\    .fingerprint = {s},
        \\    .minimum_zig_version = "
    ++ version.zig ++
        \\",
        \\    .dependencies = .{{
        \\        .PyOZ = .{{
        \\            .path = "{s}",
        \\        }},
        \\    }},
        \\    .paths = .{{
        \\        "build.zig",
        \\        "build.zig.zon",
        \\        "src",
        \\    }},
        \\}}
        \\
    , .{ name, fingerprint, relative_path });
    defer allocator.free(content);
    try dir.writeFile(io, .{ .sub_path = "build.zig.zon", .data = content });
}

// =============================================================================
// Templates
// =============================================================================

const pyproject_template =
    \\[build-system]
    \\requires = ["pyoz"]
    \\build-backend = "pyoz.backend"
    \\
    \\[project]
    \\name = "{[name]s}"
    \\version = "0.1.0"
    \\description = "A Python extension module built with PyOZ"
    \\requires-python = ">=3.10"
    \\readme = "README.md"
    \\
    \\[tool.pyoz]
    \\# Path to your Zig source file
    \\module-path = "src/lib.zig"
    \\
    \\# Optimization level for release builds: "Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"
    \\# optimize = "ReleaseFast"
    \\
    \\# Native module name (defaults to project name)
    \\# Use "_name" prefix to separate the .so from a Python wrapper package
    \\# module-name = "_mymodule"
    \\
    \\# Strip debug symbols in release builds
    \\# strip = true
    \\
    \\# File extensions to include from py-packages (default: .py only)
    \\# Use ["*"] to include all files
    \\# include-ext = ["py", "zig", "json"]
    \\
    \\# Linux platform tag for wheel builds (default: "linux_x86_64" or "linux_aarch64")
    \\# Use manylinux tags only if building in a manylinux container
    \\# linux-platform-tag = "manylinux_2_17_x86_64"
    \\
;

const pyproject_package_template =
    \\[build-system]
    \\requires = ["pyoz"]
    \\build-backend = "pyoz.backend"
    \\
    \\[project]
    \\name = "{[name]s}"
    \\version = "0.1.0"
    \\description = "A Python extension module built with PyOZ"
    \\requires-python = ">=3.10"
    \\readme = "README.md"
    \\
    \\[tool.pyoz]
    \\# Path to your Zig source file
    \\module-path = "src/lib.zig"
    \\
    \\# Native module name (underscore prefix is optional for package layout)
    \\module-name = "_{[name]s}"
    \\
    \\# Python package directory to include in the wheel
    \\py-packages = ["{[name]s}"]
    \\
    \\# Optimization level for release builds: "Debug", "ReleaseSafe", "ReleaseFast", "ReleaseSmall"
    \\# optimize = "ReleaseFast"
    \\
    \\# Strip debug symbols in release builds
    \\# strip = true
    \\
    \\# File extensions to include from py-packages (default: .py only)
    \\# Use ["*"] to include all files
    \\# include-ext = ["py", "zig", "json"]
    \\
    \\# Linux platform tag for wheel builds (default: "linux_x86_64" or "linux_aarch64")
    \\# Use manylinux tags only if building in a manylinux container
    \\# linux-platform-tag = "manylinux_2_17_x86_64"
    \\
;

const lib_zig_template =
    \\const pyoz = @import("PyOZ");
    \\
    \\// ============================================================================
    \\// Define your functions here
    \\// ============================================================================
    \\
    \\/// Add two integers
    \\fn add(a: i64, b: i64) i64 {
    \\    return a + b;
    \\}
    \\
    \\/// Multiply two floats
    \\fn multiply(a: f64, b: f64) f64 {
    \\    return a * b;
    \\}
    \\
    \\/// Greet someone by name
    \\fn greet(name: []const u8) ![]const u8 {
    \\    _ = name;
    \\    return "Hello from {[name]s}!";
    \\}
    \\
    \\// ============================================================================
    \\// Module definition
    \\// ============================================================================
    \\
    \\pub const Module = pyoz.module(.{
    \\    .name = "{[name]s}",
    \\    .doc = "{[name]s} - A Python extension module built with PyOZ",
    \\    .funcs = &.{
    \\        pyoz.func("add", add, "Add two integers"),
    \\        pyoz.func("multiply", multiply, "Multiply two floats"),
    \\        pyoz.func("greet", greet, "Return a greeting"),
    \\    },
    \\    .classes = &.{},
    \\});
    \\
    \\// Required: forces analysis of all pub decls so PyInit_ is exported.
    \\comptime {
    \\    for (@typeInfo(@This()).@"struct".decls) |decl| {
    \\        _ = @field(@This(), decl.name);
    \\    }
    \\}
    \\
;

const build_zig_template =
    \\//! Build script for {[name]s}
    \\//!
    \\//! You can use this directly with `zig build`, or use `pyoz build` for
    \\//! automatic Python configuration detection.
    \\
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    // Strip option (can be set via -Dstrip=true or from pyoz CLI)
    \\    const strip = b.option(bool, "strip", "Strip debug symbols from the binary") orelse false;
    \\
    \\    // Get PyOZ dependency
    \\    const pyoz_dep = b.dependency("PyOZ", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    // Create the user's lib module
    \\    const user_lib_mod = b.createModule(.{
    \\        .root_source_file = b.path("src/lib.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .strip = strip,
    \\        // libc is required for the Python C API
    \\        .link_libc = true,
    \\        .imports = &.{
    \\            .{ .name = "PyOZ", .module = pyoz_dep.module("PyOZ") },
    \\        },
    \\    });
    \\
    \\    // To add custom C include paths or link objects, add them to user_lib_mod:
    \\    //   user_lib_mod.addIncludePath(b.path("vendor/include"));
    \\    //   user_lib_mod.addObjectFile(b.path("vendor/libfoo.a"));
    \\
    \\    // Build the Python extension as a dynamic library
    \\    const lib = b.addLibrary(.{
    \\        .name = "{[name]s}",
    \\        .linkage = .dynamic,
    \\        .root_module = user_lib_mod,
    \\    });
    \\
    \\    // Extensions get the Python C API from the interpreter at load time, not
    \\    // from a library: macOS needs this (-undefined dynamic_lookup).
    \\    if (target.result.os.tag == .macos) lib.linker_allow_shlib_undefined = true;
    \\
    \\    // On Windows, link against the Python stable ABI library (python3.lib).
    \\    // These options are passed automatically by `pyoz build`.
    \\    // For manual `zig build` on Windows, pass: -Dpython-lib-dir=<path> -Dpython-lib-name=python3
    \\    if (b.option([]const u8, "python-lib-dir", "Python library directory")) |lib_dir| {
    \\        user_lib_mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    \\    }
    \\    if (b.option([]const u8, "python-lib-name", "Python library name")) |lib_name| {
    \\        user_lib_mod.linkSystemLibrary(lib_name, .{});
    \\    }
    \\
    \\    // Extension depends on the *target* OS (.pyd for Windows, .so otherwise),
    \\    // so cross-compiling from Linux to Windows produces a correct .pyd
    \\    const ext = if (target.result.os.tag == .windows) ".pyd" else ".so";
    \\
    \\    // Install the shared library
    \\    const install = b.addInstallArtifact(lib, .{
    \\        .dest_sub_path = b.fmt("{[name]s}{s}", .{ext}),
    \\    });
    \\    b.getInstallStep().dependOn(&install.step);
    \\
    \\}
    \\
;

const build_zig_package_template =
    \\//! Build script for {[name]s}
    \\//!
    \\//! You can use this directly with `zig build`, or use `pyoz build` for
    \\//! automatic Python configuration detection.
    \\
    \\const std = @import("std");
    \\
    \\pub fn build(b: *std.Build) void {
    \\    const target = b.standardTargetOptions(.{});
    \\    const optimize = b.standardOptimizeOption(.{});
    \\
    \\    // Strip option (can be set via -Dstrip=true or from pyoz CLI)
    \\    const strip = b.option(bool, "strip", "Strip debug symbols from the binary") orelse false;
    \\
    \\    // Get PyOZ dependency
    \\    const pyoz_dep = b.dependency("PyOZ", .{
    \\        .target = target,
    \\        .optimize = optimize,
    \\    });
    \\
    \\    // Create the user's lib module
    \\    const user_lib_mod = b.createModule(.{
    \\        .root_source_file = b.path("src/lib.zig"),
    \\        .target = target,
    \\        .optimize = optimize,
    \\        .strip = strip,
    \\        // libc is required for the Python C API
    \\        .link_libc = true,
    \\        .imports = &.{
    \\            .{ .name = "PyOZ", .module = pyoz_dep.module("PyOZ") },
    \\        },
    \\    });
    \\
    \\    // To add custom C include paths or link objects, add them to user_lib_mod:
    \\    //   user_lib_mod.addIncludePath(b.path("vendor/include"));
    \\    //   user_lib_mod.addObjectFile(b.path("vendor/libfoo.a"));
    \\
    \\    // Build the Python extension as a dynamic library
    \\    // The underscore prefix is optional; it separates the .so from the Python package directory
    \\    const lib = b.addLibrary(.{
    \\        .name = "_{[name]s}",
    \\        .linkage = .dynamic,
    \\        .root_module = user_lib_mod,
    \\    });
    \\
    \\    // Extensions get the Python C API from the interpreter at load time, not
    \\    // from a library: macOS needs this (-undefined dynamic_lookup).
    \\    if (target.result.os.tag == .macos) lib.linker_allow_shlib_undefined = true;
    \\
    \\    // On Windows, link against the Python stable ABI library (python3.lib).
    \\    // These options are passed automatically by `pyoz build`.
    \\    // For manual `zig build` on Windows, pass: -Dpython-lib-dir=<path> -Dpython-lib-name=python3
    \\    if (b.option([]const u8, "python-lib-dir", "Python library directory")) |lib_dir| {
    \\        user_lib_mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    \\    }
    \\    if (b.option([]const u8, "python-lib-name", "Python library name")) |lib_name| {
    \\        user_lib_mod.linkSystemLibrary(lib_name, .{});
    \\    }
    \\
    \\    // Extension depends on the *target* OS (.pyd for Windows, .so otherwise),
    \\    // so cross-compiling from Linux to Windows produces a correct .pyd
    \\    const ext = if (target.result.os.tag == .windows) ".pyd" else ".so";
    \\
    \\    // Install the shared library
    \\    const install = b.addInstallArtifact(lib, .{
    \\        .dest_sub_path = b.fmt("_{[name]s}{s}", .{ext}),
    \\    });
    \\    b.getInstallStep().dependOn(&install.step);
    \\
    \\}
    \\
;

const init_py_template =
    \\# Auto-generated by PyOZ - re-exports all symbols from the native extension
    \\from ._{[name]s} import *
    \\
;

const lib_zig_package_template =
    \\const pyoz = @import("PyOZ");
    \\
    \\// ============================================================================
    \\// Define your functions here
    \\// ============================================================================
    \\
    \\/// Add two integers
    \\fn add(a: i64, b: i64) i64 {
    \\    return a + b;
    \\}
    \\
    \\/// Multiply two floats
    \\fn multiply(a: f64, b: f64) f64 {
    \\    return a * b;
    \\}
    \\
    \\/// Greet someone by name
    \\fn greet(name: []const u8) ![]const u8 {
    \\    _ = name;
    \\    return "Hello from {[name]s}!";
    \\}
    \\
    \\// ============================================================================
    \\// Module definition
    \\// ============================================================================
    \\
    \\pub const Module = pyoz.module(.{
    \\    .name = "_{[name]s}",
    \\    .doc = "{[name]s} - A Python extension module built with PyOZ",
    \\    .funcs = &.{
    \\        pyoz.func("add", add, "Add two integers"),
    \\        pyoz.func("multiply", multiply, "Multiply two floats"),
    \\        pyoz.func("greet", greet, "Return a greeting"),
    \\    },
    \\    .classes = &.{},
    \\});
    \\
    \\// Required: forces analysis of all pub decls so PyInit_ is exported.
    \\comptime {
    \\    for (@typeInfo(@This()).@"struct".decls) |decl| {
    \\        _ = @field(@This(), decl.name);
    \\    }
    \\}
    \\
;

const build_zig_zon_template =
    \\.{
    \\    .name = .{[name]s},
    \\    .version = "0.1.0",
    \\    .fingerprint = {[fingerprint]s},
    \\    .minimum_zig_version = "
++ version.zig ++
    \\",
    \\    .dependencies = .{
    \\        .PyOZ = .{
    \\            .url = "https://github.com/pyozig/PyOZ/archive/refs/tags/v{[pyoz_version]s}.tar.gz",
    \\            // .hash = "...",
    \\        },
    \\    },
    \\    .paths = .{
    \\        "build.zig",
    \\        "build.zig.zon",
    \\        "src",
    \\    },
    \\}
    \\
;

const readme_template =
    \\# {[name]s}
    \\
    \\A Python extension module built with [PyOZ](https://github.com/pyozig/PyOZ).
    \\
    \\## Building
    \\
    \\```bash
    \\# Using PyOZ CLI (recommended)
    \\pyoz build
    \\
    \\# Or using Zig directly
    \\zig build
    \\```
    \\
    \\## Development
    \\
    \\```bash
    \\# Install in development mode
    \\pyoz develop
    \\
    \\# Now you can import and test
    \\python -c "import {[name]s}; print({[name]s}.add(2, 3))"
    \\```
    \\
    \\## Building Wheels
    \\
    \\```bash
    \\# Build a wheel for distribution
    \\pyoz build
    \\
    \\# The wheel will be in dist/
    \\```
    \\
    \\## Usage
    \\
    \\```python
    \\import {[name]s}
    \\
    \\# Add two numbers
    \\result = {[name]s}.add(2, 3)
    \\print(result)  # 5
    \\
    \\# Multiply floats
    \\result = {[name]s}.multiply(2.5, 4.0)
    \\print(result)  # 10.0
    \\
    \\# Get a greeting
    \\print({[name]s}.greet("World"))
    \\```
    \\
;

const gitignore_content =
    \\# Zig
    \\zig-cache/
    \\zig-out/
    \\.zig-cache/
    \\
    \\# Python
    \\__pycache__/
    \\*.py[cod]
    \\*$py.class
    \\*.so
    \\*.pyd
    \\.Python
    \\build/
    \\develop/
    \\dist/
    \\*.egg-info/
    \\.eggs/
    \\
    \\# Virtual environments
    \\venv/
    \\.venv/
    \\env/
    \\
    \\# IDE
    \\.idea/
    \\.vscode/
    \\*.swp
    \\*~
    \\
;
