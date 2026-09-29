//! Core metadata (the wheel's METADATA file) from pyproject.toml's [project]
//! table, per PEP 621/639 and the core metadata spec.
//!
//! Also collects what the metadata refers to: license files (shipped in
//! `{dist-info}/licenses/`) and entry points (`entry_points.txt`). The same
//! METADATA text is sent as the upload form by `pyoz publish`, so what PyPI
//! shows always matches the wheel.

const std = @import("std");
const Io = std.Io;
const toml = @import("toml.zig");

pub const Metadata = struct {
    text: []u8,
    /// Paths relative to the project root, '/'-separated, sorted
    license_files: [][]u8,
    /// Contents of entry_points.txt, if the project declares any
    entry_points: ?[]u8,

    pub fn deinit(m: *Metadata, gpa: std.mem.Allocator) void {
        gpa.free(m.text);
        for (m.license_files) |f| gpa.free(f);
        gpa.free(m.license_files);
        if (m.entry_points) |e| gpa.free(e);
    }
};

/// Build the metadata for the project in `dir` (its pyproject.toml).
pub fn build(gpa: std.mem.Allocator, io: Io, dir: Io.Dir) !Metadata {
    const src = dir.readFileAlloc(io, "pyproject.toml", gpa, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) return error.PyProjectNotFound;
        return err;
    };
    defer gpa.free(src);
    var doc = toml.parseDocument(gpa, src) catch |err| {
        std.debug.print("Error: pyproject.toml is not valid TOML ({s})\n", .{@errorName(err)});
        return err;
    };
    defer doc.deinit();
    const project = doc.root.getTable("project") orelse {
        std.debug.print("Error: pyproject.toml has no [project] table\n", .{});
        return error.MissingProjectTable;
    };
    return render(gpa, io, dir, project);
}

