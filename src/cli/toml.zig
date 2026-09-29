const std = @import("std");

/// Minimal TOML parser - only parses what PyOZ needs from pyproject.toml
/// Not a full TOML implementation!
pub const PyProjectConfig = struct {
    // [project]
    name: []const u8 = "",
    version: []const u8 = "",
    description: []const u8 = "",
    python_requires: []const u8 = "",

    // [tool.pyoz]
    module_name: []const u8 = "",
    module_path: []const u8 = "",
    optimize: []const u8 = "",
    strip: bool = false,
    linux_platform_tag: []const u8 = "",
    abi3: bool = false,
    py_packages: std.ArrayList([]const u8) = .empty,
    include_ext: std.ArrayList([]const u8) = .empty,

    // Track which fields were allocated
    name_allocated: bool = false,
    version_allocated: bool = false,
    description_allocated: bool = false,
    python_requires_allocated: bool = false,
    module_name_allocated: bool = false,
    module_path_allocated: bool = false,
    optimize_allocated: bool = false,
    linux_platform_tag_allocated: bool = false,

    pub fn deinit(self: *PyProjectConfig, allocator: std.mem.Allocator) void {
        if (self.name_allocated) allocator.free(self.name);
        if (self.version_allocated) allocator.free(self.version);
        if (self.description_allocated) allocator.free(self.description);
        if (self.python_requires_allocated) allocator.free(self.python_requires);
        if (self.module_name_allocated) allocator.free(self.module_name);
        if (self.module_path_allocated) allocator.free(self.module_path);
        if (self.optimize_allocated) allocator.free(self.optimize);
        if (self.linux_platform_tag_allocated) allocator.free(self.linux_platform_tag);
        for (self.py_packages.items) |pkg| allocator.free(pkg);
        self.py_packages.deinit(allocator);
        for (self.include_ext.items) |ext| allocator.free(ext);
        self.include_ext.deinit(allocator);
    }

    /// Get version with fallback to default
    pub fn getVersion(self: PyProjectConfig) []const u8 {
        return if (self.version.len > 0) self.version else "0.1.0";
    }

    /// Get python_requires with fallback to default
    pub fn getPythonRequires(self: PyProjectConfig) []const u8 {
        return if (self.python_requires.len > 0) self.python_requires else ">=3.10";
    }

    /// Get module_name with fallback to project name
    pub fn getModuleName(self: PyProjectConfig) []const u8 {
        return if (self.module_name.len > 0) self.module_name else self.name;
    }

    /// Get module_path with fallback to default
    pub fn getModulePath(self: PyProjectConfig) []const u8 {
        return if (self.module_path.len > 0) self.module_path else "src/lib.zig";
    }

    /// Get optimize (empty string means debug/unset)
    pub fn getOptimize(self: PyProjectConfig) []const u8 {
        return self.optimize;
    }

    /// Get linux platform tag (empty string means use default linux_* tag)
    pub fn getLinuxPlatformTag(self: PyProjectConfig) []const u8 {
        return self.linux_platform_tag;
    }

    /// Get ABI3 mode (Python 3.10 minimum)
    pub fn getAbi3(self: PyProjectConfig) bool {
        return self.abi3;
    }

    /// Check if a filename should be included based on include-ext.
    /// Defaults to .py only if include-ext is not set. Wildcard "*" matches all files.
    pub fn shouldIncludeFile(self: PyProjectConfig, basename: []const u8) bool {
        const exts = self.include_ext.items;
        if (exts.len == 0) {
            // Default: .py only
            return std.mem.endsWith(u8, basename, ".py");
        }
        for (exts) |ext| {
            if (std.mem.eql(u8, ext, "*")) return true;
            // Check if basename ends with ".{ext}"
            if (ext.len + 1 <= basename.len) {
                const tail = basename[basename.len - ext.len ..];
                if (basename[basename.len - ext.len - 1] == '.' and std.mem.eql(u8, tail, ext)) {
                    return true;
                }
            }
        }
        return false;
    }
};

