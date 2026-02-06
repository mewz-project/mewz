const std = @import("std");
const Allocator = std.mem.Allocator;

const heap = @import("heap.zig");
const fs = @import("fs.zig");
const http_client = @import("http_client.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const poll = @import("poll.zig");
const rand = @import("rand.zig");
const stream = @import("stream.zig");
const tcpip = @import("tcpip.zig");
const timer = @import("timer.zig");
const types = @import("wasi/types.zig");
const x64 = @import("x64.zig");

const Client = http_client.Client;
const Request = http_client.Request;
const Stream = stream.Stream;
const WasiError = types.WasiError;
const ShutdownFlag = types.ShutdownFlag;
const IoVec = types.IoVec;
const FdStat = types.FdStat;
const Prestat = types.Prestat;
const FileType = types.FileType;
const FdFlag = types.FdFlag;
pub const AddressFamily = types.AddressFamily;
const SocketType = types.SocketType;

const linear_memory_offset: usize = 0xffff800000000000;

var linear_memory_top: usize = linear_memory_offset;
var linear_memory_block_num: usize = 0;

pub export fn memory_grow(num: usize) callconv(.c) usize {
    log.debug.printf("WASI memory_grow: {d}\n", .{num});
    const old_num = linear_memory_block_num;
    for (0..num) |_| {
        _ = mem.allocAndMapBlock(linear_memory_top);
        linear_memory_top += mem.BLOCK_SIZE;
    }
    linear_memory_block_num += num;

    return old_num;
}

pub export fn memory_base() callconv(.c) usize {
    log.debug.printf("WASI memory_base\n", .{});
    return linear_memory_offset;
}

pub export fn clock_time_get(clock_id: i32, precision: i64, time_addr: i32) WasiError {
    log.debug.printf("WASI clock_time_get: {d} {d} {d}\n", .{ clock_id, precision, time_addr });
    const time_ptr = @as(*u64, @ptrFromInt(@as(usize, @intCast(time_addr)) + linear_memory_offset));
    time_ptr.* = timer.getNanoSeconds();
    return WasiError.SUCCESS;
}

// env_addrs: a pointer to an array of pointers to each environment variable, formed like KEY=VALUE\0
// env_buf_addr: a pointer to a buffer that will be filled with the environment variables, formed like KEY=VALUE\0KEY=VALUE\0
pub export fn environ_get(env_addrs: i32, env_buf_addr: i32) WasiError {
    log.debug.printf("WASI environ_get: {d} {d}\n", .{ env_addrs, env_buf_addr });
    return WasiError.SUCCESS;
}

// env_count_addr: a pointer to an integer that will be filled with the number of environment variables
// env_buf_size_addr: a pointer to an integer that will be filled with the size of the buffer needed to hold all environment variables
pub export fn environ_sizes_get(env_count_addr: i32, env_buf_size_addr: i32) WasiError {
    log.debug.printf("WASI environ_sizes_get: {d} {d}\n", .{ env_count_addr, env_buf_size_addr });
    const env_count_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(env_count_addr)) + linear_memory_offset));
    const env_buf_size_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(env_buf_size_addr)) + linear_memory_offset));

    env_count_ptr.* = 0;
    env_buf_size_ptr.* = 0;

    return WasiError.SUCCESS;
}

pub export fn fd_write(fd: i32, buf_iovec_addr: i32, vec_len: i32, size_addr: i32) callconv(.c) WasiError {
    log.debug.printf("WASI fd_write: {d} {d} {d} {d}\n", .{ fd, buf_iovec_addr, vec_len, size_addr });

    @setRuntimeSafety(false);

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;

    var iovec_ptr = @as([*]IoVec, @ptrFromInt(@as(usize, @intCast(buf_iovec_addr)) + linear_memory_offset));
    const iovecs = iovec_ptr[0..@as(usize, @intCast(vec_len))];

    if (iovecs.len == 1) {
        // fast path: avoid memory allocation and copy
        const addr = @as(usize, @intCast(iovecs[0].buf)) + linear_memory_offset;
        const len = @as(usize, @intCast(iovecs[0].buf_len));
        const buf = @as([*]u8, @ptrFromInt(addr))[0..len];
        const nwritten = s.write(buf) catch return WasiError.INVAL;
        const size_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(size_addr)) + linear_memory_offset));
        size_ptr.* = @as(i32, @intCast(nwritten));
        return WasiError.SUCCESS;
    }

    const buf = ioVecsToSlice(iovecs, heap.runtime_allocator) catch return WasiError.NOMEM;
    defer heap.runtime_allocator.free(buf);

    const len = s.write(buf) catch return WasiError.INVAL;

    const size_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(size_addr)) + linear_memory_offset));
    size_ptr.* = @as(i32, @intCast(len));

    return WasiError.SUCCESS;
}

pub export fn fd_read(fd: i32, buf_iovec_addr: i32, vec_len: i32, size_addr: i32) callconv(.c) WasiError {
    log.debug.printf("WASI fd_read: fd={d} buf_iovec_addr=0x{x} vec_len={d} size_addr=0x{x}\n", .{ fd, buf_iovec_addr, vec_len, size_addr });

    @setRuntimeSafety(false);

    // get stream from fd
    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;

    var iovec_ptr = @as([*]IoVec, @ptrFromInt(@as(usize, @intCast(buf_iovec_addr)) + linear_memory_offset));
    const iovecs = iovec_ptr[0..@as(usize, @intCast(vec_len))];

    var buf: []u8 = undefined;
    if (iovecs.len == 1) {
        // fast path: avoid memory allocation and copy
        const addr = @as(usize, @intCast(iovecs[0].buf)) + linear_memory_offset;
        const len = @as(usize, @intCast(iovecs[0].buf_len));
        buf = @as([*]u8, @ptrFromInt(addr))[0..len];
    } else {
        buf = heap.runtime_allocator.alloc(u8, totalSizeOfIoVecs(iovecs)) catch return WasiError.NOMEM;
    }

    const size_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(size_addr)) + linear_memory_offset));

    const nread = s.read(buf) catch |err| {
        switch (err) {
            tcpip.Socket.Error.Again => return WasiError.AGAIN,
            else => return WasiError.INVAL,
        }
    };

    if (iovecs.len > 1) {
        _ = copySliceToIoVecs(buf, iovecs);
        heap.runtime_allocator.free(buf);
    }

    size_ptr.* = @as(i32, @intCast(nread));

    return WasiError.SUCCESS;
}

