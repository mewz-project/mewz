const builtin = @import("std").builtin;
const x64 = @import("x64.zig");

var interrupt_enabled: bool = false;

pub fn SpinLock(comptime T: type) type {
    return struct {
        locked: bool,
        ptr: *anyopaque,

        const This = @This();

        pub fn new(ptr: *T) This {
            return This{ .locked = false, .ptr = @as(*anyopaque, @alignCast(@ptrCast(ptr))) };
        }

        pub fn acquire(this: *volatile This) *T {
            pushcli();
            if (this.locked) {
                @panic("deadlock");
            }

            while (@atomicRmw(bool, &this.locked, builtin.AtomicRmwOp.Xchg, true, builtin.AtomicOrder.Acquire)) {}

            return @as(*T, @alignCast(@ptrCast(this.ptr)));
        }

        pub fn release(this: *volatile This) void {
            _ = @atomicRmw(bool, &this.locked, builtin.AtomicRmwOp.Xchg, false, builtin.AtomicOrder.Release);

            popcli();
        }
    };
}

pub const Waiter = struct {
    waiting: bool,

    const Self = @This();

    pub fn new() Self {
        return Self{ .waiting = false };
    }

    pub fn setWait(self: *volatile Self) void {
        @atomicStore(bool, &self.waiting, true, builtin.AtomicOrder.SeqCst);
    }

    pub fn wait(self: *volatile Self) void {
        while (true) {
            while (self.waiting) {}
            if (!@atomicLoad(bool, &self.waiting, builtin.AtomicOrder.SeqCst)) {
                break;
            }
        }

        return;
    }
};

var ncli: u32 = 0;

pub fn pushcli() void {
    const eflags = x64.readeflags();
    x64.cli();

    if (ncli == 0) {
        interrupt_enabled = (eflags & x64.EFLAGS_IF) != 0;
    }

    ncli += 1;
}

pub fn popcli() void {
    ncli -= 1;

    if (ncli == 0 and interrupt_enabled) {
        x64.sti();
    }
}
