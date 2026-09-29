//! CPython headers (and Windows import libraries) for building wheels for a
//! platform or Python version other than the build machine's.
//!
//! They come from python-build-standalone, which publishes relocatable CPython
//! builds for every platform PyOZ targets. The archive for a (version, target)
//! pair is downloaded once, verified against the release's SHA256SUMS, and
//! only `include/` and `libs/` are kept in the cache:
//!
//!   $PYOZ_CACHE_DIR, else
//!   Linux: $XDG_CACHE_HOME/pyoz or ~/.cache/pyoz
//!   macOS: ~/Library/Caches/pyoz
//!   Windows: %LOCALAPPDATA%\pyoz

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const sys = @import("sys.zig");
const target_mod = @import("target.zig");
const Target = target_mod.Target;
const Python = target_mod.Python;

/// Pinned python-build-standalone release and the CPython versions it ships.
/// Bump together when refreshing (see the release's asset list).
pub const pbs_release = "20260924";
const pbs_base_url = "https://github.com/astral-sh/python-build-standalone/releases/download/" ++ pbs_release ++ "/";
const pbs_versions = [_]struct { minor: u8, full: []const u8 }{
    .{ .minor = 10, .full = "3.10.21" },
    .{ .minor = 11, .full = "3.11.16" },
    .{ .minor = 12, .full = "3.12.14" },
    .{ .minor = 13, .full = "3.13.15" },
    .{ .minor = 14, .full = "3.14.7" },
};

pub const Headers = struct {
    /// Directory containing Python.h (and the matching pyconfig.h)
    include_dir: []u8,
    /// Windows: directory with python3.lib / python3XY[t].lib
    lib_dir: ?[]u8,

    pub fn deinit(h: *Headers, gpa: std.mem.Allocator) void {
        gpa.free(h.include_dir);
        if (h.lib_dir) |d| gpa.free(d);
    }
};

/// Headers for `py` on `target`, downloading them on first use.
pub fn get(ctx: sys.Ctx, target: Target, py: Python) !Headers {
    const gpa = ctx.gpa;
    const io = ctx.io;

    const full = for (pbs_versions) |v| {
        if (v.minor == py.minor) break v.full;
    } else {
        std.debug.print("Error: no CPython 3.{d} headers available for cross-builds (supported: 3.10-3.14)\n", .{py.minor});
        return error.UnsupportedPython;
    };
    if (target.os == .windows and target.arch == .aarch64 and py.minor == 10) {
        std.debug.print("Error: CPython 3.10 does not support Windows on ARM64\n", .{});
        return error.UnsupportedPython;
    }

    const asset = try std.fmt.allocPrint(gpa, "cpython-{s}+{s}-{s}{s}-install_only_stripped.tar.gz", .{
        full, pbs_release, target.pbsTriple(), if (py.freethreaded) "-freethreaded" else "",
    });
    defer gpa.free(asset);
    const stem = asset[0 .. asset.len - ".tar.gz".len];

    const root = try cacheRoot(gpa, ctx.environ);
    defer gpa.free(root);
    const dir = try std.fs.path.join(gpa, &.{ root, "python", stem });
    defer gpa.free(dir);
    const marker = try std.fs.path.join(gpa, &.{ dir, ".complete" });
    defer gpa.free(marker);

    const cwd = Io.Dir.cwd();
    if (!sys.exists(io, marker)) try download(ctx, asset, dir);

    // Locate Python.h: include/pythonX.Y[t]/ on Unix, include/ on Windows
    const include_root = try std.fs.path.join(gpa, &.{ dir, "include" });
    defer gpa.free(include_root);
    var include_dir: []u8 = undefined;
    if (target.os == .windows) {
        include_dir = try gpa.dupe(u8, include_root);
    } else {
        var d = try cwd.openDir(io, include_root, .{ .iterate = true });
        defer d.close(io);
        var it = d.iterate();
        const sub = while (try it.next(io)) |e| {
            if (e.kind == .directory and std.mem.startsWith(u8, e.name, "python3")) break try gpa.dupe(u8, e.name);
        } else return error.HeadersNotFound;
        defer gpa.free(sub);
        include_dir = try std.fs.path.join(gpa, &.{ include_root, sub });
    }
    errdefer gpa.free(include_dir);

    const lib_dir: ?[]u8 = if (target.os == .windows) try std.fs.path.join(gpa, &.{ dir, "libs" }) else null;
    return .{ .include_dir = include_dir, .lib_dir = lib_dir };
}

