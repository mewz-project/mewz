const std = @import("std");
const Allocator = std.mem.Allocator;

const log = @import("log.zig");
const x64 = @import("x64.zig");
const mem = @import("mem.zig");

const CONDIG_ADDRESS = 0x0cf8;
const CONDIG_DATA = 0x0cfc;

pub var devices = [10]?Device{ null, null, null, null, null, null, null, null, null, null };

var null_device_index: usize = 0;

pub const Error = error{
    InvalidDevice,
};

pub const Config = packed struct {
    vendor_id: u16,
    device_id: u16,
    command: u16,
    status: u16,
    revision: u8,
    prog_if: u8,
    subclass: u8,
    class: u8,
    cache_line_size: u8,
    latency_timer: u8,
    header_type: u8,
    bist: u8,
    bar0: u32,
    bar1: u32,
    bar2: u32,
    bar3: u32,
    bar4: u32,
    bar5: u32,
    cardbus_cis_ptr: u32,
    subsystem_vendor: u16,
    subsystem: u16,
    rom_base: u32,
    capabilities_ptr: u8,
    reserved0: u24,
    reserved1: u32,
    interrupt_line: u8,
    interrupt_pin: u8,
    min_grant: u8,
    max_latency: u8,

    const Self = @This();

    fn isInvalid(self: *const Self) bool {
        return self.vendor_id == 0xffff;
    }

    // ref: https://docs.oracle.com/cd/E19683-01/806-5222/hwovr-28/index.html
    pub fn bar(self: *const Self, index: u8) u32 {
        const value = switch (index) {
            0 => self.bar0,
            1 => self.bar1,
            2 => self.bar2,
            3 => self.bar3,
            4 => self.bar4,
            5 => self.bar5,
            else => @panic("pci: invalid bar index"),
        };

        if ((value & 1) == 0) {
            return value & 0xfffffff0;
        }

        @panic("pci: IO space mapped BAR is not supported");
    }
};

pub const Capability = struct {
    id: u8,
    next: u8,
    len: u8,
    data: []u8,

    const Self = @This();
};

pub const Device = struct {
    bus: u8,
    slot: u8,
    func: u8,
    config: Config,
    capabilities: []Capability,

    const Self = @This();

    fn new(bus: u8, slot: u8, func: u8) (Allocator.Error || Error)!Self {
        var config_buffer: [16]u32 align(8) = [16]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        for (0..16) |i| {
            const config_value = readConfig(bus, slot, func, @as(u8, @intCast(i * 4)));
            config_buffer[i] = config_value;
        }

        const config = @as(*Config, @ptrCast(&config_buffer[0]));
        if (config.isInvalid()) {
            return Error.InvalidDevice;
        }

        var dev = Self{
            .bus = bus,
            .slot = slot,
            .func = func,
            .config = config.*,
            .capabilities = undefined,
        };

        var cap_addr = config.capabilities_ptr;
        var capabilities = try mem.boottime_allocator.?.alloc(Capability, 16);

        for (0..16) |i| {
            if (cap_addr == 0) {
                capabilities = capabilities[0..i];
                break;
            }

            var cap = Capability{
                .id = dev.read8(cap_addr),
                .next = dev.read8(cap_addr + 1),
                .len = dev.read8(cap_addr + 2),
                .data = undefined,
            };

            var data = try mem.boottime_allocator.?.alloc(u8, cap.len);
            for (0..cap.len) |j| {
                data[j] = dev.read8(cap_addr + @as(u8, @intCast(j)));
            }
            cap.data = data;

            capabilities[i] = cap;

            cap_addr = cap.next;

            if (i == 15) {
                @panic("pci: too many capabilities");
            }
        }

        dev.capabilities = capabilities;

        return dev;
    }

    fn headerType(self: *const Self) u8 {
        return self.read8(0xe);
    }

    fn isSingleFunction(self: *const Self) bool {
        return (self.headerType() & 0x80) == 0;
    }

    pub fn enable_bus_master(self: *Self) void {
        const command = self.read32(4);
        self.write32(4, command | (1 << 2));
    }

    // offset is in bytes
    fn read8(self: *const Self, offset: u8) u8 {
        const value = readConfig(self.bus, self.slot, self.func, offset & 0xfc);
        return @as(u8, @intCast(((value >> @as(u5, @intCast(((offset & 0x03) * 8)))) & 0xff)));
    }

    // offset is in bytes
    fn read32(self: *const Self, offset: u8) u32 {
        return readConfig(self.bus, self.slot, self.func, offset);
    }

    fn write32(self: *const Self, offset: u8, value: u32) void {
        const b = @as(u32, @intCast(self.bus));
        const s = @as(u32, @intCast(self.slot));
        const f = @as(u32, @intCast(self.func));
        const o = @as(u32, @intCast(offset));
        const address: u32 = 0x80000000 | (b << 16) | (s << 11) | (f << 8) | (o & 0xfc);
        x64.out(CONDIG_ADDRESS, address);
        x64.out(CONDIG_DATA, value);
    }
};

// This requires mem.init to have been called
pub fn init() void {
    // TODO: check for host bridge
    // TODO: check for PCI-to-PCI bridge

    var root = Device{
        .bus = 0,
        .slot = 0,
        .func = 0,
        .config = undefined,
        .capabilities = undefined,
    };

    if (root.isSingleFunction()) {
        scanBus(0);
        return;
    }

    for (0..8) |func| {
        const device = scanFunction(0, 0, @as(u8, @intCast(func)));
        if (device) |d| {
            devices[null_device_index] = d;
            null_device_index += 1;
        }
    }
}

fn scanFunction(bus: u8, slot: u8, func: u8) ?Device {
    const device = Device.new(bus, slot, func) catch return null;

    log.info.printf("pci: found device at bus {}, slot {}, func {}\n", .{ bus, slot, func });
    log.info.printf("pci: vendor id: {x}\n", .{device.config.vendor_id});
    log.info.printf("pci: device id: {x}\n", .{device.config.device_id});

    return device;
}

fn scanBus(bus: u8) void {
    for (0..32) |slot| {
        const device = scanFunction(bus, @as(u8, @intCast(slot)), 0);
        if (device) |d| {
            devices[null_device_index] = d;
            null_device_index += 1;
        }
    }
}

// offset is in bytes
fn readConfig(bus: u8, slot: u8, func: u8, offset: u8) u32 {
    const b = @as(u32, @intCast(bus));
    const s = @as(u32, @intCast(slot));
    const f = @as(u32, @intCast(func));
    const o = @as(u32, @intCast(offset));
    const address: u32 = 0x80000000 | (b << 16) | (s << 11) | (f << 8) | (o & 0xfc);
    x64.out(CONDIG_ADDRESS, address);
    return x64.in(u32, CONDIG_DATA);
}
