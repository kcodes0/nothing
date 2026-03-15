.text
.align 4
.global _gcd
_gcd:
    stp x29, x30, [sp, #-64]!
    mov x29, sp
.LBB_gcd_entry:
    str x0, [x29, #16]
    str x1, [x29, #24]
    ldr x9, [x29, #16]
    str x9, [x29, #32]
    ldr x9, [x29, #24]
    str x9, [x29, #40]
    b .LBB_gcd_loop
.LBB_gcd_loop:
    ldr x9, [x29, #40]
    mov x10, #0
    cmp x9, x10
    cset x9, eq
    str x9, [x29, #56]
    ldr x9, [x29, #56]
    str x9, [sp, #-16]!
    ldr x9, [sp], #16
    cbnz x9, .LBB_gcd_done
    b .LBB_gcd_step
.LBB_gcd_step:
    ldr x9, [x29, #32]
    ldr x10, [x29, #40]
    sdiv x11, x9, x10
    msub x9, x11, x10, x9
    str x9, [x29, #48]
    ldr x9, [x29, #40]
    str x9, [x29, #32]
    ldr x9, [x29, #48]
    str x9, [x29, #40]
    b .LBB_gcd_loop
.LBB_gcd_done:
    ldr x0, [x29, #32]
    ldp x29, x30, [sp], #64
    ret
.global _main
_main:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
.LBB_main_entry:
    mov x0, #48
    mov x1, #18
    bl _gcd
    str x0, [x29, #16]
    ldr x0, [x29, #16]
    ldp x29, x30, [sp], #32
    ret
