const std = @import("std");
const version = @import("version");

const commands = @import("commands.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const ctx: commands.Ctx = .{ .gpa = allocator, .io = init.io, .environ = init.environ_map };

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-V")) {
        printVersion();
        return;
    }

    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    }

    // Dispatch to command handlers
    if (std.mem.eql(u8, command, "init")) {
        try commands.init(ctx, args[2..]);
    } else if (std.mem.eql(u8, command, "build")) {
        try commands.build(ctx, args[2..]);
    } else if (std.mem.eql(u8, command, "develop")) {
        try commands.develop(ctx, args[2..]);
    } else if (std.mem.eql(u8, command, "publish")) {
        try commands.publish(ctx, args[2..]);
    } else if (std.mem.eql(u8, command, "test")) {
        try commands.runTests(ctx, args[2..]);
    } else if (std.mem.eql(u8, command, "bench")) {
        try commands.runBench(ctx, args[2..]);
    } else {
        std.debug.print("Unknown command: {s}\n\n", .{command});
        printUsage();
        std.process.exit(1);
    }
}

fn printVersion() void {
    std.debug.print("pyoz {s}\n", .{version.string});
}

fn printUsage() void {
    std.debug.print(
        \\pyoz {s} - Build and package Zig Python extensions
        \\
        \\Usage: pyoz <command> [options]
        \\
        \\Commands:
        \\  init          Create a new PyOZ project
        \\  build         Build the extension module and create wheel
        \\  develop       Build and install in development mode
        \\  publish       Publish to PyPI
        \\  test          Run embedded tests
        \\  bench         Run embedded benchmarks
        \\
        \\Options:
        \\  -h, --help     Show this help message
        \\  -V, --version  Show version information
        \\
        \\Run 'pyoz <command> --help' for more information on a command.
        \\
    , .{version.string});
}

test {
    _ = @import("builder.zig");
    _ = @import("binfo.zig");
    _ = @import("target.zig");
    _ = @import("pyheaders.zig");
    _ = @import("toml.zig");
    _ = @import("metadata.zig");
    _ = @import("zip.zig");
    _ = @import("wheel.zig");
    _ = @import("project.zig");
    _ = @import("sys.zig");
}