fn render(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, project: *toml.Table) !Metadata {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    const name = project.getString("name") orelse return error.MissingProjectName;
    const version = project.getString("version") orelse "0.1.0";

    // License: SPDX expression (PEP 639) or legacy {text}/{file} table
    var license_expression: ?[]const u8 = null;
    var license_text: ?[]const u8 = null;
    var license_file_entry: ?[]const u8 = null;
    if (project.get("license")) |lic| switch (lic) {
        .string => |s| license_expression = s,
        .table => |t| {
            license_text = t.getString("text");
            license_file_entry = t.getString("file");
        },
        else => return fieldError("license", "a string (SPDX expression) or a table"),
    };

    const license_files = try collectLicenseFiles(gpa, io, dir, project.getArray("license-files"), license_file_entry);
    errdefer {
        for (license_files) |f| gpa.free(f);
        gpa.free(license_files);
    }

    const classifiers = project.getArray("classifiers") orelse &.{};
    if (license_expression != null) for (classifiers) |c| {
        if (std.mem.startsWith(u8, c.asString() orelse "", "License ::")) {
            // PEP 639: tools must reject this combination (so does PyPI)
            std.debug.print("Error: `license = \"...\"` (an SPDX expression) cannot be combined with \"License ::\" classifiers; remove the classifier.\n", .{});
            return error.LicenseClassifierConflict;
        }
    };

    const md_version = if (license_expression != null or license_files.len > 0) "2.4" else "2.1";
    try header(gpa, &out, "Metadata-Version", md_version);
    try header(gpa, &out, "Name", name);
    try header(gpa, &out, "Version", version);
    if (project.getString("description")) |d| try header(gpa, &out, "Summary", d);

    if (project.getArray("keywords")) |kws| {
        var joined: std.ArrayList(u8) = .empty;
        defer joined.deinit(gpa);
        for (kws, 0..) |k, i| {
            if (i > 0) try joined.append(gpa, ',');
            try joined.appendSlice(gpa, k.asString() orelse return fieldError("keywords", "an array of strings"));
        }
        if (joined.items.len > 0) try header(gpa, &out, "Keywords", joined.items);
    }

    try people(gpa, &out, project.getArray("authors"), "Author");
    try people(gpa, &out, project.getArray("maintainers"), "Maintainer");

    if (license_expression) |e| try header(gpa, &out, "License-Expression", e);
    if (license_text) |t| try foldedHeader(gpa, &out, "License", t);
    for (license_files) |f| try header(gpa, &out, "License-File", f);

    for (classifiers) |c| try header(gpa, &out, "Classifier", c.asString() orelse return fieldError("classifiers", "an array of strings"));

    if (project.getString("requires-python")) |r| try header(gpa, &out, "Requires-Python", r);

    for (project.getArray("dependencies") orelse &.{}) |d|
        try header(gpa, &out, "Requires-Dist", d.asString() orelse return fieldError("dependencies", "an array of strings"));

    if (project.getTable("optional-dependencies")) |extras| {
        for (extras.keys.items, extras.values.items) |extra_raw, deps| {
            const extra = try normalizeExtra(gpa, extra_raw);
            defer gpa.free(extra);
            try header(gpa, &out, "Provides-Extra", extra);
            for (deps.asArray() orelse return fieldError("optional-dependencies", "tables of string arrays")) |d| {
                const req = d.asString() orelse return fieldError("optional-dependencies", "tables of string arrays");
                const line = if (std.mem.indexOfScalar(u8, req, ';')) |semi|
                    try std.fmt.allocPrint(gpa, "{s}; ({s}) and extra == \"{s}\"", .{ std.mem.trim(u8, req[0..semi], " "), std.mem.trim(u8, req[semi + 1 ..], " "), extra })
                else
                    try std.fmt.allocPrint(gpa, "{s}; extra == \"{s}\"", .{ std.mem.trim(u8, req, " "), extra });
                defer gpa.free(line);
                try header(gpa, &out, "Requires-Dist", line);
            }
        }
    }

    if (project.getTable("urls")) |urls| {
        for (urls.keys.items, urls.values.items) |label, url| {
            const line = try std.fmt.allocPrint(gpa, "{s}, {s}", .{ label, url.asString() orelse return fieldError("urls", "a table of strings") });
            defer gpa.free(line);
            try header(gpa, &out, "Project-URL", line);
        }
    }

    // Long description: the readme, as the message body
    var readme = try loadReadme(gpa, io, dir, project.get("readme"));
    defer if (readme) |*r| gpa.free(r.content);
    if (readme) |r| try header(gpa, &out, "Description-Content-Type", r.content_type);
    try out.append(gpa, '\n');
    if (readme) |r| try out.appendSlice(gpa, r.content);

    const entry_points = try entryPoints(gpa, project);
    errdefer if (entry_points) |e| gpa.free(e);

    return .{
        .text = try out.toOwnedSlice(gpa),
        .license_files = license_files,
        .entry_points = entry_points,
    };
}

fn fieldError(comptime field: []const u8, comptime expected: []const u8) error{InvalidProjectField} {
    std.debug.print("Error: [project] {s} must be {s}\n", .{ field, expected });
    return error.InvalidProjectField;
}

/// One header line; embedded newlines would end the header, so they become spaces.
fn header(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try out.appendSlice(gpa, name);
    try out.appendSlice(gpa, ": ");
    for (std.mem.trim(u8, value, " \t\r\n")) |c| try out.append(gpa, if (c == '\n' or c == '\r') ' ' else c);
    try out.append(gpa, '\n');
}

/// Multi-line value: continuation lines are indented (RFC 822 folding).
fn foldedHeader(gpa: std.mem.Allocator, out: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try out.appendSlice(gpa, name);
    try out.appendSlice(gpa, ": ");
    var lines = std.mem.splitScalar(u8, std.mem.trim(u8, value, "\r\n"), '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.appendSlice(gpa, "\n        ");
        first = false;
        try out.appendSlice(gpa, std.mem.trimEnd(u8, line, "\r"));
    }
    try out.append(gpa, '\n');
}

