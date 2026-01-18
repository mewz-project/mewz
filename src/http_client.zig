const heap = @import("heap.zig");
const log = @import("log.zig");
const tcpip = @import("tcpip.zig");
const std = @import("std");
const stream = @import("stream.zig");

const Allocator = std.mem.Allocator;
const IpAddr = tcpip.IpAddr;
const Stream = stream.Stream;
const Socket = tcpip.Socket;

pub const Method = enum {
    GET,
    POST,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    uri: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,

    fn hasHeader(self: *const Request, name: []const u8) bool {
        for (self.headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, name)) return true;
        }
        return false;
    }

    pub fn writeHeaders(self: *const Request, writer: anytype) !void {
        // Request line
        const method_str = switch (self.method) {
            .GET => "GET",
            .POST => "POST",
        };
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ method_str, self.uri });

        // Headers
        if (!self.hasHeader("Connection")) {
            try writer.writeAll("Connection: close\r\n"); // TODO: Support keep-alive
        }
        for (self.headers) |h| {
            try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        if (self.body) |b| {
            try writer.print("Content-Length: {d}\r\n", .{b.len});
        }

        try writer.writeAll("\r\n");
    }
};

pub const Client = struct {
    pub fn init() Client {
        return .{};
    }

    pub fn send(_: *Client, server_ip: *IpAddr, port: u16, req: *const Request) !void {
        log.debug.printf("Connecting to {x}:{d}...\n", .{ server_ip.addr, port });

        // Create socket
        const sock_tmp = try Socket.new(.INET4, heap.runtime_allocator);

        // Register sock to fd_table
        const fd = stream.fd_table.set(Stream{ .socket = sock_tmp }) catch {
            var s = sock_tmp;
            s.close() catch {};
            return error.OutOfFds;
        };
        log.debug.printf("Socket created. fd={d}\n", .{fd});

        // Get new socket
        var s = stream.fd_table.get(fd) orelse @panic("fd_table missing just-inserted fd");
        var sock = switch (s.*) {
            Stream.socket => &s.socket,
            else => @panic("fd_table entry is not a socket"),
        };
        defer {
            sock.close() catch {};
            stream.fd_table.remove(fd);
            log.debug.printf("Socket closed. fd={d}\n", .{fd});
        }
        sock.setFd(fd);

        // Connect
        log.debug.printf("Socket connecting...\n", .{});
        const ip_addr_ptr = @as(*anyopaque, server_ip);
        try sock.connect(ip_addr_ptr, @as(i32, port));

        // Serialize HTTP request
        // TODO: avoid fixed-size buffer for large headers
        log.debug.printf("Serializing HTTP request...\n", .{});
        log.debug.printf("request.body.len={d}\n", .{if (req.body) |b| b.len else 0});
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        // Send request
        try req.writeHeaders(w);
        try sendAll(sock, fbs.getWritten());

        // Body
        if (req.body) |b| {
            try sendAll(sock, b);
        }

        // Receive response
        // TODO: asynchronous receive
        log.debug.printf("Receiving HTTP response...\n", .{});
        var tmp: [512]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = sock.read(tmp[0..]) catch |e| {
                log.warn.printf("sock.read error: {any}\n", .{e});
                break;
            };

            if (n == 0) {
                log.debug.printf("EOF (server closed). total={d}\n", .{total});
                break;
            }

            total += n;

            // Dump received data
            // TODO: return parsed response
            log.info.print(tmp[0..n]);
        }
    }
};

fn sendAll(sock: *Socket, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const sent = sock.send(@constCast(data[off..])) catch |e| switch (e) {
            Socket.Error.Again => {
                // TODO: avoid busy-waiting
                continue;
            },
            else => return e,
        };
        off += sent;
    }
}
