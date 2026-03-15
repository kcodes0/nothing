// expect: 84
.text
.global _main
_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #42
    bl double_it
    ldp x29, x30, [sp], #16
    bl _exit

double_it:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    add x0, x0, x0      // x0 = x0 * 2
    ldp x29, x30, [sp], #16
    ret
