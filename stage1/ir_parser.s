// Stage 1 IR Compiler - Parser
// Parses token stream into function/block/instruction data structures
// Target: AArch64 macOS (Apple Silicon)

.global _parse_and_codegen

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

.equ TOK_SIZE,      32

.equ OP_ADD,        0
.equ OP_SUB,        1
.equ OP_MUL,        2
.equ OP_DIV,        3
.equ OP_MOD,        4
.equ OP_AND,        5
.equ OP_OR,         6
.equ OP_XOR,        7
.equ OP_SHL,        8
.equ OP_SHR,        9
.equ OP_CMP_EQ,     10
.equ OP_CMP_NE,     11
.equ OP_CMP_LT,     12
.equ OP_CMP_GT,     13
.equ OP_CMP_LE,     14
.equ OP_CMP_GE,     15
.equ OP_LOAD,       16
.equ OP_STORE,      17
.equ OP_ALLOCA,     18
.equ OP_BR,         19
.equ OP_BR_COND,    20
.equ OP_RET,        21
.equ OP_CALL,       22
.equ OP_PHI,        23
.equ OP_ZEXT,       24
.equ OP_SEXT,       25
.equ OP_TRUNC,      26
.equ OP_PTRTOINT,   27
.equ OP_INTTOPTR,   28
.equ OP_ARG,        29

.equ OPKIND_VREG,   0
.equ OPKIND_IMM,    1
.equ OPKIND_BLOCK,  2
.equ OPKIND_FUNC,   3

// Instruction struct layout (256 bytes):
// [0]   opcode_id     (4)
// [4]   result_vreg   (4), -1 if none
// [8]   type_id       (4)
// [12]  num_operands  (4)
// [16]  op[0].kind    (4)
// [20]  (pad)         (4)
// [24]  op[0].value   (8)
// [32]  op[0].name_ptr (8)
// [40]  op[0].name_len (8)
// [48]  op[1].kind    (4)
// [52]  (pad)         (4)
// [56]  op[1].value   (8)
// [64]  op[1].name_ptr (8)
// [72]  op[1].name_len (8)
// [80]  op[2].kind    (4)
// [84]  (pad)         (4)
// [88]  op[2].value   (8)
// [96]  op[2].name_ptr (8)
// [104] op[2].name_len (8)
// [112] op[3].kind    (4) -- used for call args
// [116] (pad)         (4)
// [120] op[3].value   (8)
// ...
// [144] phi_count     (4)
// [148] (pad)         (4)
// [152] phi[0].value_kind (4)
// [156] (pad)         (4)
// [160] phi[0].value  (8)
// [168] phi[0].block_name_ptr (8)
// [176] phi[0].block_name_len (8)
// [184] phi[1].value_kind (4)
// ...each phi entry = 32 bytes
// phi[1] at 184, phi[2] at 216

.equ INSTR_SIZE,    256
.equ BLOCK_SIZE,    32
.equ FUNC_SIZE,     64
.equ VREG_ENTRY_SIZE, 32
.equ MAX_FUNCS,     64
.equ MAX_BLOCKS,    256
.equ MAX_INSTRS,    4096
.equ MAX_VREGS,     1024

.text
.align 4

