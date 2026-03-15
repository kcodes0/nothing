// encoder.s — ARM64 instruction encoder for the bootstrapped assembler
// AArch64 macOS (Apple AAPCS64)
//
// Each function takes instruction operands and returns a 32-bit encoded
// instruction word in w0. All functions are pure leaf functions — no calls,
// no stack frame setup, just shifts and ORs.
//
// Calling convention: x0-x7 args, w0 return, x18 reserved (never touched)

.section __TEXT,__text

// =============================================================================
// _enc_add_imm — Encode ADD/SUB immediate
//   Encoding: sf|op|S|100010|sh|imm12|Rn|Rd
//   Fixed bits [28:24] = 10001 => base = 0x11000000
//   x0=sf(0/1), x1=op(0=add,1=sub), x2=setflags(S), x3=Rd, x4=Rn, x5=imm12
//   Returns: w0 = encoded instruction
// =============================================================================
.globl _enc_add_imm
.p2align 2
_enc_add_imm:
    mov     w8, #0x11000000         // base: bits [28:24] = 10001
    orr     w8, w8, w3              // Rd [4:0]
    orr     w8, w8, w4, lsl #5     // Rn [9:5]
    orr     w8, w8, w5, lsl #10    // imm12 [21:10]
    // shift=0 at [23:22] — already zero
    orr     w8, w8, w2, lsl #29    // S [29]
    orr     w8, w8, w1, lsl #30    // op [30]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_add_reg — Encode ADD/SUB shifted register
//   Encoding: sf|op|S|01011|shift|0|Rm|imm6|Rn|Rd
//   Fixed bits [28:24] = 01011 => 0x0B000000
//   x0=sf, x1=op, x2=setflags, x3=Rd, x4=Rn, x5=Rm,
//   x6=shift_type(0=LSL,1=LSR,2=ASR), x7=shift_amt(imm6)
//   Returns: w0
// =============================================================================
.globl _enc_add_reg
.p2align 2
_enc_add_reg:
    mov     w8, #0x0B000000         // base: bits [28:24] = 01011
    orr     w8, w8, w3              // Rd [4:0]
    orr     w8, w8, w4, lsl #5     // Rn [9:5]
    orr     w8, w8, w7, lsl #10    // imm6 [15:10]
    orr     w8, w8, w5, lsl #16    // Rm [20:16]
    // bit [21] = 0 — already zero
    orr     w8, w8, w6, lsl #22    // shift [23:22]
    orr     w8, w8, w2, lsl #29    // S [29]
    orr     w8, w8, w1, lsl #30    // op [30]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_logic_reg — Encode AND/ORR/EOR/ANDS shifted register
//   Encoding: sf|opc|01010|shift|N|Rm|imm6|Rn|Rd
//   Fixed bits [28:24] = 01010 => 0x0A000000
//   x0=sf, x1=opc(2 bits), x2=N(invert), x3=Rd, x4=Rn, x5=Rm,
//   x6=shift_type, x7=shift_amt(imm6)
//   AND: opc=00,N=0  ORR: opc=01,N=0  EOR: opc=10,N=0  ANDS: opc=11,N=0
//   ORN/MVN: opc=01,N=1
//   Returns: w0
// =============================================================================
.globl _enc_logic_reg
.p2align 2
_enc_logic_reg:
    mov     w8, #0x0A000000         // base: bits [28:24] = 01010
    orr     w8, w8, w3              // Rd [4:0]
    orr     w8, w8, w4, lsl #5     // Rn [9:5]
    orr     w8, w8, w7, lsl #10    // imm6 [15:10]
    orr     w8, w8, w5, lsl #16    // Rm [20:16]
    orr     w8, w8, w2, lsl #21    // N [21]
    orr     w8, w8, w6, lsl #22    // shift [23:22]
    orr     w8, w8, w1, lsl #29    // opc [30:29]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_mul — Encode MUL (alias for MADD with Ra=XZR=31)
