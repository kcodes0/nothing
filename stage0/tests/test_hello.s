// expect: 0
// stdout: Hello
// NOTE: requires adrp/add relocation support (PAGE/PAGEOFF)
.data
msg:
    .asciz "Hello\n"

.text
.global _main
_main:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x0, #1          // stdout
    adrp x1, msg@PAGE
    add x1, x1, msg@PAGEOFF
    mov x2, #6          // length of "Hello\n"
    bl _write
    mov x0, #0
    ldp x29, x30, [sp], #16
    bl _exit
