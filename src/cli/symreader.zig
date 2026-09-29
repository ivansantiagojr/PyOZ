//! Cross-platform symbol reader for extracting data from compiled modules
//!
//! This module reads ELF (Linux), PE (Windows), and Mach-O (macOS) files
//! to extract symbol data without actually loading the library.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Upper bound on module size we are willing to load for inspection.
const max_module_size = 512 * 1024 * 1024;

/// In-memory view of a module file with a seek/read cursor.
/// The whole file is read once; parsers then work on the slice, which avoids
/// hundreds of small seek/read syscalls and makes short reads impossible.
const Blob = struct {
    data: []const u8,
    pos: u64 = 0,

    fn seekTo(self: *Blob, offset: u64) error{Unseekable}!void {
        if (offset > self.data.len) return error.Unseekable;
        self.pos = offset;
    }

    fn read(self: *Blob, buf: []u8) error{}!usize {
        const start: usize = @intCast(self.pos);
        const n = @min(buf.len, self.data.len - start);
        @memcpy(buf[0..n], self.data[start..][0..n]);
        self.pos += n;
        return n;
    }
};

fn loadModule(io: Io, allocator: std.mem.Allocator, module_path: []const u8) ?[]u8 {
    return Io.Dir.cwd().readFileAlloc(io, module_path, allocator, .limited(max_module_size)) catch null;
}

/// Read stubs data directly from a compiled module file
pub fn extractStubs(io: Io, allocator: std.mem.Allocator, module_path: []const u8) !?[]const u8 {
    const bytes = loadModule(io, allocator, module_path) orelse return null;
    defer allocator.free(bytes);
    var blob: Blob = .{ .data = bytes };
    const file = &blob;

    // Read magic bytes to determine file format
    var magic: [4]u8 = undefined;
    _ = file.read(&magic) catch return null;
    file.seekTo(0) catch return null;

    // ELF: 0x7F 'E' 'L' 'F'
    if (magic[0] == 0x7F and magic[1] == 'E' and magic[2] == 'L' and magic[3] == 'F') {
        return extractFromElf(allocator, file);
    }

    // PE: 'M' 'Z'
    if (magic[0] == 'M' and magic[1] == 'Z') {
        return extractFromPe(allocator, file);
    }

    // Mach-O 64-bit little-endian: 0xCFFAEDFE
    if (magic[0] == 0xCF and magic[1] == 0xFA and magic[2] == 0xED and magic[3] == 0xFE) {
        return extractFromMachO64(allocator, file);
    }

    // Mach-O 64-bit big-endian: 0xFEEDFACF
    if (magic[0] == 0xFE and magic[1] == 0xED and magic[2] == 0xFA and magic[3] == 0xCF) {
        return extractFromMachO64BE(allocator, file);
    }

    return null;
}

// =============================================================================
// ELF Parser (Linux)
// =============================================================================

fn extractFromElf(allocator: std.mem.Allocator, file: *Blob) !?[]const u8 {
    const elf = std.elf;

    // Read ELF header
    var ehdr: elf.Elf64_Ehdr = undefined;
    const ehdr_bytes = std.mem.asBytes(&ehdr);
    const bytes_read = file.read(ehdr_bytes) catch return null;
    if (bytes_read != @sizeOf(elf.Elf64_Ehdr)) return null;

    // Verify it's a 64-bit ELF
    if (ehdr.e_ident[elf.EI_CLASS] != elf.ELFCLASS64) {
        return null;
    }

    // Find section header string table
    const shstrtab_offset = ehdr.e_shoff + @as(u64, ehdr.e_shstrndx) * @as(u64, ehdr.e_shentsize);
    file.seekTo(shstrtab_offset) catch return null;

    var shstrtab_shdr: elf.Elf64_Shdr = undefined;
    _ = file.read(std.mem.asBytes(&shstrtab_shdr)) catch return null;

    // Read section header string table
    const shstrtab = allocator.alloc(u8, shstrtab_shdr.sh_size) catch return null;
    defer allocator.free(shstrtab);
    file.seekTo(shstrtab_shdr.sh_offset) catch return null;
    _ = file.read(shstrtab) catch return null;

    // Find symbol tables, string tables, and .pyozstub section
    var symtab_shdr: ?elf.Elf64_Shdr = null;
    var strtab_shdr: ?elf.Elf64_Shdr = null;
    var dynsym_shdr: ?elf.Elf64_Shdr = null;
    var dynstr_shdr: ?elf.Elf64_Shdr = null;
    var pyozstub_shdr: ?elf.Elf64_Shdr = null;

    var i: u16 = 0;
    while (i < ehdr.e_shnum) : (i += 1) {
        const shdr_offset = ehdr.e_shoff + @as(u64, i) * @as(u64, ehdr.e_shentsize);
        file.seekTo(shdr_offset) catch continue;

        var shdr: elf.Elf64_Shdr = undefined;
        _ = file.read(std.mem.asBytes(&shdr)) catch continue;

        const name = std.mem.sliceTo(shstrtab[shdr.sh_name..], 0);

        if (std.mem.eql(u8, name, ".symtab")) {
            symtab_shdr = shdr;
        } else if (std.mem.eql(u8, name, ".strtab")) {
            strtab_shdr = shdr;
        } else if (std.mem.eql(u8, name, ".dynsym")) {
            dynsym_shdr = shdr;
        } else if (std.mem.eql(u8, name, ".dynstr")) {
            dynstr_shdr = shdr;
        } else if (std.mem.eql(u8, name, ".pyozstub")) {
            pyozstub_shdr = shdr;
        }
    }

    // Try .pyozstub section first (survives stripping)
    if (pyozstub_shdr) |shdr| {
        if (try extractFromSection(allocator, file, shdr.sh_offset, shdr.sh_size)) |result| {
            return result;
        }
    }

    // Fall back to symbol-based extraction (non-stripped binaries)
    if (symtab_shdr != null and strtab_shdr != null) {
        if (try findElfSymbol(allocator, file, symtab_shdr.?, strtab_shdr.?, ehdr)) |result| {
            return result;
        }
    }

    if (dynsym_shdr != null and dynstr_shdr != null) {
        if (try findElfSymbol(allocator, file, dynsym_shdr.?, dynstr_shdr.?, ehdr)) |result| {
            return result;
        }
    }

    return null;
}

