// asm.s — Main entry point for the bootstrapped AArch64 assembler
// AArch64 macOS (Apple Silicon)
// Calling convention: AAPCS64 (x0-x7 args, x0 return, x29/x30 frame pair, x18 reserved)
//
// Program flow:
//   1. Parse command-line arguments (input .s file, optional output .o file)
//   2. Open and read the input file into a heap buffer
//   3. Initialize subsystems (sym, lex, parse, macho)
//   4. Tokenize the input (_lex_tokenize)
//   5. Pass 1: collect labels and compute section sizes (_parse_pass1)
//   6. Pass 2: encode instructions, fill section buffers (_parse_pass2)
//   7. Build symbol/string tables for Mach-O output (_macho_build_symtab)
//   8. Copy parse buffers into macho globals
//   9. Open output file, emit Mach-O object, close files
//  10. Free memory, exit(0)
//
// Usage: asm <input.s> [output.o]

.section __TEXT,__text,regular,pure_instructions
.p2align 2

// =============================================================================
// External references — libSystem
// =============================================================================
.extern _open
.extern _read
.extern _write
.extern _close
.extern _malloc
.extern _free
.extern _exit

// =============================================================================
// External references — lexer (lexer.s)
// =============================================================================
.extern _lex_init
.extern _lex_tokenize
.extern _lex_free

// =============================================================================
// External references — parser (parser.s)
// =============================================================================
.extern _parse_init
.extern _parse_pass1
.extern _parse_pass2
.extern _parse_free
.extern _parse_text_buf
.extern _parse_text_size
.extern _parse_data_buf
.extern _parse_data_size

// =============================================================================
// External references — symbol table (symtab.s)
// =============================================================================
.extern _sym_init

// =============================================================================
// External references — Mach-O emitter (macho.s)
// =============================================================================
.extern _macho_init
.extern _macho_build_symtab
.extern _macho_emit
.extern _macho_text_buf
.extern _macho_text_size
.extern _macho_data_buf
.extern _macho_data_size

// =============================================================================
// External references — error reporting (error.s)
// =============================================================================
.extern _error_exit

// =============================================================================
// Constants
// =============================================================================
.set O_RDONLY,       0
.set O_WRONLY,       0x0001
.set O_CREAT,       0x0200
.set O_TRUNC,       0x0400
.set O_WR_CR_TR,    0x0601          // O_WRONLY | O_CREAT | O_TRUNC
.set FILE_MODE,     0x1A4           // 0644 octal
.set READ_BUF_SIZE, 0x400000        // 4 MB read buffer

// =============================================================================
// Public symbols
// =============================================================================
.globl _main