//   Encoding: sf|00|11011|000|Rm|0|Ra|Rn|Rd
//   Fixed bits [28:24] = 11011, [23:21] = 000, [15] = 0 (o0 for MADD)
//   Base = 0x1B000000
//   Ra = 31 (XZR) for MUL alias
//   x0=sf, x1=Rd, x2=Rn, x3=Rm
//   Returns: w0
// =============================================================================
.globl _enc_mul
.p2align 2
_enc_mul:
    mov     w8, #0x1B000000         // base: 00011011000.....
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, #(31 << 10)    // Ra [14:10] = 11111 (XZR)
    // bit [15] = 0 (o0=0 for MADD) — already zero
    orr     w8, w8, w3, lsl #16    // Rm [20:16]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_madd — Encode MADD
//   Encoding: sf|00|11011|000|Rm|0|Ra|Rn|Rd
//   Base = 0x1B000000, bit [15] = 0 (o0=0)
//   x0=sf, x1=Rd, x2=Rn, x3=Rm, x4=Ra
//   Returns: w0
// =============================================================================
.globl _enc_madd
.p2align 2
_enc_madd:
    mov     w8, #0x1B000000         // base
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, w4, lsl #10    // Ra [14:10]
    // bit [15] = 0 — already zero
    orr     w8, w8, w3, lsl #16    // Rm [20:16]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_msub — Encode MSUB
//   Encoding: sf|00|11011|000|Rm|1|Ra|Rn|Rd
//   Base = 0x1B000000, bit [15] = 1 (o0=1)
//   x0=sf, x1=Rd, x2=Rn, x3=Rm, x4=Ra
//   Returns: w0
// =============================================================================
.globl _enc_msub
.p2align 2
_enc_msub:
    mov     w8, #0x1B000000         // base
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, w4, lsl #10    // Ra [14:10]
    orr     w8, w8, #(1 << 15)     // o0 [15] = 1 (MSUB)
    orr     w8, w8, w3, lsl #16    // Rm [20:16]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_udiv — Encode UDIV
//   Encoding: sf|00|11010110|Rm|00001|0|Rn|Rd
//   Fixed bits: [28:21] = 11010110 => base includes sf=0 placeholder
//   Full base for bits [30:10]: 00|11010110|Rm|000010|Rn|Rd
//   Base = 0x1AC00800  (00011010110|00000|000010|00000|00000)
//   Wait, let me recalculate:
//   [30:29] = 00, [28:21] = 11010110 => bits 28..21
//   bit 28 = 1, 27 = 1, 26 = 0, 25 = 1, 24 = 0, 23 = 1, 22 = 1, 21 = 0
//   = 0x1AC00000 for bits [30:21]
//   [15:11] = 00001, [10] = 0 for UDIV => 0x00000800
//   Base = 0x1AC00800
//   x0=sf, x1=Rd, x2=Rn, x3=Rm
//   Returns: w0
// =============================================================================
.globl _enc_udiv
.p2align 2
_enc_udiv:
    // sf|0|0|11010110|Rm|000010|Rn|Rd
    // bits [30:29] = 00
    // bits [28:21] = 11010110
    // bits [15:11] = 00001, bit [10] = 0 => UDIV
    mov     w8, #0x0800             // bits [15:10] = 000010
    movk    w8, #0x1AC0, lsl #16    // bits [30:21] = 0011010110
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, w3, lsl #16    // Rm [20:16]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_sdiv — Encode SDIV
//   Same as UDIV but bit [10] = 1
//   Base = 0x1AC00C00
//   x0=sf, x1=Rd, x2=Rn, x3=Rm
//   Returns: w0
// =============================================================================
.globl _enc_sdiv
.p2align 2
_enc_sdiv:
    // sf|0|0|11010110|Rm|000011|Rn|Rd
    // bits [15:10] = 000011 => 0x0C00
    mov     w8, #0x0C00             // bits [15:10] = 000011
    movk    w8, #0x1AC0, lsl #16    // bits [30:21] = 0011010110
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, w3, lsl #16    // Rm [20:16]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_movz — Encode MOVZ (move wide with zero)
//   Encoding: sf|10|100101|hw|imm16|Rd
//   opc=10: base = sf|10|100101|hw|imm16|Rd
//   Fixed bits [28:23] = 100101 => with opc=10 at [30:29]:
//   bits [30:23] = 10100101 => 0x52800000
//   x0=sf, x1=Rd, x2=imm16, x3=hw(0-3)
//   Returns: w0
// =============================================================================
.globl _enc_movz
.p2align 2
_enc_movz:
    // sf|10|100101|hw|imm16|Rd
    // bits [30:29] = 10 (opc for MOVZ)
    // bits [28:23] = 100101
    // Combined [30:23] = 10100101
    // Base = 0x52800000
    mov     w8, #0x52800000
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // imm16 [20:5]
    orr     w8, w8, w3, lsl #21    // hw [22:21]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_movk — Encode MOVK (move wide with keep)
