const Allocator = @import("std").mem.Allocator;

const heap = @import("heap.zig");
const log = @import("log.zig");
const stream = @import("stream.zig");
const sync = @import("sync.zig");
const lwip = @import("lwip.zig");
const util = @import("util.zig");
const virito_net = @import("drivers/virtio/net.zig");
const wasi = @import("wasi.zig");
const types = @import("wasi/types.zig");

const Stream = stream.Stream;

pub const IpAddr = extern struct {
    addr: u32,
};

pub const Socket = struct {
    pcb_addr: usize,
    buffer: sync.SpinLock(util.RingBuffer),
    waiter: sync.Waiter,
    fd: i32 = -1,
    flags: u16 = 0,
    is_connected: bool = false,
    is_read_shutdown: bool = false,
    is_write_shutdown: bool = false,
    is_listening: bool = false,

    const Self = @This();

    pub const Error = error{ Failed, Again };

    const BUFFER_SIZE: usize = 16384;

    pub fn new(af: wasi.AddressFamily, allocator: Allocator) Allocator.Error!Self {
        const buffer = try heap.runtime_allocator.create(util.RingBuffer);
        buffer.* = try util.RingBuffer.new(BUFFER_SIZE, allocator);
        var ret = Self{
            .pcb_addr = undefined,
            .buffer = sync.SpinLock(util.RingBuffer).new(buffer),
            .waiter = sync.Waiter.new(),
        };

        ret.pcb_addr = lwip.acquire().lwip_new_tcp_pcb(wasiToLwipAddressType(af));
        lwip.release();

        return ret;
    }

    pub fn newFromPcb(pcb: *anyopaque, allocator: Allocator) Allocator.Error!Self {
        const buffer = try heap.runtime_allocator.create(util.RingBuffer);
        buffer.* = try util.RingBuffer.new(BUFFER_SIZE, allocator);
        const ret = Self{
            .pcb_addr = @intFromPtr(pcb),
            .buffer = sync.SpinLock(util.RingBuffer).new(buffer),
            .waiter = sync.Waiter.new(),
        };

        return ret;
    }

    pub fn bind(self: *Self, ip_addr: *anyopaque, port: i32) Error!void {
        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));
        const err = lwip.acquire().lwip_tcp_bind(pcb, ip_addr, port);
        lwip.release();
        if (err != 0) {
            return Error.Failed;
        }
    }

    pub fn listen(self: *Self, backlog: i32) Error!void {
        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));

        const new_pcb_ptr = lwip.acquire().tcp_listen_with_backlog(pcb, @as(u8, @intCast(backlog)));
        lwip.release();
        if (new_pcb_ptr == null) {
            return Error.Failed;
        }
        self.pcb_addr = @intFromPtr(new_pcb_ptr);

        lwip.acquire().lwip_accept(new_pcb_ptr.?);
        lwip.release();

        self.is_listening = true;

        return;
    }

    pub fn accept(self: *Self) Error!i32 {
        var sock_buf = self.buffer.acquire();
        if (sock_buf.availableToRead() > 0) {
            var buf = [4]u8{ 0, 0, 0, 0 };
            if (sock_buf.read(buf[0..]) != 4) {
                @panic("accept: new file descriptor not found");
            }
            self.buffer.release();
            const new_fd = @as(*i32, @alignCast(@ptrCast(buf[0..].ptr)));
            return new_fd.*;
        }

        if (self.isNonBlocking()) {
            self.buffer.release();
            return Error.Again;
        }

        self.waiter.setWait();
        self.buffer.release();

        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));
        lwip.acquire().lwip_accept(pcb);
        lwip.release();

        self.waiter.wait();

        return self.accept();
    }

    pub fn read(self: *Self, buffer: []u8) Stream.Error!usize {
        // if not connected, simply return read buffer even if it is empty
        if (!self.is_connected) {
            const size = self.buffer.acquire().read(buffer);
            self.buffer.release();
            return size;
        }

        const size = self.buffer.acquire().read(buffer);
        if (size > 0) {
            self.buffer.release();
            return size;
        }

        if (self.isNonBlocking()) {
            self.buffer.release();
            return Stream.Error.Again;
        }

        self.waiter.setWait();
        self.buffer.release();
        self.waiter.wait();
        return self.read(buffer);
    }

    pub fn send(self: *Self, buffer: []u8) Error!usize {
        const locked_lwip = lwip.acquire();
        defer lwip.release();

        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));

        const len = @min(buffer.len, locked_lwip.lwip_tcp_sndbuf(pcb));
        const err = locked_lwip.lwip_send(pcb, buffer.ptr, len);
        if (err < 0) {
            log.debug.printf("lwip_send failed: {d}\n", .{err});
            return Error.Failed;
        }

        return len;
    }

    pub fn connect(self: *Self, ip_addr: *anyopaque, port: i32) Error!void {
        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));
        self.waiter.setWait();
        const err = lwip.acquire().lwip_connect(pcb, ip_addr, port);
        lwip.release();

        if (err != 0) {
            return Error.Failed;
        }
        self.waiter.wait();

        return;
    }

    pub fn shutdown(self: *Self, read_close: bool, write_close: bool) Error!void {
        if (self.alreadyClosed()) {
            return;
        }

        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));
        const read_flag: i32 = if (read_close) 1 else 0;
        const write_flag: i32 = if (write_close) 1 else 0;

        // ensure releasing pcb and unsetting fd are done atomically
        const locked_lwip = lwip.acquire();
        defer lwip.release();

        const err = locked_lwip.tcp_shutdown(pcb, read_flag, write_flag);
        if (err != 0) {
            return Error.Failed;
        }

        if (read_close) {
            self.is_read_shutdown = true;
        }
        if (write_close) {
            self.is_write_shutdown = true;
        }

        if (self.alreadyClosed()) {
            locked_lwip.lwip_unset_fd(@as(*anyopaque, @ptrFromInt(self.pcb_addr)));
        }

        return;
    }

    pub fn close(self: *Self) Error!void {
        if (!self.alreadyClosed()) {
            // ensure releasing pcb and unsetting fd are done atomically
            const locked_lwip = lwip.acquire();
            defer lwip.release();

            const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));
            const err = locked_lwip.lwip_tcp_close(pcb);
            if (err != 0) {
                return Error.Failed;
            }

            locked_lwip.lwip_unset_fd(@as(*anyopaque, @ptrFromInt(self.pcb_addr)));
        }

        self.waiter.waiting = false;
        self.is_connected = false;

        self.buffer.acquire().deinit(heap.runtime_allocator);
        self.buffer.release();
        heap.runtime_allocator.destroy(@as(*util.RingBuffer, @alignCast(@ptrCast(self.buffer.ptr))));
    }

    pub fn getRemoteAddr(self: *Self) *IpAddr {
        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));
        const addr = lwip.acquire().lwip_get_remote_ip(pcb);
        lwip.release();
        return addr;
    }

    pub fn getLocalAddr(self: *Self) *IpAddr {
        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));
        const addr = lwip.acquire().lwip_get_local_ip(pcb);
        lwip.release();
        return addr;
    }

    pub fn getRemotePort(self: *Self) u16 {
        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));
        const port = lwip.acquire().lwip_get_remote_port(pcb);
        lwip.release();
        return port;
    }

    pub fn getLocalPort(self: *Self) u16 {
        const pcb = @as(*anyopaque, @ptrFromInt(self.pcb_addr));
        const port = lwip.acquire().lwip_get_local_port(pcb);
        lwip.release();
        return port;
    }

    pub fn setFd(self: *Self, fd: i32) void {
        self.fd = fd;
        lwip.acquire().lwip_set_fd(@as(*anyopaque, @ptrFromInt(self.pcb_addr)), &self.fd);
        lwip.release();
    }

    pub fn bytesCanRead(self: *Self) ?usize {
        const buf = self.buffer.acquire();
        defer self.buffer.release();
        const nbytes = buf.availableToRead();

        if (nbytes == 0) {
            if (!self.is_listening and !self.is_connected) {
                return 0;
            }

            return null;
        }

        // if the socket is listening, return the number of connections available
        if (self.is_listening) {
            return nbytes / 4;
        }

        return nbytes;
    }

    pub fn bytesCanWrite(self: *Self) ?usize {
        if (!self.is_listening and !self.is_connected) {
            return 0;
        }

        const buf = self.buffer.acquire();
        defer self.buffer.release();
        const nbytes = buf.availableToWrite();

        if (nbytes == 0) {
            return null;
        }

        return nbytes;
    }

    fn alreadyClosed(self: *Self) bool {
        return self.is_read_shutdown and self.is_write_shutdown;
    }

    fn isNonBlocking(self: *Self) bool {
        return self.flags & types.FdFlag.NonBlock.toInt() != 0;
    }
};

