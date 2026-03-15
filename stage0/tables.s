// tables.s — Static lookup tables for the ARM64 bootstrapped assembler
// Provides mnemonic, register, condition code, and directive tables
// plus lookup functions for each.
//
// Calling convention: Apple AAPCS64
// External dependency: str_eq_lit from strings.s
//   str_eq_lit(x0=str_ptr, x1=str_len, x2=literal_ptr) -> x0=1 if equal

.section __TEXT,__text,regular,pure_instructions
.p2align 2

// ============================================================================
// External references
// ============================================================================
.extern _str_eq_lit

// ============================================================================
// Public symbols
// ============================================================================
.globl _lookup_mnemonic
.globl _lookup_register
.globl _lookup_cond_code
.globl _lookup_directive

// Expose table symbols for testing/debugging
.globl _mnemonic_table
.globl _mnemonic_count
.globl _cond_table
.globl _cond_count
.globl _directive_table
.globl _directive_count

// ============================================================================
// Constants — Mnemonic entry layout
// ============================================================================
// Each mnemonic entry:
//   - 12 bytes: null-terminated name (padded)
//   -  4 bytes: mnemonic ID (int32)
//   Total: 16 bytes per entry
.set MNEM_ENTRY_SIZE,  16
.set MNEM_NAME_OFFSET,  0
.set MNEM_ID_OFFSET,   12

// Condition table entry layout:
//   - 4 bytes: null-terminated name (padded)
//   - 4 bytes: condition code (int32)
//   Total: 8 bytes per entry
.set COND_ENTRY_SIZE,   8
.set COND_NAME_OFFSET,  0
.set COND_CODE_OFFSET,  4

// Directive table entry layout:
//   - 12 bytes: null-terminated name (padded)
//   -  4 bytes: directive ID (int32)
//   Total: 16 bytes per entry
.set DIR_ENTRY_SIZE,   16
.set DIR_NAME_OFFSET,   0
.set DIR_ID_OFFSET,    12


// ============================================================================
// lookup_mnemonic — Find a mnemonic by name via linear scan
// ============================================================================
// Args:   x0 = name_ptr, x1 = name_len
// Returns: x0 = mnemonic_id (-1 if not found)
.p2align 2
_lookup_mnemonic:
    // Prologue — save callee-saved regs + lr
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                     // x19 = name_ptr (preserved)
    mov     x20, x1                     // x20 = name_len (preserved)

    // Load table base and count
    adrp    x21, _mnemonic_table@PAGE
    add     x21, x21, _mnemonic_table@PAGEOFF  // x21 = table base
    adrp    x22, _mnemonic_count@PAGE
    add     x22, x22, _mnemonic_count@PAGEOFF
    ldr     w22, [x22]                  // x22 = entry count

    mov     x23, #0                     // x23 = index

1:  // Loop: compare each entry
    cmp     x23, x22
    b.ge    2f                          // exhausted table -> not found

    // Compute entry address: x21 + index * MNEM_ENTRY_SIZE
    mov     x24, #MNEM_ENTRY_SIZE
    madd    x24, x23, x24, x21         // x24 = &table[index]

    // Call str_eq_lit(name_ptr, name_len, entry_name_ptr)
    mov     x0, x19
    mov     x1, x20
    add     x2, x24, #MNEM_NAME_OFFSET
    bl      _str_eq_lit

    // If match, return the mnemonic ID
    cbnz    x0, 3f

    add     x23, x23, #1
    b       1b

2:  // Not found
    mov     x0, #-1
    b       4f

