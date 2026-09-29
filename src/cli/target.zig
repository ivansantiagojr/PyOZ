//! Wheel targets (platform + CPython version) and the Zig targets that build them.
//!
//! Wheels are built for an explicit, portable Zig target rather than the
//! build machine: baseline CPU (no host-only instructions such as AVX-512),
//! glibc 2.17 on Linux (manylinux2014) and the oldest macOS Zig supports.

const std = @import("std");
const builtin = @import("builtin");

pub const Os = enum { linux, macos, windows };
pub const Arch = enum { x86_64, aarch64 };

pub const Target = struct {
    os: Os,
    arch: Arch,

    pub const all = [_]Target{
        .{ .os = .linux, .arch = .x86_64 },   .{ .os = .linux, .arch = .aarch64 },
        .{ .os = .macos, .arch = .x86_64 },   .{ .os = .macos, .arch = .aarch64 },
        .{ .os = .windows, .arch = .x86_64 }, .{ .os = .windows, .arch = .aarch64 },
    };

    /// The build machine, if wheels can be built for it.
    pub fn host() ?Target {
        return .{
            .os = switch (builtin.os.tag) {
                .linux => .linux,
                .macos => .macos,
                .windows => .windows,
                else => return null,
            },
            .arch = switch (builtin.cpu.arch) {
                .x86_64 => .x86_64,
                .aarch64 => .aarch64,
                else => return null,
            },
        };
    }

    pub fn eql(a: Target, b: Target) bool {
        return a.os == b.os and a.arch == b.arch;
    }

    pub fn isHost(t: Target) bool {
        return if (host()) |h| t.eql(h) else false;
    }

    /// "x86_64-linux", "aarch64-macos", "arm64-windows", "linux-x86_64", ...
    pub fn parse(s: []const u8) !Target {
        var it = std.mem.splitScalar(u8, s, '-');
        const a = it.next() orelse return error.InvalidTarget;
        const b = it.next() orelse return error.InvalidTarget;
        if (it.next() != null) return error.InvalidTarget;
        if (parseArch(a)) |arch| return .{ .arch = arch, .os = parseOs(b) orelse return error.InvalidTarget };
        if (parseArch(b)) |arch| return .{ .arch = arch, .os = parseOs(a) orelse return error.InvalidTarget };
        return error.InvalidTarget;
    }

    fn parseArch(s: []const u8) ?Arch {
        if (std.mem.eql(u8, s, "x86_64") or std.mem.eql(u8, s, "amd64")) return .x86_64;
        if (std.mem.eql(u8, s, "aarch64") or std.mem.eql(u8, s, "arm64")) return .aarch64;
        return null;
    }

    fn parseOs(s: []const u8) ?Os {
        if (std.mem.eql(u8, s, "darwin")) return .macos;
        return std.meta.stringToEnum(Os, s);
    }

    pub fn name(t: Target, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{s}-{s}", .{ @tagName(t.arch), @tagName(t.os) }) catch unreachable;
    }

    /// Zig target triple for a portable build. `glibc` applies to Linux only.
    pub fn zigTriple(t: Target, buf: []u8, glibc: Glibc) []const u8 {
        const arch = @tagName(t.arch);
        return switch (t.os) {
            .linux => std.fmt.bufPrint(buf, "{s}-linux-gnu.{d}.{d}", .{ arch, glibc.major, glibc.minor }),
            .macos => std.fmt.bufPrint(buf, "{s}-macos.{s}", .{ arch, macos_min }),
            .windows => std.fmt.bufPrint(buf, "{s}-windows-gnu", .{arch}),
        } catch unreachable;
    }

    pub fn extension(t: Target) []const u8 {
        return if (t.os == .windows) ".pyd" else ".so";
    }

    /// Where Zig installs the shared library (DLLs go to bin/).
    pub fn outDir(t: Target) []const u8 {
        return if (t.os == .windows) "zig-out/bin" else "zig-out/lib";
    }

    /// python-build-standalone target triple.
    pub fn pbsTriple(t: Target) []const u8 {
        return switch (t.os) {
            .linux => if (t.arch == .x86_64) "x86_64-unknown-linux-gnu" else "aarch64-unknown-linux-gnu",
            .macos => if (t.arch == .x86_64) "x86_64-apple-darwin" else "aarch64-apple-darwin",
            .windows => if (t.arch == .x86_64) "x86_64-pc-windows-msvc" else "aarch64-pc-windows-msvc",
        };
    }
};

/// Oldest macOS Zig 0.16 can target.
pub const macos_min = "13.0";

