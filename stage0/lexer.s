// lexer.s — Tokenizer for ARM64 assembly source files
// Part of the bootstrapped assembler (stage0)
// AArch64 macOS (Apple AAPCS64)
//
// Reads a buffer of assembly source text and produces a stream of tokens.
// Each token is 32 bytes: type(8) | text_ptr(8) | text_len(8) | line_num(8)
//
// External dependencies:
//   _lookup_register  (tables.s)  — classify identifier as register
//   _lookup_mnemonic  (tables.s)  — classify identifier as mnemonic
//   _malloc, _free, _realloc      — libSystem heap allocation

.section __TEXT,__text,regular,pure_instructions
.p2align 2

// ============================================================================
// External references
// ============================================================================
.extern _lookup_register
.extern _lookup_mnemonic
.extern _malloc
.extern _free
.extern _realloc

// ============================================================================
// Public symbols
// ============================================================================
.globl _lex_init
.globl _lex_tokenize
.globl _lex_get_token
.globl _lex_free

// ============================================================================
// Token type constants
// ============================================================================
.set TOK_MNEMONIC,   0
.set TOK_REGISTER,   1
.set TOK_IMMEDIATE,  2
.set TOK_LABEL_DEF,  3
.set TOK_LABEL_REF,  4
.set TOK_LBRACKET,   5
.set TOK_RBRACKET,   6
.set TOK_COMMA,      7
.set TOK_EXCLAIM,    8
.set TOK_DIRECTIVE,  9
.set TOK_NEWLINE,   10
.set TOK_EOF,       11
.set TOK_STRING,    12
.set TOK_HASH,      13
.set TOK_MINUS,     14

// Token struct size: 4 fields * 8 bytes = 32 bytes
.set TOK_SIZE,       32
.set TOK_TYPE_OFF,    0
.set TOK_TEXT_OFF,    8
.set TOK_LEN_OFF,   16
.set TOK_LINE_OFF,  24

// Initial token array capacity
.set INIT_TOK_CAP, 4096


// ============================================================================
// _lex_init — Initialize lexer with input buffer
// ============================================================================
// Args:   x0 = input_ptr, x1 = input_len
// Sets up global state variables and allocates initial token array.
.p2align 2
_lex_init:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    mov     x19, x0                     // x19 = input_ptr
    mov     x20, x1                     // x20 = input_len

    // Store input pointer and length
    adrp    x8, _lex_input@PAGE
    add     x8, x8, _lex_input@PAGEOFF
    str     x19, [x8]

    adrp    x8, _lex_len@PAGE
    add     x8, x8, _lex_len@PAGEOFF
    str     x20, [x8]

    // Reset position to 0
    adrp    x8, _lex_pos@PAGE
    add     x8, x8, _lex_pos@PAGEOFF
    str     xzr, [x8]

    // Reset line number to 1
    adrp    x8, _lex_line@PAGE
    add     x8, x8, _lex_line@PAGEOFF
    mov     x9, #1
    str     x9, [x8]

    // Reset token count to 0
    adrp    x8, _lex_tok_count@PAGE
    add     x8, x8, _lex_tok_count@PAGEOFF
    str     xzr, [x8]

    // Set token capacity
    adrp    x8, _lex_tok_cap@PAGE
    add     x8, x8, _lex_tok_cap@PAGEOFF
    mov     x9, #INIT_TOK_CAP
    str     x9, [x8]

    // Allocate token array: INIT_TOK_CAP * TOK_SIZE bytes
    mov     x0, #INIT_TOK_CAP
    mov     x1, #TOK_SIZE
    mul     x0, x0, x1                  // x0 = total bytes
    bl      _malloc

    // Store token array pointer
    adrp    x8, _lex_tokens@PAGE
    add     x8, x8, _lex_tokens@PAGEOFF
    str     x0, [x8]

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


// ============================================================================
// _lex_free — Free the token array
// ============================================================================
.p2align 2
_lex_free:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    adrp    x8, _lex_tokens@PAGE
    add     x8, x8, _lex_tokens@PAGEOFF
    ldr     x0, [x8]
    cbz     x0, Lfree_done              // nothing to free

    bl      _free

    // Clear the pointer
    adrp    x8, _lex_tokens@PAGE
    add     x8, x8, _lex_tokens@PAGEOFF
    str     xzr, [x8]

