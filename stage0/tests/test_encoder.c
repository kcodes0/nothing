// test_encoder.c — Test harness for encoder.s
// Compares encoder output against known-good ARM64 instruction encodings.

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>

// Encoder function declarations
extern uint32_t enc_add_imm(int sf, int op, int setflags, int rd, int rn, int imm12);
extern uint32_t enc_add_reg(int sf, int op, int setflags, int rd, int rn, int rm, int shift_type, int shift_amt);
extern uint32_t enc_logic_reg(int sf, int opc, int N, int rd, int rn, int rm, int shift_type, int shift_amt);
extern uint32_t enc_mul(int sf, int rd, int rn, int rm);
extern uint32_t enc_madd(int sf, int rd, int rn, int rm, int ra);
extern uint32_t enc_msub(int sf, int rd, int rn, int rm, int ra);
extern uint32_t enc_udiv(int sf, int rd, int rn, int rm);
extern uint32_t enc_sdiv(int sf, int rd, int rn, int rm);
extern uint32_t enc_movz(int sf, int rd, int imm16, int hw);
extern uint32_t enc_movk(int sf, int rd, int imm16, int hw);
extern uint32_t enc_movn(int sf, int rd, int imm16, int hw);
extern uint32_t enc_b(int64_t offset);
extern uint32_t enc_bl(int64_t offset);
extern uint32_t enc_b_cond(int cond, int64_t offset);
extern uint32_t enc_cbz(int sf, int rt, int64_t offset);
extern uint32_t enc_cbnz(int sf, int rt, int64_t offset);
extern uint32_t enc_ret(int rn);
extern uint32_t enc_ldr_uoff(int size, int rt, int rn, int offset);
extern uint32_t enc_str_uoff(int size, int rt, int rn, int offset);
extern uint32_t enc_ldr_pre(int size, int rt, int rn, int simm9);
extern uint32_t enc_ldr_post(int size, int rt, int rn, int simm9);
extern uint32_t enc_str_pre(int size, int rt, int rn, int simm9);
extern uint32_t enc_str_post(int size, int rt, int rn, int simm9);
extern uint32_t enc_ldp(int sf, int rt, int rt2, int rn, int offset, int type);
extern uint32_t enc_stp(int sf, int rt, int rt2, int rn, int offset, int type);
extern uint32_t enc_adr(int rd, int offset);
extern uint32_t enc_adrp(int rd, int offset);
extern uint32_t enc_svc(int imm16);
extern uint32_t enc_nop(void);
extern uint32_t enc_cset(int sf, int rd, int cond);
extern uint32_t enc_csel(int sf, int rd, int rn, int rm, int cond);
extern uint32_t enc_ubfm(int sf, int rd, int rn, int immr, int imms);
extern uint32_t enc_sbfm(int sf, int rd, int rn, int immr, int imms);

static int tests_run = 0;
static int tests_passed = 0;

static void check(const char *name, uint32_t got, uint32_t expected) {
    tests_run++;
    if (got == expected) {
        tests_passed++;
    } else {
        printf("FAIL: %-30s got=0x%08X expected=0x%08X\n", name, got, expected);
    }
}

