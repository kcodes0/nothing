// expect: 1
.text
.global _main
_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #10
    mov x1, #20
    cmp x0, x1
    b.lt less_than
    mov x0, #0
    b done
less_than:
    mov x0, #1
done:
    ldp x29, x30, [sp], #16
    bl _exit
