// Stage 1 IR Compiler - Code Generator
// Walks parsed IR data structures and emits AArch64 assembly
// Target: AArch64 macOS (Apple Silicon)

.global _codegen_all

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

.equ INSTR_SIZE, 256
.equ BLOCK_SIZE, 32
.equ FUNC_SIZE, 64

// Macro to load address of a data symbol into x0
// Uses x8 as scratch (x8 is a temp on AAPCS64)
.macro LOAD_ADDR reg, sym
    adrp    \reg, \sym@PAGE
    add     \reg, \reg, \sym@PAGEOFF
.endm

.text
.align 4

// =========================================================
// Helper functions
// =========================================================

// emit_str: append string to output buffer
// x0 = string ptr, x1 = string len
_emit_str:
    cbz     x1, 9f
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    LOAD_ADDR x10, _g_outbuf
    ldr     x11, [x10]
    LOAD_ADDR x10, _g_outpos
    ldr     x12, [x10]
    mov     x13, #0
0:  cmp     x13, x1
    b.ge    1f
    ldrb    w14, [x0, x13]
    strb    w14, [x11, x12]
    add     x12, x12, #1
    add     x13, x13, #1
    b       0b
1:  LOAD_ADDR x10, _g_outpos
    str     x12, [x10]
    ldp     x29, x30, [sp], #16
9:  ret

// emit_cstr: emit null-terminated string
_emit_cstr:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    mov     x10, x0
    mov     x1, #0
0:  ldrb    w11, [x10, x1]
    cbz     w11, 1f
    add     x1, x1, #1
    b       0b
1:  bl      _emit_str
    ldp     x29, x30, [sp], #16
    ret

// emit_uint: emit unsigned 64-bit int as decimal
_emit_uint:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    mov     x10, x0
    add     x11, sp, #56
    mov     x12, x11
    mov     x13, #10

    cbnz    x10, 0f
    sub     x11, x11, #1
    mov     w14, #'0'
    strb    w14, [x11]
    b       1f
0:  cbz     x10, 1f
    udiv    x14, x10, x13
    msub    x15, x14, x13, x10
    add     w15, w15, #'0'
    sub     x11, x11, #1
    strb    w15, [x11]
    mov     x10, x14
    b       0b
1:  mov     x0, x11
    sub     x1, x12, x11
    bl      _emit_str
    ldp     x29, x30, [sp], #64
    ret