/// Extract data from a section with format: magic (8 bytes) + 8-byte length + content
fn extractFromSection(allocator: std.mem.Allocator, file: *Blob, offset: u64, size: u64) !?[]const u8 {
    return extractFromSectionWithMagic(allocator, file, offset, size, "PYOZSTUB");
}

/// Generic section extraction with configurable magic string
fn extractFromSectionWithMagic(allocator: std.mem.Allocator, file: *Blob, offset: u64, size: u64, magic: *const [8]u8) !?[]const u8 {
    if (size < 16) return null; // Need at least header

    file.seekTo(offset) catch return null;

    // Read and verify magic
    var header: [16]u8 = undefined;
    _ = file.read(&header) catch return null;

    if (!std.mem.eql(u8, header[0..8], magic)) return null;

    // Read length (little-endian u64)
    const data_len = std.mem.readInt(u64, header[8..16], .little);
    if (data_len == 0 or data_len > 1024 * 1024) return null;
    if (data_len + 16 > size) return null;

    // Read content
    const data = allocator.alloc(u8, data_len) catch return null;
    errdefer allocator.free(data);

    const read_count = file.read(data) catch {
        allocator.free(data);
        return null;
    };
    if (read_count != data_len) {
        allocator.free(data);
        return null;
    }

    return data;
}

/// Extract data from a named section in a compiled module file.
/// Searches for the section by name in ELF/PE/MachO format.
fn extractNamedSection(io: Io, allocator: std.mem.Allocator, module_path: []const u8, elf_name: []const u8, macho_name: []const u8, magic: *const [8]u8) !?[]const u8 {
    const bytes = loadModule(io, allocator, module_path) orelse return null;
    defer allocator.free(bytes);
    var blob: Blob = .{ .data = bytes };
    const file = &blob;

    var file_magic: [4]u8 = undefined;
    _ = file.read(&file_magic) catch return null;
    file.seekTo(0) catch return null;

    if (file_magic[0] == 0x7F and file_magic[1] == 'E' and file_magic[2] == 'L' and file_magic[3] == 'F') {
        return extractNamedSectionElf(allocator, file, elf_name, magic);
    }
    if (file_magic[0] == 'M' and file_magic[1] == 'Z') {
        return extractNamedSectionPe(allocator, file, elf_name, magic);
    }
    if (file_magic[0] == 0xCF and file_magic[1] == 0xFA and file_magic[2] == 0xED and file_magic[3] == 0xFE) {
        return extractNamedSectionMachO(allocator, file, macho_name, magic);
    }

    return null;
}

/// ELF: find a named section and extract its content
fn extractNamedSectionElf(allocator: std.mem.Allocator, file: *Blob, section_name: []const u8, magic: *const [8]u8) !?[]const u8 {
    const elf = std.elf;

    var ehdr: elf.Elf64_Ehdr = undefined;
    const bytes_read = file.read(std.mem.asBytes(&ehdr)) catch return null;
    if (bytes_read != @sizeOf(elf.Elf64_Ehdr)) return null;
    if (ehdr.e_ident[elf.EI_CLASS] != elf.ELFCLASS64) return null;

    const shstrtab_offset = ehdr.e_shoff + @as(u64, ehdr.e_shstrndx) * @as(u64, ehdr.e_shentsize);
    file.seekTo(shstrtab_offset) catch return null;

    var shstrtab_shdr: elf.Elf64_Shdr = undefined;
    _ = file.read(std.mem.asBytes(&shstrtab_shdr)) catch return null;

    const shstrtab = allocator.alloc(u8, shstrtab_shdr.sh_size) catch return null;
    defer allocator.free(shstrtab);
    file.seekTo(shstrtab_shdr.sh_offset) catch return null;
    _ = file.read(shstrtab) catch return null;

    var i: u16 = 0;
    while (i < ehdr.e_shnum) : (i += 1) {
        const shdr_offset = ehdr.e_shoff + @as(u64, i) * @as(u64, ehdr.e_shentsize);
        file.seekTo(shdr_offset) catch continue;

        var shdr: elf.Elf64_Shdr = undefined;
        _ = file.read(std.mem.asBytes(&shdr)) catch continue;

        const name = std.mem.sliceTo(shstrtab[shdr.sh_name..], 0);
        if (std.mem.eql(u8, name, section_name)) {
            return extractFromSectionWithMagic(allocator, file, shdr.sh_offset, shdr.sh_size, magic);
        }
    }
    return null;
}

/// PE: find a named section and extract its content
fn extractNamedSectionPe(allocator: std.mem.Allocator, file: *Blob, section_name: []const u8, magic: *const [8]u8) !?[]const u8 {
    var dos_header: [64]u8 = undefined;
    _ = file.read(&dos_header) catch return null;

    const pe_offset = std.mem.readInt(u32, dos_header[0x3C..0x40], .little);
    file.seekTo(pe_offset) catch return null;

    var pe_sig: [4]u8 = undefined;
    _ = file.read(&pe_sig) catch return null;
    if (!std.mem.eql(u8, &pe_sig, "PE\x00\x00")) return null;

    var coff_header: [20]u8 = undefined;
    _ = file.read(&coff_header) catch return null;

    const num_sections = std.mem.readInt(u16, coff_header[2..4], .little);
    const optional_header_size = std.mem.readInt(u16, coff_header[16..18], .little);

    const sections_offset = pe_offset + 24 + optional_header_size;
    file.seekTo(sections_offset) catch return null;

    // PE section names are 8 chars max; compare prefix
    const prefix_len = @min(section_name.len, 8);

    var i: u16 = 0;
    while (i < num_sections) : (i += 1) {
        var section_header: [40]u8 = undefined;
        _ = file.read(&section_header) catch return null;

        const sec_name = std.mem.sliceTo(section_header[0..8], 0);
        if (sec_name.len >= prefix_len and std.mem.startsWith(u8, sec_name, section_name[0..prefix_len])) {
            const raw_offset = std.mem.readInt(u32, section_header[20..24], .little);
            const raw_size = std.mem.readInt(u32, section_header[16..20], .little);
            return extractFromSectionWithMagic(allocator, file, raw_offset, raw_size, magic);
        }
    }
    return null;
}