fn wasiToLwipAddressType(t: wasi.AddressFamily) u8 {
    switch (t) {
        wasi.AddressFamily.INET4 => return 0,
        wasi.AddressFamily.INET6 => return 6,
        wasi.AddressFamily.Unspec => return 46,
    }
}

pub extern fn init() void;

export fn transmit(addr: [*c]u8, size: u32) callconv(.C) void {
    const data = addr[0..size];
    virito_net.virtio_net.transmit(data);
}

export fn socketPush(fd: i32, ptr: [*]u8, len: usize) i32 {
    const s = stream.fd_table.get(fd) orelse @panic("socketPush: invalid fd");
    var socket = switch (s.*) {
        stream.Stream.socket => &s.socket,
        else => @panic("socketPush: invalid fd"),
    };

    const buffer = ptr[0..len];
    const sock_buf = socket.buffer.acquire();
    defer socket.buffer.release();
    sock_buf.write(buffer) catch return -1;
    return 0;
}

export fn notifyAccepted(pcb: *anyopaque, fd: i32) callconv(.C) ?*i32 {
    // unset waiter
    const s = stream.fd_table.get(fd) orelse @panic("notifyAccepted: invalid fd");
    var socket = switch (s.*) {
        stream.Stream.socket => &s.socket,
        else => @panic("notifyAccepted: invalid fd"),
    };
    socket.waiter.waiting = false;

    // create new socket
    var new_socket = Socket.newFromPcb(pcb, heap.runtime_allocator) catch return null;
    new_socket.is_connected = true;
    const new_fd = stream.fd_table.set(Stream{ .socket = new_socket }) catch return null;
    var set_stream = stream.fd_table.get(new_fd) orelse @panic("notifyConnected: new_socket is not set");
    const set_socket = &set_stream.socket;

    return &set_socket.*.fd;
}

