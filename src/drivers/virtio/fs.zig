const common = @import("common.zig");
const fuse = @import("../../fuse.zig");
const interrupt = @import("../../interrupt.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const pci = @import("../../pci.zig");

const REQUEST_BUF_SIZE = 4096;
const RESPONSE_BUF_SIZE = 65536;
const MAX_READ_RESPONSE_DATA = RESPONSE_BUF_SIZE - @sizeOf(fuse.OutHeader);

pub var virtio_fs: ?*VirtioFs = null;

const VirtioFsDeviceConfig = extern struct {
    tag: [36]u8,
    num_queues: u32,
};

const VirtioFs = struct {
    virtio: common.Virtio(VirtioFsDeviceConfig),
    tag: [36]u8,
    unique_counter: u64,
    request_buf: []u8,
    response_buf: []u8,

    const Self = @This();

    fn new(virtio: common.Virtio(VirtioFsDeviceConfig)) Self {
        const tag = @as(*[36]u8, @ptrCast(@volatileCast(&virtio.transport.device_config.tag))).*;

        var tag_len: usize = 0;
        for (tag) |c| {
            if (c == 0) break;
            tag_len += 1;
        }
        log.info.printf("virtio-fs: tag={s}\n", .{tag[0..tag_len]});

        const request_buf = mem.boottime_allocator.?.alloc(u8, REQUEST_BUF_SIZE) catch @panic("virtio-fs: request buf alloc failed");
        const response_buf = mem.boottime_allocator.?.alloc(u8, RESPONSE_BUF_SIZE) catch @panic("virtio-fs: response buf alloc failed");

        return Self{
            .virtio = virtio,
            .tag = tag,
            .unique_counter = 1,
            .request_buf = request_buf,
            .response_buf = response_buf,
        };
    }

    fn hiprioq(self: *Self) *common.Virtqueue {
        return &self.virtio.virtqueues[0];
    }

    fn requestq(self: *Self) *common.Virtqueue {
        return &self.virtio.virtqueues[1];
    }

    fn nextUnique(self: *Self) u64 {
        const val = self.unique_counter;
        self.unique_counter += 1;
        return val;
    }

    fn sendRequest(self: *Self, req_len: usize, resp_len: usize) ?[]u8 {
        @memset(self.response_buf[0..resp_len], 0);

        var chain = [2]common.VirtqDescBuffer{
            common.VirtqDescBuffer{
                .addr = @intFromPtr(self.request_buf.ptr),
                .len = @as(u32, @intCast(req_len)),
                .type = common.VirtqDescBufferType.ReadonlyFromDevice,
            },
            common.VirtqDescBuffer{
                .addr = @intFromPtr(self.response_buf.ptr),
                .len = @as(u32, @intCast(resp_len)),
                .type = common.VirtqDescBufferType.WritableFromDevice,
            },
        };

        const rq = self.requestq();
        rq.enqueue(chain[0..2]);
        self.virtio.transport.notifyQueue(rq);

        // Poll for completion by checking used ring directly
        var timeout: u32 = 0;
        while (rq.used.idx().* == rq.last_used_idx and timeout < 100_000_000) : (timeout += 1) {
            asm volatile ("pause");
        }

        if (rq.used.idx().* == rq.last_used_idx) {
            log.fatal.printf("virtio-fs: request timed out (avail={d} used={d} last_used={d})\n", .{ rq.avail.idx().*, rq.used.idx().*, rq.last_used_idx });
            return null;
        }

        _ = rq.popUsed(null) catch {
            log.fatal.print("virtio-fs: popUsed failed\n");
            return null;
        };

        const out_header = @as(*fuse.OutHeader, @ptrCast(@alignCast(self.response_buf.ptr)));
        const out_len = @as(usize, @intCast(out_header.len));
        if (out_len < @sizeOf(fuse.OutHeader) or out_len > resp_len or out_len > self.response_buf.len) {
            log.fatal.printf("virtio-fs: invalid response length: {d}\n", .{out_header.len});
            return null;
        }
        if (out_header.err != 0) {
            log.info.printf("virtio-fs: FUSE error: {d}\n", .{out_header.err});
            return null;
        }

        return self.response_buf[0..@as(usize, @intCast(out_header.len))];
    }

    pub fn fuseInit(self: *Self) bool {
        const req_len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.InitIn);
        const resp_len = @sizeOf(fuse.OutHeader) + @sizeOf(fuse.InitOut);

        fuse.fillInHeader(
            self.request_buf[0..@sizeOf(fuse.InHeader)],
            @as(u32, req_len),
            fuse.Opcode.FUSE_INIT,
            self.nextUnique(),
            fuse.FUSE_ROOT_ID,
        );

        const init_in = @as(*fuse.InitIn, @ptrCast(@alignCast(self.request_buf[@sizeOf(fuse.InHeader)..].ptr)));
        init_in.* = fuse.InitIn{
            .major = fuse.FUSE_KERNEL_VERSION,
            .minor = fuse.FUSE_KERNEL_MINOR_VERSION,
            .max_readahead = 65536,
            .flags = 0,
        };

        const response = self.sendRequest(req_len, resp_len) orelse return false;
        _ = response;

        log.info.print("virtio-fs: FUSE_INIT succeeded\n");
        return true;
    }

    pub fn fuseLookup(self: *Self, parent_nodeid: u64, name: []const u8) ?fuse.EntryOut {
        const req_len = @sizeOf(fuse.InHeader) + name.len + 1;
        const resp_len = @sizeOf(fuse.OutHeader) + @sizeOf(fuse.EntryOut);

        fuse.fillInHeader(
            self.request_buf[0..@sizeOf(fuse.InHeader)],
            @as(u32, @intCast(req_len)),
            fuse.Opcode.FUSE_LOOKUP,
            self.nextUnique(),
            parent_nodeid,
        );

        const name_buf = self.request_buf[@sizeOf(fuse.InHeader)..];
        @memcpy(name_buf[0..name.len], name);
        name_buf[name.len] = 0;

        const response = self.sendRequest(req_len, resp_len) orelse return null;
        if (response.len < @sizeOf(fuse.OutHeader) + @sizeOf(fuse.EntryOut)) return null;

        const entry = @as(*const fuse.EntryOut, @ptrCast(@alignCast(response[@sizeOf(fuse.OutHeader)..].ptr)));
        return entry.*;
    }

    pub fn fuseGetattr(self: *Self, nodeid: u64) ?fuse.AttrOut {
        const req_len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.GetattrIn);
        const resp_len = @sizeOf(fuse.OutHeader) + @sizeOf(fuse.AttrOut);

        fuse.fillInHeader(
            self.request_buf[0..@sizeOf(fuse.InHeader)],
            @as(u32, req_len),
            fuse.Opcode.FUSE_GETATTR,
            self.nextUnique(),
            nodeid,
        );

        const getattr_in = @as(*fuse.GetattrIn, @ptrCast(@alignCast(self.request_buf[@sizeOf(fuse.InHeader)..].ptr)));
        getattr_in.* = fuse.GetattrIn{
            .getattr_flags = 0,
            .dummy = 0,
            .fh = 0,
        };

        const response = self.sendRequest(req_len, resp_len) orelse return null;
        if (response.len < @sizeOf(fuse.OutHeader) + @sizeOf(fuse.AttrOut)) return null;

        const attr_out = @as(*const fuse.AttrOut, @ptrCast(@alignCast(response[@sizeOf(fuse.OutHeader)..].ptr)));
        return attr_out.*;
    }

    pub fn fuseOpen(self: *Self, nodeid: u64, is_dir: bool, open_flags: u32) ?fuse.OpenOut {
        const req_len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.OpenIn);
        const resp_len = @sizeOf(fuse.OutHeader) + @sizeOf(fuse.OpenOut);

        const opcode = if (is_dir) fuse.Opcode.FUSE_OPENDIR else fuse.Opcode.FUSE_OPEN;

        fuse.fillInHeader(
            self.request_buf[0..@sizeOf(fuse.InHeader)],
            @as(u32, req_len),
            opcode,
            self.nextUnique(),
            nodeid,
        );

        const open_in = @as(*fuse.OpenIn, @ptrCast(@alignCast(self.request_buf[@sizeOf(fuse.InHeader)..].ptr)));
        open_in.* = fuse.OpenIn{
            .flags = if (is_dir) 0 else open_flags,
            .open_flags = 0,
        };

        const response = self.sendRequest(req_len, resp_len) orelse return null;
        if (response.len < @sizeOf(fuse.OutHeader) + @sizeOf(fuse.OpenOut)) return null;

        const open_out = @as(*const fuse.OpenOut, @ptrCast(@alignCast(response[@sizeOf(fuse.OutHeader)..].ptr)));
        return open_out.*;
    }

    pub fn fuseRead(self: *Self, nodeid: u64, fh: u64, offset: u64, out_buf: []u8) ?usize {
        const req_len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.ReadIn);
        const max_data = @min(out_buf.len, MAX_READ_RESPONSE_DATA);
        const resp_len = @sizeOf(fuse.OutHeader) + max_data;

        fuse.fillInHeader(
            self.request_buf[0..@sizeOf(fuse.InHeader)],
            @as(u32, req_len),
            fuse.Opcode.FUSE_READ,
            self.nextUnique(),
            nodeid,
        );

        const read_in = @as(*fuse.ReadIn, @ptrCast(@alignCast(self.request_buf[@sizeOf(fuse.InHeader)..].ptr)));
        read_in.* = fuse.ReadIn{
            .fh = fh,
            .offset = offset,
            .size = @as(u32, @intCast(max_data)),
            .read_flags = 0,
            .lock_owner = 0,
            .flags = 0,
            .padding = 0,
        };

        const response = self.sendRequest(req_len, resp_len) orelse return null;
        if (response.len < @sizeOf(fuse.OutHeader)) return null;

        const data_len = response.len - @sizeOf(fuse.OutHeader);
        if (data_len == 0) return 0;

        const copy_len = @min(data_len, out_buf.len);
        @memcpy(out_buf[0..copy_len], response[@sizeOf(fuse.OutHeader)..][0..copy_len]);
        return copy_len;
    }

    pub fn fuseWrite(self: *Self, nodeid: u64, fh: u64, offset: u64, data: []const u8) ?usize {
        if (data.len == 0) return 0;

        const req_base_len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.WriteIn);
        const max_data = REQUEST_BUF_SIZE - req_base_len;
        if (max_data == 0) return null;

        const write_size: usize = @min(data.len, max_data);
        const req_len = req_base_len + write_size;
        const resp_len = @sizeOf(fuse.OutHeader) + @sizeOf(fuse.WriteOut);

        fuse.fillInHeader(
            self.request_buf[0..@sizeOf(fuse.InHeader)],
            @as(u32, @intCast(req_len)),
            fuse.Opcode.FUSE_WRITE,
            self.nextUnique(),
            nodeid,
        );

        const write_in = @as(*fuse.WriteIn, @ptrCast(@alignCast(self.request_buf[@sizeOf(fuse.InHeader)..].ptr)));
        write_in.* = fuse.WriteIn{
            .fh = fh,
            .offset = offset,
            .size = @as(u32, @intCast(write_size)),
            .write_flags = 0,
            .lock_owner = 0,
            .flags = 0,
            .padding = 0,
        };

        const write_data_offset = @sizeOf(fuse.InHeader) + @sizeOf(fuse.WriteIn);
        @memcpy(self.request_buf[write_data_offset .. write_data_offset + write_size], data[0..write_size]);

        const response = self.sendRequest(req_len, resp_len) orelse return null;
        if (response.len < @sizeOf(fuse.OutHeader) + @sizeOf(fuse.WriteOut)) return null;

        const write_out = @as(*const fuse.WriteOut, @ptrCast(@alignCast(response[@sizeOf(fuse.OutHeader)..].ptr)));
        return @as(usize, @intCast(write_out.size));
    }

    pub fn fuseCreate(self: *Self, parent_nodeid: u64, name: []const u8, flags: u32, mode: u32) ?struct { entry: fuse.EntryOut, open: fuse.OpenOut } {
        const req_len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.CreateIn) + name.len + 1;
        const resp_len = @sizeOf(fuse.OutHeader) + @sizeOf(fuse.EntryOut) + @sizeOf(fuse.OpenOut);

        fuse.fillInHeader(
            self.request_buf[0..@sizeOf(fuse.InHeader)],
            @as(u32, @intCast(req_len)),
            fuse.Opcode.FUSE_CREATE,
            self.nextUnique(),
            parent_nodeid,
        );

        const create_in = @as(*fuse.CreateIn, @ptrCast(@alignCast(self.request_buf[@sizeOf(fuse.InHeader)..].ptr)));
        create_in.* = fuse.CreateIn{
            .flags = flags,
            .mode = mode,
            .umask = 0o022,
            .open_flags = 0,
        };

        const name_offset = @sizeOf(fuse.InHeader) + @sizeOf(fuse.CreateIn);
        @memcpy(self.request_buf[name_offset..][0..name.len], name);
        self.request_buf[name_offset + name.len] = 0;

        const response = self.sendRequest(req_len, resp_len) orelse return null;
        if (response.len < @sizeOf(fuse.OutHeader) + @sizeOf(fuse.EntryOut) + @sizeOf(fuse.OpenOut)) return null;

        const entry = @as(*const fuse.EntryOut, @ptrCast(@alignCast(response[@sizeOf(fuse.OutHeader)..].ptr)));
        const open_out = @as(*const fuse.OpenOut, @ptrCast(@alignCast(response[@sizeOf(fuse.OutHeader) + @sizeOf(fuse.EntryOut) ..].ptr)));
        return .{ .entry = entry.*, .open = open_out.* };
    }

    pub fn fuseRelease(self: *Self, nodeid: u64, fh: u64, is_dir: bool) void {
        const req_len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.ReleaseIn);
        const resp_len = @sizeOf(fuse.OutHeader);

        const opcode = if (is_dir) fuse.Opcode.FUSE_RELEASEDIR else fuse.Opcode.FUSE_RELEASE;

        fuse.fillInHeader(
            self.request_buf[0..@sizeOf(fuse.InHeader)],
            @as(u32, req_len),
            opcode,
            self.nextUnique(),
            nodeid,
        );

        const release_in = @as(*fuse.ReleaseIn, @ptrCast(@alignCast(self.request_buf[@sizeOf(fuse.InHeader)..].ptr)));
        release_in.* = fuse.ReleaseIn{
            .fh = fh,
            .flags = 0,
            .release_flags = 0,
            .lock_owner = 0,
        };

        _ = self.sendRequest(req_len, resp_len);
    }

    pub fn fuseReaddir(self: *Self, nodeid: u64, fh: u64, offset: u64, size: u32) ?[]u8 {
        const req_len = @sizeOf(fuse.InHeader) + @sizeOf(fuse.ReadIn);
        const max_data = @min(size, RESPONSE_BUF_SIZE - @sizeOf(fuse.OutHeader));
        const resp_len = @sizeOf(fuse.OutHeader) + max_data;

        fuse.fillInHeader(
            self.request_buf[0..@sizeOf(fuse.InHeader)],
            @as(u32, req_len),
            fuse.Opcode.FUSE_READDIR,
            self.nextUnique(),
            nodeid,
        );

        const read_in = @as(*fuse.ReadIn, @ptrCast(@alignCast(self.request_buf[@sizeOf(fuse.InHeader)..].ptr)));
        read_in.* = fuse.ReadIn{
            .fh = fh,
            .offset = offset,
            .size = max_data,
            .read_flags = 0,
            .lock_owner = 0,
            .flags = 0,
            .padding = 0,
        };

        const response = self.sendRequest(req_len, resp_len) orelse return null;
        if (response.len <= @sizeOf(fuse.OutHeader)) return null;

        const data_len = response.len - @sizeOf(fuse.OutHeader);
        return response[@sizeOf(fuse.OutHeader)..][0..data_len];
    }

    fn handleIrq(frame: *interrupt.InterruptFrame) void {
        _ = frame;
        const fs_dev = virtio_fs orelse return;
        _ = fs_dev.virtio.transport.getIsr() orelse return;
    }
};

