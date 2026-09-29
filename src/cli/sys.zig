//! Process/filesystem helpers shared by CLI commands (Zig 0.16 std.Io based).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;

/// Everything a CLI command needs from the process: allocator, I/O and environment.
pub const Ctx = struct {
    gpa: Allocator,
    io: Io,
    environ: *const Environ.Map,
};

pub const StdIo = std.process.SpawnOptions.StdIo;

pub const SpawnOpts = struct {
    environ_map: ?*const Environ.Map = null,
    stdout: StdIo = .inherit,
    stderr: StdIo = .inherit,
};

/// Spawn `argv`, wait for it, and report whether it exited with status 0.
/// A child killed by a signal counts as failure instead of tripping a
/// union-field safety check (the 0.15 code accessed `term.Exited` directly).
pub fn runInherit(io: Io, argv: []const []const u8, opts: SpawnOpts) !bool {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .environ_map = opts.environ_map,
        .stdout = opts.stdout,
        .stderr = opts.stderr,
    });
    const term = try child.wait(io);
    return exitedOk(term);
}

pub fn exitedOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

/// Run `argv`, capture stdout, and return it (caller frees) if the process exited 0.
pub fn runCapture(gpa: Allocator, io: Io, argv: []const []const u8) ![]u8 {
    const result = std.process.run(gpa, io, .{ .argv = argv }) catch return error.CommandFailed;
    defer gpa.free(result.stderr);
    if (!exitedOk(result.term)) {
        gpa.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

pub fn exists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// Owned runtime for code that has no `main` (e.g. the CLI embedded in the
/// `_pyoz` Python extension): builds an `Io` and an environment snapshot.
/// Must not be moved after `init`, since `ctx()` points into it.
pub const Runtime = struct {
    threaded: Io.Threaded,
    environ_map: Environ.Map,

    pub fn init(self: *Runtime, gpa: Allocator) !void {
        const env = hostEnviron();
        self.threaded = .init(gpa, .{ .environ = env });
        errdefer self.threaded.deinit();
        self.environ_map = try env.createMap(gpa);
    }

    pub fn deinit(self: *Runtime) void {
        self.environ_map.deinit();
        self.threaded.deinit();
    }

    pub fn ctx(self: *Runtime) Ctx {
        return .{ .gpa = self.threaded.allocator, .io = self.threaded.io(), .environ = &self.environ_map };
    }

    fn hostEnviron() Environ {
        if (Environ.Block == Environ.GlobalBlock) return .{ .block = .global };
        // Loaded into a libc-linked host process (Python): read libc's `environ`.
        return .{ .block = .{ .slice = std.mem.sliceTo(@as([*:null]const ?[*:0]const u8, @ptrCast(std.c.environ)), null) } };
    }
};