/// authors / maintainers: names without an email go to `Author`, the rest to
/// `Author-email` as "Name <email>".
fn people(gpa: std.mem.Allocator, out: *std.ArrayList(u8), list: ?[]const toml.Value, comptime field: []const u8) !void {
    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(gpa);
    var emails: std.ArrayList(u8) = .empty;
    defer emails.deinit(gpa);
    for (list orelse return) |entry| {
        const t = entry.asTable() orelse return fieldError("authors/maintainers", "an array of { name, email } tables");
        const name = t.getString("name");
        if (t.getString("email")) |email| {
            if (emails.items.len > 0) try emails.appendSlice(gpa, ", ");
            if (name) |n| {
                // Names with commas must be quoted in an address list
                if (std.mem.indexOfScalar(u8, n, ',') != null) try emails.print(gpa, "\"{s}\" <{s}>", .{ n, email }) else try emails.print(gpa, "{s} <{s}>", .{ n, email });
            } else try emails.appendSlice(gpa, email);
        } else if (name) |n| {
            if (names.items.len > 0) try names.appendSlice(gpa, ", ");
            try names.appendSlice(gpa, n);
        }
    }
    if (names.items.len > 0) try header(gpa, out, field, names.items);
    if (emails.items.len > 0) try header(gpa, out, field ++ "-email", emails.items);
}

/// PEP 685: lowercase, runs of -_. become '-'.
fn normalizeExtra(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var sep = false;
    for (s) |c| {
        if (c == '-' or c == '_' or c == '.') {
            sep = true;
            continue;
        }
        if (sep and out.items.len > 0) try out.append(gpa, '-');
        sep = false;
        try out.append(gpa, std.ascii.toLower(c));
    }
    return out.toOwnedSlice(gpa);
}

const Readme = struct { content: []u8, content_type: []const u8 };

fn loadReadme(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, value: ?toml.Value) !?Readme {
    const v = value orelse {
        // No `readme` key: README.md if present (PyOZ's historical default)
        const content = dir.readFileAlloc(io, "README.md", gpa, .limited(1024 * 1024)) catch return null;
        return .{ .content = content, .content_type = "text/markdown" };
    };
    switch (v) {
        .string => |path| return .{ .content = try readProjectFile(gpa, io, dir, path, "readme"), .content_type = contentTypeFor(path) },
        .table => |t| {
            const ct = t.getString("content-type");
            if (t.getString("file")) |path| return .{ .content = try readProjectFile(gpa, io, dir, path, "readme"), .content_type = ct orelse contentTypeFor(path) };
            if (t.getString("text")) |text| return .{ .content = try gpa.dupe(u8, text), .content_type = ct orelse "text/plain" };
            return fieldError("readme", "a path or a table with `file` or `text`");
        },
        else => return fieldError("readme", "a path or a table with `file` or `text`"),
    }
}

