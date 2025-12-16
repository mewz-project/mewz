const common = @import("common.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const pci = @import("../../pci.zig");

pub var virtio_vaccel: *VirtioVAccel = undefined;

const VirtioVAccel = struct {
    virtio: common.Virtio(VitrioVAccelDeviceConfig),

    const Self = @This();

    fn new(virtio: common.Virtio(VitrioVAccelDeviceConfig)) Self {
        const self = Self{
            .virtio = virtio,
        };

        return self;
    }
};

const VitrioVAccelDeviceConfig = packed struct {
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

    const virtio = common.Virtio(VitrioVAccelDeviceConfig)
        .new(&pci_dev, 0, 2, mem.boottime_allocator.?) catch @panic("virtio-accel init failed");
    const virtio_vaccel_slice = mem.boottime_allocator.?.alloc(VirtioVAccel, 1) catch @panic("virtio-accel alloc failed");
    virtio_vaccel = @as(*VirtioVAccel, @ptrCast(virtio_vaccel_slice.ptr));
    virtio_vaccel.* = VirtioVAccel.new(virtio);

    // TODO:
    // interrupt.registerIrq(virtio_vaccel.virtio.transport.pci_dev.config.interrupt_line, handleIrq);
}