/// MachO: find a named section and extract its content
fn extractNamedSectionMachO(allocator: std.mem.Allocator, file: *Blob, section_name: []const u8, magic_bytes: *const [8]u8) !?[]const u8 {
    var header: [32]u8 = undefined;
    _ = file.read(&header) catch return null;

    const ncmds = std.mem.readInt(u32, header[16..20], .little);

    var cmd_offset: u64 = 32;
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        file.seekTo(cmd_offset) catch break;

        var cmd_header: [8]u8 = undefined;
        _ = file.read(&cmd_header) catch break;

        const cmd = std.mem.readInt(u32, cmd_header[0..4], .little);
        const cmdsize = std.mem.readInt(u32, cmd_header[4..8], .little);

        if (cmd == LC_SEGMENT_64) {
            var seg_cmd: [72]u8 = undefined;
            file.seekTo(cmd_offset) catch break;
            _ = file.read(&seg_cmd) catch break;

            const nsects = std.mem.readInt(u32, seg_cmd[64..68], .little);
            var sect_offset: u64 = cmd_offset + 72;

            var s: u32 = 0;
            while (s < nsects) : (s += 1) {
                file.seekTo(sect_offset) catch break;
                var sect_hdr: [80]u8 = undefined;
                _ = file.read(&sect_hdr) catch break;

                const sect_name = std.mem.sliceTo(sect_hdr[0..16], 0);
                if (std.mem.eql(u8, sect_name, section_name)) {
                    const sect_file_offset: u64 = std.mem.readInt(u32, sect_hdr[48..52], .little);
                    const sect_size: u64 = std.mem.readInt(u64, sect_hdr[40..48], .little);
                    return extractFromSectionWithMagic(allocator, file, sect_file_offset, sect_size, magic_bytes);
                }
                sect_offset += 80;
            }
        }
        cmd_offset += cmdsize;
    }
    return null;
}

/// Check if a compiled module exports a specific symbol (e.g., "PyInit__liburing").
/// Used to validate that the module's export function matches the expected name.
pub fn hasExportSymbol(io: Io, allocator: std.mem.Allocator, module_path: []const u8, symbol_name: []const u8) bool {
    const bytes = loadModule(io, allocator, module_path) orelse return false;
    defer allocator.free(bytes);
    var blob: Blob = .{ .data = bytes };
    const file = &blob;

    var magic: [4]u8 = undefined;
    _ = file.read(&magic) catch return false;
    file.seekTo(0) catch return false;

    // ELF
    if (magic[0] == 0x7F and magic[1] == 'E' and magic[2] == 'L' and magic[3] == 'F') {
        return elfHasSymbol(allocator, file, symbol_name);
    }

    // PE
    if (magic[0] == 'M' and magic[1] == 'Z') {
        return peHasSymbol(allocator, file, symbol_name);
    }

    // Mach-O — assume valid if we can't parse (symbol tables are complex)
    return true;
}

/// Check if an ELF file exports a specific symbol via .dynsym
fn elfHasSymbol(allocator: std.mem.Allocator, file: *Blob, symbol_name: []const u8) bool {
    const elf = std.elf;

    var ehdr: elf.Elf64_Ehdr = undefined;
    const bytes_read = file.read(std.mem.asBytes(&ehdr)) catch return false;
    if (bytes_read != @sizeOf(elf.Elf64_Ehdr)) return false;
    if (ehdr.e_ident[elf.EI_CLASS] != elf.ELFCLASS64) return false;

    // Read section header string table
    const shstrtab_offset = ehdr.e_shoff + @as(u64, ehdr.e_shstrndx) * @as(u64, ehdr.e_shentsize);
    file.seekTo(shstrtab_offset) catch return false;

    var shstrtab_shdr: elf.Elf64_Shdr = undefined;
    _ = file.read(std.mem.asBytes(&shstrtab_shdr)) catch return false;

    const shstrtab = allocator.alloc(u8, shstrtab_shdr.sh_size) catch return false;
    defer allocator.free(shstrtab);
    file.seekTo(shstrtab_shdr.sh_offset) catch return false;
    _ = file.read(shstrtab) catch return false;

    // Find .dynsym and .dynstr (dynamic symbols survive stripping)
    var dynsym_shdr: ?elf.Elf64_Shdr = null;
    var dynstr_shdr: ?elf.Elf64_Shdr = null;
    var symtab_shdr: ?elf.Elf64_Shdr = null;
    var strtab_shdr: ?elf.Elf64_Shdr = null;

    var i: u16 = 0;
    while (i < ehdr.e_shnum) : (i += 1) {
        const shdr_offset = ehdr.e_shoff + @as(u64, i) * @as(u64, ehdr.e_shentsize);
        file.seekTo(shdr_offset) catch continue;

        var shdr: elf.Elf64_Shdr = undefined;
        _ = file.read(std.mem.asBytes(&shdr)) catch continue;

        const name = std.mem.sliceTo(shstrtab[shdr.sh_name..], 0);
        if (std.mem.eql(u8, name, ".dynsym")) dynsym_shdr = shdr;
        if (std.mem.eql(u8, name, ".dynstr")) dynstr_shdr = shdr;
        if (std.mem.eql(u8, name, ".symtab")) symtab_shdr = shdr;
        if (std.mem.eql(u8, name, ".strtab")) strtab_shdr = shdr;
    }

    // Check .dynsym first (always present in shared libraries)
    if (dynsym_shdr != null and dynstr_shdr != null) {
        if (elfSymtabContains(allocator, file, dynsym_shdr.?, dynstr_shdr.?, symbol_name)) return true;
    }
    // Fall back to .symtab (non-stripped)
    if (symtab_shdr != null and strtab_shdr != null) {
        if (elfSymtabContains(allocator, file, symtab_shdr.?, strtab_shdr.?, symbol_name)) return true;
    }

    return false;
}

/// Check if an ELF symbol table contains a specific symbol name
fn elfSymtabContains(allocator: std.mem.Allocator, file: *Blob, symtab: std.elf.Elf64_Shdr, strtab: std.elf.Elf64_Shdr, symbol_name: []const u8) bool {
    const strtab_data = allocator.alloc(u8, strtab.sh_size) catch return false;
    defer allocator.free(strtab_data);
    file.seekTo(strtab.sh_offset) catch return false;
    _ = file.read(strtab_data) catch return false;

    const sym_count = symtab.sh_size / @sizeOf(std.elf.Elf64_Sym);
    var j: u64 = 0;
    while (j < sym_count) : (j += 1) {
        const sym_offset = symtab.sh_offset + j * @sizeOf(std.elf.Elf64_Sym);
        file.seekTo(sym_offset) catch continue;

        var sym: std.elf.Elf64_Sym = undefined;
        _ = file.read(std.mem.asBytes(&sym)) catch continue;

        if (sym.st_name >= strtab_data.len) continue;
        const sym_name = std.mem.sliceTo(strtab_data[sym.st_name..], 0);
        if (std.mem.eql(u8, sym_name, symbol_name)) return true;
    }
    return false;
}