pub export fn fd_close(fd: i32) callconv(.c) WasiError {
    log.debug.printf("WASI fd_close: {d}\n", .{fd});
    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    s.close() catch return WasiError.BADF;
    stream.fd_table.remove(fd);
    return WasiError.SUCCESS;
}

pub export fn fd_filestat_get(fd: i32, filestat_addr: i32) callconv(.c) WasiError {
    log.debug.printf("WASI fd_filestat_get: {d} {d}\n", .{ fd, filestat_addr });

    var filestat_ptr = @as(*types.FileStat, @ptrFromInt(@as(usize, @intCast(filestat_addr)) + linear_memory_offset));
    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;

    filestat_ptr.dev = 0;
    filestat_ptr.ino = 0;
    filestat_ptr.file_type = FileType.fromStream(s);
    filestat_ptr.nlink = 0;
    filestat_ptr.size = @as(u64, @intCast(s.size()));
    filestat_ptr.atim = 0;
    filestat_ptr.mtim = 0;
    filestat_ptr.ctim = 0;

    return WasiError.SUCCESS;
}

pub export fn fd_fdstat_get(fd: i32, fdstat_addr: i32) callconv(.c) WasiError {
    log.debug.printf("WASI fd_fdstat_get: {d} {d}\n", .{ fd, fdstat_addr });

    var fdstat_ptr = @as(*FdStat, @ptrFromInt(@as(usize, @intCast(fdstat_addr)) + linear_memory_offset));
    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    fdstat_ptr.file_type = FileType.fromStream(s);
    fdstat_ptr.flags = s.flags();
    fdstat_ptr.rights_base = types.FULL_RIGHTS;
    fdstat_ptr.rights_inheriting = types.FULL_RIGHTS;

    return WasiError.SUCCESS;
}

pub export fn fd_fdstat_set_flags(fd: i32, flags: i32) callconv(.c) WasiError {
    log.debug.printf("WASI fd_fdstat_set_flags: {d} {d}\n", .{ fd, flags });

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    s.setFlags(@as(u16, @bitCast(@as(i16, @truncate(flags)))));
    return WasiError.SUCCESS;
}

pub export fn fd_prestat_get(fd: i32, prestat_addr: i32) callconv(.c) WasiError {
    log.debug.printf("WASI fd_prestat_get: {d} {d}\n", .{ fd, prestat_addr });
    var prestat_ptr = @as(*Prestat, @ptrFromInt(@as(usize, @intCast(prestat_addr)) + linear_memory_offset));

    // get stream from fd
    const s = stream.fd_table.get(fd) orelse return WasiError.BADF;

    // if fd is Directory, return prestat
    switch (s.*) {
        Stream.dir => {
            const dir = s.dir;
            prestat_ptr.tag = 0; // __WASI_PREOPENTYPE_DIR
            prestat_ptr.pr_name_len = @as(u32, @intCast(dir.name.len));
            return WasiError.SUCCESS;
        },
        else => return WasiError.BADF,
    }
}

pub export fn fd_prestat_dir_name(fd: i32, path_addr: i32, max_path_len: i32) WasiError {
    log.debug.printf("WASI fd_prestat_dir_name: {d} {d} {d}\n", .{ fd, path_addr, max_path_len });

    // get stream from fd
    const s = stream.fd_table.get(fd) orelse return WasiError.BADF;

    // if fd is Directory, return it's name
    switch (s.*) {
        Stream.dir => {
            const dir = s.dir;

            const path_name = dir.name;
            const len = @min(@as(usize, @intCast(max_path_len)), path_name.len);

            var path_ptr = @as([*]u8, @ptrFromInt(@as(usize, @intCast(path_addr)) + linear_memory_offset));

            @memcpy(path_ptr[0..len], path_name[0..len]);

            return WasiError.SUCCESS;
        },
        else => return WasiError.BADF,
    }
}

pub export fn path_open(fd: i32, dirflags: i32, path_addr: i32, path_length: i32, oflags: i32, rights_base: i64, rights_inferiting: i64, fdflags: i32, opened_fd_addr: i32) WasiError {
    log.debug.printf("WASI path_open: fd:{d}, dirflags:{d}, path_offset:{d}, path_length:{d}, oflags:{d}, rights_bas:{d}, rights_inferiting:{d}, fdflags:{d}, opened_fd_addr:{d}\n", .{ fd, dirflags, path_addr, path_length, oflags, rights_base, rights_inferiting, fdflags, opened_fd_addr });

    // get path name
    var path_ptr = @as([*]u8, @ptrFromInt(@as(usize, @intCast(path_addr)) + linear_memory_offset));
    const path_name = path_ptr[0..@as(usize, @intCast(path_length))];

    log.debug.printf("file path: {s}\n", .{path_name});

    // get stream from fd
    const s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    const dir = switch (s.*) {
        Stream.dir => |*d| d,
        else => return WasiError.BADF,
    };

    // search file by name
    const regular_file = dir.getFileByName(path_name) orelse return WasiError.NOENT;

    // open file
    const opened_file = fs.OpenedFile{
        .inner = regular_file,
        .pos = 0,
    };
    const new_fd = stream.fd_table.set(Stream{ .opened_file = opened_file }) catch return WasiError.NOMEM;

    // return opened fd
    const return_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(opened_fd_addr)) + linear_memory_offset));
    return_ptr.* = new_fd;
    return WasiError.SUCCESS;
}

