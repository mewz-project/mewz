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

    var it = std.debug.StackIterator.init(@returnAddress(), null);
    var ix: usize = 0;
    log.fatal.printf("Stack Trace:\n", .{});
    while (it.next()) |frame| : (ix += 1) {
        log.fatal.printf("#{d:0>2}: 0x{X:0>16}\n", .{ ix, frame });
    }

    asm volatile ("hlt");

    unreachable;
}
