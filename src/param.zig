const std = @import("std");
const log = @import("log.zig");
const Ip4Address = std.os.linux.sockaddr;

const Params = struct {
    addr: u32 = undefined,
    subnetmask: u32 = undefined,
};

pub var params = Params{};

// TODO: Add tests
pub fn parseFromArgs(args: []const u8) void {
    const addr_str = getParamPart(args);
    parse(addr_str);
}

fn parse(args: []const u8) void {
    var params_itr = std.mem.split(u8, args, " ");
    while (params_itr.next()) |part| {
        var kv = std.mem.split(u8, part, "=");

        const k = kv.next() orelse continue;
        const v = kv.next() orelse continue;

        if (std.mem.eql(u8, k, "ip")) {
            parseIp(v);
        } else {
            @panic("invalid param format");
        }
    }
}

// retrive substring which is surrounded by ''
fn getParamPart(args: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = 0;
    var in_quote = false;
    for (0..args.len) |i| {
        if (args[i] == '\'') {
            if (in_quote) {
                end = i;
                break;
            } else {
                start = i + 1;
                in_quote = true;
            }
        }
    }
    return args[start..end];
}

fn parseIp(ip_str: []const u8) void {
    var parts = std.mem.split(u8, ip_str, "/");
    const ip = parts.next() orelse @panic("invalid ip format");
    const subnet = parts.next() orelse @panic("invalid ip format");
    if (parts.next()) |_| {
        @panic("invalid ip format");
    }

    params.addr = parseIp4Address(ip) orelse {
        @panic("invalid ip format");
    };

    const subnet_num = std.fmt.parseInt(u32, subnet, 10) catch {
        @panic("invalid subnet format");
    };
    if (subnet_num > 32) {
        @panic("invalid subnet format");
    }
    for (0..subnet_num) |i| {
        params.subnetmask |= @as(u32, 1) << @as(u5, @intCast(31 - i));
    }
}

// This function is a copy of std.net.Ip4Address.parse
fn parseIp4Address(buf: []const u8) ?u32 {
    var result: u32 = 0;
    const out_ptr = std.mem.asBytes(&result);

    var x: u8 = 0;
    var index: u8 = 0;
    var saw_any_digits = false;
    var has_zero_prefix = false;
    for (buf) |c| {
        if (c == '.') {
            if (!saw_any_digits) {
                return null; // invalid character
            }
            if (index == 3) {
                return null; // invalid end
            }
            out_ptr[index] = x;
            index += 1;
            x = 0;
            saw_any_digits = false;
            has_zero_prefix = false;
        } else if (c >= '0' and c <= '9') {
            if (c == '0' and !saw_any_digits) {
                has_zero_prefix = true;
            } else if (has_zero_prefix) {
                return null; // non canonical
            }
            saw_any_digits = true;
            x = std.math.mul(u8, x, 10) catch {
                return null; // overflow
            };
            x = std.math.add(u8, x, c - '0') catch {
                return null; // overflow
            };
        } else {
            return null; // invalid character
        }
    }
    if (index == 3 and saw_any_digits) {
        out_ptr[index] = x;
        return result;
    }

    return null; // incomplete
}