pub export fn random_get(addr: i32, l: i32) WasiError {
    log.debug.printf("WASI random_get: {d} {d}\n", .{ addr, l });

    const len = @as(usize, @intCast(l));
    const buf = @as([*]u8, @ptrFromInt(@as(usize, @intCast(addr)) + linear_memory_offset))[0..len];
    rand.X64Random.bytes(buf);

    return WasiError.SUCCESS;
}

pub export fn poll_oneoff(
    input_addr: i32,
    output_addr: i32,
    nsubscriptions: i32,
    nevents_addr: i32,
) callconv(.c) WasiError {
    log.debug.printf("WASI poll_oneoff: {d} {d} {d} {d}\n", .{ input_addr, output_addr, nsubscriptions, nevents_addr });

    const subscriptions = @as([*]types.Subscription, @ptrFromInt(@as(usize, @intCast(input_addr)) + linear_memory_offset))[0..@as(usize, @intCast(nsubscriptions))];
    const events = @as([*]types.Event, @ptrFromInt(@as(usize, @intCast(output_addr)) + linear_memory_offset))[0..@as(usize, @intCast(nsubscriptions))];
    const nevents = @as(*i32, @ptrFromInt(@as(usize, @intCast(nevents_addr)) + linear_memory_offset));

    nevents.* = poll.poll(subscriptions, events, nsubscriptions);

    return WasiError.SUCCESS;
}

pub export fn proc_exit(status: i32) callconv(.c) void {
    log.debug.printf("WASI proc_exit: {d}\n", .{status});

    x64.shutdown(@as(u16, @intCast(status)));
    unreachable;
}

pub export fn sched_yield() callconv(.c) WasiError {
    log.debug.printf("WASI sched_yield\n", .{});

    return WasiError.SUCCESS;
}

pub export fn sock_open(
    family: AddressFamily,
    typ: SocketType,
    fd_addr: i32,
) callconv(.c) WasiError {
    log.debug.printf("WASI sock_open: {d} {d} {d}\n", .{ @intFromEnum(family), @intFromEnum(typ), fd_addr });

    const fd = @as(*i32, @ptrFromInt(@as(usize, @intCast(fd_addr)) + linear_memory_offset));

    // TODO: support UDP
    // TODO: return error code
    switch (typ) {
        SocketType.Stream => {},
        else => return WasiError.INVAL,
    }

    switch (family) {
        AddressFamily.INET4 => {},
        else => return WasiError.INVAL,
    }

    const socket = tcpip.Socket.new(family, heap.runtime_allocator) catch return WasiError.NOMEM;
    fd.* = stream.fd_table.set(Stream{ .socket = socket }) catch return WasiError.NOMEM;

    return WasiError.SUCCESS;
}

pub export fn sock_bind(
    fd: i32,
    ip_iovec_addr: i32,
    port: i32,
) callconv(.c) WasiError {
    log.debug.printf("WASI sock_bind: {d} {d} {d}\n", .{ fd, ip_iovec_addr, port });

    @setRuntimeSafety(false);

    const ip_iovec = @as(*IoVec, @ptrFromInt(@as(usize, @intCast(ip_iovec_addr)) + linear_memory_offset));
    const ip_addr_ptr = @as(*anyopaque, @ptrFromInt(@as(usize, @intCast(ip_iovec.buf)) + linear_memory_offset));

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    var socket = switch (s.*) {
        Stream.socket => &s.socket,
        else => return WasiError.BADF,
    };
    socket.bind(ip_addr_ptr, port) catch return WasiError.INVAL;

    return WasiError.SUCCESS;
}

pub export fn sock_listen(fd: i32, backlog: i32) WasiError {
    log.debug.printf("WASI sock_listen: {d} {d}\n", .{ fd, backlog });

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    var socket = switch (s.*) {
        Stream.socket => &s.socket,
        else => return WasiError.BADF,
    };
    socket.listen(backlog) catch return WasiError.INVAL;

    return WasiError.SUCCESS;
}

pub export fn sock_accept(fd: i32, new_fd_addr: i32) WasiError {
    log.debug.printf("WASI sock_accept: {d} {d}\n", .{ fd, new_fd_addr });

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    var socket = switch (s.*) {
        Stream.socket => &s.socket,
        else => return WasiError.BADF,
    };

    const new_fd_val = socket.accept() catch |err| {
        switch (err) {
            tcpip.Socket.Error.Again => return WasiError.AGAIN,
            else => return WasiError.INVAL,
        }
    };

    const new_fd_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(new_fd_addr)) + linear_memory_offset));
    new_fd_ptr.* = new_fd_val;

    return WasiError.SUCCESS;
}

const RiFlag = enum(i32) {
    RECV_PEEK = 1,
    RECV_WAITALL = 2,
};

const RoFlag = enum(i32) {
    RECV_DATA_TRUNCATED = 1,
};

