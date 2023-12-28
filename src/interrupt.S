// This file is derived from https://github.com/nuta/kerla.
// Here is the original license:

// Permission is hereby granted, free of charge, to any
// person obtaining a copy of this software and associated
// documentation files (the "Software"), to deal in the
// Software without restriction, including without
// limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of
// the Software, and to permit persons to whom the Software
// is furnished to do so, subject to the following
// conditions:
// 
// The above copyright notice and this permission notice
// shall be included in all copies or substantial portions
// of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF
// ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED
// TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
// PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT
// SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
// OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR
// IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

.intel_syntax noprefix
//
//  Interrupt/exception handlers
//
.set INTERRUPT_HANDLER_SIZE, 16

.align INTERRUPT_HANDLER_SIZE
.global interrupt_handlers
interrupt_handlers:
.set i, 0
.rept 256
.set handler_start, .
// Exceptions with error code.
.if i == 8 || 10 <= i && i <= 14 || i == 17
    .align INTERRUPT_HANDLER_SIZE
    // cli
    push i
    jmp interrupt_common
    .align INTERRUPT_HANDLER_SIZE
// Interrupts and exceptions without error code.
.else
    .align INTERRUPT_HANDLER_SIZE
    // cli
    push 0 // Dummy value as error code.
    push i
    jmp interrupt_common
    .align INTERRUPT_HANDLER_SIZE
.endif

// Increment the counter.
.set i, i + 1
.endr

.extern interruptHandler
interrupt_common:
    //
    //  The current stack frame:
    //
    //            +--------------------+
    //     48     |        SS          |
    //            +--------------------+
    //     40     |        RSP         |
    //            +--------------------+
    //     32     |       RFLAGS       |
    //            +--------------------+
    //     24     |        CS          |
    //            +--------------------+
    //     16     |        RIP         |
    //            +--------------------+
    //      8     |     Error code     |
    //            +--------------------+
    //      0     |     IRQ Number     | <- RSP
    //            +--------------------+
    //

    // Check CS register in the IRET frame to determine if the interrupt has
    // occurred in user mode.
    test qword ptr [rsp + 24], 3
    jz 1f
    swapgs
1:
    // Save RDI and set the IRQ number to RDI at once.
    xchg rdi, [rsp]

    // Save registers except RDI (we have already saved it above).
    push r15
    push r14
    push r13
    push r12
    push r11
    push r10
    push r9
    push r8
    push rbp
    push rsi
    push rdx
    push rcx
    push rbx
    push rax

    mov rsi, rsp

    sub    rsp,0x138
    movaps XMMWORD PTR [rsp+0x120],xmm15
    movaps XMMWORD PTR [rsp+0x110],xmm14
    movaps XMMWORD PTR [rsp+0x100],xmm13
    movaps XMMWORD PTR [rsp+0xf0],xmm12

    movaps XMMWORD PTR [rsp+0xe0],xmm11

    movaps XMMWORD PTR [rsp+0xd0],xmm10

    movaps XMMWORD PTR [rsp+0xc0],xmm9

    movaps XMMWORD PTR [rsp+0xb0],xmm8

    movaps XMMWORD PTR [rsp+0xa0],xmm7
    movaps XMMWORD PTR [rsp+0x90],xmm6
    movaps XMMWORD PTR [rsp+0x80],xmm5
    movaps XMMWORD PTR [rsp+0x70],xmm4
    movaps XMMWORD PTR [rsp+0x60],xmm3
    movaps XMMWORD PTR [rsp+0x50],xmm2
    movaps XMMWORD PTR [rsp+0x40],xmm1
    movaps XMMWORD PTR [rsp+0x30],xmm0
    cld
    xorps  xmm0,xmm0
    movaps XMMWORD PTR [rsp],xmm0
    movaps XMMWORD PTR [rsp+0x10],xmm0
    mov    QWORD PTR [rsp+0x20],0x0

    mov    DWORD PTR [rsp],0x0

    call commonInterruptHandler

    mov    eax,0xfee000b0
    mov    QWORD PTR [rsp],rax
    mov    rax,QWORD PTR [rsp]
    mov    DWORD PTR [rax],0x0
    movaps xmm0,XMMWORD PTR [rsp+0x30]
    movaps xmm1,XMMWORD PTR [rsp+0x40]
    movaps xmm2,XMMWORD PTR [rsp+0x50]
    movaps xmm3,XMMWORD PTR [rsp+0x60]
    movaps xmm4,XMMWORD PTR [rsp+0x70]
    movaps xmm5,XMMWORD PTR [rsp+0x80]
    movaps xmm6,XMMWORD PTR [rsp+0x90]
    movaps xmm7,XMMWORD PTR [rsp+0xa0]
    movaps xmm8,XMMWORD PTR [rsp+0xb0]

    movaps xmm9,XMMWORD PTR [rsp+0xc0]

    movaps xmm10,XMMWORD PTR [rsp+0xd0]

    movaps xmm11,XMMWORD PTR [rsp+0xe0]

    movaps xmm12,XMMWORD PTR [rsp+0xf0]

    movaps xmm13,XMMWORD PTR [rsp+0x100]
    movaps xmm14,XMMWORD PTR [rsp+0x110]
    movaps xmm15,XMMWORD PTR [rsp+0x120]
    add    rsp,0x138

    pop rax
    pop rbx
    pop rcx
    pop rdx
    pop rsi
    pop rbp
    pop r8
    pop r9
    pop r10
    pop r11
    pop r12
    pop r13
    pop r14
    pop r15
    pop rdi

    // Skip error code.
    add rsp, 8

    // Check CS register in the IRET frame to determine whether the exception
    // occur in the userspace. If so, do SWAPGS.
    test qword ptr [rsp + 8], 3
    jz 1f

    cli
    swapgs
1:
    iretq
