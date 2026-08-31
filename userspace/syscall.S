.section .text

.global syscall0
syscall0:
    movq %rdi, %rax
    syscall
    ret

.global syscall1
syscall1:
    movq %rdi, %rax
    movq %rsi, %rdi
    syscall
    ret

.global syscall2
syscall2:
    movq %rdi, %rax
    movq %rsi, %rdi
    movq %rdx, %rsi
    syscall
    ret

.global syscall3
syscall3:
    movq %rdi, %rax
    movq %rsi, %rdi
    movq %rdx, %rsi
    movq %rcx, %rdx
    syscall
    ret