/// Check if a PE file exports a specific symbol
fn peHasSymbol(allocator: std.mem.Allocator, file: *Blob, symbol_name: []const u8) bool {
    _ = allocator;

    // Read DOS header
    var dos_header: [64]u8 = undefined;
    _ = file.read(&dos_header) catch return false;
    const pe_offset = std.mem.readInt(u32, dos_header[0x3C..0x40], .little);
    file.seekTo(pe_offset) catch return false;

    // Verify PE signature
    var pe_sig: [4]u8 = undefined;
    _ = file.read(&pe_sig) catch return false;
    if (!std.mem.eql(u8, &pe_sig, "PE\x00\x00")) return false;

    // Read COFF header
    var coff_header: [20]u8 = undefined;
    _ = file.read(&coff_header) catch return false;
    const optional_header_size = std.mem.readInt(u16, coff_header[16..18], .little);

    // Read optional header to get export directory RVA
    if (optional_header_size < 112) return false;
    var opt_header_buf: [256]u8 = undefined;
    const read_size = @min(optional_header_size, 256);
    _ = file.read(opt_header_buf[0..read_size]) catch return false;

    // PE32+ magic check
    const pe_magic = std.mem.readInt(u16, opt_header_buf[0..2], .little);
    if (pe_magic != 0x020B) return false; // Not PE32+

    // Export directory RVA is at offset 112 in PE32+ optional header
    if (read_size < 120) return false;
    const export_rva = std.mem.readInt(u32, opt_header_buf[112..116], .little);
    const export_size = std.mem.readInt(u32, opt_header_buf[116..120], .little);
    if (export_rva == 0 or export_size == 0) return false;

    // Read section headers to find the section containing the export directory
    const num_sections = std.mem.readInt(u16, coff_header[2..4], .little);
    var s: u16 = 0;
    while (s < num_sections) : (s += 1) {
        var section_header: [40]u8 = undefined;
        _ = file.read(&section_header) catch return false;

        const va = std.mem.readInt(u32, section_header[12..16], .little);
        const raw_size = std.mem.readInt(u32, section_header[16..20], .little);
        const raw_offset = std.mem.readInt(u32, section_header[20..24], .little);
        const vsize = std.mem.readInt(u32, section_header[8..12], .little);

        if (export_rva >= va and export_rva < va + @max(vsize, raw_size)) {
            // Found the section containing exports
            const export_file_offset = raw_offset + (export_rva - va);
            file.seekTo(export_file_offset) catch return false;

            var export_dir: [40]u8 = undefined;
            _ = file.read(&export_dir) catch return false;

            const num_names = std.mem.readInt(u32, export_dir[24..28], .little);
            const names_rva = std.mem.readInt(u32, export_dir[32..36], .little);
            const names_file_offset = raw_offset + (names_rva - va);

            // Read name pointer array
            var n: u32 = 0;
            while (n < num_names) : (n += 1) {
                file.seekTo(names_file_offset + n * 4) catch return false;
                var name_rva_buf: [4]u8 = undefined;
                _ = file.read(&name_rva_buf) catch return false;
                const name_rva = std.mem.readInt(u32, &name_rva_buf, .little);

                const name_file_offset = raw_offset + (name_rva - va);
                file.seekTo(name_file_offset) catch continue;

                var name_buf: [256]u8 = undefined;
                const name_bytes_read = file.read(&name_buf) catch continue;
                if (name_bytes_read == 0) continue;

                const name = std.mem.sliceTo(name_buf[0..name_bytes_read], 0);
                if (std.mem.eql(u8, name, symbol_name)) return true;
            }
            return false;
        }
    }
    return false;
}

/// Read test data directly from a compiled module file
pub fn extractTests(io: Io, allocator: std.mem.Allocator, module_path: []const u8) !?[]const u8 {
    return extractNamedSection(io, allocator, module_path, ".pyoztest", "__pyoztest", "PYOZTEST");
}

/// Read benchmark data directly from a compiled module file
pub fn extractBenchmarks(io: Io, allocator: std.mem.Allocator, module_path: []const u8) !?[]const u8 {
    return extractNamedSection(io, allocator, module_path, ".pyozbenc", "__pyozbenc", "PYOZBENC");
}

