// strings.s — String and memory utility functions for the bootstrapped assembler
// AArch64 macOS (Apple Silicon)
// Calling convention: AAPCS64 (x0-x7 args, x0 return, x29/x30 frame pair, x18 reserved)

.section __TEXT,__text

// =============================================================================
// str_cmp — Compare two length-prefixed strings
//   x0 = ptr_a, x1 = len_a, x2 = ptr_b, x3 = len_b
//   Returns: x0 = 0 if equal, non-zero if different
// =============================================================================
.globl _str_cmp
.p2align 2
_str_cmp:
    // Leaf-like but uses a loop; no calls, so skip frame setup
    // First compare lengths
    cmp     x1, x3
    b.ne    .Lstr_cmp_neq           // Lengths differ — not equal

    // Lengths match. Compare byte-by-byte.
    // x1 = remaining count, x0 = ptr_a, x2 = ptr_b
    cbz     x1, .Lstr_cmp_eq        // Both empty — equal
    mov     x4, x0                  // Save ptr_a (we'll walk x4 and x2)
    mov     x5, x2                  // Save ptr_b
    mov     x6, x1                  // Counter

.Lstr_cmp_loop:
    ldrb    w7, [x4], #1
    ldrb    w8, [x5], #1
    cmp     w7, w8
    b.ne    .Lstr_cmp_neq
    subs    x6, x6, #1
    b.ne    .Lstr_cmp_loop

.Lstr_cmp_eq:
    mov     x0, #0
    ret

.Lstr_cmp_neq:
    mov     x0, #1
    ret


// =============================================================================
// str_to_int — Parse decimal integer from string (supports leading '-')
//   x0 = ptr, x1 = len
//   Returns: x0 = parsed integer value
// =============================================================================
.globl _str_to_int
.p2align 2
_str_to_int:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     x2, x0                  // x2 = current pointer
    mov     x3, x1                  // x3 = remaining length
    mov     x4, #0                  // x4 = accumulator
    mov     x5, #0                  // x5 = is_negative flag

    // Check for empty string
    cbz     x3, .Lsti_done

    // Check for leading '-'
    ldrb    w6, [x2]
    cmp     w6, #'-'
    b.ne    .Lsti_parse_loop
    mov     x5, #1                  // Mark negative
    add     x2, x2, #1             // Skip '-'
    subs    x3, x3, #1
    b.eq    .Lsti_done              // String was just "-"

.Lsti_parse_loop:
    ldrb    w6, [x2], #1
    sub     w6, w6, #'0'           // Convert ASCII digit to value
    // Accumulate: x4 = x4 * 10 + digit
    mov     x7, #10
    mul     x4, x4, x7
    and     x6, x6, #0xff         // Zero-extend byte to 64-bit
    add     x4, x4, x6
    subs    x3, x3, #1
    b.ne    .Lsti_parse_loop

.Lsti_done:
    // Apply sign
    cbz     x5, .Lsti_positive
    neg     x4, x4

.Lsti_positive:
    mov     x0, x4

    ldp     x29, x30, [sp], #16
    ret


// =============================================================================
// str_to_hex — Parse hex integer from string (after "0x" prefix stripped)
//   x0 = ptr, x1 = len (hex digits only)
//   Returns: x0 = parsed integer value
// =============================================================================
.globl _str_to_hex
.p2align 2
_str_to_hex:
    // Leaf function — no calls
    mov     x2, x0                  // x2 = current pointer
    mov     x3, x1                  // x3 = remaining length
    mov     x4, #0                  // x4 = accumulator

    cbz     x3, .Lsth_done

.Lsth_loop:
    ldrb    w5, [x2], #1

    // Classify the hex digit
    cmp     w5, #'0'
    b.lt    .Lsth_done              // Invalid char — stop
    cmp     w5, #'9'
    b.le    .Lsth_digit

    cmp     w5, #'A'
    b.lt    .Lsth_done
    cmp     w5, #'F'
    b.le    .Lsth_upper

    cmp     w5, #'a'
    b.lt    .Lsth_done
    cmp     w5, #'f'
    b.le    .Lsth_lower

    b       .Lsth_done              // Invalid char — stop

.Lsth_digit:
    sub     w5, w5, #'0'           // 0-9
    b       .Lsth_accum

.Lsth_upper:
    sub     w5, w5, #'A'
    add     w5, w5, #10            // A-F -> 10-15
    b       .Lsth_accum

.Lsth_lower:
    sub     w5, w5, #'a'
    add     w5, w5, #10            // a-f -> 10-15

