const std = @import("std");
const Allocator = std.mem.Allocator;

const heap = @import("heap.zig");
const fs = @import("fs.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const poll = @import("poll.zig");
const rand = @import("rand.zig");
const stream = @import("stream.zig");
const tcpip = @import("tcpip.zig");
const timer = @import("timer.zig");
const types = @import("wasi/types.zig");
const x64 = @import("x64.zig");

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

pub export fn memory_grow(num: usize) callconv(.C) usize {
    log.debug.printf("WASI memory_grow: {d}\n", .{num});
    const old_num = linear_memory_block_num;
    for (0..num) |_| {
        _ = mem.allocAndMapBlock(linear_memory_top);
        linear_memory_top += mem.BLOCK_SIZE;
    }
    linear_memory_block_num += num;

    return old_num;
}

pub export fn memory_base() callconv(.C) usize {
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

pub export fn fd_write(fd: i32, buf_iovec_addr: i32, vec_len: i32, size_addr: i32) callconv(.C) WasiError {
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

pub export fn fd_read(fd: i32, buf_iovec_addr: i32, vec_len: i32, size_addr: i32) callconv(.C) WasiError {
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

pub export fn fd_close(fd: i32) callconv(.C) WasiError {
    log.debug.printf("WASI fd_close: {d}\n", .{fd});
    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    s.close() catch return WasiError.BADF;
    stream.fd_table.remove(fd);
    return WasiError.SUCCESS;
}

pub export fn fd_filestat_get(fd: i32, filestat_addr: i32) callconv(.C) WasiError {
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

pub export fn fd_fdstat_get(fd: i32, fdstat_addr: i32) callconv(.C) WasiError {
    log.debug.printf("WASI fd_fdstat_get: {d} {d}\n", .{ fd, fdstat_addr });

    var fdstat_ptr = @as(*FdStat, @ptrFromInt(@as(usize, @intCast(fdstat_addr)) + linear_memory_offset));
    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    fdstat_ptr.file_type = FileType.fromStream(s);
    fdstat_ptr.flags = s.flags();
    fdstat_ptr.rights_base = types.FULL_RIGHTS;
    fdstat_ptr.rights_inheriting = types.FULL_RIGHTS;

    return WasiError.SUCCESS;
}

pub export fn fd_fdstat_set_flags(fd: i32, flags: i32) callconv(.C) WasiError {
    log.debug.printf("WASI fd_fdstat_set_flags: {d} {d}\n", .{ fd, flags });

    var s = stream.fd_table.get(fd) orelse return WasiError.BADF;
    s.setFlags(@as(u16, @bitCast(@as(i16, @truncate(flags)))));
    return WasiError.SUCCESS;
}

pub export fn fd_prestat_get(fd: i32, prestat_addr: i32) callconv(.C) WasiError {
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
) callconv(.C) WasiError {
    log.debug.printf("WASI poll_oneoff: {d} {d} {d} {d}\n", .{ input_addr, output_addr, nsubscriptions, nevents_addr });

    const subscriptions = @as([*]types.Subscription, @ptrFromInt(@as(usize, @intCast(input_addr)) + linear_memory_offset))[0..@as(usize, @intCast(nsubscriptions))];
    const events = @as([*]types.Event, @ptrFromInt(@as(usize, @intCast(output_addr)) + linear_memory_offset))[0..@as(usize, @intCast(nsubscriptions))];
    const nevents = @as(*i32, @ptrFromInt(@as(usize, @intCast(nevents_addr)) + linear_memory_offset));

    nevents.* = poll.poll(subscriptions, events, nsubscriptions);

    return WasiError.SUCCESS;
}

pub export fn proc_exit(status: i32) callconv(.C) void {
    log.debug.printf("WASI proc_exit: {d}\n", .{status});

    x64.shutdown(@as(u16, @intCast(status)));
    unreachable;
}

pub export fn sched_yield() callconv(.C) WasiError {
    log.debug.printf("WASI sched_yield\n", .{});

    return WasiError.SUCCESS;
}

pub export fn sock_open(
    family: AddressFamily,
    typ: SocketType,
    fd_addr: i32,
) callconv(.C) WasiError {
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
) callconv(.C) WasiError {
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
        buf = @as([*]u8, @ptrFromInt(addr))[0..len];
    } else {
        buf = heap.runtime_allocator.alloc(u8, totalSizeOfIoVecs(iovecs)) catch return WasiError.NOMEM;
    }

    const recv_len_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(recv_len_addr)) + linear_memory_offset));
    const oflags_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(oflags_addr)) + linear_memory_offset));

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
        const sent_len = socket.send(buf) catch return WasiError.INVAL;
        const send_len_ptr = @as(*i32, @ptrFromInt(@as(usize, @intCast(send_len_addr)) + linear_memory_offset));
        send_len_ptr.* = @as(i32, @intCast(sent_len));
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

    const base = memory_grow(1) * mem.BLOCK_SIZE;
    // Socket
    log.info.printf("base: {x}\n", .{base});

    if (!testClientSocket(base)) {
        return;
    }

    if (!testServerSocket(base)) {
        return;
    }

    log.fatal.print("Integration test passed\n");
}

