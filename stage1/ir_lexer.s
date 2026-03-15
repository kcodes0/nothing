// Stage 1 IR Compiler - Lexer
// Tokenizes IR text into an array of tokens
// Target: AArch64 macOS (Apple Silicon)

.global _lexer_tokenize

// Token types
.equ TOK_EOF,       0
.equ TOK_FUNC,      1
.equ TOK_ARROW,     2    // ->
.equ TOK_LBRACE,    3    // {
.equ TOK_RBRACE,    4    // }
.equ TOK_LPAREN,    5    // (
.equ TOK_RPAREN,    6    // )
.equ TOK_COMMA,     7    // ,
.equ TOK_COLON,     8    // :
.equ TOK_PERCENT,   9    // %name
.equ TOK_AT,        10   // @name
.equ TOK_TYPE,      11   // i64, i8, ptr
.equ TOK_OPCODE,    12   // add, sub, etc.
.equ TOK_INTEGER,   13   // numeric literal
.equ TOK_LBRACKET,  14   // [
.equ TOK_RBRACKET,  15   // ]
.equ TOK_NEWLINE,   16
.equ TOK_EQUALS,    17   // =
.equ TOK_IDENT,     18   // bare identifier (block labels before colon)

// Token struct: 32 bytes
// offset 0: type (4 bytes)
// offset 4: padding (4 bytes)
// offset 8: text_ptr (8 bytes)
// offset 16: text_len (8 bytes)
// offset 24: line_num (4 bytes)
// offset 28: padding (4 bytes)

.equ TOK_SIZE, 32

.text
.align 4