.Lsth_accum:
    lsl     x4, x4, #4             // accumulator <<= 4
    and     x5, x5, #0xff         // Zero-extend byte to 64-bit
    add     x4, x4, x5            // accumulator += digit
    subs    x3, x3, #1
    b.ne    .Lsth_loop

.Lsth_done:
    mov     x0, x4
    ret


// =============================================================================
// memcpy_custom — Copy bytes from src to dst
//   x0 = dst, x1 = src, x2 = len
//   Returns: x0 = dst
// =============================================================================
.globl _memcpy_custom
.p2align 2
_memcpy_custom:
    // Leaf function
    mov     x3, x0                  // Save dst for return value
    cbz     x2, .Lmcpy_done

.Lmcpy_loop:
    ldrb    w4, [x1], #1
    strb    w4, [x3], #1
    subs    x2, x2, #1
    b.ne    .Lmcpy_loop

.Lmcpy_done:
    // x0 still holds original dst
    ret


// =============================================================================
// memset_custom — Fill memory with a byte value
//   x0 = dst, x1 = value (byte), x2 = len
//   Returns: x0 = dst
// =============================================================================
.globl _memset_custom
.p2align 2
_memset_custom:
    // Leaf function
    mov     x3, x0                  // Save dst for return value
    cbz     x2, .Lmset_done

.Lmset_loop:
    strb    w1, [x3], #1
    subs    x2, x2, #1
    b.ne    .Lmset_loop

.Lmset_done:
    // x0 still holds original dst
    ret


// =============================================================================
// str_len — Compute length of null-terminated string
//   x0 = ptr
//   Returns: x0 = length (not including null terminator)
// =============================================================================
.globl _str_len
.p2align 2
_str_len:
    // Leaf function
    mov     x1, x0                  // x1 = walking pointer
    mov     x2, #0                  // x2 = length counter

.Lslen_loop:
    ldrb    w3, [x1], #1
    cbz     w3, .Lslen_done
    add     x2, x2, #1
    b       .Lslen_loop

.Lslen_done:
    mov     x0, x2
    ret


// =============================================================================
// str_copy — Copy null-terminated string from src to dst
//   x0 = dst, x1 = src
//   Returns: x0 = dst
// =============================================================================
.globl _str_copy
.p2align 2
_str_copy:
    // Leaf function
    mov     x2, x0                  // Save dst for return value
    mov     x3, x0                  // x3 = walking dst pointer

.Lscpy_loop:
    ldrb    w4, [x1], #1
    strb    w4, [x3], #1
    cbnz    w4, .Lscpy_loop         // Copy including the null terminator

    mov     x0, x2                  // Return original dst
    ret


// =============================================================================
// int_to_str — Convert signed 64-bit integer to decimal string
//   x0 = value (signed i64), x1 = buffer pointer
//   Returns: x0 = length of string written
//
// Strategy: push digits onto the stack in reverse, then copy them out in order.
// =============================================================================
.globl _int_to_str
.p2align 2
_int_to_str:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    // We use the scratch area at sp+16..sp+47 (32 bytes) for digit storage

    mov     x2, x1                  // x2 = buffer pointer
    mov     x3, #0                  // x3 = digit count
    mov     x4, #0                  // x4 = is_negative flag

    // Handle zero specially
    cbnz    x0, .Lits_not_zero
    mov     w5, #'0'
    strb    w5, [x2]
    mov     x0, #1
    ldp     x29, x30, [sp], #48
    ret

.Lits_not_zero:
    // Check for negative
    tbnz    x0, #63, .Lits_negative
    mov     x1, x0                  // x1 = absolute value
    b       .Lits_gen_digits

.Lits_negative:
    mov     x4, #1                  // Mark negative
    neg     x1, x0                  // x1 = absolute value

.Lits_gen_digits:
    // Generate digits in reverse order, store in scratch area on stack
    mov     x5, #10
    add     x6, x29, #16           // x6 = scratch buffer base (on stack)

.Lits_div_loop:
    udiv    x7, x1, x5             // x7 = quotient
    msub    x8, x7, x5, x1         // x8 = remainder (x1 - x7*10)
    add     w8, w8, #'0'           // Convert to ASCII
    strb    w8, [x6, x3]           // Store digit
    add     x3, x3, #1
    mov     x1, x7                  // quotient becomes new value
    cbnz    x1, .Lits_div_loop

    // Now x3 = digit count, digits are in reverse order in scratch buffer
    // Write '-' if negative
    cbz     x4, .Lits_reverse
    mov     w8, #'-'
    strb    w8, [x2], #1

.Lits_reverse:
    // Copy digits from scratch buffer in reverse order to output buffer
    sub     x7, x3, #1             // x7 = index into scratch (start from end)