fn readProjectFile(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8, comptime what: []const u8) ![]u8 {
    return dir.readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| {
        std.debug.print("Error: cannot read " ++ what ++ " file '{s}': {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

fn contentTypeFor(path: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".markdown")) return "text/markdown";
    if (std.ascii.eqlIgnoreCase(ext, ".rst")) return "text/x-rst";
    return "text/plain";
}

/// PEP 639 license-files globs (a pattern without wildcards must exist), or by
/// default the usual top-level license files. Globs match within one directory
/// level (`LICENSES/*`); `**` is not supported.
fn collectLicenseFiles(gpa: std.mem.Allocator, io: Io, dir: Io.Dir, patterns: ?[]const toml.Value, extra: ?[]const u8) ![][]u8 {
    var found: std.ArrayList([]u8) = .empty;
    errdefer {
        for (found.items) |f| gpa.free(f);
        found.deinit(gpa);
    }
    const defaults = [_]toml.Value{ .{ .string = "LICEN[CS]E*" }, .{ .string = "COPYING*" }, .{ .string = "NOTICE*" }, .{ .string = "AUTHORS*" } };
    const explicit = patterns != null;
    for (patterns orelse &defaults) |pv| {
        const pattern = pv.asString() orelse return fieldError("license-files", "an array of glob strings");
        if (std.mem.indexOf(u8, pattern, "**") != null or std.mem.startsWith(u8, pattern, "/") or std.mem.indexOf(u8, pattern, "..") != null) {
            std.debug.print("Error: unsupported license-files pattern '{s}' (relative globs within one directory, no '**')\n", .{pattern});
            return error.InvalidProjectField;
        }
        const slash = std.mem.lastIndexOfScalar(u8, pattern, '/');
        const sub = if (slash) |s| pattern[0..s] else "";
        const file_glob = if (slash) |s| pattern[s + 1 ..] else pattern;
        if (std.mem.indexOfAny(u8, sub, "*?[") != null) {
            std.debug.print("Error: license-files pattern '{s}': wildcards are only supported in the file name\n", .{pattern});
            return error.InvalidProjectField;
        }

        var matched = false;
        var d = (if (sub.len == 0) dir.openDir(io, ".", .{ .iterate = true }) else dir.openDir(io, sub, .{ .iterate = true })) catch null;
        if (d) |*od| {
            defer od.close(io);
            var it = od.iterate();
            while (try it.next(io)) |e| {
                if (e.kind != .file or !globMatch(file_glob, e.name)) continue;
                matched = true;
                const rel = if (sub.len == 0) try gpa.dupe(u8, e.name) else try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, e.name });
                try appendUnique(gpa, &found, rel);
            }
        }
        if (explicit and !matched and std.mem.indexOfAny(u8, file_glob, "*?[") == null) {
            std.debug.print("Error: license file '{s}' (from license-files) does not exist\n", .{pattern});
            return error.LicenseFileNotFound;
        }
    }
    if (extra) |path| {
        dir.access(io, path, .{}) catch {
            std.debug.print("Error: license file '{s}' does not exist\n", .{path});
            return error.LicenseFileNotFound;
        };
        try appendUnique(gpa, &found, try gpa.dupe(u8, path));
    }
    std.mem.sort([]u8, found.items, {}, struct {
        fn lt(_: void, a: []u8, b: []u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return found.toOwnedSlice(gpa);
}

fn appendUnique(gpa: std.mem.Allocator, list: *std.ArrayList([]u8), item: []u8) !void {
    for (list.items) |existing| if (std.mem.eql(u8, existing, item)) {
        gpa.free(item);
        return;
    };
    try list.append(gpa, item);
}

/// Glob with `*`, `?` and `[...]` character classes.
fn globMatch(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;
    switch (pattern[0]) {
        '*' => {
            var i: usize = 0;
            while (i <= name.len) : (i += 1) if (globMatch(pattern[1..], name[i..])) return true;
            return false;
        },
        '?' => return name.len > 0 and globMatch(pattern[1..], name[1..]),
        '[' => {
            const close = std.mem.indexOfScalarPos(u8, pattern, 1, ']') orelse return name.len > 0 and name[0] == '[' and globMatch(pattern[1..], name[1..]);
            if (name.len == 0) return false;
            return std.mem.indexOfScalar(u8, pattern[1..close], name[0]) != null and globMatch(pattern[close + 1 ..], name[1..]);
        },
        else => return name.len > 0 and name[0] == pattern[0] and globMatch(pattern[1..], name[1..]),
    }
}

/// entry_points.txt from [project.scripts], [project.gui-scripts] and
/// [project.entry-points.<group>].
fn entryPoints(gpa: std.mem.Allocator, project: *toml.Table) !?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try entryGroup(gpa, &out, "console_scripts", project.getTable("scripts"));
    try entryGroup(gpa, &out, "gui_scripts", project.getTable("gui-scripts"));
    if (project.getTable("entry-points")) |groups| {
        for (groups.keys.items, groups.values.items) |group, v| {
            if (std.mem.eql(u8, group, "console_scripts") or std.mem.eql(u8, group, "gui_scripts")) {
                std.debug.print("Error: use [project.scripts] / [project.gui-scripts] instead of entry-points.{s}\n", .{group});
                return error.InvalidProjectField;
            }
            try entryGroup(gpa, &out, group, v.asTable() orelse return fieldError("entry-points", "tables of strings"));
        }
    }
    if (out.items.len == 0) return null;
    return try out.toOwnedSlice(gpa);
}

fn entryGroup(gpa: std.mem.Allocator, out: *std.ArrayList(u8), group: []const u8, table: ?*toml.Table) !void {
    const t = table orelse return;
    if (t.keys.items.len == 0) return;
    if (out.items.len > 0) try out.append(gpa, '\n');
    try out.print(gpa, "[{s}]\n", .{group});
    for (t.keys.items, t.values.items) |k, v| try out.print(gpa, "{s} = {s}\n", .{ k, v.asString() orelse return fieldError("scripts/entry-points", "tables of strings") });
}

/// Upload form fields for PyPI's legacy upload API, derived from METADATA
/// (the same mapping twine uses). Values point into `text`.
pub const FormField = struct { name: []const u8, value: []const u8 };

pub fn formFields(gpa: std.mem.Allocator, text: []const u8) ![]FormField {
    var fields: std.ArrayList(FormField) = .empty;
    errdefer fields.deinit(gpa);
    const split = std.mem.indexOf(u8, text, "\n\n") orelse text.len;
    var lines = std.mem.splitScalar(u8, text[0..split], '\n');
    while (lines.next()) |line| {
        // Folded continuation lines (License text) belong to the previous field
        if (line.len > 0 and (line[0] == ' ' or line[0] == '\t')) {
            if (fields.items.len > 0) {
                const last = &fields.items[fields.items.len - 1];
                const start = @intFromPtr(last.value.ptr) - @intFromPtr(text.ptr);
                const end = @intFromPtr(line.ptr) - @intFromPtr(text.ptr) + line.len;
                last.value = text[start..end];
            }
            continue;
        }
        const colon = std.mem.indexOf(u8, line, ": ") orelse continue;
        const key = line[0..colon];
        const name: ?[]const u8 = for (form_names) |m| {
            if (std.ascii.eqlIgnoreCase(m[0], key)) break m[1];
        } else null;
        if (name) |n| try fields.append(gpa, .{ .name = n, .value = line[colon + 2 ..] });
    }
    if (split + 2 < text.len) try fields.append(gpa, .{ .name = "description", .value = text[split + 2 ..] });
    return fields.toOwnedSlice(gpa);
}

const form_names = [_][2][]const u8{
    .{ "Metadata-Version", "metadata_version" },
    .{ "Name", "name" },
    .{ "Version", "version" },
    .{ "Summary", "summary" },
    .{ "Keywords", "keywords" },
    .{ "Author", "author" },
    .{ "Author-email", "author_email" },
    .{ "Maintainer", "maintainer" },
    .{ "Maintainer-email", "maintainer_email" },
    .{ "License", "license" },
    .{ "License-Expression", "license_expression" },
    .{ "License-File", "license_file" },
    .{ "Classifier", "classifiers" },
    .{ "Requires-Python", "requires_python" },
    .{ "Requires-Dist", "requires_dist" },
    .{ "Provides-Extra", "provides_extra" },
    .{ "Project-URL", "project_urls" },
    .{ "Description-Content-Type", "description_content_type" },
};

// ============================================================================
// Tests
// ============================================================================

fn testProject(tmp: *std.testing.TmpDir, pyproject: []const u8, files: []const [2][]const u8) !void {
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "pyproject.toml", .data = pyproject });
    for (files) |f| {
        if (std.fs.path.dirname(f[0])) |p| try tmp.dir.createDirPath(io, p);
        try tmp.dir.writeFile(io, .{ .sub_path = f[0], .data = f[1] });
    }
}

