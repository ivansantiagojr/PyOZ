const std = @import("std");
const pyoz = @import("PyOZ");
const version = @import("version");

const project = @import("project.zig");
const builder = @import("builder.zig");
const commands = @import("commands.zig");
const wheel = @import("wheel.zig");
const sys = @import("sys.zig");

/// Run a CLI entry point with a fresh Io/environment runtime.
fn withCtx(comptime f: anytype, extra: anytype) !@typeInfo(@typeInfo(@TypeOf(f)).@"fn".return_type.?).error_union.payload {
    var rt: sys.Runtime = undefined;
    try rt.init(std.heap.page_allocator);
    defer rt.deinit();
    return @call(.auto, f, .{rt.ctx()} ++ extra);
}

const InitArgs = pyoz.Args(struct {
    name: ?[]const u8 = null,
    in_current_dir: ?bool = null,
    local_pyoz_path: ?[]const u8 = null,
    package_layout: ?bool = null,
});

fn init_project(args: InitArgs) !void {
    try withCtx(project.create, .{ args.value.name, args.value.in_current_dir orelse false, args.value.local_pyoz_path, args.value.package_layout orelse false });
}

const BuildArgs = pyoz.Args(struct {
    release: ?bool = null,
    stubs: ?bool = null,
});

fn build_wheel(args: BuildArgs) ![]const u8 {
    return try withCtx(wheel.buildWheel, .{ args.value.release orelse false, args.value.stubs orelse true });
}

/// `pyoz build` from the Python CLI: same arguments as the native CLI.
fn cli_build(args: pyoz.ListView([]const u8)) !void {
    var buf: [64][]const u8 = undefined;
    if (args.len() > buf.len) return error.TooManyArguments;
    for (0..args.len()) |i| buf[i] = args.get(i) orelse return error.TypeError;
    try withCtx(commands.build, .{@as([]const []const u8, buf[0..args.len()])});
}

/// PEP 660: build an editable wheel into `wheel_directory`, return its path.
fn build_editable(wheel_directory: []const u8) ![]const u8 {
    return try withCtx(wheel.buildEditableWheel, .{wheel_directory});
}

fn develop_mode() !void {
    try withCtx(builder.developMode, .{});
}

const PublishArgs = pyoz.Args(struct {
    test_pypi: ?bool = null,
});

fn publish_wheels(args: PublishArgs) !void {
    try withCtx(wheel.publish, .{args.value.test_pypi orelse false});
}

const TestArgs = pyoz.Args(struct {
    release: ?bool = null,
    verbose: ?bool = null,
});

fn run_tests(args: TestArgs) !void {
    var args_buf: [2][]const u8 = undefined;
    var args_len: usize = 0;
    if (args.value.release orelse false) {
        args_buf[args_len] = "--release";
        args_len += 1;
    }
    if (args.value.verbose orelse false) {
        args_buf[args_len] = "--verbose";
        args_len += 1;
    }
    try withCtx(commands.runTests, .{@as([]const []const u8, args_buf[0..args_len])});
}

fn run_bench() !void {
    const bench_args = [_][]const u8{};
    try withCtx(commands.runBench, .{@as([]const []const u8, &bench_args)});
}

fn get_version() []const u8 {
    return version.string;
}

pub const PyOZCli = pyoz.module(.{
    .name = "_pyoz",
    .doc = "PyOZ native CLI library - build Python extensions in Zig",
    .classes = &.{},
    .funcs = &.{
        pyoz.kwfunc("init", init_project, "Create a new PyOZ project"),
        pyoz.kwfunc("build", build_wheel, "Build extension module and create wheel"),
        pyoz.func("cli_build", cli_build, "Run `pyoz build` with command-line arguments").withParams("args"),
        pyoz.func("develop", develop_mode, "Build and install in development mode"),
        pyoz.func("build_editable", build_editable, "Build a PEP 660 editable wheel").withParams("wheel_directory"),
        pyoz.kwfunc("publish", publish_wheels, "Publish wheel(s) to PyPI"),
        pyoz.kwfunc("run_tests", run_tests, "Run embedded tests"),
        pyoz.func("run_bench", run_bench, "Run embedded benchmarks"),
        pyoz.func("version", get_version, "Get PyOZ version string"),
    },
    .consts = &.{
        pyoz.constant("__version__", version.string),
    },
});

// Required: forces analysis of all pub decls so PyInit_ is exported.
comptime {
    for (@typeInfo(@This()).@"struct".decls) |decl| {
        _ = @field(@This(), decl.name);
    }
}