.Lits_rev_loop:
    ldrb    w8, [x6, x7]
    strb    w8, [x2], #1
    subs    x7, x7, #1
    b.ge    .Lits_rev_loop

    // Calculate total length: digit_count + is_negative
    add     x0, x3, x4

    ldp     x29, x30, [sp], #48
    ret


// =============================================================================
// int_to_hex_str — Convert integer to hex string (no "0x" prefix)
//   x0 = value, x1 = buffer pointer
//   Returns: x0 = length of string written
//
// Strategy: extract nibbles from most significant to least, skip leading zeros.
// =============================================================================
.globl _int_to_hex_str
.p2align 2
_int_to_hex_str:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     x2, x1                  // x2 = buffer pointer (walking)
    mov     x3, x1                  // x3 = buffer start (for length calc)

    // Handle zero specially
    cbnz    x0, .Liths_not_zero
    mov     w4, #'0'
    strb    w4, [x2]
    mov     x0, #1
    ldp     x29, x30, [sp], #16
    ret

.Liths_not_zero:
    // Find the highest non-zero nibble
    // Count leading zeros, round down to nibble boundary
    clz     x4, x0                  // x4 = leading zero bits
    lsr     x4, x4, #2             // x4 = leading zero nibbles
    mov     x5, #16
    sub     x5, x5, x4             // x5 = number of nibbles to emit
    // Shift position: start from the topmost non-zero nibble
    // bit_shift = (x5 - 1) * 4
    sub     x6, x5, #1
    lsl     x6, x6, #2             // x6 = initial shift amount

.Liths_nibble_loop:
    lsr     x7, x0, x6             // Extract nibble
    and     x7, x7, #0xf

    cmp     x7, #10
    b.lt    .Liths_dec_digit
    // a-f
    add     w7, w7, #('a' - 10)
    b       .Liths_store

.Liths_dec_digit:
    add     w7, w7, #'0'

.Liths_store:
    strb    w7, [x2], #1
    subs    x6, x6, #4             // Move to next nibble
    b.ge    .Liths_nibble_loop

    // Length = current position - start
    sub     x0, x2, x3

    ldp     x29, x30, [sp], #16
    ret


// =============================================================================
// str_starts_with — Check if string starts with a prefix
//   x0 = str_ptr, x1 = str_len, x2 = prefix_ptr, x3 = prefix_len
//   Returns: x0 = 1 if starts with prefix, 0 otherwise
// =============================================================================
.globl _str_starts_with
.p2align 2
_str_starts_with:
    // Leaf function
    // If prefix is longer than string, cannot match
    cmp     x3, x1
    b.hi    .Lssw_no

    // If prefix is empty, always matches
    cbz     x3, .Lssw_yes

    // Compare prefix_len bytes
    mov     x4, x0                  // x4 = str walking pointer
    mov     x5, x2                  // x5 = prefix walking pointer
    mov     x6, x3                  // x6 = remaining count

.Lssw_loop:
    ldrb    w7, [x4], #1
    ldrb    w8, [x5], #1
    cmp     w7, w8
    b.ne    .Lssw_no
    subs    x6, x6, #1
    b.ne    .Lssw_loop

.Lssw_yes:
    mov     x0, #1
    ret

.Lssw_no:
    mov     x0, #0
    ret


// =============================================================================
// str_eq_lit — Compare length-prefixed string with null-terminated literal
//   x0 = str_ptr, x1 = str_len, x2 = literal_ptr (null-terminated)
//   Returns: x0 = 1 if equal, 0 if not
//
// Strategy: walk both strings. After str_len bytes, the literal must be at '\0'.
// =============================================================================
.globl _str_eq_lit
.p2align 2
_str_eq_lit:
    // Leaf function
    mov     x3, x0                  // x3 = str walking pointer
    mov     x4, x2                  // x4 = literal walking pointer
    mov     x5, x1                  // x5 = remaining string length

    // If string is empty, literal must be empty too
    cbz     x5, .Lsel_check_lit_end

.Lsel_loop:
    ldrb    w6, [x3], #1            // Next byte from string
    ldrb    w7, [x4], #1            // Next byte from literal
    cbz     w7, .Lsel_no             // Literal ended early — not equal
    cmp     w6, w7
    b.ne    .Lsel_no
    subs    x5, x5, #1
    b.ne    .Lsel_loop

.Lsel_check_lit_end:
    // We've consumed all str_len bytes. Literal must also be at null terminator.
    ldrb    w7, [x4]
    cbnz    w7, .Lsel_no             // Literal has more chars — not equal

    mov     x0, #1
    ret

.Lsel_no:
    mov     x0, #0
    ret
