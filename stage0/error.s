// error.s — Error reporting module for the bootstrapped assembler
// AArch64 macOS (Apple AAPCS64)
//
// Public functions:
//   error_exit     — print "error: <msg>\n" to stderr and exit(1)
//   error_at_line  — print "error at line N: <msg>\n" to stderr and exit(1)
//   warn_at_line   — print "warning at line N: <msg>\n" to stderr (no exit)
//   print_str      — write string to stdout
//   print_int      — write signed integer to stdout
//   print_newline  — write '\n' to stdout
//
// Calling convention notes:
//   - x29 = frame pointer, x30 = link register
//   - x18 is reserved (platform register), never touched
//   - Stack kept 16-byte aligned at all times
//   - External calls: _write(fd, buf, len), _exit(status) from libSystem

.section __TEXT,__text
.p2align 2

// ---------------------------------------------------------------------------
// Private helper: _strlen
// Compute length of a null-terminated string.
//   In:  x0 = pointer to string
//   Out: x0 = length (not including null terminator)
// Clobbers: x1
// ---------------------------------------------------------------------------
_strlen:
    mov     x1, x0                  // x1 = start of string
1:
    ldrb    w2, [x0], #1            // load byte, advance pointer
    cbnz    w2, 1b                  // loop until null terminator
    sub     x0, x0, x1              // x0 = (end+1) - start
    sub     x0, x0, #1             // subtract 1 (we advanced past the null)
    ret

// ---------------------------------------------------------------------------
// Private helper: _int_to_str
// Convert an unsigned 64-bit integer to a decimal string.
//   In:  x0 = value to convert
//        x1 = pointer to buffer (must be >= 20 bytes)
//   Out: x0 = pointer to first digit in buffer
//        x1 = length of resulting string
// Clobbers: x2, x3, x4, x5
// ---------------------------------------------------------------------------
_int_to_str:
    mov     x4, x1                  // x4 = buffer base
    add     x1, x1, #20            // x1 = past end of buffer (work backwards)
    mov     x3, x1                  // x3 = save end position

    // Special case: zero
    cbnz    x0, 2f
    sub     x1, x1, #1
    mov     w2, #'0'
    strb    w2, [x1]
    mov     x0, x1                  // x0 = pointer to "0"
    mov     x1, #1                  // x1 = length 1
    ret

2:  // Division loop: extract digits from least-significant to most
    mov     x5, #10
3:
    cbz     x0, 4f                  // done when quotient is 0
    udiv    x2, x0, x5             // x2 = x0 / 10
    msub    x3, x2, x5, x0        // x3 = x0 - (x2 * 10) = remainder
    add     w3, w3, #'0'           // convert to ASCII digit
    sub     x1, x1, #1
    strb    w3, [x1]               // store digit (right to left)
    mov     x0, x2                  // quotient becomes new value
    b       3b

4:
    // x1 = pointer to first digit
    mov     x0, x1                  // return pointer in x0
    add     x2, x4, #20            // x2 = end of buffer
    sub     x1, x2, x0             // x1 = length of string
    ret

// ---------------------------------------------------------------------------
// Private helper: _signed_int_to_str
// Convert a signed 64-bit integer to a decimal string.
//   In:  x0 = signed value
//        x1 = pointer to buffer (must be >= 21 bytes)
//   Out: x0 = pointer to first character
//        x1 = length of resulting string
// Clobbers: x2, x3, x4, x5, x6
// ---------------------------------------------------------------------------
_signed_int_to_str:
    // Save link register since we call _int_to_str
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    // Check for negative
    tbnz    x0, #63, 1f            // branch if sign bit set

    // Positive: just convert directly
    bl      _int_to_str
    ldp     x29, x30, [sp], #16
    ret

