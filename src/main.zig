const std = @import("std");
const options = @import("options");

const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const log = @import("log.zig");
const fs = @import("fs.zig");
const heap = @import("heap.zig");
const mem = @import("mem.zig");
const uart = @import("uart.zig");
const pci = @import("pci.zig");
const picirq = @import("picirq.zig");
const tcpip = @import("tcpip.zig");
const timer = @import("timer.zig");
const multiboot = @import("multiboot.zig");
const virtio_net = @import("drivers/virtio/net.zig");
const interrupt = @import("interrupt.zig");
const x64 = @import("x64.zig");

const wasi = @import("wasi.zig");

extern fn wasker_main() void;

export fn bspEarlyInit(boot_magic: u32, boot_params: u64) align(16) callconv(.C) void {
    _ = boot_magic;
    const bootinfo = @as(*multiboot.BootInfo, @ptrFromInt(boot_params));

    uart.init();
    lapic.init();
    ioapic.init();
    picirq.init();
    x64.init();
    timer.init();
    interrupt.init();
    mem.init(bootinfo);
    pci.init();
    virtio_net.init();
    mem.init2();
    tcpip.init();
    fs.init();

    uart.putc('\n');

    asm volatile ("sti");

    if (options.is_test) {
        wasi.integrationTest();
    }

    if (options.has_wasm) {
        wasker_main();
    }

    _ = wasi.memory_grow;
    _ = heap.sbrk;

    x64.shutdown(0);
    unreachable;
}

// ssize_t write(int fd, const void* buf, size_t count)
export fn write(fd: i32, b: *const u8, count: usize) callconv(.C) isize {
    if (fd == 1 or fd == 2) {
        const buf = @as([*]u8, @constCast(@ptrCast(b)))[0..count];
        log.fatal.print(buf);
        return @as(isize, @intCast(count));
    }
    return -1;
}
