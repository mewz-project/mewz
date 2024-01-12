const ioapic = @import("ioapic.zig");
const interrupt = @import("interrupt.zig");
const x64 = @import("x64.zig");

const COM1 = 0x3f8;

pub fn init() void {
    // Turn off the FIFO
    x64.out(COM1 + 2, @as(u8, 0));

    // 9600 baud, 8 data bits, 1 stop bit, parity off.
    x64.out(COM1 + 3, @as(u8, 0x80)); // Unlock divisor
    x64.out(COM1 + 0, @as(u8, 115200 / 9600));
    x64.out(COM1 + 1, @as(u8, 0));
    x64.out(COM1 + 3, @as(u8, 0x03)); // Lock divisor, 8 data bits.
    x64.out(COM1 + 4, @as(u8, 0));
    x64.out(COM1 + 1, @as(u8, 0x01)); // Enable receive interrupts.

    // If status if 0xFF, no serial port.
    if (x64.in(u8, COM1 + 5) == 0xff) {
        @panic("serial port does not exist");
    }

    // Acknowledge pre-existing interrupt conditions;
    // enable interrupts.
    _ = x64.in(u8, COM1 + 2);
    _ = x64.in(u8, COM1 + 0);
    ioapic.ioapicenable(interrupt.IRQ_COM1, 0);
}

pub fn putc(c: u8) void {
    var i: u32 = 0;
    while (i < 128 and ((x64.in(u8, COM1 + 5)) & 0x20) == 0) : (i += 1) {
        // lapic.microdelay(10);
    }
    x64.out(COM1 + 0, @as(u8, c));
}

pub fn puts(data: []const u8) void {
    for (data) |c| {
        putc(c);
    }
}

pub fn write(data: []const u8) usize {
    puts(data);
    return data.len;
}
