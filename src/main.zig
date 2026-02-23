const std = @import("std");
const options = @import("options");

const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const log = @import("log.zig");
const heap = @import("heap.zig");
const mem = @import("mem.zig");
const mewz_panic = @import("panic.zig");
const uart = @import("uart.zig");
const param = @import("param.zig");
const pci = @import("pci.zig");
const picirq = @import("picirq.zig");
const stream = @import("stream.zig");
const tcpip = @import("tcpip.zig");
const timer = @import("timer.zig");
const util = @import("util.zig");
const multiboot = @import("multiboot.zig");
const vfs = @import("vfs.zig");
const virtio_net = @import("drivers/virtio/net.zig");
const interrupt = @import("interrupt.zig");
const x64 = @import("x64.zig");

const wasi = @import("wasi.zig");

extern fn wasker_main() void;

pub const panic = mewz_panic.panic;

export fn bspEarlyInit(boot_magic: u32, boot_params: u32) align(16) callconv(.c) void {
    const bootinfo = @as(*multiboot.BootInfo, @ptrFromInt(boot_params));
    const cmdline = util.getString(bootinfo.cmdline);

    x64.init();
    param.parseFromArgs(cmdline);

    uart.init();
    lapic.init();
    ioapic.init();
    picirq.init();
    printBootinfo(boot_magic, bootinfo);
    timer.init();
    interrupt.init();
    mem.init(bootinfo);
    pci.init();
    log.debug.print("pci init finish\n");
    if (param.params.isNetworkEnabled()) {
        virtio_net.init();
    }
    vfs.init();

    mem.init2();
    if (param.params.isNetworkEnabled()) {
        tcpip.init(param.params.addr.?, param.params.subnetmask.?, param.params.gateway.?, &virtio_net.virtio_net.mac_addr);
    }

    const root_dir = vfs.makeRootDir();
    const root_fd = stream.fd_table.set(stream.Stream{ .dir = root_dir }) catch {
        log.fatal.print("failed to set root directory\n");
        x64.shutdown(1);
        unreachable;
    };
    log.debug.printf("root directory: fd={d}, path={s}\n", .{ root_fd, root_dir.name });

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
export fn write(fd: i32, b: *const u8, count: usize) callconv(.c) isize {
    if (fd == 1 or fd == 2) {
        const buf = @as([*]u8, @constCast(@ptrCast(b)))[0..count];
        log.fatal.print(buf);
        return @as(isize, @intCast(count));
    }
    return -1;
}

fn printBootinfo(magic: u32, bootinfo: *multiboot.BootInfo) void {
    log.debug.print("=== bootinfo ===\n");
    log.debug.printf("magic: {x}\n", .{magic});
    log.debug.printf("bootinfo addr: {x}\n", .{@intFromPtr(bootinfo)});
    log.debug.printf("flags: {b:0>8}\n", .{bootinfo.flags});
    log.debug.printf("mmap_addr: {x}\n", .{bootinfo.mmap_addr});
    log.debug.printf("mmap_length: {x}\n", .{bootinfo.mmap_length});
    const boot_loader_name = @as([*]u8, @ptrFromInt(bootinfo.boot_loader_name))[0..20];
    log.debug.printf("boot_loader_name: {s}\n", .{boot_loader_name});
    log.debug.print("================\n");
}
