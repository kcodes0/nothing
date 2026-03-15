// parser.s — Two-pass parser for the bootstrapped ARM64 assembler
// AArch64 macOS (Apple AAPCS64)
//
// Pass 1: Collects labels/offsets, determines section sizes
// Pass 2: Encodes instructions, resolves branches, records relocations
//
// External dependencies:
//   _lex_get_token (lexer.s), _lookup_mnemonic, _lookup_register,
//   _lookup_cond_code, _lookup_directive (tables.s),
//   _enc_* (encoder.s), _sym_* (symtab.s), _str_* (strings.s),
//   _error_at_line (error.s), _macho_add_reloc (macho.s),
//   _malloc, _free (libSystem)

.section __TEXT,__text,regular,pure_instructions
.p2align 2

// ============================================================================
// External references
// ============================================================================
.extern _lex_get_token
.extern _lookup_mnemonic
.extern _lookup_register
.extern _lookup_cond_code
.extern _lookup_directive
.extern _sym_add
.extern _sym_lookup
.extern _sym_define
.extern _sym_set_global
.extern _sym_is_defined
.extern _str_to_int
.extern _str_to_hex
.extern _str_eq_lit
.extern _str_cmp
.extern _memcpy_custom
.extern _error_at_line
.extern _error_exit
.extern _macho_add_reloc
.extern _malloc
.extern _free

// ============================================================================
// Public symbols
// ============================================================================
.globl _parse_init
.globl _parse_pass1
.globl _parse_pass2
.globl _parse_free
.globl _parse_text_buf
.globl _parse_text_size
.globl _parse_data_buf
.globl _parse_data_size
.globl _parse_cur_section
.globl _parse_tok_idx
.globl _parse_tok_count

// ============================================================================
// Token type constants (must match lexer.s)
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

.set TOK_SIZE,       32
.set TOK_TYPE_OFF,    0
.set TOK_TEXT_OFF,    8
.set TOK_LEN_OFF,   16
.set TOK_LINE_OFF,  24

// ============================================================================
// Mnemonic IDs (must match tables.s)
// ============================================================================
.set MN_ADD,   0
.set MN_SUB,   1
.set MN_MUL,   2
.set MN_MADD,  3
.set MN_MSUB,  4
.set MN_NEG,   5
.set MN_AND,   6
.set MN_ORR,   7
.set MN_EOR,   8
.set MN_MVN,   9
.set MN_LSL,  10
.set MN_LSR,  11
.set MN_ASR,  12
.set MN_CMP,  13
.set MN_CMN,  14
.set MN_TST,  15
.set MN_B,    16
.set MN_BL,   17
.set MN_RET,  18
.set MN_CBZ,  19
.set MN_CBNZ, 20
.set MN_LDR,  21
.set MN_STR,  22
.set MN_LDRB, 23
.set MN_STRB, 24
.set MN_LDP,  25
.set MN_STP,  26
.set MN_ADR,  27
.set MN_ADRP, 28
.set MN_MOV,  29
.set MN_MOVZ, 30
.set MN_MOVK, 31
.set MN_MOVN, 32
.set MN_SVC,  33
.set MN_NOP,  34
.set MN_BEQ,  35
.set MN_BNE,  36
.set MN_BLT,  37
.set MN_BGT,  38
.set MN_BLE,  39
.set MN_BGE,  40
.set MN_BCS,  41
.set MN_BCC,  42
.set MN_BMI,  43
.set MN_BPL,  44
.set MN_BHI,  45
.set MN_BLS,  46
.set MN_SUBS, 47
.set MN_ADDS, 48
.set MN_ANDS, 49
.set MN_UDIV, 50
.set MN_SDIV, 51
.set MN_LDRH, 52
.set MN_STRH, 53
.set MN_UBFM, 54
.set MN_SBFM, 55
.set MN_CSET, 56
.set MN_CSEL, 57

// ============================================================================
// Directive IDs (must match tables.s)
// ============================================================================
.set DIR_TEXT,   0
.set DIR_DATA,   1
.set DIR_ASCII,  2
.set DIR_ASCIZ,  3
.set DIR_BYTE,   4
.set DIR_QUAD,   5
.set DIR_ALIGN,  6
.set DIR_GLOBAL, 7
.set DIR_SPACE,  8
.set DIR_ZERO,   9

// ============================================================================
// Relocation types (must match macho.s)
// ============================================================================
.set ARM64_RELOC_BRANCH26,  2
.set ARM64_RELOC_PAGE21,    3
.set ARM64_RELOC_PAGEOFF12, 4

// Buffer size: 1 MB
.set BUF_SIZE, 0x100000


// ============================================================================
// _parse_init — Initialize parser state
// ============================================================================
// Args: x0 = token_count
// Allocates text buffer (1MB) and data buffer (1MB) via _malloc
.p2align 2
_parse_init:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    mov     x19, x0                     // save token_count

    // Store token count
    adrp    x8, _parse_tok_count@PAGE
    add     x8, x8, _parse_tok_count@PAGEOFF
    str     x19, [x8]

    // Reset token index
    adrp    x8, _parse_tok_idx@PAGE
    add     x8, x8, _parse_tok_idx@PAGEOFF
    str     xzr, [x8]

    // Reset sizes
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    str     xzr, [x8]

    adrp    x8, _parse_data_size@PAGE
    add     x8, x8, _parse_data_size@PAGEOFF
    str     xzr, [x8]

    // Reset current section to text (0)
    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    str     xzr, [x8]

    // Allocate text buffer (1MB)
    mov     x0, #BUF_SIZE
    bl      _malloc
    adrp    x8, _parse_text_buf@PAGE
    add     x8, x8, _parse_text_buf@PAGEOFF
    str     x0, [x8]

    // Allocate data buffer (1MB)
    mov     x0, #BUF_SIZE
    bl      _malloc
    adrp    x8, _parse_data_buf@PAGE
    add     x8, x8, _parse_data_buf@PAGEOFF
    str     x0, [x8]

    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


// ============================================================================
// _parse_free — Free allocated buffers
// ============================================================================
.p2align 2
_parse_free:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    adrp    x8, _parse_text_buf@PAGE
    add     x8, x8, _parse_text_buf@PAGEOFF
    ldr     x0, [x8]
    cbz     x0, 1f
    bl      _free
    adrp    x8, _parse_text_buf@PAGE
    add     x8, x8, _parse_text_buf@PAGEOFF
    str     xzr, [x8]
1:
    adrp    x8, _parse_data_buf@PAGE
    add     x8, x8, _parse_data_buf@PAGEOFF
    ldr     x0, [x8]
    cbz     x0, 2f
    bl      _free
    adrp    x8, _parse_data_buf@PAGE
    add     x8, x8, _parse_data_buf@PAGEOFF
    str     xzr, [x8]
2:
    ldp     x29, x30, [sp], #16
    ret


// ============================================================================
// _parse_next_token — Get next token and advance index
// ============================================================================
// Returns: x0 = pointer to current token
.p2align 2
_parse_next_token:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    adrp    x8, _parse_tok_idx@PAGE
    add     x8, x8, _parse_tok_idx@PAGEOFF
    ldr     x0, [x8]                    // x0 = current index

    // Advance index
    add     x9, x0, #1
    str     x9, [x8]

    // Get token pointer: call _lex_get_token(index)
    bl      _lex_get_token

    ldp     x29, x30, [sp], #16
    ret


// ============================================================================
// _parse_peek_token — Peek at next token without consuming
// ============================================================================
// Returns: x0 = pointer to next token
.p2align 2
_parse_peek_token:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    adrp    x8, _parse_tok_idx@PAGE
    add     x8, x8, _parse_tok_idx@PAGEOFF
    ldr     x0, [x8]                    // x0 = current index (don't advance)

    bl      _lex_get_token

    ldp     x29, x30, [sp], #16
    ret


