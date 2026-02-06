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

    // Use rbp as frame pointer to restore rsp later.
    // (rbp's original value is already saved in the push sequence above.)
    mov rbp, rsp
    and rsp, -64              // Align stack to 64 bytes (required by XSAVE)
    sub rsp, 0xC00            // Allocate 3072 bytes for XSAVE area

    // Zero the XSAVE header before XSAVE.
    // XSAVE writes XSTATE_BV (bytes 512-519) and XCOMP_BV (bytes 520-527),
    // but does NOT clear the reserved area (bytes 528-575).
    // XRSTOR will #GP if those reserved bytes are non-zero.
    mov qword ptr [rsp+0x200], 0
    mov qword ptr [rsp+0x208], 0
    mov qword ptr [rsp+0x210], 0
    mov qword ptr [rsp+0x218], 0
    mov qword ptr [rsp+0x220], 0
    mov qword ptr [rsp+0x228], 0
    mov qword ptr [rsp+0x230], 0
    mov qword ptr [rsp+0x238], 0

    // Save all extended state (X87, SSE, AVX, AVX-512) via XSAVE
    mov edx, 0xFFFFFFFF
    mov eax, 0xFFFFFFFF
    xsave64 [rsp]

    cld
    call commonInterruptHandler

    // Send LAPIC End-of-Interrupt
    mov eax, 0xfee000b0
    mov dword ptr [rax], 0

    // Restore all extended state via XRSTOR
    mov edx, 0xFFFFFFFF
    mov eax, 0xFFFFFFFF
    xrstor64 [rsp]

    // Restore stack pointer
    mov rsp, rbp

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