const Section = enum {
    none,
    project,
    tool_pyoz,
    other,
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) !PyProjectConfig {
    var config = PyProjectConfig{};
    var current_section: Section = .none;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);

        // Skip empty lines and comments
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // Section header
        if (trimmed[0] == '[') {
            if (std.mem.eql(u8, trimmed, "[project]")) {
                current_section = .project;
            } else if (std.mem.eql(u8, trimmed, "[tool.pyoz]")) {
                current_section = .tool_pyoz;
            } else {
                current_section = .other;
            }
            continue;
        }

        // Key = value
        const eq_pos = std.mem.indexOf(u8, trimmed, "=") orelse continue;
        const key = std.mem.trim(u8, trimmed[0..eq_pos], &std.ascii.whitespace);
        const value = stripQuotes(std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace));

        switch (current_section) {
            .project => {
                if (std.mem.eql(u8, key, "name")) {
                    config.name = try allocator.dupe(u8, value);
                    config.name_allocated = true;
                } else if (std.mem.eql(u8, key, "version")) {
                    config.version = try allocator.dupe(u8, value);
                    config.version_allocated = true;
                } else if (std.mem.eql(u8, key, "description")) {
                    config.description = try allocator.dupe(u8, value);
                    config.description_allocated = true;
                } else if (std.mem.eql(u8, key, "requires-python")) {
                    config.python_requires = try allocator.dupe(u8, value);
                    config.python_requires_allocated = true;
                }
            },
            .tool_pyoz => {
                if (std.mem.eql(u8, key, "module-name")) {
                    config.module_name = try allocator.dupe(u8, value);
                    config.module_name_allocated = true;
                } else if (std.mem.eql(u8, key, "module-path")) {
                    config.module_path = try allocator.dupe(u8, value);
                    config.module_path_allocated = true;
                } else if (std.mem.eql(u8, key, "optimize")) {
                    config.optimize = try allocator.dupe(u8, value);
                    config.optimize_allocated = true;
                } else if (std.mem.eql(u8, key, "strip")) {
                    config.strip = std.mem.eql(u8, value, "true");
                } else if (std.mem.eql(u8, key, "linux-platform-tag")) {
                    config.linux_platform_tag = try allocator.dupe(u8, value);
                    config.linux_platform_tag_allocated = true;
                } else if (std.mem.eql(u8, key, "abi3")) {
                    config.abi3 = std.mem.eql(u8, value, "true");
                } else if (std.mem.eql(u8, key, "py-packages")) {
                    // Parse TOML array: ["pkg1", "pkg2"]
                    const raw = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);
                    if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') {
                        const inner = raw[1 .. raw.len - 1];
                        var items = std.mem.splitScalar(u8, inner, ',');
                        while (items.next()) |item| {
                            const stripped = stripQuotes(std.mem.trim(u8, item, &std.ascii.whitespace));
                            if (stripped.len > 0) {
                                try config.py_packages.append(allocator, try allocator.dupe(u8, stripped));
                            }
                        }
                    }
                } else if (std.mem.eql(u8, key, "include-ext")) {
                    // Parse TOML array: ["py", "zig", "json"] or ["*"]
                    const raw = std.mem.trim(u8, trimmed[eq_pos + 1 ..], &std.ascii.whitespace);
                    if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') {
                        const inner = raw[1 .. raw.len - 1];
                        var items = std.mem.splitScalar(u8, inner, ',');
                        while (items.next()) |item| {
                            const stripped = stripQuotes(std.mem.trim(u8, item, &std.ascii.whitespace));
                            if (stripped.len > 0) {
                                try config.include_ext.append(allocator, try allocator.dupe(u8, stripped));
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    if (config.name.len == 0) {
        return error.MissingProjectName;
    }

    return config;
}

fn stripQuotes(s: []const u8) []const u8 {
    if (s.len < 2) return s;
    if ((s[0] == '"' and s[s.len - 1] == '"') or
        (s[0] == '\'' and s[s.len - 1] == '\''))
    {
        return s[1 .. s.len - 1];
    }
    return s;
}

/// Load and parse pyproject.toml from the current directory
pub fn loadPyProject(allocator: std.mem.Allocator, io: std.Io) !PyProjectConfig {
    const content = std.Io.Dir.cwd().readFileAlloc(io, "pyproject.toml", allocator, .limited(1024 * 1024)) catch |err| {
        if (err == error.FileNotFound) {
            return error.PyProjectNotFound;
        }
        return err;
    };
    defer allocator.free(content);

    return parse(allocator, content);
}

// ============================================================================
// Document parser
// ============================================================================
//
// A TOML reader for the [project] table (PEP 621): multi-line arrays, inline
// tables (authors, license, readme), [project.urls] and friends. Strings are
// decoded; numbers, booleans and dates are kept as source text. Arrays of
// tables ([[x]]) are parsed but not kept: nothing PyOZ reads uses them.

pub const Value = union(enum) {
    string: []const u8,
    /// Numbers, booleans, dates: their source text
    raw: []const u8,
    array: []const Value,
    table: *Table,

    pub fn asString(v: Value) ?[]const u8 {
        return if (v == .string) v.string else null;
    }

    pub fn asArray(v: Value) ?[]const Value {
        return if (v == .array) v.array else null;
    }

    pub fn asTable(v: Value) ?*Table {
        return if (v == .table) v.table else null;
    }
};

pub const Table = struct {
    /// Insertion order is kept (metadata fields follow the file's order)
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(Value) = .empty,

    pub fn get(t: *const Table, key: []const u8) ?Value {
        for (t.keys.items, t.values.items) |k, v| if (std.mem.eql(u8, k, key)) return v;
        return null;
    }

    pub fn getString(t: *const Table, key: []const u8) ?[]const u8 {
        return if (t.get(key)) |v| v.asString() else null;
    }

    pub fn getArray(t: *const Table, key: []const u8) ?[]const Value {
        return if (t.get(key)) |v| v.asArray() else null;
    }

    pub fn getTable(t: *const Table, key: []const u8) ?*Table {
        return if (t.get(key)) |v| v.asTable() else null;
    }

    fn put(t: *Table, a: std.mem.Allocator, key: []const u8, value: Value) !void {
        if (t.get(key) != null) return error.DuplicateKey;
        try t.keys.append(a, key);
        try t.values.append(a, value);
    }

    /// Existing sub-table `key`, or a new one.
    fn sub(t: *Table, a: std.mem.Allocator, key: []const u8) !*Table {
        if (t.get(key)) |v| return v.asTable() orelse error.NotATable;
        const child = try a.create(Table);
        child.* = .{};
        try t.put(a, key, .{ .table = child });
        return child;
    }
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Table,

    pub fn deinit(d: *Document) void {
        d.arena.deinit();
    }
};

pub fn parseDocument(gpa: std.mem.Allocator, src: []const u8) !Document {
    var doc: Document = .{ .arena = .init(gpa), .root = undefined };
    errdefer doc.arena.deinit();
    const a = doc.arena.allocator();
    doc.root = try a.create(Table);
    doc.root.* = .{};

    var p: Parser = .{ .a = a, .s = src };
    var current = doc.root;
    var scratch: Table = .{}; // target of [[array.of.tables]] (discarded)
    while (true) {
        p.skipBlank();
        if (p.eof()) break;
        if (p.peek() == '[') {
            p.i += 1;
            const array_of_tables = !p.eof() and p.peek() == '[';
            if (array_of_tables) p.i += 1;
            const path = try p.keyPath();
            try p.expect(']');
            if (array_of_tables) try p.expect(']');
            try p.lineEnd();
            if (array_of_tables) {
                scratch = .{};
                current = &scratch;
            } else {
                current = doc.root;
                for (path) |k| current = try current.sub(a, k);
            }
        } else {
            const path = try p.keyPath();
            p.skipSpaces();
            try p.expect('=');
            p.skipSpaces();
            const value = try p.value();
            var t = current;
            for (path[0 .. path.len - 1]) |k| t = try t.sub(a, k);
            try t.put(a, path[path.len - 1], value);
            try p.lineEnd();
        }
    }
    return doc;
}

const Parser = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,

    fn eof(p: *Parser) bool {
        return p.i >= p.s.len;
    }

    fn peek(p: *Parser) u8 {
        return p.s[p.i];
    }

    fn startsWith(p: *Parser, prefix: []const u8) bool {
        return std.mem.startsWith(u8, p.s[p.i..], prefix);
    }

    fn skipSpaces(p: *Parser) void {
        while (!p.eof() and (p.peek() == ' ' or p.peek() == '\t')) p.i += 1;
    }

    /// Whitespace, newlines and comments
    fn skipBlank(p: *Parser) void {
        while (!p.eof()) {
            switch (p.peek()) {
                ' ', '\t', '\r', '\n' => p.i += 1,
                '#' => while (!p.eof() and p.peek() != '\n') {
                    p.i += 1;
                },
                else => return,
            }
        }
    }

    fn expect(p: *Parser, c: u8) !void {
        if (p.eof() or p.peek() != c) return error.InvalidToml;
        p.i += 1;
    }

    /// Rest of the line must be empty or a comment
    fn lineEnd(p: *Parser) !void {
        p.skipSpaces();
        if (!p.eof() and p.peek() == '#') while (!p.eof() and p.peek() != '\n') {
            p.i += 1;
        };
        if (p.eof()) return;
        if (p.peek() == '\r') p.i += 1;
        try p.expect('\n');
    }

    fn keyPath(p: *Parser) ![]const []const u8 {
        var parts: std.ArrayList([]const u8) = .empty;
        while (true) {
            p.skipSpaces();
            if (p.eof()) return error.InvalidToml;
            const key = switch (p.peek()) {
                '"' => try p.basicString(),
                '\'' => try p.literalString(),
                else => blk: {
                    const start = p.i;
                    while (!p.eof() and (std.ascii.isAlphanumeric(p.peek()) or p.peek() == '_' or p.peek() == '-')) p.i += 1;
                    if (p.i == start) return error.InvalidToml;
                    break :blk p.s[start..p.i];
                },
            };
            try parts.append(p.a, key);
            p.skipSpaces();
            if (p.eof() or p.peek() != '.') break;
            p.i += 1;
        }
        return parts.items;
    }

    fn value(p: *Parser) anyerror!Value {
        if (p.eof()) return error.InvalidToml;
        switch (p.peek()) {
            '"' => return .{ .string = if (p.startsWith("\"\"\"")) try p.multilineBasic() else try p.basicString() },
            '\'' => return .{ .string = if (p.startsWith("'''")) try p.multilineLiteral() else try p.literalString() },
            '[' => {
                p.i += 1;
                var items: std.ArrayList(Value) = .empty;
                while (true) {
                    p.skipBlank();
                    if (p.eof()) return error.InvalidToml;
                    if (p.peek() == ']') break;
                    try items.append(p.a, try p.value());
                    p.skipBlank();
                    if (p.eof()) return error.InvalidToml;
                    if (p.peek() == ',') {
                        p.i += 1;
                    } else if (p.peek() != ']') return error.InvalidToml;
                }
                p.i += 1;
                return .{ .array = items.items };
            },
            '{' => {
                p.i += 1;
                const t = try p.a.create(Table);
                t.* = .{};
                p.skipBlank();
                if (!p.eof() and p.peek() == '}') {
                    p.i += 1;
                    return .{ .table = t };
                }
                while (true) {
                    const path = try p.keyPath();
                    try p.expect('=');
                    p.skipSpaces();
                    const v = try p.value();
                    var target = t;
                    for (path[0 .. path.len - 1]) |k| target = try target.sub(p.a, k);
                    try target.put(p.a, path[path.len - 1], v);
                    p.skipBlank();
                    if (p.eof()) return error.InvalidToml;
                    if (p.peek() == ',') {
                        p.i += 1;
                        p.skipBlank();
                        continue;
                    }
                    try p.expect('}');
                    return .{ .table = t };
                }
            },
            else => {
                const start = p.i;
                while (!p.eof()) switch (p.peek()) {
                    ',', ']', '}', '#', '\n', '\r', ' ', '\t' => break,
                    else => p.i += 1,
                };
                if (p.i == start) return error.InvalidToml;
                return .{ .raw = p.s[start..p.i] };
            },
        }
    }

    fn basicString(p: *Parser) ![]const u8 {
        try p.expect('"');
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.eof() or p.peek() == '\n') return error.InvalidToml;
            const c = p.peek();
            p.i += 1;
            if (c == '"') return out.items;
            if (c == '\\') try p.escape(&out) else try out.append(p.a, c);
        }
    }

    fn multilineBasic(p: *Parser) ![]const u8 {
        p.i += 3;
        p.skipFirstNewline();
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.eof()) return error.InvalidToml;
            if (p.startsWith("\"\"\"")) {
                p.i += 3;
                // Up to two quotes may end the content: """a"""""
                var extra: usize = 0;
                while (extra < 2 and !p.eof() and p.peek() == '"') : ({
                    p.i += 1;
                    extra += 1;
                }) try out.append(p.a, '"');
                return out.items;
            }
            const c = p.peek();
            p.i += 1;
            if (c != '\\') {
                try out.append(p.a, c);
                continue;
            }
            // Line-ending backslash: trim the newline and following whitespace
            var j = p.i;
            while (j < p.s.len and (p.s[j] == ' ' or p.s[j] == '\t')) j += 1;
            if (j < p.s.len and (p.s[j] == '\n' or p.s[j] == '\r')) {
                p.i = j;
                while (!p.eof() and std.ascii.isWhitespace(p.peek())) p.i += 1;
            } else try p.escape(&out);
        }
    }

    fn literalString(p: *Parser) ![]const u8 {
        try p.expect('\'');
        const start = p.i;
        while (!p.eof() and p.peek() != '\'') : (p.i += 1) if (p.peek() == '\n') return error.InvalidToml;
        const s = p.s[start..p.i];
        try p.expect('\'');
        return s;
    }

    fn multilineLiteral(p: *Parser) ![]const u8 {
        p.i += 3;
        p.skipFirstNewline();
        const start = p.i;
        const end = std.mem.indexOfPos(u8, p.s, p.i, "'''") orelse return error.InvalidToml;
        p.i = end + 3;
        return p.s[start..end];
    }

    fn skipFirstNewline(p: *Parser) void {
        if (p.startsWith("\r\n")) p.i += 2 else if (p.startsWith("\n")) p.i += 1;
    }

    fn escape(p: *Parser, out: *std.ArrayList(u8)) !void {
        if (p.eof()) return error.InvalidToml;
        const c = p.peek();
        p.i += 1;
        const simple: ?u8 = switch (c) {
            'b' => 8,
            't' => '\t',
            'n' => '\n',
            'f' => 12,
            'r' => '\r',
            'e' => 27,
            '"' => '"',
            '\\' => '\\',
            else => null,
        };
        if (simple) |s| return out.append(p.a, s);
        const digits: usize = switch (c) {
            'u' => 4,
            'U' => 8,
            else => return error.InvalidToml,
        };
        if (p.i + digits > p.s.len) return error.InvalidToml;
        const cp = std.fmt.parseInt(u21, p.s[p.i .. p.i + digits], 16) catch return error.InvalidToml;
        p.i += digits;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return error.InvalidToml;
        try out.appendSlice(p.a, buf[0..n]);
    }
};

