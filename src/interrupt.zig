// x64 trap and interrupt constants.

const lapic = @import("lapic.zig");
const log = @import("log.zig");
const x64 = @import("x64.zig");

// Processor-defined
pub const T_BRKPT = 3;
pub const T_IRQ0 = 32;
pub const IRQ_COM1 = 4;
pub const IRQ_ERROR = 19;
pub const IRQ_SPURIOUS = 31;

// System segment type bits
pub const STS_IG32 = 0xE; // 32-bit Interrupt Gate
pub const STS_TG32 = 0xF; // 32-bit Trap Gate

// various segment selectors.
pub const SEG_KCODE = 1; // kernel code
pub const SEG_KDATA = 2; // kernel data+stack

extern const interrupt_handlers: u32;

var idt: [256]InterruptDescriptor = undefined;

var irq_handlers: [256]?*const fn (*InterruptFrame) void = init: {
    var initial_value: [256]?fn (*InterruptFrame) void = undefined;
    for (&initial_value) |*pt| {
        pt.* = null;
    }
    break :init undefined;
};

pub const InterruptDescriptor = packed struct {
    off_15_0: u16, // low 16 bits of offset in segment
    cs: u16, // code segment selector
    ist: u3, // # interrupt stack table, 0 for interrupt/trap gates
    rsv1: u5, // reserved (should be zero I guess)
    typ: u4, // type (STS_{IG32, TG32})
    s: u1, // must be 0 (system)
    dpl: u2, // descriptor (meaning new) privilege level
    p: u1, // Present
    off_31_16: u16, // 16-31 bits of offset in segment
    off_63_32: u32, // 32-63 bits of offset in segment
    rsv2: u32, // reserved

    const Self = @This();

    pub fn new(isTrap: bool, sel: u16, off: u64, d: u2) Self {
        return Self{
            .off_15_0 = @as(u16, @intCast(off & 0xffff)),
            .cs = sel,
            .ist = 0,
            .rsv1 = 0,
            .typ = if (isTrap) STS_TG32 else STS_IG32,
            .s = 0,
            .dpl = d,
            .p = 1,
            .off_31_16 = @as(u16, @intCast((off >> 16) & 0xffff)),
            .off_63_32 = @as(u32, @intCast(off >> 32)),
            .rsv2 = 0,
        };
    }
};

// Layout of the interrupt frame built on the stack by the
// hardware and by interrupt.S, and passed to common_interrupt_handler().
pub const InterruptFrame = packed struct {
    rax: u64,
    rbx: u64,
    rcx: u64,
    rdx: u64,
    rsi: u64,
    rbp: u64,
    r8: u64,
    r9: u64,
    r10: u64,
    r11: u64,
    r12: u64,
    r13: u64,
    r14: u64,
    r15: u64,
    rdi: u64,
    err: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

pub fn init() void {
    // Make interrupt descriptor table (IDT)
    // It should be calculated at comptime, but cannot due to the Zig compiler
    idt = init: {
        var initial_value: [256]InterruptDescriptor = undefined;
        var int_handler_pointer: usize = @intFromPtr(&interrupt_handlers);
        for (&initial_value) |*pt| {
            pt.* = InterruptDescriptor.new(false, SEG_KCODE << 3, int_handler_pointer, 0);
            int_handler_pointer += 16;
        }
        break :init initial_value;
    };

    x64.lidt(@intFromPtr(&idt), @as(u16, @intCast(@sizeOf(@TypeOf(idt)))));
}

pub fn registerIrq(irq: u8, handler: *const fn (*InterruptFrame) void) void {
    irq_handlers[irq] = handler;
}

var ticks: u32 = 0;
export fn commonInterruptHandler(trapno: u8, frame: *InterruptFrame) callconv(.C) void {
    switch (trapno) {
        T_BRKPT => {
            const buf = @as([*]u8, @ptrFromInt(frame.rdi))[0..1000];
            printMessage(buf);
            while (true) {}
        },
        T_IRQ0...255 => {
            const irq = trapno - T_IRQ0;
            if (irq_handlers[irq]) |irq_handler| {
                irq_handler(frame);
            } else {
                log.fatal.print("unregisterd interrupt\n");
                unexpectedInterruptHandler(trapno, frame);
            }
        },
        else => {
            unexpectedInterruptHandler(trapno, frame);
        },
    }
    lapic.lapiceoi();
}

fn printMessage(buf: []u8) void {
    for (buf, 0..) |c, i| {
        if (c == 0) {
            log.fatal.printf("panic: {s}\n", .{buf[0..i]});
            break;
        }
    }
}

fn unexpectedInterruptHandler(trapno: u8, frame: *InterruptFrame) void {
    log.fatal.printf("unexpected interrupt {d}\n", .{trapno});
    log.fatal.printf("error code 0x{x}\n", .{frame.err});
    log.fatal.printf("RIP 0x{x}\n", .{frame.rip});
    log.fatal.printf("CR2 0x{x}\n", .{x64.cr2()});
    while (true) {}
}
