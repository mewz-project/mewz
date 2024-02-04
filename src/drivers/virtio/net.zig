const common = @import("common.zig");
const heap = @import("../../heap.zig");
const interrupt = @import("../../interrupt.zig");
const log = @import("../../log.zig");
const lwip = @import("../../lwip.zig");
const mem = @import("../../mem.zig");
const pci = @import("../../pci.zig");

const PACKET_MAX_LEN = 2048;

pub var virtio_net: *VirtioNet = undefined;

extern fn rx_recv(data: *u8, len: u16) void;

const VirtioNetDeviceFeature = enum(u64) {
    VIRTIO_NET_F_CSUM = 1 << 0,
    VIRTIO_NET_F_GUEST_CSUM = 1 << 1,
    VIRTIO_NET_F_CTRL_GUEST_OFFLOADS = 1 << 2,
    VIRTIO_NET_F_MTU = 1 << 3,
    VIRTIO_NET_F_MAC = 1 << 5,
    VIRTIO_NET_F_GUEST_TSO4 = 1 << 7,
    VIRTIO_NET_F_GUEST_TSO6 = 1 << 8,
    VIRTIO_NET_F_GUEST_ECN = 1 << 9,
    VIRTIO_NET_F_GUEST_UFO = 1 << 10,
    VIRTIO_NET_F_HOST_TSO4 = 1 << 11,
    VIRTIO_NET_F_HOST_TSO6 = 1 << 12,
    VIRTIO_NET_F_HOST_ECN = 1 << 13,
    VIRTIO_NET_F_HOST_UFO = 1 << 14,
    VIRTIO_NET_F_MRG_RXBUF = 1 << 15,
    VIRTIO_NET_F_STATUS = 1 << 16,
    VIRTIO_NET_F_CTRL_VQ = 1 << 17,
    VIRTIO_NET_F_CTRL_RX = 1 << 18,
    VIRTIO_NET_F_CTRL_VLAN = 1 << 19,
    VIRTIO_NET_F_GUEST_ANNOUNCE = 1 << 21,
    VIRTIO_NET_F_MQ = 1 << 22,
    VIRTIO_NET_F_CTRL_MAC_ADDR = 1 << 23,
    VIRTIO_NET_F_HOST_USO = 1 << 56,
    VIRTIO_NET_F_HASH_REPORT = 1 << 57,
    VIRTIO_NET_F_GUEST_HDRLEN = 1 << 59,
    VIRTIO_NET_F_RSS = 1 << 60,
    VIRTIO_NET_F_RSC_EXT = 1 << 61,
    VIRTIO_NET_F_STANDBY = 1 << 62,
    VIRTIO_NET_F_SPEED_DUPLEX = 1 << 63,
};

const Header = struct {
    flags: u8,
    gso_type: u8,
    hdr_len: u16,
    gso_size: u16,
    checksum_start: u16,
    checksum_offset: u16,
    num_buffer: u16,
};

