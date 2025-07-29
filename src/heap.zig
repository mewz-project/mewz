// kallocator comes from zig's stdlib: https://github.com/ziglang/zig/blob/master/lib/std/heap.zig
// Hear is the original license:
//
// The MIT License (Expat)
//
// Copyright (c) Zig contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

const std = @import("std");
const mem = @import("mem.zig");
const sync = @import("sync.zig");

const Allocator = std.mem.Allocator;
const SpinLock = sync.SpinLock(empty);

const empty = struct {};

extern fn malloc(usize) ?*anyopaque;
extern fn realloc(?*anyopaque, usize) ?*anyopaque;
extern fn free(?*anyopaque) void;

var e = empty{};
var lock = SpinLock.new(&e);

pub const Error = Allocator.Error;
// this implementation is come from zig's stdlib: https://github.com/ziglang/zig/blob/master/lib/std/heap.zig
pub const runtime_allocator = Allocator{
    .ptr = undefined,
    .vtable = &raw_c_allocator_vtable,
};

const raw_c_allocator_vtable = Allocator.VTable{
    .alloc = rawCAlloc,
    .resize = rawCResize,
    .remap = rawCRemap,
    .free = rawCFree,
};

const ENOMEM = 12;
extern var errno: i32;

const INITIAL_PROGRAM_BREAK: usize = 0xffffc00000000000;
var program_break: usize = INITIAL_PROGRAM_BREAK;
var program_break_end: usize = INITIAL_PROGRAM_BREAK;

pub export fn sbrk(diff: i32) usize {
    if (diff < 0) {
        const diff_abs = -diff;
        const old_program_break = program_break;
        program_break = program_break - @as(usize, @intCast(diff_abs));
        return old_program_break;
    }

    const next_program_break = program_break + @as(usize, @intCast(diff));
    if (next_program_break >= program_break_end) {
        _ = mem.allocAndMapBlock(program_break_end);
        program_break_end += mem.BLOCK_SIZE;
        return sbrk(diff);
    }

    const old_program_break = program_break;
    program_break = next_program_break;
    return old_program_break;
}

fn rawCAlloc(
    _: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    ret_addr: usize,
) ?[*]u8 {
    _ = ret_addr;

    _ = lock.acquire();
    defer lock.release();

    std.debug.assert(alignment.compare(.lte, .of(std.c.max_align_t)));
    // Note that this pointer cannot be aligncasted to max_align_t because if
    // len is < max_align_t then the alignment can be smaller. For example, if
    // max_align_t is 16, but the user requests 8 bytes, there is no built-in
    // type in C that is size 8 and has 16 byte alignment, so the alignment may
    // be 8 bytes rather than 16. Similarly if only 1 byte is requested, malloc
    // is allowed to return a 1-byte aligned pointer.
    return @ptrCast(malloc(len));
}

fn rawCResize(
    context: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    return_address: usize,
) bool {
    _ = context;
    _ = memory;
    _ = alignment;
    _ = new_len;
    _ = return_address;
    return false;
}

fn rawCRemap(
    context: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    new_len: usize,
    return_address: usize,
) ?[*]u8 {
    _ = context;
    _ = alignment;
    _ = return_address;

    _ = lock.acquire();
    defer lock.release();

    return @ptrCast(realloc(memory.ptr, new_len));
}

fn rawCFree(
    context: *anyopaque,
    memory: []u8,
    alignment: std.mem.Alignment,
    return_address: usize,
) void {
    _ = context;
    _ = alignment;
    _ = return_address;

    _ = lock.acquire();
    defer lock.release();

    free(memory.ptr);
}
