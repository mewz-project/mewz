const heap = @import("heap.zig");
const stream = @import("stream.zig");
const timer = @import("timer.zig");
const types = @import("wasi/types.zig");

const WasiError = types.WasiError;
const WasiSubscription = types.Subscription;
const Event = types.Event;
const EventFdReadwrite = types.EventFdReadwrite;
const EventType = types.EventType;

const Stream = stream.Stream;
const Timer = timer.Timer;

const Subscription = struct {
    target: Target,
    userdata: u64,

    const Self = @This();

    pub fn toEvent(self: *Self) ?Event {
        switch (self.target) {
            .fd_read => |s| {
                const nbytes = s.bytesCanRead();
                if (nbytes > 0) {
                    return Event{
                        .userdata = self.userdata,
                        .err = WasiError.SUCCESS.toU16(),
                        .eventtype = EventType.fd_read.toInt(),
                        .event_fd_readwrite = EventFdReadwrite{
                            .nbytes = nbytes,
                            .flags = s.flags(),
                        },
                    };
                } else {
                    return null;
                }
            },
            .fd_write => |s| {
                const nbytes = s.bytesCanWrite();
                if (nbytes > 0) {
                    return Event{
                        .userdata = self.userdata,
                        .err = WasiError.SUCCESS.toU16(),
                        .eventtype = EventType.fd_write.toInt(),
                        .event_fd_readwrite = EventFdReadwrite{
                            .nbytes = nbytes,
                            .flags = s.flags(),
                        },
                    };
                } else {
                    return null;
                }
            },
            .clock => |c| {
                if (c.isFinished()) {
                    return Event{
                        .userdata = self.userdata,
                        .err = WasiError.SUCCESS.toU16(),
                        .eventtype = EventType.clock.toInt(),
                        .event_fd_readwrite = EventFdReadwrite{ .nbytes = 0, .flags = 0 },
                    };
                } else {
                    return null;
                }
            },
        }
    }
};

const Target = union(enum) {
    fd_read: *Stream,
    fd_write: *Stream,
    clock: *Timer,
};

pub fn poll(wasi_subscriptions: []WasiSubscription, events: []Event, nsubscriptions: i32) i32 {
    var nevents: usize = 0;
    // FIXME: Can we avoid allocating this?
    var subscriptions = heap.runtime_allocator.alloc(?Subscription, @as(usize, @intCast(nsubscriptions))) catch @panic("failed to allocate memory for subscriptions: out of memory");

    defer heap.runtime_allocator.free(subscriptions);
    // WARNING: Timers are registered only in this function,
    // so we can unregister all timers here.
    defer timer.unregisterAll();

    for (wasi_subscriptions, 0..) |sub, i| {
        const eventtype = EventType.fromInt(sub.content.tag);
        if (eventtype == null) {
            events[nevents] = Event{
                .userdata = sub.userdata,
                .err = WasiError.INVAL.toU16(),
                .eventtype = sub.content.tag,
                .event_fd_readwrite = EventFdReadwrite{ .nbytes = 0, .flags = 0 },
            };
            nevents += 1;
            continue;
        }
        switch (eventtype.?) {
            EventType.fd_read, EventType.fd_write => {
                const fd = if (eventtype.? == EventType.fd_read)
                    sub.content.type.fd_read.fd
                else
                    sub.content.type.fd_write.fd;

                const s = stream.fd_table.get(fd);
                if (s == null) {
                    events[nevents] = Event{
                        .userdata = sub.userdata,
                        .err = WasiError.BADF.toU16(),
                        .eventtype = eventtype.?.toInt(),
                        .event_fd_readwrite = EventFdReadwrite{ .nbytes = 0, .flags = 0 },
                    };
                    nevents += 1;
                    continue;
                }

                const target = if (eventtype.? == EventType.fd_read)
                    Target{ .fd_read = s.? }
                else
                    Target{ .fd_write = s.? };

                subscriptions[i] = Subscription{
                    .target = target,
                    .userdata = sub.userdata,
                };
            },
            EventType.clock => {
                var t = if (sub.content.type.clock.isAbsolute())
                    timer.Timer.newByAbsoluteTime(sub.content.type.clock.timeout)
                else
                    timer.Timer.newByRelativeTime(sub.content.type.clock.timeout);
                t.register() catch @panic("failed to register timer: out of memory");

                subscriptions[i] = Subscription{
                    .target = Target{
                        .clock = &t,
                    },
                    .userdata = sub.userdata,
                };
            },
        }
    }

    while (nevents == 0) {
        for (subscriptions) |s| {
            var sub = s orelse continue;
            const event = sub.toEvent() orelse continue;
            events[nevents] = event;
            nevents += 1;
        }
    }

    return @as(i32, @intCast(nevents));
}
