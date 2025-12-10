const log = @import("../../log.zig");
const pci = @import("../../pci.zig");

pub fn init() void {
    _ = find: {
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
}