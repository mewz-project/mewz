const std = @import("std");

const types = @import("types.zig");

const WasiAddrinfo = types.WasiAddrinfo;
const WasiAddressFamily = types.WasiAddressFamily;
const WasiSocketType = types.WasiSocketType;
const AiFlags = types.AiFlags;
const AiProtocol = types.AiProtocol;

pub const memory_base: usize = 0xffff800000000000;

const addrinfo_off_addrlen = @offsetOf(WasiAddrinfo, "ai_addrlen");
const addrinfo_off_ai_addr = @offsetOf(WasiAddrinfo, "ai_addr");
const addrinfo_off_canonname = @offsetOf(WasiAddrinfo, "ai_canonname");
const addrinfo_off_canonnamelen = @offsetOf(WasiAddrinfo, "ai_canonnamelen");

pub fn bytesAt(addr: u32) [*]u8 {
    return @ptrFromInt(@as(usize, @intCast(addr)) + memory_base);
}

pub fn ptrFromGuest(comptime T: type, addr: u32) *T {
    return @ptrFromInt(@as(usize, @intCast(addr)) + memory_base);
}

pub fn sliceFromGuest(addr: i32, len: i32) ?[]u8 {
    if (addr == 0 or len == 0) return null;
    const ptr = @as([*]u8, @ptrFromInt(@as(usize, @intCast(addr)) + memory_base));
    var slice = ptr[0..@as(usize, @intCast(len))];
    if (slice.len > 0 and slice[slice.len - 1] == 0) {
        slice = slice[0 .. slice.len - 1];
    }
    return slice;
}

fn writeSockaddrAt(sa_addr: u32, port: u16, ip: [4]u8) void {
    const sa_bytes = bytesAt(sa_addr);
    sa_bytes[0] = @intFromEnum(WasiAddressFamily.INET4);
    std.mem.writeInt(u32, sa_bytes[4..8], 6, .little);

    const sa_data_addr = std.mem.readInt(u32, sa_bytes[8..12], .little);
    const sa_data_ptr = bytesAt(sa_data_addr);
    const port_be = std.mem.nativeToBig(u16, port);
    const port_bytes = std.mem.asBytes(&port_be);
    sa_data_ptr[0] = port_bytes[0];
    sa_data_ptr[1] = port_bytes[1];
    sa_data_ptr[2] = ip[0];
    sa_data_ptr[3] = ip[1];
    sa_data_ptr[4] = ip[2];
    sa_data_ptr[5] = ip[3];
}

pub fn addrinfoHintFamilyIsInet6(hint_addr: i32) bool {
    const hint_bytes = bytesAt(@intCast(hint_addr));
    return hint_bytes[2] == @intFromEnum(WasiAddressFamily.INET6);
}

pub fn addrinfoAddrlen(ai_addr: u32) u32 {
    const bytes = bytesAt(ai_addr);
    return std.mem.readInt(u32, bytes[addrinfo_off_addrlen..][0..4], .little);
}

pub fn fillAddrinfo(
    ai_addr: u32,
    hints: ?*const WasiAddrinfo,
    port: u16,
    ip: [4]u8,
    node: ?[]const u8,
) void {
    const bytes = bytesAt(ai_addr);

    if (hints) |h| {
        const hint_bytes = @as([*]const u8, @ptrCast(h));
        std.mem.writeInt(u16, bytes[0..2], std.mem.readInt(u16, hint_bytes[0..2], .little), .little);
        bytes[2] = if (hint_bytes[2] == @intFromEnum(WasiAddressFamily.Unspec)) @intFromEnum(WasiAddressFamily.INET4) else hint_bytes[2];
        bytes[3] = hint_bytes[3];
        bytes[4] = hint_bytes[4];
    } else {
        std.mem.writeInt(u16, bytes[0..2], @intFromEnum(AiFlags.Passive), .little);
        bytes[2] = @intFromEnum(WasiAddressFamily.INET4);
        bytes[3] = @intFromEnum(WasiSocketType.Stream);
        bytes[4] = @intFromEnum(AiProtocol.TCP);
    }

    std.mem.writeInt(u32, bytes[addrinfo_off_addrlen..][0..4], 6, .little);

    const sockaddr_addr = std.mem.readInt(u32, bytes[addrinfo_off_ai_addr..][0..4], .little);
    writeSockaddrAt(sockaddr_addr, port, ip);

    const canon_addr = std.mem.readInt(u32, bytes[addrinfo_off_canonname..][0..4], .little);
    const canon_len = std.mem.readInt(u32, bytes[addrinfo_off_canonnamelen..][0..4], .little);
    if (node) |n| {
        if (canon_addr != 0 and canon_len > 0) {
            const canon_ptr = bytesAt(canon_addr);
            const copy_len = @min(n.len, @as(usize, @intCast(canon_len)) - 1);
            @memcpy(canon_ptr[0..copy_len], n[0..copy_len]);
            canon_ptr[copy_len] = 0;
        }
    }
}