fn findElfSymbol(
    allocator: std.mem.Allocator,
    file: *Blob,
    symtab_shdr: std.elf.Elf64_Shdr,
    strtab_shdr: std.elf.Elf64_Shdr,
    ehdr: std.elf.Elf64_Ehdr,
) !?[]const u8 {
    const elf = std.elf;

    // Read string table
    const strtab = allocator.alloc(u8, strtab_shdr.sh_size) catch return null;
    defer allocator.free(strtab);
    file.seekTo(strtab_shdr.sh_offset) catch return null;
    _ = file.read(strtab) catch return null;

    // Find our symbols
    const sym_count = symtab_shdr.sh_size / @sizeOf(elf.Elf64_Sym);
    var stubs_data_sym: ?elf.Elf64_Sym = null;
    var stubs_len_sym: ?elf.Elf64_Sym = null;

    var j: u64 = 0;
    while (j < sym_count) : (j += 1) {
        const sym_offset = symtab_shdr.sh_offset + j * @sizeOf(elf.Elf64_Sym);
        file.seekTo(sym_offset) catch continue;

        var sym: elf.Elf64_Sym = undefined;
        _ = file.read(std.mem.asBytes(&sym)) catch continue;

        if (sym.st_name >= strtab.len) continue;
        const sym_name = std.mem.sliceTo(strtab[sym.st_name..], 0);

        if (std.mem.eql(u8, sym_name, "__pyoz_stubs_data__")) {
            stubs_data_sym = sym;
        } else if (std.mem.eql(u8, sym_name, "__pyoz_stubs_len__")) {
            stubs_len_sym = sym;
        }

        if (stubs_data_sym != null and stubs_len_sym != null) break;
    }

    if (stubs_data_sym == null or stubs_len_sym == null) return null;

    const data_sym = stubs_data_sym.?;
    const len_sym = stubs_len_sym.?;

    // Get section headers for the symbols
    if (data_sym.st_shndx == 0 or data_sym.st_shndx >= ehdr.e_shnum) return null;
    if (len_sym.st_shndx == 0 or len_sym.st_shndx >= ehdr.e_shnum) return null;

    // Read all section headers for vaddr-to-file-offset conversion
    const section_headers = allocator.alloc(elf.Elf64_Shdr, ehdr.e_shnum) catch return null;
    defer allocator.free(section_headers);

    for (0..ehdr.e_shnum) |idx| {
        const shdr_off = ehdr.e_shoff + @as(u64, @intCast(idx)) * @as(u64, ehdr.e_shentsize);
        file.seekTo(shdr_off) catch return null;
        _ = file.read(std.mem.asBytes(&section_headers[idx])) catch return null;
    }

    const data_shdr = section_headers[data_sym.st_shndx];
    const len_shdr = section_headers[len_sym.st_shndx];

    // Calculate file offsets for the symbol locations
    const data_ptr_file_offset = data_shdr.sh_offset + (data_sym.st_value - data_shdr.sh_addr);
    const len_file_offset = len_shdr.sh_offset + (len_sym.st_value - len_shdr.sh_addr);

    // Read the length value (direct usize)
    file.seekTo(len_file_offset) catch return null;
    var stubs_len: u64 = undefined;
    _ = file.read(std.mem.asBytes(&stubs_len)) catch return null;

    if (stubs_len == 0 or stubs_len > 1024 * 1024) return null;

    // Read the pointer value (the data symbol contains a pointer to the actual string data)
    file.seekTo(data_ptr_file_offset) catch return null;
    var stubs_ptr_vaddr: u64 = undefined;
    _ = file.read(std.mem.asBytes(&stubs_ptr_vaddr)) catch return null;

    // Convert the virtual address to file offset
    const stubs_file_offset = elfVaddrToFileOffset(stubs_ptr_vaddr, section_headers) orelse return null;

    // Read the actual stubs data
    const stubs = allocator.alloc(u8, stubs_len) catch return null;
    errdefer allocator.free(stubs);

    file.seekTo(stubs_file_offset) catch {
        allocator.free(stubs);
        return null;
    };
    const read_count = file.read(stubs) catch {
        allocator.free(stubs);
        return null;
    };
    if (read_count != stubs_len) {
        allocator.free(stubs);
        return null;
    }

    return stubs;
}

/// Convert ELF virtual address to file offset
fn elfVaddrToFileOffset(vaddr: u64, sections: []const std.elf.Elf64_Shdr) ?u64 {
    for (sections) |shdr| {
        if (shdr.sh_type == std.elf.SHT_NULL) continue;
        if (vaddr >= shdr.sh_addr and vaddr < shdr.sh_addr + shdr.sh_size) {
            return shdr.sh_offset + (vaddr - shdr.sh_addr);
        }
    }
    return null;
}

// =============================================================================
// PE Parser (Windows)
// =============================================================================

const IMAGE_FILE_MACHINE_AMD64 = 0x8664;
const IMAGE_FILE_MACHINE_I386 = 0x14c;
const IMAGE_FILE_MACHINE_ARM64 = 0xAA64;

const PeSection = struct {
    name: [8]u8,
    virtual_size: u32,
    virtual_address: u32,
    raw_size: u32,
    raw_offset: u32,
};

fn extractFromPe(allocator: std.mem.Allocator, file: *Blob) !?[]const u8 {
    // Read DOS header
    var dos_header: [64]u8 = undefined;
    _ = file.read(&dos_header) catch return null;

    // PE offset is at 0x3C
    const pe_offset = std.mem.readInt(u32, dos_header[0x3C..0x40], .little);
    file.seekTo(pe_offset) catch return null;

    // Verify PE signature
    var pe_sig: [4]u8 = undefined;
    _ = file.read(&pe_sig) catch return null;
    if (!std.mem.eql(u8, &pe_sig, "PE\x00\x00")) return null;

    // Read COFF header (20 bytes)
    var coff_header: [20]u8 = undefined;
    _ = file.read(&coff_header) catch return null;

    const machine = std.mem.readInt(u16, coff_header[0..2], .little);
    const num_sections = std.mem.readInt(u16, coff_header[2..4], .little);
    const symtab_offset = std.mem.readInt(u32, coff_header[8..12], .little);
    const num_symbols = std.mem.readInt(u32, coff_header[12..16], .little);
    const optional_header_size = std.mem.readInt(u16, coff_header[16..18], .little);

    // Determine if 64-bit
    const is_64bit = (machine == IMAGE_FILE_MACHINE_AMD64 or machine == IMAGE_FILE_MACHINE_ARM64);

    // Read optional header to get image base and export directory
    var image_base: u64 = 0;
    var export_dir_rva: u32 = 0;
    var export_dir_size: u32 = 0;

    if (optional_header_size > 0) {
        const opt_header_offset = pe_offset + 24;
        file.seekTo(opt_header_offset) catch return null;

        if (is_64bit) {
            // PE32+ optional header
            var opt_header: [112]u8 = undefined;
            _ = file.read(&opt_header) catch return null;
            image_base = std.mem.readInt(u64, opt_header[24..32], .little);

            // Export directory is first data directory (at offset 112 in optional header)
            if (optional_header_size >= 120) {
                file.seekTo(opt_header_offset + 112) catch return null;
                var export_entry: [8]u8 = undefined;
                _ = file.read(&export_entry) catch return null;
                export_dir_rva = std.mem.readInt(u32, export_entry[0..4], .little);
                export_dir_size = std.mem.readInt(u32, export_entry[4..8], .little);
            }
        } else {
            // PE32 optional header
            var opt_header: [96]u8 = undefined;
            _ = file.read(&opt_header) catch return null;
            image_base = std.mem.readInt(u32, opt_header[28..32], .little);

            // Export directory
            if (optional_header_size >= 104) {
                file.seekTo(opt_header_offset + 96) catch return null;
                var export_entry: [8]u8 = undefined;
                _ = file.read(&export_entry) catch return null;
                export_dir_rva = std.mem.readInt(u32, export_entry[0..4], .little);
                export_dir_size = std.mem.readInt(u32, export_entry[4..8], .little);
            }
        }
    }

    // Read section headers
    const sections_offset = pe_offset + 24 + optional_header_size;
    file.seekTo(sections_offset) catch return null;

    var sections = allocator.alloc(PeSection, num_sections) catch return null;
    defer allocator.free(sections);

    for (0..num_sections) |i| {
        var section_header: [40]u8 = undefined;
        _ = file.read(&section_header) catch return null;

        sections[i] = .{
            .name = section_header[0..8].*,
            .virtual_size = std.mem.readInt(u32, section_header[8..12], .little),
            .virtual_address = std.mem.readInt(u32, section_header[12..16], .little),
            .raw_size = std.mem.readInt(u32, section_header[16..20], .little),
            .raw_offset = std.mem.readInt(u32, section_header[20..24], .little),
        };

        // Check for .pyozstub section (PE names are 8 chars, so ".pyozstu" or starts with ".pyozst")
        const sec_name = std.mem.sliceTo(&sections[i].name, 0);
        if (std.mem.eql(u8, sec_name, ".pyozstu") or std.mem.startsWith(u8, sec_name, ".pyozst")) {
            // Found the section, try to extract stubs
            if (try extractFromSection(allocator, file, sections[i].raw_offset, sections[i].raw_size)) |result| {
                return result;
            }
        }
    }

    // Try to find symbols via export directory
    if (export_dir_rva != 0 and export_dir_size != 0) {
        if (try findPeExportedSymbols(allocator, file, sections, export_dir_rva, is_64bit, image_base)) |result| {
            return result;
        }
    }

    // Fall back to COFF symbol table (if present, usually in debug builds)
    if (symtab_offset != 0 and num_symbols != 0) {
        if (try findPeCoffSymbols(allocator, file, symtab_offset, num_symbols, sections, is_64bit)) |result| {
            return result;
        }
    }

    return null;
}

