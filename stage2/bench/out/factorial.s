.text
.align 4
.global _main
_main:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
.LBB_main_entry:
    mov x9, #1
    str x9, [x29, #16]
    mov x9, #1
    str x9, [x29, #32]
    b .LBB_main_loop
.LBB_main_loop:
    ldr x9, [x29, #32]
    ldr x10, [x29, #16]
    mul x9, x9, x10
    str x9, [x29, #40]
    ldr x9, [x29, #16]
    mov x10, #1
    add x9, x9, x10
    str x9, [x29, #24]
    ldr x9, [x29, #24]
    mov x10, #12
    cmp x9, x10
    cset x9, gt
    str x9, [x29, #48]
    ldr x9, [x29, #48]
    str x9, [sp, #-16]!
    ldr x9, [sp], #16
    cbnz x9, .LBB_main_finish
    ldr x9, [x29, #24]
    str x9, [x29, #16]
    ldr x9, [x29, #40]
    str x9, [x29, #32]
    b .LBB_main_loop
.LBB_main_finish:
    ldr x9, [x29, #40]
    mov x10, #256
    sdiv x11, x9, x10
    msub x9, x11, x10, x9
    str x9, [x29, #56]
    ldr x0, [x29, #56]
    ldp x29, x30, [sp], #64
    ret
