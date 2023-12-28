const multiboot = @import("multiboot.zig");
const log = @import("log.zig");
const sync = @import("sync.zig");
const util = @import("util.zig");

const SpinLock = sync.SpinLock;

const std = @import("std");
const Allocator = std.mem.Allocator;
const FixedBufferAllocator = std.heap.FixedBufferAllocator;

// end of the kernel image (defined in linker script)
pub extern const image_end: u8;

pub const BLOCK_SIZE = 65536; // 64KiB
pub const PAGE_SIZE = 4096; // 4KiB
const MIN_BOOTTIME_ALLOCATOR_SIZE = 10 * 1024 * 1024; // 10 MiB

var free_blocks_internal: ?*FreeList = null;
var free_blocks_lock = SpinLock(?*FreeList).new(&free_blocks_internal);

// This can be used only during the boot time.
// This allocates memory in physical address.
pub var boottime_allocator: ?Allocator = null;
var boottime_fba: ?FixedBufferAllocator = null;

const FreeList = struct {
    next: ?*FreeList,
};

const PageMapEntry = packed struct {
    present: u1,
    writable: u1,
    user_accessible: u1,
    write_through: u1,
    cache_disable: u1,
    accessed: u1,
    dirty: u1,
    huge_page: u1,
    global: u1,
    rsv1: u3,
    address: u40,
    rsv2: u12,

    // pages for PageMapEntry
    var free_pages_internal: ?*FreeList = null;
    var free_pages_lock = SpinLock(?*FreeList).new(&free_pages_internal);

    extern var __kernel_pml4: [512]PageMapEntry;

    const Self = @This();

    // allocate pages for PageMapEntry in a 64KiB block
    fn allocPages() void {
        // get a 64KiB block of physical memory
        const block_addr = allocBlock();

        const free_pages = free_pages_lock.acquire();
        defer free_pages_lock.release();

        // split the block into 4KiB pages
        var current_addr = block_addr;
        while (current_addr < block_addr + BLOCK_SIZE) : (current_addr += PAGE_SIZE) {
            const page = @as(*FreeList, @ptrFromInt(current_addr));
            page.next = free_pages.*;
            free_pages.* = page;
        }
    }

    // allocate a new blank table of entries
    fn allocTable() *[512]PageMapEntry {
        var free_pages = free_pages_lock.acquire();
        defer free_pages_lock.release();

        // allocate a new block of pages if necessary
        if (free_pages.* == null) {
            free_pages_lock.release();
            allocPages();
            free_pages = free_pages_lock.acquire();
        }

        // get a page from the free list
        const page = free_pages.*;
        free_pages.* = page.?.next;

        // initialize the page
        const free_pages_as_bytes = @as([*]u8, @ptrCast(page))[0..PAGE_SIZE];
        @memset(free_pages_as_bytes, 0);

        return @as(*[512]PageMapEntry, @ptrFromInt(@intFromPtr(page)));
    }

    // get the page table entry for the given virtual address
    // if the entry is not present, allocate a new table
    fn lookupEntry(v_addr: usize) *Self {
        var table = &__kernel_pml4;
        var entry: *Self = undefined;
        const levels = [_]u6{ 4, 3, 2, 1 };
        for (levels) |level| {
            const index = (v_addr >> (12 + 9 * (level - 1))) & 0x1ff;
            entry = &table.*[index];
            if (level == 1 or entry.*.huge_page == 1) {
                return entry;
            }
            if (entry.*.present == 0) {
                entry.*.present = 1;
                entry.*.writable = 1;
                entry.*.global = 1;

                const new_table = allocTable();
                if (@intFromPtr(new_table) % PAGE_SIZE != 0) {
                    @panic("mapBlock: entry is not aligned");
                }

                entry.*.address = @as(u40, @intCast((@intFromPtr(new_table) >> 12)));
            }

            {
                @setRuntimeSafety(false);
                table = @as(*[512]PageMapEntry, @ptrFromInt(entry.getPointAddr()));
            }
        }

        unreachable;
    }

    // map a 64KiB block of physical memory to a virtual address
    fn mapBlock(v_addr: usize, p_addr: usize) void {
        if (v_addr % BLOCK_SIZE != 0) {
            @panic("mapBlock: v_addr is not aligned");
        }
        if (p_addr % PAGE_SIZE != 0) {
            @panic("mapBlock: p_addr is not aligned");
        }

        // get the page table entry for the given virtual address
        // the virtual address is aligned to the block size, so the pages are in the same table
        const pt_ptr = lookupEntry(v_addr);
        var pt_iterator = @as([*]PageMapEntry, @ptrCast(pt_ptr));

        // map the pages of the block
        for (0..(BLOCK_SIZE / PAGE_SIZE)) |i| {
            const pt = &pt_iterator[i];

            if (pt.*.present == 1) {
                @panic("mapBlock: page already mapped");
            }

            pt.*.present = 1;
            pt.*.writable = 1;
            pt.*.global = 1;

            const mapped_page_addr = p_addr + i * PAGE_SIZE;
            pt.*.address = @as(u40, @intCast(mapped_page_addr >> 12));
        }
    }

    // get the address pointed to by this entry
    fn getPointAddr(self: *Self) usize {
        return @as(usize, self.address << 12) & 0x7ffffffffffff000;
    }
};