fn rvaToFileOffset(rva: u32, sections: []const PeSection) ?u32 {
    for (sections) |sec| {
        if (rva >= sec.virtual_address and rva < sec.virtual_address + sec.virtual_size) {
            return sec.raw_offset + (rva - sec.virtual_address);
        }
    }
    return null;
}

fn findPeExportedSymbols(
    allocator: std.mem.Allocator,
    file: *Blob,
    sections: []const PeSection,
    export_dir_rva: u32,
    is_64bit: bool,
    image_base: u64,
) !?[]const u8 {
    const export_offset = rvaToFileOffset(export_dir_rva, sections) orelse return null;
    file.seekTo(export_offset) catch return null;

    // Export directory table (40 bytes)
    var export_dir: [40]u8 = undefined;
    _ = file.read(&export_dir) catch return null;

    const num_names = std.mem.readInt(u32, export_dir[24..28], .little);
    const addr_table_rva = std.mem.readInt(u32, export_dir[28..32], .little);
    const name_ptr_rva = std.mem.readInt(u32, export_dir[32..36], .little);
    const ordinal_table_rva = std.mem.readInt(u32, export_dir[36..40], .little);

    const name_ptr_offset = rvaToFileOffset(name_ptr_rva, sections) orelse return null;
    const ordinal_offset = rvaToFileOffset(ordinal_table_rva, sections) orelse return null;
    const addr_offset = rvaToFileOffset(addr_table_rva, sections) orelse return null;

    var data_sym_rva: ?u32 = null;
    var len_sym_rva: ?u32 = null;

    // Iterate through exported names
    var i: u32 = 0;
    while (i < num_names) : (i += 1) {
        // Read name RVA
        file.seekTo(name_ptr_offset + i * 4) catch continue;
        var name_rva_bytes: [4]u8 = undefined;
        _ = file.read(&name_rva_bytes) catch continue;
        const name_rva = std.mem.readInt(u32, &name_rva_bytes, .little);

        const name_offset = rvaToFileOffset(name_rva, sections) orelse continue;
        file.seekTo(name_offset) catch continue;

        // Read symbol name (null-terminated)
        var name_buf: [64]u8 = undefined;
        const name_len = file.read(&name_buf) catch continue;
        const sym_name = std.mem.sliceTo(name_buf[0..name_len], 0);

        // Check if it's one of our symbols
        const is_data = std.mem.eql(u8, sym_name, "__pyoz_stubs_data__");
        const is_len = std.mem.eql(u8, sym_name, "__pyoz_stubs_len__");

        if (is_data or is_len) {
            // Get ordinal
            file.seekTo(ordinal_offset + i * 2) catch continue;
            var ordinal_bytes: [2]u8 = undefined;
            _ = file.read(&ordinal_bytes) catch continue;
            const ordinal = std.mem.readInt(u16, &ordinal_bytes, .little);

            // Get address from export address table
            file.seekTo(addr_offset + @as(u32, ordinal) * 4) catch continue;
            var addr_bytes: [4]u8 = undefined;
            _ = file.read(&addr_bytes) catch continue;
            const sym_rva = std.mem.readInt(u32, &addr_bytes, .little);

            if (is_data) {
                data_sym_rva = sym_rva;
            } else {
                len_sym_rva = sym_rva;
            }
        }

        if (data_sym_rva != null and len_sym_rva != null) break;
    }

    if (data_sym_rva == null or len_sym_rva == null) return null;

    // Read the length value (the symbol points to a usize containing the length)
    const len_offset = rvaToFileOffset(len_sym_rva.?, sections) orelse return null;
    file.seekTo(len_offset) catch return null;

    var stubs_len: u64 = undefined;
    if (is_64bit) {
        _ = file.read(std.mem.asBytes(&stubs_len)) catch return null;
    } else {
        var len32: u32 = undefined;
        _ = file.read(std.mem.asBytes(&len32)) catch return null;
        stubs_len = len32;
    }

    if (stubs_len == 0 or stubs_len > 1024 * 1024) return null;

    // Read the pointer value (the data symbol contains a pointer to the actual string data)
    const data_ptr_offset = rvaToFileOffset(data_sym_rva.?, sections) orelse return null;
    file.seekTo(data_ptr_offset) catch return null;

    var stubs_ptr_rva: u64 = undefined;
    if (is_64bit) {
        _ = file.read(std.mem.asBytes(&stubs_ptr_rva)) catch return null;
    } else {
        var ptr32: u32 = undefined;
        _ = file.read(std.mem.asBytes(&ptr32)) catch return null;
        stubs_ptr_rva = ptr32;
    }

    // The pointer is a virtual address (image_base + RVA), so subtract image_base to get RVA
    // Actually for PE, the pointer value might be an absolute VA or an RVA depending on relocation
    // Let's try treating it as RVA first (relative to image base)
    const actual_rva: u32 = @truncate(stubs_ptr_rva -| image_base);
    const data_offset = rvaToFileOffset(actual_rva, sections) orelse {
        // If that didn't work, try treating it as already being an RVA
        const direct_offset = rvaToFileOffset(@truncate(stubs_ptr_rva), sections) orelse return null;
        file.seekTo(direct_offset) catch return null;

        const stubs = allocator.alloc(u8, stubs_len) catch return null;
        errdefer allocator.free(stubs);

        const read_count = file.read(stubs) catch {
            allocator.free(stubs);
            return null;
        };
        if (read_count != stubs_len) {
            allocator.free(stubs);
            return null;
        }
        return stubs;
    };

    file.seekTo(data_offset) catch return null;

    const stubs = allocator.alloc(u8, stubs_len) catch return null;
    errdefer allocator.free(stubs);

    const read_count = file.read(stubs) catch {
        allocator.free(stubs);
        return null;
    };
    if (read_count != stubs_len) {
        allocator.free(stubs);
        return null;
    }

    return stubs;
}

