// Stage 1 IR Compiler - Main Entry Point
// Reads an IR text file, lexes, parses, and generates AArch64 assembly to stdout
// Target: AArch64 macOS (Apple Silicon)

.global _main
.align 4

// Syscall numbers for macOS
.equ SYS_EXIT,    1
.equ SYS_READ,    3
.equ SYS_WRITE,   4
.equ SYS_OPEN,    5
.equ SYS_CLOSE,   6

// Constants
.equ MAX_FILE_SIZE, 1048576   // 1MB
.equ MAX_OUTPUT,    4194304   // 4MB output buffer

.text

// _main(argc, argv)
// x0 = argc, x1 = argv
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
    b.ge    .Largs_ok
    // Print usage
    adr     x1, msg_usage
    mov     x2, #42
    mov     x0, #2              // stderr
    mov     x16, #SYS_WRITE
    svc     #0x80
    mov     x0, #1
    b       .Lexit

.Largs_ok:
    // Open file (argv[1])
    ldr     x0, [x20, #8]      // argv[1]
    mov     x1, #0              // O_RDONLY
    mov     x2, #0
    mov     x16, #SYS_OPEN
    svc     #0x80
    // Check for error (carry flag set on error for macOS)
    b.cs    .Lopen_error
    mov     x21, x0             // fd

    // Allocate read buffer
    mov     x0, #MAX_FILE_SIZE
    bl      _malloc
    mov     x22, x0             // read buffer

    // Read file
    mov     x0, x21             // fd
    mov     x1, x22             // buffer
    mov     x2, #MAX_FILE_SIZE
    mov     x16, #SYS_READ
    svc     #0x80
    b.cs    .Lread_error
    mov     x23, x0             // bytes read

    // Close file
    mov     x0, x21
    mov     x16, #SYS_CLOSE
    svc     #0x80

    // Allocate token buffer (space for ~16384 tokens * 32 bytes = 512KB)
    mov     x0, #524288
    bl      _malloc
    mov     x24, x0             // token buffer

    // Call lexer: lexer_tokenize(src, src_len, token_buf) -> num_tokens
    mov     x0, x22             // source text
    mov     x1, x23             // source length
    mov     x2, x24             // token buffer
    bl      _lexer_tokenize
    mov     x25, x0             // num_tokens

    // Allocate output buffer
    mov     x0, #MAX_OUTPUT
    bl      _malloc
    mov     x26, x0             // output buffer

    // Call parser + codegen: parse_and_codegen(tokens, num_tokens, src, output_buf) -> output_len
    mov     x0, x24             // tokens
    mov     x1, x25             // num_tokens
    mov     x2, x22             // source text (for string refs)
    mov     x3, x26             // output buffer
    bl      _parse_and_codegen
    mov     x27, x0             // output length

    // Write output to stdout
    mov     x0, #1              // stdout
    mov     x1, x26             // buffer
    mov     x2, x27             // length
    mov     x16, #SYS_WRITE
    svc     #0x80

    // Free buffers
    mov     x0, x22
    bl      _free
    mov     x0, x24
    bl      _free
    mov     x0, x26
    bl      _free

    // Exit success
    mov     x0, #0
    b       .Lexit

.Lopen_error:
    adr     x1, msg_open_err
    mov     x2, #24
    mov     x0, #2
    mov     x16, #SYS_WRITE
    svc     #0x80
    mov     x0, #1
    b       .Lexit

.Lread_error:
    adr     x1, msg_read_err
    mov     x2, #18
    mov     x0, #2
    mov     x16, #SYS_WRITE
    svc     #0x80
    mov     x0, #1
    b       .Lexit

.Lexit:
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldp     x29, x30, [sp], #96
    ret

.data
msg_usage:      .ascii "Usage: irc <input.ir>\n"
                .ascii "Stage 1 IR Compiler\n"
msg_open_err:   .ascii "Error: cannot open file\n"
msg_read_err:   .ascii "Error: read failed\n"
