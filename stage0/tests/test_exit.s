// expect: 42
.text
.global _main
_main:
    mov x0, #42
    bl _exit
