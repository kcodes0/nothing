.text
.align 4
.global _main
_main:
    stp x29, x30, [sp, #-112]!
    mov x29, sp
.LBB_main_entry:
    mov x9, #0
    str x9, [x29, #16]
    mov x9, #0
    str x9, [x29, #32]
    b .LBB_main_outer
.LBB_main_outer:
    mov x9, #0
    str x9, [x29, #48]
    ldr x9, [x29, #32]
    str x9, [x29, #64]
    b .LBB_main_inner
.LBB_main_inner:
    ldr x9, [x29, #64]
    mov x10, #1
    add x9, x9, x10
    str x9, [x29, #72]
    ldr x9, [x29, #48]
    mov x10, #1
    add x9, x9, x10
    str x9, [x29, #56]
    ldr x9, [x29, #56]
    mov x10, #10
    cmp x9, x10
    cset x9, ge
    str x9, [x29, #80]
    ldr x9, [x29, #80]
    str x9, [sp, #-16]!
    ldr x9, [x29, #72]
    str x9, [x29, #40]
    ldr x9, [sp], #16
    cbnz x9, .LBB_main_outer_inc
    ldr x9, [x29, #56]
    str x9, [x29, #48]
    ldr x9, [x29, #72]
    str x9, [x29, #64]
    b .LBB_main_inner
.LBB_main_outer_inc:
    ldr x9, [x29, #16]
    mov x10, #1
    add x9, x9, x10
    str x9, [x29, #24]
    ldr x9, [x29, #24]
    mov x10, #10
    cmp x9, x10
    cset x9, ge
    str x9, [x29, #88]
    ldr x9, [x29, #88]
    str x9, [sp, #-16]!
    ldr x9, [x29, #40]
    str x9, [x29, #96]
    ldr x9, [sp], #16
    cbnz x9, .LBB_main_done
    ldr x9, [x29, #24]
    str x9, [x29, #16]
    ldr x9, [x29, #40]
    str x9, [x29, #32]
    b .LBB_main_outer
.LBB_main_done:
    ldr x0, [x29, #96]
    ldp x29, x30, [sp], #112
    ret