//   Encoding: sf|11|100101|hw|imm16|Rd
//   opc=11: base = 0x72800000
//   x0=sf, x1=Rd, x2=imm16, x3=hw(0-3)
//   Returns: w0
// =============================================================================
.globl _enc_movk
.p2align 2
_enc_movk:
    mov     w8, #0x72800000
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // imm16 [20:5]
    orr     w8, w8, w3, lsl #21    // hw [22:21]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_movn — Encode MOVN (move wide with NOT)
//   Encoding: sf|00|100101|hw|imm16|Rd
//   opc=00: base = 0x12800000
//   x0=sf, x1=Rd, x2=imm16, x3=hw(0-3)
//   Returns: w0
// =============================================================================
.globl _enc_movn
.p2align 2
_enc_movn:
    mov     w8, #0x12800000
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // imm16 [20:5]
    orr     w8, w8, w3, lsl #21    // hw [22:21]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_b — Encode unconditional branch B
//   Encoding: 0|00101|imm26
//   Base = 0x14000000 (op=0 for B)
//   x0=offset_in_bytes (signed, PC-relative, divided by 4 to get imm26)
//   Returns: w0
// =============================================================================
.globl _enc_b
.p2align 2
_enc_b:
    // Convert byte offset to instruction offset (divide by 4)
    asr     x8, x0, #2             // imm26 = offset >> 2 (signed)
    and     w8, w8, #0x03FFFFFF     // mask to 26 bits
    mov     w9, #0x14000000         // base opcode for B
    orr     w8, w8, w9
    mov     w0, w8
    ret

// =============================================================================
// _enc_bl — Encode branch with link BL
//   Encoding: 1|00101|imm26
//   Base = 0x94000000 (op=1 for BL)
//   x0=offset_in_bytes (signed, PC-relative)
//   Returns: w0
// =============================================================================
.globl _enc_bl
.p2align 2
_enc_bl:
    asr     x8, x0, #2             // imm26 = offset >> 2 (signed)
    and     w8, w8, #0x03FFFFFF     // mask to 26 bits
    mov     w9, #0x94000000
    orr     w8, w8, w9              // OR in base opcode for BL
    mov     w0, w8
    ret

// =============================================================================
// _enc_b_cond — Encode conditional branch B.cond
//   Encoding: 0101010|0|imm19|0|cond
//   Base = 0x54000000
//   x0=cond_code(4 bits), x1=offset_in_bytes
//   Returns: w0
// =============================================================================
.globl _enc_b_cond
.p2align 2
_enc_b_cond:
    mov     w8, #0x54000000         // base: 01010100 ...
    orr     w8, w8, w0              // cond [3:0]
    // bit [4] = 0 — already zero
    asr     x9, x1, #2             // imm19 = offset >> 2 (signed)
    and     w9, w9, #0x7FFFF        // mask to 19 bits
    orr     w8, w8, w9, lsl #5     // imm19 [23:5]
    mov     w0, w8
    ret

