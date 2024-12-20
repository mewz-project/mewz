const std = @import("std");
const ioapic = @import("../../ioapic.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const pci = @import("../../pci.zig");

const Allocator = std.mem.Allocator;

const VIRTIO_PCI_CAP_COMMON_CFG: u8 = 1;
const VIRTIO_PCI_CAP_NOTIFY_CFG: u8 = 2;
const VIRTIO_PCI_CAP_ISR_CFG: u8 = 3;
const VIRTIO_PCI_CAP_DEVICE_CFG: u8 = 4;

pub const VIRTQ_AVAIL_F_NO_INTERRUPT: u16 = 1;

const Error = std.mem.Allocator.Error;

pub const IsrStatus = enum(u32) {
    QUEUE = 0x1,
    CONFIG = 0x2,

    const Self = @This();

    pub fn isQueue(self: Self) bool {
        return @intFromEnum(self) & @intFromEnum(Self.QUEUE) != 0;
    }
};

pub fn Virtio(comptime DeviceConfigType: type) type {
    return struct {
        transport: VirtioMmioTransport(DeviceConfigType),
        virtqueues: []Virtqueue,

        const Self = @This();

        pub fn new(dev: *pci.Device, features: u64, queue_num: u32, allocator: Allocator) Error!Self {
            var transport = VirtioMmioTransport(DeviceConfigType).new(@constCast(dev));

            transport.common_config.device_status = DeviceStatus.RESET.toInt();
            transport.common_config.device_status |= DeviceStatus.ACKNOWLEDGE.toInt();
            transport.common_config.device_status |= DeviceStatus.DRIVER.toInt();

            const device_features = transport.read_device_feature();
            if ((device_features & features) != features) {
                @panic("virtio net does not support required features");
            }
            transport.write_driver_feature(features);

            transport.common_config.device_status |= DeviceStatus.FEATURES_OK.toInt();
            if ((transport.common_config.device_status & DeviceStatus.FEATURES_OK.toInt()) == 0) {
                @panic("virtio net failed to set FEATURES_OK");
            }

            const queue_size = transport.common_config.queue_size;
            const virtqueues = try allocator.alloc(Virtqueue, queue_num);
            for (0..queue_num) |i| {
                const queue_index = @as(u16, @intCast(i));
                transport.common_config.queue_select = queue_index;
                const virtqueue = try Virtqueue.new(queue_index, queue_size, allocator);
                transport.common_config.queue_desc = @as(u64, @intFromPtr(virtqueue.desc));
                transport.common_config.queue_driver = @as(u64, @intCast(virtqueue.avail.addr()));
                transport.common_config.queue_device = @as(u64, @intCast(virtqueue.used.addr()));
                transport.common_config.queue_enable = 1;
                virtqueues[i] = virtqueue;
            }

            ioapic.ioapicenable(dev.config.interrupt_line, 0);

            transport.common_config.device_status |= DeviceStatus.DRIVER_OK.toInt();

            return Self{
                .transport = transport,
                .virtqueues = virtqueues,
            };
        }
    };
}

pub const Virtqueue = struct {
    desc: [*]volatile VirtqDesc,
    avail: AvailRing,
    used: UsedRing,

    index: u16,
    num_descs: u16,
    num_free_descs: u16,
    not_notified_num_descs: u16 = 0,
    last_used_idx: u16,
    free_desc_head_idx: u16,

    const Self = @This();

    fn new(index: u16, queue_size: u16, allocator: Allocator) Error!Self {
        const desc_slice = try allocator.alignedAlloc(VirtqDesc, 16, queue_size * @sizeOf(VirtqDesc));
        @memset(desc_slice, VirtqDesc{ .addr = 0, .len = 0, .flags = 0, .next = 0 });
        const desc = @as([*]volatile VirtqDesc, @ptrCast(desc_slice));
        for (0..queue_size) |i| {
            desc[i].next = if (i == queue_size - 1) 0 else @as(u16, @intCast(i + 1));
        }

        const avail = try AvailRing.new(queue_size, allocator);
        const used = try UsedRing.new(queue_size, allocator);

        return Self{
            .desc = desc,
            .avail = avail,
            .used = used,
            .index = index,
            .num_descs = queue_size,
            .num_free_descs = queue_size,
            .last_used_idx = 0,
            .free_desc_head_idx = 0,
        };
    }

    pub fn enqueue(self: *Self, chain: []const VirtqDescBuffer) void {
        if (self.num_free_descs < chain.len) {
            while (true) {
                const used_chain = self.popUsed(null) catch @panic("failed to pop used desc");
                if (used_chain == null) {
                    break;
                }
            }
        }

        if (self.num_descs < chain.len) {
            @panic("not enough descs");
        }

        const head_idx = self.free_desc_head_idx;
        var desc_idx = head_idx;
        for (chain, 0..) |desc_buf, i| {
            var desc: *volatile VirtqDesc = &self.desc[desc_idx];
            switch (desc_buf.type) {
                VirtqDescBufferType.ReadonlyFromDevice => {
                    desc.*.addr = desc_buf.addr;
                    desc.*.len = desc_buf.len;
                    desc.*.flags = 0;
                },
                VirtqDescBufferType.WritableFromDevice => {
                    desc.*.addr = desc_buf.addr;
                    desc.*.len = desc_buf.len;
                    desc.*.flags = @intFromEnum(VirtqDescFlag.WRITE);
                },
            }

            if (i == chain.len - 1) {
                self.free_desc_head_idx = desc.next;
                desc.next = 0;
                desc.flags &= ~@intFromEnum(VirtqDescFlag.NEXT);
            } else {
                desc.flags |= @intFromEnum(VirtqDescFlag.NEXT);
                desc_idx = desc.next;
            }
        }

        self.num_free_descs -= @as(u16, @intCast(chain.len));
        self.not_notified_num_descs += @as(u16, @intCast(chain.len));

        const avail_idx = (self.avail.idx().* % self.num_descs);
        self.avail.ring()[avail_idx] = head_idx;
        self.avail.idx().* +%= 1;
    }

    // Return the descriptor chain specified by used ring,
    // but null if there is no used descriptor.
    // And prepend the descriptors to the free descriptor list.
    pub fn popUsed(self: *Self, allocator: ?Allocator) Error!?UsedRing.Chain {
        if (self.used.idx().* == self.last_used_idx) {
            return null;
        }
        defer self.last_used_idx +%= 1;

        const used_idx = (self.last_used_idx % self.num_descs);
        const used_elem = self.used.ring()[used_idx];

        var num_descs: u16 = 0;
        var desc_idx = used_elem.id;
        while (true) {
            const desc = &self.desc[desc_idx];
            num_descs += 1;
            if (!desc.hasNext()) {
                desc.*.next = self.free_desc_head_idx;
                self.num_free_descs += num_descs;
                self.free_desc_head_idx = @as(u16, @intCast(used_elem.id));
                break;
            }
            desc_idx = desc.next;
        }

        if (allocator == null) {
            return UsedRing.Chain{
                .desc_list = null,
                .total_len = used_elem.len,
            };
        }

        const desc_list = try allocator.?.alloc(VirtqDescBuffer, num_descs);

        // retrive buffer from descriptor chain
        desc_idx = @as(u16, @intCast(used_elem.id));
        for (desc_list) |*desc_buf| {
            const desc: *volatile VirtqDesc = &self.desc[desc_idx];
            desc_buf.*.addr = desc.*.addr;
            desc_buf.*.len = desc.*.len;
            desc_buf.*.type = if (desc.*.flags & @intFromEnum(VirtqDescFlag.WRITE) != 0)
                VirtqDescBufferType.WritableFromDevice
            else
                VirtqDescBufferType.ReadonlyFromDevice;

            if (!desc.hasNext()) {
                break;
            }

            desc_idx = desc.next;
        }

        return UsedRing.Chain{
            .desc_list = desc_list,
            .total_len = used_elem.len,
        };
    }

    pub fn popUsedOne(self: *Self) ?UsedRing.UsedRingEntry {
        if (self.used.idx().* == self.last_used_idx) {
            return null;
        }

        const used_idx = (self.last_used_idx % self.num_descs);
        const used_elem = self.used.ring()[used_idx];
        self.last_used_idx +%= 1;

        const desc_idx = used_elem.id;
        const desc: *volatile VirtqDesc = &self.desc[desc_idx];

        if (desc.hasNext()) {
            @panic("popUsedOne: descriptor is chained, which is not expected");
        }

        desc.*.next = self.free_desc_head_idx;
        self.num_free_descs += 1;
        self.free_desc_head_idx = @as(u16, @intCast(used_elem.id));

        return used_elem;
    }

    // retrieveFromUsedDesc retrieves the data from the used descriptor chain
    pub fn retrieveFromUsedDesc(self: *Self, chain: UsedRing.Chain, allocator: Allocator) Error![]u8 {
        _ = self;
        const total_len = chain.total_len;
        const total_buf = try allocator.alloc(u8, total_len);

        var offset: usize = 0;
        var remaining_len = total_len;
        for (chain.desc_list.?, 0..) |desc_buf, i| {
            const buf = @as([*]u8, @ptrFromInt(@as(usize, @intCast(desc_buf.addr))));

            // the last buffer's length may be less than desc_buf.len
            if (i == chain.desc_list.?.len - 1) {
                @memcpy(total_buf[offset..], buf[0..remaining_len]);
                break;
            }

            @memcpy(total_buf[offset..], buf[0..desc_buf.len]);
            offset += desc_buf.len;
            remaining_len -= desc_buf.len;
        }

        return total_buf;
    }
};

pub const VirtqDescFlag = enum(u16) {
    NEXT = 1,
    WRITE = 2,
    INDIRECT = 4,
};

pub const VirtqDesc = packed struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,

    const Self = @This();

    fn hasNext(self: *const volatile Self) bool {
        return (self.flags & @intFromEnum(VirtqDescFlag.NEXT)) != 0;
    }
};

