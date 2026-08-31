import sys

def main():
    print(".section .text")
    print(".globl isr_address")
    print("isr_address:")
    print("    movzx %dil, %edi")
    print("    lea isr_table(%rip), %rax")
    print("    mov (%rax, %rdi, 8), %rax")
    print("    ret")
    print("")
    print(".globl loadIdt")
    print("loadIdt:")
    print("    lidt (%rdi)")
    print("    ret")
    print("")
    print(".globl isr_common")
    print("isr_common:")
    print("    pushq %rax")
    print("    pushq %rbx")
    print("    pushq %rcx")
    print("    pushq %rdx")
    print("    pushq %rsi")
    print("    pushq %rdi")
    print("    pushq %rbp")
    print("    pushq %r8")
    print("    pushq %r9")
    print("    pushq %r10")
    print("    pushq %r11")
    print("    pushq %r12")
    print("    pushq %r13")
    print("    pushq %r14")
    print("    pushq %r15")
    print("    ")
    print("    testb $3, 144(%rsp)")
    print("    jz isr_from_kernel")
    print("    swapgs")
    print("")
    print("isr_from_kernel:")
    print("    movq %rsp, %rdi")
    print("    pushq %r12")
    print("    movq %rsp, %r12")
    print("    andq $-16, %rsp")
    print("    subq $512, %rsp")
    print("    fxsave (%rsp)")
    print("    cld")
    print("    .extern isr_handler")
    print("    call isr_handler")
    print("    fxrstor (%rsp)")
    print("    movq %r12, %rsp")
    print("    popq %r12")
    print("")
    print("    testb $3, 144(%rsp)")
    print("    jz isr_return_to_kernel")
    print("    swapgs")
    print("")
    print("isr_return_to_kernel:")
    print("    popq %r15")
    print("    popq %r14")
    print("    popq %r13")
    print("    popq %r12")
    print("    popq %r11")
    print("    popq %r10")
    print("    popq %r9")
    print("    popq %r8")
    print("    popq %rbp")
    print("    popq %rdi")
    print("    popq %rsi")
    print("    popq %rdx")
    print("    popq %rcx")
    print("    popq %rbx")
    print("    popq %rax")
    print("    addq $16, %rsp")
    print("    iretq")
    print("")

    has_error = [8, 10, 11, 12, 13, 14, 17]

    for i in range(256):
        print(f".globl isr_stub_{i}")
        print(f"isr_stub_{i}:")
        if i not in has_error:
            print("    pushq $0")
        print(f"    pushq ${i}")
        print("    jmp isr_common")
    
    print("")
    print(".globl isr_table")
    print(".align 8")
    print("isr_table:")
    for i in range(256):
        print(f"    .quad isr_stub_{i}")

if __name__ == "__main__":
    out_file = None
    if "-o" in sys.argv:
        idx = sys.argv.index("-o")
        if idx + 1 < len(sys.argv):
            out_file = sys.argv[idx + 1]
    
    if out_file:
        with open(out_file, 'w') as f:
            sys.stdout = f
            main()
    else:
        main()
