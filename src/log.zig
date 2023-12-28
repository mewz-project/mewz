const std = @import("std");
const fmt = std.fmt;
const options = @import("options");

const uart = @import("uart.zig");

const LogLevel = enum(u8) {
    Debug = 1,
    Info = 2,
    Warn = 3,
    Fatal = 4,

    const Self = @This();

    fn fromString(s: []const u8) Self {
        if (std.mem.eql(u8, s, "debug")) {
            return .Debug;
        } else if (std.mem.eql(u8, s, "info")) {
            return .Info;
        } else if (std.mem.eql(u8, s, "warn")) {
            return .Warn;
        } else if (std.mem.eql(u8, s, "fatal")) {
            return .Fatal;
        } else {
            @panic("invalid log level");
        }
    }

    fn largerThan(self: Self, other: Self) bool {
        return @intFromEnum(self) > @intFromEnum(other);
    }
};

const log_level = LogLevel.fromString(options.log_level);

pub const debug = init: {
    if (log_level.largerThan(LogLevel.Debug)) {
        break :init dummy;
    } else {
        break :init impl("DEBUG");
    }
};

pub const info = init: {
    if (log_level.largerThan(LogLevel.Info)) {
        break :init dummy;
    } else {
        break :init impl("INFO");
    }
};

pub const warn = init: {
    if (log_level.largerThan(LogLevel.Warn)) {
        break :init dummy;
    } else {
        break :init impl("WARN");
    }
};

pub const fatal = init: {
    if (log_level.largerThan(LogLevel.Fatal)) {
        break :init dummy;
    } else {
        break :init impl("FATAL");
    }
};

pub fn impl(comptime level: []const u8) type {
    return struct {
        pub fn print(s: []const u8) void {
            uart.puts("[LOG " ++ level ++ "]: ");
            uart.puts(s);
        }

        pub fn printf(comptime format: []const u8, args: anytype) void {
            var buf: [1024]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(buf[0..1024]);
            const allocator = fba.allocator();
            const s = fmt.allocPrint(allocator, format, args) catch "log.printf: invalid format error\n";
            print(s);
        }

        pub fn dumpHex(data: []const u8) void {
            const bytes_per_line = 16;

            for (data, 0..) |b, i| {
                if ((i % bytes_per_line) == 0 and i > 0) {
                    print("\n");
                }
                printf("{x:0>2} ", .{b});
            }
            print("\n");
        }
    };
}

const dummy = struct {
    pub fn print(s: []const u8) void {
        _ = s;
    }
    pub fn printf(comptime format: []const u8, args: anytype) void {
        _ = args;
        _ = format;
    }
    pub fn dumpHex(data: []const u8) void {
        _ = data;
    }
};