// _lexer_tokenize(src, src_len, token_buf) -> num_tokens in x0
// x0 = source text pointer
// x1 = source text length
// x2 = token buffer pointer
// Returns number of tokens in x0
_lexer_tokenize:
    stp     x29, x30, [sp, #-96]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]

    mov     x19, x0             // src
    mov     x20, x1             // src_len
    mov     x21, x2             // token_buf
    mov     x22, #0             // pos (current position in src)
    mov     x23, #0             // num_tokens
    mov     x24, #1             // line_num

.Llex_loop:
    // Check if we've reached the end
    cmp     x22, x20
    b.ge    .Llex_done

    // Get current character
    ldrb    w9, [x19, x22]

    // Skip single-line comments: //
    cmp     w9, #'/'
    b.ne    .Llex_not_comment
    add     x10, x22, #1
    cmp     x10, x20
    b.ge    .Llex_not_comment
    ldrb    w11, [x19, x10]
    cmp     w11, #'/'
    b.ne    .Llex_not_comment
    // Skip to end of line
.Lskip_comment:
    add     x22, x22, #1
    cmp     x22, x20
    b.ge    .Llex_loop
    ldrb    w9, [x19, x22]
    cmp     w9, #10             // newline
    b.ne    .Lskip_comment
    // Don't skip the newline itself, let it be tokenized
    b       .Llex_loop

.Llex_not_comment:
    // Skip spaces and tabs (but not newlines)
    cmp     w9, #' '
    b.eq    .Llex_skip_ws
    cmp     w9, #9              // tab
    b.eq    .Llex_skip_ws
    cmp     w9, #13             // carriage return
    b.eq    .Llex_skip_ws
    b       .Llex_not_ws

.Llex_skip_ws:
    add     x22, x22, #1
    b       .Llex_loop

.Llex_not_ws:
    // Newline
    cmp     w9, #10
    b.ne    .Llex_not_newline
    // Emit newline token
    mov     w0, #TOK_NEWLINE
    mov     x1, x19
    add     x1, x1, x22
    mov     x2, #1
    mov     w3, w24
    bl      .Lstore_token
    add     x24, x24, #1        // increment line number
    add     x22, x22, #1
    b       .Llex_loop

.Llex_not_newline:
    // Single character tokens
    cmp     w9, #'{'
    b.eq    .Llex_lbrace
    cmp     w9, #'}'
    b.eq    .Llex_rbrace
    cmp     w9, #'('
    b.eq    .Llex_lparen
    cmp     w9, #')'
    b.eq    .Llex_rparen
    cmp     w9, #','
    b.eq    .Llex_comma
    cmp     w9, #':'
    b.eq    .Llex_colon
    cmp     w9, #'['
    b.eq    .Llex_lbracket
    cmp     w9, #']'
    b.eq    .Llex_rbracket
    cmp     w9, #'='
    b.eq    .Llex_equals

    // Arrow: ->
    cmp     w9, #'-'
    b.eq    .Llex_maybe_arrow

    // %name
    cmp     w9, #'%'
    b.eq    .Llex_percent

    // @name
    cmp     w9, #'@'
    b.eq    .Llex_at

    // Number (digit or negative)
    cmp     w9, #'0'
    b.ge    .Llex_maybe_number
    b       .Llex_maybe_ident

.Llex_maybe_number:
    cmp     w9, #'9'
    b.le    .Llex_number
    b       .Llex_maybe_ident

.Llex_maybe_ident:
    // Identifiers: [a-zA-Z_][a-zA-Z0-9_]*
    bl      .Lis_alpha_or_underscore
    cmp     w0, #0
    b.eq    .Llex_unknown
    b       .Llex_ident

// === Single char token emitters ===
.Llex_lbrace:
    mov     w0, #TOK_LBRACE
    b       .Llex_emit_single

.Llex_rbrace:
    mov     w0, #TOK_RBRACE
    b       .Llex_emit_single

.Llex_lparen:
    mov     w0, #TOK_LPAREN
    b       .Llex_emit_single

.Llex_rparen:
    mov     w0, #TOK_RPAREN
    b       .Llex_emit_single

.Llex_comma:
    mov     w0, #TOK_COMMA
    b       .Llex_emit_single

.Llex_colon:
    mov     w0, #TOK_COLON
    b       .Llex_emit_single

.Llex_lbracket:
    mov     w0, #TOK_LBRACKET
    b       .Llex_emit_single

.Llex_rbracket:
    mov     w0, #TOK_RBRACKET
    b       .Llex_emit_single

.Llex_equals:
    mov     w0, #TOK_EQUALS
    b       .Llex_emit_single

.Llex_emit_single:
    // w0 = token type
    add     x1, x19, x22       // text_ptr
    mov     x2, #1             // text_len
    mov     w3, w24            // line_num
    bl      .Lstore_token
    add     x22, x22, #1
    b       .Llex_loop

// Arrow ->
.Llex_maybe_arrow:
    add     x10, x22, #1
    cmp     x10, x20
    b.ge    .Llex_unknown
    ldrb    w11, [x19, x10]
    cmp     w11, #'>'
    b.ne    .Llex_neg_number
    // It's an arrow
    mov     w0, #TOK_ARROW
    add     x1, x19, x22
    mov     x2, #2
    mov     w3, w24
    bl      .Lstore_token
    add     x22, x22, #2
    b       .Llex_loop

.Llex_neg_number:
    // Could be negative number: check if next char is digit
    add     x10, x22, #1
    cmp     x10, x20
    b.ge    .Llex_unknown
    ldrb    w11, [x19, x10]
    cmp     w11, #'0'
    b.lt    .Llex_unknown
    cmp     w11, #'9'
    b.gt    .Llex_unknown
    // It's a negative number, fall through to number parsing
    b       .Llex_number

// Number literal
.Llex_number:
    mov     x25, x22           // start position
    // If starts with '-', skip it
    ldrb    w9, [x19, x22]
    cmp     w9, #'-'
    b.ne    .Llex_num_digits
    add     x22, x22, #1

.Llex_num_digits:
    cmp     x22, x20
    b.ge    .Llex_num_done
    ldrb    w9, [x19, x22]
    cmp     w9, #'0'
    b.lt    .Llex_num_done
    cmp     w9, #'9'
    b.gt    .Llex_num_done
    add     x22, x22, #1
    b       .Llex_num_digits

.Llex_num_done:
    mov     w0, #TOK_INTEGER
    add     x1, x19, x25       // text_ptr
    sub     x2, x22, x25       // text_len
    mov     w3, w24
    bl      .Lstore_token
    b       .Llex_loop

// %name token
.Llex_percent:
    mov     x25, x22           // start pos (includes %)
    add     x22, x22, #1       // skip %
.Llex_percent_loop:
    cmp     x22, x20
    b.ge    .Llex_percent_done
    ldrb    w9, [x19, x22]
    // Allow [a-zA-Z0-9_]
    cmp     w9, #'_'
    b.eq    .Llex_percent_cont
    cmp     w9, #'a'
    b.lt    .Llex_percent_check_upper
    cmp     w9, #'z'
    b.le    .Llex_percent_cont
.Llex_percent_check_upper:
    cmp     w9, #'A'
    b.lt    .Llex_percent_check_digit
    cmp     w9, #'Z'
    b.le    .Llex_percent_cont
.Llex_percent_check_digit:
    cmp     w9, #'0'
    b.lt    .Llex_percent_done
    cmp     w9, #'9'
    b.gt    .Llex_percent_done
.Llex_percent_cont:
    add     x22, x22, #1
    b       .Llex_percent_loop
.Llex_percent_done:
    mov     w0, #TOK_PERCENT
    add     x1, x19, x25       // text includes %
    sub     x2, x22, x25
    mov     w3, w24
    bl      .Lstore_token
    b       .Llex_loop

// @name token
.Llex_at:
    mov     x25, x22           // start pos (includes @)
    add     x22, x22, #1       // skip @
.Llex_at_loop:
    cmp     x22, x20
    b.ge    .Llex_at_done
    ldrb    w9, [x19, x22]
    cmp     w9, #'_'
    b.eq    .Llex_at_cont
    cmp     w9, #'a'
    b.lt    .Llex_at_check_upper
    cmp     w9, #'z'
    b.le    .Llex_at_cont
.Llex_at_check_upper:
    cmp     w9, #'A'
    b.lt    .Llex_at_check_digit
    cmp     w9, #'Z'
    b.le    .Llex_at_cont
.Llex_at_check_digit:
    cmp     w9, #'0'
    b.lt    .Llex_at_done
    cmp     w9, #'9'
    b.gt    .Llex_at_done
.Llex_at_cont:
    add     x22, x22, #1
    b       .Llex_at_loop
.Llex_at_done:
    mov     w0, #TOK_AT
    add     x1, x19, x25
    sub     x2, x22, x25
    mov     w3, w24
    bl      .Lstore_token
    b       .Llex_loop

// Identifier / keyword
.Llex_ident:
    mov     x25, x22           // start position
.Llex_ident_loop:
    cmp     x22, x20
    b.ge    .Llex_ident_done
    ldrb    w9, [x19, x22]
    cmp     w9, #'_'
    b.eq    .Llex_ident_cont
    cmp     w9, #'a'
    b.lt    .Llex_ident_check_upper
    cmp     w9, #'z'
    b.le    .Llex_ident_cont
.Llex_ident_check_upper:
    cmp     w9, #'A'
    b.lt    .Llex_ident_check_digit
    cmp     w9, #'Z'
    b.le    .Llex_ident_cont
.Llex_ident_check_digit:
    cmp     w9, #'0'
    b.lt    .Llex_ident_done
    cmp     w9, #'9'
    b.gt    .Llex_ident_done
.Llex_ident_cont:
    add     x22, x22, #1
    b       .Llex_ident_loop

.Llex_ident_done:
    // Determine token type by checking keywords
    add     x1, x19, x25       // text_ptr
    sub     x2, x22, x25       // text_len

    // Check for "func"
    cmp     x2, #4
    b.ne    .Llex_not_func
    ldrb    w9, [x1]
    cmp     w9, #'f'
    b.ne    .Llex_not_func
    ldrb    w9, [x1, #1]
    cmp     w9, #'u'
    b.ne    .Llex_not_func
    ldrb    w9, [x1, #2]
    cmp     w9, #'n'
    b.ne    .Llex_not_func
    ldrb    w9, [x1, #3]
    cmp     w9, #'c'
    b.ne    .Llex_not_func
    mov     w0, #TOK_FUNC
    mov     w3, w24
    bl      .Lstore_token
    b       .Llex_loop

.Llex_not_func:
    // Check for types: i64, i8, ptr
    // i64
    cmp     x2, #3
    b.ne    .Llex_not_i64
    ldrb    w9, [x1]
    cmp     w9, #'i'
    b.ne    .Llex_not_i64
    ldrb    w9, [x1, #1]
    cmp     w9, #'6'
    b.ne    .Llex_not_i64
    ldrb    w9, [x1, #2]
    cmp     w9, #'4'
    b.ne    .Llex_not_i64
    mov     w0, #TOK_TYPE
    mov     w3, w24
    bl      .Lstore_token
    b       .Llex_loop

.Llex_not_i64:
    // i8
    cmp     x2, #2
    b.ne    .Llex_not_i8
    ldrb    w9, [x1]
    cmp     w9, #'i'
    b.ne    .Llex_not_i8
    ldrb    w9, [x1, #1]
    cmp     w9, #'8'
    b.ne    .Llex_not_i8
    mov     w0, #TOK_TYPE
    mov     w3, w24
    bl      .Lstore_token
    b       .Llex_loop

.Llex_not_i8:
    // ptr
    cmp     x2, #3
    b.ne    .Llex_not_ptr
    ldrb    w9, [x1]
    cmp     w9, #'p'
    b.ne    .Llex_not_ptr
    ldrb    w9, [x1, #1]
    cmp     w9, #'t'
    b.ne    .Llex_not_ptr
    ldrb    w9, [x1, #2]
    cmp     w9, #'r'
    b.ne    .Llex_not_ptr
    mov     w0, #TOK_TYPE
    mov     w3, w24
    bl      .Lstore_token
    b       .Llex_loop

.Llex_not_ptr:
    // Check if it's an opcode by matching known opcodes
    // We'll check the common ones: add, sub, mul, div, mod, and, or, xor
    // shl, shr, cmp_eq, cmp_ne, cmp_lt, cmp_gt, cmp_le, cmp_ge
    // load, store, alloca, br, br_cond, ret, call, phi
    // zext, sext, trunc, ptrtoint, inttoptr, arg

    // For simplicity, we classify known IR opcodes as TOK_OPCODE
    // and everything else as TOK_IDENT

    mov     x5, x1             // save text_ptr
    mov     x6, x2             // save text_len

    // Check each opcode
    adr     x10, opcode_table
.Lcheck_opcode_loop:
    ldrb    w11, [x10]          // length of opcode name (0 = end of table)
    cmp     w11, #0
    b.eq    .Llex_is_ident      // not an opcode
    // Compare length
    cmp     x6, x11
    b.ne    .Lnext_opcode
    // Compare bytes
    add     x12, x10, #1        // opcode string start
    mov     x13, #0
.Lcmp_opcode:
    cmp     x13, x6
    b.ge    .Llex_is_opcode     // full match
    ldrb    w14, [x5, x13]
    ldrb    w15, [x12, x13]
    cmp     w14, w15
    b.ne    .Lnext_opcode
    add     x13, x13, #1
    b       .Lcmp_opcode

.Lnext_opcode:
    // Skip to next entry: 1 byte len + len bytes + padding to align
    add     x10, x10, #1
    add     x10, x10, x11
    b       .Lcheck_opcode_loop

.Llex_is_opcode:
    mov     w0, #TOK_OPCODE
    mov     x1, x5
    mov     x2, x6
    mov     w3, w24
    bl      .Lstore_token
    b       .Llex_loop

.Llex_is_ident:
    mov     w0, #TOK_IDENT
    mov     x1, x5
    mov     x2, x6
    mov     w3, w24
    bl      .Lstore_token
    b       .Llex_loop

.Llex_unknown:
    // Skip unknown character
    add     x22, x22, #1
    b       .Llex_loop

.Llex_done:
    // Emit EOF token
    mov     w0, #TOK_EOF
    mov     x1, #0
    mov     x2, #0
    mov     w3, w24
    bl      .Lstore_token

    mov     x0, x23             // return num_tokens

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldp     x29, x30, [sp], #96
    ret

// Helper: store a token
// w0 = type, x1 = text_ptr, x2 = text_len, w3 = line_num
// Uses x21 (token_buf), x23 (num_tokens) from caller
.Lstore_token:
    // Calculate offset: x23 * 32
    lsl     x10, x23, #5        // * 32
    add     x10, x21, x10       // token_buf + offset
    str     w0, [x10]           // type
    str     x1, [x10, #8]       // text_ptr
    str     x2, [x10, #16]      // text_len
    str     w3, [x10, #24]      // line_num
    add     x23, x23, #1
    ret

// Helper: check if w9 is [a-zA-Z_]
// Returns w0 = 1 if yes, 0 if no
.Lis_alpha_or_underscore:
    cmp     w9, #'_'
    b.eq    .Lis_alpha_yes
    cmp     w9, #'a'
    b.lt    .Lis_alpha_check_upper
    cmp     w9, #'z'
    b.le    .Lis_alpha_yes
.Lis_alpha_check_upper:
    cmp     w9, #'A'
    b.lt    .Lis_alpha_no
    cmp     w9, #'Z'
    b.le    .Lis_alpha_yes
.Lis_alpha_no:
    mov     w0, #0
    ret
.Lis_alpha_yes:
    mov     w0, #1
    ret

.data
.align 3
// Opcode table: each entry is [len_byte][string_bytes]
// Terminated by a 0 length byte
opcode_table:
    .byte 3
    .ascii "add"
    .byte 3
    .ascii "sub"
    .byte 3
    .ascii "mul"
    .byte 3
    .ascii "div"
    .byte 3
    .ascii "mod"
    .byte 3
    .ascii "and"
    .byte 2
    .ascii "or"
    .byte 3
    .ascii "xor"
    .byte 3
    .ascii "shl"
    .byte 3
    .ascii "shr"
    .byte 6
    .ascii "cmp_eq"
    .byte 6
    .ascii "cmp_ne"
    .byte 6
    .ascii "cmp_lt"
    .byte 6
    .ascii "cmp_gt"
    .byte 6
    .ascii "cmp_le"
    .byte 6
    .ascii "cmp_ge"
    .byte 4
    .ascii "load"
    .byte 5
    .ascii "store"
    .byte 6
    .ascii "alloca"
    .byte 2
    .ascii "br"
    .byte 7
    .ascii "br_cond"
    .byte 3
    .ascii "ret"
    .byte 4
    .ascii "call"
    .byte 3
    .ascii "phi"
    .byte 4
    .ascii "zext"
    .byte 4
    .ascii "sext"
    .byte 5
    .ascii "trunc"
    .byte 8
    .ascii "ptrtoint"
    .byte 8
    .ascii "inttoptr"
    .byte 3
    .ascii "arg"
    .byte 0              // end of table
