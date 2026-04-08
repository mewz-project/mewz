const log = @import("log.zig");
const options = @import("options");
const std = @import("std");

const FILES_MAX: usize = 200;

extern var _binary_build_disk_tar_start: [*]u8;

pub var files: [FILES_MAX]RegularFile = undefined;
pub var num_dirs: usize = 0;
pub var dirs: [FILES_MAX]Directory = undefined;

const TarHeader = extern struct {
    name: [100]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [12]u8,
    mtime: [12]u8,
    checksum: [8]u8,
    typeflag: u8,
    linkname: [100]u8,
    magic: [6]u8,
    version: [2]u8,
    uname: [32]u8,
    gname: [32]u8,
    devmajor: [8]u8,
    devminor: [8]u8,
    prefix: [155]u8,
    padding: [12]u8,
    // Flexible array member pointing to the data following the header
};

pub const RegularFile = struct {
    name: []u8,
    data: []u8,
};

pub const OpenedFile = struct {
    inner: *RegularFile,
    pos: usize = 0,

    const Self = @This();

    pub fn read(self: *Self, buffer: []u8) usize {
        const nread = @min(buffer.len, self.inner.data.len - self.pos);
        @memcpy(buffer[0..nread], self.inner.data[self.pos..][0..nread]);
        self.pos = self.pos + nread;
        return nread;
    }
};

pub const Directory = struct {
    name: []u8,

    const Self = @This();
    const Error = error{Failed};

    // Get file by relative path from this directory
    pub fn getFileByName(self: *Self, file_name: []const u8) ?*RegularFile {
        for (&files) |*file| {
            if (file.name.len != self.name.len + file_name.len) {
                continue;
            }

            if (std.mem.eql(u8, file.name[0..self.name.len], self.name) and
                std.mem.eql(u8, file.name[self.name.len..], file_name))
            {
                return file;
            }
        }

        return null;
    }
};

fn oct2int(oct: []const u8, len: usize) u32 {
    var dec: u32 = 0;
    var i: usize = 0;

    while (i < len) : (i += 1) {
        if (oct[i] < '0' or oct[i] > '7') {
            break;
        }

        dec = dec * 8 + (oct[i] - '0');
    }
    return dec;
}

pub fn init() void {
    // check if fs is enabled
    if (!options.has_fs) {
        log.debug.print("file system is not attached\n");
        return;
    }

    log.debug.printf("FILES_MAX: {d}\n", .{FILES_MAX});
    const disk_ptr_addr = &_binary_build_disk_tar_start;
    const disk_pointer = @as([*]u8, @ptrCast(@constCast(disk_ptr_addr)));

    var off: usize = 0;
    var i: usize = 0;
    var i_regular: usize = 0;
    var i_dir: usize = 0;
    while (i < FILES_MAX) : (i += 1) {
        const header: *TarHeader = @as(*TarHeader, @ptrFromInt(@as(usize, @intFromPtr(disk_pointer)) + off));

        // file exists ?
        if (header.name[0] == 0) {
            break;
        }

        // check magic
        const ustar_magic = [6]u8{ 'u', 's', 't', 'a', 'r', 0 };
        var j: usize = 0;
        while (j < ustar_magic.len) : (j += 1) {
            if (ustar_magic[j] != header.magic[j]) {
                @panic("invalid tar magic\n");
            }
        }

        // get name len
        var name_len: usize = 0;
        while (name_len < header.name.len) : (name_len += 1) {
            if (header.name[name_len] == 0) {
                break;
            }
        }

        // check if directory
        if (header.typeflag == '5') {
            // register directory
            dirs[i_dir] = Directory{
                .name = header.name[0..name_len],
            };

            // update cursor
            off += @sizeOf(TarHeader);

            log.debug.printf("directory: {s}\n", .{@as([*]u8, @ptrCast(&header.name[0]))[0..name_len]});

            i_dir += 1;
            continue;
        }

        // check if regular file
        if (header.typeflag != '0') {
            // update cursor
            off += @sizeOf(TarHeader);

            if (header.typeflag == '2') {
                log.debug.printf("symlink: {s}\n", .{@as([*]u8, @ptrCast(&header.name[0]))[0..name_len]});
            } else {
                log.debug.printf("unknown typeflag: {c}\n", .{header.typeflag});
            }
            continue;
        }

        // register regular file
        files[i_regular] = RegularFile{
            .name = undefined,
            .data = undefined,
        };

        // get name
        files[i_regular].name = header.name[0..name_len];

        // get data
        const size: u32 = oct2int(&header.size, header.size.len);
        const data_ptr: [*]u8 = @as([*]u8, @ptrFromInt(@as(usize, @intFromPtr(disk_pointer)) + off + @sizeOf(TarHeader)));
        files[i_regular].data = data_ptr[0..size];

        // update offset to next file
        off += @sizeOf(TarHeader) + ((size + 511) / 512) * 512;

        // debug
        log.debug.printf("regular file: {s}\n", .{files[i_regular].name});

        i_regular += 1;
    }

    num_dirs = i_dir;
}