test parseDocument {
    const src =
        \\# comment
        \\[project]
        \\name = "demo"   # trailing
        \\description = "Say \"hi\" é"
        \\license = { text = "MIT" }
        \\keywords = ['a', "b",]
        \\classifiers = [
        \\    "Programming Language :: Python :: 3",  # why
        \\    "License :: OSI Approved :: MIT License",
        \\]
        \\authors = [{ name = "Ada", email = "ada@example.com" }, { name = "Bob" }]
        \\readme = """
        \\line1 \
        \\   continued"""
        \\version = "1.0"
        \\dynamic = []
        \\requires-python = '>=3.10'
        \\urls.Source = "https://example.com/src"
        \\
        \\[project.urls]
        \\Homepage = "https://example.com"
        \\
        \\[project.optional-dependencies]
        \\fast = ["numpy>=2; python_version >= '3.11'"]
        \\
        \\[[tool.other]]
        \\x = 1
        \\
        \\[tool.pyoz]
        \\abi3 = true
    ;
    var doc = try parseDocument(std.testing.allocator, src);
    defer doc.deinit();
    const project = doc.root.getTable("project").?;
    try std.testing.expectEqualStrings("demo", project.getString("name").?);
    try std.testing.expectEqualStrings("Say \"hi\" \u{e9}", project.getString("description").?);
    try std.testing.expectEqualStrings("MIT", project.getTable("license").?.getString("text").?);
    try std.testing.expectEqual(@as(usize, 2), project.getArray("keywords").?.len);
    try std.testing.expectEqualStrings("License :: OSI Approved :: MIT License", project.getArray("classifiers").?[1].string);
    try std.testing.expectEqualStrings("ada@example.com", project.getArray("authors").?[0].table.getString("email").?);
    try std.testing.expectEqualStrings("line1 continued", project.getString("readme").?);
    try std.testing.expectEqualStrings("https://example.com", project.getTable("urls").?.getString("Homepage").?);
    try std.testing.expectEqualStrings("https://example.com/src", project.getTable("urls").?.getString("Source").?);
    try std.testing.expectEqualStrings("numpy>=2; python_version >= '3.11'", project.getTable("optional-dependencies").?.getArray("fast").?[0].string);
    try std.testing.expectEqualStrings("true", doc.root.getTable("tool").?.getTable("pyoz").?.get("abi3").?.raw);
    try std.testing.expectError(error.InvalidToml, parseDocument(std.testing.allocator, "[project]\nname = \"unterminated\n"));
    try std.testing.expectError(error.DuplicateKey, parseDocument(std.testing.allocator, "a = 1\na = 2\n"));
}