Lfree_done:
    ldp     x29, x30, [sp], #16
    ret


// ============================================================================
// _lex_get_token — Get token at index
// ============================================================================
// Args:   x0 = index
// Returns: x0 = pointer to token struct at that index
.p2align 2
_lex_get_token:
    // Leaf function — no frame needed
    adrp    x8, _lex_tokens@PAGE
    add     x8, x8, _lex_tokens@PAGEOFF
    ldr     x8, [x8]                    // x8 = token array base
    mov     x9, #TOK_SIZE
    madd    x0, x0, x9, x8              // x0 = base + index * 32
    ret


// ============================================================================
// emit_token — Add a token to the token array (private helper)
// ============================================================================
// Args:   x0 = type, x1 = text_ptr, x2 = text_len, x3 = line_num
// Grows the array via realloc if capacity is exceeded.
.p2align 2
Lemit_token:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                     // type
    mov     x20, x1                     // text_ptr
    mov     x21, x2                     // text_len
    mov     x22, x3                     // line_num

    // Load current count and capacity
    adrp    x8, _lex_tok_count@PAGE
    add     x8, x8, _lex_tok_count@PAGEOFF
    ldr     x23, [x8]                   // x23 = count

    adrp    x8, _lex_tok_cap@PAGE
    add     x8, x8, _lex_tok_cap@PAGEOFF
    ldr     x24, [x8]                   // x24 = capacity

    // Check if we need to grow
    cmp     x23, x24
    b.lo    Lemit_store                  // count < capacity, proceed

    // Grow: double the capacity
    lsl     x24, x24, #1               // new_cap = old_cap * 2

    // Store new capacity
    adrp    x8, _lex_tok_cap@PAGE
    add     x8, x8, _lex_tok_cap@PAGEOFF
    str     x24, [x8]

    // Realloc the token array
    adrp    x8, _lex_tokens@PAGE
    add     x8, x8, _lex_tokens@PAGEOFF
    ldr     x0, [x8]                    // old pointer
    mov     x1, #TOK_SIZE
    mul     x1, x24, x1                 // new size in bytes
    bl      _realloc

    // Store new pointer
    adrp    x8, _lex_tokens@PAGE
    add     x8, x8, _lex_tokens@PAGEOFF
    str     x0, [x8]

