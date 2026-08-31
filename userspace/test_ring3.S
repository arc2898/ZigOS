.section .text
.globl _start
_start:
    // We are in Ring 3.
    // Let's try to trigger a syscall for 'R'
    mov $1, %rax
    mov $1, %rdi
    lea msg_r(%rip), %rsi
    mov $1, %rdx
    syscall

    // Trigger a syscall for '3'
    mov $1, %rax
    mov $1, %rdi
    lea msg_3(%rip), %rsi
    mov $1, %rdx
    syscall

    // Loop forever
loop:
    jmp loop

.section .data
msg_r: .ascii "R"
msg_3: .ascii "3"
