.text
.align 4
.global _main
_main:
    stp x29, x30, [sp, #-96]!
    mov x29, sp
.LBB_main_entry:
    mov x9, #27
    str x9, [x29, #16]
    mov x9, #0
    str x9, [x29, #32]
    b .LBB_main_loop
.LBB_main_loop:
    ldr x9, [x29, #16]
    mov x10, #1
    cmp x9, x10
    cset x9, eq
    str x9, [x29, #48]
    ldr x9, [x29, #48]
    str x9, [sp, #-16]!
    ldr x9, [sp], #16
    cbnz x9, .LBB_main_done
    b .LBB_main_check_even
.LBB_main_check_even:
    ldr x9, [x29, #16]
    mov x10, #2
    sdiv x11, x9, x10
    msub x9, x11, x10, x9
    str x9, [x29, #56]
    ldr x9, [x29, #56]
    mov x10, #0
    cmp x9, x10
    cset x9, eq
    str x9, [x29, #64]
    ldr x9, [x29, #64]
    str x9, [sp, #-16]!
    ldr x9, [sp], #16
    cbnz x9, .LBB_main_even
    b .LBB_main_odd
.LBB_main_even:
    ldr x9, [x29, #16]
    mov x10, #2
    sdiv x9, x9, x10
    str x9, [x29, #72]
    ldr x9, [x29, #72]
    str x9, [x29, #24]
    b .LBB_main_update
.LBB_main_odd:
    ldr x9, [x29, #16]
    mov x10, #3
    mul x9, x9, x10
    str x9, [x29, #80]
    ldr x9, [x29, #80]
    mov x10, #1
    add x9, x9, x10
    str x9, [x29, #88]
    ldr x9, [x29, #88]
    str x9, [x29, #24]
    b .LBB_main_update
.LBB_main_update:
    ldr x9, [x29, #32]
    mov x10, #1
    add x9, x9, x10
    str x9, [x29, #40]
    ldr x9, [x29, #24]
    str x9, [x29, #16]
    ldr x9, [x29, #40]
    str x9, [x29, #32]
    b .LBB_main_loop
.LBB_main_done:
    ldr x0, [x29, #32]
    ldp x29, x30, [sp], #96
    ret
