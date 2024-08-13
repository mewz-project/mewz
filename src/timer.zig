const std = @import("std");
const heap = @import("heap.zig");
const interrupt = @import("interrupt.zig");
const sync = @import("sync.zig");
const net = @import("drivers/virtio/net.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const SpinLock = sync.SpinLock;

var timers_inner: ArrayList(*Timer) = undefined;
var timers: SpinLock(ArrayList(*Timer)) = undefined;

var ticks_internal: u64 = 0;
var ticks = SpinLock(u64).new(&ticks_internal);

pub const IRQ_TIMER = 0;
const frequency = 1000; // TODO: measure frequency while booting

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
            .ns = getNanoSeconds() + ns,
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
        if (timer.ns <= getNanoSeconds()) {
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
}

pub fn getNanoSeconds() u64 {
    const t = ticks.acquire().*;
    ticks.release();
    return t * (1000000000 / frequency);
}

pub fn unregisterAll() void {
    timers.acquire().*.clearRetainingCapacity();
    timers.release();
}

export fn sys_now() callconv(.C) i32 {
    return @as(i32, @intCast(getNanoSeconds() / 1000000));
}
