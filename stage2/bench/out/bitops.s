.text
.align 4
.global _main
_main:
    stp x29, x30, [sp, #-48]!
    mov x29, sp
.LBB_main_entry:
    mov x9, #255
    mov x10, #0
    add x9, x9, x10
    str x9, [x29, #16]
    mov x9, #85
    mov x10, #0
    add x9, x9, x10
    str x9, [x29, #24]
    ldr x9, [x29, #16]
    ldr x10, [x29, #24]
    eor x9, x9, x10
    str x9, [x29, #32]
    ldr x9, [x29, #32]
    mov x10, #255
    and x9, x9, x10
    str x9, [x29, #40]
    ldr x0, [x29, #40]
    ldp x29, x30, [sp], #48
    ret
