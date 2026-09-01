const std = @import("std");

const max_argc = 64;

var argv_storage: [max_argc][]const u8 = undefined;
var argc: usize = 0;

/// Parse guest command-line arguments from the multiboot cmdline.
///
/// Only tokens after a `--` separator become guest argv. Kernel parameters
/// (`ip=10.0.2.15/24`, etc.) must appear before `--`.
pub fn init(cmdline: []const u8) void {
    argc = 0;
    var after_separator = false;
    var iter = std.mem.splitScalar(u8, cmdline, ' ');
    while (iter.next()) |part| {
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "--")) {
            after_separator = true;
            continue;
        }
        if (!after_separator) continue;
        if (argc >= max_argc) break;
        argv_storage[argc] = part;
        argc += 1;
    }
}

pub fn getArgc() usize {
    return argc;
}

pub fn getArgv() []const []const u8 {
    return argv_storage[0..argc];
}

pub fn argvBufSize() usize {
    var size: usize = 0;
    for (getArgv()) |arg| {
        size += arg.len + 1;
    }
    return size;
}
