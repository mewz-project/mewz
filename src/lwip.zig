const sync = @import("sync.zig");
const IpAddr = @import("tcpip.zig").IpAddr;

const empty = struct {};
pub var lock = sync.SpinLock(empty).new(@constCast(&empty{}));

const vtable = VTable{};

pub fn acquire() *const VTable {
    _ = lock.acquire();
    return &vtable;
}

pub fn release() void {
    lock.release();
}

const VTable = struct {
    lwip_new_tcp_pcb: *const fn (ip_type: u8) callconv(.C) usize = lwip_new_tcp_pcb,
    lwip_set_fd: *const fn (pcb: *anyopaque, fd_ptr: *i32) callconv(.C) void = lwip_set_fd,
    lwip_tcp_bind: *const fn (pcb: *anyopaque, ipaddr: *anyopaque, port: i32) callconv(.C) i8 = lwip_tcp_bind,
    tcp_listen_with_backlog: *const fn (pcb: *anyopaque, backblog: u8) callconv(.C) ?*anyopaque = tcp_listen_with_backlog,
    lwip_accept: *const fn (pcb: *anyopaque) callconv(.C) void = lwip_accept,
    lwip_tcp_sndbuf: *const fn (pcb: *anyopaque) callconv(.C) u16 = lwip_tcp_sndbuf,
    lwip_send: *const fn (pcb: *anyopaque, buf: *anyopaque, len: u16) callconv(.C) i8 = lwip_send,
    lwip_connect: *const fn (pcb: *anyopaque, ipaddr: *anyopaque, port: i32) callconv(.C) i8 = lwip_connect,
    tcp_shutdown: *const fn (pcb: *anyopaque, shut_rx: i32, shut_tx: i32) callconv(.C) i8 = tcp_shutdown,
    lwip_tcp_close: *const fn (pcb: *anyopaque) callconv(.C) i8 = lwip_tcp_close,
    lwip_unset_fd: *const fn (pcb: *anyopaque) callconv(.C) void = lwip_unset_fd,
    lwip_get_local_ip: *const fn (pcb: *anyopaque) callconv(.C) *IpAddr = lwip_get_local_ip,
    lwip_get_remote_ip: *const fn (pcb: *anyopaque) callconv(.C) *IpAddr = lwip_get_remote_ip,
    lwip_get_local_port: *const fn (pcb: *anyopaque) callconv(.C) u16 = lwip_get_local_port,
    lwip_get_remote_port: *const fn (pcb: *anyopaque) callconv(.C) u16 = lwip_get_remote_port,
    sys_check_timeouts: *const fn () callconv(.C) void = sys_check_timeouts,
};

extern fn lwip_new_tcp_pcb(ip_type: u8) usize;
extern fn lwip_set_fd(pcb: *anyopaque, fd_ptr: *i32) void;
extern fn lwip_tcp_bind(pcb: *anyopaque, ipaddr: *anyopaque, port: i32) i8;
extern fn tcp_listen_with_backlog(pcb: *anyopaque, backblog: u8) ?*anyopaque;
extern fn lwip_accept(pcb: *anyopaque) void;
extern fn lwip_tcp_sndbuf(pcb: *anyopaque) u16;
extern fn lwip_send(pcb: *anyopaque, buf: *anyopaque, len: u16) i8;
extern fn lwip_connect(pcb: *anyopaque, ipaddr: *anyopaque, port: i32) i8;
extern fn tcp_shutdown(pcb: *anyopaque, shut_rx: i32, shut_tx: i32) i8;
extern fn lwip_tcp_close(pcb: *anyopaque) i8;
extern fn lwip_unset_fd(pcb: *anyopaque) void;
extern fn lwip_get_local_ip(pcb: *anyopaque) *IpAddr;
extern fn lwip_get_remote_ip(pcb: *anyopaque) *IpAddr;
extern fn lwip_get_local_port(pcb: *anyopaque) u16;
extern fn lwip_get_remote_port(pcb: *anyopaque) u16;
extern fn sys_check_timeouts() void;