pub export fn sock_recv(fd: i32, iovec_addr: i32, buf_len: i32, flags: i32, recv_len_addr: i32, oflags_addr: i32) WasiError {
    log.debug.printf("WASI sock_recv: {d} {d} {d} {d} {d} {d}\n", .{ fd, iovec_addr, buf_len, flags, recv_len_addr, oflags_addr });

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    var socket = switch (s.*) {
        Stream.socket => &s.socket,
        else => return WasiError.BADF,
    };

    var iovec_ptr = @as([*]IoVec, @ptrFromInt(@as(usize, @intCast(iovec_addr)) + linear_memory_offset));
    const iovecs = iovec_ptr[0..@as(usize, @intCast(buf_len))];

    var buf: []u8 = undefined;
    if (iovecs.len == 1) {
        // fast path: avoid memory allocation and copy
        const addr = @as(usize, @intCast(iovecs[0].buf)) + linear_memory_offset;
        const len = @as(usize, @intCast(iovecs[0].buf_len));
        log.debug.printf("WASI sock_recv: using fast path: linear_memory_offset: {x}, addr: {x}, len: {d}\n", .{ linear_memory_offset, addr, len });
        buf = @as([*]u8, @ptrFromInt(addr))[0..len];
    } else {
        buf = heap.runtime_allocator.alloc(u8, totalSizeOfIoVecs(iovecs)) catch return WasiError.NOMEM;
    }

    const recv_len_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(recv_len_addr)) + linear_memory_offset));
    const oflags_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(oflags_addr)) + linear_memory_offset));

    log.debug.printf("WASI sock_recv: allocated buf len={d}\n", .{buf.len});
    const recv_len = socket.read(buf) catch |err| {
        switch (err) {
            tcpip.Socket.Error.Again => return WasiError.AGAIN,
            else => return WasiError.INVAL,
        }
    };

    if (iovecs.len > 1) {
        _ = copySliceToIoVecs(buf, iovecs);
        heap.runtime_allocator.free(buf);
    }

    recv_len_ptr.* = @as(i32, @intCast(recv_len));
    oflags_ptr.* = 0;

    log.debug.printf("WASI sock_recv: received {d} bytes\n", .{recv_len});
    return WasiError.SUCCESS;
}

pub export fn sock_send(fd: i32, buf_iovec_addr: i32, buf_len: i32, flags: i32, send_len_addr: i32) WasiError {
    log.debug.printf("WASI sock_send: {d} {d} {d} {d} {d}\n", .{ fd, buf_iovec_addr, buf_len, flags, send_len_addr });

    @setRuntimeSafety(false);

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    var socket = switch (s.*) {
        Stream.socket => &s.socket,
        else => return WasiError.BADF,
    };

    var iovec_ptr = @as([*]IoVec, @ptrFromInt(@as(usize, @intCast(buf_iovec_addr)) + linear_memory_offset));
    const iovecs = iovec_ptr[0..@as(usize, @intCast(buf_len))];

    if (iovecs.len == 1) {
        // fast path: avoid memory allocation and copy
        const addr = @as(usize, @intCast(iovecs[0].buf)) + linear_memory_offset;
        const len = @as(usize, @intCast(iovecs[0].buf_len));
        const buf = @as([*]u8, @ptrFromInt(addr))[0..len];

        const sent_len = socket.send(buf) catch |err| {
            switch (err) {
                tcpip.Socket.Error.Again => return WasiError.AGAIN,
                else => return WasiError.INVAL,
            }
        };

        const send_len_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(send_len_addr)) + linear_memory_offset));
        send_len_ptr.* = @as(i32, @intCast(sent_len));
        log.debug.printf("WASI sock_send: buf_len={d}, sent_len={d}\n", .{ buf.len, sent_len });
        return WasiError.SUCCESS;
    }

    const buf = ioVecsToSlice(iovecs, heap.runtime_allocator) catch return WasiError.NOMEM;
    defer heap.runtime_allocator.free(buf);

    const send_len_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(send_len_addr)) + linear_memory_offset));

    const sent_len = socket.send(buf) catch return WasiError.INVAL;
    log.debug.printf("WASI sock_send: sent {d} bytes\n", .{sent_len});
    send_len_ptr.* = @as(i32, @intCast(sent_len));

    return WasiError.SUCCESS;
}

pub export fn sock_connect(fd: i32, buf_ioved_addr: i32, port: i32) WasiError {
    log.debug.printf("WASI sock_connect: {d} {d} {d}\n", .{ fd, buf_ioved_addr, port });

    @setRuntimeSafety(false);

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    var socket = switch (s.*) {
        Stream.socket => &s.socket,
        else => return WasiError.BADF,
    };

    const buf_iovec = @as(*IoVec, @ptrFromInt(@as(usize, @intCast(buf_ioved_addr)) + linear_memory_offset));
    const ip_addr_ptr = @as(*anyopaque, @ptrFromInt(@as(usize, @intCast(buf_iovec.buf)) + linear_memory_offset));

    socket.connect(ip_addr_ptr, port) catch return WasiError.INVAL;

    return WasiError.SUCCESS;
}

pub export fn sock_shutdown(fd: i32, flag: ShutdownFlag) WasiError {
    log.debug.printf("WASI sock_shutdown: {d} {d}\n", .{ fd, @intFromEnum(flag) });

    @setRuntimeSafety(false);

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    var socket = switch (s.*) {
        Stream.socket => &s.socket,
        else => return WasiError.BADF,
    };

    const read_flag = flag.isRead();
    const write_flag = flag.isWrite();

    socket.shutdown(read_flag, write_flag) catch return WasiError.INVAL;

    return WasiError.SUCCESS;
}

pub export fn sock_getpeeraddr(fd: i32, ip_iovec_addr: i32, type_addr: i32, port_addr: i32) WasiError {
    log.debug.printf("WASI sock_getpeeraddr: {d} {d} {d} {d}\n", .{ fd, ip_iovec_addr, type_addr, port_addr });

    @setRuntimeSafety(false);

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    var socket = switch (s.*) {
        Stream.socket => &s.socket,
        else => return WasiError.BADF,
    };

    const remote_ip = socket.getRemoteAddr();
    const remote_port = socket.getRemotePort();

    const ip_iovec = @as(*IoVec, @ptrFromInt(@as(usize, @intCast(ip_iovec_addr)) + linear_memory_offset));
    if (ip_iovec.buf_len < 4) {
        return WasiError.NOMEM;
    }
    const ip_addr_ptr = @as(*u32, @ptrFromInt(@as(usize, @intCast(ip_iovec.buf)) + linear_memory_offset));
    ip_addr_ptr.* = remote_ip.addr;

    const type_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(type_addr)) + linear_memory_offset));
    type_ptr.* = @intFromEnum(AddressFamily.INET4);

    const port_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(port_addr)) + linear_memory_offset));
    port_ptr.* = remote_port;

    return WasiError.SUCCESS;
}

