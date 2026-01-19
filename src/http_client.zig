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

pub const HeaderOwned = struct {
    name: []u8,
    value: []u8,
};

pub const Request = struct {
    method: Method,
    host: []const u8,
    uri: []const u8,
    headers: []const Header = &.{},
    body: ?[]const u8 = null,
    
    pub fn writeTo(self: *const Request, writer: anytype) !void {
        // Request line
        const method_str = switch (self.method) {
            .GET => "GET",
            .POST => "POST",
        };
        try writer.print("{s} {s} HTTP/1.1\r\n", .{ method_str, self.uri });

        // Headers
        try writer.print("Host: {s}\r\n", .{self.host});
        for (self.headers) |h| {
            try writer.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        try writer.writeAll("Connection: close\r\n"); // TODO: Support keep-alive
        

        if (self.body) |b| {
            try writer.print("Content-Length: {d}\r\n", .{b.len});
        }

        // Header end
        try writer.writeAll("\r\n");

        // Body
        if (self.body) |b| {
            try writer.writeAll(b);
        }
    }
};

pub const Response = struct {
    status_code: u16,
    reason: []u8,
    headers: []HeaderOwned,
    body: []const u8,

    pub fn deinit(self: *Response, allocator: Allocator) void {
        for (self.headers) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        allocator.free(self.headers);
        allocator.free(self.reason);
        allocator.free(self.body);
    }
};

fn parseHttpResponse(allocator: Allocator, raw: []const u8) !Response {
    const sep = "\r\n\r\n";
    const header_end = std.mem.indexOf(u8, raw, sep) orelse return error.BadHttpResponse;

    const header_bytes = raw[0..header_end];
    const body_bytes = raw[header_end + sep.len ..];

    // Split lines
    var it = std.mem.splitSequence(u8, header_bytes, "\r\n");
    const status_line = it.next() orelse return error.BadHttpResponse;

    // Parse status line
    var sit = std.mem.splitScalar(u8, status_line, ' ');
    _ = sit.next() orelse return error.BadHttpResponse; // HTTP version
    const code_str = sit.next() orelse return error.BadHttpResponse;
    const reason_rest = sit.rest(); // remaining as reason (may include spaces)

    const status_code = try std.fmt.parseInt(u16, code_str, 10);
    const reason = try allocator.dupe(u8, reason_rest);

    // Parse headers
    var headers_list: std.ArrayList(HeaderOwned) = .{};
    errdefer {
        for (headers_list.items) |h| {
            allocator.free(h.name);
            allocator.free(h.value);
        }
        headers_list.deinit(heap.runtime_allocator);
        allocator.free(reason);
    }

    while (it.next()) |line| {
        if (line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = std.mem.trim(u8, line[0..colon], " \t");
        const value = std.mem.trim(u8, line[colon+1..], " \t");
        try headers_list.append(heap.runtime_allocator, .{
            .name = try allocator.dupe(u8, name),
            .value = try allocator.dupe(u8, value),
        });
    }

    const headers_owned = try headers_list.toOwnedSlice(heap.runtime_allocator);
    const body_owned = try allocator.dupe(u8, body_bytes);

    return Response{
        .status_code = status_code,
        .reason = reason,
        .headers = headers_owned,
        .body = body_owned,
    };
}


pub const Client = struct {

    pub fn init() Client {
        return .{};
    }

    pub fn send(_: *Client, server_ip: *IpAddr, port: u16, req: *const Request) !Response {
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
        log.debug.printf("request.body.len={d}\n", .{ if (req.body) |b| b.len else 0 });
        var buf: [4096]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&buf);
        const w = fbs.writer();

        // try req.writeTo(w);
        // Header
        try w.print("POST {s} HTTP/1.1\r\n", .{req.uri});
        try w.print("Host: {s}\r\n", .{req.host});
        for (req.headers) |h| {
            try w.print("{s}: {s}\r\n", .{ h.name, h.value });
        }
        const body = req.body orelse "";
        try w.print("Content-Length: {d}\r\n", .{body.len});
        try w.writeAll("Connection: close\r\n\r\n");
        try sendAll(sock, fbs.getWritten());

        // Body
        if (req.body) |b| {
            try sendAll(sock, b);
        }

        // Receive response
        log.debug.printf("Receiving HTTP response...\n", .{});
        var recv_buf: std.ArrayList(u8) = .{};
        errdefer recv_buf.deinit(heap.runtime_allocator);
        
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
            try recv_buf.appendSlice(heap.runtime_allocator, tmp[0..n]);
            // log.info.print(tmp[0..n]);
        }

        // Parse HTTP response
        const raw = recv_buf.items;
        const response = try parseHttpResponse(heap.runtime_allocator, raw);
        
        // close
        try sock.close();
        log.debug.printf("Socket closed. fd={d}\n", .{fd});

        return response;
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

pub fn testHTTPClientGET(uri: []const u8) !void {
    var client = Client.init();

    // Host IP in little-endian format:
    // Host IP is 10.0.2.2 when using QEMU default user-mode networking
    var ip = tcpip.IpAddr{ .addr = 0x0202000A };
    const req = Request{
        .method = .GET,
        .host = "10.0.2.2",
        .uri = uri,
        .headers = &.{
        },
    };
    var res = try client.send(&ip, 8000, &req);
    defer res.deinit(heap.runtime_allocator);

    log.debug.printf("GET response:\n", .{});
    log.debug.printf("  Response status: {d} {s}\n", .{ res.status_code, res.reason });
    for (res.headers) |h| {
        log.debug.printf("  Header: {s}: {s}\n", .{ h.name, h.value });
    }
    log.debug.printf("  Body ({d} bytes):\n{s}\n", .{ res.body.len, res.body });
}

pub fn testHTTPClientPOST(uri: []const u8, body: []const u8) !void {
    var client = Client.init();

    // Host IP in little-endian format:
    // Host IP is 10.0.2.2 when using QEMU default user-mode networking
    var ip = tcpip.IpAddr{ .addr = 0x0202000A };
    const req = Request{
        .method = .POST,
        .host = "10.0.2.2",
        .uri = uri,
        .headers = &.{
        },
        .body = body,
    };
    var res = try client.send(&ip, 8000, &req);
    defer res.deinit(heap.runtime_allocator);

    log.debug.printf("POST response:\n", .{});
    log.debug.printf("  Response status: {d} {s}\n", .{ res.status_code, res.reason });
    for (res.headers) |h| {
        log.debug.printf("  Header: {s}: {s}\n", .{ h.name, h.value });
    }
    log.debug.printf("  Body ({d} bytes):\n", .{ res.body.len });
    log.debug.print(res.body);
}