Lemit_store:
    // Compute address: tokens + count * TOK_SIZE
    adrp    x8, _lex_tokens@PAGE
    add     x8, x8, _lex_tokens@PAGEOFF
    ldr     x8, [x8]                    // x8 = token array base
    mov     x9, #TOK_SIZE
    madd    x8, x23, x9, x8             // x8 = &tokens[count]

    // Store token fields
    str     x19, [x8, #TOK_TYPE_OFF]    // type
    str     x20, [x8, #TOK_TEXT_OFF]    // text_ptr
    str     x21, [x8, #TOK_LEN_OFF]    // text_len
    str     x22, [x8, #TOK_LINE_OFF]   // line_num

    // Increment count
    add     x23, x23, #1
    adrp    x8, _lex_tok_count@PAGE
    add     x8, x8, _lex_tok_count@PAGEOFF
    str     x23, [x8]

    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


// ============================================================================
// _lex_tokenize — Tokenize the entire input buffer
// ============================================================================
// No args (uses global state). Returns: x0 = number of tokens produced.
//
// Main loop: skip whitespace (space/tab), then classify and emit token
// based on the current character.
//
// We use callee-saved registers throughout:
//   x19 = input base pointer
//   x20 = current position
//   x21 = input length
//   x22 = current line number
// These are reloaded from globals at the start and stored back at the end.
.p2align 2
_lex_tokenize:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    // Load global state into registers
    adrp    x8, _lex_input@PAGE
    add     x8, x8, _lex_input@PAGEOFF
    ldr     x19, [x8]                   // x19 = input base

    adrp    x8, _lex_pos@PAGE
    add     x8, x8, _lex_pos@PAGEOFF
    ldr     x20, [x8]                   // x20 = position

    adrp    x8, _lex_len@PAGE
    add     x8, x8, _lex_len@PAGEOFF
    ldr     x21, [x8]                   // x21 = input length

    adrp    x8, _lex_line@PAGE
    add     x8, x8, _lex_line@PAGEOFF
    ldr     x22, [x8]                   // x22 = line number

    // ---- Main tokenization loop ----
Ltok_loop:
    // Skip whitespace (space and tab only, NOT newline)
Ltok_skip_ws:
    cmp     x20, x21
    b.ge    Ltok_eof                     // end of input

    ldrb    w23, [x19, x20]             // w23 = current char
    cmp     w23, #' '
    b.eq    Ltok_ws_next
    cmp     w23, #'\t'
    b.eq    Ltok_ws_next
    b       Ltok_classify                // not whitespace, go classify

Ltok_ws_next:
    add     x20, x20, #1
    b       Ltok_skip_ws

    // ---- Classify current character ----
Ltok_classify:
    // Reload current char (still in w23 from skip_ws, but be safe)
    ldrb    w23, [x19, x20]

    // Newline
    cmp     w23, #'\n'
    b.eq    Ltok_newline

    // Comment: // or ;
    cmp     w23, #'/'
    b.eq    Ltok_maybe_comment
    cmp     w23, #';'
    b.eq    Ltok_line_comment

    // Hash: # (immediate or standalone)
    cmp     w23, #'#'
    b.eq    Ltok_hash

    // Brackets and punctuation
    cmp     w23, #'['
    b.eq    Ltok_lbracket
    cmp     w23, #']'
    b.eq    Ltok_rbracket
    cmp     w23, #','
    b.eq    Ltok_comma
    cmp     w23, #'!'
    b.eq    Ltok_exclaim
    cmp     w23, #'-'
    b.eq    Ltok_minus

    // String literal
    cmp     w23, #'"'
    b.eq    Ltok_string

    // Directive (starts with '.')
    cmp     w23, #'.'
    b.eq    Ltok_directive

    // Identifier (letter or underscore)
    bl      Lis_alpha_or_underscore      // clobbers w9; returns w0=1 if yes
    cbnz    w0, Ltok_identifier

    // Digit — bare number (rare, but handle for completeness)
    bl      Lis_digit                    // w23 still loaded; returns w0=1 if yes
    cbnz    w0, Ltok_number

    // Unknown character — skip it
    add     x20, x20, #1
    b       Ltok_loop


    // ================================================================
    // Token handlers
    // ================================================================

    // ---- Newline ----
Ltok_newline:
    add     x24, x19, x20               // text_ptr = input + pos
    mov     x0, #TOK_NEWLINE
    mov     x1, x24
    mov     x2, #1
    mov     x3, x22
    bl      Lemit_token
    add     x20, x20, #1                // consume '\n'
    add     x22, x22, #1                // increment line number
    b       Ltok_loop

    // ---- Maybe comment (//) ----
Ltok_maybe_comment:
    // Check if next char is also '/'
    add     x8, x20, #1
    cmp     x8, x21
    b.ge    Ltok_loop_advance_one        // lone '/' at end — skip
    ldrb    w9, [x19, x8]
    cmp     w9, #'/'
    b.ne    Ltok_loop_advance_one        // lone '/' — skip

    // It is a // comment — skip to end of line
Ltok_line_comment:
    add     x20, x20, #1                // skip the '/' or ';'
Ltok_comment_scan:
    cmp     x20, x21
    b.ge    Ltok_loop                    // hit end of input
    ldrb    w9, [x19, x20]
    cmp     w9, #'\n'
    b.eq    Ltok_loop                    // stop before newline (let main loop emit it)
    add     x20, x20, #1
    b       Ltok_comment_scan

Ltok_loop_advance_one:
    add     x20, x20, #1
    b       Ltok_loop

    // ---- Hash: # ----
    // If followed by digit, '-', or '0x', lex as TOK_IMMEDIATE.
    // Otherwise emit TOK_HASH.
Ltok_hash:
    add     x8, x20, #1                 // position after '#'
    cmp     x8, x21
    b.ge    Ltok_hash_standalone         // '#' at end of input

    ldrb    w9, [x19, x8]

    // Check for '-' after #
    cmp     w9, #'-'
    b.eq    Ltok_hash_immediate

    // Check for digit after #
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.ls    Ltok_hash_immediate          // 0-9

    // Otherwise standalone hash
Ltok_hash_standalone:
    add     x24, x19, x20               // text_ptr
    mov     x0, #TOK_HASH
    mov     x1, x24
    mov     x2, #1
    mov     x3, x22
    bl      Lemit_token
    add     x20, x20, #1                // consume '#'
    b       Ltok_loop

Ltok_hash_immediate:
    // Lex an immediate value after '#'.
    // text_ptr points to char after '#', text_len = length of number part.
    add     x20, x20, #1                // skip '#'
    add     x24, x19, x20               // text_ptr = start of number

    // Check for '-' sign
    ldrb    w9, [x19, x20]
    cmp     w9, #'-'
    b.ne    Ltok_imm_no_neg
    add     x20, x20, #1                // consume '-'

Ltok_imm_no_neg:
    // Check for 0x hex prefix
    cmp     x20, x21
    b.ge    Ltok_imm_done
    ldrb    w9, [x19, x20]
    cmp     w9, #'0'
    b.ne    Ltok_imm_dec_loop
    // Check for 'x' after '0'
    add     x8, x20, #1
    cmp     x8, x21
    b.ge    Ltok_imm_dec_loop
    ldrb    w10, [x19, x8]
    cmp     w10, #'x'
    b.eq    Ltok_imm_hex
    cmp     w10, #'X'
    b.eq    Ltok_imm_hex
    b       Ltok_imm_dec_loop

Ltok_imm_hex:
    // Consume '0x' and hex digits
    add     x20, x20, #2                // skip '0x'
Ltok_imm_hex_loop:
    cmp     x20, x21
    b.ge    Ltok_imm_done
    ldrb    w9, [x19, x20]
    // Check if hex digit: 0-9, a-f, A-F
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.ls    Ltok_imm_hex_next
    sub     w10, w9, #'a'
    cmp     w10, #5
    b.ls    Ltok_imm_hex_next
    sub     w10, w9, #'A'
    cmp     w10, #5
    b.ls    Ltok_imm_hex_next
    b       Ltok_imm_done                // not a hex digit, stop

Ltok_imm_hex_next:
    add     x20, x20, #1
    b       Ltok_imm_hex_loop

Ltok_imm_dec_loop:
    // Consume decimal digits
    cmp     x20, x21
    b.ge    Ltok_imm_done
    ldrb    w9, [x19, x20]
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.hi    Ltok_imm_done                // not a digit, stop
    add     x20, x20, #1
    b       Ltok_imm_dec_loop

Ltok_imm_done:
    // Compute text_len
    add     x8, x19, x20                // current position in buffer
    sub     x2, x8, x24                 // text_len = current - text_ptr
    mov     x0, #TOK_IMMEDIATE
    mov     x1, x24
    // x2 already set
    mov     x3, x22
    bl      Lemit_token
    b       Ltok_loop

    // ---- Single character tokens ----
Ltok_lbracket:
    add     x24, x19, x20
    mov     x0, #TOK_LBRACKET
    mov     x1, x24
    mov     x2, #1
    mov     x3, x22
    bl      Lemit_token
    add     x20, x20, #1
    b       Ltok_loop

Ltok_rbracket:
    add     x24, x19, x20
    mov     x0, #TOK_RBRACKET
    mov     x1, x24
    mov     x2, #1
    mov     x3, x22
    bl      Lemit_token
    add     x20, x20, #1
    b       Ltok_loop

Ltok_comma:
    add     x24, x19, x20
    mov     x0, #TOK_COMMA
    mov     x1, x24
    mov     x2, #1
    mov     x3, x22
    bl      Lemit_token
    add     x20, x20, #1
    b       Ltok_loop

Ltok_exclaim:
    add     x24, x19, x20
    mov     x0, #TOK_EXCLAIM
    mov     x1, x24
    mov     x2, #1
    mov     x3, x22
    bl      Lemit_token
    add     x20, x20, #1
    b       Ltok_loop

Ltok_minus:
    add     x24, x19, x20
    mov     x0, #TOK_MINUS
    mov     x1, x24
    mov     x2, #1
    mov     x3, x22
    bl      Lemit_token
    add     x20, x20, #1
    b       Ltok_loop

    // ---- String literal ----
    // Lex from opening " to closing ".
    // text_ptr/text_len point to content BETWEEN quotes.
Ltok_string:
    add     x20, x20, #1                // skip opening '"'
    add     x24, x19, x20               // text_ptr = start of string content

Ltok_string_loop:
    cmp     x20, x21
    b.ge    Ltok_string_end              // unterminated string (hit EOF)
    ldrb    w9, [x19, x20]
    cmp     w9, #'"'
    b.eq    Ltok_string_end_quote
    cmp     w9, #'\\'
    b.eq    Ltok_string_escape
    cmp     w9, #'\n'
    b.eq    Ltok_string_end              // unterminated string (hit newline)
    add     x20, x20, #1
    b       Ltok_string_loop

Ltok_string_escape:
    // Skip the backslash and the escaped character
    add     x20, x20, #2                // consume \ and the next char
    b       Ltok_string_loop

Ltok_string_end_quote:
    // Compute text_len (content between quotes)
    add     x8, x19, x20
    sub     x2, x8, x24                 // text_len
    mov     x0, #TOK_STRING
    mov     x1, x24
    // x2 already set
    mov     x3, x22
    bl      Lemit_token
    add     x20, x20, #1                // skip closing '"'
    b       Ltok_loop

Ltok_string_end:
    // Unterminated string — emit what we have
    add     x8, x19, x20
    sub     x2, x8, x24
    mov     x0, #TOK_STRING
    mov     x1, x24
    mov     x3, x22
    bl      Lemit_token
    b       Ltok_loop

    // ---- Directive (.text, .data, etc.) ----
    // Starts with '.', followed by alphanumeric chars.
    // Include the dot in the token text.
Ltok_directive:
    add     x24, x19, x20               // text_ptr includes the '.'
    add     x20, x20, #1                // consume '.'

Ltok_directive_loop:
    cmp     x20, x21
    b.ge    Ltok_directive_done
    ldrb    w23, [x19, x20]
    // Check if alphanumeric or '_'
    bl      Lis_alnum_or_underscore
    cbz     w0, Ltok_directive_done
    add     x20, x20, #1
    b       Ltok_directive_loop

Ltok_directive_done:
    add     x8, x19, x20
    sub     x2, x8, x24                 // text_len (includes '.')
    mov     x0, #TOK_DIRECTIVE
    mov     x1, x24
    // x2 set
    mov     x3, x22
    bl      Lemit_token
    b       Ltok_loop

    // ---- Identifier ----
    // Starts with letter or '_'. Reads alphanumeric, '_', and '.' chars.
    // After reading:
    //   - If next char is ':', emit TOK_LABEL_DEF (consume colon)
    //   - Else try _lookup_register, then _lookup_mnemonic
    //   - Fallback: TOK_LABEL_REF
Ltok_identifier:
    add     x24, x19, x20               // text_ptr = start of identifier
    add     x20, x20, #1                // consume first char

Ltok_ident_loop:
    cmp     x20, x21
    b.ge    Ltok_ident_classify
    ldrb    w23, [x19, x20]
    // Check alphanumeric, '_', or '.'
    bl      Lis_ident_char
    cbz     w0, Ltok_ident_classify
    add     x20, x20, #1
    b       Ltok_ident_loop

Ltok_ident_classify:
    // Compute identifier length
    add     x8, x19, x20
    sub     x23, x8, x24                // x23 = ident_len (reusing x23 since we're done scanning chars)

    // --- Special case: "b" followed by '.' could be a conditional branch ---
    // Check if identifier is exactly "b" and next char is '.'
    cmp     x23, #1
    b.ne    Ltok_ident_check_colon       // not length 1
    ldrb    w9, [x24]                    // first char
    cmp     w9, #'b'
    b.ne    Ltok_ident_check_colon       // not 'b'

    // It is "b". Check if next char is '.'
    cmp     x20, x21
    b.ge    Ltok_ident_check_colon       // at end, just "b"
    ldrb    w9, [x19, x20]
    cmp     w9, #'.'
    b.ne    Ltok_ident_check_colon       // no '.', just "b"

    // Consume '.' and the condition code suffix (2-3 alphanumeric chars)
    add     x20, x20, #1                // consume '.'
Ltok_bcond_loop:
    cmp     x20, x21
    b.ge    Ltok_bcond_done
    ldrb    w23, [x19, x20]
    bl      Lis_alpha_lower
    cbz     w0, Ltok_bcond_done
    add     x20, x20, #1
    b       Ltok_bcond_loop

Ltok_bcond_done:
    // Recalculate length to include ".cond"
    add     x8, x19, x20
    sub     x23, x8, x24                // x23 = total length of "b.eq" etc.
    // Now fall through to classify — it will match as a mnemonic via lookup

Ltok_ident_check_colon:
    // Check if next char is ':'
    cmp     x20, x21
    b.ge    Ltok_ident_try_register
    ldrb    w9, [x19, x20]
    cmp     w9, #':'
    b.ne    Ltok_ident_try_register

    // It is a label definition — consume the colon
    mov     x0, #TOK_LABEL_DEF
    mov     x1, x24
    mov     x2, x23
    mov     x3, x22
    bl      Lemit_token
    add     x20, x20, #1                // consume ':'
    b       Ltok_loop

Ltok_ident_try_register:
    // Try _lookup_register(name_ptr, name_len)
    mov     x0, x24                      // name_ptr
    mov     x1, x23                      // name_len
    bl      _lookup_register
    // Returns x0 = register number (-1 if not found)
    cmn     x0, #1                       // compare with -1
    b.eq    Ltok_ident_try_mnemonic      // not a register

    // It is a register
    mov     x0, #TOK_REGISTER
    mov     x1, x24
    mov     x2, x23
    mov     x3, x22
    bl      Lemit_token
    b       Ltok_loop

Ltok_ident_try_mnemonic:
    // Try _lookup_mnemonic(name_ptr, name_len)
    mov     x0, x24                      // name_ptr
    mov     x1, x23                      // name_len
    bl      _lookup_mnemonic
    // Returns x0 = mnemonic_id (-1 if not found)
    cmn     x0, #1
    b.eq    Ltok_ident_label_ref         // not a mnemonic

    // It is a mnemonic
    mov     x0, #TOK_MNEMONIC
    mov     x1, x24
    mov     x2, x23
    mov     x3, x22
    bl      Lemit_token
    b       Ltok_loop

Ltok_ident_label_ref:
    // Default: label reference
    mov     x0, #TOK_LABEL_REF
    mov     x1, x24
    mov     x2, x23
    mov     x3, x22
    bl      Lemit_token
    b       Ltok_loop

    // ---- Bare number (digit at start, not after #) ----
Ltok_number:
    add     x24, x19, x20               // text_ptr
    // Check for 0x hex prefix
    ldrb    w9, [x19, x20]
    cmp     w9, #'0'
    b.ne    Ltok_num_dec_loop

    // Could be hex: check for 'x' after '0'
    add     x8, x20, #1
    cmp     x8, x21
    b.ge    Ltok_num_dec_loop
    ldrb    w10, [x19, x8]
    cmp     w10, #'x'
    b.eq    Ltok_num_hex
    cmp     w10, #'X'
    b.eq    Ltok_num_hex
    b       Ltok_num_dec_loop

Ltok_num_hex:
    add     x20, x20, #2                // consume '0x'
Ltok_num_hex_loop:
    cmp     x20, x21
    b.ge    Ltok_num_done
    ldrb    w9, [x19, x20]
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.ls    Ltok_num_hex_next
    sub     w10, w9, #'a'
    cmp     w10, #5
    b.ls    Ltok_num_hex_next
    sub     w10, w9, #'A'
    cmp     w10, #5
    b.ls    Ltok_num_hex_next
    b       Ltok_num_done

Ltok_num_hex_next:
    add     x20, x20, #1
    b       Ltok_num_hex_loop

Ltok_num_dec_loop:
    cmp     x20, x21
    b.ge    Ltok_num_done
    ldrb    w9, [x19, x20]
    sub     w10, w9, #'0'
    cmp     w10, #9
    b.hi    Ltok_num_done
    add     x20, x20, #1
    b       Ltok_num_dec_loop

Ltok_num_done:
    add     x8, x19, x20
    sub     x2, x8, x24                 // text_len
    mov     x0, #TOK_IMMEDIATE
    mov     x1, x24
    // x2 set
    mov     x3, x22
    bl      Lemit_token
    b       Ltok_loop

    // ---- End of input — emit TOK_EOF ----
Ltok_eof:
    // text_ptr points to end of input, text_len = 0
    add     x24, x19, x20
    mov     x0, #TOK_EOF
    mov     x1, x24
    mov     x2, #0
    mov     x3, x22
    bl      Lemit_token

    // Store updated state back to globals
    adrp    x8, _lex_pos@PAGE
    add     x8, x8, _lex_pos@PAGEOFF
    str     x20, [x8]

    adrp    x8, _lex_line@PAGE
    add     x8, x8, _lex_line@PAGEOFF
    str     x22, [x8]

    // Return token count
    adrp    x8, _lex_tok_count@PAGE
    add     x8, x8, _lex_tok_count@PAGEOFF
    ldr     x0, [x8]

    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


// ============================================================================
// Character classification helpers (private, leaf functions)
// ============================================================================
// These operate on the character currently in w23.
// They return w0 = 1 if match, 0 otherwise.
// They must NOT clobber x19-x24 or x29/x30.

// ---- Lis_alpha_or_underscore ----
// Check if w23 is a letter (a-z, A-Z) or underscore.
.p2align 2
Lis_alpha_or_underscore:
    // Check underscore
    cmp     w23, #'_'
    b.eq    Lchar_yes
    // Check lowercase
    sub     w9, w23, #'a'
    cmp     w9, #25                      // 'z' - 'a' = 25
    b.ls    Lchar_yes
    // Check uppercase
    sub     w9, w23, #'A'
    cmp     w9, #25
    b.ls    Lchar_yes
    b       Lchar_no

// ---- Lis_digit ----
// Check if w23 is a decimal digit.
.p2align 2
Lis_digit:
    sub     w9, w23, #'0'
    cmp     w9, #9
    b.ls    Lchar_yes
    b       Lchar_no

// ---- Lis_alnum_or_underscore ----
// Check if w23 is alphanumeric or underscore.
.p2align 2
Lis_alnum_or_underscore:
    cmp     w23, #'_'
    b.eq    Lchar_yes
    sub     w9, w23, #'a'
    cmp     w9, #25
    b.ls    Lchar_yes
    sub     w9, w23, #'A'
    cmp     w9, #25
    b.ls    Lchar_yes
    sub     w9, w23, #'0'
    cmp     w9, #9
    b.ls    Lchar_yes
    b       Lchar_no

// ---- Lis_ident_char ----
// Check if w23 is alphanumeric, underscore, or '.'.
// Identifiers can contain dots (for things like b.eq handling, though
// we special-case that; also useful for symbol names with dots).
.p2align 2
Lis_ident_char:
    cmp     w23, #'_'
    b.eq    Lchar_yes
    cmp     w23, #'.'
    b.eq    Lchar_yes
    sub     w9, w23, #'a'
    cmp     w9, #25
    b.ls    Lchar_yes
    sub     w9, w23, #'A'
    cmp     w9, #25
    b.ls    Lchar_yes
    sub     w9, w23, #'0'
    cmp     w9, #9
    b.ls    Lchar_yes
    b       Lchar_no

// ---- Lis_alpha_lower ----
// Check if w23 is a lowercase letter (a-z).
.p2align 2
Lis_alpha_lower:
    sub     w9, w23, #'a'
    cmp     w9, #25
    b.ls    Lchar_yes
    b       Lchar_no

// Shared return points for character classification
Lchar_yes:
    mov     w0, #1
    ret

Lchar_no:
    mov     w0, #0
    ret


// ============================================================================
// DATA SECTION — Lexer global state
// ============================================================================
.section __DATA,__data
.p2align 3

_lex_input:
    .quad   0                            // pointer to input buffer

_lex_pos:
    .quad   0                            // current position in input

_lex_len:
    .quad   0                            // total input length

_lex_line:
    .quad   1                            // current line number (1-based)

_lex_tokens:
    .quad   0                            // pointer to token array (heap-allocated)

_lex_tok_count:
    .quad   0                            // number of tokens produced

_lex_tok_cap:
    .quad   0                            // capacity of token array

// Expose state symbols for testing/debugging
.globl _lex_input
.globl _lex_pos
.globl _lex_len
.globl _lex_line
.globl _lex_tokens
.globl _lex_tok_count
.globl _lex_tok_cap

.subsections_via_symbols
