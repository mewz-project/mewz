const interrupt = @import("interrupt.zig");
const timer = @import("timer.zig");

const LAPIC = 0xFEE00000;

// Local APIC registers, divided by 4 for use as []u32 indices.
const ID = 0x0020 / @sizeOf(u32); // ID
const VER = 0x0030 / @sizeOf(u32); // VERSION
const TPR = 0x0080 / @sizeOf(u32); // Task Priority
const EOI = 0x00B0 / @sizeOf(u32); // EOI
const SVR = 0x00F0 / @sizeOf(u32); // Spurious Interrupt Vector
const ENABLE = 0x00000100; // Unit Enable
const ESR = 0x0280 / @sizeOf(u32); // Error Status
const ICRLO = 0x0300 / @sizeOf(u32); // Interrupt Command
const INIT = 0x00000500; // INIT/RESET
const STARTUP = 0x00000600; // Startup IPI
const DELIVS = 0x00001000; // Delivery status
const ASSERT = 0x00004000; // Assert interrupt (vs deassert)
const DEASSERT = 0x00000000;
const LEVEL = 0x00008000; // Level triggered
const BCAST = 0x00080000; // Send to all APICs, including self
const BUSY = 0x00001000;
const FIXED = 0x00000000;
const ICRHI = 0x0310 / @sizeOf(u32); // Interrupt Command [63:32]
const TIMER = 0x0320 / @sizeOf(u32); // Local Vector Table 0 (TIMER)
const X1 = 0x0000000B; // divide counts by 1
const PERIODIC = 0x00020000; // Periodic
const PCINT = 0x0340 / @sizeOf(u32); // Performance Counter LVT
const LINT0 = 0x0350 / @sizeOf(u32); // Local Vector Table 1 (LINT0)
const LINT1 = 0x0360 / @sizeOf(u32); // Local Vector Table 2 (LINT1)
const ERROR = 0x0370 / @sizeOf(u32); // Local Vector Table 3 (ERROR)
const MASKED = 0x00010000; // Interrupt masked
const TICR = 0x0380 / @sizeOf(u32); // Timer Initial Count
const TCCR = 0x0390 / @sizeOf(u32); // Timer Current Count
const TDCR = 0x03E0 / @sizeOf(u32); // Timer Divide Configuration

pub var lapic: [*]volatile u32 = @as([*]u32, @ptrFromInt(LAPIC));

fn lapicw(index: u32, value: u32) void {
    lapic[index] = value;
    _ = lapic[ID]; // wait for write to finish
}

pub fn init() void {
    // Enable local APIC; set spurious interrupt vector.
    lapicw(SVR, ENABLE | (interrupt.T_IRQ0 + interrupt.IRQ_SPURIOUS));

    // The timer repeatedly counts down at bus frequency
    // from lapic[TICR] and then issues an interrupt.
    // If xv6 cared more about precise timekeeping,
    // TICR would be calibrated using an external time source.
    lapicw(TDCR, X1);
    lapicw(TIMER, PERIODIC | (interrupt.T_IRQ0 + timer.IRQ_TIMER));
    lapicw(TICR, 1000000);

    // Disable logical interrupt lines.
    lapicw(LINT0, MASKED);
    lapicw(LINT1, MASKED);

    // Disable performance counter overflow interrupts
    // on machines that provide that interrupt entry.

    if (((lapic[VER] >> 16) & 0xFF) >= 4) {
        lapicw(PCINT, MASKED);
    }

    // Map error interrupt to IRQ_ERROR.
    lapicw(ERROR, interrupt.T_IRQ0 + interrupt.IRQ_ERROR);

    // Clear error status register (requires back-to-back writes).
    lapicw(ESR, 0);
    lapicw(ESR, 0);

    // Ack any outstainding interrupts.
    lapicw(EOI, 0);

    // Send an Init Level De-Assert to synchronise arbitration ID's.
    lapicw(ICRHI, 0);
    lapicw(ICRLO, BCAST | INIT | LEVEL);
    while (lapic[ICRLO] & DELIVS != 0) {}

    // Enable interrupts on the APIC (but not on the processor).
    lapicw(TPR, 0);
}

pub fn lapicid() u32 {
    return lapic[ID] >> 24;
}

pub fn lapiceoi() void {
    lapicw(EOI, 0);
}

// Spin for a given number of microseconds.
// On real hardware would want to tune this dynamically.
pub fn microdelay(_: u32) void {}
