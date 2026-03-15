// Stage 1 IR Compiler - Lexer
// Tokenizes IR text into an array of tokens
// Target: AArch64 macOS (Apple Silicon)

.global _lexer_tokenize

// Token types
.equ TOK_EOF,       0
.equ TOK_FUNC,      1
.equ TOK_ARROW,     2
.equ TOK_LBRACE,    3
.equ TOK_RBRACE,    4
.equ TOK_LPAREN,    5
.equ TOK_RPAREN,    6
.equ TOK_COMMA,     7
.equ TOK_COLON,     8
.equ TOK_PERCENT,   9
.equ TOK_AT,        10
.equ TOK_TYPE,      11
.equ TOK_OPCODE,    12
.equ TOK_INTEGER,   13
.equ TOK_LBRACKET,  14
.equ TOK_RBRACKET,  15
.equ TOK_NEWLINE,   16
.equ TOK_EQUALS,    17
.equ TOK_IDENT,     18

.equ TOK_SIZE, 32

.text
.align 4

// _lexer_tokenize(src, src_len, token_buf) -> num_tokens
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
    mov     x22, #0             // pos
    mov     x23, #0             // num_tokens
    mov     x24, #1             // line_num

.Llex_loop:
    cmp     x22, x20
    b.ge    .Llex_done
    ldrb    w9, [x19, x22]

    // Skip comments //
    cmp     w9, #'/'
    b.ne    10f
    add     x10, x22, #1
    cmp     x10, x20
    b.ge    10f
    ldrb    w11, [x19, x10]
    cmp     w11, #'/'
    b.ne    10f
    // skip to end of line
2:  add     x22, x22, #1
    cmp     x22, x20
    b.ge    .Llex_loop
    ldrb    w9, [x19, x22]
    cmp     w9, #10
    b.ne    2b
    b       .Llex_loop

10: // skip whitespace (not newlines)
    cmp     w9, #' '
    b.eq    11f
    cmp     w9, #9
    b.eq    11f
    cmp     w9, #13
    b.eq    11f
    b       12f
11: add     x22, x22, #1
    b       .Llex_loop

12: // newline
    cmp     w9, #10
    b.ne    13f
    mov     w0, #TOK_NEWLINE
    add     x1, x19, x22
    mov     x2, #1
    mov     w3, w24
    bl      _lex_store_token
    add     x24, x24, #1
    add     x22, x22, #1
    b       .Llex_loop

13: // single char tokens
    cmp     w9, #'{'
    b.ne    14f
    mov     w0, #TOK_LBRACE
    b       .Llex_single
14: cmp     w9, #'}'
    b.ne    15f
    mov     w0, #TOK_RBRACE
    b       .Llex_single
15: cmp     w9, #'('
    b.ne    16f
    mov     w0, #TOK_LPAREN
    b       .Llex_single
16: cmp     w9, #')'
    b.ne    17f
    mov     w0, #TOK_RPAREN
    b       .Llex_single
17: cmp     w9, #','
    b.ne    18f
    mov     w0, #TOK_COMMA
    b       .Llex_single
18: cmp     w9, #':'
    b.ne    19f
    mov     w0, #TOK_COLON
    b       .Llex_single
19: cmp     w9, #'['
    b.ne    20f
    mov     w0, #TOK_LBRACKET
    b       .Llex_single
20: cmp     w9, #']'
    b.ne    21f
    mov     w0, #TOK_RBRACKET
    b       .Llex_single
21: cmp     w9, #'='
    b.ne    22f
    mov     w0, #TOK_EQUALS
    b       .Llex_single

22: // arrow ->
    cmp     w9, #'-'
    b.ne    30f
    add     x10, x22, #1
    cmp     x10, x20
    b.ge    25f
    ldrb    w11, [x19, x10]
    cmp     w11, #'>'
    b.ne    25f
    // arrow
    mov     w0, #TOK_ARROW
    add     x1, x19, x22
    mov     x2, #2
    mov     w3, w24
    bl      _lex_store_token
    add     x22, x22, #2
    b       .Llex_loop

25: // negative number?
    add     x10, x22, #1
    cmp     x10, x20
    b.ge    80f
    ldrb    w11, [x19, x10]
    cmp     w11, #'0'
    b.lt    80f
    cmp     w11, #'9'
    b.gt    80f
    b       .Llex_number

30: // % name
    cmp     w9, #'%'
    b.ne    35f
    mov     x25, x22
    add     x22, x22, #1
31: cmp     x22, x20
    b.ge    32f
    ldrb    w9, [x19, x22]
    bl      _is_alnum_underscore
    cbz     w0, 32f
    add     x22, x22, #1
    b       31b
32: mov     w0, #TOK_PERCENT
    add     x1, x19, x25
    sub     x2, x22, x25
    mov     w3, w24
    bl      _lex_store_token
    b       .Llex_loop

35: // @ name
    cmp     w9, #'@'
    b.ne    40f
    mov     x25, x22
    add     x22, x22, #1
36: cmp     x22, x20
    b.ge    37f
    ldrb    w9, [x19, x22]
    bl      _is_alnum_underscore
    cbz     w0, 37f
    add     x22, x22, #1
    b       36b
37: mov     w0, #TOK_AT
    add     x1, x19, x25
    sub     x2, x22, x25
    mov     w3, w24
    bl      _lex_store_token
    b       .Llex_loop

40: // number
    cmp     w9, #'0'
    b.lt    50f
    cmp     w9, #'9'
    b.gt    50f

.Llex_number:
    mov     x25, x22
    ldrb    w9, [x19, x22]
    cmp     w9, #'-'
    b.ne    41f
    add     x22, x22, #1