// =============================================================================
// _main — Entry point
// =============================================================================
// Args (from kernel/dyld):
//   x0 = argc
//   x1 = argv  (array of char* pointers)
.p2align 2
_main:
    stp     x29, x30, [sp, #-96]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]

    // Save argc and argv
    mov     x19, x0                     // x19 = argc
    mov     x20, x1                     // x20 = argv

    // -------------------------------------------------------------------------
    // Step 1: Validate arguments
    // -------------------------------------------------------------------------
    cmp     x19, #2
    b.ge    .Largs_ok

    // argc < 2: print usage and exit(1)
    adrp    x0, _usage_msg@PAGE
    add     x0, x0, _usage_msg@PAGEOFF
    bl      _error_exit                 // does not return

.Largs_ok:
    // x21 = input filename (argv[1])
    ldr     x21, [x20, #8]

    // x22 = output filename (argv[2] if provided, else derived)
    cmp     x19, #3
    b.lt    .Lderive_output
    ldr     x22, [x20, #16]
    b       .Lhave_output

.Lderive_output:
    // Derive output filename: copy input name, replace .s with .o (or append .o)
    mov     x0, x21
    bl      _derive_output_name
    mov     x22, x0                     // x22 = derived output filename
    // x23 = 1 means we malloced the output name and must free it later
    mov     x23, #1
    b       .Lopen_input

.Lhave_output:
    mov     x23, #0                     // did not malloc output name

    // -------------------------------------------------------------------------
    // Step 2: Open and read the input file
    // -------------------------------------------------------------------------
.Lopen_input:
    // open(input_path, O_RDONLY)
    mov     x0, x21
    mov     x1, #O_RDONLY
    mov     x2, #0
    bl      _open
    cmp     x0, #0
    b.ge    .Lopen_ok

    // open failed
    adrp    x0, _err_open_input@PAGE
    add     x0, x0, _err_open_input@PAGEOFF
    bl      _error_exit

.Lopen_ok:
    mov     x24, x0                     // x24 = input fd

    // Allocate read buffer (4 MB)
    mov     x0, #READ_BUF_SIZE
    bl      _malloc
    cbz     x0, .Loom
    mov     x25, x0                     // x25 = read buffer pointer

    // Read the entire file in a loop
    mov     x26, #0                     // x26 = total bytes read

.Lread_loop:
    mov     x0, x24                     // fd
    add     x1, x25, x26               // buf + offset
    mov     x2, #READ_BUF_SIZE
    sub     x2, x2, x26                // remaining space
    cbz     x2, .Lread_done            // buffer full
    bl      _read
    cmp     x0, #0
    b.le    .Lread_done                 // 0 = EOF, negative = error
    add     x26, x26, x0               // accumulate bytes
    b       .Lread_loop

.Lread_done:
    // Close input file
    mov     x0, x24
    bl      _close

    // x25 = input buffer, x26 = input length
    // Null-terminate for safety (we have 4MB buffer, file is smaller)
    strb    wzr, [x25, x26]

    // -------------------------------------------------------------------------
    // Step 3: Initialize subsystems
    // -------------------------------------------------------------------------
    bl      _sym_init

    // Initialize lexer with input buffer
    mov     x0, x25                     // input ptr
    mov     x1, x26                     // input len
    bl      _lex_init

    bl      _parse_init
    bl      _macho_init

    // -------------------------------------------------------------------------
    // Step 4: Tokenize
    // -------------------------------------------------------------------------
    bl      _lex_tokenize
    mov     x27, x0                     // x27 = token count (for reference)

    // -------------------------------------------------------------------------
    // Step 5: Pass 1 — collect labels and section sizes
    // -------------------------------------------------------------------------
    bl      _parse_pass1

    // -------------------------------------------------------------------------
    // Step 6: Pass 2 — encode instructions, fill section buffers
    // -------------------------------------------------------------------------
    bl      _parse_pass2

    // -------------------------------------------------------------------------
    // Step 7: Build symbol and string tables for Mach-O
    // -------------------------------------------------------------------------
    bl      _macho_build_symtab

    // -------------------------------------------------------------------------
    // Step 8: Copy parse section buffers to macho globals
    // -------------------------------------------------------------------------
    // _macho_text_buf = _parse_text_buf
    adrp    x8, _parse_text_buf@PAGE
    add     x8, x8, _parse_text_buf@PAGEOFF
    ldr     x9, [x8]
    adrp    x10, _macho_text_buf@PAGE
    add     x10, x10, _macho_text_buf@PAGEOFF
    str     x9, [x10]

    // _macho_text_size = _parse_text_size
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x9, [x8]
    adrp    x10, _macho_text_size@PAGE
    add     x10, x10, _macho_text_size@PAGEOFF
    str     x9, [x10]

    // _macho_data_buf = _parse_data_buf
    adrp    x8, _parse_data_buf@PAGE
    add     x8, x8, _parse_data_buf@PAGEOFF
    ldr     x9, [x8]
    adrp    x10, _macho_data_buf@PAGE
    add     x10, x10, _macho_data_buf@PAGEOFF
    str     x9, [x10]

    // _macho_data_size = _parse_data_size
    adrp    x8, _parse_data_size@PAGE
    add     x8, x8, _parse_data_size@PAGEOFF
    ldr     x9, [x8]
    adrp    x10, _macho_data_size@PAGE
    add     x10, x10, _macho_data_size@PAGEOFF
    str     x9, [x10]

    // -------------------------------------------------------------------------
    // Step 9: Open output file and emit Mach-O
    // -------------------------------------------------------------------------
    // open(output_path, O_WRONLY|O_CREAT|O_TRUNC, 0644)
    mov     x0, x22
    mov     x1, #O_WR_CR_TR
    mov     x2, #FILE_MODE
    bl      _open
    cmp     x0, #0
    b.ge    .Lout_open_ok

    adrp    x0, _err_open_output@PAGE
    add     x0, x0, _err_open_output@PAGEOFF
    bl      _error_exit

.Lout_open_ok:
    mov     x28, x0                     // x28 = output fd

    // Emit the Mach-O object file
    mov     x0, x28                     // fd
    bl      _macho_emit

    // Close output file
    mov     x0, x28
    bl      _close

    // -------------------------------------------------------------------------
    // Step 10: Cleanup and exit
    // -------------------------------------------------------------------------

    // Free the input buffer
    mov     x0, x25
    bl      _free

    // Free lexer token array
    bl      _lex_free

    // Free parser buffers
    bl      _parse_free

    // Free derived output filename if we allocated it
    cbz     x23, .Lskip_free_outname
    mov     x0, x22
    bl      _free
.Lskip_free_outname:

    // Exit successfully
    mov     x0, #0
    ldp     x27, x28, [sp, #80]
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #96
    ret                                 // return 0 from main

.Loom:
    adrp    x0, _err_oom@PAGE
    add     x0, x0, _err_oom@PAGEOFF
    bl      _error_exit


// =============================================================================
// _derive_output_name — Derive .o filename from input filename
// =============================================================================
// Args:   x0 = input filename (null-terminated C string)
// Returns: x0 = pointer to malloc'd output filename string
//
// Strategy: copy the input filename, find the last '.', replace everything
// after it with 'o'. If no '.' is found, append ".o" to the end.
.p2align 2
_derive_output_name:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                     // x19 = input filename

    // Compute string length
    mov     x20, #0                     // x20 = length counter
    mov     x21, #-1                    // x21 = last dot position (-1 = none)
.Lder_len:
    ldrb    w8, [x19, x20]
    cbz     w8, .Lder_len_done
    cmp     w8, #'.'
    b.ne    .Lder_no_dot
    mov     x21, x20                    // record position of this dot
.Lder_no_dot:
    add     x20, x20, #1
    b       .Lder_len

.Lder_len_done:
    // x20 = strlen(input), x21 = last dot pos or -1

    // Calculate output name length
    // If dot found: dot_pos + 2 (for ".o\0")
    // If no dot: strlen + 3 (for ".o\0")
    cmn     x21, #1                     // compare x21 with -1
    b.eq    .Lder_no_ext

    // Has extension: output length = dot_pos + 2 + 1(null)
    add     x0, x21, #3
    b       .Lder_alloc

.Lder_no_ext:
    // No extension: output length = strlen + 2 + 1(null)
    add     x0, x20, #3
    mov     x21, x20                    // treat "dot position" as end of string

.Lder_alloc:
    mov     x22, x0                     // x22 = alloc size
    bl      _malloc
    cbz     x0, .Lder_oom

    // Copy characters up to the dot position
    mov     x8, #0                      // copy index
.Lder_copy:
    cmp     x8, x21
    b.ge    .Lder_copy_done
    ldrb    w9, [x19, x8]
    strb    w9, [x0, x8]
    add     x8, x8, #1
    b       .Lder_copy

.Lder_copy_done:
    // Append ".o\0"
    mov     w9, #'.'
    strb    w9, [x0, x8]
    add     x8, x8, #1
    mov     w9, #'o'
    strb    w9, [x0, x8]
    add     x8, x8, #1
    strb    wzr, [x0, x8]

    // x0 already points to the new string
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

.Lder_oom:
    adrp    x0, _err_oom@PAGE
    add     x0, x0, _err_oom@PAGEOFF
    bl      _error_exit


// =============================================================================
// Data section — string constants
// =============================================================================
.section __DATA,__data

.p2align 3
_usage_msg:
    .asciz "usage: asm <input.s> [output.o]"

_err_open_input:
    .asciz "failed to open input file"

_err_open_output:
    .asciz "failed to open output file"

_err_oom:
    .asciz "out of memory"
