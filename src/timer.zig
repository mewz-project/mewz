const std = @import("std");
const heap = @import("heap.zig");
const interrupt = @import("interrupt.zig");
const lapic = @import("lapic.zig");
const param = @import("param.zig");
const sync = @import("sync.zig");
const x64 = @import("x64.zig");
const net = @import("drivers/virtio/net.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.array_list.Managed;
const SpinLock = sync.SpinLock;

var timers_inner: ArrayList(*Timer) = undefined;
var timers: SpinLock(ArrayList(*Timer)) = undefined;

var boot_tsc: u64 = 0;
var boot_epoch_ns: u64 = 0;
var tsc_freq_hz: u64 = 0;

pub const IRQ_TIMER = 0;

const cmos_index_port: u16 = 0x70;
const cmos_data_port: u16 = 0x71;

const LAPIC_TCCR = 0x0390 / @sizeOf(u32);
const LAPIC_TICR = 0x0380 / @sizeOf(u32);
const lapic_timer_hz: u64 = 1000;
const lapic_calibration_wraps: u32 = 100;

pub const Timer = struct {
    ns: u64,
    clock_id: u32,
    is_finished_internal: bool = false,

    const Self = @This();

    pub fn newFromWasiClock(clock_id: u32, timeout: u64, absolute: bool) ?Self {
        const now = switch (clock_id) {
            0 => getRealtimeNanoSeconds(),
            1 => getMonotonicNanoSeconds(),
            else => return null,
        };
        return .{
            .ns = if (absolute) timeout else now + timeout,
            .clock_id = clock_id,
        };
    }

    pub fn register(self: *Self) Allocator.Error!void {
        try timers.acquire().*.append(self);
        timers.release();
    }

    pub fn isFinished(self: *Self) bool {
        return @atomicLoad(bool, &self.*.is_finished_internal, std.builtin.AtomicOrder.seq_cst);
    }

    pub fn nowNanoSeconds(self: *const Self) u64 {
        return switch (self.clock_id) {
            0 => getRealtimeNanoSeconds(),
            1 => getMonotonicNanoSeconds(),
            else => getMonotonicNanoSeconds(),
        };
    }

    pub fn isExpired(self: *const Self) bool {
        return self.nowNanoSeconds() >= self.ns;
    }
};

pub fn handleIrq(frame: *interrupt.InterruptFrame) void {
    _ = frame;

    var timer_list = timers.acquire();
    for (timer_list.items, 0..) |t, i| {
        if (t.isExpired()) {
            t.is_finished_internal = true;
            _ = timer_list.swapRemove(i);
        }
    }
    timers.release();

    net.flush();
}

fn calibrateTscFromLapicTimer() u64 {
    var last = lapic.lapic[LAPIC_TCCR];
    while (last == lapic.lapic[LAPIC_TICR]) {
        last = lapic.lapic[LAPIC_TCCR];
    }

    const start_tsc = x64.rdtsc();
    var wraps: u32 = 0;
    while (wraps < lapic_calibration_wraps) {
        const cur = lapic.lapic[LAPIC_TCCR];
        if (cur > last) wraps += 1;
        last = cur;
    }
    const tsc_delta = x64.rdtsc() - start_tsc;
    return (tsc_delta * lapic_timer_hz) / lapic_calibration_wraps;
}

fn detectTscFrequencyHz() u64 {
    if (x64.kvmTscFrequencyHz()) |hz| return hz;
    return calibrateTscFromLapicTimer();
}

pub fn init() void {
    tsc_freq_hz = detectTscFrequencyHz();
    boot_tsc = x64.rdtsc();

    const boot_unix_secs = readRtcUnixSeconds() orelse param.params.epoch orelse
        @panic("REALTIME unavailable: CMOS RTC read failed and no epoch= kernel parameter");
    boot_epoch_ns = boot_unix_secs * 1_000_000_000;

    timers_inner = ArrayList(*Timer).init(heap.runtime_allocator);
    timers = SpinLock(ArrayList(*Timer)).new(&timers_inner);

    interrupt.registerIrq(IRQ_TIMER, handleIrq);
}

fn tscToNanoSeconds(tsc: u64) u64 {
    const ns = (@as(u128, tsc) * 1_000_000_000) / @as(u128, tsc_freq_hz);
    return @intCast(ns);
}

pub fn getMonotonicNanoSeconds() u64 {
    return tscToNanoSeconds(x64.rdtsc() - boot_tsc);
}

pub fn getRealtimeNanoSeconds() u64 {
    return boot_epoch_ns + getMonotonicNanoSeconds();
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