test "metadata from a full [project] table" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testProject(&tmp,
        \\[project]
        \\name = "liburing"
        \\version = "2026.3.25"
        \\description = "Python bindings"
        \\readme = "README.rst"
        \\license = "MIT"
        \\requires-python = ">=3.10"
        \\keywords = ["io_uring", "linux"]
        \\authors = [{ name = "Ada, L.", email = "ada@example.com" }, { name = "Bob" }]
        \\classifiers = [
        \\    "Operating System :: POSIX :: Linux",
        \\    "Programming Language :: Python :: 3",
        \\]
        \\dependencies = ["dynamic-import>=2024.1"]
        \\
        \\[project.optional-dependencies]
        \\Test_Suite = ["pytest", "numpy; python_version >= '3.11'"]
        \\
        \\[project.urls]
        \\Source = "https://github.com/YoSTEALTH/Liburing"
        \\
        \\[project.scripts]
        \\uring-info = "liburing.cli:main"
    , &.{ .{ "README.rst", "Title\n=====\n" }, .{ "LICENSE.txt", "MIT License\n" }, .{ "COPYING", "x" } });

    var md = try build(gpa, std.testing.io, tmp.dir);
    defer md.deinit(gpa);
    try std.testing.expectEqualStrings(
        \\Metadata-Version: 2.4
        \\Name: liburing
        \\Version: 2026.3.25
        \\Summary: Python bindings
        \\Keywords: io_uring,linux
        \\Author: Bob
        \\Author-email: "Ada, L." <ada@example.com>
        \\License-Expression: MIT
        \\License-File: COPYING
        \\License-File: LICENSE.txt
        \\Classifier: Operating System :: POSIX :: Linux
        \\Classifier: Programming Language :: Python :: 3
        \\Requires-Python: >=3.10
        \\Requires-Dist: dynamic-import>=2024.1
        \\Provides-Extra: test-suite
        \\Requires-Dist: pytest; extra == "test-suite"
        \\Requires-Dist: numpy; (python_version >= '3.11') and extra == "test-suite"
        \\Project-URL: Source, https://github.com/YoSTEALTH/Liburing
        \\Description-Content-Type: text/x-rst
        \\
        \\Title
        \\=====
        \\
    , md.text);
    try std.testing.expectEqual(@as(usize, 2), md.license_files.len);
    try std.testing.expectEqualStrings("[console_scripts]\nuring-info = liburing.cli:main\n", md.entry_points.?);

    const fields = try formFields(gpa, md.text);
    defer gpa.free(fields);
    var classifiers: usize = 0;
    for (fields) |f| if (std.mem.eql(u8, f.name, "classifiers")) {
        classifiers += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), classifiers);
    try std.testing.expectEqualStrings("description", fields[fields.len - 1].name);
    try std.testing.expectEqualStrings("Title\n=====\n", fields[fields.len - 1].value);
}

