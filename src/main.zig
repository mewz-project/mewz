const std = @import("std");
const options = @import("options");

const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const log = @import("log.zig");
const fs = @import("fs.zig");
const heap = @import("heap.zig");
const http_client = @import("http_client.zig");
const mem = @import("mem.zig");
const mewz_panic = @import("panic.zig");
const uart = @import("uart.zig");
const param = @import("param.zig");
const pci = @import("pci.zig");
const picirq = @import("picirq.zig");
const tcpip = @import("tcpip.zig");
const timer = @import("timer.zig");
const util = @import("util.zig");
const multiboot = @import("multiboot.zig");
const virtio_net = @import("drivers/virtio/net.zig");
const interrupt = @import("interrupt.zig");
const x64 = @import("x64.zig");

const wasi = @import("wasi.zig");

extern fn wasker_main() void;

pub const panic = mewz_panic.panic;

pub fn testHTTPClient() !void {
    log.debug.printf("Starting testHTTPClient...\n", .{});
    var client = http_client.Client.init();

    // Host IP in little-endian format:
    // Host IP is 10.0.2.2 when using QEMU default user-mode networking
    var ip = tcpip.IpAddr{ .addr = 0x0202000A };
    log.debug.printf("Target IP: {x}\n", .{ip.addr});
    const req = http_client.Request{
        .method = .GET,
        .host = "10.0.2.2",
        .uri = "/v2",
        .headers = &.{
        },
    };
    try client.send(&ip, 8000, &req);
}


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
        log.debug.print("Initializing virtio_net...\n");
        virtio_net.init();
    }

    mem.init2();
    if (param.params.isNetworkEnabled()) {
        log.debug.print("Initializing tcpip...\n");
        log.debug.printf("IP Addr: {x}\n", .{param.params.addr.?});
        tcpip.init(param.params.addr.?, param.params.subnetmask.?, param.params.gateway.?, &virtio_net.virtio_net.mac_addr);
    }
    fs.init();

    uart.putc('\n');

    asm volatile ("sti");

    if (options.is_test) {
        wasi.integrationTest();
    }

    log.debug.printf("Starting HTTP client...\n", .{});
    testHTTPClient() catch |err| {
        log.fatal.printf("testHTTPClient failed: {any}\n", .{err});
    };

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