// =============================================================================
// _enc_cbz — Encode CBZ (compare and branch if zero)
//   Encoding: sf|011010|0|imm19|Rt
//   Base = 0x34000000 (op=0 for CBZ)
//   x0=sf, x1=Rt, x2=offset_in_bytes
//   Returns: w0
// =============================================================================
.globl _enc_cbz
.p2align 2
_enc_cbz:
    mov     w8, #0x34000000         // base: 0|0110100|...
    orr     w8, w8, w1              // Rt [4:0]
    asr     x9, x2, #2             // imm19 = offset >> 2 (signed)
    and     w9, w9, #0x7FFFF        // mask to 19 bits
    orr     w8, w8, w9, lsl #5     // imm19 [23:5]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_cbnz — Encode CBNZ (compare and branch if not zero)
//   Encoding: sf|011010|1|imm19|Rt
//   Base = 0x35000000 (op=1 for CBNZ)
//   x0=sf, x1=Rt, x2=offset_in_bytes
//   Returns: w0
// =============================================================================
.globl _enc_cbnz
.p2align 2
_enc_cbnz:
    mov     w8, #0x35000000
    orr     w8, w8, w1              // Rt [4:0]
    asr     x9, x2, #2             // imm19 = offset >> 2 (signed)
    and     w9, w9, #0x7FFFF        // mask to 19 bits
    orr     w8, w8, w9, lsl #5     // imm19 [23:5]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_ret — Encode RET
//   Encoding: 1101011001011111000000|Rn|00000
//   = 0xD65F0000 | (Rn << 5)
//   x0=Rn (typically 30 for x30)
//   Returns: w0
// =============================================================================
.globl _enc_ret
.p2align 2
_enc_ret:
    mov     w8, #0x0000
    movk    w8, #0xD65F, lsl #16    // 0xD65F0000
    orr     w8, w8, w0, lsl #5     // Rn [9:5]
    mov     w0, w8
    ret

// =============================================================================
// _enc_ldr_uoff — Encode LDR unsigned offset
//   Encoding: size|111|V|01|opc|imm12|Rn|Rt
//   V=0 (not SIMD), opc depends on load vs store
//   For LDR: opc=01
//   size: 00=byte, 01=half, 10=word, 11=dword
//   imm12 is scaled by access size
//   x0=size(0=byte,1=half,2=word,3=dword), x1=Rt, x2=Rn, x3=offset_bytes
//   Returns: w0
//
//   Base pattern: size|111|0|01|01|imm12|Rn|Rt
//   For size=3(64-bit): 11|111|0|01|01|... = 0xF9400000
//   For size=2(32-bit): 10|111|0|01|01|... = 0xB9400000
//   For size=1(16-bit): 01|111|0|01|01|... = 0x79400000
//   For size=0(8-bit):  00|111|0|01|01|... = 0x39400000
//   Generic: base = 0x39400000 | (size << 30)
// =============================================================================
.globl _enc_ldr_uoff
.p2align 2
_enc_ldr_uoff:
    // Scale offset by access size to get imm12
    // size 0 => shift 0, size 1 => shift 1, size 2 => shift 2, size 3 => shift 3
    lsr     w9, w3, w0              // imm12 = offset_bytes >> size
    mov     w8, #0x39400000         // base for size=0, LDR, V=0
    orr     w8, w8, w1              // Rt [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, w9, lsl #10    // imm12 [21:10]
    orr     w8, w8, w0, lsl #30    // size [31:30]
    mov     w0, w8
    ret

// =============================================================================
// _enc_str_uoff — Encode STR unsigned offset
//   Same encoding but opc=00 (store)
//   Base: size|111|0|01|00|imm12|Rn|Rt
//   For size=0: 0x39000000
//   x0=size, x1=Rt, x2=Rn, x3=offset_bytes
//   Returns: w0
// =============================================================================
.globl _enc_str_uoff
.p2align 2
_enc_str_uoff:
    lsr     w9, w3, w0              // imm12 = offset_bytes >> size
    mov     w8, #0x39000000         // base for size=0, STR, V=0
    orr     w8, w8, w1              // Rt [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, w9, lsl #10    // imm12 [21:10]
    orr     w8, w8, w0, lsl #30    // size [31:30]
    mov     w0, w8
    ret

