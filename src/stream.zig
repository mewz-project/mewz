const fs = @import("fs.zig");
const log = @import("log.zig");
const uart = @import("uart.zig");
const tcpip = @import("tcpip.zig");
const sync = @import("sync.zig");

const Directory = fs.Directory;
const Socket = tcpip.Socket;
const SpinLock = sync.SpinLock;
const OpenedFile = fs.OpenedFile;

const STREAM_NUM = 2048;

var streams_internal: [STREAM_NUM]?Stream = init: {
    var initial_fd_table: [STREAM_NUM]?Stream = undefined;
    // set stdin, stdout, and stderr to the uart
    initial_fd_table[0] = Stream{ .uart = void{} };
    initial_fd_table[1] = Stream{ .uart = void{} };
    initial_fd_table[2] = Stream{ .uart = void{} };
    break :init initial_fd_table;
};

// thread safe file descriptor table
pub var fd_table = FdTable{ .streams = SpinLock([STREAM_NUM]?Stream).new(&streams_internal) };

const FdTable = struct {
    streams: SpinLock([STREAM_NUM]?Stream),
    index: usize = 0,

    const Self = @This();

    pub fn get(self: *Self, fd: i32) ?*Stream {
        const streams = self.streams.acquire();
        defer self.streams.release();
        const s = &streams.*[@as(usize, @intCast(fd))];
        if (s.* == null) {
            return null;
        }

        return @as(*Stream, @ptrCast(s));
    }

    // If the stream has fd field, it will be set to the new fd
    pub fn set(self: *Self, stream: Stream) Stream.Error!i32 {
        const streams = self.streams.acquire();
        defer self.streams.release();
        var i = (self.index + 1) % STREAM_NUM;
        defer self.index = i;

        while (i != self.index) : (i = (i + 1) % STREAM_NUM) {
            if (streams.*[i] == null) {
                streams.*[i] = stream;
                const set_stream = &streams.*[i];

                const new_fd = @as(i32, @intCast(i));
                switch (set_stream.*.?) {
                    Stream.uart => {},
                    Stream.socket => |*sock| {
                        sock.setFd(new_fd);
                    },
                    Stream.opened_file => {},
                    Stream.dir => {},
                }

                return new_fd;
            }
        }

        return Stream.Error.FdFull;
    }

    pub fn remove(self: *Self, fd: i32) void {
        const streams = self.streams.acquire();
        defer self.streams.release();
        streams.*[@as(usize, @intCast(fd))] = null;
    }
};

pub const Stream = union(enum) {
    uart: void,
    socket: Socket,
    opened_file: OpenedFile,
    dir: Directory,

    const Self = @This();

    pub const Error = error{FdFull} || Socket.Error;

    pub fn read(self: *Self, buffer: []u8) Error!usize {
        return switch (self.*) {
            Self.uart => @panic("read on uart unimplemented"),
            Self.socket => |*sock| sock.read(buffer),
            Self.opened_file => |*f| f.read(buffer),
            Self.dir => @panic("read on dir unimplemented"),
        };
    }

    pub fn write(self: *Self, buffer: []u8) Error!usize {
        return switch (self.*) {
            Self.uart => uart.write(buffer),
            Self.socket => |*sock| sock.send(buffer),
            Self.opened_file => @panic("write on opened_file unimplemented"),
            Self.dir => @panic("write on dir unimplemented"),
        };
    }

    pub fn close(self: *Self) Error!void {
        return switch (self.*) {
            Self.uart => @panic("close on uart unimplemented"),
            Self.socket => |*sock| sock.close(),
            Self.opened_file => {},
            Self.dir => {},
        };
    }

    pub fn flags(self: *Self) u16 {
        return switch (self.*) {
            Self.uart => 0,
            Self.socket => 0,
            Self.opened_file => 0,
            Self.dir => 0,
        };
    }

    pub fn setFlags(self: *Self, f: u16) void {
        switch (self.*) {
            Self.uart => {
                log.warn("set flags on uart unimplemented");
            },
            Self.socket => |*sock| sock.*.flags |= f,
            Self.opened_file => @panic("set flags on opened_file unimplemented"),
            Self.dir => @panic("set flags on dir unimplemented"),
        }
    }

    pub fn bytesCanRead(self: *Self) ?usize {
        return switch (self.*) {
            Self.uart => 1,
            Self.socket => |*sock| sock.bytesCanRead(),
            Self.opened_file => |*f| f.inner.data.len - f.pos,
            Self.dir => 0,
        };
    }

    pub fn bytesCanWrite(self: *Self) ?usize {
        return switch (self.*) {
            Self.uart => 1,
            Self.socket => |*sock| sock.bytesCanWrite(),
            Self.opened_file => 0,
            Self.dir => 0,
        };
    }

    pub fn size(self: *Self) usize {
        return switch (self.*) {
            Self.uart => 0,
            Self.socket => 0,
            Self.opened_file => |*f| f.inner.data.len,
            Self.dir => 0,
        };
    }
};