// _parse_and_codegen(tokens, num_tokens, src, output_buf) -> output_len
_parse_and_codegen:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    // Store params in globals
    adrp    x10, _pg_tokens@PAGE
    str     x0, [x10, _pg_tokens@PAGEOFF]
    adrp    x10, _pg_num_tokens@PAGE
    str     x1, [x10, _pg_num_tokens@PAGEOFF]
    mov     x19, x3             // output_buf

    adrp    x10, _pg_tok_pos@PAGE
    str     xzr, [x10, _pg_tok_pos@PAGEOFF]

    // Allocate arrays
    mov     x0, #FUNC_SIZE
    mov     x1, #MAX_FUNCS
    mul     x0, x0, x1
    bl      _malloc
    mov     x20, x0
    adrp    x10, _pg_func_array@PAGE
    str     x0, [x10, _pg_func_array@PAGEOFF]

    mov     x0, #BLOCK_SIZE
    mov     x1, #MAX_BLOCKS
    mul     x0, x0, x1
    bl      _malloc
    mov     x21, x0
    adrp    x10, _pg_block_array@PAGE
    str     x0, [x10, _pg_block_array@PAGEOFF]

    mov     x0, #INSTR_SIZE
    mov     x1, #MAX_INSTRS
    mul     x0, x0, x1
    bl      _malloc
    mov     x22, x0
    adrp    x10, _pg_instr_array@PAGE
    str     x0, [x10, _pg_instr_array@PAGEOFF]

    mov     x0, #VREG_ENTRY_SIZE
    mov     x1, #MAX_VREGS
    mul     x0, x0, x1
    bl      _malloc
    mov     x23, x0
    adrp    x10, _pg_vreg_table@PAGE
    str     x0, [x10, _pg_vreg_table@PAGEOFF]

    // Init counters
    adrp    x10, _pg_num_funcs@PAGE
    str     wzr, [x10, _pg_num_funcs@PAGEOFF]
    adrp    x10, _pg_total_blocks@PAGE
    str     wzr, [x10, _pg_total_blocks@PAGEOFF]
    adrp    x10, _pg_total_instrs@PAGE
    str     wzr, [x10, _pg_total_instrs@PAGEOFF]
    adrp    x10, _pg_num_vregs@PAGE
    str     wzr, [x10, _pg_num_vregs@PAGEOFF]

    // Parse all functions
1:  bl      _p_skip_nl
    bl      _p_peek
    cmp     w0, #TOK_EOF
    b.eq    2f
    cmp     w0, #TOK_FUNC
    b.ne    _p_error
    bl      _p_func
    b       1b

2:  // Codegen
    adrp    x10, _pg_num_funcs@PAGE
    ldr     w0, [x10, _pg_num_funcs@PAGEOFF]
    mov     x1, x20
    mov     x2, x21
    mov     x3, x22
    mov     x4, x23
    mov     x5, x19
    mov     x6, #0
    bl      _codegen_all
    mov     x24, x0

    mov     x0, x20
    bl      _free
    mov     x0, x21
    bl      _free
    mov     x0, x22
    bl      _free
    mov     x0, x23
    bl      _free

    mov     x0, x24
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x29, x30, [sp], #64
    ret

_p_error:
    adrp    x1, _p_err_msg@PAGE
    add     x1, x1, _p_err_msg@PAGEOFF
    mov     x2, #13
    mov     x0, #2
    mov     x16, #4
    svc     #0x80
    mov     x0, #1
    mov     x16, #1
    svc     #0x80

// Peek -> w0 = token type
_p_peek:
    adrp    x10, _pg_tok_pos@PAGE
    ldr     x11, [x10, _pg_tok_pos@PAGEOFF]
    adrp    x10, _pg_num_tokens@PAGE
    ldr     x12, [x10, _pg_num_tokens@PAGEOFF]
    cmp     x11, x12
    b.ge    1f
    lsl     x13, x11, #5
    adrp    x10, _pg_tokens@PAGE
    ldr     x14, [x10, _pg_tokens@PAGEOFF]
    ldr     w0, [x14, x13]
    ret
1:  mov     w0, #TOK_EOF
    ret

// Next -> x0 = token pointer, advances
_p_next:
    adrp    x10, _pg_tok_pos@PAGE
    ldr     x11, [x10, _pg_tok_pos@PAGEOFF]
    lsl     x13, x11, #5
    adrp    x12, _pg_tokens@PAGE
    ldr     x14, [x12, _pg_tokens@PAGEOFF]
    add     x0, x14, x13
    add     x11, x11, #1
    str     x11, [x10, _pg_tok_pos@PAGEOFF]
    ret

// Skip one token
_p_skip:
    adrp    x10, _pg_tok_pos@PAGE
    ldr     x11, [x10, _pg_tok_pos@PAGEOFF]
    add     x11, x11, #1
    str     x11, [x10, _pg_tok_pos@PAGEOFF]
    ret