fn findPeCoffSymbols(
    allocator: std.mem.Allocator,
    file: *Blob,
    symtab_offset: u32,
    num_symbols: u32,
    sections: []const PeSection,
    is_64bit: bool,
) !?[]const u8 {
    // COFF symbol table entries are 18 bytes each
    // String table immediately follows symbol table

    const strtab_offset = symtab_offset + num_symbols * 18;

    // Read string table size (first 4 bytes of string table)
    file.seekTo(strtab_offset) catch return null;
    var strtab_size_bytes: [4]u8 = undefined;
    _ = file.read(&strtab_size_bytes) catch return null;
    const strtab_size = std.mem.readInt(u32, &strtab_size_bytes, .little);

    // Read string table
    const strtab = allocator.alloc(u8, strtab_size) catch return null;
    defer allocator.free(strtab);
    file.seekTo(strtab_offset) catch return null;
    _ = file.read(strtab) catch return null;

    var data_sym_value: ?u32 = null;
    var data_sym_section: ?u16 = null;
    var len_sym_value: ?u32 = null;
    var len_sym_section: ?u16 = null;

    var i: u32 = 0;
    while (i < num_symbols) : (i += 1) {
        file.seekTo(symtab_offset + i * 18) catch continue;

        var sym_entry: [18]u8 = undefined;
        _ = file.read(&sym_entry) catch continue;

        // Get symbol name
        var sym_name: []const u8 = undefined;
        if (sym_entry[0] == 0 and sym_entry[1] == 0 and sym_entry[2] == 0 and sym_entry[3] == 0) {
            // Name is in string table
            const str_offset = std.mem.readInt(u32, sym_entry[4..8], .little);
            if (str_offset < strtab.len) {
                sym_name = std.mem.sliceTo(strtab[str_offset..], 0);
            } else {
                continue;
            }
        } else {
            // Short name (up to 8 chars, null-padded)
            sym_name = std.mem.sliceTo(sym_entry[0..8], 0);
        }

        const value = std.mem.readInt(u32, sym_entry[8..12], .little);
        const section_num = std.mem.readInt(u16, sym_entry[12..14], .little);
        const aux_count = sym_entry[17];

        if (std.mem.eql(u8, sym_name, "__pyoz_stubs_data__")) {
            data_sym_value = value;
            data_sym_section = section_num;
        } else if (std.mem.eql(u8, sym_name, "__pyoz_stubs_len__")) {
            len_sym_value = value;
            len_sym_section = section_num;
        }

        // Skip auxiliary symbol entries
        i += aux_count;

        if (data_sym_value != null and len_sym_value != null) break;
    }

    if (data_sym_value == null or len_sym_value == null) return null;
    if (data_sym_section == null or len_sym_section == null) return null;

    // Section numbers are 1-based
    if (data_sym_section.? == 0 or data_sym_section.? > sections.len) return null;
    if (len_sym_section.? == 0 or len_sym_section.? > sections.len) return null;

    const data_section = sections[data_sym_section.? - 1];
    const len_section = sections[len_sym_section.? - 1];

    // Calculate file offsets
    const data_file_offset = data_section.raw_offset + data_sym_value.?;
    const len_file_offset = len_section.raw_offset + len_sym_value.?;

    // Read length
    file.seekTo(len_file_offset) catch return null;
    var stubs_len: u64 = undefined;
    if (is_64bit) {
        _ = file.read(std.mem.asBytes(&stubs_len)) catch return null;
    } else {
        var len32: u32 = undefined;
        _ = file.read(std.mem.asBytes(&len32)) catch return null;
        stubs_len = len32;
    }

    if (stubs_len == 0 or stubs_len > 1024 * 1024) return null;

    // Read data
    const stubs = allocator.alloc(u8, stubs_len) catch return null;
    errdefer allocator.free(stubs);

    file.seekTo(data_file_offset) catch {
        allocator.free(stubs);
        return null;
    };
    const read_count = file.read(stubs) catch {
        allocator.free(stubs);
        return null;
    };
    if (read_count != stubs_len) {
        allocator.free(stubs);
        return null;
    }

    return stubs;
}

// =============================================================================
// Mach-O Parser (macOS)
// =============================================================================

const MH_MAGIC_64 = 0xFEEDFACF;
const LC_SYMTAB = 0x2;
const LC_SEGMENT_64 = 0x19;

const MachOSegment = struct {
    vmaddr: u64,
    fileoff: u64,
    vmsize: u64,
};