pub const AvailRing = struct {
    // flags: u16,
    // idx: u16,
    // ring: [QUEUE_SIZE]u16,
    // used_event: u16,
    data: []u8,
    queue_size: u16,

    const Self = @This();

    fn new(queue_size: u16, allocator: Allocator) Error!Self {
        const size = @sizeOf(u16) * queue_size + @sizeOf(u16) * 3;
        const data = allocator.alignedAlloc(u8, 8, size) catch |err| {
            log.fatal.printf("failed to allocate avail ring: {}\n", .{err});
            return err;
        };
        @memset(data, 0);
        return Self{
            .data = data,
            .queue_size = queue_size,
        };
    }

    fn addr(self: Self) usize {
        return @intFromPtr(self.data.ptr);
    }

    pub fn flags(self: Self) *volatile u16 {
        const offset = 0;
        return @as(*volatile u16, @ptrCast(@alignCast(&self.data[offset])));
    }

    pub fn idx(self: Self) *volatile u16 {
        const offset = @sizeOf(u16);
        return @as(*volatile u16, @ptrCast(@alignCast(&self.data[offset])));
    }

    pub fn ring(self: Self) []volatile u16 {
        const offset = 2 * @sizeOf(u16);
        return @as([*]volatile u16, @ptrCast(@alignCast(&self.data[offset])))[0..self.queue_size];
    }

    pub fn used_event(self: Self) *volatile u16 {
        const offset = 2 * @sizeOf(u16) + @sizeOf(u16) * self.queue_size;
        return @as(*volatile u16, @ptrCast(@alignCast(&self.data[offset])));
    }
};

