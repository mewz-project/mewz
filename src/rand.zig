const Random = @import("std").rand.Random;

pub const X64Random = Random{
    .ptr = undefined,
    .fillFn = x64FillFn,
};

pub fn x64FillFn(p: *anyopaque, b: []u8) void {
    _ = p;
    var buf = b;
    for (0..buf.len / 8) |i| {
        const r = asm ("rdrand %[reg]"
            : [reg] "=r" (-> u64),
        );
        const ptr = @as(*u64, @ptrCast(@alignCast(&buf[i * 8])));
        ptr.* = r;
    }

    if (buf.len % 8 != 0) {
        var r = asm ("rdrand %[reg]"
            : [reg] "=r" (-> u64),
        );
        const randBuf = @as([*]u8, @ptrCast(&r));
        for (0..buf.len % 8) |i| {
            buf[buf.len - buf.len % 8 + i] = randBuf[i];
        }
    }
}
