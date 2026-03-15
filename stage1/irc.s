// Stage 1 IR Compiler - Main Entry Point
// Reads an IR text file, lexes, parses, and generates AArch64 assembly to stdout
// Target: AArch64 macOS (Apple Silicon)

.global _main
.align 4

.equ SYS_EXIT,    1
.equ SYS_READ,    3
.equ SYS_WRITE,   4
.equ SYS_OPEN,    5
.equ SYS_CLOSE,   6
.equ MAX_FILE_SIZE, 1048576
.equ MAX_OUTPUT,    4194304

.text

_main:
    stp     x29, x30, [sp, #-96]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]

    mov     x19, x0             // argc
    mov     x20, x1             // argv

    // Check argc >= 2
    cmp     x19, #2
    b.ge    1f
    adrp    x1, _msg_usage@PAGE
    add     x1, x1, _msg_usage@PAGEOFF
    mov     x2, #31
    mov     x0, #2
    mov     x16, #SYS_WRITE
    svc     #0x80
    mov     x0, #1
    b       99f

1:  // Open file argv[1]
    ldr     x0, [x20, #8]
    mov     x1, #0
    mov     x2, #0
    mov     x16, #SYS_OPEN
    svc     #0x80
    b.cs    90f
    mov     x21, x0             // fd

    // Allocate read buffer
    mov     x0, #MAX_FILE_SIZE
    bl      _malloc
    mov     x22, x0

    // Read file
    mov     x0, x21
    mov     x1, x22
    mov     x2, #MAX_FILE_SIZE
    mov     x16, #SYS_READ
    svc     #0x80
    b.cs    91f
    mov     x23, x0             // bytes_read

    // Close file
    mov     x0, x21
    mov     x16, #SYS_CLOSE
    svc     #0x80

    // Allocate token buffer (16384 tokens * 32 bytes)
    mov     x0, #524288
    bl      _malloc
    mov     x24, x0

    // Lex
    mov     x0, x22
    mov     x1, x23
    mov     x2, x24
    bl      _lexer_tokenize
    mov     x25, x0             // num_tokens

    // Allocate output buffer
    mov     x0, #MAX_OUTPUT
    bl      _malloc
    mov     x26, x0

    // Parse and codegen
    mov     x0, x24
    mov     x1, x25
    mov     x2, x22
    mov     x3, x26
    bl      _parse_and_codegen
    mov     x27, x0             // output_len

    // Write output to stdout
    mov     x0, #1
    mov     x1, x26
    mov     x2, x27
    mov     x16, #SYS_WRITE
    svc     #0x80

    // Free
    mov     x0, x22
    bl      _free
    mov     x0, x24
    bl      _free
    mov     x0, x26
    bl      _free

    mov     x0, #0
    b       99f

90: // open error
    adrp    x1, _msg_open_err@PAGE
    add     x1, x1, _msg_open_err@PAGEOFF
    mov     x2, #24
    mov     x0, #2
    mov     x16, #SYS_WRITE
    svc     #0x80
    mov     x0, #1
    b       99f

91: // read error
    adrp    x1, _msg_read_err@PAGE
    add     x1, x1, _msg_read_err@PAGEOFF
    mov     x2, #19
    mov     x0, #2
    mov     x16, #SYS_WRITE
    svc     #0x80
    mov     x0, #1

99: // exit
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldp     x29, x30, [sp], #96
    ret

.data
_msg_usage:     .ascii "Usage: irc <input.ir>\n"
                .ascii "         \n"
_msg_open_err:  .ascii "Error: cannot open file\n"
_msg_read_err:  .ascii "Error: read failed\n"