// ============================================================================
// _parse_expect_token — Get next token and verify type
// ============================================================================
// Args: x0 = expected token type
// Returns: x0 = pointer to token
.p2align 2
_parse_expect_token:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    mov     x19, x0                     // x19 = expected type

    bl      _parse_next_token           // x0 = token ptr
    mov     x20, x0                     // x20 = token ptr

    ldr     x8, [x20, #TOK_TYPE_OFF]
    cmp     x8, x19
    b.ne    Lexpect_error

    mov     x0, x20
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

Lexpect_error:
    ldr     x0, [x20, #TOK_LINE_OFF]
    adrp    x1, Lerr_unexpected_token@PAGE
    add     x1, x1, Lerr_unexpected_token@PAGEOFF
    bl      _error_at_line
    // does not return


// ============================================================================
// _parse_skip_to_newline — Skip tokens until TOK_NEWLINE or TOK_EOF
// ============================================================================
.p2align 2
_parse_skip_to_newline:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

Lskip_nl_loop:
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_NEWLINE
    b.eq    Lskip_nl_done
    cmp     x8, #TOK_EOF
    b.eq    Lskip_nl_done
    bl      _parse_next_token           // consume token
    b       Lskip_nl_loop

Lskip_nl_done:
    ldp     x29, x30, [sp], #16
    ret


// ============================================================================
// _parse_read_register — Read a register token, return info
// ============================================================================
// Returns: x0 = reg_number, x1 = is_32bit
.p2align 2
_parse_read_register:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    bl      _parse_next_token           // x0 = token ptr
    // Verify it is a register
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_REGISTER
    b.ne    Lreg_read_err

    // Look up register
    ldr     x1, [x0, #TOK_LEN_OFF]     // name_len
    ldr     x0, [x0, #TOK_TEXT_OFF]     // name_ptr
    bl      _lookup_register
    // Returns: x0 = reg_number, x1 = is_32bit, x2 = is_sp

    ldp     x29, x30, [sp], #16
    ret

Lreg_read_err:
    ldr     x0, [x0, #TOK_LINE_OFF]
    adrp    x1, Lerr_expected_register@PAGE
    add     x1, x1, Lerr_expected_register@PAGEOFF
    bl      _error_at_line


// ============================================================================
// _parse_read_immediate — Read an immediate value from the token stream
// ============================================================================
// Handles TOK_IMMEDIATE (possibly preceded by TOK_HASH or TOK_MINUS)
// Returns: x0 = immediate value (signed)
.p2align 2
_parse_read_immediate:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    mov     x19, #0                     // x19 = negate flag

    // Peek: if HASH, consume it
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_HASH
    b.ne    Limm_check_minus
    bl      _parse_next_token           // consume hash

Limm_check_minus:
    // Peek: if MINUS, consume it and set negate
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_MINUS
    b.ne    Limm_read_val
    mov     x19, #1
    bl      _parse_next_token           // consume minus

Limm_read_val:
    // Next token should be TOK_IMMEDIATE
    bl      _parse_next_token
    mov     x20, x0                     // x20 = token ptr

    ldr     x8, [x20, #TOK_TYPE_OFF]
    cmp     x8, #TOK_IMMEDIATE
    b.ne    Limm_err

    ldr     x0, [x20, #TOK_TEXT_OFF]    // text_ptr
    ldr     x1, [x20, #TOK_LEN_OFF]    // text_len

    // Check if hex: starts with '0x'
    cmp     x1, #2
    b.lo    Limm_parse_dec
    ldrb    w8, [x0]
    cmp     w8, #'0'
    b.ne    Limm_check_neg_hex
    ldrb    w8, [x0, #1]
    cmp     w8, #'x'
    b.eq    Limm_parse_hex
    cmp     w8, #'X'
    b.eq    Limm_parse_hex
    b       Limm_check_neg_hex

Limm_check_neg_hex:
    // Check if it starts with '-0x' (negative already consumed via MINUS token,
    // but the lexer might have included '-' in the immediate text)
    cmp     w8, #'-'
    b.ne    Limm_parse_dec
    // Check if text starts with '-'
    ldrb    w8, [x0]
    cmp     w8, #'-'
    b.ne    Limm_parse_dec
    // It is a negative number in the token text itself
    add     x0, x0, #1
    sub     x1, x1, #1
    mov     x19, #1                     // set negate
    // Check for 0x after -
    cmp     x1, #2
    b.lo    Limm_parse_dec
    ldrb    w8, [x0]
    cmp     w8, #'0'
    b.ne    Limm_parse_dec
    ldrb    w8, [x0, #1]
    cmp     w8, #'x'
    b.eq    Limm_parse_hex
    cmp     w8, #'X'
    b.eq    Limm_parse_hex
    b       Limm_parse_dec

Limm_parse_hex:
    // Skip '0x' prefix
    add     x0, x0, #2
    sub     x1, x1, #2
    bl      _str_to_hex
    b       Limm_apply_sign

Limm_parse_dec:
    // Check if text itself starts with '-'
    ldr     x0, [x20, #TOK_TEXT_OFF]
    ldr     x1, [x20, #TOK_LEN_OFF]
    ldrb    w8, [x0]
    cmp     w8, #'-'
    b.ne    Limm_parse_dec2
    // Negative in text
    mov     x19, #1
    add     x0, x0, #1
    sub     x1, x1, #1

Limm_parse_dec2:
    bl      _str_to_int

Limm_apply_sign:
    cbz     x19, Limm_done
    neg     x0, x0

Limm_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

Limm_err:
    ldr     x0, [x20, #TOK_LINE_OFF]
    adrp    x1, Lerr_expected_immediate@PAGE
    add     x1, x1, Lerr_expected_immediate@PAGEOFF
    bl      _error_at_line


// ============================================================================
// _parse_skip_comma — Consume a comma token
// ============================================================================
.p2align 2
_parse_skip_comma:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     x0, #TOK_COMMA
    bl      _parse_expect_token

    ldp     x29, x30, [sp], #16
    ret


// ============================================================================
// Lget_cur_offset — Helper: get current section offset
// ============================================================================
// Returns: x0 = current offset in active section
.p2align 2
Lget_cur_offset:
    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    ldr     x8, [x8]
    cbnz    x8, 1f
    // text section
    adrp    x9, _parse_text_size@PAGE
    add     x9, x9, _parse_text_size@PAGEOFF
    ldr     x0, [x9]
    ret
1:  // data section
    adrp    x9, _parse_data_size@PAGE
    add     x9, x9, _parse_data_size@PAGEOFF
    ldr     x0, [x9]
    ret


// ============================================================================
// Lset_cur_offset — Helper: set current section offset
// ============================================================================
// Args: x0 = new offset
.p2align 2
Lset_cur_offset:
    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    ldr     x8, [x8]
    cbnz    x8, 1f
    adrp    x9, _parse_text_size@PAGE
    add     x9, x9, _parse_text_size@PAGEOFF
    str     x0, [x9]
    ret
1:
    adrp    x9, _parse_data_size@PAGE
    add     x9, x9, _parse_data_size@PAGEOFF
    str     x0, [x9]
    ret


// ============================================================================
// Lget_cur_buf — Helper: get current section buffer pointer + offset
// ============================================================================
// Returns: x0 = pointer to current write position
.p2align 2
Lget_cur_buf:
    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    ldr     x8, [x8]
    cbnz    x8, 1f
    adrp    x9, _parse_text_buf@PAGE
    add     x9, x9, _parse_text_buf@PAGEOFF
    ldr     x9, [x9]
    adrp    x10, _parse_text_size@PAGE
    add     x10, x10, _parse_text_size@PAGEOFF
    ldr     x10, [x10]
    add     x0, x9, x10
    ret
1:
    adrp    x9, _parse_data_buf@PAGE
    add     x9, x9, _parse_data_buf@PAGEOFF
    ldr     x9, [x9]
    adrp    x10, _parse_data_size@PAGE
    add     x10, x10, _parse_data_size@PAGEOFF
    ldr     x10, [x10]
    add     x0, x9, x10
    ret


// ============================================================================
// Lemit_inst — Write a 32-bit instruction to text buffer and advance offset
// ============================================================================
// Args: w0 = instruction word
.p2align 2
Lemit_inst:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    str     x19, [sp, #16]

    mov     w19, w0                     // save instruction

    // Get text buffer + text_size
    adrp    x8, _parse_text_buf@PAGE
    add     x8, x8, _parse_text_buf@PAGEOFF
    ldr     x8, [x8]
    adrp    x9, _parse_text_size@PAGE
    add     x9, x9, _parse_text_size@PAGEOFF
    ldr     x10, [x9]

    // Store instruction (little-endian, naturally)
    str     w19, [x8, x10]

    // Advance text_size by 4
    add     x10, x10, #4
    str     x10, [x9]

    ldr     x19, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret


// ============================================================================
// _parse_pass1 — First pass: collect labels and compute section sizes
// ============================================================================
.p2align 2
_parse_pass1:
    stp     x29, x30, [sp, #-80]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]

    // Reset state for pass 1
    adrp    x8, _parse_tok_idx@PAGE
    add     x8, x8, _parse_tok_idx@PAGEOFF
    str     xzr, [x8]

    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    str     xzr, [x8]

    adrp    x8, _parse_data_size@PAGE
    add     x8, x8, _parse_data_size@PAGEOFF
    str     xzr, [x8]

    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    str     xzr, [x8]

Lp1_loop:
    bl      _parse_peek_token
    mov     x19, x0                     // x19 = token ptr
    ldr     x20, [x19, #TOK_TYPE_OFF]   // x20 = token type

    cmp     x20, #TOK_EOF
    b.eq    Lp1_done

    cmp     x20, #TOK_NEWLINE
    b.eq    Lp1_skip_newline

    cmp     x20, #TOK_LABEL_DEF
    b.eq    Lp1_label_def

    cmp     x20, #TOK_MNEMONIC
    b.eq    Lp1_mnemonic

    cmp     x20, #TOK_DIRECTIVE
    b.eq    Lp1_directive

    // Skip any other token
    bl      _parse_next_token
    b       Lp1_loop

Lp1_skip_newline:
    bl      _parse_next_token           // consume newline
    b       Lp1_loop

Lp1_label_def:
    bl      _parse_next_token           // consume label def token
    mov     x19, x0
    // Add symbol
    ldr     x0, [x19, #TOK_TEXT_OFF]    // name_ptr
    ldr     x1, [x19, #TOK_LEN_OFF]    // name_len
    bl      _sym_add                    // x0 = sym entry
    mov     x21, x0                     // x21 = sym entry

    // Get current offset and section
    bl      Lget_cur_offset
    mov     x1, x0                      // x1 = offset

    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    ldr     x2, [x8]                    // x2 = section

    mov     x0, x21                     // x0 = sym entry
    bl      _sym_define
    b       Lp1_loop

Lp1_mnemonic:
    bl      _parse_next_token           // consume mnemonic
    // Every instruction is 4 bytes in text section
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x9, [x8]
    add     x9, x9, #4
    str     x9, [x8]
    // Skip to next newline (ignore operands in pass 1)
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_directive:
    bl      _parse_next_token           // consume directive token
    mov     x19, x0                     // x19 = directive token

    // Look up directive ID
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _lookup_directive           // x0 = directive_id
    mov     x20, x0                     // x20 = directive_id

    cmp     x20, #DIR_TEXT
    b.eq    Lp1_dir_text
    cmp     x20, #DIR_DATA
    b.eq    Lp1_dir_data
    cmp     x20, #DIR_ASCII
    b.eq    Lp1_dir_ascii
    cmp     x20, #DIR_ASCIZ
    b.eq    Lp1_dir_asciz
    cmp     x20, #DIR_BYTE
    b.eq    Lp1_dir_byte
    cmp     x20, #DIR_QUAD
    b.eq    Lp1_dir_quad
    cmp     x20, #DIR_ALIGN
    b.eq    Lp1_dir_align
    cmp     x20, #DIR_GLOBAL
    b.eq    Lp1_dir_global
    cmp     x20, #DIR_SPACE
    b.eq    Lp1_dir_space
    cmp     x20, #DIR_ZERO
    b.eq    Lp1_dir_space               // .zero is same as .space

    // Unknown directive — skip line
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_dir_text:
    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    str     xzr, [x8]                   // section = 0 (text)
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_dir_data:
    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    mov     x9, #1
    str     x9, [x8]                    // section = 1 (data)
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_dir_ascii:
    // Next token should be TOK_STRING
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_STRING
    b.ne    Lp1_dir_ascii_skip
    bl      _parse_next_token
    ldr     x21, [x0, #TOK_LEN_OFF]    // string length
    bl      Lget_cur_offset
    add     x0, x0, x21
    bl      Lset_cur_offset
Lp1_dir_ascii_skip:
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_dir_asciz:
    // Same as ascii but +1 for null terminator
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_STRING
    b.ne    Lp1_dir_asciz_skip
    bl      _parse_next_token
    ldr     x21, [x0, #TOK_LEN_OFF]    // string length
    add     x21, x21, #1               // +1 for null
    bl      Lget_cur_offset
    add     x0, x0, x21
    bl      Lset_cur_offset
Lp1_dir_asciz_skip:
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_dir_byte:
    bl      Lget_cur_offset
    add     x0, x0, #1
    bl      Lset_cur_offset
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_dir_quad:
    bl      Lget_cur_offset
    add     x0, x0, #8
    bl      Lset_cur_offset
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_dir_align:
    // Read alignment value
    bl      _parse_read_immediate       // x0 = alignment
    mov     x21, x0

    // Get current offset and align it
    bl      Lget_cur_offset
    // Align: offset = (offset + (align-1)) & ~(align-1)
    // But .align N on macOS means align to 2^N bytes
    mov     x22, #1
    lsl     x22, x22, x21              // x22 = 2^N
    sub     x23, x22, #1               // mask = 2^N - 1
    add     x0, x0, x23
    bic     x0, x0, x23                // aligned offset
    bl      Lset_cur_offset
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_dir_global:
    // Next token should be a label ref or identifier
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_LABEL_REF
    b.eq    Lp1_dir_global_label
    cmp     x8, #TOK_MNEMONIC
    b.eq    Lp1_dir_global_label        // identifiers might be tokenized as mnemonic
    b       Lp1_dir_global_skip

Lp1_dir_global_label:
    bl      _parse_next_token           // consume the label ref
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_add                    // x0 = sym entry
    bl      _sym_set_global

Lp1_dir_global_skip:
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_dir_space:
    // .space N or .zero N — advance by N bytes
    bl      _parse_read_immediate       // x0 = N
    mov     x21, x0
    bl      Lget_cur_offset
    add     x0, x0, x21
    bl      Lset_cur_offset
    bl      _parse_skip_to_newline
    b       Lp1_loop

Lp1_done:
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret


// ============================================================================
// _parse_pass2 — Second pass: encode instructions and fill buffers
// ============================================================================
.p2align 2
_parse_pass2:
    stp     x29, x30, [sp, #-80]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]

    // Reset state for pass 2
    adrp    x8, _parse_tok_idx@PAGE
    add     x8, x8, _parse_tok_idx@PAGEOFF
    str     xzr, [x8]

    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    str     xzr, [x8]

    adrp    x8, _parse_data_size@PAGE
    add     x8, x8, _parse_data_size@PAGEOFF
    str     xzr, [x8]

    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    str     xzr, [x8]

Lp2_loop:
    bl      _parse_peek_token
    mov     x19, x0
    ldr     x20, [x19, #TOK_TYPE_OFF]

    cmp     x20, #TOK_EOF
    b.eq    Lp2_done

    cmp     x20, #TOK_NEWLINE
    b.eq    Lp2_skip_newline

    cmp     x20, #TOK_LABEL_DEF
    b.eq    Lp2_label_def

    cmp     x20, #TOK_MNEMONIC
    b.eq    Lp2_mnemonic

    cmp     x20, #TOK_DIRECTIVE
    b.eq    Lp2_directive

    // Skip other tokens
    bl      _parse_next_token
    b       Lp2_loop

Lp2_skip_newline:
    bl      _parse_next_token
    b       Lp2_loop

Lp2_label_def:
    bl      _parse_next_token           // consume label def (already handled in pass 1)
    b       Lp2_loop

Lp2_directive:
    bl      _parse_next_token           // consume directive token
    mov     x19, x0

    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _lookup_directive
    mov     x20, x0                     // x20 = directive_id

    cmp     x20, #DIR_TEXT
    b.eq    Lp2_dir_text
    cmp     x20, #DIR_DATA
    b.eq    Lp2_dir_data
    cmp     x20, #DIR_ASCII
    b.eq    Lp2_dir_ascii
    cmp     x20, #DIR_ASCIZ
    b.eq    Lp2_dir_asciz
    cmp     x20, #DIR_BYTE
    b.eq    Lp2_dir_byte
    cmp     x20, #DIR_QUAD
    b.eq    Lp2_dir_quad
    cmp     x20, #DIR_ALIGN
    b.eq    Lp2_dir_align
    cmp     x20, #DIR_GLOBAL
    b.eq    Lp2_dir_global_skip
    cmp     x20, #DIR_SPACE
    b.eq    Lp2_dir_space
    cmp     x20, #DIR_ZERO
    b.eq    Lp2_dir_space

    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_text:
    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    str     xzr, [x8]
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_data:
    adrp    x8, _parse_cur_section@PAGE
    add     x8, x8, _parse_cur_section@PAGEOFF
    mov     x9, #1
    str     x9, [x8]
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_ascii:
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_STRING
    b.ne    Lp2_dir_ascii_skip
    bl      _parse_next_token
    mov     x19, x0                     // string token
    ldr     x21, [x19, #TOK_TEXT_OFF]   // string text ptr
    ldr     x22, [x19, #TOK_LEN_OFF]   // string length

    // Copy string bytes to current section buffer
    bl      Lget_cur_buf                // x0 = dst
    mov     x1, x21                     // src
    mov     x2, x22                     // len
    bl      Lcopy_string_data

    // Advance offset
    bl      Lget_cur_offset
    add     x0, x0, x22
    bl      Lset_cur_offset

Lp2_dir_ascii_skip:
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_asciz:
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_STRING
    b.ne    Lp2_dir_asciz_skip
    bl      _parse_next_token
    mov     x19, x0
    ldr     x21, [x19, #TOK_TEXT_OFF]
    ldr     x22, [x19, #TOK_LEN_OFF]

    // Copy string bytes
    bl      Lget_cur_buf
    mov     x1, x21
    mov     x2, x22
    bl      Lcopy_string_data

    // Add null terminator
    bl      Lget_cur_buf
    add     x8, x0, x22
    strb    wzr, [x8]

    // Advance offset by len + 1
    bl      Lget_cur_offset
    add     x0, x0, x22
    add     x0, x0, #1
    bl      Lset_cur_offset

Lp2_dir_asciz_skip:
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_byte:
    bl      _parse_read_immediate       // x0 = value
    mov     x21, x0
    bl      Lget_cur_buf
    strb    w21, [x0]
    bl      Lget_cur_offset
    add     x0, x0, #1
    bl      Lset_cur_offset
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_quad:
    // Check if next is immediate or label ref
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_LABEL_REF
    b.eq    Lp2_dir_quad_label
    // Assume immediate
    bl      _parse_read_immediate
    mov     x21, x0
    bl      Lget_cur_buf
    str     x21, [x0]
    bl      Lget_cur_offset
    add     x0, x0, #8
    bl      Lset_cur_offset
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_quad_label:
    bl      _parse_next_token
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_lookup
    // For now, store 0 and skip (would need relocation)
    bl      Lget_cur_buf
    str     xzr, [x0]
    bl      Lget_cur_offset
    add     x0, x0, #8
    bl      Lset_cur_offset
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_align:
    bl      _parse_read_immediate       // x0 = N
    mov     x21, x0
    bl      Lget_cur_offset
    // Align to 2^N
    mov     x22, #1
    lsl     x22, x22, x21
    sub     x23, x22, #1
    // Fill padding with zeros
    mov     x24, x0                     // save original offset
    add     x0, x0, x23
    bic     x0, x0, x23                 // aligned offset
    mov     x25, x0                     // new offset
    // Zero-fill padding bytes
    sub     x26, x25, x24              // padding count
    cbz     x26, Lp2_align_done
    bl      Lget_cur_buf                // x0 = buf ptr at current offset
    // Zero fill
    mov     x1, x26
Lp2_align_zero:
    cbz     x1, Lp2_align_done2
    strb    wzr, [x0], #1
    sub     x1, x1, #1
    b       Lp2_align_zero
Lp2_align_done2:
    mov     x0, x25
    bl      Lset_cur_offset
Lp2_align_done:
    mov     x0, x25
    bl      Lset_cur_offset
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_global_skip:
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_dir_space:
    bl      _parse_read_immediate       // x0 = N
    mov     x21, x0
    // Zero-fill N bytes
    bl      Lget_cur_buf
    mov     x1, x21
Lp2_space_zero:
    cbz     x1, Lp2_space_done
    strb    wzr, [x0], #1
    sub     x1, x1, #1
    b       Lp2_space_zero
Lp2_space_done:
    bl      Lget_cur_offset
    add     x0, x0, x21
    bl      Lset_cur_offset
    bl      _parse_skip_to_newline
    b       Lp2_loop

// ============================================================================
// Pass 2: Mnemonic dispatch
// ============================================================================
Lp2_mnemonic:
    bl      _parse_next_token           // consume mnemonic token
    mov     x19, x0                     // x19 = mnemonic token

    // Look up mnemonic ID
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _lookup_mnemonic
    mov     x20, x0                     // x20 = mnemonic_id

    // Save line number for error reporting
    ldr     x26, [x19, #TOK_LINE_OFF]

    // Dispatch by mnemonic ID
    cmp     x20, #MN_ADD
    b.eq    Lp2_add
    cmp     x20, #MN_SUB
    b.eq    Lp2_sub
    cmp     x20, #MN_ADDS
    b.eq    Lp2_adds
    cmp     x20, #MN_SUBS
    b.eq    Lp2_subs

    cmp     x20, #MN_AND
    b.eq    Lp2_and
    cmp     x20, #MN_ORR
    b.eq    Lp2_orr
    cmp     x20, #MN_EOR
    b.eq    Lp2_eor
    cmp     x20, #MN_ANDS
    b.eq    Lp2_ands

    cmp     x20, #MN_MUL
    b.eq    Lp2_mul
    cmp     x20, #MN_MADD
    b.eq    Lp2_madd
    cmp     x20, #MN_MSUB
    b.eq    Lp2_msub
    cmp     x20, #MN_UDIV
    b.eq    Lp2_udiv
    cmp     x20, #MN_SDIV
    b.eq    Lp2_sdiv

    cmp     x20, #MN_MOV
    b.eq    Lp2_mov
    cmp     x20, #MN_MOVZ
    b.eq    Lp2_movz
    cmp     x20, #MN_MOVK
    b.eq    Lp2_movk
    cmp     x20, #MN_MOVN
    b.eq    Lp2_movn

    cmp     x20, #MN_NEG
    b.eq    Lp2_neg
    cmp     x20, #MN_MVN
    b.eq    Lp2_mvn

    cmp     x20, #MN_CMP
    b.eq    Lp2_cmp
    cmp     x20, #MN_CMN
    b.eq    Lp2_cmn
    cmp     x20, #MN_TST
    b.eq    Lp2_tst

    cmp     x20, #MN_B
    b.eq    Lp2_b
    cmp     x20, #MN_BL
    b.eq    Lp2_bl
    cmp     x20, #MN_RET
    b.eq    Lp2_ret

    cmp     x20, #MN_CBZ
    b.eq    Lp2_cbz
    cmp     x20, #MN_CBNZ
    b.eq    Lp2_cbnz

    // Conditional branches: b.eq through b.ls (35-46)
    cmp     x20, #MN_BEQ
    b.ge    Lp2_check_bcond

Lp2_mnem_dispatch2:
    cmp     x20, #MN_LDR
    b.eq    Lp2_ldr
    cmp     x20, #MN_STR
    b.eq    Lp2_str
    cmp     x20, #MN_LDRB
    b.eq    Lp2_ldrb
    cmp     x20, #MN_STRB
    b.eq    Lp2_strb
    cmp     x20, #MN_LDRH
    b.eq    Lp2_ldrh
    cmp     x20, #MN_STRH
    b.eq    Lp2_strh
    cmp     x20, #MN_LDP
    b.eq    Lp2_ldp
    cmp     x20, #MN_STP
    b.eq    Lp2_stp

    cmp     x20, #MN_ADR
    b.eq    Lp2_adr
    cmp     x20, #MN_ADRP
    b.eq    Lp2_adrp

    cmp     x20, #MN_LSL
    b.eq    Lp2_lsl
    cmp     x20, #MN_LSR
    b.eq    Lp2_lsr
    cmp     x20, #MN_ASR
    b.eq    Lp2_asr

    cmp     x20, #MN_SVC
    b.eq    Lp2_svc
    cmp     x20, #MN_NOP
    b.eq    Lp2_nop

    cmp     x20, #MN_UBFM
    b.eq    Lp2_ubfm
    cmp     x20, #MN_SBFM
    b.eq    Lp2_sbfm

    cmp     x20, #MN_CSET
    b.eq    Lp2_cset
    cmp     x20, #MN_CSEL
    b.eq    Lp2_csel

    // Unknown mnemonic — skip line
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_check_bcond:
    cmp     x20, #MN_BLS
    b.le    Lp2_bcond
    b       Lp2_mnem_dispatch2

// ============================================================================
// ADD / SUB / ADDS / SUBS
// Pattern: op Rd, Rn, Rm  or  op Rd, Rn, #imm
// ============================================================================
Lp2_add:
    mov     x21, #0                     // op=0 (add)
    mov     x22, #0                     // setflags=0
    b       Lp2_addsub_common

Lp2_sub:
    mov     x21, #1                     // op=1 (sub)
    mov     x22, #0
    b       Lp2_addsub_common

Lp2_adds:
    mov     x21, #0                     // op=0 (add)
    mov     x22, #1                     // setflags=1
    b       Lp2_addsub_common

Lp2_subs:
    mov     x21, #1                     // op=1 (sub)
    mov     x22, #1                     // setflags=1
    b       Lp2_addsub_common

Lp2_addsub_common:
    // Read Rd
    bl      _parse_read_register
    mov     x23, x0                     // Rd
    mov     x24, x1                     // is_32bit (determines sf)

    bl      _parse_skip_comma

    // Read Rn
    bl      _parse_read_register
    mov     x25, x0                     // Rn

    bl      _parse_skip_comma

    // Peek next: register or immediate?
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_REGISTER
    b.eq    Lp2_addsub_reg
    // Immediate
    bl      _parse_read_immediate
    mov     x5, x0                      // imm12
    // sf = !is_32bit
    mov     x0, #1
    sub     x0, x0, x24                 // sf
    mov     x1, x21                     // op
    mov     x2, x22                     // S
    mov     x3, x23                     // Rd
    mov     x4, x25                     // Rn
    // x5 = imm12
    bl      _enc_add_imm
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_addsub_reg:
    bl      _parse_read_register
    mov     x26, x0                     // Rm

    // Check for optional shift: , lsl/lsr/asr #amt
    mov     w8, #0                      // shift_type = 0 (LSL)
    mov     w9, #0                      // shift_amt = 0

    // Peek for comma (shift follows)
    stp     x8, x9, [sp, #-16]!        // save shift info
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    ldp     x8, x9, [sp]               // reload (but x8 is clobbered)
    // Reload shift defaults
    ldr     x10, [x0, #TOK_TYPE_OFF]
    cmp     x10, #TOK_COMMA
    b.ne    Lp2_addsub_reg_encode
    // There might be a shift — consume comma and check
    bl      _parse_next_token           // consume comma
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_MNEMONIC
    b.ne    Lp2_addsub_reg_encode       // not a shift mnemonic

    // Read shift type
    bl      _parse_next_token
    ldr     x0, [x0, #TOK_TEXT_OFF]
    ldr     x1, [x0, #TOK_LEN_OFF]
    // For simplicity, just default to LSL=0
    mov     w8, #0                      // shift_type

    // Read shift amount
    bl      _parse_read_immediate
    mov     w9, w0                      // shift_amt
    add     sp, sp, #16                 // pop old saved values
    stp     x8, x9, [sp, #-16]!        // push updated values

Lp2_addsub_reg_encode:
    ldp     x8, x9, [sp], #16          // pop shift_type, shift_amt
    // Encode: sf, op, S, Rd, Rn, Rm, shift_type, shift_amt
    mov     x0, #1
    sub     x0, x0, x24                 // sf
    mov     x1, x21                     // op
    mov     x2, x22                     // S
    mov     x3, x23                     // Rd
    mov     x4, x25                     // Rn
    mov     x5, x26                     // Rm
    mov     x6, x8                      // shift_type
    mov     x7, x9                      // shift_amt
    bl      _enc_add_reg
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// AND / ORR / EOR / ANDS — logical register
// Pattern: op Rd, Rn, Rm
// ============================================================================
Lp2_and:
    mov     x21, #0b00                  // opc
    mov     x22, #0                     // N
    b       Lp2_logic_common

Lp2_orr:
    mov     x21, #0b01
    mov     x22, #0
    b       Lp2_logic_common

Lp2_eor:
    mov     x21, #0b10
    mov     x22, #0
    b       Lp2_logic_common

Lp2_ands:
    mov     x21, #0b11
    mov     x22, #0
    b       Lp2_logic_common

Lp2_logic_common:
    bl      _parse_read_register
    mov     x23, x0                     // Rd
    mov     x24, x1                     // is_32bit
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x25, x0                     // Rn
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x26, x0                     // Rm

    mov     x0, #1
    sub     x0, x0, x24                 // sf
    mov     x1, x21                     // opc
    mov     x2, x22                     // N
    mov     x3, x23                     // Rd
    mov     x4, x25                     // Rn
    mov     x5, x26                     // Rm
    mov     x6, #0                      // shift_type = LSL
    mov     x7, #0                      // shift_amt = 0
    bl      _enc_logic_reg
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// MUL — mul Rd, Rn, Rm
// ============================================================================
Lp2_mul:
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    mov     x22, x1                     // is_32bit
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0                     // Rn
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x24, x0                     // Rm

    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, x21                     // Rd
    mov     x2, x23                     // Rn
    mov     x3, x24                     // Rm
    bl      _enc_mul
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// MADD — madd Rd, Rn, Rm, Ra
// ============================================================================
Lp2_madd:
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    mov     x22, x1                     // is_32bit
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0                     // Rn
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x24, x0                     // Rm
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x25, x0                     // Ra

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x23
    mov     x3, x24
    mov     x4, x25
    bl      _enc_madd
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// MSUB — msub Rd, Rn, Rm, Ra
// ============================================================================
Lp2_msub:
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x24, x0
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x25, x0

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x23
    mov     x3, x24
    mov     x4, x25
    bl      _enc_msub
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// UDIV / SDIV — op Rd, Rn, Rm
// ============================================================================
Lp2_udiv:
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x24, x0

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x23
    mov     x3, x24
    bl      _enc_udiv
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_sdiv:
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x24, x0

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x23
    mov     x3, x24
    bl      _enc_sdiv
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// MOV — mov Rd, Rm  or  mov Rd, #imm
// ============================================================================
Lp2_mov:
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    mov     x22, x1                     // is_32bit

    bl      _parse_skip_comma

    // Peek: register or immediate?
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_REGISTER
    b.eq    Lp2_mov_reg
    // Immediate: mov Rd, #imm → movz
    bl      _parse_read_immediate
    mov     x23, x0                     // imm value

    // Check if negative
    tbnz    x23, #63, Lp2_mov_neg

    // Check if fits in 16 bits
    mov     x8, #0xFFFF
    cmp     x23, x8
    b.hi    Lp2_mov_wide

    // Simple movz
    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, x21                     // Rd
    mov     x2, x23                     // imm16
    mov     x3, #0                      // hw=0
    bl      _enc_movz
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_mov_neg:
    // Negative value: use movn
    // movn Rd, #(~imm & 0xFFFF), lsl #0
    mvn     x23, x23                    // bitwise NOT
    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, x21                     // Rd
    and     x2, x23, #0xFFFF           // imm16
    mov     x3, #0                      // hw=0
    bl      _enc_movn
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_mov_wide:
    // Large constant: movz + movk sequence
    // movz Rd, #(imm & 0xFFFF), lsl #0
    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    and     x2, x23, #0xFFFF
    mov     x3, #0
    bl      _enc_movz
    bl      Lemit_inst

    // movk Rd, #((imm >> 16) & 0xFFFF), lsl #16
    lsr     x24, x23, #16
    and     x24, x24, #0xFFFF
    cbz     x24, Lp2_mov_wide_check32

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x24
    mov     x3, #1                      // hw=1
    bl      _enc_movk
    bl      Lemit_inst

Lp2_mov_wide_check32:
    // Check bits 32-47
    lsr     x24, x23, #32
    and     x24, x24, #0xFFFF
    cbz     x24, Lp2_mov_wide_check48

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x24
    mov     x3, #2
    bl      _enc_movk
    bl      Lemit_inst

Lp2_mov_wide_check48:
    // Check bits 48-63
    lsr     x24, x23, #48
    and     x24, x24, #0xFFFF
    cbz     x24, Lp2_mov_wide_done

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x24
    mov     x3, #3
    bl      _enc_movk
    bl      Lemit_inst

Lp2_mov_wide_done:
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_mov_reg:
    // mov Rd, Rm → orr Rd, xzr, Rm
    bl      _parse_read_register
    mov     x23, x0                     // Rm

    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, #0b01                   // opc = ORR
    mov     x2, #0                      // N = 0
    mov     x3, x21                     // Rd
    mov     x4, #31                     // Rn = XZR
    mov     x5, x23                     // Rm
    mov     x6, #0                      // shift = LSL
    mov     x7, #0                      // amt = 0
    bl      _enc_logic_reg
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// MOVZ / MOVK / MOVN — movz Rd, #imm [, lsl #shift]
// ============================================================================
Lp2_movz:
    mov     x21, #0                     // 0 = movz
    b       Lp2_movzk_common

Lp2_movk:
    mov     x21, #1                     // 1 = movk
    b       Lp2_movzk_common

Lp2_movn:
    mov     x21, #2                     // 2 = movn
    b       Lp2_movzk_common

Lp2_movzk_common:
    bl      _parse_read_register
    mov     x22, x0                     // Rd
    mov     x23, x1                     // is_32bit

    bl      _parse_skip_comma

    bl      _parse_read_immediate
    mov     x24, x0                     // imm16

    // Check for optional , lsl #shift
    mov     x25, #0                     // hw = 0
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_COMMA
    b.ne    Lp2_movzk_encode

    bl      _parse_next_token           // consume comma
    // Expect "lsl" mnemonic token
    bl      _parse_next_token           // consume lsl
    bl      _parse_read_immediate       // shift amount
    // Convert shift to hw: 0→0, 16→1, 32→2, 48→3
    lsr     x25, x0, #4                // hw = shift / 16

Lp2_movzk_encode:
    mov     x0, #1
    sub     x0, x0, x23                 // sf
    mov     x1, x22                     // Rd
    and     x2, x24, #0xFFFF           // imm16
    mov     x3, x25                     // hw

    cmp     x21, #1
    b.eq    Lp2_movzk_k
    cmp     x21, #2
    b.eq    Lp2_movzk_n

    bl      _enc_movz
    b       Lp2_movzk_emit

Lp2_movzk_k:
    bl      _enc_movk
    b       Lp2_movzk_emit

Lp2_movzk_n:
    bl      _enc_movn

Lp2_movzk_emit:
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// NEG — neg Rd, Rm → sub Rd, xzr, Rm
// ============================================================================
Lp2_neg:
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    mov     x22, x1                     // is_32bit
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0                     // Rm

    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, #1                      // op = sub
    mov     x2, #0                      // S = 0
    mov     x3, x21                     // Rd
    mov     x4, #31                     // Rn = XZR
    mov     x5, x23                     // Rm
    mov     x6, #0
    mov     x7, #0
    bl      _enc_add_reg
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// MVN — mvn Rd, Rm → orn Rd, xzr, Rm (opc=01, N=1)
// ============================================================================
Lp2_mvn:
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0

    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, #0b01                   // opc = ORR
    mov     x2, #1                      // N = 1 (invert → ORN)
    mov     x3, x21                     // Rd
    mov     x4, #31                     // Rn = XZR
    mov     x5, x23                     // Rm
    mov     x6, #0
    mov     x7, #0
    bl      _enc_logic_reg
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// CMP — cmp Rn, Rm/#imm → subs xzr, Rn, Rm/#imm
// ============================================================================
Lp2_cmp:
    bl      _parse_read_register
    mov     x21, x0                     // Rn
    mov     x22, x1                     // is_32bit
    bl      _parse_skip_comma

    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_REGISTER
    b.eq    Lp2_cmp_reg

    // cmp Rn, #imm → subs xzr, Rn, #imm
    bl      _parse_read_immediate
    mov     x5, x0                      // imm12
    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, #1                      // op = sub
    mov     x2, #1                      // S = 1
    // Rd = XZR (31) for W or X depending on sf
    mov     x3, #31                     // Rd = xzr/wzr
    mov     x4, x21                     // Rn
    bl      _enc_add_imm
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_cmp_reg:
    bl      _parse_read_register
    mov     x23, x0                     // Rm

    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, #1                      // op = sub
    mov     x2, #1                      // S = 1
    mov     x3, #31                     // Rd = xzr
    mov     x4, x21                     // Rn
    mov     x5, x23                     // Rm
    mov     x6, #0
    mov     x7, #0
    bl      _enc_add_reg
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// CMN — cmn Rn, Rm/#imm → adds xzr, Rn, Rm/#imm
// ============================================================================
Lp2_cmn:
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma

    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_REGISTER
    b.eq    Lp2_cmn_reg

    bl      _parse_read_immediate
    mov     x5, x0
    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, #0                      // op = add
    mov     x2, #1                      // S = 1
    mov     x3, #31
    mov     x4, x21
    bl      _enc_add_imm
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_cmn_reg:
    bl      _parse_read_register
    mov     x23, x0
    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, #0
    mov     x2, #1
    mov     x3, #31
    mov     x4, x21
    mov     x5, x23
    mov     x6, #0
    mov     x7, #0
    bl      _enc_add_reg
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// TST — tst Rn, Rm → ands xzr, Rn, Rm
// ============================================================================
Lp2_tst:
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, #0b11                   // opc = ANDS
    mov     x2, #0                      // N = 0
    mov     x3, #31                     // Rd = xzr
    mov     x4, x21                     // Rn
    mov     x5, x23                     // Rm
    mov     x6, #0
    mov     x7, #0
    bl      _enc_logic_reg
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// B / BL — branch to label
// ============================================================================
Lp2_b:
    bl      _parse_next_token           // consume label ref
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_lookup
    mov     x21, x0                     // sym entry (or 0)

    cbz     x21, Lp2_b_extern

    // Check if defined
    mov     x0, x21
    bl      _sym_is_defined
    cbz     x0, Lp2_b_extern

    // Defined label: compute PC-relative offset
    ldr     x22, [x21, #16]            // sym value (offset)
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x23, [x8]                   // current text offset (PC)
    sub     x0, x22, x23               // offset = target - PC
    bl      _enc_b
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_b_extern:
    // External/undefined symbol — emit relocation
    // Re-add symbol to ensure it is in symtab
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_add
    mov     x21, x0

    // Get nlist index
    ldr     w22, [x21, #40]            // nlist_index

    // Record relocation
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x0, [x8]                    // address = current text offset
    mov     x1, x22                     // sym_index
    mov     x2, #ARM64_RELOC_BRANCH26   // type
    mov     x3, #1                      // pcrel = 1
    mov     x4, #1                      // extern = 1
    mov     x5, #2                      // length = 2 (4 bytes)
    bl      _macho_add_reloc

    // Encode with offset=0 (linker will patch)
    mov     x0, #0
    bl      _enc_b
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_bl:
    bl      _parse_next_token           // consume label ref
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_lookup
    mov     x21, x0

    cbz     x21, Lp2_bl_extern

    mov     x0, x21
    bl      _sym_is_defined
    cbz     x0, Lp2_bl_extern

    // Defined label
    ldr     x22, [x21, #16]
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x23, [x8]
    sub     x0, x22, x23
    bl      _enc_bl
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_bl_extern:
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_add
    mov     x21, x0
    ldr     w22, [x21, #40]

    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x0, [x8]
    mov     x1, x22
    mov     x2, #ARM64_RELOC_BRANCH26
    mov     x3, #1
    mov     x4, #1
    mov     x5, #2
    bl      _macho_add_reloc

    mov     x0, #0
    bl      _enc_bl
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// RET — ret [Rn]
// ============================================================================
Lp2_ret:
    // Check if there is an operand
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_REGISTER
    b.eq    Lp2_ret_reg

    // ret → ret x30
    mov     x0, #30
    bl      _enc_ret
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_ret_reg:
    bl      _parse_read_register
    bl      _enc_ret
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// B.cond — conditional branches
// ============================================================================
Lp2_bcond:
    // x20 = mnemonic_id (35-46)
    // Map mnemonic_id to condition code using lookup table
    sub     x21, x20, #MN_BEQ          // index into cond map table
    adrp    x8, Lbcond_table@PAGE
    add     x8, x8, Lbcond_table@PAGEOFF
    ldrb    w22, [x8, x21]             // w22 = condition code

    // Read label
    bl      _parse_next_token
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_lookup
    mov     x21, x0

    cbz     x21, Lp2_bcond_extern

    mov     x0, x21
    bl      _sym_is_defined
    cbz     x0, Lp2_bcond_extern

    // Defined label
    ldr     x23, [x21, #16]            // target offset
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x24, [x8]                   // PC
    sub     x1, x23, x24               // offset = target - PC

    mov     x0, x22                     // cond code
    bl      _enc_b_cond
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_bcond_extern:
    // External conditional branch (rare, but handle)
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_add
    mov     x21, x0
    ldr     w23, [x21, #40]

    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x0, [x8]
    mov     x1, x23
    mov     x2, #ARM64_RELOC_BRANCH26
    mov     x3, #1
    mov     x4, #1
    mov     x5, #2
    bl      _macho_add_reloc

    mov     x0, x22                     // cond
    mov     x1, #0                      // offset = 0
    bl      _enc_b_cond
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// CBZ / CBNZ
// ============================================================================
Lp2_cbz:
    bl      _parse_read_register
    mov     x21, x0                     // Rt
    mov     x22, x1                     // is_32bit
    bl      _parse_skip_comma

    bl      _parse_next_token           // label ref
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_lookup
    mov     x23, x0

    cbz     x23, Lp2_cbz_zero
    mov     x0, x23
    bl      _sym_is_defined
    cbz     x0, Lp2_cbz_zero

    ldr     x24, [x23, #16]
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x25, [x8]
    sub     x2, x24, x25               // offset

    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, x21                     // Rt
    bl      _enc_cbz
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_cbz_zero:
    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, #0
    bl      _enc_cbz
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_cbnz:
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma

    bl      _parse_next_token
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_lookup
    mov     x23, x0

    cbz     x23, Lp2_cbnz_zero
    mov     x0, x23
    bl      _sym_is_defined
    cbz     x0, Lp2_cbnz_zero

    ldr     x24, [x23, #16]
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x25, [x8]
    sub     x2, x24, x25

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    bl      _enc_cbnz
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_cbnz_zero:
    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, #0
    bl      _enc_cbnz
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// LDR / STR / LDRB / STRB / LDRH / STRH
// Pattern: op Rt, [Rn] or [Rn, #imm] or [Rn, #imm]! or [Rn], #imm
// ============================================================================
Lp2_ldr:
    mov     x21, #3                     // size=3 (64-bit)
    mov     x22, #1                     // is_load=1
    b       Lp2_ldst_common

Lp2_str:
    mov     x21, #3
    mov     x22, #0                     // is_load=0
    b       Lp2_ldst_common

Lp2_ldrb:
    mov     x21, #0                     // size=0 (byte)
    mov     x22, #1
    b       Lp2_ldst_common

Lp2_strb:
    mov     x21, #0
    mov     x22, #0
    b       Lp2_ldst_common

Lp2_ldrh:
    mov     x21, #1                     // size=1 (halfword)
    mov     x22, #1
    b       Lp2_ldst_common

Lp2_strh:
    mov     x21, #1
    mov     x22, #0
    b       Lp2_ldst_common

Lp2_ldst_common:
    // Read Rt
    bl      _parse_read_register
    mov     x23, x0                     // Rt
    mov     x24, x1                     // is_32bit of Rt

    bl      _parse_skip_comma

    // Expect LBRACKET
    mov     x0, #TOK_LBRACKET
    bl      _parse_expect_token

    // Read Rn
    bl      _parse_read_register
    mov     x25, x0                     // Rn

    // Peek next token
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]

    // [Rn] — no offset
    cmp     x8, #TOK_RBRACKET
    b.eq    Lp2_ldst_no_offset

    // [Rn, ...
    cmp     x8, #TOK_COMMA
    b.eq    Lp2_ldst_offset

    // Unexpected
    b       Lp2_ldst_no_offset

Lp2_ldst_no_offset:
    bl      _parse_next_token           // consume RBRACKET
    // Unsigned offset with imm=0
    mov     x0, x21                     // size
    mov     x1, x23                     // Rt
    mov     x2, x25                     // Rn
    mov     x3, #0                      // offset = 0
    cmp     x22, #1
    b.eq    Lp2_ldst_uoff_ldr
    bl      _enc_str_uoff
    b       Lp2_ldst_emit
Lp2_ldst_uoff_ldr:
    bl      _enc_ldr_uoff
    b       Lp2_ldst_emit

Lp2_ldst_offset:
    bl      _parse_next_token           // consume comma

    // Read immediate offset
    bl      _parse_read_immediate
    mov     x26, x0                     // offset value

    // Peek: RBRACKET
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_RBRACKET
    b.ne    Lp2_ldst_uoff_fallback

    bl      _parse_next_token           // consume RBRACKET

    // Peek: EXCLAIM → pre-index
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_EXCLAIM
    b.eq    Lp2_ldst_pre

    // No exclaim: check for post-index comma after bracket
    // This is unsigned offset: [Rn, #imm]
    mov     x0, x21                     // size
    mov     x1, x23                     // Rt
    mov     x2, x25                     // Rn
    mov     x3, x26                     // offset
    cmp     x22, #1
    b.eq    1f
    bl      _enc_str_uoff
    b       Lp2_ldst_emit
1:  bl      _enc_ldr_uoff
    b       Lp2_ldst_emit

Lp2_ldst_pre:
    bl      _parse_next_token           // consume EXCLAIM
    // Pre-index: [Rn, #imm]!
    mov     x0, x21
    mov     x1, x23
    mov     x2, x25
    mov     x3, x26
    cmp     x22, #1
    b.eq    1f
    bl      _enc_str_pre
    b       Lp2_ldst_emit
1:  bl      _enc_ldr_pre
    b       Lp2_ldst_emit

Lp2_ldst_uoff_fallback:
    // Fallback: treat as unsigned offset
    mov     x0, x21
    mov     x1, x23
    mov     x2, x25
    mov     x3, x26
    cmp     x22, #1
    b.eq    1f
    bl      _enc_str_uoff
    b       Lp2_ldst_emit
1:  bl      _enc_ldr_uoff
    b       Lp2_ldst_emit

Lp2_ldst_emit:
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// LDP / STP
// Pattern: ldp Rt, Rt2, [Rn, #imm] or pre/post-index
// ============================================================================
Lp2_ldp:
    mov     x21, #1                     // is_load = 1
    b       Lp2_ldpstp_common

Lp2_stp:
    mov     x21, #0                     // is_load = 0
    b       Lp2_ldpstp_common

Lp2_ldpstp_common:
    // Read Rt
    bl      _parse_read_register
    mov     x22, x0                     // Rt
    mov     x23, x1                     // is_32bit (determines sf)

    bl      _parse_skip_comma

    // Read Rt2
    bl      _parse_read_register
    mov     x24, x0                     // Rt2

    bl      _parse_skip_comma

    // Expect LBRACKET
    mov     x0, #TOK_LBRACKET
    bl      _parse_expect_token

    // Read Rn
    bl      _parse_read_register
    mov     x25, x0                     // Rn

    // Peek next
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]

    // [Rn] — signed offset with imm=0
    cmp     x8, #TOK_RBRACKET
    b.eq    Lp2_ldpstp_no_offset

    // [Rn, #imm...
    cmp     x8, #TOK_COMMA
    b.eq    Lp2_ldpstp_offset

    b       Lp2_ldpstp_no_offset

Lp2_ldpstp_no_offset:
    bl      _parse_next_token           // consume RBRACKET

    // Check for post-index: ], #imm
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_COMMA
    b.eq    Lp2_ldpstp_post_start

    // Signed offset with imm=0
    mov     x0, #1
    sub     x0, x0, x23                 // sf
    mov     x1, x22                     // Rt
    mov     x2, x24                     // Rt2
    mov     x3, x25                     // Rn
    mov     x4, #0                      // offset = 0
    mov     x5, #0                      // type = signed offset
    cmp     x21, #1
    b.eq    1f
    bl      _enc_stp
    b       Lp2_ldpstp_emit
1:  bl      _enc_ldp
    b       Lp2_ldpstp_emit

Lp2_ldpstp_post_start:
    bl      _parse_next_token           // consume comma
    bl      _parse_read_immediate
    mov     x26, x0                     // offset

    mov     x0, #1
    sub     x0, x0, x23
    mov     x1, x22
    mov     x2, x24
    mov     x3, x25
    mov     x4, x26
    mov     x5, #2                      // type = post-index
    cmp     x21, #1
    b.eq    1f
    bl      _enc_stp
    b       Lp2_ldpstp_emit
1:  bl      _enc_ldp
    b       Lp2_ldpstp_emit

Lp2_ldpstp_offset:
    bl      _parse_next_token           // consume comma

    bl      _parse_read_immediate
    mov     x26, x0                     // offset

    // Expect RBRACKET
    mov     x0, #TOK_RBRACKET
    bl      _parse_expect_token

    // Check for exclaim → pre-index
    bl      _parse_peek_token
    ldr     x8, [x0, #TOK_TYPE_OFF]
    cmp     x8, #TOK_EXCLAIM
    b.eq    Lp2_ldpstp_pre

    // Signed offset
    mov     x0, #1
    sub     x0, x0, x23
    mov     x1, x22
    mov     x2, x24
    mov     x3, x25
    mov     x4, x26
    mov     x5, #0                      // type = signed offset
    cmp     x21, #1
    b.eq    1f
    bl      _enc_stp
    b       Lp2_ldpstp_emit
1:  bl      _enc_ldp
    b       Lp2_ldpstp_emit

Lp2_ldpstp_pre:
    bl      _parse_next_token           // consume exclaim

    mov     x0, #1
    sub     x0, x0, x23
    mov     x1, x22
    mov     x2, x24
    mov     x3, x25
    mov     x4, x26
    mov     x5, #1                      // type = pre-index
    cmp     x21, #1
    b.eq    1f
    bl      _enc_stp
    b       Lp2_ldpstp_emit
1:  bl      _enc_ldp
    b       Lp2_ldpstp_emit

Lp2_ldpstp_emit:
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// ADR / ADRP
// ============================================================================
Lp2_adr:
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    bl      _parse_skip_comma

    bl      _parse_next_token           // label ref
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_lookup
    mov     x22, x0

    cbz     x22, Lp2_adr_zero
    mov     x0, x22
    bl      _sym_is_defined
    cbz     x0, Lp2_adr_zero

    ldr     x23, [x22, #16]            // target offset
    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x24, [x8]                   // PC
    sub     x1, x23, x24               // offset
    mov     x0, x21                     // Rd
    bl      _enc_adr
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_adr_zero:
    mov     x0, x21
    mov     x1, #0
    bl      _enc_adr
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_adrp:
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    bl      _parse_skip_comma

    bl      _parse_next_token           // label ref
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _sym_add
    mov     x22, x0                     // sym entry

    // Record PAGE21 relocation
    ldr     w23, [x22, #40]            // nlist_index

    adrp    x8, _parse_text_size@PAGE
    add     x8, x8, _parse_text_size@PAGEOFF
    ldr     x0, [x8]                    // address
    mov     x1, x23                     // sym_index
    mov     x2, #ARM64_RELOC_PAGE21     // type
    mov     x3, #1                      // pcrel
    mov     x4, #1                      // extern
    mov     x5, #2                      // length (4 bytes)
    bl      _macho_add_reloc

    // Encode with offset=0
    mov     x0, x21
    mov     x1, #0
    bl      _enc_adrp
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// LSL / LSR / ASR (immediate aliases)
// ============================================================================
Lp2_lsl:
    // lsl Rd, Rn, #imm → ubfm Rd, Rn, #(-imm mod 64), #(63-imm)  [64-bit]
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    mov     x22, x1                     // is_32bit
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0                     // Rn
    bl      _parse_skip_comma
    bl      _parse_read_immediate
    mov     x24, x0                     // shift amount

    // Compute immr and imms based on sf
    mov     x0, #1
    sub     x0, x0, x22                 // sf
    cbz     x0, Lp2_lsl_32

    // 64-bit: immr = (-imm) & 63, imms = 63 - imm
    neg     x3, x24
    and     x3, x3, #63               // immr
    mov     x4, #63
    sub     x4, x4, x24               // imms
    b       Lp2_lsl_enc

Lp2_lsl_32:
    // 32-bit: immr = (-imm) & 31, imms = 31 - imm
    neg     x3, x24
    and     x3, x3, #31
    mov     x4, #31
    sub     x4, x4, x24

Lp2_lsl_enc:
    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21                     // Rd
    mov     x2, x23                     // Rn
    // x3 = immr, x4 = imms
    bl      _enc_ubfm
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_lsr:
    // lsr Rd, Rn, #imm → ubfm Rd, Rn, #imm, #63  [64-bit]
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0
    bl      _parse_skip_comma
    bl      _parse_read_immediate
    mov     x24, x0                     // shift amount

    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, x21
    mov     x2, x23
    mov     x3, x24                     // immr = imm
    cbz     x0, 1f
    mov     x4, #63                     // imms = 63 (64-bit)
    b       2f
1:  mov     x4, #31                     // imms = 31 (32-bit)
2:
    // Restore sf
    mov     x0, #1
    sub     x0, x0, x22
    bl      _enc_ubfm
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_asr:
    // asr Rd, Rn, #imm → sbfm Rd, Rn, #imm, #63  [64-bit]
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0
    bl      _parse_skip_comma
    bl      _parse_read_immediate
    mov     x24, x0

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x23
    mov     x3, x24
    cbz     x0, 1f
    mov     x4, #63
    b       2f
1:  mov     x4, #31
2:
    mov     x0, #1
    sub     x0, x0, x22
    bl      _enc_sbfm
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// UBFM / SBFM — ubfm Rd, Rn, #immr, #imms
// ============================================================================
Lp2_ubfm:
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    mov     x22, x1                     // is_32bit
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0                     // Rn
    bl      _parse_skip_comma
    bl      _parse_read_immediate
    mov     x24, x0                     // immr
    bl      _parse_skip_comma
    bl      _parse_read_immediate
    mov     x25, x0                     // imms

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x23
    mov     x3, x24
    mov     x4, x25
    bl      _enc_ubfm
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop

Lp2_sbfm:
    bl      _parse_read_register
    mov     x21, x0
    mov     x22, x1
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0
    bl      _parse_skip_comma
    bl      _parse_read_immediate
    mov     x24, x0
    bl      _parse_skip_comma
    bl      _parse_read_immediate
    mov     x25, x0

    mov     x0, #1
    sub     x0, x0, x22
    mov     x1, x21
    mov     x2, x23
    mov     x3, x24
    mov     x4, x25
    bl      _enc_sbfm
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// SVC — svc #imm
// ============================================================================
Lp2_svc:
    bl      _parse_read_immediate
    bl      _enc_svc
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// NOP
// ============================================================================
Lp2_nop:
    bl      _enc_nop
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// CSET — cset Rd, cond
// ============================================================================
Lp2_cset:
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    mov     x22, x1                     // is_32bit
    bl      _parse_skip_comma

    // Read condition code name
    bl      _parse_next_token
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _lookup_cond_code           // x0 = cond code

    mov     x2, x0                      // cond
    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, x21                     // Rd
    bl      _enc_cset
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


// ============================================================================
// CSEL — csel Rd, Rn, Rm, cond
// ============================================================================
Lp2_csel:
    bl      _parse_read_register
    mov     x21, x0                     // Rd
    mov     x22, x1                     // is_32bit
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x23, x0                     // Rn
    bl      _parse_skip_comma
    bl      _parse_read_register
    mov     x24, x0                     // Rm
    bl      _parse_skip_comma

    // Read condition code
    bl      _parse_next_token
    mov     x19, x0
    ldr     x0, [x19, #TOK_TEXT_OFF]
    ldr     x1, [x19, #TOK_LEN_OFF]
    bl      _lookup_cond_code
    mov     x25, x0                     // cond

    mov     x0, #1
    sub     x0, x0, x22                 // sf
    mov     x1, x21                     // Rd
    mov     x2, x23                     // Rn
    mov     x3, x24                     // Rm
    mov     x4, x25                     // cond
    bl      _enc_csel
    bl      Lemit_inst
    bl      _parse_skip_to_newline
    b       Lp2_loop


Lp2_done:
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #80
    ret


// ============================================================================
// Lcopy_string_data — Copy string data, processing escape sequences
// ============================================================================
// Args: x0 = dst, x1 = src, x2 = len (raw token text)
// Copies bytes, translating \n, \t, \\, \0, \"
.p2align 2
Lcopy_string_data:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    mov     x3, x0                      // dst
    mov     x4, x1                      // src
    mov     x5, x2                      // remaining

Lcopy_str_loop:
    cbz     x5, Lcopy_str_done
    ldrb    w6, [x4], #1
    sub     x5, x5, #1

    cmp     w6, #'\\'
    b.ne    Lcopy_str_plain

    // Escape sequence
    cbz     x5, Lcopy_str_plain_backslash
    ldrb    w6, [x4], #1
    sub     x5, x5, #1

    cmp     w6, #'n'
    b.eq    Lcopy_str_newline
    cmp     w6, #'t'
    b.eq    Lcopy_str_tab
    cmp     w6, #'0'
    b.eq    Lcopy_str_null
    cmp     w6, #'\\'
    b.eq    Lcopy_str_backslash
    cmp     w6, #'"'
    b.eq    Lcopy_str_quote

    // Unknown escape: store literal backslash + char
    mov     w7, #'\\'
    strb    w7, [x3], #1
    strb    w6, [x3], #1
    b       Lcopy_str_loop

Lcopy_str_newline:
    mov     w6, #10
    strb    w6, [x3], #1
    b       Lcopy_str_loop

Lcopy_str_tab:
    mov     w6, #9
    strb    w6, [x3], #1
    b       Lcopy_str_loop

Lcopy_str_null:
    strb    wzr, [x3], #1
    b       Lcopy_str_loop

Lcopy_str_backslash:
    mov     w6, #'\\'
    strb    w6, [x3], #1
    b       Lcopy_str_loop

Lcopy_str_quote:
    mov     w6, #'"'
    strb    w6, [x3], #1
    b       Lcopy_str_loop

Lcopy_str_plain_backslash:
    mov     w6, #'\\'
Lcopy_str_plain:
    strb    w6, [x3], #1
    b       Lcopy_str_loop

Lcopy_str_done:
    ldp     x29, x30, [sp], #16
    ret


// ============================================================================
// DATA SECTION
// ============================================================================
.section __DATA,__data
.p2align 3

_parse_text_buf:
    .quad   0
_parse_text_size:
    .quad   0
_parse_data_buf:
    .quad   0
_parse_data_size:
    .quad   0
_parse_cur_section:
    .quad   0
_parse_tok_idx:
    .quad   0
_parse_tok_count:
    .quad   0

// Condition code lookup table for b.cond (indexed by mnemonic_id - 35)
// b.eq=0x0, b.ne=0x1, b.lt=0xB, b.gt=0xC, b.le=0xD, b.ge=0xA,
// b.cs=0x2, b.cc=0x3, b.mi=0x4, b.pl=0x5, b.hi=0x8, b.ls=0x9
.p2align 2
Lbcond_table:
    .byte   0x0                         // b.eq (35)
    .byte   0x1                         // b.ne (36)
    .byte   0xB                         // b.lt (37)
    .byte   0xC                         // b.gt (38)
    .byte   0xD                         // b.le (39)
    .byte   0xA                         // b.ge (40)
    .byte   0x2                         // b.cs (41)
    .byte   0x3                         // b.cc (42)
    .byte   0x4                         // b.mi (43)
    .byte   0x5                         // b.pl (44)
    .byte   0x8                         // b.hi (45)
    .byte   0x9                         // b.ls (46)

// Error message strings
.p2align 2
Lerr_unexpected_token:
    .asciz  "unexpected token"
Lerr_expected_register:
    .asciz  "expected register"
Lerr_expected_immediate:
    .asciz  "expected immediate value"

.subsections_via_symbols