pub const Glibc = struct {
    major: u32 = 2,
    minor: u32 = 17,

    /// glibc version from a manylinux tag: "manylinux_2_28_x86_64" -> 2.28,
    /// "manylinux2014_x86_64" -> 2.17. null for other tags.
    pub fn fromTag(tag: []const u8) ?Glibc {
        if (std.mem.startsWith(u8, tag, "manylinux2014")) return .{ .major = 2, .minor = 17 };
        if (!std.mem.startsWith(u8, tag, "manylinux_")) return null;
        var it = std.mem.splitScalar(u8, tag["manylinux_".len..], '_');
        const major = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        const minor = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch return null;
        return .{ .major = major, .minor = minor };
    }
};

/// A CPython version to build for: "3.12", "3.14t" (free-threaded).
pub const Python = struct {
    major: u8 = 3,
    minor: u8,
    freethreaded: bool = false,

    pub fn parse(s_in: []const u8) !Python {
        var s = s_in;
        if (std.mem.startsWith(u8, s, "cp3")) s = s[2..]; // cp312 -> 312
        const ft = std.mem.endsWith(u8, s, "t");
        if (ft) s = s[0 .. s.len - 1];
        const minor_str = if (std.mem.startsWith(u8, s, "3.")) s[2..] else if (s.len > 1 and s[0] == '3') s[1..] else return error.InvalidPython;
        const minor = std.fmt.parseInt(u8, minor_str, 10) catch return error.InvalidPython;
        if (minor < 10) return error.UnsupportedPython; // PyOZ's floor
        if (ft and minor < 13) return error.UnsupportedPython; // no free-threaded CPython before 3.13
        return .{ .minor = minor, .freethreaded = ft };
    }

    pub fn eql(a: Python, b: Python) bool {
        return a.major == b.major and a.minor == b.minor and a.freethreaded == b.freethreaded;
    }

    /// "cp312" / "cp314t" (ABI tag); the Python tag is the same without "t"
    pub fn abiTag(p: Python, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "cp{d}{d}{s}", .{ p.major, p.minor, if (p.freethreaded) "t" else "" }) catch unreachable;
    }

    pub fn pythonTag(p: Python, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "cp{d}{d}", .{ p.major, p.minor }) catch unreachable;
    }

    pub fn name(p: Python, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "{d}.{d}{s}", .{ p.major, p.minor, if (p.freethreaded) "t" else "" }) catch unreachable;
    }
};

test "Target.parse" {
    try std.testing.expectEqual(Target{ .os = .linux, .arch = .x86_64 }, try Target.parse("x86_64-linux"));
    try std.testing.expectEqual(Target{ .os = .macos, .arch = .aarch64 }, try Target.parse("arm64-macos"));
    try std.testing.expectEqual(Target{ .os = .macos, .arch = .aarch64 }, try Target.parse("darwin-arm64"));
    try std.testing.expectEqual(Target{ .os = .windows, .arch = .x86_64 }, try Target.parse("windows-amd64"));
    try std.testing.expectError(error.InvalidTarget, Target.parse("riscv64-linux"));
    try std.testing.expectError(error.InvalidTarget, Target.parse("x86_64"));
}

test "Target.zigTriple" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("x86_64-linux-gnu.2.17", (Target{ .os = .linux, .arch = .x86_64 }).zigTriple(&buf, .{}));
    try std.testing.expectEqualStrings("aarch64-linux-gnu.2.28", (Target{ .os = .linux, .arch = .aarch64 }).zigTriple(&buf, .{ .minor = 28 }));
    try std.testing.expectEqualStrings("aarch64-macos.13.0", (Target{ .os = .macos, .arch = .aarch64 }).zigTriple(&buf, .{}));
    try std.testing.expectEqualStrings("x86_64-windows-gnu", (Target{ .os = .windows, .arch = .x86_64 }).zigTriple(&buf, .{}));
}

test "Python.parse" {
    try std.testing.expectEqual(Python{ .minor = 12 }, try Python.parse("3.12"));
    try std.testing.expectEqual(Python{ .minor = 14, .freethreaded = true }, try Python.parse("3.14t"));
    try std.testing.expectEqual(Python{ .minor = 13 }, try Python.parse("cp313"));
    try std.testing.expectEqual(Python{ .minor = 11 }, try Python.parse("311"));
    try std.testing.expectError(error.UnsupportedPython, Python.parse("3.9"));
    try std.testing.expectError(error.UnsupportedPython, Python.parse("3.12t"));
    try std.testing.expectError(error.InvalidPython, Python.parse("banana"));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("cp314t", (Python{ .minor = 14, .freethreaded = true }).abiTag(&buf));
}

test "Glibc.fromTag" {
    try std.testing.expectEqual(Glibc{ .major = 2, .minor = 28 }, Glibc.fromTag("manylinux_2_28_x86_64").?);
    try std.testing.expectEqual(Glibc{ .major = 2, .minor = 17 }, Glibc.fromTag("manylinux2014_aarch64").?);
    try std.testing.expect(Glibc.fromTag("linux_x86_64") == null);
}
