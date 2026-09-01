const std = @import("std");
const tcpip = @import("tcpip.zig");

pub const Error = error{
    Noname,
    Memory,
    Failed,
    Family,
    Service,
};

pub const Hints = struct {
    passive: bool = false,
    numeric_host: bool = false,
    want_inet6: bool = false,
};

pub fn parseServicePort(service: ?[]const u8) Error!u16 {
    const s = service orelse return 0;
    if (s.len == 0) return 0;

    // wasmedge_wasi_socket passes service names like "http" to sock_getaddrinfo.
    if (std.mem.eql(u8, s, "http")) return 80;
    if (std.mem.eql(u8, s, "https")) return 443;

    var port: u16 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return Error.Service;
        port = port * 10 + (c - '0');
    }
    return port;
}

pub fn resolveNode(node: ?[]const u8, hints: ?Hints) Error![4]u8 {
    const n = node orelse {
        if (hints) |h| {
            if (h.passive) return .{ 0, 0, 0, 0 };
        }
        return .{ 127, 0, 0, 1 };
    };
    if (n.len == 0) return Error.Noname;

    if (hints) |h| {
        if (h.want_inet6) return Error.Family;
        if (h.numeric_host) {
            return tcpip.parseIpv4Address(n) orelse return Error.Noname;
        }
    }

    if (std.mem.eql(u8, n, "localhost")) return .{ 127, 0, 0, 1 };

    if (tcpip.parseIpv4Address(n)) |ip| return ip;

    return tcpip.resolveHostname(n) catch |err| switch (err) {
        tcpip.ResolveError.Noname => return Error.Noname,
        tcpip.ResolveError.Memory => return Error.Memory,
        tcpip.ResolveError.Failed => return Error.Failed,
    };
}