pub const UsedRing = struct {
    const UsedRingEntry = packed struct {
        id: u32,
        len: u32,
    };

    // flags: u16,
    // idx: u16,
    // ring: [QUEUE_SIZE]UsedRingEntry,
    // avail_event: u16,

    data: []u8,
    queue_size: u16,

    const Self = @This();

    fn new(queue_size: u16, allocator: Allocator) Error!Self {
        const size = @sizeOf(UsedRingEntry) * queue_size + @sizeOf(u16) * 3;
        const data = try allocator.alignedAlloc(u8, 4, size);
        @memset(data, 0);
        return Self{
            .data = data,
            .queue_size = queue_size,
        };
    }

    fn addr(self: Self) usize {
        return @intFromPtr(self.data.ptr);
    }

    pub fn flags(self: Self) *volatile u16 {
        const offset = 0;
        return @as(*volatile u16, @ptrCast(@alignCast(&self.data[offset])));
    }

    pub fn idx(self: Self) *volatile u16 {
        const offset = @sizeOf(u16);
        return @as(*volatile u16, @ptrCast(@alignCast(&self.data[offset])));
    }

    pub fn ring(self: Self) []volatile UsedRingEntry {
        @setRuntimeSafety(false);
        const offset = 2 * @sizeOf(u16);
        return @as([*]volatile UsedRingEntry, @ptrCast(@alignCast(&self.data[offset])))[0..self.queue_size];
    }

    pub fn avail_event(self: Self) *volatile u16 {
        const offset = 2 * @sizeOf(u16) + @sizeOf(UsedRingEntry) * self.queue_size;
        return @as(*volatile u16, @ptrCast(@alignCast(&self.data[offset])));
    }

    const Chain = struct {
        desc_list: ?[]VirtqDescBuffer,
        total_len: u32,

        const Self = @This();
    };
};

pub const VirtqDescBufferType = enum {
    ReadonlyFromDevice,
    WritableFromDevice,
};
pub const VirtqDescBuffer = struct {
    addr: u64,
    len: u32,
    type: VirtqDescBufferType,
};

pub const DeviceStatus = enum(u8) {
    RESET = 0,
    ACKNOWLEDGE = 1,
    DRIVER = 2,
    FAILED = 128,
    FEATURES_OK = 8,
    DRIVER_OK = 4,
    DEVICE_NEEDS_RESET = 64,

    const Self = @This();

    fn toInt(self: Self) u8 {
        return @intFromEnum(self);
    }
};

