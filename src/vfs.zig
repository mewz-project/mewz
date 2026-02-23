const fs = @import("fs.zig");
const fuse = @import("fuse.zig");
const log = @import("log.zig");
const virtio_fs_driver = @import("drivers/virtio/fs.zig");

const O_WRONLY: u32 = 0x0001;
const O_RDWR: u32 = 0x0002;
const O_CREAT: u32 = 0x0040;
const O_TRUNC: u32 = 0x0200;
const O_APPEND: u32 = 0x0400;

const WASI_FDFLAG_APPEND: u16 = 0x0001;

pub const OpenOptions = struct {
    read: bool = true,
    write: bool = false,
    append: bool = false,
    truncate: bool = false,
    create: bool = false,
};

pub const VfsFile = struct {
    backend: Backend,
    pos: u64 = 0,
    can_write: bool = false,
    fd_flags: u16 = 0,

    const Backend = union(enum) {
        mem_file: MemFileBackend,
        virtio_file: VirtioFileBackend,
    };

    const MemFileBackend = struct {
        inner: *fs.RegularFile,
    };

    const VirtioFileBackend = struct {
        nodeid: u64,
        fh: u64,
        file_size: u64,
    };

    const Self = @This();

    pub fn read(self: *Self, buffer: []u8) error{ FdFull, Failed, Again }!usize {
        switch (self.backend) {
            .mem_file => |*mf| {
                const data = mf.inner.data;
                const pos = @as(usize, @intCast(self.pos));
                if (pos >= data.len) return 0;
                const nread = @min(buffer.len, data.len - pos);
                @memcpy(buffer[0..nread], data[pos..][0..nread]);
                self.pos += @as(u64, @intCast(nread));
                return nread;
            },
            .virtio_file => |*vf| {
                const dev = virtio_fs_driver.virtio_fs orelse return 0;
                const nread = dev.fuseRead(vf.nodeid, vf.fh, self.pos, @as(u32, @intCast(@min(buffer.len, 65536 - 80))), buffer) orelse return 0;
                self.pos += @as(u64, @intCast(nread));
                return nread;
            },
        }
    }

    pub fn write(self: *Self, buffer: []const u8) error{ FdFull, Failed, Again, ReadOnly }!usize {
        if (buffer.len == 0) return 0;
        if (!self.can_write) return error.ReadOnly;

        const append_mode = (self.fd_flags & WASI_FDFLAG_APPEND) != 0;
        const start_offset = if (append_mode) switch (self.backend) {
            .mem_file => self.pos,
            .virtio_file => |*vf| vf.file_size,
        } else self.pos;

        const nwritten = try self.writeAt(buffer, start_offset, true);
        return nwritten;
    }

    pub fn pwrite(self: *Self, buffer: []const u8, offset: u64) error{ FdFull, Failed, Again, ReadOnly }!usize {
        if (buffer.len == 0) return 0;
        if (!self.can_write) return error.ReadOnly;
        return self.writeAt(buffer, offset, false);
    }

    fn writeAt(self: *Self, buffer: []const u8, offset: u64, update_pos: bool) error{Failed}!usize {
        switch (self.backend) {
            .mem_file => return error.Failed,
            .virtio_file => |*vf| {
                const dev = virtio_fs_driver.virtio_fs orelse return error.Failed;

                var total_written: usize = 0;
                var current_offset = offset;
                while (total_written < buffer.len) {
                    const nwritten = dev.fuseWrite(vf.nodeid, vf.fh, current_offset, buffer[total_written..]) orelse {
                        if (total_written > 0) break;
                        return error.Failed;
                    };
                    if (nwritten == 0) break;
                    total_written += nwritten;
                    current_offset += @as(u64, @intCast(nwritten));
                }

                if (total_written == 0) return error.Failed;

                if (current_offset > vf.file_size) {
                    vf.file_size = current_offset;
                }
                if (update_pos) {
                    self.pos = current_offset;
                }

                return total_written;
            },
        }
    }

    pub fn close(self: *Self) void {
        switch (self.backend) {
            .mem_file => {},
            .virtio_file => |*vf| {
                const dev = virtio_fs_driver.virtio_fs orelse return;
                dev.fuseRelease(vf.nodeid, vf.fh, false);
            },
        }
    }

    pub fn size(self: *const Self) u64 {
        return switch (self.backend) {
            .mem_file => |*mf| @as(u64, @intCast(mf.inner.data.len)),
            .virtio_file => |*vf| vf.file_size,
        };
    }

    pub fn bytesCanRead(self: *Self) usize {
        switch (self.backend) {
            .mem_file => |*mf| {
                const pos = @as(usize, @intCast(self.pos));
                if (pos >= mf.inner.data.len) return 0;
                return mf.inner.data.len - pos;
            },
            .virtio_file => |*vf| {
                const pos = self.pos;
                if (pos >= vf.file_size) return 0;
                return @as(usize, @intCast(vf.file_size - pos));
            },
        }
    }

    pub fn bytesCanWrite(self: *const Self) usize {
        return if (self.can_write) 1 else 0;
    }

    pub fn flags(self: *const Self) u16 {
        return self.fd_flags;
    }

    pub fn setFlags(self: *Self, value: u16) void {
        self.fd_flags = value;
    }

    pub fn seek(self: *Self, offset: i64, whence: i32) error{Failed}!u64 {
        const base: i128 = switch (whence) {
            0 => 0,
            1 => @as(i128, @intCast(self.pos)),
            2 => @as(i128, @intCast(self.size())),
            else => return error.Failed,
        };
        const new_pos = base + @as(i128, offset);
        if (new_pos < 0) return error.Failed;

        self.pos = @as(u64, @intCast(new_pos));
        return self.pos;
    }

    pub fn tell(self: *const Self) u64 {
        return self.pos;
    }
};

