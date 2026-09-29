const std = @import("std");
const builtin = @import("builtin");
const metadata = @import("metadata.zig");

/// PyPI repository configuration
pub const Repository = struct {
    name: []const u8,
    url: []const u8,

    pub const pypi = Repository{
        .name = "PyPI",
        .url = "https://upload.pypi.org/legacy/",
    };

    pub const testpypi = Repository{
        .name = "TestPyPI",
        .url = "https://test.pypi.org/legacy/",
    };
};

/// Upload a wheel file to PyPI using native Zig HTTP client
pub fn uploadWheel(
    allocator: std.mem.Allocator,
    io: std.Io,
    wheel_path: []const u8,
    repo: Repository,
    username: []const u8,
    password: []const u8,
) !void {
    const basename = std.Io.Dir.path.basename(wheel_path);
    std.debug.print("Uploading {s} to {s}...\n", .{ basename, repo.name });

    // Read the wheel file
    const cwd = std.Io.Dir.cwd();
    const wheel_data = try cwd.readFileAlloc(io, wheel_path, allocator, .limited(500 * 1024 * 1024));
    defer allocator.free(wheel_data);

    // Calculate SHA256 hash
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(wheel_data, &hash, .{});

    const hash_hex = std.fmt.bytesToHex(hash, .lower);

    // Extract Python version tag from wheel filename
    const pyversion = extractPythonVersion(basename) orelse "py3";

    // Build multipart form data
    const boundary = "----PyOZUploadBoundary7MA4YWxkTrZu0gW";

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);

    // Add form fields
    try addFormField(allocator, &body, boundary, ":action", "file_upload");
    try addFormField(allocator, &body, boundary, "protocol_version", "1");
    try addFormField(allocator, &body, boundary, "filetype", "bdist_wheel");
    try addFormField(allocator, &body, boundary, "pyversion", pyversion);
    try addFormField(allocator, &body, boundary, "sha256_digest", &hash_hex);

    // The same core metadata the wheel's METADATA holds (classifiers,
    // license, URLs, dependencies, readme, ...), as upload form fields.
    var md = try metadata.build(allocator, io, cwd);
    defer md.deinit(allocator);
    const fields = try metadata.formFields(allocator, md.text);
    defer allocator.free(fields);
    for (fields) |f| try addFormField(allocator, &body, boundary, f.name, f.value);

    // Add the wheel file
    try addFormFile(allocator, &body, boundary, "content", basename, wheel_data);

    // Close the multipart form
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "--\r\n");

    // Create Basic Auth header
    const auth_input = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ username, password });
    defer allocator.free(auth_input);

    const auth_encoded = try base64Encode(allocator, auth_input);
    defer allocator.free(auth_encoded);

    const auth_header = try std.fmt.allocPrint(allocator, "Basic {s}", .{auth_encoded});
    defer allocator.free(auth_header);

    const content_type = try std.fmt.allocPrint(allocator, "multipart/form-data; boundary={s}", .{boundary});
    defer allocator.free(content_type);

    // Make HTTP request
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Capture the response body: PyPI explains *why* an upload was rejected there.
    var response: std.Io.Writer.Allocating = .init(allocator);
    defer response.deinit();

    const result = client.fetch(.{
        .location = .{ .url = repo.url },
        .method = .POST,
        .headers = .{
            .content_type = .{ .override = content_type },
            .authorization = .{ .override = auth_header },
        },
        .payload = body.items,
        .response_writer = &response.writer,
    }) catch |err| {
        std.debug.print("HTTP request failed: {s}\n", .{@errorName(err)});
        return error.NetworkError;
    };

    // Check response status
    const status_code = @intFromEnum(result.status);

    if (status_code >= 200 and status_code < 300) {
        std.debug.print("Upload successful!\n", .{});
    } else if (status_code == 400) {
        // PyPI says why in the response; add a hint for the common cases
        const msg = response.written();
        std.debug.print("Upload failed: {s} rejected the wheel (HTTP 400)\n", .{repo.name});
        printServerMessage(msg);
        if (containsIgnoreCase(msg, "already exists")) {
            std.debug.print("Hint: this version was already uploaded; bump the version in pyproject.toml.\n", .{});
        } else if (containsIgnoreCase(msg, "platform tag")) {
            std.debug.print("Hint: PyPI only accepts portable (manylinux) Linux wheels; rebuild without --native or linux-platform-tag = \"linux_*\".\n", .{});
        } else if (containsIgnoreCase(msg, "classifier")) {
            std.debug.print("Hint: check the classifiers in pyproject.toml against https://pypi.org/classifiers/\n", .{});
        }
        return error.BadRequest;
    } else if (status_code == 401 or status_code == 403) {
        std.debug.print("Upload failed: Authentication failed (HTTP {d})\n", .{status_code});
        std.debug.print("Make sure you're using an API token with username '__token__'\n", .{});
        return error.AuthFailed;
    } else {
        std.debug.print("Upload failed with HTTP status {d}\n", .{status_code});
        printServerMessage(response.written());
        return error.UploadFailed;
    }
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn printServerMessage(body: []const u8) void {
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    if (trimmed.len == 0) return;
    std.debug.print("Server response: {s}\n", .{trimmed[0..@min(trimmed.len, 2048)]});
}