fn extractFromMachO64(allocator: std.mem.Allocator, file: *Blob) !?[]const u8 {
    // Mach-O 64-bit header (little-endian)
    var header: [32]u8 = undefined;
    _ = file.read(&header) catch return null;

    const ncmds = std.mem.readInt(u32, header[16..20], .little);

    // Find LC_SYMTAB, segments, and __pyozstub section
    var symtab_offset: u32 = 0;
    var symtab_nsyms: u32 = 0;
    var strtab_offset: u32 = 0;
    var strtab_size: u32 = 0;

    // Store segment info for address-to-offset conversion
    var segments: [32]MachOSegment = undefined;
    var num_segments: usize = 0;

    // Look for __pyozstub section
    var pyozstub_offset: ?u64 = null;
    var pyozstub_size: ?u64 = null;

    var cmd_offset: u64 = 32; // After header
    var i: u32 = 0;
    while (i < ncmds) : (i += 1) {
        file.seekTo(cmd_offset) catch break;

        var cmd_header: [8]u8 = undefined;
        _ = file.read(&cmd_header) catch break;

        const cmd = std.mem.readInt(u32, cmd_header[0..4], .little);
        const cmdsize = std.mem.readInt(u32, cmd_header[4..8], .little);

        if (cmd == LC_SYMTAB) {
            var symtab_cmd: [24]u8 = undefined;
            file.seekTo(cmd_offset) catch break;
            _ = file.read(&symtab_cmd) catch break;

            symtab_offset = std.mem.readInt(u32, symtab_cmd[8..12], .little);
            symtab_nsyms = std.mem.readInt(u32, symtab_cmd[12..16], .little);
            strtab_offset = std.mem.readInt(u32, symtab_cmd[16..20], .little);
            strtab_size = std.mem.readInt(u32, symtab_cmd[20..24], .little);
        } else if (cmd == LC_SEGMENT_64 and num_segments < 32) {
            // Read full segment command header (72 bytes)
            var seg_cmd: [72]u8 = undefined;
            file.seekTo(cmd_offset) catch break;
            _ = file.read(&seg_cmd) catch break;

            segments[num_segments] = .{
                .vmaddr = std.mem.readInt(u64, seg_cmd[24..32], .little),
                .fileoff = std.mem.readInt(u64, seg_cmd[40..48], .little),
                .vmsize = std.mem.readInt(u64, seg_cmd[32..40], .little),
            };
            num_segments += 1;

            // Check sections within this segment for __pyozstub
            const nsects = std.mem.readInt(u32, seg_cmd[64..68], .little);
            var sect_offset: u64 = cmd_offset + 72; // Sections follow segment header

            var s: u32 = 0;
            while (s < nsects) : (s += 1) {
                file.seekTo(sect_offset) catch break;
                // section_64 is 80 bytes: sectname[16], segname[16], addr, size, offset, ...
                var sect_hdr: [80]u8 = undefined;
                _ = file.read(&sect_hdr) catch break;

                const sect_name = std.mem.sliceTo(sect_hdr[0..16], 0);
                if (std.mem.eql(u8, sect_name, "__pyozstub") or std.mem.startsWith(u8, sect_name, ".pyozstub")) {
                    pyozstub_offset = std.mem.readInt(u32, sect_hdr[48..52], .little);
                    pyozstub_size = std.mem.readInt(u64, sect_hdr[40..48], .little);
                }
                sect_offset += 80;
            }
        }

        cmd_offset += cmdsize;
    }

    // Try .pyozstub section first (survives stripping)
    if (pyozstub_offset != null and pyozstub_size != null) {
        if (try extractFromSection(allocator, file, pyozstub_offset.?, pyozstub_size.?)) |result| {
            return result;
        }
    }

    // Fall back to symbol-based extraction
    if (symtab_offset == 0 or strtab_offset == 0) return null;

    // Read string table
    const strtab = allocator.alloc(u8, strtab_size) catch return null;
    defer allocator.free(strtab);
    file.seekTo(strtab_offset) catch return null;
    _ = file.read(strtab) catch return null;

    // Search symbols (nlist_64 is 16 bytes)
    var data_sym_value: ?u64 = null;
    var len_sym_value: ?u64 = null;

    var j: u32 = 0;
    while (j < symtab_nsyms) : (j += 1) {
        file.seekTo(symtab_offset + @as(u64, j) * 16) catch continue;

        var nlist: [16]u8 = undefined;
        _ = file.read(&nlist) catch continue;

        const strx = std.mem.readInt(u32, nlist[0..4], .little);
        const n_value = std.mem.readInt(u64, nlist[8..16], .little);

        if (strx >= strtab.len) continue;
        const sym_name = std.mem.sliceTo(strtab[strx..], 0);

        // Mach-O symbols often have underscore prefix
        const name_to_check = if (sym_name.len > 0 and sym_name[0] == '_') sym_name[1..] else sym_name;

        // Try both the exported name and internal pointer name
        // Only accept if n_value is non-zero (skip indirect/external symbols)
        if (std.mem.eql(u8, name_to_check, "__pyoz_stubs_data__") or
            std.mem.eql(u8, name_to_check, "_pyoz_stubs_ptr__"))
        {
            if (n_value != 0) data_sym_value = n_value;
        } else if (std.mem.eql(u8, name_to_check, "__pyoz_stubs_len__") or
            std.mem.eql(u8, name_to_check, "_pyoz_stubs_len__"))
        {
            if (n_value != 0) len_sym_value = n_value;
        }

        if (data_sym_value != null and len_sym_value != null) break;
    }

    if (data_sym_value == null or len_sym_value == null) return null;

    // Convert virtual addresses to file offsets
    const data_ptr_offset = vmaddrToFileOffset(data_sym_value.?, segments[0..num_segments]) orelse return null;
    const len_offset = vmaddrToFileOffset(len_sym_value.?, segments[0..num_segments]) orelse return null;

    // Read length
    file.seekTo(len_offset) catch return null;
    var stubs_len: u64 = undefined;
    _ = file.read(std.mem.asBytes(&stubs_len)) catch return null;

    if (stubs_len == 0 or stubs_len > 1024 * 1024) return null;

    // Read the pointer value (the data symbol contains a pointer to the actual string data)
    file.seekTo(data_ptr_offset) catch return null;
    var stubs_ptr_vmaddr: u64 = undefined;
    _ = file.read(std.mem.asBytes(&stubs_ptr_vmaddr)) catch return null;

    // Convert pointer (virtual address) to file offset
    const data_offset = vmaddrToFileOffset(stubs_ptr_vmaddr, segments[0..num_segments]) orelse return null;

    // Read data
    const stubs = allocator.alloc(u8, stubs_len) catch return null;
    errdefer allocator.free(stubs);

    file.seekTo(data_offset) catch {
        allocator.free(stubs);
        return null;
    };
    _ = file.read(stubs) catch {
        allocator.free(stubs);
        return null;
    };

    return stubs;
}

fn extractFromMachO64BE(allocator: std.mem.Allocator, file: *Blob) !?[]const u8 {
    // Big-endian Mach-O - rare, skip for now
    _ = allocator;
    _ = file;
    return null;
}

fn vmaddrToFileOffset(vmaddr: u64, segments: []const MachOSegment) ?u64 {
    for (segments) |seg| {
        if (vmaddr >= seg.vmaddr and vmaddr < seg.vmaddr + seg.vmsize) {
            return seg.fileoff + (vmaddr - seg.vmaddr);
        }
    }
    return null;
}