pub const VirtioCommonConfig = packed struct {
    device_feature_select: u32,
    device_feature: u32,
    driver_feature_select: u32,
    driver_feature: u32,
    config_msix_vector: u16,
    num_queues: u16,
    device_status: u8,
    config_generation: u8,
    queue_select: u16,
    queue_size: u16,
    queue_msix_vector: u16,
    queue_enable: u16,
    queue_notify_off: u16,
    queue_desc: u64,
    queue_driver: u64,
    queue_device: u64,
    queue_notify_data: u16,
    queue_reset: u16,
};

pub fn VirtioMmioTransport(comptime DeviceConfigType: type) type {
    // FIXME: volatile pointer of packed struct doesn't work?
    // https://ziglang.org/documentation/master/#toc-packed-struct
    return packed struct {
        common_config: *volatile VirtioCommonConfig,
        device_config: *volatile DeviceConfigType,
        notify: usize,
        notify_off_multiplier: u32,
        isr: *volatile u32,
        pci_dev: *const pci.Device,

        const Self = @This();

        pub fn new(dev: *pci.Device) Self {
            var self = Self{
                .common_config = undefined,
                .device_config = undefined,
                .notify = undefined,
                .notify_off_multiplier = undefined,
                .isr = undefined,
                .pci_dev = dev,
            };

            // Virtio Structure PCI Capabilities: https://docs.oasis-open.org/virtio/virtio/v1.2/csd01/virtio-v1.2-csd01.html#x1-1240004
            // struct virtio_pci_cap {
            //   u8 cap_vndr;    /* Generic PCI field: PCI_CAP_ID_VNDR */
            //   u8 cap_next;    /* Generic PCI field: next ptr. */
            //   u8 cap_len;     /* Generic PCI field: capability length */
            //   u8 cfg_type;    /* Identifies the structure. */
            //   u8 bar;         /* Where to find it. */
            //   u8 id;          /* Multiple capabilities of the same type */
            //   u8 padding[2];  /* Pad to full dword. */
            //   le32 offset;    /* Offset within bar. */
            //   le32 length;    /* Length of the structure, in bytes. */
            // };
            for (dev.capabilities) |pci_cap| {
                if (pci_cap.id != 9 or pci_cap.len < 16) {
                    continue;
                }

                const cfg_type = pci_cap.data[3];
                const bar_index = pci_cap.data[4];
                var offset: u32 = 0;
                @memcpy(@as([*]u8, @ptrCast(&offset)), pci_cap.data[8..12]);
                log.debug.printf("offset: {d}\n", .{offset});
                const bar = dev.config.bar(bar_index);
                const addr = @as(usize, @intCast(bar)) + @as(usize, @intCast(offset));

                switch (cfg_type) {
                    VIRTIO_PCI_CAP_COMMON_CFG => {
                        self.common_config = @as(*VirtioCommonConfig, @ptrFromInt(addr));
                    },
                    VIRTIO_PCI_CAP_DEVICE_CFG => {
                        self.device_config = @as(*DeviceConfigType, @ptrFromInt(addr));
                    },
                    VIRTIO_PCI_CAP_NOTIFY_CFG => {
                        self.notify = addr;
                        // self.notify_off_multiplier = @as(*u32, @ptrCast(@constCast(@alignCast(pci_cap.data[16..20])))).*;
                        @memcpy(@as([*]u8, @ptrCast(&self.notify_off_multiplier)), pci_cap.data[16..20]);
                        log.debug.printf("notify_off_multiplier: {d}\n", .{self.notify_off_multiplier});
                    },
                    VIRTIO_PCI_CAP_ISR_CFG => {
                        self.isr = @as(*u32, @ptrFromInt(addr));
                    },
                    else => {},
                }
            }

            @constCast(dev).enable_bus_master();

            return self;
        }

        pub fn read_device_feature(self: *Self) u64 {
            var value: u64 = 0;
            self.common_config.device_feature_select = 0;
            value |= @as(u64, self.common_config.device_feature);
            self.common_config.device_feature_select = 1;
            value |= @as(u64, self.common_config.device_feature) << 32;
            return value;
        }

        pub fn write_driver_feature(self: *Self, value: u64) void {
            self.common_config.driver_feature_select = 0;
            self.common_config.driver_feature = @as(u32, @intCast(value & 0xffffffff));
            self.common_config.driver_feature_select = 1;
            self.common_config.driver_feature = @as(u32, @intCast(value >> 32));
        }

        pub fn notifyQueue(self: *Self, virtq: *Virtqueue) void {
            if (virtq.not_notified_num_descs == 0) {
                return;
            }

            self.common_config.queue_select = virtq.index;
            const offset = self.notify_off_multiplier * self.common_config.queue_notify_off;
            const addr = self.notify + @as(usize, @intCast(offset));
            @as(*volatile u16, @ptrFromInt(addr)).* = virtq.index;

            virtq.not_notified_num_descs = 0;
        }

        pub fn getIsr(self: *Self) IsrStatus {
            return @as(IsrStatus, @enumFromInt(self.isr.*));
        }
    };
}