fn testServerSocket(base: usize) bool {
    @setRuntimeSafety(false);

    // sock_open
    const fd1 = @as(*i32, @ptrFromInt(base + 4 + 0xffff800000000000));
    fd1.* = -2;
    var res = sock_open(@enumFromInt(1), @enumFromInt(2), 4);
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_open failed: res={d}\n", .{@intFromEnum(res)});
        return false;
    }
    if (!(fd1.* == 4)) {
        log.fatal.printf("sock_open failed: fd={d}\n", .{fd1.*});
        return false;
    }

    // sock_bind
    var ip = @as([*]u8, @ptrFromInt(base + 8 + 0xffff800000000000));
    ip[0] = 0;
    ip[1] = 0;
    ip[2] = 0;
    ip[3] = 0;
    const port = 1234;
    var ip_iovec_ptr = @as(*IoVec, @ptrFromInt(base + 12 + 0xffff800000000000));
    ip_iovec_ptr.buf = @as(u32, @intCast(base + 8));
    ip_iovec_ptr.buf_len = 4;
    res = sock_bind(fd1.*, @as(i32, @intCast(base + 12)), port);
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
    res = sock_accept(fd1.*, @as(i32, @intCast(base + 20)));
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_accept failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    const fd2 = @as(*i32, @ptrFromInt(base + 20 + 0xffff800000000000));
    log.info.print("server socket test: sock_accept succeeded\n");

    // sock_recv
    var buf_iovec_ptr = @as(*IoVec, @ptrFromInt(base + 24 + 0xffff800000000000));
    buf_iovec_ptr.buf = @as(u32, @intCast(base + 40));
    buf_iovec_ptr.buf_len = 1024;
    res = sock_recv(fd2.*, @as(i32, @intCast(base + 24)), 1, 0, @as(i32, @intCast(base + 32)), @as(i32, @intCast(base + 36)));
    if (@intFromEnum(res) != 0) {
        log.fatal.printf("sock_recv failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("server socket test: sock_recv succeeded\n");

    var buf = @as([*]u8, @ptrFromInt(base + 40 + 0xffff800000000000));
    const len = @as(*i32, @ptrFromInt(base + 32 + 0xffff800000000000));
    const received_buf = buf[0..@as(usize, @intCast(len.*))];
    log.info.print(received_buf);

    // random_get
    // sock_send
    _ = random_get(@as(i32, @intCast(base + 40)), 5);
    buf_iovec_ptr.buf_len = 5;
    res = sock_send(fd2.*, @as(i32, @intCast(base + 24)), 1, 0, @as(i32, @intCast(base + 32)));
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

fn testClientSocket(base: usize) bool {
    @setRuntimeSafety(false);

    // sock_open
    const fd0 = @as(*i32, @ptrFromInt(base + 0 + 0xffff800000000000));
    fd0.* = -2;
    var res = sock_open(@enumFromInt(1), @enumFromInt(2), 0);
    if (@intFromEnum(res) != 0) {
        log.info.printf("sock_open failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("client socket test: sock_open succeeded\n");

    // sock_connect
    var ip_iovec = @as(*IoVec, @ptrFromInt(base + 4 + 0xffff800000000000));
    ip_iovec.buf = @as(u32, @intCast(base + 8));
    ip_iovec.buf_len = 4;
    var ip = @as([*]u8, @ptrFromInt(base + 8 + 0xffff800000000000));
    ip[0] = 1;
    ip[1] = 1;
    ip[2] = 1;
    ip[3] = 1;
    res = sock_connect(fd0.*, @as(i32, @intCast(base + 4)), 80);
    if (@intFromEnum(res) != 0) {
        log.info.printf("sock_connect failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("client socket test: sock_connect succeeded\n");

    // fd_write
    var buf_iovec = @as([*]IoVec, @ptrFromInt(base + 12 + 0xffff800000000000))[0..2];
    var buf = @as([*]u8, @ptrFromInt(base + 28 + 0xffff800000000000));
    @memcpy(buf, "GET / HTT");
    buf_iovec[0].buf = @as(u32, @intCast(base + 28));
    buf_iovec[0].buf_len = 9;
    buf = @as([*]u8, @ptrFromInt(base + 40 + 0xffff800000000000));
    @memcpy(buf, "P/1.1\r\n\r\n");
    buf_iovec[1].buf = @as(u32, @intCast(base + 40));
    buf_iovec[1].buf_len = 9;
    res = fd_write(fd0.*, @as(i32, @intCast(base + 12)), 2, @as(i32, @intCast(base + 52)));
    if (@intFromEnum(res) != 0) {
        log.info.printf("fd_write failed: {d}\n", .{@intFromEnum(res)});
        return false;
    }
    log.info.print("client socket test: fd_write succeeded\n");

    // sock_getlocaladdr
    _ = sock_getlocaladdr(fd0.*, @as(i32, @intCast(base + 4)), @as(i32, @intCast(base + 40)), @as(i32, @intCast(base + 44)));
    if (ip[0] != 10 or ip[1] != 0 or ip[2] != 2 or ip[3] != 15) {
        log.info.printf("sock_getlocaladdr failed: {d}.{d}.{d}.{d}\n", .{ ip[0], ip[1], ip[2], ip[3] });
        return false;
    }
    log.info.print("client socket test: sock_getlocaladdr succeeded\n");

    // sock_getpeeraddr
    _ = sock_getpeeraddr(fd0.*, @as(i32, @intCast(base + 4)), @as(i32, @as(i32, @intCast(base + 40))), @as(i32, @intCast(base + 44)));
    const peer_port = @as(*i32, @ptrFromInt(base + 44 + 0xffff800000000000));
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
