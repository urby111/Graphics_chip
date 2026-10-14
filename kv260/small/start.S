.section .text.boot,"ax"
.global _start
.type _start,%function
_start:
 msr daifset, #15
 mrs x0, CurrentEL
 cmp x0, #12
 b.ne fatal
 mrs x0, cptr_el3
 bic x0, x0, #0x400
 msr cptr_el3, x0
 mov x0, #0x300000
 msr cpacr_el1, x0
 mrs x0, sctlr_el3
 bic x0, x0, #1
 bic x0, x0, #4
 bic x0, x0, #0x1000
 msr sctlr_el3, x0
 isb
 ldr x0, =_stack_top
 mov sp, x0
 adr x0, vectors
 msr vbar_el3, x0
 isb
 ldr x0, =_bss_start
 ldr x1, =_bss_end
1: cmp x0, x1
 b.hs 2f
 str xzr, [x0], #8
 b 1b
2: bl main
 ldr x1, =0x0ff00000
 str w0, [x1, #8]
 mov w0, #0xee
 str w0, [x1, #4]
 dsb sy
3: wfe
 b 3b
.balign 2048
vectors:
.rept 16
 b fatal
 .balign 128
.endr
fatal:
 ldr x0, =0x0ff00000
 mov w1, #0xef
 str w1, [x0, #4]
 mrs x1, esr_el3
 str w1, [x0, #12]
 mrs x1, elr_el3
 str w1, [x0, #16]
 mrs x1, far_el3
 str w1, [x0, #20]
 dsb sy
4: wfe
 b 4b