const VirtioNet = struct {
    virtio: common.Virtio(VirtioNetDeviceConfig),

    mac_addr: [6]u8,

    tx_ring_index: usize,
    tx_ring: []u8,
    rx_ring: []u8,

    const Self = @This();

    fn new(virtio: common.Virtio(VirtioNetDeviceConfig)) Self {
        const mac_addr = @as(*[6]u8, @ptrCast(@volatileCast(&virtio.transport.device_config.mac))).*;
        log.info.printf("mac: {x}:{x}:{x}:{x}:{x}:{x}\n", .{ mac_addr[0], mac_addr[1], mac_addr[2], mac_addr[3], mac_addr[4], mac_addr[5] });

        var self = Self{
            .virtio = virtio,
            .mac_addr = mac_addr,
            .tx_ring_index = 0,
            .tx_ring = undefined,
            .rx_ring = undefined,
        };

        const tx_ring_len = @as(usize, @intCast(self.transmitq().num_descs));
        const rx_ring_len = @as(usize, @intCast(self.receiveq().num_descs));
        self.tx_ring = mem.boottime_allocator.?.alloc(u8, tx_ring_len * PACKET_MAX_LEN) catch @panic("virtio net tx ring alloc failed");
        self.rx_ring = mem.boottime_allocator.?.alloc(u8, rx_ring_len * PACKET_MAX_LEN) catch @panic("virtio net rx ring alloc failed");

        for (0..rx_ring_len) |i| {
            const desc_buf = common.VirtqDescBuffer{
                .addr = @intFromPtr(&self.rx_ring[i * PACKET_MAX_LEN]),
                .len = PACKET_MAX_LEN,
                .type = common.VirtqDescBufferType.WritableFromDevice,
            };
            var chain = [1]common.VirtqDescBuffer{desc_buf};
            self.receiveq().enqueue(chain[0..1]);
            self.virtio.transport.notifyQueue(self.receiveq());
        }

        self.transmitq().avail.flags().* = common.VIRTQ_AVAIL_F_NO_INTERRUPT;

        return self;
    }

    fn receiveq(self: *Self) *common.Virtqueue {
        return &self.virtio.virtqueues[0];
    }

    fn transmitq(self: *Self) *common.Virtqueue {
        return &self.virtio.virtqueues[1];
    }

    pub fn transmit(
        self: *Self,
        data: []const u8,
    ) void {
        @setRuntimeSafety(false);

        const idx = self.tx_ring_index % self.transmitq().num_descs;
        const base = @intFromPtr(&virtio_net.tx_ring[idx * PACKET_MAX_LEN]);
        defer self.tx_ring_index +%= 1;

        const header = @as(*Header, @ptrFromInt(base));
        header.* = Header{
            .flags = 0,
            .gso_type = 0,
            .hdr_len = 0,
            .gso_size = 0,
            .checksum_start = 0,
            .checksum_offset = 0,
            .num_buffer = 1,
        };

        const buf = @as([*]u8, @ptrFromInt(base + @sizeOf(Header)));
        @memcpy(buf, data);

        var desc_buf = [_]common.VirtqDescBuffer{common.VirtqDescBuffer{
            .addr = base,
            .len = @sizeOf(Header) + @as(u32, @intCast(data.len)),
            .type = common.VirtqDescBufferType.ReadonlyFromDevice,
        }};

        self.transmitq().enqueue(desc_buf[0..1]);

        if (self.transmitq().not_notified_num_descs > self.transmitq().num_descs / 2) {
            self.virtio.transport.notifyQueue(self.transmitq());
        }
    }

    pub fn receive(self: *Self) void {
        const isr = self.virtio.transport.getIsr();
        if (isr.isQueue()) {
            lwip.acquire().sys_check_timeouts();
            lwip.release();

            const rq = self.receiveq();
            while (rq.last_used_idx != rq.used.idx().*) {
                // Each packet is contained in a single descriptor,
                // because VIRTIO_NET_F_MRG_RXBUF is not negotiated.
                const used_elem = rq.popUsedOne() orelse continue;
                const buf = @as([*]u8, @ptrFromInt(rq.desc[used_elem.id].addr))[0..used_elem.len];
                const packet_buf = buf[@sizeOf(Header)..];

                rx_recv(@as(*u8, @ptrCast(packet_buf.ptr)), @as(u16, @intCast(packet_buf.len)));

                rq.enqueue(([1]common.VirtqDescBuffer{common.VirtqDescBuffer{
                    .addr = rq.desc[used_elem.id].addr,
                    .len = PACKET_MAX_LEN,
                    .type = common.VirtqDescBufferType.WritableFromDevice,
                }})[0..1]);
            }

            if (rq.not_notified_num_descs > rq.num_descs / 2) {
                self.virtio.transport.notifyQueue(self.receiveq());
            }
        }
    }
};

const VirtioNetDeviceConfig = packed struct {
    mac: u48,
    status: u16,
    max_virtqueue_pairs: u16,
    mtu: u16,
    speed: u32,
    duplex: u8,
};

pub fn init() void {
    var pci_dev = find: {
        for (pci.devices) |d| {
            const dev = d orelse continue;
            if (dev.config.vendor_id == 0x1af4 and dev.config.device_id == 0x1041) {
                break :find dev;
            }
        }
        @panic("virtio net is not found");
    };

    // TODO: VIRTIO_F_VERSION_1
    const virtio = common.Virtio(VirtioNetDeviceConfig)
        .new(&pci_dev, (1 << 32) | @intFromEnum(VirtioNetDeviceFeature.VIRTIO_NET_F_MAC), 2, mem.boottime_allocator.?) catch @panic("virtio init failed");

    const virtio_net_slice = mem.boottime_allocator.?.alloc(VirtioNet, 1) catch @panic("virtio net alloc failed");
    virtio_net = @as(*VirtioNet, @ptrCast(virtio_net_slice.ptr));
    virtio_net.* = VirtioNet.new(virtio);
    interrupt.registerIrq(virtio_net.virtio.transport.pci_dev.config.interrupt_line, handleIrq);
}

fn handleIrq(frame: *interrupt.InterruptFrame) void {
    _ = frame;
    log.debug.print("interrupt\n");
    virtio_net.receive();
}

pub fn flush() void {
    virtio_net.virtio.transport.notifyQueue(virtio_net.transmitq());
}