41: cmp     x22, x20
    b.ge    42f
    ldrb    w9, [x19, x22]
    cmp     w9, #'0'
    b.lt    42f
    cmp     w9, #'9'
    b.gt    42f
    add     x22, x22, #1
    b       41b
42: mov     w0, #TOK_INTEGER
    add     x1, x19, x25
    sub     x2, x22, x25
    mov     w3, w24
    bl      _lex_store_token
    b       .Llex_loop

50: // identifier / keyword
    bl      _is_alpha_underscore
    cbz     w0, 80f

    mov     x25, x22
51: add     x22, x22, #1
    cmp     x22, x20
    b.ge    52f
    ldrb    w9, [x19, x22]
    bl      _is_alnum_underscore
    cbnz    w0, 51b

52: // Classify: func, type, opcode, or ident
    add     x26, x19, x25       // text_ptr
    sub     x27, x22, x25       // text_len

    // Check "func"
    cmp     x27, #4
    b.ne    53f
    ldrb    w9, [x26]
    cmp     w9, #'f'
    b.ne    53f
    ldrb    w9, [x26, #1]
    cmp     w9, #'u'
    b.ne    53f
    ldrb    w9, [x26, #2]
    cmp     w9, #'n'
    b.ne    53f
    ldrb    w9, [x26, #3]
    cmp     w9, #'c'
    b.ne    53f
    mov     w0, #TOK_FUNC
    b       55f

53: // Check types: i64, i8, ptr
    // i64
    cmp     x27, #3
    b.ne    60f
    ldrb    w9, [x26]
    cmp     w9, #'i'
    b.ne    61f
    ldrb    w9, [x26, #1]
    cmp     w9, #'6'
    b.ne    60f
    ldrb    w9, [x26, #2]
    cmp     w9, #'4'
    b.ne    60f
    mov     w0, #TOK_TYPE
    b       55f

60: // i8
    cmp     x27, #2
    b.ne    61f
    ldrb    w9, [x26]
    cmp     w9, #'i'
    b.ne    61f
    ldrb    w9, [x26, #1]
    cmp     w9, #'8'
    b.ne    61f
    mov     w0, #TOK_TYPE
    b       55f

61: // ptr
    cmp     x27, #3
    b.ne    54f
    ldrb    w9, [x26]
    cmp     w9, #'p'
    b.ne    54f
    ldrb    w9, [x26, #1]
    cmp     w9, #'t'
    b.ne    54f
    ldrb    w9, [x26, #2]
    cmp     w9, #'r'
    b.ne    54f
    mov     w0, #TOK_TYPE
    b       55f

54: // Check opcodes
    mov     x0, x26             // text_ptr
    mov     x1, x27             // text_len
    bl      _is_opcode
    cbnz    w0, 62f
    mov     w0, #TOK_IDENT
    b       55f
62: mov     w0, #TOK_OPCODE

55: // Store token
    mov     x1, x26
    mov     x2, x27
    mov     w3, w24
    bl      _lex_store_token
    b       .Llex_loop

80: // unknown char, skip
    add     x22, x22, #1
    b       .Llex_loop

.Llex_single:
    add     x1, x19, x22
    mov     x2, #1
    mov     w3, w24
    bl      _lex_store_token
    add     x22, x22, #1
    b       .Llex_loop

.Llex_done:
    // EOF token
    mov     w0, #TOK_EOF
    mov     x1, #0
    mov     x2, #0
    mov     w3, w24
    bl      _lex_store_token

    mov     x0, x23             // return num_tokens

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldp     x29, x30, [sp], #96
    ret

// Store token: w0=type, x1=text_ptr, x2=text_len, w3=line_num
_lex_store_token:
    lsl     x10, x23, #5
    add     x10, x21, x10
    str     w0, [x10]
    str     x1, [x10, #8]
    str     x2, [x10, #16]
    str     w3, [x10, #24]
    add     x23, x23, #1
    ret

// Check if w9 is [a-zA-Z_], return w0=1/0
_is_alpha_underscore:
    cmp     w9, #'_'
    b.eq    1f
    cmp     w9, #'a'
    b.lt    2f
    cmp     w9, #'z'
    b.le    1f
2:  cmp     w9, #'A'
    b.lt    3f
    cmp     w9, #'Z'
    b.le    1f
3:  mov     w0, #0
    ret
1:  mov     w0, #1
    ret

// Check if w9 is [a-zA-Z0-9_], return w0=1/0
_is_alnum_underscore:
    cmp     w9, #'_'
    b.eq    1f
    cmp     w9, #'a'
    b.lt    2f
    cmp     w9, #'z'
    b.le    1f
2:  cmp     w9, #'A'
    b.lt    3f
    cmp     w9, #'Z'
    b.le    1f
3:  cmp     w9, #'0'
    b.lt    4f
    cmp     w9, #'9'
    b.le    1f
4:  mov     w0, #0
    ret
1:  mov     w0, #1
    ret

// Check if (x0, x1) matches any opcode, return w0=1/0
_is_opcode:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x0             // text_ptr
    mov     x20, x1             // text_len

    adrp    x10, _opcode_names@PAGE
    add     x10, x10, _opcode_names@PAGEOFF

5:  ldrb    w11, [x10]          // length
    cbz     w11, 6f             // end of table
    cmp     x20, x11
    b.ne    7f
    // compare bytes
    add     x12, x10, #1
    mov     x13, #0
8:  cmp     x13, x20
    b.ge    9f                  // match!
    ldrb    w14, [x19, x13]
    ldrb    w15, [x12, x13]
    cmp     w14, w15
    b.ne    7f
    add     x13, x13, #1
    b       8b
7:  // next entry
    add     x10, x10, #1
    add     x10, x10, x11
    b       5b

9:  mov     w0, #1
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret
6:  mov     w0, #0
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

.data
.align 3
_opcode_names:
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
    .byte 0