// =============================================================================
// _enc_ldr_pre — Encode LDR with pre-index
//   Encoding: size|111|V|00|opc|0|simm9|11|Rn|Rt
//   V=0, opc=01 (load)
//   idx=11 for pre-index
//   Base: 0x38400C00 for size=0 (byte)
//     size|111|0|00|01|0|simm9|11|Rn|Rt
//     bits [29:27] = 111, [26] V=0, [25:24] = 00, [23:22] opc=01
//     bit [21] = 0, [11:10] = 11 (pre-index)
//   x0=size, x1=Rt, x2=Rn, x3=simm9
//   Returns: w0
// =============================================================================
.globl _enc_ldr_pre
.p2align 2
_enc_ldr_pre:
    mov     w8, #0x0C00             // bits [11:10] = 11 (pre-index)
    movk    w8, #0x3840, lsl #16    // 00|111|0|00|01|0 => 0x38400000
    orr     w8, w8, w1              // Rt [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    and     w9, w3, #0x1FF          // mask simm9 to 9 bits
    orr     w8, w8, w9, lsl #12    // simm9 [20:12]
    orr     w8, w8, w0, lsl #30    // size [31:30]
    mov     w0, w8
    ret

// =============================================================================
// _enc_ldr_post — Encode LDR with post-index
//   Same as pre but idx=01 at bits [11:10]
//   Base: 0x38400400 for size=0
//   x0=size, x1=Rt, x2=Rn, x3=simm9
//   Returns: w0
// =============================================================================
.globl _enc_ldr_post
.p2align 2
_enc_ldr_post:
    mov     w8, #0x0400             // bits [11:10] = 01 (post-index)
    movk    w8, #0x3840, lsl #16    // 0x38400000
    orr     w8, w8, w1              // Rt [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    and     w9, w3, #0x1FF          // mask simm9 to 9 bits
    orr     w8, w8, w9, lsl #12    // simm9 [20:12]
    orr     w8, w8, w0, lsl #30    // size [31:30]
    mov     w0, w8
    ret

// =============================================================================
// _enc_str_pre — Encode STR with pre-index
//   Same structure but opc=00 (store)
//   Base: 0x38000C00 for size=0
//   x0=size, x1=Rt, x2=Rn, x3=simm9
//   Returns: w0
// =============================================================================
.globl _enc_str_pre
.p2align 2
_enc_str_pre:
    mov     w8, #0x0C00             // bits [11:10] = 11 (pre-index)
    movk    w8, #0x3800, lsl #16    // 0x38000000 (opc=00 for store)
    orr     w8, w8, w1              // Rt [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    and     w9, w3, #0x1FF          // mask simm9 to 9 bits
    orr     w8, w8, w9, lsl #12    // simm9 [20:12]
    orr     w8, w8, w0, lsl #30    // size [31:30]
    mov     w0, w8
    ret

// =============================================================================
// _enc_str_post — Encode STR with post-index
//   Base: 0x38000400 for size=0
//   x0=size, x1=Rt, x2=Rn, x3=simm9
//   Returns: w0
// =============================================================================
.globl _enc_str_post
.p2align 2
_enc_str_post:
    mov     w8, #0x0400             // bits [11:10] = 01 (post-index)
    movk    w8, #0x3800, lsl #16    // 0x38000000
    orr     w8, w8, w1              // Rt [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    and     w9, w3, #0x1FF          // mask simm9 to 9 bits
    orr     w8, w8, w9, lsl #12    // simm9 [20:12]
    orr     w8, w8, w0, lsl #30    // size [31:30]
    mov     w0, w8
    ret