pub fn init() bool {
    var pci_dev = find: {
        for (pci.devices) |d| {
            const dev = d orelse continue;
            if (dev.config.vendor_id == 0x1af4 and dev.config.device_id == 0x105a) {
                break :find dev;
            }
        }
        log.debug.print("virtio-fs: device not found\n");
        return false;
    };

    const virtio = common.Virtio(VirtioFsDeviceConfig)
        .new(&pci_dev, (1 << 32), 2, mem.boottime_allocator.?) catch {
        log.fatal.print("virtio-fs: virtio init failed\n");
        return false;
    };

    const fs_slice = mem.boottime_allocator.?.alloc(VirtioFs, 1) catch {
        log.fatal.print("virtio-fs: alloc failed\n");
        return false;
    };
    virtio_fs = @as(*VirtioFs, @ptrCast(fs_slice.ptr));
    virtio_fs.?.* = VirtioFs.new(virtio);

    interrupt.registerIrq(virtio_fs.?.virtio.transport.pci_dev.config.interrupt_line, VirtioFs.handleIrq);

    if (!virtio_fs.?.fuseInit()) {
        log.fatal.print("virtio-fs: FUSE_INIT failed\n");
        virtio_fs = null;
        return false;
    }

    log.info.print("virtio-fs: initialized\n");
    return true;
}
