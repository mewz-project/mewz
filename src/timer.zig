const std = @import("std");
const heap = @import("heap.zig");
const interrupt = @import("interrupt.zig");
const log = @import("log.zig");
const param = @import("param.zig");
const sync = @import("sync.zig");
const x64 = @import("x64.zig");
const net = @import("drivers/virtio/net.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const SpinLock = sync.SpinLock;

var timers_inner: ArrayList(*Timer) = undefined;
var timers: SpinLock(ArrayList(*Timer)) = undefined;

var ticks_internal: u64 = 0;
var ticks = SpinLock(u64).new(&ticks_internal);

/// REALTIME = boot_epoch_offset_ns + monotonic_ns
var boot_epoch_offset_ns: u64 = 0;

pub const IRQ_TIMER = 0;
const frequency = 1000; // TODO: measure frequency while booting

const cmos_index_port: u16 = 0x70;
const cmos_data_port: u16 = 0x71;

pub const Timer = struct {
    ns: u64,
    is_finished_internal: bool = false, // should be atomic

    const Self = @This();

    pub fn newByAbsoluteTime(ns: u64) Self {
        return .{
            .ns = ns,
        };
    }

    pub fn newByRelativeTime(ns: u64) Self {
        return .{
            .ns = getMonotonicNanoSeconds() + ns,
        };
    }

    pub fn register(self: *Self) Allocator.Error!void {
        try timers.acquire().*.append(self);
        timers.release();
    }

    pub fn isFinished(self: *Self) bool {
        return @atomicLoad(bool, &self.*.is_finished_internal, std.builtin.AtomicOrder.seq_cst);
    }
};

pub fn handleIrq(frame: *interrupt.InterruptFrame) void {
    _ = frame;

    ticks.acquire().* += 1;
    ticks.release();

    var timer_list = timers.acquire();
    for (timer_list.items, 0..) |timer, i| {
        if (timer.ns <= getMonotonicNanoSeconds()) {
            timer.*.is_finished_internal = true;
            _ = timer_list.swapRemove(i);
        }
    }
    timers.release();

    net.flush();
}

pub fn init() void {
    timers_inner = ArrayList(*Timer).init(heap.runtime_allocator);
    timers = SpinLock(ArrayList(*Timer)).new(&timers_inner);

    interrupt.registerIrq(IRQ_TIMER, handleIrq);

    const monotonic_at_boot = getMonotonicNanoSeconds();
    const boot_unix_secs = readRtcUnixSeconds() orelse param.params.epoch orelse blk: {
        log.debug.print("timer: CMOS RTC unavailable and no epoch= cmdline; using 2026-01-01 UTC\n");
        break :blk @as(u64, 1767225600); // 2026-01-01 00:00:00 UTC
    };
    boot_epoch_offset_ns = boot_unix_secs * 1_000_000_000 - monotonic_at_boot;
}

pub fn getMonotonicNanoSeconds() u64 {
    const t = ticks.acquire().*;
    ticks.release();
    return t * (1_000_000_000 / frequency);
}

pub fn getRealtimeNanoSeconds() u64 {
    return boot_epoch_offset_ns + getMonotonicNanoSeconds();
}

pub fn getNanoSeconds() u64 {
    return getMonotonicNanoSeconds();
}

pub fn unregisterAll() void {
    timers.acquire().*.clearRetainingCapacity();
    timers.release();
}

export fn sys_now() callconv(.c) i32 {
    return @as(i32, @intCast(getMonotonicNanoSeconds() / 1_000_000));
}

fn cmosRead(reg: u8) u8 {
    x64.out(cmos_index_port, reg);
    return x64.in(u8, cmos_data_port);
}

fn bcdToDec(bcd: u8) u8 {
    return (bcd >> 4) * 10 + (bcd & 0x0F);
}

fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

fn daysInMonth(year: u16, month: u8) u8 {
    const days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeapYear(year)) return 29;
    return days[month - 1];
}

fn dateToUnixSeconds(year: u16, month: u8, day: u8, hour: u8, minute: u8, second: u8) u64 {
    var days: u64 = 0;
    var y: u16 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeapYear(y)) 366 else 365;
    }
    var m: u8 = 1;
    while (m < month) : (m += 1) {
        days += daysInMonth(year, m);
    }
    days += day - 1;
    return days * 86400 + @as(u64, hour) * 3600 + @as(u64, minute) * 60 + second;
}

fn readRtcUnixSeconds() ?u64 {
    // Wait until an update is not in progress.
    var timeout: u32 = 0;
    while (cmosRead(0x0A) & 0x80 != 0) {
        timeout += 1;
        if (timeout > 1_000_000) return null;
    }

    const reg_b = cmosRead(0x0B);
    const is_bcd = (reg_b & 0x04) == 0;
    const is_12h = (reg_b & 0x02) != 0;

    var second = cmosRead(0x00);
    var minute = cmosRead(0x02);
    const hour_raw = cmosRead(0x04);
    var day = cmosRead(0x07);
    var month = cmosRead(0x08);
    var year = cmosRead(0x09);

    // Re-check update-in-progress to avoid torn reads.
    if (cmosRead(0x0A) & 0x80 != 0) return null;

    var hour: u8 = undefined;
    if (is_bcd) {
        second = bcdToDec(second);
        minute = bcdToDec(minute);
        hour = bcdToDec(hour_raw & 0x7F);
        day = bcdToDec(day);
        month = bcdToDec(month);
        year = bcdToDec(year);
    } else {
        hour = hour_raw & 0x7F;
    }

    if (is_12h) {
        const pm = (hour_raw & 0x80) != 0;
        if (pm and hour != 12) hour += 12;
        if (!pm and hour == 12) hour = 0;
    }

    if (month < 1 or month > 12 or day < 1 or day > 31 or hour > 23 or minute > 59 or second > 59) {
        return null;
    }

    var full_year: u16 = @as(u16, 2000) + year;
    const century_reg = cmosRead(0x32);
    if (century_reg != 0) {
        const century = if (is_bcd) bcdToDec(century_reg) else century_reg;
        full_year = @as(u16, century) * 100 + year;
    } else if (year >= 70) {
        full_year = @as(u16, 1900) + year;
    }

    if (full_year < 1970) return null;

    return dateToUnixSeconds(full_year, month, day, hour, minute, second);
}