fn extractPythonVersion(wheel_filename: []const u8) ?[]const u8 {
    // Format: {name}-{version}-{python}-{abi}-{platform}.whl
    var parts = std.mem.splitScalar(u8, wheel_filename, '-');
    _ = parts.next(); // name
    _ = parts.next(); // version
    return parts.next(); // python tag
}

fn addFormField(allocator: std.mem.Allocator, body: *std.ArrayList(u8), boundary: []const u8, name: []const u8, value: []const u8) !void {
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "\r\n");
    try body.appendSlice(allocator, "Content-Disposition: form-data; name=\"");
    try body.appendSlice(allocator, name);
    try body.appendSlice(allocator, "\"\r\n\r\n");
    try body.appendSlice(allocator, value);
    try body.appendSlice(allocator, "\r\n");
}

fn addFormFile(allocator: std.mem.Allocator, body: *std.ArrayList(u8), boundary: []const u8, name: []const u8, filename: []const u8, data: []const u8) !void {
    try body.appendSlice(allocator, "--");
    try body.appendSlice(allocator, boundary);
    try body.appendSlice(allocator, "\r\n");
    try body.appendSlice(allocator, "Content-Disposition: form-data; name=\"");
    try body.appendSlice(allocator, name);
    try body.appendSlice(allocator, "\"; filename=\"");
    try body.appendSlice(allocator, filename);
    try body.appendSlice(allocator, "\"\r\n");
    try body.appendSlice(allocator, "Content-Type: application/octet-stream\r\n\r\n");
    try body.appendSlice(allocator, data);
    try body.appendSlice(allocator, "\r\n");
}

fn base64Encode(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(input.len);
    const buf = try allocator.alloc(u8, size);
    _ = encoder.encode(buf, input);
    return buf;
}

/// Get API token from environment or show instructions.
/// For TestPyPI, TEST_PYPI_TOKEN takes precedence so a production token is never
/// sent to the test server when both are set.
pub fn getCredentials(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, repo: Repository) !struct { username: []const u8, password: []const u8 } {
    const is_test = std.mem.eql(u8, repo.name, "TestPyPI");
    const token: ?[]const u8 = if (is_test)
        environ.get("TEST_PYPI_TOKEN") orelse environ.get("PYPI_TOKEN")
    else
        environ.get("PYPI_TOKEN");

    if (token) |t| {
        return .{ .username = try allocator.dupe(u8, "__token__"), .password = try allocator.dupe(u8, t) };
    }

    // No token found - provide instructions
    std.debug.print("\nNo API token found.\n\n", .{});

    if (std.mem.eql(u8, repo.name, "TestPyPI")) {
        std.debug.print("To publish to TestPyPI:\n", .{});
        std.debug.print("  1. Create an account at https://test.pypi.org/\n", .{});
        std.debug.print("  2. Generate a token at https://test.pypi.org/manage/account/token/\n", .{});
        std.debug.print("  3. Set: export TEST_PYPI_TOKEN='pypi-...'\n", .{});
    } else {
        std.debug.print("To publish to PyPI:\n", .{});
        std.debug.print("  1. Create an account at https://pypi.org/\n", .{});
        std.debug.print("  2. Generate a token at https://pypi.org/manage/account/token/\n", .{});
        std.debug.print("  3. Set: export PYPI_TOKEN='pypi-...'\n", .{});
    }

    return error.NoCredentials;
}