pub fn init(info: *multiboot.BootInfo) void {
    const image_end_addr = @intFromPtr(&image_end);

    {
        // disable alignment checks for mmaps
        @setRuntimeSafety(false);

        // mmap_addr points to the MemoryMap array
        // mmap_length is the size of the MemoryMap array in bytes
        const mmaps_ptr = @as([*]multiboot.MemoryMap, @ptrFromInt(info.mmap_addr));
        const mmaps = mmaps_ptr[0 .. info.mmap_length / @sizeOf(multiboot.MemoryMap)];

        for (mmaps) |*mmap| {
            if (mmap.type == multiboot.MemoryType.available) {
                // exclude the kernel image from available memory, because it's already used
                const base = @max(image_end_addr, mmap.base);
                const end = mmap.base + mmap.length;
                if (end <= base) {
                    continue;
                }
                log.info.printf("available memory: {x} - {x}\n", .{ base, end });

                // align the range to BLOCK_SIZE
                const aligned_base = util.roundUp(usize, base, PAGE_SIZE);
                const aligned_end = util.roundDown(usize, end, PAGE_SIZE);

                const length = aligned_end - aligned_base;
                if (length >= MIN_BOOTTIME_ALLOCATOR_SIZE) {
                    // create a new allocator for the boot time
                    const buf = @as([*]u8, @ptrFromInt(aligned_base))[0..length];
                    boottime_fba = FixedBufferAllocator.init(buf);
                    boottime_allocator = boottime_fba.?.allocator();
                } else {
                    // add the range to the free list
                    initRange(aligned_base, length);
                }
            }
        }
    }
}

pub fn init2() void {
    const base = @intFromPtr(boottime_fba.?.buffer.ptr) + boottime_fba.?.end_index;
    const length = boottime_fba.?.buffer.len - boottime_fba.?.end_index;
    const aligned_base = util.roundUp(usize, base, PAGE_SIZE);
    const aligned_length = util.roundDown(usize, length, PAGE_SIZE);
    initRange(aligned_base, aligned_length);

    boottime_allocator = null;
    boottime_fba = null;
}

// allocate a 64KiB block of physical memory
pub fn allocBlock() usize {
    const free_blocks = free_blocks_lock.acquire();
    defer free_blocks_lock.release();

    if (free_blocks.*) |block| {
        free_blocks.* = block.next;
        return @intFromPtr(block);
    }
    @panic("out of memory");
}

pub fn getPaddr(v_addr: usize) usize {
    const entry = PageMapEntry.lookupEntry(v_addr);
    const page_addr = entry.getPointAddr();
    var offset: usize = undefined;
    if (entry.huge_page == 1) {
        offset = v_addr & 0x1fffff;
    } else {
        offset = v_addr & 0xfff;
    }
    return page_addr + offset;
}

// allocate a 64KiB block of physical memory and map it to a virtual address
// it returns the physical address of the block
pub fn allocAndMapBlock(v_addr: usize) usize {
    const block = allocBlock();
    fillBlockZero(block);
    PageMapEntry.mapBlock(v_addr, block);
    return block;
}

fn fillBlockZero(block_addr: usize) void {
    const buf = @as([*]u8, @ptrFromInt(block_addr))[0..BLOCK_SIZE];
    @memset(buf, 0);
}

fn printSize() void {
    const free_blocks = free_blocks_lock.acquire();
    defer free_blocks_lock.release();

    var current = free_blocks.*;
    var count: u32 = 0;
    var size: u32 = 0;
    while (current != null) : (current = current.?.next) {
        size += BLOCK_SIZE;
        count += 1;
    }
    log.info.printf("free memory: {x} bytes, {d} blocks\n", .{ size, count });
}

// base and length must be aligned to BLOCK_SIZE
fn initRange(base: usize, length: usize) void {
    if (length == 0) {
        return;
    }

    if (base % PAGE_SIZE != 0) {
        @panic("freeRange: base is not aligned");
    }
    if (length % PAGE_SIZE != 0) {
        @panic("freeRange: length is not aligned");
    }

    const free_blocks = free_blocks_lock.acquire();
    defer free_blocks_lock.release();

    // prepend the blocks to the free list
    var current = base;
    while (current < base + length) : (current += BLOCK_SIZE) {
        // TODO: check if the address is already mapped
        const block = @as(*FreeList, @ptrFromInt(current));
        block.next = free_blocks.*;
        free_blocks.* = block;
    }
}