// emit_sint: emit signed 64-bit int
_emit_sint:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    cmp     x0, #0
    b.ge    0f
    str     x0, [sp, #-16]!
    mov     w0, #'-'
    bl      _emit_char
    ldr     x0, [sp], #16
    neg     x0, x0
0:  bl      _emit_uint
    ldp     x29, x30, [sp], #16
    ret

// emit_char: emit single character
_emit_char:
    LOAD_ADDR x10, _g_outbuf
    ldr     x11, [x10]
    LOAD_ADDR x10, _g_outpos
    ldr     x12, [x10]
    strb    w0, [x11, x12]
    add     x12, x12, #1
    str     x12, [x10]
    ret

// calc_frame_size: w0 = num_vregs -> w0 = frame_size
_calc_frame_size:
    lsl     w0, w0, #3
    add     w0, w0, #16
    add     w0, w0, #15
    and     w0, w0, #0xFFFFFFF0
    cmp     w0, #16
    b.ge    0f
    mov     w0, #16
0:  ret

// emit "x<N>" where w0=N
_emit_xreg:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    str     x19, [sp, #-16]!
    mov     w19, w0
    mov     w0, #'x'
    bl      _emit_char
    mov     x0, x19
    bl      _emit_uint
    ldr     x19, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// emit_load_operand: load value into register
// w0=kind, x1=value, w2=target_reg
_emit_load_operand:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     w19, w2             // target reg
    mov     x20, x1             // value

    cmp     w0, #OPKIND_IMM
    b.eq    .Lelo_imm
    cmp     w0, #OPKIND_VREG
    b.eq    .Lelo_vreg
    b       .Lelo_done

.Lelo_imm:
    // Check if fits in simple mov (0..65535)
    cmp     x20, #0
    b.lt    .Lelo_imm_large
    mov     x10, #65535
    cmp     x20, x10
    b.gt    .Lelo_imm_large

    // mov xN, #val
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_mov
    bl      _emit_cstr
    mov     w0, w19
    bl      _emit_xreg
    LOAD_ADDR x0, _s_comma_hash
    bl      _emit_cstr
    mov     x0, x20
    bl      _emit_uint
    mov     w0, #'\n'
    bl      _emit_char
    b       .Lelo_done

.Lelo_imm_large:
    // movz xN, #(val & 0xFFFF)
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_movz
    bl      _emit_cstr
    mov     w0, w19
    bl      _emit_xreg
    LOAD_ADDR x0, _s_comma_hash
    bl      _emit_cstr
    and     x0, x20, #0xFFFF
    bl      _emit_uint
    mov     w0, #'\n'
    bl      _emit_char

    // movk bits 16-31
    lsr     x10, x20, #16
    and     x10, x10, #0xFFFF
    cbz     x10, .Lelo_ck32
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_movk
    bl      _emit_cstr
    mov     w0, w19
    bl      _emit_xreg
    LOAD_ADDR x0, _s_comma_hash
    bl      _emit_cstr
    lsr     x0, x20, #16
    and     x0, x0, #0xFFFF
    bl      _emit_uint
    LOAD_ADDR x0, _s_lsl16
    bl      _emit_cstr

.Lelo_ck32:
    lsr     x10, x20, #32
    and     x10, x10, #0xFFFF
    cbz     x10, .Lelo_ck48
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_movk
    bl      _emit_cstr
    mov     w0, w19
    bl      _emit_xreg
    LOAD_ADDR x0, _s_comma_hash
    bl      _emit_cstr
    lsr     x0, x20, #32
    and     x0, x0, #0xFFFF
    bl      _emit_uint
    LOAD_ADDR x0, _s_lsl32
    bl      _emit_cstr

.Lelo_ck48:
    lsr     x10, x20, #48
    and     x10, x10, #0xFFFF
    cbz     x10, .Lelo_done
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_movk
    bl      _emit_cstr
    mov     w0, w19
    bl      _emit_xreg
    LOAD_ADDR x0, _s_comma_hash
    bl      _emit_cstr
    lsr     x0, x20, #48
    and     x0, x0, #0xFFFF
    bl      _emit_uint
    LOAD_ADDR x0, _s_lsl48
    bl      _emit_cstr

.Lelo_done:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

.Lelo_vreg:
    // ldr xN, [x29, #offset]
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_ldr
    bl      _emit_cstr
    mov     w0, w19
    bl      _emit_xreg
    LOAD_ADDR x0, _s_comma_fp_hash
    bl      _emit_cstr
    lsl     w0, w20, #3
    add     x0, x0, #16
    bl      _emit_uint
    LOAD_ADDR x0, _s_bracket_nl
    bl      _emit_cstr
    b       .Lelo_done

// emit_store_x9: str x9, [x29, #offset]
// w0 = vreg_id
_emit_store_x9:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp
    str     x19, [sp, #-16]!
    mov     w19, w0
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_str_x9_fp
    bl      _emit_cstr
    lsl     w0, w19, #3
    add     x0, x0, #16
    bl      _emit_uint
    LOAD_ADDR x0, _s_bracket_nl
    bl      _emit_cstr
    ldr     x19, [sp], #16
    ldp     x29, x30, [sp], #16
    ret

// emit block label: .LBB_funcname_blockname
// x2=block_name_ptr, x3=block_name_len
_emit_block_label:
    stp     x29, x30, [sp, #-32]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    mov     x19, x2
    mov     x20, x3
    LOAD_ADDR x0, _s_lbb_prefix
    bl      _emit_cstr
    LOAD_ADDR x10, _g_cur_func_name
    ldr     x0, [x10]
    LOAD_ADDR x10, _g_cur_func_namelen
    ldr     x1, [x10]
    bl      _emit_str
    mov     w0, #'_'
    bl      _emit_char
    mov     x0, x19
    mov     x1, x20
    bl      _emit_str
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #32
    ret

// =========================================================
// _codegen_all
// =========================================================
_codegen_all:
    stp     x29, x30, [sp, #-80]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]

    mov     w19, w0
    mov     x20, x1
    mov     x21, x2
    mov     x22, x3

    LOAD_ADDR x10, _g_outbuf
    str     x5, [x10]
    LOAD_ADDR x10, _g_outpos
    str     x6, [x10]
    LOAD_ADDR x10, _g_block_array
    str     x2, [x10]
    LOAD_ADDR x10, _g_instr_array
    str     x3, [x10]

    LOAD_ADDR x0, _s_dot_text
    bl      _emit_cstr

    mov     w23, #0
.Lcga_loop:
    cmp     w23, w19
    b.ge    .Lcga_done
    mov     x12, #FUNC_SIZE
    umull   x13, w23, w12
    add     x0, x20, x13
    bl      _codegen_func
    add     w23, w23, #1
    b       .Lcga_loop

.Lcga_done:
    LOAD_ADDR x10, _g_outpos
    ldr     x0, [x10]
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x29, x30, [sp], #80
    ret

// =========================================================
// _codegen_func
// =========================================================
_codegen_func:
    stp     x29, x30, [sp, #-80]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]

    mov     x19, x0
    ldr     x20, [x19]
    ldr     x21, [x19, #8]
    ldr     w22, [x19, #24]
    ldr     w23, [x19, #28]
    ldr     w24, [x19, #32]

    LOAD_ADDR x10, _g_cur_func_name
    str     x20, [x10]
    LOAD_ADDR x10, _g_cur_func_namelen
    str     x21, [x10]
    LOAD_ADDR x10, _g_cur_num_vregs
    str     w24, [x10]
    LOAD_ADDR x10, _g_func_first_block
    str     w22, [x10]
    LOAD_ADDR x10, _g_func_num_blocks
    str     w23, [x10]

    mov     w0, w24
    bl      _calc_frame_size
    mov     w25, w0
    LOAD_ADDR x10, _g_cur_frame_size
    str     w25, [x10]

    // .global _funcname
    LOAD_ADDR x0, _s_dot_global
    bl      _emit_cstr
    mov     w0, #'_'
    bl      _emit_char
    mov     x0, x20
    mov     x1, x21
    bl      _emit_str
    mov     w0, #'\n'
    bl      _emit_char

    // _funcname:
    mov     w0, #'_'
    bl      _emit_char
    mov     x0, x20
    mov     x1, x21
    bl      _emit_str
    LOAD_ADDR x0, _s_colon_nl
    bl      _emit_cstr

    // stp x29, x30, [sp, #-framesize]!
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_stp_x29_x30
    bl      _emit_cstr
    neg     w0, w25
    sxtw    x0, w0
    bl      _emit_sint
    LOAD_ADDR x0, _s_bracket_bang_nl
    bl      _emit_cstr

    // mov x29, sp
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_mov_x29_sp
    bl      _emit_cstr

    // blocks
    mov     w26, #0
.Lcgf_loop:
    cmp     w26, w23
    b.ge    .Lcgf_done
    add     w0, w22, w26
    bl      _codegen_block
    add     w26, w26, #1
    b       .Lcgf_loop

.Lcgf_done:
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x29, x30, [sp], #80
    ret

// =========================================================
// _codegen_block
// =========================================================
_codegen_block:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     w19, w0

    LOAD_ADDR x10, _g_block_array
    ldr     x11, [x10]
    mov     x12, #BLOCK_SIZE
    umull   x13, w19, w12
    add     x20, x11, x13

    ldr     x21, [x20]
    ldr     x22, [x20, #8]
    ldr     w23, [x20, #16]
    ldr     w24, [x20, #20]

    // .LBB_funcname_blockname:
    LOAD_ADDR x0, _s_lbb_prefix
    bl      _emit_cstr
    LOAD_ADDR x10, _g_cur_func_name
    ldr     x0, [x10]
    LOAD_ADDR x10, _g_cur_func_namelen
    ldr     x1, [x10]
    bl      _emit_str
    mov     w0, #'_'
    bl      _emit_char
    mov     x0, x21
    mov     x1, x22
    bl      _emit_str
    LOAD_ADDR x0, _s_colon_nl
    bl      _emit_cstr

    mov     w25, #0
.Lcgb_loop:
    cmp     w25, w24
    b.ge    .Lcgb_done
    add     w0, w23, w25
    bl      _codegen_instr
    add     w25, w25, #1
    b       .Lcgb_loop

.Lcgb_done:
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x29, x30, [sp], #64
    ret

// =========================================================
// _codegen_instr
// =========================================================
_codegen_instr:
    stp     x29, x30, [sp, #-80]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]

    mov     w19, w0

    LOAD_ADDR x10, _g_cur_instr_idx
    str     w19, [x10]

    LOAD_ADDR x10, _g_instr_array
    ldr     x11, [x10]
    mov     x12, #INSTR_SIZE
    umull   x13, w19, w12
    add     x20, x11, x13

    ldr     w21, [x20]          // opcode
    ldr     w22, [x20, #4]      // result_vreg
    ldr     w23, [x20, #12]     // num_operands

    cmp     w21, #OP_RET
    b.eq    .Lcgi_ret
    cmp     w21, #OP_BR
    b.eq    .Lcgi_br
    cmp     w21, #OP_BR_COND
    b.eq    .Lcgi_br_cond
    cmp     w21, #OP_CALL
    b.eq    .Lcgi_call
    cmp     w21, #OP_PHI
    b.eq    .Lcgi_phi
    cmp     w21, #OP_ARG
    b.eq    .Lcgi_arg
    cmp     w21, #OP_CMP_EQ
    b.ge    1f
    b       .Lcgi_binop
1:  cmp     w21, #OP_CMP_GE
    b.le    .Lcgi_cmp
    b       .Lcgi_binop

// --- binop ---
.Lcgi_binop:
    ldr     w0, [x20, #16]
    ldr     x1, [x20, #24]
    mov     w2, #9
    bl      _emit_load_operand

    ldr     w0, [x20, #48]
    ldr     x1, [x20, #56]
    mov     w2, #10
    bl      _emit_load_operand

    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr

    cmp     w21, #OP_ADD
    b.eq    .Lb_add
    cmp     w21, #OP_SUB
    b.eq    .Lb_sub
    cmp     w21, #OP_MUL
    b.eq    .Lb_mul
    cmp     w21, #OP_DIV
    b.eq    .Lb_div
    cmp     w21, #OP_MOD
    b.eq    .Lb_mod
    cmp     w21, #OP_AND
    b.eq    .Lb_and
    cmp     w21, #OP_OR
    b.eq    .Lb_or
    cmp     w21, #OP_XOR
    b.eq    .Lb_xor
    cmp     w21, #OP_SHL
    b.eq    .Lb_shl
    cmp     w21, #OP_SHR
    b.eq    .Lb_shr
    b       .Lcgi_done

.Lb_add: LOAD_ADDR x0, _s_add_x9_x10
    bl _emit_cstr
    b .Lcgi_store
.Lb_sub: LOAD_ADDR x0, _s_sub_x9_x10
    bl _emit_cstr
    b .Lcgi_store
.Lb_mul: LOAD_ADDR x0, _s_mul_x9_x10
    bl _emit_cstr
    b .Lcgi_store
.Lb_div: LOAD_ADDR x0, _s_sdiv_x9_x10
    bl _emit_cstr
    b .Lcgi_store
.Lb_mod: LOAD_ADDR x0, _s_sdiv_x11_x9_x10
    bl _emit_cstr
    LOAD_ADDR x0, _s_indent
    bl _emit_cstr
    LOAD_ADDR x0, _s_msub_x9
    bl _emit_cstr
    b .Lcgi_store
.Lb_and: LOAD_ADDR x0, _s_and_x9_x10
    bl _emit_cstr
    b .Lcgi_store
.Lb_or: LOAD_ADDR x0, _s_orr_x9_x10
    bl _emit_cstr
    b .Lcgi_store
.Lb_xor: LOAD_ADDR x0, _s_eor_x9_x10
    bl _emit_cstr
    b .Lcgi_store
.Lb_shl: LOAD_ADDR x0, _s_lsl_x9_x10
    bl _emit_cstr
    b .Lcgi_store
.Lb_shr: LOAD_ADDR x0, _s_asr_x9_x10
    bl _emit_cstr
    b .Lcgi_store

.Lcgi_store:
    mov     w0, w22
    bl      _emit_store_x9
    b       .Lcgi_done

// --- cmp ---
.Lcgi_cmp:
    ldr     w0, [x20, #16]
    ldr     x1, [x20, #24]
    mov     w2, #9
    bl      _emit_load_operand
    ldr     w0, [x20, #48]
    ldr     x1, [x20, #56]
    mov     w2, #10
    bl      _emit_load_operand
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_cmp_x9_x10
    bl      _emit_cstr
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_cset_x9
    bl      _emit_cstr

    cmp     w21, #OP_CMP_EQ
    b.eq    .Lc_eq
    cmp     w21, #OP_CMP_NE
    b.eq    .Lc_ne
    cmp     w21, #OP_CMP_LT
    b.eq    .Lc_lt
    cmp     w21, #OP_CMP_GT
    b.eq    .Lc_gt
    cmp     w21, #OP_CMP_LE
    b.eq    .Lc_le
    cmp     w21, #OP_CMP_GE
    b.eq    .Lc_ge
    b       .Lcgi_done

.Lc_eq: LOAD_ADDR x0, _s_eq_nl
    bl _emit_cstr
    b .Lcgi_store
.Lc_ne: LOAD_ADDR x0, _s_ne_nl
    bl _emit_cstr
    b .Lcgi_store
.Lc_lt: LOAD_ADDR x0, _s_lt_nl
    bl _emit_cstr
    b .Lcgi_store
.Lc_gt: LOAD_ADDR x0, _s_gt_nl
    bl _emit_cstr
    b .Lcgi_store
.Lc_le: LOAD_ADDR x0, _s_le_nl
    bl _emit_cstr
    b .Lcgi_store
.Lc_ge: LOAD_ADDR x0, _s_ge_nl
    bl _emit_cstr
    b .Lcgi_store

// --- ret ---
.Lcgi_ret:
    cmp     w23, #0
    b.eq    .Lcgi_ret_epi
    ldr     w0, [x20, #16]
    ldr     x1, [x20, #24]
    mov     w2, #0
    bl      _emit_load_operand
.Lcgi_ret_epi:
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_ldp_x29_x30
    bl      _emit_cstr
    LOAD_ADDR x10, _g_cur_frame_size
    ldr     w0, [x10]
    mov     x0, x0
    bl      _emit_uint
    mov     w0, #'\n'
    bl      _emit_char
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_ret_nl
    bl      _emit_cstr
    b       .Lcgi_done

// --- br ---
.Lcgi_br:
    ldr     x0, [x20, #32]
    ldr     x1, [x20, #40]
    bl      _emit_phi_moves
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_b_space
    bl      _emit_cstr
    ldr     x2, [x20, #32]
    ldr     x3, [x20, #40]
    bl      _emit_block_label
    mov     w0, #'\n'
    bl      _emit_char
    b       .Lcgi_done

// --- br_cond ---
.Lcgi_br_cond:
    // Load condition
    ldr     w0, [x20, #16]
    ldr     x1, [x20, #24]
    mov     w2, #9
    bl      _emit_load_operand

    // phi moves for TRUE (but we need to NOT clobber x9!)
    // Actually this is a problem: phi moves may emit loads that clobber x9.
    // We need to save x9 first. But we're emitting ASM text, not executing.
    // The generated code loads x9 (condition), then does phi moves (which use x9 as temp),
    // then cbnz x9. So the phi moves would clobber x9!
    //
    // FIX: emit save of condition to a temp location, emit phi moves,
    // then reload condition. Or: save x9 on stack before phi moves.
    // Let's emit: str x9, [sp, #-16]! ... ldp x9, xzr, [sp], #16

    // Save condition
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_save_x9
    bl      _emit_cstr

    // phi moves for TRUE target
    ldr     x0, [x20, #64]
    ldr     x1, [x20, #72]
    bl      _emit_phi_moves

    // Restore condition
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_restore_x9
    bl      _emit_cstr

    // cbnz x9, true_label
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_cbnz_x9
    bl      _emit_cstr
    ldr     x2, [x20, #64]
    ldr     x3, [x20, #72]
    bl      _emit_block_label
    mov     w0, #'\n'
    bl      _emit_char

    // phi moves for FALSE target
    ldr     x0, [x20, #96]
    ldr     x1, [x20, #104]
    bl      _emit_phi_moves

    // b false_label
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_b_space
    bl      _emit_cstr
    ldr     x2, [x20, #96]
    ldr     x3, [x20, #104]
    bl      _emit_block_label
    mov     w0, #'\n'
    bl      _emit_char
    b       .Lcgi_done

// --- call ---
.Lcgi_call:
    mov     w24, #1
.Lcgi_call_args:
    cmp     w24, w23
    b.ge    .Lcgi_call_bl
    mov     w10, #32
    umull   x11, w24, w10
    add     x11, x11, #16
    ldr     w0, [x20, x11]
    add     x12, x11, #8
    ldr     x1, [x20, x12]
    sub     w2, w24, #1
    bl      _emit_load_operand
    add     w24, w24, #1
    b       .Lcgi_call_args

.Lcgi_call_bl:
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_bl
    bl      _emit_cstr
    mov     w0, #'_'
    bl      _emit_char
    ldr     x0, [x20, #32]
    ldr     x1, [x20, #40]
    bl      _emit_str
    mov     w0, #'\n'
    bl      _emit_char

    cmn     w22, #1
    b.eq    .Lcgi_done
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_str_x0_fp
    bl      _emit_cstr
    lsl     w0, w22, #3
    add     x0, x0, #16
    bl      _emit_uint
    LOAD_ADDR x0, _s_bracket_nl
    bl      _emit_cstr
    b       .Lcgi_done

// --- phi ---
.Lcgi_phi:
    b       .Lcgi_done

// --- arg ---
.Lcgi_arg:
    ldr     x24, [x20, #24]
    LOAD_ADDR x0, _s_indent
    bl      _emit_cstr
    LOAD_ADDR x0, _s_str_sp
    bl      _emit_cstr
    mov     w0, #'x'
    bl      _emit_char
    mov     x0, x24
    bl      _emit_uint
    LOAD_ADDR x0, _s_comma_fp_hash
    bl      _emit_cstr
    lsl     w0, w22, #3
    add     x0, x0, #16
    bl      _emit_uint
    LOAD_ADDR x0, _s_bracket_nl
    bl      _emit_cstr
    b       .Lcgi_done

.Lcgi_done:
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x29, x30, [sp], #80
    ret

// =========================================================
// _emit_phi_moves
// =========================================================
_emit_phi_moves:
    stp     x29, x30, [sp, #-96]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]

    mov     x19, x0             // target name_ptr
    mov     x20, x1             // target name_len

    LOAD_ADDR x10, _g_cur_instr_idx
    ldr     w21, [x10]
    LOAD_ADDR x10, _g_func_first_block
    ldr     w22, [x10]
    LOAD_ADDR x10, _g_func_num_blocks
    ldr     w23, [x10]
    LOAD_ADDR x10, _g_block_array
    ldr     x24, [x10]
    LOAD_ADDR x10, _g_instr_array
    ldr     x25, [x10]

    // Find source block
    mov     w26, #0
    mov     x27, #0
    mov     x28, #0

.Lepm_fsrc:
    cmp     w26, w23
    b.ge    .Lepm_ftgt
    add     w10, w22, w26
    mov     x12, #BLOCK_SIZE
    umull   x13, w10, w12
    add     x14, x24, x13
    ldr     w15, [x14, #16]
    ldr     w16, [x14, #20]
    add     w17, w15, w16
    cmp     w21, w15
    b.lt    .Lepm_fsrc_n
    cmp     w21, w17
    b.ge    .Lepm_fsrc_n
    ldr     x27, [x14]
    ldr     x28, [x14, #8]
    b       .Lepm_ftgt
.Lepm_fsrc_n:
    add     w26, w26, #1
    b       .Lepm_fsrc

.Lepm_ftgt:
    cbz     x27, .Lepm_done
    mov     w26, #0
.Lepm_ftgt_l:
    cmp     w26, w23
    b.ge    .Lepm_done
    add     w10, w22, w26
    mov     x12, #BLOCK_SIZE
    umull   x13, w10, w12
    add     x14, x24, x13
    ldr     x15, [x14]
    ldr     x16, [x14, #8]
    cmp     x16, x20
    b.ne    .Lepm_ftgt_n
    mov     x17, #0
.Lepm_ct:
    cmp     x17, x20
    b.ge    .Lepm_found
    ldrb    w0, [x19, x17]
    ldrb    w1, [x15, x17]
    cmp     w0, w1
    b.ne    .Lepm_ftgt_n
    add     x17, x17, #1
    b       .Lepm_ct
.Lepm_ftgt_n:
    add     w26, w26, #1
    b       .Lepm_ftgt_l

.Lepm_found:
    ldr     w15, [x14, #16]
    ldr     w16, [x14, #20]
    mov     w17, #0

.Lepm_ps:
    cmp     w17, w16
    b.ge    .Lepm_done
    add     w10, w15, w17
    mov     x12, #INSTR_SIZE
    umull   x13, w10, w12
    add     x14, x25, x13
    ldr     w10, [x14]
    cmp     w10, #OP_PHI
    b.ne    .Lepm_pn

    ldr     w0, [x14, #144]     // phi_count
    ldr     w1, [x14, #4]       // result_vreg
    mov     w2, #0

.Lepm_es:
    cmp     w2, w0
    b.ge    .Lepm_pn
    mov     w10, #32
    umull   x11, w2, w10
    add     x11, x11, #152
    add     x12, x11, #16
    ldr     x3, [x14, x12]
    add     x12, x11, #24
    ldr     x4, [x14, x12]
    cmp     x4, x28
    b.ne    .Lepm_en
    mov     x5, #0
.Lepm_cs:
    cmp     x5, x28
    b.ge    .Lepm_em
    ldrb    w6, [x27, x5]
    ldrb    w7, [x3, x5]
    cmp     w6, w7
    b.ne    .Lepm_en
    add     x5, x5, #1
    b       .Lepm_cs

.Lepm_em:
    ldr     w3, [x14, x11]
    add     x12, x11, #8
    ldr     x4, [x14, x12]
    stp     x14, x0, [sp, #-48]!
    str     w1, [sp, #16]
    str     w2, [sp, #20]
    str     w17, [sp, #24]
    str     w15, [sp, #28]
    str     w16, [sp, #32]
    mov     w0, w3
    mov     x1, x4
    mov     w2, #9
    bl      _emit_load_operand
    ldr     w0, [sp, #16]
    bl      _emit_store_x9
    ldr     w17, [sp, #24]
    ldr     w15, [sp, #28]
    ldr     w16, [sp, #32]
    ldr     w2, [sp, #20]
    ldp     x14, x0, [sp], #48
    ldr     w1, [x14, #4]

.Lepm_en:
    add     w2, w2, #1
    b       .Lepm_es

.Lepm_pn:
    add     w17, w17, #1
    b       .Lepm_ps

.Lepm_done:
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x23, x24, [sp, #48]
    ldp     x25, x26, [sp, #64]
    ldp     x27, x28, [sp, #80]
    ldp     x29, x30, [sp], #96
    ret

// =========================================================
// Data
// =========================================================
.data
.align 3

_s_minus:           .asciz "-"
_s_indent:          .asciz "    "
_s_dot_text:        .asciz ".text\n.align 4\n"
_s_dot_global:      .asciz ".global "
_s_colon_nl:        .asciz ":\n"
_s_stp_x29_x30:    .asciz "stp x29, x30, [sp, #"
_s_bracket_bang_nl: .asciz "]!\n"
_s_mov_x29_sp:      .asciz "mov x29, sp\n"
_s_ldp_x29_x30:    .asciz "ldp x29, x30, [sp], #"
_s_ret_nl:          .asciz "ret\n"
_s_lbb_prefix:      .asciz ".LBB_"
_s_add_x9_x10:     .asciz "add x9, x9, x10\n"
_s_sub_x9_x10:     .asciz "sub x9, x9, x10\n"
_s_mul_x9_x10:     .asciz "mul x9, x9, x10\n"
_s_sdiv_x9_x10:    .asciz "sdiv x9, x9, x10\n"
_s_sdiv_x11_x9_x10:.asciz "sdiv x11, x9, x10\n"
_s_msub_x9:         .asciz "msub x9, x11, x10, x9\n"
_s_and_x9_x10:     .asciz "and x9, x9, x10\n"
_s_orr_x9_x10:     .asciz "orr x9, x9, x10\n"
_s_eor_x9_x10:     .asciz "eor x9, x9, x10\n"
_s_lsl_x9_x10:     .asciz "lsl x9, x9, x10\n"
_s_asr_x9_x10:     .asciz "asr x9, x9, x10\n"
_s_cmp_x9_x10:     .asciz "cmp x9, x10\n"
_s_cset_x9:         .asciz "cset x9, "
_s_eq_nl:           .asciz "eq\n"
_s_ne_nl:           .asciz "ne\n"
_s_lt_nl:           .asciz "lt\n"
_s_gt_nl:           .asciz "gt\n"
_s_le_nl:           .asciz "le\n"
_s_ge_nl:           .asciz "ge\n"
_s_str_x9_fp:       .asciz "str x9, [x29, #"
_s_str_x0_fp:       .asciz "str x0, [x29, #"
_s_bracket_nl:      .asciz "]\n"
_s_b_space:         .asciz "b "
_s_bl:              .asciz "bl "
_s_cbnz_x9:        .asciz "cbnz x9, "
_s_mov:             .asciz "mov "
_s_movz:            .asciz "movz "
_s_movk:            .asciz "movk "
_s_ldr:             .asciz "ldr "
_s_str_sp:          .asciz "str "
_s_comma_hash:      .asciz ", #"
_s_comma_fp_hash:   .asciz ", [x29, #"
_s_lsl16:           .asciz ", lsl #16\n"
_s_lsl32:           .asciz ", lsl #32\n"
_s_lsl48:           .asciz ", lsl #48\n"
_s_save_x9:         .asciz "str x9, [sp, #-16]!\n"
_s_restore_x9:      .asciz "ldr x9, [sp], #16\n"

.align 3
_g_outbuf:           .quad 0
_g_outpos:           .quad 0
_g_block_array:      .quad 0
_g_instr_array:      .quad 0
_g_cur_func_name:    .quad 0
_g_cur_func_namelen: .quad 0
_g_cur_num_vregs:    .long 0
    .long 0
_g_cur_frame_size:   .long 0
    .long 0
_g_func_first_block: .long 0
    .long 0
_g_func_num_blocks:  .long 0
    .long 0
_g_cur_instr_idx:    .long 0
    .long 0