// This function is called when in the lwIP receive callback.
// It notifies the socket that data is available by setting the waiter.
export fn notifyReceived(fd: i32) callconv(.C) void {
    const s = stream.fd_table.get(fd) orelse @panic("notifyConnected: invalid fd");
    var socket = switch (s.*) {
        stream.Stream.socket => &s.socket,
        else => @panic("notifyReceived: invalid fd"),
    };

    // This function is called from the interrupt handler,
    // so we don't need to make it atomic.
    socket.waiter.waiting = false;
}

export fn notifyConnected(fd: i32) callconv(.C) void {
    const s = stream.fd_table.get(fd) orelse @panic("notifyConnected: invalid fd");
    var socket = switch (s.*) {
        stream.Stream.socket => &s.socket,
        else => @panic("notifyConnected: invalid fd"),
    };
    socket.is_connected = true;
    socket.waiter.waiting = false;
}

export fn notifyClosed(fd: i32) callconv(.C) void {
    // if the socket is already closed, just return
    const s = stream.fd_table.get(fd) orelse return;
    var socket = switch (s.*) {
        stream.Stream.socket => &s.socket,
        else => @panic("notifyClosed: invalid fd"),
    };
    socket.is_connected = false;
    socket.waiter.waiting = false;
}

export fn notifyError(fd: i32, err: i32) callconv(.C) void {
    _ = err;

    // if the socket is already closed, just return
    const s = stream.fd_table.get(fd) orelse return;
    var socket = switch (s.*) {
        stream.Stream.socket => &s.socket,
        else => @panic("notifyError: invalid fd"),
    };

    socket.waiter.waiting = false;
    socket.is_connected = false;
    socket.is_read_shutdown = true;
    socket.is_write_shutdown = true;
}
