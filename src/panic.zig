const std = @import("std");
const log = @import("log.zig");

var panicked = false;

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    log.fatal.printf("=== PANIC ===\n", .{});
    log.fatal.printf("Message: {s}\n", .{msg});
    asm volatile ("cli");

    if (panicked) {
        log.fatal.print("Double Panic\n");
        asm volatile ("hlt");
    }
    panicked = true;

    log.fatal.printf("Stack Trace:\n", .{});
    var ix: usize = 0;
    var fp: ?[*]const usize = @ptrFromInt(@frameAddress());
    while (fp) |frame_ptr| : (ix += 1) {
        const ret_addr = frame_ptr[1];
        if (ret_addr == 0) break;
        log.fatal.printf("#{d:0>2}: 0x{X:0>16}\n", .{ ix, ret_addr });
        const next = frame_ptr[0];
        if (next == 0) break;
        fp = @ptrFromInt(next);
    }

    asm volatile ("hlt");

    unreachable;
}
