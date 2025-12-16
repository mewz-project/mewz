const common = @import("common.zig");
const interrupt = @import("../../interrupt.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const pci = @import("../../pci.zig");

pub var virtio_vaccel: *VirtioVAccel = undefined;

const VIRTIO_ACCEL_DEVICE_READY = 1;
const VACCEL_OP_MAX_LEN = 2048;

const VIRTIO_ACCEL_NO_OP = 0;
const VIRTIO_ACCEL_CREATE_SESSION = 1;
const VIRTIO_ACCEL_DESTROY_SESSION = 2;
const VIRTIO_ACCEL_DO_OP = 3;
const VIRTIO_ACCEL_GET_TIMERS = 4;

// struct virtio_accel_arg {
//     uint32_t len;
//     unsigned char *buf;
//     unsigned char *usr_buf;
//     unsigned char *usr_pages;
//     uint32_t usr_npages;
//     unsigned char padding[5];
// };

// struct virtio_accel_op {
//     uint32_t in_nr;
//     uint32_t out_nr;
//     struct virtio_accel_arg *in;
//     struct virtio_accel_arg *out;
// };

// struct virtio_accel_hdr {
//     uint32_t sess_id;

// #define VIRTIO_ACCEL_NO_OP                   0
// #define VIRTIO_ACCEL_CREATE_SESSION          1
// #define VIRTIO_ACCEL_DESTROY_SESSION         2
// #define VIRTIO_ACCEL_DO_OP                   3
// #define VIRTIO_ACCEL_GET_TIMERS              4
//     uint32_t op_type;

//     /* session create structs */
//     struct virtio_accel_op op;
// };

const VirtioVAccelArg = packed struct {
    len: u32,
    buf: u64,
    usr_buf: u64,
    usr_pages: u64,
    usr_npages: u32,
    padding: u40,
    // padding: [5]u8,
};

const VirtioVAccelOp = packed struct {
    in_nr: u32,
    out_nr: u32,
    in: u64,
    out: u64,
};

const VirtioVAccelHdr = packed struct {
    sess_id: u32,
    op_type: u32,
    op: VirtioVAccelOp,
};

pub const AccelArg = struct {
    buf: [*]u8,
    len: u32,
};

const VirtioVAccel = struct {
    virtio: common.Virtio(VirtioVAccelDeviceConfig),

    tx_ring_index: usize,
    tx_ring: []u8,
    rx_ring: []u8,

    const Self = @This();

    fn new(virtio: common.Virtio(VirtioVAccelDeviceConfig)) Self {
        const status = @as(*volatile u32, @ptrCast(&virtio.transport.device_config.status)).*;
        const services = @as(*volatile u32, @ptrCast(&virtio.transport.device_config.services)).*;
        const max_size = @as(*volatile u64, @ptrCast(&virtio.transport.device_config.max_size)).*;
        if ((status & VIRTIO_ACCEL_DEVICE_READY) == 0) {
            @panic("virtio-vaccel: device not ready");
        }        
        log.info.printf("virtio-vaccel: status={x}, services={x}, max_size={}\n", .{ status, services, max_size });
        
        var self = Self{
            .virtio = virtio,
            .tx_ring_index = 0,
            .tx_ring = undefined,
            .rx_ring = undefined,
        };

        const tx_ring_len = @as(usize, @intCast(self.transmitq().num_descs));
        const rx_ring_len = @as(usize, @intCast(self.receiveq().num_descs));
        self.tx_ring = mem.boottime_allocator.?.alloc(u8, tx_ring_len * VACCEL_OP_MAX_LEN) catch @panic("virtio-vaccel: tx ring alloc failed");
        self.rx_ring = mem.boottime_allocator.?.alloc(u8, rx_ring_len * VACCEL_OP_MAX_LEN) catch @panic("virtio-vaccel: rx ring alloc failed");

        // Since response from qemu happens only after request, we don't need to preallocate rx buffers.
        // for (0..rx_ring_len) |i| {
        //     const desc_buf = common.VirtqDescBuffer{
        //         .addr = @intFromPtr(&self.rx_ring[i * VACCEL_OP_MAX_LEN]),
        //         .len = VACCEL_OP_MAX_LEN,
        //         .type = common.VirtqDescBufferType.WritableFromDevice,
        //     };
        //     var chain = [1]common.VirtqDescBuffer{desc_buf};
        //     self.receiveq().enqueue(chain[0..1]);
        //     self.virtio.transport.notifyQueue(self.receiveq());
        // }

        return self;
    }

    fn receiveq(self: *Self) *common.Virtqueue {
        return &self.virtio.virtqueues[0];
    }

    fn transmitq(self: *Self) *common.Virtqueue {
        return &self.virtio.virtqueues[1];
    }

    pub fn receive(_: *Self) void {
    }

    pub fn sendRequest(self: *Self, op_type: u32, session_id: u32, out_args: []const AccelArg, in_args: []const AccelArg, session_id_out: ?*u64) u32 {
        log.info.printf("virtio-vaccel: sendRequest op_type={}, session_id={}, out_args.len={}, in_args.len={}\n", .{op_type, session_id, out_args.len, in_args.len});
        _ = self.receiveq();
        var hdr = VirtioVAccelHdr {
            .sess_id = session_id,
            .op_type = op_type,
            .op = VirtioVAccelOp{
                .in_nr = @intCast(in_args.len),
                .out_nr = @intCast(out_args.len),
                .in = 0,
                .out = 0,
            },
        };

        var out_meta_buf: []VirtioVAccelArg = &[_]VirtioVAccelArg{};
        var in_meta_buf: []VirtioVAccelArg = &[_]VirtioVAccelArg{};
        
        if (out_args.len > 0) {
            out_meta_buf = mem.boottime_allocator.?.alloc(VirtioVAccelArg, out_args.len) catch @panic("virtio-vaccel: out meta alloc failed");
            for (out_args, 0..) |arg, i| {
                out_meta_buf[i] = VirtioVAccelArg{
                    .len = arg.len,
                    .buf = @intFromPtr(arg.buf),
                    .usr_buf = 0,
                    .usr_pages = 0,
                    .usr_npages = 0,
                    .padding = 0,
                };
            }
            hdr.op.out = @as(u64, @intFromPtr(&out_meta_buf[0]));
        }

        if (in_args.len > 0) {
            in_meta_buf = mem.boottime_allocator.?.alloc(VirtioVAccelArg, in_args.len) catch @panic("virtio-vaccel: in meta alloc failed");
            for (in_args, 0..) |arg, i| {
                in_meta_buf[i] = VirtioVAccelArg{
                    .len = arg.len,
                    .buf = @intFromPtr(arg.buf),
                    .usr_buf = 0,
                    .usr_pages = 0,
                    .usr_npages = 0,
                    .padding = 0
                };
            }
            hdr.op.in = @as(u64, @intFromPtr(&in_meta_buf[0]));
        }

        // Create descriptor chain
        var max_chain = 3 + out_args.len + in_args.len;
        if (session_id_out != null) {
            // need extra buffer for session_id output
            max_chain += 1;
        }
        var chain = mem.boottime_allocator.?.alloc(common.VirtqDescBuffer, max_chain) catch @panic("virtio-vaccel: desc chain alloc failed");
        var idx_chain: usize = 0;

        // out: hdr
        chain[idx_chain] = common.VirtqDescBuffer{
            .addr = @intFromPtr(&hdr),
            .len = @sizeOf(VirtioVAccelHdr),
            .type = common.VirtqDescBufferType.ReadonlyFromDevice,
        };
        idx_chain += 1;

        // out: out_args
        if (out_args.len > 0) {
            chain[idx_chain] = common.VirtqDescBuffer{
                .addr = @intFromPtr(&out_meta_buf[0]),
                .len = @as(u32, @intCast(@sizeOf(VirtioVAccelArg) * out_args.len)),
                .type = common.VirtqDescBufferType.ReadonlyFromDevice,
            };
            idx_chain += 1;
        }

        // out: in_args
        if (in_args.len > 0) {
            chain[idx_chain] = common.VirtqDescBuffer{
                .addr = @intFromPtr(&in_meta_buf[0]),
                .len = @as(u32, @intCast(@sizeOf(VirtioVAccelArg) * in_args.len)),
                .type = common.VirtqDescBufferType.ReadonlyFromDevice,
            };
            idx_chain += 1;
        }

        // out: payloads
        for (out_args) |arg| {
            chain[idx_chain] = common.VirtqDescBuffer{
                .addr = @intFromPtr(arg.buf),
                .len = arg.len,
                .type = common.VirtqDescBufferType.ReadonlyFromDevice,
            };
            idx_chain += 1;
        }

        // in: payloads
        for (in_args) |arg| {
            chain[idx_chain] = common.VirtqDescBuffer{
                .addr = @intFromPtr(arg.buf),
                .len = arg.len,
                .type = common.VirtqDescBufferType.WritableFromDevice,
            };
            idx_chain += 1;
        }

        // in: session_id_out
        if (session_id_out) |session_id_ptr| {
            session_id_ptr.* = 0;
            chain[idx_chain] = common.VirtqDescBuffer{
                .addr = @intFromPtr(session_id_ptr),
                .len = @sizeOf(u64),
                .type = common.VirtqDescBufferType.WritableFromDevice,
            };
            idx_chain += 1;
        }

        // in: status
        var status: u32 = 0;
        chain[idx_chain] = common.VirtqDescBuffer{
            .addr = @intFromPtr(&status),
            .len = @sizeOf(u32),
            .type = common.VirtqDescBufferType.WritableFromDevice,
        };
        idx_chain += 1;


        // Enqueue the descriptor chain
        const vq = self.transmitq();
        vq.enqueue(chain[0..idx_chain]);
        self.virtio.transport.notifyQueue(vq);

        while (true) {
            // wait for response
            const used_chain = vq.popUsedOne();
            if (used_chain != null){
                break;
            }
        }
        return status;
    }

    pub fn createSession(self: *Self, out_args: []const AccelArg, in_args: []const AccelArg) struct { status: u32, session_id: u32 } {
        var session_id: u64 = 0;
        const status = self.sendRequest(
            VIRTIO_ACCEL_CREATE_SESSION,
            0,
            out_args,
            in_args,
            &session_id,
        );
        return .{ .status = status, .session_id = @intCast(session_id) };
    }
};

const VirtioVAccelDeviceConfig = packed struct {
    // bit 0: if set, the device is ready
    status: u32,
    services: u32,
    max_size: u64,
};

pub fn init() void {
    var pci_dev = find: {
        for (pci.devices) |d| {
            const dev = d orelse continue;
            if (dev.config.vendor_id == 0x1af4 and dev.config.device_id == 0x1055) {
                break :find dev;
            }
        }
        log.info.printf("virtio-vaccel: no device found, skip initialization\n", .{});
        return;
    };
    log.info.printf("virtio-vaccel: device found\n", .{});

    const virtio_features = 1 << 32; // VIRTIO_F_VERSION_1
    const virtio = common.Virtio(VirtioVAccelDeviceConfig)
        .new(&pci_dev, virtio_features, 2, mem.boottime_allocator.?) catch @panic("virtio-accel init failed");
    const virtio_vaccel_slice = mem.boottime_allocator.?.alloc(VirtioVAccel, 1) catch @panic("virtio-accel alloc failed");
    virtio_vaccel = @as(*VirtioVAccel, @ptrCast(virtio_vaccel_slice.ptr));
    virtio_vaccel.* = VirtioVAccel.new(virtio);

    // TODO:
    interrupt.registerIrq(virtio_vaccel.virtio.transport.pci_dev.config.interrupt_line, handleIrq);
}

fn handleIrq(frame: *interrupt.InterruptFrame) void {
    _ = frame;
    log.debug.print("virtio-vaccel: interrupt\n");
    virtio_vaccel.receive();
}