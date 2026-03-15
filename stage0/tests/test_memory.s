// expect: 30
.text
.global _main
_main:
    stp x29, x30, [sp, #-32]!
    mov x29, sp
    mov x0, #10
    str x0, [x29, #16]     // store 10 at [fp+16]
    mov x0, #20
    str x0, [x29, #24]     // store 20 at [fp+24]
    ldr x0, [x29, #16]     // load 10
    ldr x1, [x29, #24]     // load 20
    add x0, x0, x1         // 30
    ldp x29, x30, [sp], #32
    bl _exit
