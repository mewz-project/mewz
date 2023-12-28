pub const EFLAGS_IF = 0x00000200;

pub fn init() void {
    enableSSE();
}

pub fn in(comptime Type: type, port: u16) Type {
    return switch (Type) {
        u8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> Type),
            : [port] "N{dx}" (port),
        ),
        else => @compileError("Invalid data type. Only u8, u16 or u32, found: " ++ @typeName(Type)),
    };
}

pub fn insl(port: u16, addr: usize, cnt: u32) void {
    asm volatile ("cld; rep insl"
        : [a] "=D" (addr),
          [b] "=c" (cnt),
        : [c] "d" (port),
          [d] "0" (addr),
          [e] "1" (cnt),
        : "memory", "cc"
    );
}

pub fn out(port: u16, data: anytype) void {
    switch (@TypeOf(data)) {
        u8 => asm volatile ("outb %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{al}" (data),
        ),
        u16 => asm volatile ("outw %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{ax}" (data),
        ),
        u32 => asm volatile ("outl %[data], %[port]"
            :
            : [port] "{dx}" (port),
              [data] "{eax}" (data),
        ),
        else => @compileError("Invalid data type. Only u8, u16 or u32, found: " ++ @typeName(@TypeOf(data))),
    }
}

pub fn outsl(port: u16, addr: usize, cnt: u32) void {
    asm volatile ("cld; rep outsl"
        : [a] "=S" (addr),
          [b] "=c" (cnt),
        : [c] "d" (port),
          [d] "0" (addr),
          [f] "1" (cnt),
        : "cc"
    );
}

pub fn lgdt(p: usize, size: u16) void {
    const pd = [3]u16{
        size - 1, @as(u16, @intCast(p & 0xffff)), @as(u16, @intCast(p >> 16)),
    };

    asm volatile ("lgdt (%%eax)"
        :
        : [pd] "{eax}" (@intFromPtr(&pd)),
    );
}

pub fn lidt(p: usize, size: u16) void {
    const pd = [5]u16{
        size - 1,
        @as(u16, @intCast(p & 0xffff)),
        @as(u16, @intCast((p >> 16) & 0xffff)),
        @as(u16, @intCast((p >> 32) & 0xffff)),
        @as(u16, @intCast(p >> 48)),
    };

    asm volatile ("lidt (%%eax)"
        :
        : [pd] "{eax}" (@intFromPtr(&pd)),
    );
}

pub fn cr2() u64 {
    const val = asm volatile ("movq %%cr2, %[cr2]"
        : [cr2] "={rax}" (-> u64),
    );

    return val;
}

pub fn lcr3(addr: usize) void {
    asm volatile ("movl %[addr], %%cr3"
        :
        : [addr] "{eax}" (addr),
    );
}

pub fn readeflags() u32 {
    const val = asm volatile ("pushfq; popq %[eflags]"
        : [eflags] "={rax}" (-> u64),
    );

    return @as(u32, @intCast(val));
}

pub fn cli() void {
    asm volatile ("cli");
}

pub fn sti() void {
    asm volatile ("sti");
}

pub fn xchg(addr: *u32, newval: u32) u32 {
    return asm volatile ("lock; xchgl (%[addr]), %[newval]"
        : [result] "={eax}" (-> u32),
        : [addr] "r" (addr),
          [newval] "{eax}" (newval),
        : "memory"
    );
}

pub fn shutdown(status: u16) void {
    out(0x501, status);
}

fn enableSSE() void {
    asm volatile (
        \\.intel_syntax noprefix
        \\mov rax, cr0
        \\and ax, 0xFFFB
        \\or ax, 0x2
        \\mov cr0, rax
        \\mov rax, cr4
        \\or ax, 3 << 9
        \\mov cr4, rax
    );
}