3:  // Found — load mnemonic ID from entry
    mov     x24, #MNEM_ENTRY_SIZE
    madd    x24, x23, x24, x21
    ldr     w0, [x24, #MNEM_ID_OFFSET]

4:  // Epilogue
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


// ============================================================================
// lookup_register — Find register by name using fast-path parsing
// ============================================================================
// Args:   x0 = name_ptr, x1 = name_len
// Returns: x0 = register number (0-31, or -1 if not found)
//          x1 = is_32bit (0 for x/sp/xzr, 1 for w/wzr)
//          x2 = is_sp (1 if "sp", else 0)
.p2align 2
_lookup_register:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    // Check for empty string
    cbz     x1, Lreg_not_found

    // Load first character
    ldrb    w2, [x0]

    // --- Check for "sp" (stack pointer) ---
    cmp     x1, #2
    b.ne    Lreg_check_xzr_wzr
    cmp     w2, #'s'
    b.ne    Lreg_check_xzr_wzr
    ldrb    w3, [x0, #1]
    cmp     w3, #'p'
    b.ne    Lreg_check_xzr_wzr
    // It's "sp"
    mov     x0, #31
    mov     x1, #0                      // 64-bit
    mov     x2, #1                      // is_sp = 1
    b       Lreg_done

Lreg_check_xzr_wzr:
    // --- Check for "xzr" or "wzr" ---
    cmp     x1, #3
    b.ne    Lreg_check_prefix

    // Second and third chars must be 'z', 'r'
    ldrb    w3, [x0, #1]
    cmp     w3, #'z'
    b.ne    Lreg_check_prefix
    ldrb    w3, [x0, #2]
    cmp     w3, #'r'
    b.ne    Lreg_check_prefix

    // First char determines width
    cmp     w2, #'x'
    b.eq    Lreg_xzr
    cmp     w2, #'w'
    b.eq    Lreg_wzr
    b       Lreg_check_prefix

Lreg_xzr:
    mov     x0, #31
    mov     x1, #0                      // 64-bit
    mov     x2, #0                      // not sp
    b       Lreg_done

Lreg_wzr:
    mov     x0, #31
    mov     x1, #1                      // 32-bit
    mov     x2, #0
    b       Lreg_done

Lreg_check_prefix:
    // --- Fast path: "x<num>" or "w<num>" ---
    // First char must be 'x' or 'w'
    mov     w4, #0                      // w4 = is_32bit
    cmp     w2, #'x'
    b.eq    Lreg_parse_num
    cmp     w2, #'w'
    b.ne    Lreg_not_found
    mov     w4, #1                      // 32-bit register

Lreg_parse_num:
    // Parse decimal number from name_ptr+1, length name_len-1
    // Must be 1 or 2 digits, value 0-30
    sub     x5, x1, #1                  // x5 = remaining length
    cbz     x5, Lreg_not_found         // no digits after prefix
    cmp     x5, #2
    b.hi    Lreg_not_found             // more than 2 digits -> invalid

    // First digit
    ldrb    w6, [x0, #1]
    sub     w6, w6, #'0'
    cmp     w6, #9
    b.hi    Lreg_not_found             // not a digit

    cmp     x5, #1
    b.eq    Lreg_have_num              // single digit

    // Two digits: first_digit * 10 + second_digit
    ldrb    w7, [x0, #2]
    sub     w7, w7, #'0'
    cmp     w7, #9
    b.hi    Lreg_not_found

    mov     w8, #10
    madd    w6, w6, w8, w7             // w6 = first*10 + second

Lreg_have_num:
    // Validate range 0-30
    cmp     w6, #30
    b.hi    Lreg_not_found

    // Return results
    mov     w0, w6                      // register number
    mov     w1, w4                      // is_32bit
    mov     x2, #0                      // not sp
    b       Lreg_done

Lreg_not_found:
    mov     x0, #-1
    mov     x1, #0
    mov     x2, #0

Lreg_done:
    ldp     x29, x30, [sp], #16
    ret


// ============================================================================
// lookup_cond_code — Find condition code by name via linear scan
// ============================================================================
// Args:   x0 = name_ptr, x1 = name_len
// Returns: x0 = condition code (0-14), or -1 if not found
.p2align 2
_lookup_cond_code:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0                     // name_ptr
    mov     x20, x1                     // name_len

    adrp    x21, _cond_table@PAGE
    add     x21, x21, _cond_table@PAGEOFF
    adrp    x22, _cond_count@PAGE
    add     x22, x22, _cond_count@PAGEOFF
    ldr     w22, [x22]

    mov     x23, #0                     // index

1:  cmp     x23, x22
    b.ge    2f

    mov     x24, #COND_ENTRY_SIZE
    madd    x24, x23, x24, x21         // &table[index]

    mov     x0, x19
    mov     x1, x20
    add     x2, x24, #COND_NAME_OFFSET
    bl      _str_eq_lit

    cbnz    x0, 3f

    add     x23, x23, #1
    b       1b

2:  // Not found
    mov     x0, #-1
    b       4f

3:  // Found
    mov     x24, #COND_ENTRY_SIZE
    madd    x24, x23, x24, x21
    ldr     w0, [x24, #COND_CODE_OFFSET]

4:  ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


// ============================================================================
// lookup_directive — Find directive by name via linear scan
// ============================================================================
// Args:   x0 = name_ptr, x1 = name_len
// Returns: x0 = directive_id (-1 if not found)
.p2align 2
_lookup_directive:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    mov     x19, x0
    mov     x20, x1

    adrp    x21, _directive_table@PAGE
    add     x21, x21, _directive_table@PAGEOFF
    adrp    x22, _directive_count@PAGE
    add     x22, x22, _directive_count@PAGEOFF
    ldr     w22, [x22]

    mov     x23, #0

1:  cmp     x23, x22
    b.ge    2f

    mov     x24, #DIR_ENTRY_SIZE
    madd    x24, x23, x24, x21

    mov     x0, x19
    mov     x1, x20
    add     x2, x24, #DIR_NAME_OFFSET
    bl      _str_eq_lit

    cbnz    x0, 3f

    add     x23, x23, #1
    b       1b

2:  mov     x0, #-1
    b       4f

3:  mov     x24, #DIR_ENTRY_SIZE
    madd    x24, x23, x24, x21
    ldr     w0, [x24, #DIR_ID_OFFSET]

4:  ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


// ============================================================================
// DATA SECTION — Static lookup tables
// ============================================================================
.section __DATA,__data

// ----------------------------------------------------------------------------
// Mnemonic table
// Each entry: 12 bytes name (null-terminated, zero-padded) + 4 bytes ID
// Total: 16 bytes per entry
// ----------------------------------------------------------------------------
.p2align 3
_mnemonic_table:
    // Arithmetic
    .ascii "add\0"                      // name (4 bytes)
    .space 8                            // padding to 12
    .long 0                             // id = 0

    .ascii "sub\0"
    .space 8
    .long 1

    .ascii "mul\0"
    .space 8
    .long 2

    .ascii "madd\0"
    .space 7
    .long 3

    .ascii "msub\0"
    .space 7
    .long 4

    .ascii "neg\0"
    .space 8
    .long 5

    // Logical
    .ascii "and\0"
    .space 8
    .long 6

    .ascii "orr\0"
    .space 8
    .long 7

    .ascii "eor\0"
    .space 8
    .long 8

    .ascii "mvn\0"
    .space 8
    .long 9

    // Shifts
    .ascii "lsl\0"
    .space 8
    .long 10

    .ascii "lsr\0"
    .space 8
    .long 11

    .ascii "asr\0"
    .space 8
    .long 12

    // Compare
    .ascii "cmp\0"
    .space 8
    .long 13

    .ascii "cmn\0"
    .space 8
    .long 14

    .ascii "tst\0"
    .space 8
    .long 15

    // Branch
    .ascii "b\0"
    .space 10
    .long 16

    .ascii "bl\0"
    .space 9
    .long 17

    .ascii "ret\0"
    .space 8
    .long 18

    .ascii "cbz\0"
    .space 8
    .long 19

    .ascii "cbnz\0"
    .space 7
    .long 20

    // Load/Store
    .ascii "ldr\0"
    .space 8
    .long 21

    .ascii "str\0"
    .space 8
    .long 22

    .ascii "ldrb\0"
    .space 7
    .long 23

    .ascii "strb\0"
    .space 7
    .long 24

    .ascii "ldp\0"
    .space 8
    .long 25

    .ascii "stp\0"
    .space 8
    .long 26

    // PC-relative addressing
    .ascii "adr\0"
    .space 8
    .long 27

    .ascii "adrp\0"
    .space 7
    .long 28

    // Move
    .ascii "mov\0"
    .space 8
    .long 29

    .ascii "movz\0"
    .space 7
    .long 30

    .ascii "movk\0"
    .space 7
    .long 31

    .ascii "movn\0"
    .space 7
    .long 32

    // System
    .ascii "svc\0"
    .space 8
    .long 33

    .ascii "nop\0"
    .space 8
    .long 34

    // Conditional branches (b.cond)
    .ascii "b.eq\0"
    .space 7
    .long 35

    .ascii "b.ne\0"
    .space 7
    .long 36

    .ascii "b.lt\0"
    .space 7
    .long 37

    .ascii "b.gt\0"
    .space 7
    .long 38

    .ascii "b.le\0"
    .space 7
    .long 39

    .ascii "b.ge\0"
    .space 7
    .long 40

    .ascii "b.cs\0"
    .space 7
    .long 41

    .ascii "b.cc\0"
    .space 7
    .long 42

    .ascii "b.mi\0"
    .space 7
    .long 43

    .ascii "b.pl\0"
    .space 7
    .long 44

    .ascii "b.hi\0"
    .space 7
    .long 45

    .ascii "b.ls\0"
    .space 7
    .long 46

    // Flag-setting arithmetic
    .ascii "subs\0"
    .space 7
    .long 47

    .ascii "adds\0"
    .space 7
    .long 48

    .ascii "ands\0"
    .space 7
    .long 49

    // Division
    .ascii "udiv\0"
    .space 7
    .long 50

    .ascii "sdiv\0"
    .space 7
    .long 51

    // Half-word load/store
    .ascii "ldrh\0"
    .space 7
    .long 52

    .ascii "strh\0"
    .space 7
    .long 53

    // Bitfield
    .ascii "ubfm\0"
    .space 7
    .long 54

    .ascii "sbfm\0"
    .space 7
    .long 55

    // Conditional
    .ascii "cset\0"
    .space 7
    .long 56

    .ascii "csel\0"
    .space 7
    .long 57

.p2align 2
_mnemonic_count:
    .long 58                            // total number of mnemonic entries


// ----------------------------------------------------------------------------
// Condition code table
// Each entry: 4 bytes name (null-terminated, zero-padded) + 4 bytes code
// Total: 8 bytes per entry
// Note: "hs" and "cs" share code 0x2; "lo" and "cc" share code 0x3
// ----------------------------------------------------------------------------
.p2align 2
_cond_table:
    .ascii "eq\0\0"
    .long 0x0

    .ascii "ne\0\0"
    .long 0x1

    .ascii "cs\0\0"
    .long 0x2

    .ascii "hs\0\0"
    .long 0x2

    .ascii "cc\0\0"
    .long 0x3

    .ascii "lo\0\0"
    .long 0x3

    .ascii "mi\0\0"
    .long 0x4

    .ascii "pl\0\0"
    .long 0x5

    .ascii "vs\0\0"
    .long 0x6

    .ascii "vc\0\0"
    .long 0x7

    .ascii "hi\0\0"
    .long 0x8

    .ascii "ls\0\0"
    .long 0x9

    .ascii "ge\0\0"
    .long 0xA

    .ascii "lt\0\0"
    .long 0xB

    .ascii "gt\0\0"
    .long 0xC

    .ascii "le\0\0"
    .long 0xD

    .ascii "al\0\0"
    .long 0xE

.p2align 2
_cond_count:
    .long 17                            // total condition entries (including aliases)


// ----------------------------------------------------------------------------
// Directive table
// Each entry: 12 bytes name (null-terminated, zero-padded) + 4 bytes ID
// Total: 16 bytes per entry
// ----------------------------------------------------------------------------
.p2align 2
_directive_table:
    .ascii ".text\0"
    .space 6
    .long 0

    .ascii ".data\0"
    .space 6
    .long 1

    .ascii ".ascii\0"
    .space 5
    .long 2

    .ascii ".asciz\0"
    .space 5
    .long 3

    .ascii ".byte\0"
    .space 6
    .long 4

    .ascii ".quad\0"
    .space 6
    .long 5

    .ascii ".align\0"
    .space 5
    .long 6

    .ascii ".global\0"
    .space 4
    .long 7

    .ascii ".globl\0"
    .space 5
    .long 7

    .ascii ".space\0"
    .space 5
    .long 8

    .ascii ".zero\0"
    .space 6
    .long 9

.p2align 2
_directive_count:
    .long 11                            // total directive entries

.subsections_via_symbols