fn totalSizeOfIoVecs(iovecs: []IoVec) usize {
    var total_size: usize = 0;
    for (iovecs) |iovec| {
        total_size += iovec.buf_len;
    }
    return total_size;
}

fn ioVecsToSlice(iovecs: []IoVec, allocator: std.mem.Allocator) Allocator.Error![]u8 {
    const total_size = totalSizeOfIoVecs(iovecs);
    var buf = try allocator.alloc(u8, total_size);
    var offset: usize = 0;
    for (iovecs) |iovec| {
        var iovec_buf = @as([*]u8, @ptrFromInt(@as(usize, @intCast(iovec.buf)) + linear_memory_offset));
        @memcpy(buf[offset..][0..iovec.buf_len], iovec_buf[0..iovec.buf_len]);
        offset += iovec.buf_len;
    }
    return buf;
}

fn copySliceToIoVecs(buf: []u8, iovecs: []IoVec) usize {
    var offset: usize = 0;
    for (iovecs) |iovec| {
        const iovec_buf = @as([*]u8, @ptrFromInt(@as(usize, @intCast(iovec.buf)) + linear_memory_offset));
        if (iovec.buf_len > buf.len - offset) {
            @memcpy(iovec_buf, buf[offset..buf.len]);
            offset = buf.len;
            break;
        } else {
            @memcpy(iovec_buf, buf[offset..][0..iovec.buf_len]);
            offset += iovec.buf_len;
        }
    }

    return offset;
}

pub export fn sock_getlocaladdr(fd: i32, ip_iovec_addr: i32, type_addr: i32, port_addr: i32) WasiError {
    log.debug.printf("WASI sock_getlocaladdr: {d} {d} {d} {d}\n", .{ fd, ip_iovec_addr, type_addr, port_addr });

    @setRuntimeSafety(false);

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    var socket = switch (s.*) {
        Stream.socket => &s.socket,
        else => return WasiError.BADF,
    };

    const local_ip = socket.getLocalAddr();
    const local_port = socket.getLocalPort();

    const ip_iovec = @as(*IoVec, @ptrFromInt(@as(usize, @intCast(ip_iovec_addr)) + linear_memory_offset));
    if (ip_iovec.buf_len < 4) {
        return WasiError.NOMEM;
    }
    const ip_addr_ptr = @as(*u32, @ptrFromInt(@as(usize, @intCast(ip_iovec.buf)) + linear_memory_offset));
    ip_addr_ptr.* = local_ip.addr;

    const type_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(type_addr)) + linear_memory_offset));
    type_ptr.* = @intFromEnum(AddressFamily.INET4);

    const port_ptr = @as(*u32, @ptrFromInt(@as(usize, @intCast(port_addr)) + linear_memory_offset));
    port_ptr.* = @as(u32, @intCast(local_port));

    return WasiError.SUCCESS;
}

pub export fn sock_setsockopt(fd: i32, level: i32, optname: i32, optval_addr: i32, optlen: i32) WasiError {
    log.debug.printf("WASI sock_setsockopt: {d} {d} {d} {d} {d}\n", .{ fd, level, optname, optval_addr, optlen });

    return WasiError.SUCCESS;
}

pub fn integrationTest() void {
    @setRuntimeSafety(false);

    // SpinLock
    const SpinLock = @import("sync.zig").SpinLock(i32);
    var x: i32 = 0;
    var lock = SpinLock.new(&x);
    lock.acquire().* = 1;
    lock.release();

    _ = memory_grow(1) * mem.BLOCK_SIZE;

    if (!testClientSocket()) {
        return;
    }

    if (!testServerSocket()) {
        return;
    }

    if (!testReadfile()) {
        return;
    }

    log.fatal.print("Integration test passed\n");
}