1:  // Negative: negate, convert, then prepend '-'
    neg     x0, x0                  // make positive
    bl      _int_to_str
    // x0 = pointer to first digit, x1 = length
    sub     x0, x0, #1             // back up one byte
    mov     w2, #'-'
    strb    w2, [x0]               // store minus sign
    add     x1, x1, #1            // length includes the sign
    ldp     x29, x30, [sp], #16
    ret

// ===================================================================
// PUBLIC FUNCTIONS
// ===================================================================

// ---------------------------------------------------------------------------
// error_exit
// Print "error: <message>\n" to stderr and exit with code 1.
//   In:  x0 = pointer to null-terminated message string
//   Does not return.
// ---------------------------------------------------------------------------
.globl _error_exit
_error_exit:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x19, [sp, #16]         // save callee-saved register

    mov     x19, x0                 // x19 = message pointer (preserved)

    // Write "error: " prefix to stderr
    mov     x0, #2                  // fd = stderr
    adrp    x1, _err_prefix@PAGE
    add     x1, x1, _err_prefix@PAGEOFF
    mov     x2, #7                  // len = 7 ("error: ")
    bl      _write

    // Compute message length
    mov     x0, x19
    bl      _strlen
    mov     x2, x0                  // x2 = message length

    // Write message to stderr
    mov     x0, #2                  // fd = stderr
    mov     x1, x19                 // buf = message
    bl      _write

    // Write newline to stderr
    mov     x0, #2                  // fd = stderr
    adrp    x1, _newline_str@PAGE
    add     x1, x1, _newline_str@PAGEOFF
    mov     x2, #1                  // len = 1
    bl      _write

    // Exit with code 1
    mov     x0, #1
    bl      _exit

// ---------------------------------------------------------------------------
// error_at_line
// Print "error at line N: <message>\n" to stderr and exit with code 1.
//   In:  x0 = line number (unsigned integer)
//        x1 = pointer to null-terminated message string
//   Does not return.
// ---------------------------------------------------------------------------
.globl _error_at_line
_error_at_line:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x1                 // x19 = message pointer
    mov     x20, x0                 // x20 = line number

    // Write "error at line " prefix to stderr
    mov     x0, #2                  // fd = stderr
    adrp    x1, _err_at_line_prefix@PAGE
    add     x1, x1, _err_at_line_prefix@PAGEOFF
    mov     x2, #14                 // len = 14 ("error at line ")
    bl      _write

    // Convert line number to string (use stack buffer)
    sub     sp, sp, #32             // allocate 32-byte buffer on stack
    mov     x0, x20                 // value = line number
    mov     x1, sp                  // buffer on stack
    bl      _int_to_str
    // x0 = pointer to digits, x1 = length
    mov     x21, x1                 // save length

    // Write line number to stderr
    mov     x2, x21                 // len
    mov     x1, x0                  // buf = digit string
    mov     x0, #2                  // fd = stderr
    bl      _write

    add     sp, sp, #32             // free stack buffer

    // Write ": " separator to stderr
    mov     x0, #2                  // fd = stderr
    adrp    x1, _colon_space@PAGE
    add     x1, x1, _colon_space@PAGEOFF
    mov     x2, #2                  // len = 2 (": ")
    bl      _write

    // Compute message length
    mov     x0, x19
    bl      _strlen
    mov     x2, x0                  // x2 = message length

    // Write message to stderr
    mov     x0, #2                  // fd = stderr
    mov     x1, x19                 // buf = message
    bl      _write

    // Write newline to stderr
    mov     x0, #2                  // fd = stderr
    adrp    x1, _newline_str@PAGE
    add     x1, x1, _newline_str@PAGEOFF
    mov     x2, #1
    bl      _write

    // Exit with code 1
    mov     x0, #1
    bl      _exit

// ---------------------------------------------------------------------------
// warn_at_line
// Print "warning at line N: <message>\n" to stderr. Returns normally.
//   In:  x0 = line number (unsigned integer)
//        x1 = pointer to null-terminated message string
// ---------------------------------------------------------------------------
.globl _warn_at_line
_warn_at_line:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    str     x21, [sp, #32]

    mov     x19, x1                 // x19 = message pointer
    mov     x20, x0                 // x20 = line number

    // Write "warning at line " prefix to stderr
    mov     x0, #2                  // fd = stderr
    adrp    x1, _warn_at_line_prefix@PAGE
    add     x1, x1, _warn_at_line_prefix@PAGEOFF
    mov     x2, #16                 // len = 16 ("warning at line ")
    bl      _write

    // Convert line number to string (use stack buffer)
    sub     sp, sp, #32             // allocate 32-byte buffer on stack
    mov     x0, x20                 // value = line number
    mov     x1, sp                  // buffer on stack
    bl      _int_to_str
    // x0 = pointer to digits, x1 = length
    mov     x21, x1                 // save length

    // Write line number to stderr
    mov     x2, x21                 // len
    mov     x1, x0                  // buf = digit string
    mov     x0, #2                  // fd = stderr
    bl      _write

    add     sp, sp, #32             // free stack buffer

    // Write ": " separator to stderr
    mov     x0, #2                  // fd = stderr
    adrp    x1, _colon_space@PAGE
    add     x1, x1, _colon_space@PAGEOFF
    mov     x2, #2                  // len = 2 (": ")
    bl      _write

    // Compute message length
    mov     x0, x19
    bl      _strlen
    mov     x2, x0                  // x2 = message length

    // Write message to stderr
    mov     x0, #2                  // fd = stderr
    mov     x1, x19                 // buf = message
    bl      _write

    // Write newline to stderr
    mov     x0, #2                  // fd = stderr
    adrp    x1, _newline_str@PAGE
    add     x1, x1, _newline_str@PAGEOFF
    mov     x2, #1
    bl      _write

    // Restore callee-saved registers and return
    ldr     x21, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret

// ---------------------------------------------------------------------------
// print_str
// Write a string to stdout.
//   In:  x0 = pointer to string
//        x1 = length of string
// ---------------------------------------------------------------------------
.globl _print_str
_print_str:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     x2, x1                  // x2 = length
    mov     x1, x0                  // x1 = buffer pointer
    mov     x0, #1                  // fd = stdout
    bl      _write

    ldp     x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------------
// print_int
// Print a signed integer to stdout as a decimal string.
//   In:  x0 = signed 64-bit integer
// ---------------------------------------------------------------------------
.globl _print_int
_print_int:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    // Allocate stack buffer for conversion (32 bytes, already aligned)
    sub     sp, sp, #32
    mov     x1, sp                  // x1 = buffer
    bl      _signed_int_to_str
    // x0 = pointer to string, x1 = length

    // Write to stdout
    mov     x2, x1                  // x2 = length
    mov     x1, x0                  // x1 = buffer
    mov     x0, #1                  // fd = stdout
    bl      _write

    add     sp, sp, #32             // free stack buffer
    ldp     x29, x30, [sp], #16
    ret

// ---------------------------------------------------------------------------
// print_newline
// Print a newline character to stdout.
// ---------------------------------------------------------------------------
.globl _print_newline
_print_newline:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     x0, #1                  // fd = stdout
    adrp    x1, _newline_str@PAGE
    add     x1, x1, _newline_str@PAGEOFF
    mov     x2, #1                  // len = 1
    bl      _write

    ldp     x29, x30, [sp], #16
    ret

// ===================================================================
// DATA SECTION — string constants
// ===================================================================

.section __DATA,__data

_err_prefix:
    .ascii  "error: "               // 7 bytes

_err_at_line_prefix:
    .ascii  "error at line "        // 14 bytes

_warn_at_line_prefix:
    .ascii  "warning at line "      // 16 bytes

_colon_space:
    .ascii  ": "                    // 2 bytes

_newline_str:
    .ascii  "\n"                    // 1 byte