// =============================================================================
// _enc_ldp — Encode LDP (load pair)
//   Encoding: opc|101|V|type|L|imm7|Rt2|Rn|Rt
//   For 64-bit (sf=1): opc=10, V=0, L=1 (load)
//   For 32-bit (sf=0): opc=00, V=0, L=1
//   type: 010=signed-offset, 011=pre-index, 001=post-index
//   imm7 is scaled by 8 for 64-bit, 4 for 32-bit (signed)
//
//   x0=sf(0=32bit,1=64bit), x1=Rt, x2=Rt2, x3=Rn,
//   x4=offset_bytes(signed), x5=type(0=signed_offset,1=pre,2=post)
//   Returns: w0
//
//   Build base:
//   For sf=1: opc=10 => bit[31:30] = 10
//   For sf=0: opc=00 => bit[31:30] = 00
//   bits [29:27] = 101, bit [26] V=0
//   type mapping: 0->010, 1->011, 2->001
//   L=1 for load => bit [22] = 1
// =============================================================================
.globl _enc_ldp
.p2align 2
_enc_ldp:
    // Start with bits [29:27] = 101, V=0 => 0x28000000 + L bit
    // bit [22] = L = 1 for load => 0x00400000
    mov     w8, #0x28400000         // bits [29:26] = 1010, bit [22] = 1

    // Encode type into bits [25:23]
    // type=0 (signed offset) => bits [25:23] = 010 => |= 0x02 << 23
    // type=1 (pre-index)     => bits [25:23] = 011 => |= 0x03 << 23
    // type=2 (post-index)    => bits [25:23] = 001 => |= 0x01 << 23
    // We'll use a lookup: add 2, but type=2 wraps to 1? No, explicit mapping:
    // Map: 0->2, 1->3, 2->1
    cmp     w5, #1
    b.eq    1f
    cmp     w5, #2
    b.eq    2f
    // type=0: signed offset => 010
    mov     w9, #2
    b       3f
1:  // type=1: pre-index => 011
    mov     w9, #3
    b       3f
2:  // type=2: post-index => 001
    mov     w9, #1
3:
    orr     w8, w8, w9, lsl #23    // type [25:23]

    orr     w8, w8, w1              // Rt [4:0]
    orr     w8, w8, w3, lsl #5     // Rn [9:5]
    orr     w8, w8, w2, lsl #10    // Rt2 [14:10]

    // Scale offset: for sf=1 (64-bit) divide by 8, for sf=0 (32-bit) divide by 4
    // sf=1: shift right 3; sf=0: shift right 2
    add     w10, w0, #2            // shift amount: sf+2 (3 for 64-bit, 2 for 32-bit)
    asr     w9, w4, w10            // imm7 = offset >> (sf+2)
    and     w9, w9, #0x7F          // mask to 7 bits
    orr     w8, w8, w9, lsl #15    // imm7 [21:15]

    // opc: sf=1 => opc=10 (bit 31=1, bit 30=0)
    //       sf=0 => opc=00 (bit 31=0, bit 30=0)
    // So just set bit 31 = sf
    orr     w8, w8, w0, lsl #31    // opc high bit [31] = sf

    mov     w0, w8
    ret

// =============================================================================
// _enc_stp — Encode STP (store pair)
//   Same as LDP but L=0 (store)
//   x0=sf, x1=Rt, x2=Rt2, x3=Rn, x4=offset_bytes, x5=type
//   Returns: w0
// =============================================================================
.globl _enc_stp
.p2align 2
_enc_stp:
    // bits [29:27] = 101, V=0, L=0 => 0x28000000
    mov     w8, #0x28000000         // base without L bit

    // Encode type [25:23] — same mapping as LDP
    cmp     w5, #1
    b.eq    1f
    cmp     w5, #2
    b.eq    2f
    // type=0: signed offset => 010
    mov     w9, #2
    b       3f
1:  // type=1: pre-index => 011
    mov     w9, #3
    b       3f