fn download(ctx: sys.Ctx, asset: []const u8, dest: []const u8) !void {
    const gpa = ctx.gpa;
    const io = ctx.io;
    std.debug.print("  Downloading CPython headers: {s}\n", .{asset});

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const sums = try fetch(gpa, &client, pbs_base_url ++ "SHA256SUMS");
    defer gpa.free(sums);
    const expected = findSum(sums, asset) orelse {
        std.debug.print("Error: {s} is not listed in the release's SHA256SUMS\n", .{asset});
        return error.ChecksumMissing;
    };

    const url = try std.fmt.allocPrint(gpa, pbs_base_url ++ "{s}", .{asset});
    defer gpa.free(url);
    const data = try fetch(gpa, &client, url);
    defer gpa.free(data);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.ascii.eqlIgnoreCase(&actual, expected)) {
        std.debug.print("Error: checksum mismatch for {s}\n", .{asset});
        return error.ChecksumMismatch;
    }

    // Extract into a temporary sibling, then rename: a concurrent or
    // interrupted build never sees a partial directory.
    const cwd = Io.Dir.cwd();
    var rnd: [8]u8 = undefined;
    io.random(&rnd);
    const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp-{x}", .{ dest, rnd });
    defer gpa.free(tmp);
    try cwd.createDirPath(io, tmp);
    errdefer cwd.deleteTree(io, tmp) catch {};
    try extract(gpa, io, data, tmp);

    const marker = try std.fs.path.join(gpa, &.{ tmp, ".complete" });
    defer gpa.free(marker);
    try cwd.writeFile(io, .{ .sub_path = marker, .data = asset });

    cwd.rename(tmp, cwd, dest, io) catch |err| {
        // Another build finished first: use its copy
        cwd.deleteTree(io, tmp) catch {};
        if (!sys.exists(io, dest)) return err;
    };
}

fn fetch(gpa: std.mem.Allocator, client: *std.http.Client, url: []const u8) ![]u8 {
    var body: Io.Writer.Allocating = .init(gpa);
    errdefer body.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
    }) catch |err| {
        std.debug.print("Error: download failed ({s}): {s}\n", .{ @errorName(err), url });
        return error.DownloadFailed;
    };
    if (result.status != .ok) {
        std.debug.print("Error: HTTP {d} for {s}\n", .{ @intFromEnum(result.status), url });
        return error.DownloadFailed;
    }
    return body.toOwnedSlice();
}

/// SHA256SUMS lines are "<hex digest>  <file name>".
fn findSum(sums: []const u8, file: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, sums, '\n');
    while (lines.next()) |line| {
        var parts = std.mem.tokenizeAny(u8, line, " \t\r*");
        const digest = parts.next() orelse continue;
        const name = parts.next() orelse continue;
        if (std.mem.eql(u8, name, file) and digest.len == 64) return digest;
    }
    return null;
}

/// Keep python/include/** and python/libs/*.lib from the .tar.gz, dropping the
/// leading "python/" (the rest of the interpreter is not needed).
fn extract(gpa: std.mem.Allocator, io: Io, data: []const u8, dest: []const u8) !void {
    var in: Io.Reader = .fixed(data);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var gz: std.compress.flate.Decompress = .init(&in, .gzip, &window);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&gz.reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });

    const cwd = Io.Dir.cwd();
    var out = try cwd.openDir(io, dest, .{});
    defer out.close(io);
    var kept: usize = 0;
    while (try it.next()) |file| {
        if (file.kind != .file) continue;
        const rel = if (std.mem.startsWith(u8, file.name, "python/")) file.name["python/".len..] else continue;
        const keep = std.mem.startsWith(u8, rel, "include/") or
            (std.mem.startsWith(u8, rel, "libs/") and std.mem.endsWith(u8, rel, ".lib"));
        if (!keep or std.mem.indexOf(u8, rel, "..") != null) continue;

        var content: Io.Writer.Allocating = .init(gpa);
        defer content.deinit();
        try it.streamRemaining(file, &content.writer);
        if (std.fs.path.dirname(rel)) |parent| try out.createDirPath(io, parent);
        try out.writeFile(io, .{ .sub_path = rel, .data = content.written() });
        kept += 1;
    }
    if (kept == 0) return error.HeadersNotFound;
}

fn cacheRoot(gpa: std.mem.Allocator, env: *const std.process.Environ.Map) ![]u8 {
    if (env.get("PYOZ_CACHE_DIR")) |d| if (d.len > 0) return gpa.dupe(u8, d);
    switch (builtin.os.tag) {
        .windows => if (env.get("LOCALAPPDATA")) |d| return std.fs.path.join(gpa, &.{ d, "pyoz" }),
        .macos => if (env.get("HOME")) |h| return std.fs.path.join(gpa, &.{ h, "Library", "Caches", "pyoz" }),
        else => {
            if (env.get("XDG_CACHE_HOME")) |d| if (d.len > 0) return std.fs.path.join(gpa, &.{ d, "pyoz" });
            if (env.get("HOME")) |h| return std.fs.path.join(gpa, &.{ h, ".cache", "pyoz" });
        },
    }
    std.debug.print("Error: cannot determine a cache directory; set PYOZ_CACHE_DIR\n", .{});
    return error.NoCacheDir;
}

test findSum {
    const sums =
        \\0000000000000000000000000000000000000000000000000000000000000001  a.tar.gz
        \\abababababababababababababababababababababababababababababababab  cpython-x.tar.gz
    ;
    try std.testing.expectEqualStrings("abababababababababababababababababababababababababababababababab", findSum(sums, "cpython-x.tar.gz").?);
    try std.testing.expect(findSum(sums, "missing.tar.gz") == null);
}
