const std = @import("std");

pub const RingBuffer = struct {
    buffer: []u8,
    read_index: usize,
    write_index: usize,

    const This = @This();

    pub const Error = error{Full};

    pub fn new(capacity: usize, allocator: std.mem.Allocator) std.mem.Allocator.Error!RingBuffer {
        return RingBuffer{
            .buffer = try allocator.alloc(u8, capacity),
            .read_index = 0,
            .write_index = 0,
        };
    }

    pub fn deinit(self: *This, allocator: std.mem.Allocator) void {
        allocator.free(self.buffer);
    }

    // Returns `index` modulo the length of the backing slice.
    pub fn mask(self: *This, index: usize) usize {
        return index % self.buffer.len;
    }

    // Returns `index` modulo twice the length of the backing slice.
    pub fn mask2(self: *This, index: usize) usize {
        return index % (2 * self.buffer.len);
    }

    pub fn read(self: *This, data: []u8) usize {
        const read_index = self.mask(self.read_index);
        const read_size = @min(data.len, self.availableToRead());

        const first_read_len = @min(read_size, self.buffer.len - read_index);
        const second_read_len = read_size - first_read_len;
        @memcpy(data[0..first_read_len], self.buffer[read_index..][0..first_read_len]);
        @memcpy(data[first_read_len..first_read_len+second_read_len], self.buffer[0..][0 .. second_read_len]);
    
        self.read_index = self.mask2(self.read_index + read_size);

        return read_size;
    }

    pub fn write(self: *This, data: []const u8) Error!void {
        if (data.len > self.availableToWrite()) {
            return Error.Full;
        }

        const write_index = self.mask(self.write_index);

        const first_write_len = @min(data.len, self.buffer.len - write_index);
        @memcpy(self.buffer[write_index..][0..first_write_len], data[0..first_write_len]);
        @memcpy(self.buffer[0..][0 .. data.len - first_write_len], data[first_write_len..]);

        self.write_index = self.mask2(self.write_index + data.len);

        return;
    }

    // Returns the number of bytes available to read.
    pub fn availableToRead(self: *This) usize {
        const wrap_offset = 2 * self.buffer.len * @intFromBool(self.write_index < self.read_index);
        const adjusted_write_index = self.write_index + wrap_offset;
        return adjusted_write_index - self.read_index;
    }

    // Returns the number of bytes available to write.
    pub fn availableToWrite(self: *This) usize {
        return self.buffer.len - self.availableToRead();
    }
};

pub fn roundUp(comptime T: type, v: T, to: T) T {
    return (v + to - 1) / to * to;
}

pub fn roundDown(comptime T: type, v: T, to: T) T {
    return v / to * to;
}

pub fn getString(addr: u32) []const u8 {
    var len: u32 = 0;
    while (@as(*u8, @ptrFromInt(addr + len)).* != 0) : (len += 1) {}
    return @as([*]u8, @ptrFromInt(addr))[0..len];
}

test "RingBuffer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var ring_buffer = try RingBuffer.new(10, allocator);
    try ring_buffer.write("012"[0..]);
    try ring_buffer.write("345"[0..]);
    var buf = try allocator.alloc(u8, 5);
    var size = ring_buffer.read(buf);

    try std.testing.expectEqual(size, 5);
    try std.testing.expectEqualSlices(u8, buf, "01234"[0..]);

    try ring_buffer.write("67"[0..]);
    try ring_buffer.write("89012"[0..]);

    buf = try allocator.alloc(u8, 7);
    size = ring_buffer.read(buf);

    try std.testing.expectEqual(size, 7);
    try std.testing.expectEqualSlices(u8, buf, "5678901"[0..]);

    buf = try allocator.alloc(u8, 10);
    size = ring_buffer.read(buf);

    try std.testing.expectEqual(size, 1);
    try std.testing.expectEqualSlices(u8, buf[0..size], "2"[0..]);

    try ring_buffer.write("345"[0..]);
    try ring_buffer.write("6789"[0..]);
    try std.testing.expectEqual(ring_buffer.write("0123"[0..]), RingBuffer.Error.Full);

    try ring_buffer.write("012"[0..]);
    buf = try allocator.alloc(u8, 10);
    size = ring_buffer.read(buf);

    try std.testing.expectEqual(size, 10);
    try std.testing.expectEqualSlices(u8, buf[0..size], "3456789012"[0..]);
}
