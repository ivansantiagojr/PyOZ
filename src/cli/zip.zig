const std = @import("std");

const flate = std.compress.flate;

/// Compression method for ZIP entries
pub const CompressionMethod = enum(u16) {
    store = 0,
    deflate = 8,
};

/// Compress data with raw DEFLATE (no zlib/gzip framing), as ZIP requires.
/// Pure Zig via std.compress.flate — replaces the vendored miniz C library,
/// which Zig 0.16's C translator can no longer import.
pub fn deflateCompress(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    if (data.len == 0) return allocator.alloc(u8, 0);

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, data.len / 2 + 64);
    defer out.deinit();

    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    var compressor = try flate.Compress.init(&out.writer, window, .raw, .default);
    try compressor.writer.writeAll(data);
    try compressor.finish();

    return out.toOwnedSlice();
}

/// Decompress raw DEFLATE data of a known uncompressed size.
pub fn deflateDecompress(allocator: std.mem.Allocator, compressed: []const u8, uncompressed_size: usize) ![]u8 {
    const out = try allocator.alloc(u8, uncompressed_size);
    errdefer allocator.free(out);
    if (uncompressed_size == 0) return out;

    const window = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window);

    var input: std.Io.Reader = .fixed(compressed);
    var decompressor: flate.Decompress = .init(&input, .raw, window);
    decompressor.reader.readSliceAll(out) catch return error.InflateFailed;
    return out;
}

test "deflate round trip" {
    const gpa = std.testing.allocator;
    const text = "PyOZ " ** 2000;
    const packed_bytes = try deflateCompress(gpa, text);
    defer gpa.free(packed_bytes);
    try std.testing.expect(packed_bytes.len < text.len / 10);
    const unpacked = try deflateDecompress(gpa, packed_bytes, text.len);
    defer gpa.free(unpacked);
    try std.testing.expectEqualStrings(text, unpacked);
}