int main(void) {
    // ---- NOP ----
    check("nop", enc_nop(), 0xD503201F);

    // ---- RET x30 ----
    check("ret x30", enc_ret(30), 0xD65F03C0);

    // ---- ADD x0, x1, #42 ----
    // ADD X0, X1, #42 => sf=1, op=0, S=0, Rd=0, Rn=1, imm12=42
    // = 0x91000000 | (1<<5) | (42<<10) = 0x9100A820
    check("add x0,x1,#42", enc_add_imm(1, 0, 0, 0, 1, 42), 0x9100A820);

    // ---- SUB x3, x4, #100 ----
    // SUB X3, X4, #100 => sf=1, op=1, S=0, Rd=3, Rn=4, imm12=100
    // = 0xD1000000 | 3 | (4<<5) | (100<<10) = 0xD1019083
    check("sub x3,x4,#100", enc_add_imm(1, 1, 0, 3, 4, 100), 0xD1019083);

    // ---- ADDS w0, w1, #1 (32-bit, set flags) ----
    // sf=0, op=0, S=1, Rd=0, Rn=1, imm12=1
    // = 0x31000000 | (1<<5) | (1<<10) = 0x31000420
    check("adds w0,w1,#1", enc_add_imm(0, 0, 1, 0, 1, 1), 0x31000420);

    // ---- SUBS x2, x3, #0 (CMP alias) ----
    // sf=1, op=1, S=1, Rd=2, Rn=3, imm12=0
    // = 0xF1000000 | 2 | (3<<5) = 0xF1000062
    check("subs x2,x3,#0", enc_add_imm(1, 1, 1, 2, 3, 0), 0xF1000062);

    // ---- ADD x0, x1, x2 (shifted register, LSL #0) ----
    // sf=1, op=0, S=0, Rd=0, Rn=1, Rm=2, shift=LSL(0), amt=0
    // = 0x8B000000 | (1<<5) | (2<<16) = 0x8B020020
    check("add x0,x1,x2", enc_add_reg(1, 0, 0, 0, 1, 2, 0, 0), 0x8B020020);

    // ---- SUB x5, x6, x7, LSL #3 ----
    // sf=1, op=1, S=0, Rd=5, Rn=6, Rm=7, shift=LSL(0), amt=3
    // = 0xCB000000 | 5 | (6<<5) | (3<<10) | (7<<16)
    // = 0xCB070CC5
    check("sub x5,x6,x7,lsl#3", enc_add_reg(1, 1, 0, 5, 6, 7, 0, 3), 0xCB070CC5);

    // ---- AND x0, x1, x2 ----
    // sf=1, opc=00, N=0, Rd=0, Rn=1, Rm=2, shift=0, amt=0
    // = 0x8A000000 | (1<<5) | (2<<16) = 0x8A020020
    check("and x0,x1,x2", enc_logic_reg(1, 0, 0, 0, 1, 2, 0, 0), 0x8A020020);

    // ---- ORR x0, x1, x2 ----
    // sf=1, opc=01, N=0 => 0xAA020020
    check("orr x0,x1,x2", enc_logic_reg(1, 1, 0, 0, 1, 2, 0, 0), 0xAA020020);

    // ---- EOR x0, x1, x2 ----
    // sf=1, opc=10, N=0 => 0xCA020020
    check("eor x0,x1,x2", enc_logic_reg(1, 2, 0, 0, 1, 2, 0, 0), 0xCA020020);

    // ---- MVN x0, x2 (ORN x0, xzr, x2) ----
    // sf=1, opc=01, N=1, Rd=0, Rn=31(xzr), Rm=2
    // = 0xAA200000 | (31<<5) | (2<<16) = 0xAA2203E0
    check("mvn x0,x2", enc_logic_reg(1, 1, 1, 0, 31, 2, 0, 0), 0xAA2203E0);

    // ---- MUL x0, x1, x2 ----
    // sf=1, Rd=0, Rn=1, Rm=2, Ra=31(xzr)
    // = 0x9B000000 | (1<<5) | (31<<10) | (2<<16) = 0x9B027C20
    check("mul x0,x1,x2", enc_mul(1, 0, 1, 2), 0x9B027C20);

    // ---- MADD x0, x1, x2, x3 ----
    // sf=1, Rd=0, Rn=1, Rm=2, Ra=3
    // = 0x9B000000 | (1<<5) | (3<<10) | (2<<16) = 0x9B020C20
    check("madd x0,x1,x2,x3", enc_madd(1, 0, 1, 2, 3), 0x9B020C20);

    // ---- MSUB x0, x1, x2, x3 ----
    // same but o0=1 at bit 15 => adds 0x8000
    // = 0x9B020C20 | 0x8000 = 0x9B028C20
    check("msub x0,x1,x2,x3", enc_msub(1, 0, 1, 2, 3), 0x9B028C20);

    // ---- UDIV x0, x1, x2 ----
    // sf=1 => 0x9AC00800 | (1<<5) | (2<<16) = 0x9AC20820
    check("udiv x0,x1,x2", enc_udiv(1, 0, 1, 2), 0x9AC20820);

    // ---- SDIV x0, x1, x2 ----
    // sf=1 => 0x9AC00C00 | (1<<5) | (2<<16) = 0x9AC20C20
    check("sdiv x0,x1,x2", enc_sdiv(1, 0, 1, 2), 0x9AC20C20);

    // ---- MOVZ x0, #0x1234, LSL #0 ----
    // sf=1, Rd=0, imm16=0x1234, hw=0
    // = 0xD2800000 | (0x1234<<5) = 0xD2824680
    check("movz x0,#0x1234", enc_movz(1, 0, 0x1234, 0), 0xD2824680);

    // ---- MOVK x0, #0xABCD, LSL #16 ----
    // sf=1, Rd=0, imm16=0xABCD, hw=1
    // = 0xF2800000 | (0xABCD<<5) | (1<<21) = 0xF2A579A0
    check("movk x0,#0xABCD,lsl#16", enc_movk(1, 0, 0xABCD, 1), 0xF2B579A0);

    // ---- MOVN x0, #0 ----
    // sf=1, Rd=0, imm16=0, hw=0
    // = 0x92800000
    check("movn x0,#0", enc_movn(1, 0, 0, 0), 0x92800000);

    // ---- B #8 (forward 2 instructions) ----
    // imm26 = 8/4 = 2
    // = 0x14000002
    check("b #8", enc_b(8), 0x14000002);

    // ---- B #-4 (back 1 instruction) ----
    // imm26 = -4/4 = -1 = 0x03FFFFFF
    // = 0x14000000 | 0x03FFFFFF = 0x17FFFFFF
    check("b #-4", enc_b(-4), 0x17FFFFFF);

    // ---- BL #100 ----
    // imm26 = 100/4 = 25
    // = 0x94000019
    check("bl #100", enc_bl(100), 0x94000019);

    // ---- B.EQ #12 ----
    // cond=0 (EQ), imm19 = 12/4 = 3
    // = 0x54000000 | (3<<5) | 0 = 0x54000060
    check("b.eq #12", enc_b_cond(0, 12), 0x54000060);

    // ---- B.NE #-8 ----
    // cond=1 (NE), imm19 = -8/4 = -2
    // -2 in 19 bits = 0x7FFFE
    // = 0x54000000 | (0x7FFFE<<5) | 1 = 0x54FFFFC1
    check("b.ne #-8", enc_b_cond(1, -8), 0x54FFFFC1);

    // ---- CBZ x0, #16 ----
    // sf=1, Rt=0, offset=16 => imm19=4
    // = 0xB4000000 | (4<<5) = 0xB4000080
    check("cbz x0,#16", enc_cbz(1, 0, 16), 0xB4000080);

    // ---- CBNZ w5, #-12 ----
    // sf=0, Rt=5, offset=-12 => imm19=-3
    // -3 in 19 bits = 0x7FFFD
    // = 0x35000000 | 5 | (0x7FFFD << 5) = 0x35FFFFA5
    check("cbnz w5,#-12", enc_cbnz(0, 5, -12), 0x35FFFFA5);

    // ---- LDR x0, [x1, #8] ----
    // size=3(dword), Rt=0, Rn=1, offset=8
    // imm12 = 8 >> 3 = 1
    // = 0xF9400000 | (1<<5) | (1<<10) = 0xF9400420
    check("ldr x0,[x1,#8]", enc_ldr_uoff(3, 0, 1, 8), 0xF9400420);

    // ---- STR x0, [sp, #16] ----
    // size=3, Rt=0, Rn=31(sp), offset=16
    // imm12 = 16 >> 3 = 2
    // = 0xF9000000 | (31<<5) | (2<<10) = 0xF9000BE0
    check("str x0,[sp,#16]", enc_str_uoff(3, 0, 31, 16), 0xF9000BE0);

    // ---- LDRB w0, [x1, #5] ----
    // size=0, Rt=0, Rn=1, offset=5
    // imm12 = 5 >> 0 = 5
    // = 0x39400000 | (1<<5) | (5<<10) = 0x39401420
    check("ldrb w0,[x1,#5]", enc_ldr_uoff(0, 0, 1, 5), 0x39401420);

    // ---- LDR x0, [x1, #-16]! (pre-index) ----
    // size=3, Rt=0, Rn=1, simm9=-16
    // -16 in 9 bits = 0x1F0
    // = 0xF8400C00 | (1<<5) | (0x1F0<<12) = 0xF8500C20
    // Actually: base for size=3 is 0xF8400C00
    // simm9 = -16 & 0x1FF = 0x1F0
    // = 0xF8400C00 | 0 | (1<<5) | (0x1F0 << 12)
    // = 0xF8400C00 | 0x20 | 0x1F0000
    // = 0xF85F0C20
    check("ldr x0,[x1,#-16]!", enc_ldr_pre(3, 0, 1, -16), 0xF85F0C20);

    // ---- STR x0, [x1], #8 (post-index) ----
    // size=3, Rt=0, Rn=1, simm9=8
    // = 0xF8000400 | (1<<5) | (8<<12) = 0xF8008420
    check("str x0,[x1],#8", enc_str_post(3, 0, 1, 8), 0xF8008420);

    // ---- STP x29, x30, [sp, #-16]! (pre-index) ----
    // sf=1, Rt=29, Rt2=30, Rn=31, offset=-16, type=1(pre)
    // opc=10, type=011(pre), L=0(store)
    // imm7 = -16 >> 3 = -2 => 0x7E
    // = 0xA9800000 | 29 | (31<<5) | (30<<10) | (0x7E<<15)
    // = 0xA9800000 | 0x1D | 0x3E0 | 0x7800 | 0x3F00000
    // Hmm let me compute more carefully:
    // base: opc=10 at [31:30], [29:27]=101, V=0 [26], type=011 [25:23], L=0 [22]
    // = 0xA9800000
    // Rt=29 => bits [4:0] = 11101
    // Rn=31 => bits [9:5] = 11111
    // Rt2=30 => bits [14:10] = 11110
    // imm7=-2 => 1111110 = 0x7E => bits [21:15]
    // = 0xA9800000 | 29 | (31<<5) | (30<<10) | (0x7E<<15)
    // = 0xA9800000 | 0x1D | 0x3E0 | 0x7800 | 0x3F0000
    // Hmm, 0x7E << 15 = 0x3F0000
    // = 0xA9BF7BFD
    check("stp x29,x30,[sp,#-16]!", enc_stp(1, 29, 30, 31, -16, 1), 0xA9BF7BFD);

    // ---- LDP x29, x30, [sp], #16 (post-index) ----
    // sf=1, Rt=29, Rt2=30, Rn=31, offset=16, type=2(post)
    // opc=10, type=001(post), L=1(load)
    // imm7 = 16 >> 3 = 2
    // = 0xA8C00000 | 29 | (31<<5) | (30<<10) | (2<<15)
    // = 0xA8C00000 | 0x1D | 0x3E0 | 0x7800 | 0x10000
    // = 0xA8C17BFD
    check("ldp x29,x30,[sp],#16", enc_ldp(1, 29, 30, 31, 16, 2), 0xA8C17BFD);

    // ---- SVC #0x80 ----
    // = 0xD4000001 | (0x80 << 5) = 0xD4001001
    check("svc #0x80", enc_svc(0x80), 0xD4001001);

    // ---- ADR x0, #0 ----
    // = 0x10000000
    check("adr x0,#0", enc_adr(0, 0), 0x10000000);

    // ---- CSET x0, EQ (cond=0) ----
    // CSINC x0, xzr, xzr, NE (inverted EQ = NE = cond 1)
    // = sf=1: 0x9A800000 | Rd=0 | (31<<5) | (1<<12) | (31<<16) | 0x400
    // = 0x9A9F17E0
    check("cset x0,eq", enc_cset(1, 0, 0), 0x9A9F17E0);

    // ---- CSEL x0, x1, x2, EQ ----
    // sf=1, Rd=0, Rn=1, Rm=2, cond=0
    // = 0x9A800000 | (1<<5) | (0<<12) | (2<<16)
    // = 0x9A820020
    check("csel x0,x1,x2,eq", enc_csel(1, 0, 1, 2, 0), 0x9A820020);

    // ---- UBFM x0, x1, #1, #63 (LSR #1) ----
    // sf=1, Rd=0, Rn=1, immr=1, imms=63, N=1
    // = 0xD3400000 | (1<<5) | (63<<10) | (1<<16) = 0xD341FC20
    check("ubfm x0,x1,#1,#63", enc_ubfm(1, 0, 1, 1, 63), 0xD341FC20);

    // ---- SBFM x0, x1, #0, #31 (SXTW) ----
    // sf=1, Rd=0, Rn=1, immr=0, imms=31, N=1
    // = 0x93400000 | (1<<5) | (31<<10) = 0x93407C20
    check("sbfm x0,x1,#0,#31", enc_sbfm(1, 0, 1, 0, 31), 0x93407C20);

    // ---- MOVZ w5, #0x1234 (32-bit) ----
    // sf=0, Rd=5, imm16=0x1234, hw=0
    // = 0x52800000 | 5 | (0x1234 << 5) = 0x52824685
    check("movz w5,#0x1234", enc_movz(0, 5, 0x1234, 0), 0x52824685);

    // Print summary
    printf("\n%d/%d tests passed\n", tests_passed, tests_run);
    if (tests_passed == tests_run) {
        printf("All tests passed!\n");
        return 0;
    } else {
        printf("%d tests FAILED\n", tests_run - tests_passed);
        return 1;
    }
}