fn testReadfile() bool {
    @setRuntimeSafety(false);

    // relative address of the file descriptor
    const fd_addr_in_linear_memory = 0;
    // absolute address of the file descriptor
    const fd_linear_memory_addr = fd_addr_in_linear_memory + linear_memory_offset;
    // path to the target file
    const file_path = "test.txt";
    // relative address of the target file path
    const file_path_addr_in_linear_memory = 4;
    // absolute address of the target file path
    const file_path_linear_memory_addr = linear_memory_offset + file_path_addr_in_linear_memory;

    // copy the destination file address into memory
    // get file descriptor based on file address
    @memcpy(@as([*]u8, @ptrFromInt(file_path_linear_memory_addr)), file_path);
    var res = path_open(3, 0, file_path_addr_in_linear_memory, file_path.len, 0, 0, 0, 0, fd_addr_in_linear_memory);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("path_open failed: res={d}\n", .{@intFromEnum(res)});
        return false;
    }
    const open_fd = @as(*i32, @ptrFromInt(fd_linear_memory_addr));

    // content stored in the target file
    const target_file_content = "fd_read test";
    // iovec relative offset address
    const iovec_addr_in_linear_memory = 200;
    // iovec absolute address
    const iovec_linear_memory_addr = 200 + linear_memory_offset;
    // relative address, starting address of buffer
    const iovec_buf_addr_in_linear_memory = 32;
    // absolute address, starting address of buffer
    const iovec_buf_linear_memory_addr = iovec_buf_addr_in_linear_memory + linear_memory_offset;
    // size of buffer
    const iovec_buf_len = target_file_content.len;
    // the number of buf's contained in iovec
    const iovec_len = 1;
    // address storing the size of the file contents, indicating the number of characters in the file
    const file_content_size_addr_in_linear_memory = 100;

    // based on the file descriptor, read the contents of the file into the buf_iovec_ptr
    var buf_iovec_ptr = @as(*IoVec, @ptrFromInt(iovec_linear_memory_addr));
    buf_iovec_ptr.buf = iovec_buf_addr_in_linear_memory;
    buf_iovec_ptr.buf_len = iovec_buf_len;
    res = fd_read(open_fd.*, iovec_addr_in_linear_memory, iovec_len, file_content_size_addr_in_linear_memory);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("fd_read failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    const received_file_content = @as([*]u8, @ptrFromInt(iovec_buf_linear_memory_addr))[0..iovec_buf_len];

    // compare file contents
    if (!std.mem.eql(u8, received_file_content, target_file_content)) {
        log.fatal.printf("compare file contents failed, want: {s}, get: {s}\n", .{ target_file_content, received_file_content });
        return false;
    }

    // compare file content size
    const received_file_content_size = @as(*i32, @ptrFromInt(file_content_size_addr_in_linear_memory + linear_memory_offset));
    if (received_file_content_size.* != target_file_content.len) {
        log.fatal.printf("compare file content size failed, want: {d}, get: {d}\n", .{ target_file_content.len, received_file_content_size.* });
        return false;
    }

    res = fd_close(open_fd.*);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("fd_close failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }

    return true;
}

fn testServerSocket() bool {
    @setRuntimeSafety(false);

    // sock_open
    const fd1 = @as(*i32, @ptrFromInt(4 + linear_memory_offset));
    fd1.* = -2;
    var res = sock_open(@enumFromInt(1), @enumFromInt(2), 4);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_open failed: res={d}\n", .{@intFromEnum(res)});
        return false;
    }
    if (!(fd1.* == 5)) {
        log.fatal.printf("sock_open failed: fd={d}\n", .{fd1.*});
        return false;
    }

    // sock_bind
    var ip = @as([*]u8, @ptrFromInt(8 + linear_memory_offset));
    ip[0] = 0;
    ip[1] = 0;
    ip[2] = 0;
    ip[3] = 0;
    const port = 1234;
    var ip_iovec_ptr = @as(*IoVec, @ptrFromInt(12 + linear_memory_offset));
    ip_iovec_ptr.buf = 8;
    ip_iovec_ptr.buf_len = 4;
    res = sock_bind(fd1.*, 12, port);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_bind failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("server socket test: sock_bind succeeded\n");

    // sock_listen
    res = sock_listen(fd1.*, 5);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_listen failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("server socket test: sock_listen succeeded\n");

    // sock_accept
    res = sock_accept(fd1.*, 20);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_accept failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    const fd2 = @as(*i32, @ptrFromInt(20 + linear_memory_offset));
    log.info.print("server socket test: sock_accept succeeded\n");

    // sock_recv
    var buf_iovec_ptr = @as(*IoVec, @ptrFromInt(24 + linear_memory_offset));
    buf_iovec_ptr.buf = 40;
    buf_iovec_ptr.buf_len = 1024;
    res = sock_recv(fd2.*, 24, 1, 0, 32, 36);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_recv failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("server socket test: sock_recv succeeded\n");

    var buf = @as([*]u8, @ptrFromInt(40 + linear_memory_offset));
    const len = @as(*i32, @ptrFromInt(32 + linear_memory_offset));
    const received_buf = buf[0..@as(usize, @intCast(len.*))];
    log.info.print(received_buf);

    // random_get
    // sock_send
    _ = random_get(40, 5);
    buf_iovec_ptr.buf_len = 5;
    res = sock_send(fd2.*, 24, 1, 0, 32);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_send failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("server socket test: sock_send succeeded\n");

    // sock_shutdown
    res = sock_shutdown(fd2.*, ShutdownFlag.BOTH);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_shutdown failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("server socket test: sock_shutdown succeeded\n");

    // fd_close
    res = fd_close(fd1.*);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("fd_close failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("server socket test: fd_close succeeded\n");

    return true;
}

fn testClientSocket() bool {
    @setRuntimeSafety(false);

    // sock_open
    const fd0 = @as(*i32, @ptrFromInt(0 + linear_memory_offset));
    fd0.* = -2;
    var res = sock_open(@enumFromInt(1), @enumFromInt(2), 0);
    if (@intFromEnum(res) != 0) {
        log.info.printf("sock_open failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("client socket test: sock_open succeeded\n");

    // sock_connect
    var ip_iovec = @as(*IoVec, @ptrFromInt(4 + linear_memory_offset));
    ip_iovec.buf = 8;
    ip_iovec.buf_len = 4;
    var ip = @as([*]u8, @ptrFromInt(8 + linear_memory_offset));
    ip[0] = 1;
    ip[1] = 1;
    ip[2] = 1;
    ip[3] = 1;
    res = sock_connect(fd0.*, 4, 80);
    if (@intFromEnum(res) != 0) {
        log.info.printf("sock_connect failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("client socket test: sock_connect succeeded\n");

    // fd_write
    var buf_iovec = @as([*]IoVec, @ptrFromInt(12 + linear_memory_offset))[0..2];
    var buf = @as([*]u8, @ptrFromInt(28 + linear_memory_offset));
    @memcpy(buf, "GET / HTT");
    buf_iovec[0].buf = 28;
    buf_iovec[0].buf_len = 9;
    buf = @as([*]u8, @ptrFromInt(40 + linear_memory_offset));
    @memcpy(buf, "P/1.1\r\n\r\n");
    buf_iovec[1].buf = 40;
    buf_iovec[1].buf_len = 9;
    res = fd_write(fd0.*, 12, 2, 52);
    if (@intFromEnum(res) != 0) {
        log.info.printf("fd_write failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("client socket test: fd_write succeeded\n");

    // sock_getlocaladdr
    _ = sock_getlocaladdr(fd0.*, 4, 40, 44);
    if (ip[0] != 10 or ip[1] != 0 or ip[2] != 2 or ip[3] != 15) {
        log.info.printf("sock_getlocaladdr failed: {d}.{d}.{d}.{d}\n", .{ ip[0], ip[1], ip[2], ip[3] });
        return false;
    }
    log.info.print("client socket test: sock_getlocaladdr succeeded\n");

    // sock_getpeeraddr
    _ = sock_getpeeraddr(fd0.*, 4, 40, 44);
    const peer_port = @as(*i32, @ptrFromInt(44 + linear_memory_offset));
    if (peer_port.* != 80) {
        log.info.printf("sock_getpeeraddr failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("client socket test: sock_getpeeraddr succeeded\n");

    // sock_shutdown
    res = sock_shutdown(fd0.*, ShutdownFlag.BOTH);
    if (@intFromEnum(res) != 0) {
        log.info.printf("sock_shutdown failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("client socket test: sock_shutdown succeeded\n");

    return true;
}

// ---------------------------------------------------------------------------
// wasi-nn implementation
// ---------------------------------------------------------------------------

// wasi-nn error codes (from wasi-nn WITX spec)
const NN_ERRNO_SUCCESS: i32 = 0;
const NN_ERRNO_INVALID_ARGUMENT: i32 = 1;
const NN_ERRNO_INVALID_ENCODING: i32 = 2;
const NN_ERRNO_MISSING_MEMORY: i32 = 3;
const NN_ERRNO_BUSY: i32 = 4;
const NN_ERRNO_RUNTIME_ERROR: i32 = 5;
const NN_ERRNO_UNSUPPORTED_OPERATION: i32 = 6;
const NN_ERRNO_TOO_LARGE: i32 = 7;
const NN_ERRNO_NOT_FOUND: i32 = 8;

// Tensor struct layout in linear memory (WITX ABI)
//   offset  0: dimensions_ptr (u32)  -- pointer to list of u32 dimension values
//   offset  4: dimensions_len (u32)  -- number of dimensions
//   offset  8: tensor_type   (u8)    -- element type enum
//   offset  9: (3 bytes padding)
//   offset 12: data_ptr      (u32)   -- pointer to tensor data bytes
//   offset 16: data_len      (u32)   -- length of tensor data in bytes
const WasiNnTensor = extern struct {
    dimensions_ptr: u32,
    dimensions_len: u32,
    tensor_type: u8,
    _pad1: u8 = 0,
    _pad2: u8 = 0,
    _pad3: u8 = 0,
    data_ptr: u32,
    data_len: u32,
};

// wasi-nn global state (single graph / single context – sufficient for a unikernel)
var nn_model_name_buf: [256]u8 = undefined;
var nn_model_name_len: usize = 0;
var nn_graph_active: bool = false;

var nn_ctx_active: bool = false;
var nn_ctx_input_data_addr: u32 = 0;
var nn_ctx_input_data_len: u32 = 0;
var nn_ctx_output_data: ?[]const u8 = null;

/// load: Load a graph from an opaque sequence of bytes.
///   arg0 (builder_ptr):      pointer to graph_builder_array (list<list<u8>>)
///   arg1 (builder_len):      number of builders in the array
///   arg2 (encoding):         graph_encoding enum value
///   arg3 (target):           execution_target enum value
///   arg4 (graph_result_ptr): pointer to store the resulting graph handle
///   returns: nn_errno
pub export fn load(builder_ptr: i32, builder_len: i32, encoding: i32, target: i32, graph_result_ptr: i32) callconv(.c) i32 {
    log.debug.printf("WASI-NN load: builder_ptr={d} builder_len={d} encoding={d} target={d} graph_result_ptr={d}\n", .{ builder_ptr, builder_len, encoding, target, graph_result_ptr });

    // No-op: store a dummy graph handle (0)
    const result_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(graph_result_ptr)) + linear_memory_offset));
    result_ptr.* = 0;

    return NN_ERRNO_SUCCESS;
}

/// load_by_name: Load a graph by name.
///   arg0 (name_ptr):         pointer to name string (e.g. model name such as "resnet")
///   arg1 (name_len):         length of name string
///   arg2 (graph_result_ptr): pointer to store the resulting graph handle
///   returns: nn_errno
pub export fn load_by_name(name_ptr: i32, name_len: i32, graph_result_ptr: i32) callconv(.c) i32 {
    log.debug.printf("WASI-NN load_by_name: name_ptr={d} name_len={d} graph_result_ptr={d}\n", .{ name_ptr, name_len, graph_result_ptr });

    const len = @as(usize, @intCast(name_len));
    if (len > nn_model_name_buf.len) {
        log.debug.printf("WASI-NN load_by_name: name too long ({d} > {d})\n", .{ len, nn_model_name_buf.len });
        return NN_ERRNO_INVALID_ARGUMENT;
    }

    const name = @as([*]const u8, @ptrFromInt(@as(usize, @intCast(name_ptr)) + linear_memory_offset))[0..len];
    @memcpy(nn_model_name_buf[0..len], name);
    nn_model_name_len = len;
    nn_graph_active = true;

    log.debug.printf("WASI-NN load_by_name: loaded model \"{s}\"\n", .{nn_model_name_buf[0..nn_model_name_len]});

    // Return graph handle 0
    const result_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(graph_result_ptr)) + linear_memory_offset));
    result_ptr.* = 0;

    return NN_ERRNO_SUCCESS;
}

/// init_execution_context: Create an execution context for a graph.
///   arg0 (graph):              graph handle
///   arg1 (context_result_ptr): pointer to store the resulting execution context handle
///   returns: nn_errno
pub export fn init_execution_context(graph: i32, context_result_ptr: i32) callconv(.c) i32 {
    log.debug.printf("WASI-NN init_execution_context: graph={d} context_result_ptr={d}\n", .{ graph, context_result_ptr });

    if (!nn_graph_active) {
        log.debug.printf("WASI-NN init_execution_context: no graph loaded\n", .{});
        return NN_ERRNO_INVALID_ARGUMENT;
    }

    // Reset context state
    nn_ctx_active = true;
    nn_ctx_input_data_addr = 0;
    nn_ctx_input_data_len = 0;
    if (nn_ctx_output_data) |data| {
        heap.runtime_allocator.free(data);
        nn_ctx_output_data = null;
    }

    // Return context handle 0
    const result_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(context_result_ptr)) + linear_memory_offset));
    result_ptr.* = 0;

    return NN_ERRNO_SUCCESS;
}

/// set_input: Set input tensor for an execution context.
///   arg0 (context):    execution context handle
///   arg1 (index):      input tensor index
///   arg2 (tensor_ptr): pointer to tensor struct in linear memory (WasiNnTensor layout)
///   returns: nn_errno
pub export fn set_input(context: i32, index: i32, tensor_ptr: i32) callconv(.c) i32 {
    log.debug.printf("WASI-NN set_input: context={d} index={d} tensor_ptr={d}\n", .{ context, index, tensor_ptr });

    if (!nn_ctx_active) {
        log.debug.printf("WASI-NN set_input: no active context\n", .{});
        return NN_ERRNO_INVALID_ARGUMENT;
    }

    // Read tensor struct from linear memory
    const tensor = @as(*const WasiNnTensor, @ptrFromInt(@as(usize, @intCast(tensor_ptr)) + linear_memory_offset));

    nn_ctx_input_data_addr = tensor.data_ptr;
    nn_ctx_input_data_len = tensor.data_len;

    log.debug.printf("WASI-NN set_input: index={d} data_ptr={d} data_len={d} tensor_type={d}\n", .{ index, tensor.data_ptr, tensor.data_len, tensor.tensor_type });

    return NN_ERRNO_SUCCESS;
}

/// compute: Compute inference on the given execution context.
///   Sends the input tensor data via HTTP POST to the Triton inference server
///   at /v2/models/{model_name}/infer and stores the response for get_output.
///   arg0 (context): execution context handle
///   returns: nn_errno
pub export fn compute(context: i32) callconv(.c) i32 {
    log.debug.printf("WASI-NN compute: context={d}\n", .{context});

    if (!nn_ctx_active) {
        log.debug.printf("WASI-NN compute: no active context\n", .{});
        return NN_ERRNO_INVALID_ARGUMENT;
    }

    // Free previous output if any
    if (nn_ctx_output_data) |data| {
        heap.runtime_allocator.free(data);
        nn_ctx_output_data = null;
    }

    // Get input data from linear memory
    const input_data = @as([*]const u8, @ptrFromInt(@as(usize, nn_ctx_input_data_addr) + linear_memory_offset))[0..@as(usize, nn_ctx_input_data_len)];

    // Build URI: /v2/models/{model_name}/infer
    var uri_buf: [512]u8 = undefined;
    const uri = std.fmt.bufPrint(&uri_buf, "/v2/models/{s}/infer", .{nn_model_name_buf[0..nn_model_name_len]}) catch {
        log.debug.printf("WASI-NN compute: URI too long\n", .{});
        return NN_ERRNO_INVALID_ARGUMENT;
    };

    // Send HTTP POST to the Triton inference server
    // Host IP is 10.0.2.2 when using QEMU default user-mode networking
    var client = Client.init();
    var ip = tcpip.IpAddr{ .addr = 0x0202000A };
    const req = Request{
        .method = .POST,
        .host = "10.0.2.2",
        .uri = uri,
        .headers = &.{},
        .body = input_data,
    };

    var res = client.send(&ip, 8000, &req) catch |err| {
        log.fatal.printf("WASI-NN compute: HTTP client send failed: {any}\n", .{err});
        return NN_ERRNO_RUNTIME_ERROR;
    };
    defer res.deinit(heap.runtime_allocator);

    log.debug.printf("WASI-NN compute: response status={d} {s}\n", .{ res.status_code, res.reason });
    log.debug.printf("WASI-NN compute: response body ({d} bytes)\n", .{res.body.len});

    // Copy response body to persistent storage for get_output
    const output = heap.runtime_allocator.alloc(u8, res.body.len) catch {
        log.fatal.printf("WASI-NN compute: failed to allocate output buffer\n", .{});
        return NN_ERRNO_MISSING_MEMORY;
    };
    @memcpy(output, res.body);
    nn_ctx_output_data = output;

    return NN_ERRNO_SUCCESS;
}

/// get_output: Get output tensor data from an execution context after compute.
///   Copies the inference response data into the caller-provided buffer.
///   arg0 (context):             execution context handle
///   arg1 (index):               output tensor index
///   arg2 (out_buffer_ptr):      pointer to output buffer in linear memory
///   arg3 (out_buffer_max_size): maximum size of output buffer in bytes
///   arg4 (bytes_written_ptr):   pointer to store actual bytes written (u32)
///   returns: nn_errno
pub export fn get_output(context: i32, index: i32, out_buffer_ptr: i32, out_buffer_max_size: i32, bytes_written_ptr: i32) callconv(.c) i32 {
    log.debug.printf("WASI-NN get_output: context={d} index={d} out_buffer_ptr={d} out_buffer_max_size={d} bytes_written_ptr={d}\n", .{ context, index, out_buffer_ptr, out_buffer_max_size, bytes_written_ptr });

    if (!nn_ctx_active) {
        log.debug.printf("WASI-NN get_output: no active context\n", .{});
        return NN_ERRNO_INVALID_ARGUMENT;
    }

    const written_ptr = @as(*u32, @ptrFromInt(@as(usize, @intCast(bytes_written_ptr)) + linear_memory_offset));

    const output_data = nn_ctx_output_data orelse {
        log.debug.printf("WASI-NN get_output: no output available (compute not called?)\n", .{});
        written_ptr.* = 0;
        return NN_ERRNO_SUCCESS;
    };

    const max_size = @as(usize, @intCast(out_buffer_max_size));
    const copy_size = @min(output_data.len, max_size);
    const out_buf = @as([*]u8, @ptrFromInt(@as(usize, @intCast(out_buffer_ptr)) + linear_memory_offset))[0..copy_size];
    @memcpy(out_buf, output_data[0..copy_size]);

    written_ptr.* = @as(u32, @intCast(copy_size));

    log.debug.printf("WASI-NN get_output: copied {d} bytes (available={d}, max={d})\n", .{ copy_size, output_data.len, max_size });

    return NN_ERRNO_SUCCESS;
}