/// ZIP file writer with optional compression support.
///
/// Output goes through a buffered `std.Io.File.Writer` (the 0.15 version issued
/// one unbuffered write syscall per header/name/payload). Every entry also records
/// its SHA-256 and size so the wheel builder can emit a spec-compliant RECORD.
pub const ZipWriter = struct {
    file: std.Io.File,
    io: std.Io,
    fw: std.Io.File.Writer,
    buffer: []u8,
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CentralDirEntry),
    bytes_written: u32,
    dos_time: u16,
    dos_date: u16,
    compression: CompressionMethod,

    const Self = @This();

    pub const Options = struct {
        compression: CompressionMethod = .deflate,
        /// Unix timestamp stamped on every entry. Callers should pass
        /// SOURCE_DATE_EPOCH when set, for reproducible wheels.
        mtime: ?i64 = null,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, options: Options) !Self {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        errdefer file.close(io);
        const buffer = try allocator.alloc(u8, 64 * 1024);
        errdefer allocator.free(buffer);

        const now = options.mtime orelse std.Io.Clock.real.now(io).toSeconds();
        const dos = timestampToDos(now);

        return Self{
            .file = file,
            .io = io,
            .fw = file.writer(io, buffer),
            .buffer = buffer,
            .allocator = allocator,
            .entries = .empty,
            .bytes_written = 0,
            .dos_time = dos.time,
            .dos_date = dos.date,
            .compression = options.compression,
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            self.allocator.free(entry.filename);
        }
        self.entries.deinit(self.allocator);
        self.file.close(self.io);
        self.allocator.free(self.buffer);
    }

    fn out(self: *Self) *std.Io.Writer {
        return &self.fw.interface;
    }

    fn advance(self: *Self, n: usize) !void {
        self.bytes_written = std.math.add(u32, self.bytes_written, std.math.cast(u32, n) orelse return error.ZipTooLarge) catch return error.ZipTooLarge;
    }

    /// Add a file to the ZIP archive with configured compression
    pub fn addFile(self: *Self, filename: []const u8, data: []const u8) !void {
        const local_header_offset = self.bytes_written;

        // Calculate CRC32 of uncompressed data
        const crc = std.hash.Crc32.hash(data);

        // Compress if needed
        var compressed_data: []const u8 = data;
        var compressed_owned: ?[]u8 = null;
        var method = self.compression;

        if (self.compression == .deflate and data.len > 0) {
            const compressed = deflateCompress(self.allocator, data) catch {
                // Fall back to store on compression error
                method = .store;
                compressed_data = data;
                compressed_owned = null;
                return self.writeEntry(filename, data, data, crc, .store, local_header_offset);
            };

            // Only use compression if it actually saves space
            if (compressed.len < data.len) {
                compressed_data = compressed;
                compressed_owned = compressed;
            } else {
                self.allocator.free(compressed);
                method = .store;
            }
        }
        defer if (compressed_owned) |owned| self.allocator.free(owned);

        try self.writeEntry(filename, compressed_data, data, crc, method, local_header_offset);
    }

    fn writeEntry(self: *Self, filename: []const u8, compressed_data: []const u8, original_data: []const u8, crc: u32, method: CompressionMethod, local_header_offset: u32) !void {
        const compressed_size = std.math.cast(u32, compressed_data.len) orelse return error.ZipTooLarge;
        const uncompressed_size = std.math.cast(u32, original_data.len) orelse return error.ZipTooLarge;

        // Write local file header
        var header: [30]u8 = undefined;

        // Local file header signature (0x04034b50)
        std.mem.writeInt(u32, header[0..4], 0x04034b50, .little);
        // Version needed to extract (2.0 = 20 for deflate)
        std.mem.writeInt(u16, header[4..6], if (method == .deflate) 20 else 10, .little);
        // General purpose bit flag
        std.mem.writeInt(u16, header[6..8], 0, .little);
        // Compression method
        std.mem.writeInt(u16, header[8..10], @intFromEnum(method), .little);
        // Last mod file time (DOS format)
        std.mem.writeInt(u16, header[10..12], self.dos_time, .little);
        // Last mod file date (DOS format)
        std.mem.writeInt(u16, header[12..14], self.dos_date, .little);
        // CRC-32
        std.mem.writeInt(u32, header[14..18], crc, .little);
        // Compressed size
        std.mem.writeInt(u32, header[18..22], compressed_size, .little);
        // Uncompressed size
        std.mem.writeInt(u32, header[22..26], uncompressed_size, .little);
        // File name length
        std.mem.writeInt(u16, header[26..28], @intCast(filename.len), .little);
        // Extra field length
        std.mem.writeInt(u16, header[28..30], 0, .little);

        try self.out().writeAll(&header);
        try self.out().writeAll(filename);
        try self.advance(30 + filename.len);

        // Write file data
        try self.out().writeAll(compressed_data);
        try self.advance(compressed_size);

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(original_data, &digest, .{});

        // Store entry for central directory
        try self.entries.append(self.allocator, .{
            .filename = try self.allocator.dupe(u8, filename),
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .crc32 = crc,
            .method = method,
            .local_header_offset = local_header_offset,
            .sha256 = digest,
        });
    }

    /// Append a wheel RECORD line (`path,sha256=<urlsafe-b64>,size`) for every
    /// entry written so far, followed by the RECORD file's own unhashed line.
    pub fn appendRecord(self: *const Self, list: *std.ArrayList(u8), record_path: []const u8) !void {
        const enc = std.base64.url_safe_no_pad.Encoder;
        for (self.entries.items) |entry| {
            var b64: [43]u8 = undefined;
            _ = enc.encode(&b64, &entry.sha256);
            try list.print(self.allocator, "{s},sha256={s},{d}\n", .{ entry.filename, &b64, entry.uncompressed_size });
        }
        try list.print(self.allocator, "{s},,\n", .{record_path});
    }

    /// Add a file from disk to the ZIP archive
    pub fn addFileFromDisk(self: *Self, filename: []const u8, disk_path: []const u8) !void {
        const data = try std.Io.Dir.cwd().readFileAlloc(self.io, disk_path, self.allocator, .limited(1024 * 1024 * 1024));
        defer self.allocator.free(data);
        try self.addFile(filename, data);
    }

    /// Finalize the ZIP file by writing central directory and end record
    pub fn finish(self: *Self) !void {
        const central_dir_offset = self.bytes_written;
        var central_dir_size: u32 = 0;

        // Write central directory entries
        for (self.entries.items) |entry| {
            var cd_header: [46]u8 = undefined;

            // Central directory file header signature (0x02014b50)
            std.mem.writeInt(u32, cd_header[0..4], 0x02014b50, .little);
            // Version made by (Unix = 3, version 2.0 = 20) -> 0x0314
            std.mem.writeInt(u16, cd_header[4..6], 0x0314, .little);
            // Version needed to extract
            std.mem.writeInt(u16, cd_header[6..8], if (entry.method == .deflate) 20 else 10, .little);
            // General purpose bit flag
            std.mem.writeInt(u16, cd_header[8..10], 0, .little);
            // Compression method
            std.mem.writeInt(u16, cd_header[10..12], @intFromEnum(entry.method), .little);
            // Last mod file time
            std.mem.writeInt(u16, cd_header[12..14], self.dos_time, .little);
            // Last mod file date
            std.mem.writeInt(u16, cd_header[14..16], self.dos_date, .little);
            // CRC-32
            std.mem.writeInt(u32, cd_header[16..20], entry.crc32, .little);
            // Compressed size
            std.mem.writeInt(u32, cd_header[20..24], entry.compressed_size, .little);
            // Uncompressed size
            std.mem.writeInt(u32, cd_header[24..28], entry.uncompressed_size, .little);
            // File name length
            std.mem.writeInt(u16, cd_header[28..30], @intCast(entry.filename.len), .little);
            // Extra field length
            std.mem.writeInt(u16, cd_header[30..32], 0, .little);
            // File comment length
            std.mem.writeInt(u16, cd_header[32..34], 0, .little);
            // Disk number start
            std.mem.writeInt(u16, cd_header[34..36], 0, .little);
            // Internal file attributes
            std.mem.writeInt(u16, cd_header[36..38], 0, .little);
            // External file attributes (Unix permissions: 0644 << 16)
            std.mem.writeInt(u32, cd_header[38..42], 0x81a40000, .little);
            // Relative offset of local header
            std.mem.writeInt(u32, cd_header[42..46], entry.local_header_offset, .little);

            try self.out().writeAll(&cd_header);
            try self.out().writeAll(entry.filename);

            central_dir_size += 46 + @as(u32, @intCast(entry.filename.len));
        }

        // Write end of central directory record
        var eocd: [22]u8 = undefined;

        // End of central directory signature (0x06054b50)
        std.mem.writeInt(u32, eocd[0..4], 0x06054b50, .little);
        // Number of this disk
        std.mem.writeInt(u16, eocd[4..6], 0, .little);
        // Disk where central directory starts
        std.mem.writeInt(u16, eocd[6..8], 0, .little);
        // Number of central directory records on this disk
        if (self.entries.items.len > std.math.maxInt(u16)) return error.ZipTooLarge;
        std.mem.writeInt(u16, eocd[8..10], @intCast(self.entries.items.len), .little);
        // Total number of central directory records
        std.mem.writeInt(u16, eocd[10..12], @intCast(self.entries.items.len), .little);
        // Size of central directory
        std.mem.writeInt(u32, eocd[12..16], central_dir_size, .little);
        // Offset of start of central directory
        std.mem.writeInt(u32, eocd[16..20], central_dir_offset, .little);
        // Comment length
        std.mem.writeInt(u16, eocd[20..22], 0, .little);

        try self.out().writeAll(&eocd);
        try self.fw.interface.flush();
    }
};

const CentralDirEntry = struct {
    filename: []const u8,
    compressed_size: u32,
    uncompressed_size: u32,
    crc32: u32,
    method: CompressionMethod,
    local_header_offset: u32,
    sha256: [32]u8,
};

/// Convert Unix timestamp to DOS date/time format
fn timestampToDos(timestamp: i64) struct { time: u16, date: u16 } {
    // Convert to epoch seconds then to broken-down time
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, timestamp)) };
    const epoch_day = epoch_seconds.getEpochDay();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1;

    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    // DOS date: bits 0-4 = day, bits 5-8 = month, bits 9-15 = year - 1980
    // DOS time: bits 0-4 = second/2, bits 5-10 = minute, bits 11-15 = hour
    const dos_year: u16 = if (year >= 1980) @intCast(year - 1980) else 0;

    const dos_date: u16 = (@as(u16, dos_year) << 9) | (@as(u16, month) << 5) | @as(u16, day);
    const dos_time: u16 = (@as(u16, hour) << 11) | (@as(u16, minute) << 5) | (@as(u16, second) >> 1);

    return .{ .time = dos_time, .date = dos_date };
}