// Skip newlines
_p_skip_nl:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
1:  bl      _p_peek
    cmp     w0, #TOK_NEWLINE
    b.ne    2f
    bl      _p_skip
    b       1b
2:  ldp     x29, x30, [sp], #16
    ret

// Parse function
_p_func:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    adrp    x10, _pg_num_funcs@PAGE
    ldr     w19, [x10, _pg_num_funcs@PAGEOFF]   // func_idx

    adrp    x10, _pg_num_vregs@PAGE
    str     wzr, [x10, _pg_num_vregs@PAGEOFF]    // reset vregs

    bl      _p_skip              // skip 'func'

    // @name
    bl      _p_peek
    cmp     w0, #TOK_AT
    b.ne    _p_error
    bl      _p_next              // x0 = token
    mov     x10, x0
    ldr     x20, [x10, #8]      // text_ptr (with @)
    ldr     x21, [x10, #16]     // text_len
    add     x20, x20, #1
    sub     x21, x21, #1

    // Func ptr
    adrp    x10, _pg_func_array@PAGE
    ldr     x11, [x10, _pg_func_array@PAGEOFF]
    mov     x12, #FUNC_SIZE
    umull   x13, w19, w12
    add     x22, x11, x13
    str     x20, [x22]
    str     x21, [x22, #8]

    // ( params )
    bl      _p_peek
    cmp     w0, #TOK_LPAREN
    b.ne    _p_error
    bl      _p_skip

    mov     w23, #0
1:  bl      _p_peek
    cmp     w0, #TOK_RPAREN
    b.eq    2f
    cmp     w0, #TOK_TYPE
    b.ne    _p_error
    bl      _p_skip
    add     w23, w23, #1
    bl      _p_peek
    cmp     w0, #TOK_COMMA
    b.ne    1b
    bl      _p_skip
    b       1b
2:  bl      _p_skip              // skip )
    str     w23, [x22, #16]      // num_params

    // -> type (optional)
    bl      _p_peek
    cmp     w0, #TOK_ARROW
    b.ne    3f
    bl      _p_skip
    bl      _p_peek
    cmp     w0, #TOK_TYPE
    b.ne    _p_error
    bl      _p_skip
3:  str     wzr, [x22, #20]

    bl      _p_skip_nl

    // {
    bl      _p_peek
    cmp     w0, #TOK_LBRACE
    b.ne    _p_error
    bl      _p_skip

    // first_block_idx
    adrp    x10, _pg_total_blocks@PAGE
    ldr     w24, [x10, _pg_total_blocks@PAGEOFF]
    str     w24, [x22, #24]

    mov     w23, #0              // block count
4:  bl      _p_skip_nl
    bl      _p_peek
    cmp     w0, #TOK_RBRACE
    b.eq    5f
    bl      _p_block
    add     w23, w23, #1
    b       4b

5:  bl      _p_skip              // skip }
    str     w23, [x22, #28]
    adrp    x10, _pg_num_vregs@PAGE
    ldr     w10, [x10, _pg_num_vregs@PAGEOFF]
    str     w10, [x22, #32]

    adrp    x10, _pg_num_funcs@PAGE
    ldr     w11, [x10, _pg_num_funcs@PAGEOFF]
    add     w11, w11, #1
    str     w11, [x10, _pg_num_funcs@PAGEOFF]

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x29, x30, [sp], #64
    ret

// Parse block
_p_block:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    adrp    x10, _pg_total_blocks@PAGE
    ldr     w19, [x10, _pg_total_blocks@PAGEOFF]

    // label:
    bl      _p_peek
    cmp     w0, #TOK_IDENT
    b.eq    1f
    cmp     w0, #TOK_OPCODE
    b.eq    1f
    b       _p_error
1:  bl      _p_next
    mov     x10, x0
    ldr     x20, [x10, #8]
    ldr     x21, [x10, #16]

    bl      _p_peek
    cmp     w0, #TOK_COLON
    b.ne    _p_error
    bl      _p_skip

    // Store block
    adrp    x10, _pg_block_array@PAGE
    ldr     x11, [x10, _pg_block_array@PAGEOFF]
    mov     x12, #BLOCK_SIZE
    umull   x13, w19, w12
    add     x22, x11, x13
    str     x20, [x22]
    str     x21, [x22, #8]

    adrp    x10, _pg_total_instrs@PAGE
    ldr     w23, [x10, _pg_total_instrs@PAGEOFF]
    str     w23, [x22, #16]     // first_instr_idx

    mov     w24, #0              // instr count

2:  bl      _p_skip_nl
    bl      _p_peek
    cmp     w0, #TOK_RBRACE
    b.eq    3f
    cmp     w0, #TOK_EOF
    b.eq    3f

    // Check for new block label (ident/opcode followed by colon)
    cmp     w0, #TOK_IDENT
    b.eq    4f
    cmp     w0, #TOK_OPCODE
    b.eq    4f
    b       5f

4:  // Lookahead: is next token a colon?
    adrp    x10, _pg_tok_pos@PAGE
    ldr     x11, [x10, _pg_tok_pos@PAGEOFF]
    add     x12, x11, #1
    adrp    x10, _pg_num_tokens@PAGE
    ldr     x13, [x10, _pg_num_tokens@PAGEOFF]
    cmp     x12, x13
    b.ge    5f
    lsl     x14, x12, #5
    adrp    x10, _pg_tokens@PAGE
    ldr     x15, [x10, _pg_tokens@PAGEOFF]
    ldr     w16, [x15, x14]
    cmp     w16, #TOK_COLON
    b.eq    3f

5:  bl      _p_instr
    add     w24, w24, #1
    b       2b

3:  str     w24, [x22, #20]

    adrp    x10, _pg_total_blocks@PAGE
    ldr     w11, [x10, _pg_total_blocks@PAGEOFF]
    add     w11, w11, #1
    str     w11, [x10, _pg_total_blocks@PAGEOFF]

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x29, x30, [sp], #64
    ret

// Parse instruction
_p_instr:
    stp     x29, x30, [sp, #-80]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]

    // Get instr index and pointer
    adrp    x10, _pg_total_instrs@PAGE
    ldr     w19, [x10, _pg_total_instrs@PAGEOFF]

    adrp    x10, _pg_instr_array@PAGE
    ldr     x11, [x10, _pg_instr_array@PAGEOFF]
    mov     x12, #INSTR_SIZE
    umull   x13, w19, w12
    add     x20, x11, x13       // instr_ptr

    // Zero it
    mov     x0, x20
    mov     w1, #0
    mov     x2, #INSTR_SIZE
    bl      _p_memset

    // Default no result
    mov     w10, #-1
    str     w10, [x20, #4]

    // Check for %name = ...
    bl      _p_peek
    cmp     w0, #TOK_PERCENT
    b.ne    .Lpi_no_result

    // %name
    bl      _p_next
    mov     x21, x0             // save token ptr
    ldr     x0, [x21, #8]       // text_ptr (includes %)
    ldr     x1, [x21, #16]      // text_len
    add     x0, x0, #1          // skip %
    sub     x1, x1, #1
    bl      _p_get_vreg          // -> w0 = vreg_id
    str     w0, [x20, #4]       // result_vreg

    // =
    bl      _p_peek
    cmp     w0, #TOK_EQUALS
    b.ne    _p_error
    bl      _p_skip

.Lpi_no_result:
    // Expect opcode
    bl      _p_peek
    cmp     w0, #TOK_OPCODE
    b.ne    _p_error
    bl      _p_next
    mov     x21, x0
    ldr     x0, [x21, #8]       // opcode text
    ldr     x1, [x21, #16]      // opcode len
    bl      _p_identify_opcode   // -> w0 = opcode_id
    str     w0, [x20]           // opcode_id
    mov     w22, w0             // save opcode

    // Dispatch based on opcode
    cmp     w22, #OP_RET
    b.eq    .Lpi_ret
    cmp     w22, #OP_BR
    b.eq    .Lpi_br
    cmp     w22, #OP_BR_COND
    b.eq    .Lpi_br_cond
    cmp     w22, #OP_CALL
    b.eq    .Lpi_call
    cmp     w22, #OP_PHI
    b.eq    .Lpi_phi
    cmp     w22, #OP_ARG
    b.eq    .Lpi_arg
    b       .Lpi_binop           // default: binary op (type op1, op2)

// Binary op: type op1, op2
.Lpi_binop:
    bl      _p_peek
    cmp     w0, #TOK_TYPE
    b.ne    _p_error
    bl      _p_skip

    bl      _p_operand           // -> w0=kind, x1=value
    str     w0, [x20, #16]
    str     x1, [x20, #24]

    bl      _p_peek
    cmp     w0, #TOK_COMMA
    b.ne    _p_error
    bl      _p_skip

    bl      _p_operand
    str     w0, [x20, #48]
    str     x1, [x20, #56]

    mov     w10, #2
    str     w10, [x20, #12]
    b       .Lpi_done

// ret [type value]
.Lpi_ret:
    bl      _p_peek
    cmp     w0, #TOK_TYPE
    b.ne    .Lpi_ret_void
    bl      _p_skip
    bl      _p_operand
    str     w0, [x20, #16]
    str     x1, [x20, #24]
    mov     w10, #1
    str     w10, [x20, #12]
    b       .Lpi_done
.Lpi_ret_void:
    str     wzr, [x20, #12]
    b       .Lpi_done

// br @label
.Lpi_br:
    bl      _p_peek
    cmp     w0, #TOK_AT
    b.ne    _p_error
    bl      _p_next
    mov     x21, x0
    ldr     x10, [x21, #8]
    ldr     x11, [x21, #16]
    add     x10, x10, #1
    sub     x11, x11, #1
    mov     w12, #OPKIND_BLOCK
    str     w12, [x20, #16]
    str     x10, [x20, #32]
    str     x11, [x20, #40]
    mov     w10, #1
    str     w10, [x20, #12]
    b       .Lpi_done

// br_cond %cond, @true, @false
.Lpi_br_cond:
    bl      _p_operand           // condition
    str     w0, [x20, #16]
    str     x1, [x20, #24]

    bl      _p_peek
    cmp     w0, #TOK_COMMA
    b.ne    _p_error
    bl      _p_skip

    // @true
    bl      _p_peek
    cmp     w0, #TOK_AT
    b.ne    _p_error
    bl      _p_next
    mov     x21, x0
    ldr     x10, [x21, #8]
    ldr     x11, [x21, #16]
    add     x10, x10, #1
    sub     x11, x11, #1
    mov     w12, #OPKIND_BLOCK
    str     w12, [x20, #48]
    str     x10, [x20, #64]
    str     x11, [x20, #72]

    bl      _p_peek
    cmp     w0, #TOK_COMMA
    b.ne    _p_error
    bl      _p_skip

    // @false
    bl      _p_peek
    cmp     w0, #TOK_AT
    b.ne    _p_error
    bl      _p_next
    mov     x21, x0
    ldr     x10, [x21, #8]
    ldr     x11, [x21, #16]
    add     x10, x10, #1
    sub     x11, x11, #1
    mov     w12, #OPKIND_BLOCK
    str     w12, [x20, #80]
    str     x10, [x20, #96]
    str     x11, [x20, #104]

    mov     w10, #3
    str     w10, [x20, #12]
    b       .Lpi_done

// call type @func, [type arg, ...]
.Lpi_call:
    bl      _p_peek
    cmp     w0, #TOK_TYPE
    b.ne    _p_error
    bl      _p_skip

    // @func
    bl      _p_peek
    cmp     w0, #TOK_AT
    b.ne    _p_error
    bl      _p_next
    mov     x21, x0
    ldr     x10, [x21, #8]
    ldr     x11, [x21, #16]
    add     x10, x10, #1
    sub     x11, x11, #1
    mov     w12, #OPKIND_FUNC
    str     w12, [x20, #16]
    str     x10, [x20, #32]
    str     x11, [x20, #40]

    mov     w23, #1              // op count (func is op[0])

.Lpi_call_args:
    bl      _p_peek
    cmp     w0, #TOK_COMMA
    b.ne    .Lpi_call_done
    bl      _p_skip

    bl      _p_peek
    cmp     w0, #TOK_TYPE
    b.ne    _p_error
    bl      _p_skip

    bl      _p_operand
    // Store at op[w23]
    mov     w10, #32
    umull   x11, w23, w10
    add     x11, x11, #16       // offset for op[w23]
    str     w0, [x20, x11]      // kind
    add     x12, x11, #8
    str     x1, [x20, x12]      // value

    add     w23, w23, #1
    b       .Lpi_call_args

.Lpi_call_done:
    str     w23, [x20, #12]
    b       .Lpi_done

// phi type [val, @block], ...
.Lpi_phi:
    bl      _p_peek
    cmp     w0, #TOK_TYPE
    b.ne    _p_error
    bl      _p_skip

    mov     w23, #0              // phi entry count

.Lpi_phi_entry:
    bl      _p_peek
    cmp     w0, #TOK_LBRACKET
    b.ne    .Lpi_phi_done
    bl      _p_skip

    // value
    bl      _p_operand
    // Store at offset 152 + w23*32
    mov     w10, #32
    umull   x11, w23, w10
    add     x11, x11, #152
    str     w0, [x20, x11]      // value_kind
    add     x12, x11, #8
    str     x1, [x20, x12]      // value

    // comma
    bl      _p_peek
    cmp     w0, #TOK_COMMA
    b.ne    _p_error
    bl      _p_skip

    // @block
    bl      _p_peek
    cmp     w0, #TOK_AT
    b.ne    _p_error
    bl      _p_next
    mov     x21, x0
    ldr     x10, [x21, #8]
    ldr     x14, [x21, #16]
    add     x10, x10, #1
    sub     x14, x14, #1
    // Recompute offset for this entry
    mov     w15, #32
    umull   x11, w23, w15
    add     x11, x11, #152
    add     x12, x11, #16
    str     x10, [x20, x12]     // block_name_ptr
    add     x12, x11, #24
    str     x14, [x20, x12]     // block_name_len

    // ]
    bl      _p_peek
    cmp     w0, #TOK_RBRACKET
    b.ne    _p_error
    bl      _p_skip

    add     w23, w23, #1

    // comma between entries
    bl      _p_peek
    cmp     w0, #TOK_COMMA
    b.ne    .Lpi_phi_done
    bl      _p_skip
    b       .Lpi_phi_entry

.Lpi_phi_done:
    str     w23, [x20, #144]
    str     wzr, [x20, #12]
    b       .Lpi_done

// arg type index
.Lpi_arg:
    bl      _p_peek
    cmp     w0, #TOK_TYPE
    b.ne    _p_error
    bl      _p_skip

    bl      _p_operand
    str     w0, [x20, #16]
    str     x1, [x20, #24]
    mov     w10, #1
    str     w10, [x20, #12]
    b       .Lpi_done

.Lpi_done:
    // Increment instr count
    adrp    x10, _pg_total_instrs@PAGE
    ldr     w11, [x10, _pg_total_instrs@PAGEOFF]
    add     w11, w11, #1
    str     w11, [x10, _pg_total_instrs@PAGEOFF]

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x29, x30, [sp], #80
    ret

// Parse operand -> w0=kind, x1=value
_p_operand:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]

    bl      _p_peek
    cmp     w0, #TOK_PERCENT
    b.eq    1f
    cmp     w0, #TOK_INTEGER
    b.eq    2f
    b       _p_error

1:  // vreg
    bl      _p_next
    mov     x19, x0
    ldr     x0, [x19, #8]       // text with %
    ldr     x1, [x19, #16]
    add     x0, x0, #1
    sub     x1, x1, #1
    bl      _p_get_vreg
    mov     x1, x0              // vreg_id in x1
    mov     w0, #OPKIND_VREG
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

2:  // immediate
    bl      _p_next
    mov     x19, x0
    ldr     x0, [x19, #8]
    ldr     x1, [x19, #16]
    bl      _p_parse_int         // -> x0 = value
    mov     x1, x0
    mov     w0, #OPKIND_IMM
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// Parse int from text: x0=ptr, x1=len -> x0=value
_p_parse_int:
    mov     x10, x0
    mov     x11, x1
    mov     x0, #0
    mov     x12, #0
    mov     x13, #0              // neg flag

    cbz     x11, 9f
    ldrb    w14, [x10]
    cmp     w14, #'-'
    b.ne    1f
    mov     x13, #1
    add     x12, x12, #1

1:  cmp     x12, x11
    b.ge    2f
    ldrb    w14, [x10, x12]
    sub     w14, w14, #'0'
    mov     x15, #10
    mul     x0, x0, x15
    add     x0, x0, x14
    add     x12, x12, #1
    b       1b

2:  cbz     x13, 9f
    neg     x0, x0
9:  ret

// Get or create vreg: x0=name_ptr, x1=name_len -> w0=vreg_id
_p_get_vreg:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0
    mov     x20, x1

    adrp    x10, _pg_vreg_table@PAGE
    ldr     x21, [x10, _pg_vreg_table@PAGEOFF]
    adrp    x10, _pg_num_vregs@PAGE
    ldr     w22, [x10, _pg_num_vregs@PAGEOFF]

    mov     w0, #0               // search index

1:  cmp     w0, w22
    b.ge    3f                   // not found, create

    mov     x12, #VREG_ENTRY_SIZE
    umull   x13, w0, w12
    add     x14, x21, x13

    ldr     x15, [x14]           // name_ptr
    ldr     x16, [x14, #8]      // name_len

    cmp     x16, x20
    b.ne    2f

    // Compare bytes
    mov     x17, #0
4:  cmp     x17, x20
    b.ge    5f                   // match
    ldrb    w2, [x19, x17]
    ldrb    w3, [x15, x17]
    cmp     w2, w3
    b.ne    2f
    add     x17, x17, #1
    b       4b

5:  // Found
    ldr     w0, [x14, #16]
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x29, x30, [sp], #48
    ret

2:  add     w0, w0, #1
    b       1b

3:  // Create new vreg
    mov     x12, #VREG_ENTRY_SIZE
    umull   x13, w22, w12
    add     x14, x21, x13
    str     x19, [x14]
    str     x20, [x14, #8]
    str     w22, [x14, #16]

    mov     w0, w22
    add     w22, w22, #1

    adrp    x10, _pg_num_vregs@PAGE
    str     w22, [x10, _pg_num_vregs@PAGEOFF]

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x29, x30, [sp], #48
    ret

// Identify opcode: x0=text, x1=len -> w0=opcode_id
_p_identify_opcode:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x0
    mov     x20, x1

    adrp    x10, _opcode_id_tbl@PAGE
    add     x10, x10, _opcode_id_tbl@PAGEOFF

1:  ldr     w11, [x10]           // opcode_id (-1 = end)
    cmn     w11, #1
    b.eq    9f
    ldr     x12, [x10, #8]      // name_ptr
    ldr     x13, [x10, #16]     // name_len

    cmp     x13, x20
    b.ne    2f

    mov     x14, #0
3:  cmp     x14, x20
    b.ge    4f                   // match
    ldrb    w15, [x19, x14]
    ldrb    w16, [x12, x14]
    cmp     w15, w16
    b.ne    2f
    add     x14, x14, #1
    b       3b

4:  mov     w0, w11
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

2:  add     x10, x10, #24
    b       1b

9:  mov     w0, #-1
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// memset: x0=ptr, w1=byte, x2=count
_p_memset:
    mov     x10, #0
1:  cmp     x10, x2
    b.ge    2f
    strb    w1, [x0, x10]
    add     x10, x10, #1
    b       1b
2:  ret

// =========================================================
// Data
// =========================================================
.data
.align 3

_p_err_msg: .ascii "Parse error!\n"

// Opcode name strings (for identification)
_op_s_add:      .ascii "add"
_op_s_sub:      .ascii "sub"
_op_s_mul:      .ascii "mul"
_op_s_div:      .ascii "div"
_op_s_mod:      .ascii "mod"
_op_s_and:      .ascii "and"
_op_s_or:       .ascii "or"
_op_s_xor:      .ascii "xor"
_op_s_shl:      .ascii "shl"
_op_s_shr:      .ascii "shr"
_op_s_cmp_eq:   .ascii "cmp_eq"
_op_s_cmp_ne:   .ascii "cmp_ne"
_op_s_cmp_lt:   .ascii "cmp_lt"
_op_s_cmp_gt:   .ascii "cmp_gt"
_op_s_cmp_le:   .ascii "cmp_le"
_op_s_cmp_ge:   .ascii "cmp_ge"
_op_s_load:     .ascii "load"
_op_s_store:    .ascii "store"
_op_s_alloca:   .ascii "alloca"
_op_s_br:       .ascii "br"
_op_s_br_cond:  .ascii "br_cond"
_op_s_ret:      .ascii "ret"
_op_s_call:     .ascii "call"
_op_s_phi:      .ascii "phi"
_op_s_zext:     .ascii "zext"
_op_s_sext:     .ascii "sext"
_op_s_trunc:    .ascii "trunc"
_op_s_ptrtoint: .ascii "ptrtoint"
_op_s_inttoptr: .ascii "inttoptr"
_op_s_arg:      .ascii "arg"

.align 3
// Each entry: opcode_id(4), pad(4), name_ptr(8), name_len(8) = 24 bytes
_opcode_id_tbl:
    .long 0, 0
    .quad _op_s_add
    .quad 3
    .long 1, 0
    .quad _op_s_sub
    .quad 3
    .long 2, 0
    .quad _op_s_mul
    .quad 3
    .long 3, 0
    .quad _op_s_div
    .quad 3
    .long 4, 0
    .quad _op_s_mod
    .quad 3
    .long 5, 0
    .quad _op_s_and
    .quad 3
    .long 6, 0
    .quad _op_s_or
    .quad 2
    .long 7, 0
    .quad _op_s_xor
    .quad 3
    .long 8, 0
    .quad _op_s_shl
    .quad 3
    .long 9, 0
    .quad _op_s_shr
    .quad 3
    .long 10, 0
    .quad _op_s_cmp_eq
    .quad 6
    .long 11, 0
    .quad _op_s_cmp_ne
    .quad 6
    .long 12, 0
    .quad _op_s_cmp_lt
    .quad 6
    .long 13, 0
    .quad _op_s_cmp_gt
    .quad 6
    .long 14, 0
    .quad _op_s_cmp_le
    .quad 6
    .long 15, 0
    .quad _op_s_cmp_ge
    .quad 6
    .long 16, 0
    .quad _op_s_load
    .quad 4
    .long 17, 0
    .quad _op_s_store
    .quad 5
    .long 18, 0
    .quad _op_s_alloca
    .quad 6
    .long 19, 0
    .quad _op_s_br
    .quad 2
    .long 20, 0
    .quad _op_s_br_cond
    .quad 7
    .long 21, 0
    .quad _op_s_ret
    .quad 3
    .long 22, 0
    .quad _op_s_call
    .quad 4
    .long 23, 0
    .quad _op_s_phi
    .quad 3
    .long 24, 0
    .quad _op_s_zext
    .quad 4
    .long 25, 0
    .quad _op_s_sext
    .quad 4
    .long 26, 0
    .quad _op_s_trunc
    .quad 5
    .long 27, 0
    .quad _op_s_ptrtoint
    .quad 8
    .long 28, 0
    .quad _op_s_inttoptr
    .quad 8
    .long 29, 0
    .quad _op_s_arg
    .quad 3
    // End marker
    .long -1, 0
    .quad 0
    .quad 0

// Parser globals
.align 3
_pg_tokens:         .quad 0
_pg_num_tokens:     .quad 0
_pg_src:            .quad 0
_pg_tok_pos:        .quad 0
_pg_func_array:     .quad 0
_pg_block_array:    .quad 0
_pg_instr_array:    .quad 0
_pg_vreg_table:     .quad 0
_pg_num_funcs:      .long 0
    .long 0
_pg_total_blocks:   .long 0
    .long 0
_pg_total_instrs:   .long 0
    .long 0
_pg_num_vregs:      .long 0
    .long 0
