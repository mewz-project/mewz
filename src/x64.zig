const std = @import("std");

pub const EFLAGS_IF = 0x00000200;

pub fn init() void {
    enableSSE();
    enableAVX();
}

pub fn in(comptime Type: type, port: u16) Type {
    return switch (Type) {
        u8 => asm volatile ("inb %[port], %[result]"
            : [result] "={al}" (-> Type),
            : [port] "{dx}" (port),
        ),
        u16 => asm volatile ("inw %[port], %[result]"
            : [result] "={ax}" (-> Type),
            : [port] "{dx}" (port),
        ),
        u32 => asm volatile ("inl %[port], %[result]"
            : [result] "={eax}" (-> Type),
            : [port] "{dx}" (port),
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
        : .{ .memory = true, .cc = true });
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
        : .{ .memory = true, .cc = true });
}

pub fn lgdt(p: usize, size: u16) void {
    const pd = [3]u16{
        size - 1, @as(u16, @intCast(p & 0xffff)), @as(u16, @intCast(p >> 16)),
    };

    asm volatile ("lgdt (%%eax)"
        :
        : [pd] "{eax}" (@intFromPtr(&pd)),
        : .{ .memory = true });
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
        : .{ .memory = true });
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
        : .{ .memory = true });
}

pub fn shutdown(status: u16) void {
    out(0x501, status);
}

pub const CpuidResult = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var eax: u32 = leaf;
    var ebx: u32 = undefined;
    var ecx: u32 = subleaf;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "+{eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "+{ecx}" (ecx),
          [edx] "={edx}" (edx),
    );
    return .{
        .eax = eax,
        .ebx = ebx,
        .ecx = ecx,
        .edx = edx,
    };
}

pub fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

const kvm_cpuid_signature: u32 = 0x4000_0000;
const kvm_cpuid_timing_info: u32 = 0x4000_0010;
const kvm_signature_ebx: u32 = 0x4b4d_564b; // "KVMK"
const kvm_signature_ecx: u32 = 0x564b_4d56; // "VMKV"
const kvm_signature_edx: u32 = 0x0000_004d; // "M"

/// Returns TSC frequency in Hz from the KVM PV timing CPUID leaf (0x40000010).
/// EAX holds the virtual TSC frequency in kHz.
pub fn kvmTscFrequencyHz() ?u64 {
    const signature = cpuid(kvm_cpuid_signature, 0);
    if (signature.ebx != kvm_signature_ebx or
        signature.ecx != kvm_signature_ecx or
        signature.edx != kvm_signature_edx)
    {
        return null;
    }

    if (signature.eax < kvm_cpuid_timing_info) {
        return null;
    }

    const timing = cpuid(kvm_cpuid_timing_info, 0);
    if (timing.eax == 0) {
        return null;
    }

    return @as(u64, timing.eax) * 1000;
}

fn enableSSE() void {
    asm volatile (
        \\.intel_syntax noprefix
        \\mov rax, cr0
        \\and ax, 0xFFFB
        \\or ax, 0x2
        \\mov cr0, rax
        \\mov rax, cr4
        \\or rax, 643 << 9
        \\mov cr4, rax
        ::: .{ .rax = true });
}

fn enableAVX() void {
    // Enable AVX and AVX-512 state in XCR0:
    //   Bit 0: X87 FPU
    //   Bit 1: SSE (XMM)
    //   Bit 2: AVX (YMM upper 128-bit)
    //   Bit 5: Opmask (k0-k7)
    //   Bit 6: ZMM_Hi256 (upper 256-bit of ZMM0-15)
    //   Bit 7: Hi16_ZMM (full ZMM16-31)
    asm volatile (
        \\.intel_syntax noprefix
        \\
        \\ // Query CPU-supported XCR0 bits via CPUID leaf 0Dh
        \\mov eax, 0x0d
        \\xor ecx, ecx
        \\cpuid
        \\mov ebx, eax
        \\
        \\ // Read current XCR0
        \\xor ecx, ecx
        \\xgetbv
        \\ // Set desired bits, masked by CPU-supported bits
        \\and ebx, 0xe7
        \\or eax, ebx
        \\xsetbv
        ::: .{ .rax = true, .rbx = true, .rcx = true, .rdx = true, .cc = true });
}
