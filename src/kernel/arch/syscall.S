.section .text
.globl syscall_entry
syscall_entry:
    swapgs
    movq %rsp, %gs:8  // Save user RSP to percpu.user_rsp
    movq %gs:0, %rsp  // Load kernel stack top from percpu.kstack_top
    
    // Build Registers frame for syscall_handler
    // IRETQ-like frame: SS, RSP, R11(RFLAGS), CS, RCX(RIP)
    pushq $0x1b       // SS
    pushq %gs:8       // User RSP
    pushq %r11        // RFLAGS
    pushq $0x23       // CS
    pushq %rcx        // RIP
    
    pushq $0          // error code
    pushq $0x80       // int_no (dummy for syscall)
    
    pushq %rax
    pushq %rbx
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %rbp
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    
    movq %rsp, %rdi
    
    pushq %r12
    movq %rsp, %r12
    andq $-16, %rsp
    subq $512, %rsp
    fxsave (%rsp)
    
    .extern syscall_handler
    call syscall_handler
    
    fxrstor (%rsp)
    movq %r12, %rsp
    popq %r12
    
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rbp
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rbx
    // Don't pop rax, it holds the return value
    addq $8, %rsp
    
    addq $16, %rsp    // skip int_no and error code
    
    popq %rcx         // original RIP
    addq $8, %rsp     // skip CS
    popq %r11         // original RFLAGS
    popq %rsp         // original RSP
    
    swapgs
    sysretq

.globl jump_to_user_asm
jump_to_user_asm:
    cli
    // rdi = *Registers, rsi = pml4
    
    // 1. Switch to user CR3
    movq %rsi, %cr3
    
    // 2. Build IRETQ frame on kernel stack
    // Registers layout: r15..rax (15), int_no, err, rip, cs, rflags, rsp, ss
    pushq 168(%rdi) // SS
    pushq 160(%rdi) // RSP
    pushq 152(%rdi) // RFLAGS
    pushq 144(%rdi) // CS
    pushq 136(%rdi) // RIP
    
    // 3. Set segments to User Data
    movw $0x1b, %ax
    movw %ax, %ds
    movw %ax, %es
    // FS/GS are usually handled via swapgs or special MSRs
    
    // 4. Restore general purpose registers
    movq 0(%rdi), %r15
    movq 8(%rdi), %r14
    movq 16(%rdi), %r13
    movq 24(%rdi), %r12
    movq 32(%rdi), %r11
    movq 40(%rdi), %r10
    movq 48(%rdi), %r9
    movq 56(%rdi), %r8
    movq 64(%rdi), %rbp
    // Skip RDI for now as it points to the frame
    movq 80(%rdi), %rsi
    movq 88(%rdi), %rdx
    movq 96(%rdi), %rcx
    movq 104(%rdi), %rbx
    movq 112(%rdi), %rax
    
    // Finally restore RDI
    movq 72(%rdi), %rdi
    
    // 5. GO!
    iretq

