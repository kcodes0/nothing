// expect: 55
.text
.global _main
_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #10
    mov x1, #20
    add x0, x0, x1      // x0 = 30
    mov x1, #2
    mul x0, x0, x1      // x0 = 60
    sub x0, x0, #5      // x0 = 55
    ldp x29, x30, [sp], #16
    bl _exit