test "legacy license table, README.md default, no license files" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testProject(&tmp,
        \\[project]
        \\name = "demo"
        \\version = "0.1.0"
        \\license = { text = "Line one\nLine two" }
    , &.{.{ "README.md", "# Demo\n" }});
    var md = try build(gpa, std.testing.io, tmp.dir);
    defer md.deinit(gpa);
    try std.testing.expectEqualStrings(
        \\Metadata-Version: 2.1
        \\Name: demo
        \\Version: 0.1.0
        \\License: Line one
        \\        Line two
        \\Description-Content-Type: text/markdown
        \\
        \\# Demo
        \\
    , md.text);
    const fields = try formFields(gpa, md.text);
    defer gpa.free(fields);
    for (fields) |f| if (std.mem.eql(u8, f.name, "license")) try std.testing.expectEqualStrings("Line one\n        Line two", f.value);
}

test "license expression with a License classifier is rejected" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testProject(&tmp,
        \\[project]
        \\name = "x"
        \\license = "MIT"
        \\classifiers = ["License :: OSI Approved :: MIT License"]
    , &.{});
    try std.testing.expectError(error.LicenseClassifierConflict, build(std.testing.allocator, std.testing.io, tmp.dir));
}

test "explicit license-files must exist; globs in subdirectories" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try testProject(&tmp,
        \\[project]
        \\name = "x"
        \\license-files = ["LICENSES/*.txt"]
    , &.{ .{ "LICENSES/MIT.txt", "m" }, .{ "LICENSES/Apache-2.0.txt", "a" }, .{ "LICENSES/notes.md", "n" }, .{ "LICENSE", "ignored: explicit list" } });
    var md = try build(gpa, std.testing.io, tmp.dir);
    defer md.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), md.license_files.len);
    try std.testing.expectEqualStrings("LICENSES/Apache-2.0.txt", md.license_files[0]);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "pyproject.toml", .data = "[project]\nname = \"x\"\nlicense-files = [\"MISSING.txt\"]\n" });
    try std.testing.expectError(error.LicenseFileNotFound, build(gpa, std.testing.io, tmp.dir));
}

test globMatch {
    try std.testing.expect(globMatch("LICEN[CS]E*", "LICENSE.txt"));
    try std.testing.expect(globMatch("LICEN[CS]E*", "LICENCE"));
    try std.testing.expect(!globMatch("LICEN[CS]E*", "LICENXE"));
    try std.testing.expect(globMatch("*.txt", "a.txt"));
    try std.testing.expect(!globMatch("*.txt", "a.md"));
    try std.testing.expect(globMatch("NOTICE?", "NOTICE1"));
}
