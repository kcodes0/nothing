// expect: 55
.text
.global _main
_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #0          // sum = 0
    mov x1, #1          // i = 1
loop:
    add x0, x0, x1      // sum += i
    add x1, x1, #1      // i++
    cmp x1, #11
    b.lt loop            // if i < 11, continue
    ldp x29, x30, [sp], #16
    bl _exit
