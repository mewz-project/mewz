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
    PUT,
    DELETE,
    PATCH,
    HEAD,
};

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

pub const Request = struct {
    method: Method,
    host: []const u8,
    uri: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    
    pub fn writeTo(self: *const Request, writer: anytype) !void {
        // Request line
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ methodToString(self.method), self.uri });

        try writer.print("Host: {s}\r\n", .{self.host});
        try writer.writeAll("Connection: close\r\n"); // TODO: Support keep-alive
        

        if (self.body) |b| {
            try writer.print("Content-Length: {d}\r\n", .{b.len});
        }

        // User headers
        for (self.headers) |h| {
            try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }

        // Header end
        try writer.writeAll("\r\n");

        // Body
        if (self.body) |b| {
            try writer.writeAll(b);
        }
    }
};

fn methodToString(m: Method) []const u8 {
    return switch (m) {
        .GET => "GET",
        .POST => "POST",
        .PUT => "PUT",
        .DELETE => "DELETE",
        .PATCH => "PATCH",
        .HEAD => "HEAD",
    };
}

pub const Client = struct {

    pub fn init() Client {
        return .{};
    }

    pub fn send(_: *Client, server_ip: *IpAddr, port: u16, req: *const Request) !void {
        log.debug.printf("Connecting to {x}:{d}...\n", .{server_ip.addr, port});

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
        sock.setFd(fd);
        
        // Connect
        log.debug.printf("Socket connecting...\n", .{});
        const ip_addr_ptr = @as(*anyopaque, server_ip);
        try sock.connect(ip_addr_ptr, @as(i32, port));

        // Serialize HTTP request
        log.debug.printf("Serializing HTTP request...\n", .{});
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        try req.writeTo(fbs.writer());

        // Send HTTP request
        log.debug.printf("Sending HTTP request ({d} bytes)...\n", .{fbs.getWritten().len});
        try sendAll(sock, fbs.getWritten());
        log.debug.printf("---- REQUEST BEGIN ----\n{s}\n---- REQUEST END ----\n", .{fbs.getWritten()});

        // Receive response
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

            log.info.print(tmp[0..n]);
        }
        
        // close
        try sock.close();
    }
};

fn sendAll(sock: *Socket, data: []const u8) !void {
    var off: usize = 0;
    while (off < data.len) {
        const sent = sock.send(@constCast(data[off..])) catch |e| switch (e) {
            Socket.Error.Again => {
                continue;
            },
            else => return e,
        };
        off += sent;
    }
}
