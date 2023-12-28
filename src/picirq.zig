const x64 = @import("x64.zig");

const IO_PIC1 = 0x20; // Master (IRQs 0-7)
const IO_PIC2 = 0xA0; // Slave (IRQs 8-15)

pub fn init() void {
    // disable PIC interrupts to use APIC
    x64.out(IO_PIC1 + 1, @as(u8, 0xff));
    x64.out(IO_PIC2 + 1, @as(u8, 0xff));
}