pub const VfsDir = struct {
    backend: Backend,
    name: []const u8,

    const Backend = union(enum) {
        mem_dir: MemDirBackend,
        virtio_dir: VirtioDirBackend,
    };

    const MemDirBackend = struct {
        dir: fs.Directory,
    };

    const VirtioDirBackend = struct {
        nodeid: u64,
    };

    const Self = @This();

    pub fn openFile(self: *Self, path: []const u8, options: OpenOptions) ?VfsFile {
        switch (self.backend) {
            .mem_dir => |*md| {
                var dir = md.dir;
                const regular_file = dir.getFileByName(path) orelse return null;
                return VfsFile{
                    .backend = .{ .mem_file = .{ .inner = regular_file } },
                    .pos = 0,
                    .can_write = false,
                    .fd_flags = 0,
                };
            },
            .virtio_dir => |*vd| {
                return openVirtioFile(vd.nodeid, path, options);
            },
        }
    }
};

fn openVirtioFile(parent_nodeid: u64, path: []const u8, options: OpenOptions) ?VfsFile {
    const dev = virtio_fs_driver.virtio_fs orelse return null;

    var current_nodeid = parent_nodeid;
    var remaining = path;

    if (remaining.len > 0 and remaining[0] == '/') {
        remaining = remaining[1..];
    }

    while (remaining.len > 0) {
        var sep_idx: usize = 0;
        while (sep_idx < remaining.len and remaining[sep_idx] != '/') : (sep_idx += 1) {}

        const component = remaining[0..sep_idx];
        if (component.len == 0) {
            remaining = if (sep_idx < remaining.len) remaining[sep_idx + 1 ..] else remaining[remaining.len..];
            continue;
        }

        const is_last = (sep_idx >= remaining.len) or (sep_idx == remaining.len - 1);

        const maybe_entry = dev.fuseLookup(current_nodeid, component);

        if (is_last) {
            if (maybe_entry) |entry| {
                const attr = entry.attr;
                if (!attr.isRegular()) return null;

                const open_flags = toLinuxOpenFlags(options);
                const open_out = dev.fuseOpen(entry.nodeid, false, open_flags) orelse return null;
                return VfsFile{
                    .backend = .{ .virtio_file = .{
                        .nodeid = entry.nodeid,
                        .fh = open_out.fh,
                        .file_size = attr.size,
                    } },
                    .pos = if (options.append) attr.size else 0,
                    .can_write = options.write,
                    .fd_flags = if (options.append) WASI_FDFLAG_APPEND else 0,
                };
            } else if (options.create) {
                const linux_flags = toLinuxOpenFlags(options) | O_CREAT | O_TRUNC;
                const result = dev.fuseCreate(current_nodeid, component, linux_flags, 0o644) orelse return null;
                return VfsFile{
                    .backend = .{ .virtio_file = .{
                        .nodeid = result.entry.nodeid,
                        .fh = result.open.fh,
                        .file_size = 0,
                    } },
                    .pos = 0,
                    .can_write = options.write,
                    .fd_flags = if (options.append) WASI_FDFLAG_APPEND else 0,
                };
            } else {
                return null;
            }
        }

        const entry = maybe_entry orelse return null;
        if (!entry.attr.isDir()) return null;
        current_nodeid = entry.nodeid;
        remaining = remaining[sep_idx + 1 ..];
    }

    return null;
}

fn toLinuxOpenFlags(options: OpenOptions) u32 {
    var flags: u32 = 0;

    if (options.write) {
        if (options.read) {
            flags |= O_RDWR;
        } else {
            flags |= O_WRONLY;
        }
    }

    if (options.append) {
        flags |= O_APPEND;
    }
    if (options.truncate) {
        flags |= O_TRUNC;
    }

    return flags;
}

var virtio_fs_available: bool = false;

pub fn isVirtioFsAvailable() bool {
    return virtio_fs_available;
}

pub fn init() void {
    virtio_fs_available = virtio_fs_driver.init();

    fs.init();

    log.debug.printf("vfs: initialized (virtio-fs={any})\n", .{virtio_fs_available});
}

pub fn makeRootDir() VfsDir {
    if (virtio_fs_available) {
        return VfsDir{
            .backend = .{ .virtio_dir = .{ .nodeid = fuse.FUSE_ROOT_ID } },
            .name = "/",
        };
    }

    if (fs.num_dirs > 0) {
        return VfsDir{
            .backend = .{ .mem_dir = .{ .dir = fs.dirs[0] } },
            .name = fs.dirs[0].name,
        };
    }

    return VfsDir{
        .backend = .{ .mem_dir = .{ .dir = fs.Directory{ .name = @constCast(&[_]u8{ '.', '/' }) } } },
        .name = "./",
    };
}