2:  // type=2: post-index => 001
    mov     w9, #1
3:
    orr     w8, w8, w9, lsl #23    // type [25:23]

    orr     w8, w8, w1              // Rt [4:0]
    orr     w8, w8, w3, lsl #5     // Rn [9:5]
    orr     w8, w8, w2, lsl #10    // Rt2 [14:10]

    // Scale offset
    add     w10, w0, #2            // shift amount: sf+2
    asr     w9, w4, w10
    and     w9, w9, #0x7F          // mask to 7 bits
    orr     w8, w8, w9, lsl #15    // imm7 [21:15]

    // opc high bit = sf
    orr     w8, w8, w0, lsl #31    // [31] = sf

    mov     w0, w8
    ret

// =============================================================================
// _enc_adr — Encode ADR (PC-relative address)
//   Encoding: 0|immlo|10000|immhi|Rd
//   bit [31] = 0 (ADR, not ADRP)
//   immlo = offset[1:0] at bits [30:29]
//   immhi = offset[20:2] at bits [23:5]
//   Base = 0x10000000
//   x0=Rd, x1=offset_bytes (signed)
//   Returns: w0
// =============================================================================
.globl _enc_adr
.p2align 2
_enc_adr:
    mov     w8, #0x10000000         // base: bit [28] = 1 (ADR marker)
    orr     w8, w8, w0              // Rd [4:0]
    // immlo = offset[1:0] => bits [30:29]
    and     w9, w1, #0x3            // extract low 2 bits
    orr     w8, w8, w9, lsl #29    // immlo [30:29]
    // immhi = offset[20:2] => bits [23:5]
    asr     w9, w1, #2             // offset >> 2
    and     w9, w9, #0x7FFFF        // mask to 19 bits
    orr     w8, w8, w9, lsl #5     // immhi [23:5]
    mov     w0, w8
    ret

// =============================================================================
// _enc_adrp — Encode ADRP (PC-relative page address)
//   Encoding: 1|immlo|10000|immhi|Rd
//   bit [31] = 1 (ADRP)
//   immlo = offset[13:12] at bits [30:29]
//   immhi = offset[32:14] at bits [23:5]
//   offset is page-granular (already divided by 4096)
//   x0=Rd, x1=offset_bytes (page-relative, will be divided by 4096)
//   Returns: w0
// =============================================================================
.globl _enc_adrp
.p2align 2
_enc_adrp:
    mov     w8, #0x10000000         // base: bit [28] = 1
    orr     w8, w8, #0x80000000     // bit [31] = 1 (ADRP)
    orr     w8, w8, w0              // Rd [4:0]
    // Divide offset by 4096 (page size) to get page offset
    asr     x9, x1, #12            // page_offset = offset >> 12
    // immlo = page_offset[1:0] => bits [30:29]
    and     w10, w9, #0x3
    orr     w8, w8, w10, lsl #29   // immlo [30:29]
    // immhi = page_offset[20:2] => bits [23:5]
    asr     w10, w9, #2
    and     w10, w10, #0x7FFFF      // mask to 19 bits
    orr     w8, w8, w10, lsl #5    // immhi [23:5]
    mov     w0, w8
    ret

// =============================================================================
// _enc_svc — Encode SVC (supervisor call)
//   Encoding: 11010100|000|imm16|000|01
//   = 0xD4000001 | (imm16 << 5)
//   x0=imm16
//   Returns: w0
// =============================================================================
.globl _enc_svc
.p2align 2
_enc_svc:
    mov     w8, #0x0001
    movk    w8, #0xD400, lsl #16    // 0xD4000001
    orr     w8, w8, w0, lsl #5     // imm16 [20:5]
    mov     w0, w8
    ret

// =============================================================================
// _enc_nop — Encode NOP
//   Encoding: 0xD503201F
//   No args
//   Returns: w0 = 0xD503201F
// =============================================================================
.globl _enc_nop
.p2align 2
_enc_nop:
    mov     w0, #0x201F
    movk    w0, #0xD503, lsl #16
    ret

// =============================================================================
// _enc_cset — Encode CSET (conditional set)
//   CSET is an alias for CSINC Rd, XZR, XZR, invert(cond)
//   CSINC encoding: sf|0|0|11010100|Rm|cond|0|1|Rn|Rd
//   For CSET: Rm=31(XZR), Rn=31(XZR), cond=inverted condition
//   Base = 0x1A800400  (00|11010100|Rm|cond|01|Rn|Rd)
//     bits [30:29] = 00, [28:21] = 11010100
//     bit [11] = 0, bit [10] = 1 => 0x00000400
//   x0=sf, x1=Rd, x2=cond_code (will be inverted: XOR bit 0)
//   Returns: w0
// =============================================================================
.globl _enc_cset
.p2align 2
_enc_cset:
    // CSINC Rd, XZR, XZR, invert(cond)
    // Invert condition: flip bit 0 (except for AL/NV)
    eor     w9, w2, #1              // inverted condition

    mov     w8, #0x0400             // bit [10] = 1
    movk    w8, #0x1A80, lsl #16    // 0x1A800000 + 0x400
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, #(31 << 5)     // Rn [9:5] = XZR (31)
    orr     w8, w8, w9, lsl #12    // cond [15:12]
    orr     w8, w8, #(31 << 16)    // Rm [20:16] = XZR (31)
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_csel — Encode CSEL (conditional select)
//   Encoding: sf|0|0|11010100|Rm|cond|0|0|Rn|Rd
//   Base = 0x1A800000
//   x0=sf, x1=Rd, x2=Rn, x3=Rm, x4=cond_code
//   Returns: w0
// =============================================================================
.globl _enc_csel
.p2align 2
_enc_csel:
    mov     w8, #0x1A800000
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, w4, lsl #12    // cond [15:12]
    // bits [11:10] = 00 — already zero
    orr     w8, w8, w3, lsl #16    // Rm [20:16]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_ubfm — Encode UBFM (unsigned bitfield move)
//   Encoding: sf|10|100110|N|immr|imms|Rn|Rd
//   N = sf for 64-bit
//   Base = 0x53000000 (sf=0) or 0xD3400000 (sf=1)
//   Actually: bits [30:29] = 10, bits [28:23] = 100110
//   Combined [30:23] = 10100110
//   With sf=0: 0|10|100110|0|... = 0x53000000
//   x0=sf, x1=Rd, x2=Rn, x3=immr, x4=imms
//   Returns: w0
// =============================================================================
.globl _enc_ubfm
.p2align 2
_enc_ubfm:
    mov     w8, #0x53000000         // base: 0|10|100110|0|...
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, w4, lsl #10    // imms [15:10]
    orr     w8, w8, w3, lsl #16    // immr [21:16]
    // N [22] = sf (for 64-bit, N must be 1)
    orr     w8, w8, w0, lsl #22    // N [22]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret

// =============================================================================
// _enc_sbfm — Encode SBFM (signed bitfield move)
//   Encoding: sf|00|100110|N|immr|imms|Rn|Rd
//   Base = 0x13000000 (sf=0)
//   x0=sf, x1=Rd, x2=Rn, x3=immr, x4=imms
//   Returns: w0
// =============================================================================
.globl _enc_sbfm
.p2align 2
_enc_sbfm:
    mov     w8, #0x13000000         // base: 0|00|100110|0|...
    orr     w8, w8, w1              // Rd [4:0]
    orr     w8, w8, w2, lsl #5     // Rn [9:5]
    orr     w8, w8, w4, lsl #10    // imms [15:10]
    orr     w8, w8, w3, lsl #16    // immr [21:16]
    // N [22] = sf
    orr     w8, w8, w0, lsl #22    // N [22]
    orr     w8, w8, w0, lsl #31    // sf [31]
    mov     w0, w8
    ret
