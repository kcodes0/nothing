// macho.s — Mach-O 64-bit object file emitter for the bootstrapped assembler
// AArch64 macOS (Apple Silicon)
// Calling convention: AAPCS64 (x0-x7 args, x0 return, x29/x30 frame pair, x18 reserved)
//
// This module takes assembled code, data, symbols, and relocations and emits
// a valid MH_OBJECT Mach-O file that the system linker (ld) can consume.
//
// Public functions:
//   _macho_init         — Initialize emitter state (zero all globals)
//   _macho_emit         — Write complete Mach-O object file to an fd
//   _macho_add_reloc    — Add a relocation entry to internal array
//   _macho_build_symtab — Build nlist_64 symbol table from assembler's symtab
//
// Mach-O Object File Layout:
//   mach_header_64           (32 bytes)
//   LC_SEGMENT_64            (72 + 2*80 = 232 bytes)
//   LC_BUILD_VERSION         (24 bytes)
//   LC_SYMTAB                (24 bytes)
//   LC_DYSYMTAB              (80 bytes)
//   __text section content
//   __data section content
//   __text relocations
//   symbol table (nlist_64)
//   string table

// =============================================================================
// External references
// =============================================================================
.extern _write
.extern _malloc
.extern _free
.extern _memcpy_custom
.extern _memset_custom
.extern _sym_iterate
.extern _sym_count
.extern _error_exit

// =============================================================================
// Constants
// =============================================================================

// Mach-O magic and CPU
.set MH_MAGIC_64,           0xFEEDFACF
.set CPU_TYPE_ARM64,        0x0100000C
.set CPU_SUBTYPE_ARM64_ALL, 0x00000000
.set MH_OBJECT,             0x1
.set MH_SUBSECTIONS_VIA_SYMBOLS, 0x2000

// Load commands
.set LC_SEGMENT_64,   0x19
.set LC_SYMTAB,       0x02
.set LC_DYSYMTAB,     0x0B
.set LC_BUILD_VERSION, 0x32

// Platform
.set PLATFORM_MACOS,  1

// Section flags
.set S_REGULAR,                0x0
.set S_ATTR_PURE_INSTRUCTIONS, 0x80000000
.set S_ATTR_SOME_INSTRUCTIONS, 0x00000400

// Symbol types
.set N_UNDF, 0x0
.set N_ABS,  0x2
.set N_SECT, 0xE
.set N_EXT,  0x01

// ARM64 relocation types
.set ARM64_RELOC_UNSIGNED,          0
.set ARM64_RELOC_SUBTRACTOR,        1
.set ARM64_RELOC_BRANCH26,          2
.set ARM64_RELOC_PAGE21,            3
.set ARM64_RELOC_PAGEOFF12,         4
.set ARM64_RELOC_GOT_LOAD_PAGE21,   5
.set ARM64_RELOC_GOT_LOAD_PAGEOFF12, 6
.set ARM64_RELOC_POINTER_TO_GOT,    7
.set ARM64_RELOC_TLVP_LOAD_PAGE21,  8
.set ARM64_RELOC_TLVP_LOAD_PAGEOFF12, 9
.set ARM64_RELOC_ADDEND,            10

// Structure sizes
.set MACH_HEADER_SIZE,    32
.set SEGMENT_CMD_SIZE,    72
.set SECTION_SIZE,        80
.set NLIST_SIZE,          16
.set RELOC_INFO_SIZE,     8
.set BUILD_VER_CMD_SIZE,  24
.set SYMTAB_CMD_SIZE,     24
.set DYSYMTAB_CMD_SIZE,   80

// Load command total sizes
.set LC_SEG_TOTAL_SIZE,   232    // 72 + 2*80 (segment + 2 sections)
.set TOTAL_CMDS_SIZE,     360    // 232 + 24 + 24 + 80
.set NUM_LOAD_CMDS,       4      // LC_SEGMENT_64, LC_BUILD_VERSION, LC_SYMTAB, LC_DYSYMTAB

// Internal relocation entry size (our format)
// Layout: address(4), reserved(4), sym_entry_ptr(8), type(4), flags(4)
.set INT_RELOC_SIZE,      24
// Internal symbol entry size (our format)
.set INT_SYM_SIZE,        32

// Output buffer size (1 MB)
.set OUTPUT_BUF_SIZE,     0x100000

// Relocation array initial capacity
.set RELOC_INIT_CAP,      256

// macOS version: 14.0.0 encoded as (14 << 16 | 0 << 8 | 0)
.set MACOS_14_VERSION,    0x000E0000

// =============================================================================
// Public symbols
// =============================================================================
.globl _macho_init
.globl _macho_emit
.globl _macho_add_reloc
.globl _macho_build_symtab

// Expose global variables so the assembler can set them
.globl _macho_text_buf
.globl _macho_text_size
.globl _macho_data_buf
.globl _macho_data_size
.globl _macho_relocs
.globl _macho_reloc_count
.globl _macho_reloc_cap
.globl _macho_syms
.globl _macho_sym_count
.globl _macho_strtab
.globl _macho_strtab_size
.globl _macho_num_locals
.globl _macho_num_defined_ext
.globl _macho_num_undef_ext


// =============================================================================
// TEXT SECTION
// =============================================================================
.section __TEXT,__text
.p2align 2


// =============================================================================
// _macho_init — Initialize emitter state
//   Zeros all global variables. Call before starting assembly.
//   No args, no return value.
// =============================================================================
.p2align 2
_macho_init:
    stp     x29, x30, [sp, #-16]!
    mov     x29, sp

    // Zero all macho global pointers and counters
    adrp    x0, _macho_text_buf@PAGE
    add     x0, x0, _macho_text_buf@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_text_size@PAGE
    add     x0, x0, _macho_text_size@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_data_buf@PAGE
    add     x0, x0, _macho_data_buf@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_data_size@PAGE
    add     x0, x0, _macho_data_size@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_relocs@PAGE
    add     x0, x0, _macho_relocs@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_reloc_count@PAGE
    add     x0, x0, _macho_reloc_count@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_reloc_cap@PAGE
    add     x0, x0, _macho_reloc_cap@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_syms@PAGE
    add     x0, x0, _macho_syms@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_sym_count@PAGE
    add     x0, x0, _macho_sym_count@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_strtab@PAGE
    add     x0, x0, _macho_strtab@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_strtab_size@PAGE
    add     x0, x0, _macho_strtab_size@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_num_locals@PAGE
    add     x0, x0, _macho_num_locals@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_num_defined_ext@PAGE
    add     x0, x0, _macho_num_defined_ext@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_num_undef_ext@PAGE
    add     x0, x0, _macho_num_undef_ext@PAGEOFF
    str     xzr, [x0]

    ldp     x29, x30, [sp], #16
    ret


// =============================================================================
// _macho_add_reloc — Add a relocation entry to the internal array
//   x0 = address (offset within section)
//   x1 = sym_entry_ptr (pointer to symbol entry from symtab.s)
//   x2 = type (ARM64_RELOC_* type)
//   x3 = pcrel (0 or 1)
//   x4 = extern_flag (0 or 1)
//   x5 = length (0=1byte, 1=2bytes, 2=4bytes, 3=8bytes)
//
// Appends a 16-byte internal relocation entry. Grows array if needed.
// =============================================================================
.p2align 2
_macho_add_reloc:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]

    // Save arguments
    mov     x19, x0                     // address
    mov     x20, x1                     // sym_index
    mov     x21, x2                     // type
    mov     x22, x3                     // pcrel
    mov     x23, x4                     // extern_flag
    mov     x24, x5                     // length

    // Load current count and capacity
    adrp    x0, _macho_reloc_count@PAGE
    add     x0, x0, _macho_reloc_count@PAGEOFF
    ldr     x1, [x0]                    // x1 = count

    adrp    x2, _macho_reloc_cap@PAGE
    add     x2, x2, _macho_reloc_cap@PAGEOFF
    ldr     x3, [x2]                    // x3 = capacity

    // Check if we need to grow the array
    cmp     x1, x3
    b.lo    Lmar_have_space

    // Need to grow: if capacity is 0, set to RELOC_INIT_CAP, else double it
    cbz     x3, Lmar_init_cap
    lsl     x3, x3, #1                 // double capacity
    b       Lmar_alloc

Lmar_init_cap:
    mov     x3, #RELOC_INIT_CAP

Lmar_alloc:
    // Allocate new array: capacity * INT_RELOC_SIZE bytes
    mov     x0, #INT_RELOC_SIZE
    mul     x0, x3, x0                  // x0 = new_cap * 16
    // Save new capacity
    stp     x3, x1, [sp, #-16]!        // push new_cap, old_count
    bl      _malloc                      // x0 = new buffer
    ldp     x3, x1, [sp], #16          // pop new_cap, old_count
    cbz     x0, Lmar_error             // malloc failed

    // Copy old data to new buffer if there was old data
    cbz     x1, Lmar_replace

    // Save new buffer pointer
    mov     x9, x0                      // x9 = new buffer

    // Load old buffer pointer
    adrp    x10, _macho_relocs@PAGE
    add     x10, x10, _macho_relocs@PAGEOFF
    ldr     x11, [x10]                  // x11 = old buffer

    // Copy old_count * INT_RELOC_SIZE bytes
    // x0 = dst (new), x1 = src (old), x2 = len
    mov     x0, x9                      // dst = new buffer
    mov     x12, x1                     // save old_count
    mov     x1, x11                     // src = old buffer
    mov     x2, #INT_RELOC_SIZE
    mul     x2, x12, x2                 // len = count * 16
    bl      _memcpy_custom

    // Free old buffer
    adrp    x10, _macho_relocs@PAGE
    add     x10, x10, _macho_relocs@PAGEOFF
    ldr     x0, [x10]                  // old buffer
    bl      _free

    mov     x0, x9                      // restore new buffer pointer
    mov     x1, x12                     // restore old count
    b       Lmar_store_new

Lmar_replace:
    // No old data, just store the new buffer
    // x0 = new buffer, x1 = 0

Lmar_store_new:
    // Store new buffer pointer and new capacity
    adrp    x10, _macho_relocs@PAGE
    add     x10, x10, _macho_relocs@PAGEOFF
    str     x0, [x10]

    adrp    x10, _macho_reloc_cap@PAGE
    add     x10, x10, _macho_reloc_cap@PAGEOFF
    str     x3, [x10]

Lmar_have_space:
    // Now append the new entry at index = count
    // Load current buffer and count
    adrp    x10, _macho_relocs@PAGE
    add     x10, x10, _macho_relocs@PAGEOFF
    ldr     x0, [x10]                  // x0 = buffer base

    adrp    x10, _macho_reloc_count@PAGE
    add     x10, x10, _macho_reloc_count@PAGEOFF
    ldr     x1, [x10]                  // x1 = current count

    // Compute entry address: base + count * INT_RELOC_SIZE
    mov     x2, #INT_RELOC_SIZE
    madd    x0, x1, x2, x0             // x0 = &entry[count]

    // Write the internal relocation entry (24 bytes):
    //   offset 0:  address (4 bytes)
    //   offset 4:  reserved (4 bytes)
    //   offset 8:  sym_entry_ptr (8 bytes)
    //   offset 16: type (4 bytes)
    //   offset 20: flags (4 bytes) — bit 0: pcrel, bit 1: extern, bits 4-5: length
    str     w19, [x0, #0]              // address
    str     wzr, [x0, #4]             // reserved
    str     x20, [x0, #8]             // sym_entry_ptr (8 bytes)
    str     w21, [x0, #16]            // type

    // Pack flags: bit 0 = pcrel, bit 1 = extern, bits 4-5 = length
    and     w22, w22, #1               // pcrel & 1
    and     w23, w23, #1               // extern & 1
    and     w24, w24, #3               // length & 3
    lsl     w23, w23, #1               // extern << 1
    lsl     w24, w24, #4               // length << 4
    orr     w22, w22, w23
    orr     w22, w22, w24
    str     w22, [x0, #20]             // flags

    // Increment count
    add     x1, x1, #1
    str     x1, [x10]

    // Return success
    mov     x0, #0
    b       Lmar_done

Lmar_error:
    adrp    x0, _macho_err_malloc@PAGE
    add     x0, x0, _macho_err_malloc@PAGEOFF
    bl      _error_exit

Lmar_done:
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #64
    ret


// =============================================================================
// _macho_build_symtab — Build nlist_64 symbol table and string table
//   from the assembler's symbol table (via _sym_iterate).
//
//   Orders symbols: locals first, then defined externals, then undefined externals.
//   This ordering is required by LC_DYSYMTAB.
//
//   Allocates _macho_syms and _macho_strtab buffers.
//   Sets _macho_sym_count, _macho_strtab_size, _macho_num_locals,
//        _macho_num_defined_ext, _macho_num_undef_ext.
//
//   No args, no return value.
// =============================================================================
.p2align 2
_macho_build_symtab:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    // -----------------------------------------------------------------------
    // Pass 1: Count symbols by category using _sym_iterate
    // We use three counters stored in globals, zeroed first.
    // -----------------------------------------------------------------------
    adrp    x0, _macho_num_locals@PAGE
    add     x0, x0, _macho_num_locals@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_num_defined_ext@PAGE
    add     x0, x0, _macho_num_defined_ext@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_num_undef_ext@PAGE
    add     x0, x0, _macho_num_undef_ext@PAGEOFF
    str     xzr, [x0]

    // Count total symbols
    bl      _sym_count
    mov     x19, x0                     // x19 = total symbol count

    cbz     x19, Lmbs_empty           // no symbols, nothing to do

    // Iterate to count categories
    adrp    x0, _mbs_count_callback@PAGE
    add     x0, x0, _mbs_count_callback@PAGEOFF
    bl      _sym_iterate

    // -----------------------------------------------------------------------
    // Allocate output symbol table: sym_count * INT_SYM_SIZE bytes
    // -----------------------------------------------------------------------
    mov     x0, #INT_SYM_SIZE
    mul     x0, x19, x0                 // x0 = total * 32
    bl      _malloc
    cbz     x0, Lmbs_error

    adrp    x1, _macho_syms@PAGE
    add     x1, x1, _macho_syms@PAGEOFF
    str     x0, [x1]

    adrp    x1, _macho_sym_count@PAGE
    add     x1, x1, _macho_sym_count@PAGEOFF
    str     x19, [x1]

    // Zero the symbol buffer
    mov     x20, x0                     // x20 = sym buffer (saved)
    mov     x1, #0
    mov     x2, #INT_SYM_SIZE
    mul     x2, x19, x2
    bl      _memset_custom

    // -----------------------------------------------------------------------
    // Allocate string table: estimate max size as sym_count * 64 + 1
    // The +1 is for the mandatory null byte at offset 0.
    // -----------------------------------------------------------------------
    mov     x0, x19
    lsl     x0, x0, #6                 // sym_count * 64
    add     x0, x0, #1                 // +1 for leading null
    bl      _malloc
    cbz     x0, Lmbs_error

    adrp    x1, _macho_strtab@PAGE
    add     x1, x1, _macho_strtab@PAGEOFF
    str     x0, [x1]

    // String table offset 0 must be a null byte
    strb    wzr, [x0]
    // Current string table write position = 1
    adrp    x1, _macho_strtab_size@PAGE
    add     x1, x1, _macho_strtab_size@PAGEOFF
    mov     x2, #1
    str     x2, [x1]

    // -----------------------------------------------------------------------
    // Initialize the category write indices for pass 2
    // Locals start at index 0
    // Defined externals start at index num_locals
    // Undefined externals start at index num_locals + num_defined_ext
    // -----------------------------------------------------------------------
    adrp    x0, _macho_num_locals@PAGE
    add     x0, x0, _macho_num_locals@PAGEOFF
    ldr     x1, [x0]                   // x1 = num_locals

    adrp    x0, _macho_num_defined_ext@PAGE
    add     x0, x0, _macho_num_defined_ext@PAGEOFF
    ldr     x2, [x0]                   // x2 = num_defined_ext

    // Store write cursors
    adrp    x0, _mbs_local_idx@PAGE
    add     x0, x0, _mbs_local_idx@PAGEOFF
    str     xzr, [x0]                  // local cursor = 0

    adrp    x0, _mbs_defext_idx@PAGE
    add     x0, x0, _mbs_defext_idx@PAGEOFF
    str     x1, [x0]                   // defext cursor = num_locals

    add     x3, x1, x2                 // num_locals + num_defined_ext
    adrp    x0, _mbs_undef_idx@PAGE
    add     x0, x0, _mbs_undef_idx@PAGEOFF
    str     x3, [x0]                   // undef cursor = num_locals + num_defined_ext

    // -----------------------------------------------------------------------
    // Pass 2: Iterate symbols again and populate the output arrays
    // -----------------------------------------------------------------------
    adrp    x0, _mbs_populate_callback@PAGE
    add     x0, x0, _mbs_populate_callback@PAGEOFF
    bl      _sym_iterate

    b       Lmbs_done

Lmbs_empty:
    // No symbols — set empty state
    adrp    x0, _macho_sym_count@PAGE
    add     x0, x0, _macho_sym_count@PAGEOFF
    str     xzr, [x0]

    adrp    x0, _macho_strtab_size@PAGE
    add     x0, x0, _macho_strtab_size@PAGEOFF
    mov     x1, #1                     // just the leading null byte
    str     x1, [x0]

    // Allocate a 1-byte strtab with a null byte
    mov     x0, #1
    bl      _malloc
    cbz     x0, Lmbs_error
    strb    wzr, [x0]
    adrp    x1, _macho_strtab@PAGE
    add     x1, x1, _macho_strtab@PAGEOFF
    str     x0, [x1]

    b       Lmbs_done

Lmbs_error:
    adrp    x0, _macho_err_malloc@PAGE
    add     x0, x0, _macho_err_malloc@PAGEOFF
    bl      _error_exit

Lmbs_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


// =============================================================================
// _mbs_count_callback — Callback for Pass 1 of _macho_build_symtab
//   Called via _sym_iterate. x0 = symbol_entry_ptr
//   Classifies symbol and increments the appropriate counter.
//
// Symbol entry layout (from symtab.s):
//   offset  0: name_ptr   (8 bytes)
//   offset  8: name_len   (8 bytes)
//   offset 16: value      (8 bytes)
//   offset 24: section    (4 bytes) — 0 = __text, 1 = __data
//   offset 28: flags      (4 bytes) — bit 0: defined, bit 1: global
// =============================================================================
.p2align 2
_mbs_count_callback:
    // Leaf-like — no calls, just increments globals
    ldr     w1, [x0, #28]              // w1 = flags
    tbnz    w1, #1, Lmcc_global       // bit 1 set = global

    // Local symbol (not global)
    adrp    x2, _macho_num_locals@PAGE
    add     x2, x2, _macho_num_locals@PAGEOFF
    ldr     x3, [x2]
    add     x3, x3, #1
    str     x3, [x2]
    ret

Lmcc_global:
    tbnz    w1, #0, Lmcc_defined_ext  // bit 0 set = defined

    // Undefined external
    adrp    x2, _macho_num_undef_ext@PAGE
    add     x2, x2, _macho_num_undef_ext@PAGEOFF
    ldr     x3, [x2]
    add     x3, x3, #1
    str     x3, [x2]
    ret

Lmcc_defined_ext:
    // Defined external
    adrp    x2, _macho_num_defined_ext@PAGE
    add     x2, x2, _macho_num_defined_ext@PAGEOFF
    ldr     x3, [x2]
    add     x3, x3, #1
    str     x3, [x2]
    ret


// =============================================================================
// _mbs_populate_callback — Callback for Pass 2 of _macho_build_symtab
//   Called via _sym_iterate. x0 = symbol_entry_ptr
//   Writes the symbol's nlist_64 data into the correct slot and updates
//   the string table.
//
// Our internal symbol format (32 bytes output):
//   offset 0:  strx (4 bytes)    — offset into string table
//   offset 4:  type (1 byte)     — N_SECT|N_EXT, N_UNDF|N_EXT, etc.
//   offset 5:  sect (1 byte)     — section ordinal (1=text, 2=data, 0=undef)
//   offset 6:  desc (2 bytes)    — 0
//   offset 8:  value (8 bytes)   — offset within section
//   offset 16: reserved (16 bytes)
// =============================================================================
.p2align 2
_mbs_populate_callback:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                     // x19 = symbol entry ptr

    // Read symbol entry fields
    ldr     x20, [x19, #0]             // x20 = name_ptr
    ldr     x21, [x19, #8]             // x21 = name_len
    ldr     w1, [x19, #28]             // w1  = flags

    // -----------------------------------------------------------------------
    // Determine category and pick the write cursor
    // -----------------------------------------------------------------------
    tbnz    w1, #1, Lmpc_global

    // Local symbol
    adrp    x2, _mbs_local_idx@PAGE
    add     x2, x2, _mbs_local_idx@PAGEOFF
    b       Lmpc_get_idx

Lmpc_global:
    tbnz    w1, #0, Lmpc_defined_ext

    // Undefined external
    adrp    x2, _mbs_undef_idx@PAGE
    add     x2, x2, _mbs_undef_idx@PAGEOFF
    b       Lmpc_get_idx

Lmpc_defined_ext:
    // Defined external
    adrp    x2, _mbs_defext_idx@PAGE
    add     x2, x2, _mbs_defext_idx@PAGEOFF

Lmpc_get_idx:
    ldr     x3, [x2]                   // x3 = current write index
    mov     x22, x2                     // x22 = cursor address (to increment later)

    // -----------------------------------------------------------------------
    // Store the nlist_index in the original symbol entry (at offset 40)
    // so relocation entries can reference the correct output index
    // -----------------------------------------------------------------------
    str     w3, [x19, #40]

    // -----------------------------------------------------------------------
    // Compute output slot address: _macho_syms + index * INT_SYM_SIZE
    // -----------------------------------------------------------------------
    adrp    x4, _macho_syms@PAGE
    add     x4, x4, _macho_syms@PAGEOFF
    ldr     x4, [x4]                   // x4 = sym buffer base
    mov     x5, #INT_SYM_SIZE
    madd    x4, x3, x5, x4             // x4 = &output_sym[index]

    // -----------------------------------------------------------------------
    // Append name to string table, get strx
    // -----------------------------------------------------------------------
    adrp    x5, _macho_strtab@PAGE
    add     x5, x5, _macho_strtab@PAGEOFF
    ldr     x6, [x5]                   // x6 = strtab base

    adrp    x7, _macho_strtab_size@PAGE
    add     x7, x7, _macho_strtab_size@PAGEOFF
    ldr     x8, [x7]                   // x8 = current strtab offset (= strx for this sym)

    // Copy name bytes: dst = strtab + offset, src = name_ptr, len = name_len
    add     x0, x6, x8                 // dst
    mov     x1, x20                     // src = name_ptr
    mov     x2, x21                     // len = name_len
    // Save registers across call
    stp     x4, x8, [sp, #-16]!        // push output_slot, strx
    bl      _memcpy_custom
    ldp     x4, x8, [sp], #16          // pop output_slot, strx

    // Write null terminator after name
    adrp    x5, _macho_strtab@PAGE
    add     x5, x5, _macho_strtab@PAGEOFF
    ldr     x6, [x5]
    add     x9, x8, x21                // offset + name_len
    strb    wzr, [x6, x9]              // null terminator

    // Update strtab size: offset + name_len + 1
    add     x9, x9, #1
    adrp    x7, _macho_strtab_size@PAGE
    add     x7, x7, _macho_strtab_size@PAGEOFF
    str     x9, [x7]

    // -----------------------------------------------------------------------
    // Fill output symbol entry (INT_SYM_SIZE = 32 bytes)
    // -----------------------------------------------------------------------
    // strx (4 bytes at offset 0)
    str     w8, [x4, #0]

    // Determine n_type and n_sect
    ldr     w1, [x19, #28]             // reload flags
    ldr     w10, [x19, #24]            // section (0=text, 1=data)

    tbnz    w1, #0, Lmpc_is_defined

    // Undefined symbol: n_type = N_UNDF | N_EXT, n_sect = 0
    mov     w11, #(N_UNDF | N_EXT)
    strb    w11, [x4, #4]              // n_type
    strb    wzr, [x4, #5]              // n_sect = 0 (NO_SECT)
    b       Lmpc_write_rest

Lmpc_is_defined:
    // Defined symbol
    // n_sect: section + 1 (1 = __text, 2 = __data)
    add     w12, w10, #1               // n_sect = section + 1

    tbnz    w1, #1, Lmpc_defined_global

    // Local defined: n_type = N_SECT
    mov     w11, #N_SECT
    strb    w11, [x4, #4]
    strb    w12, [x4, #5]
    b       Lmpc_write_rest

Lmpc_defined_global:
    // Global defined: n_type = N_SECT | N_EXT
    mov     w11, #(N_SECT | N_EXT)
    strb    w11, [x4, #4]
    strb    w12, [x4, #5]

Lmpc_write_rest:
    // desc (2 bytes at offset 6) = 0
    strh    wzr, [x4, #6]

    // value (8 bytes at offset 8) = symbol value
    ldr     x13, [x19, #16]            // entry->value
    str     x13, [x4, #8]

    // Zero the reserved bytes (offsets 16-31)
    stp     xzr, xzr, [x4, #16]

    // -----------------------------------------------------------------------
    // Increment the write cursor
    // -----------------------------------------------------------------------
    ldr     x3, [x22]
    add     x3, x3, #1
    str     x3, [x22]

    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


// =============================================================================
// _macho_emit — Write the complete Mach-O object file
//   x0 = output file descriptor (already opened by caller)
//   Returns: x0 = 0 on success, -1 on error
//
// Strategy: allocate a 1MB buffer, build the entire file in memory,
// then write it all at once.
// =============================================================================
.p2align 2
_macho_emit:
    stp     x29, x30, [sp, #-112]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]
    stp     x23, x24, [sp, #48]
    stp     x25, x26, [sp, #64]
    stp     x27, x28, [sp, #80]

    mov     x19, x0                     // x19 = output fd

    // -----------------------------------------------------------------------
    // Load all sizes we need for layout computation
    // -----------------------------------------------------------------------
    adrp    x0, _macho_text_size@PAGE
    add     x0, x0, _macho_text_size@PAGEOFF
    ldr     x20, [x0]                  // x20 = text_size

    adrp    x0, _macho_data_size@PAGE
    add     x0, x0, _macho_data_size@PAGEOFF
    ldr     x21, [x0]                  // x21 = data_size

    adrp    x0, _macho_reloc_count@PAGE
    add     x0, x0, _macho_reloc_count@PAGEOFF
    ldr     x22, [x0]                  // x22 = reloc_count

    adrp    x0, _macho_sym_count@PAGE
    add     x0, x0, _macho_sym_count@PAGEOFF
    ldr     x23, [x0]                  // x23 = sym_count

    adrp    x0, _macho_strtab_size@PAGE
    add     x0, x0, _macho_strtab_size@PAGEOFF
    ldr     x24, [x0]                  // x24 = strtab_size

    // -----------------------------------------------------------------------
    // Compute file layout offsets
    //
    // headers_end = MACH_HEADER_SIZE + TOTAL_CMDS_SIZE = 32 + 360 = 392
    //
    // text_offset = headers_end (already 4-byte aligned since 392 = 98*4)
    // data_offset = text_offset + text_size, aligned to 8-byte boundary
    // reloc_offset = data_offset + data_size, aligned to 4-byte boundary
    // symtab_offset = reloc_offset + reloc_count * 8
    // strtab_offset = symtab_offset + sym_count * 16
    // total_size = strtab_offset + strtab_size
    // -----------------------------------------------------------------------

    // text_offset
    mov     x25, #(MACH_HEADER_SIZE + TOTAL_CMDS_SIZE)  // x25 = text_offset = 392

    // data_offset = align8(text_offset + text_size)
    add     x26, x25, x20              // text_offset + text_size
    add     x26, x26, #7
    and     x26, x26, #~7              // x26 = data_offset (8-byte aligned)

    // reloc_offset = align4(data_offset + data_size)
    add     x27, x26, x21              // data_offset + data_size
    add     x27, x27, #3
    and     x27, x27, #~3              // x27 = reloc_offset (4-byte aligned)

    // symtab_offset = reloc_offset + reloc_count * RELOC_INFO_SIZE
    mov     x0, #RELOC_INFO_SIZE
    madd    x28, x22, x0, x27          // x28 = symtab_offset

    // strtab_offset = symtab_offset + sym_count * NLIST_SIZE
    mov     x0, #NLIST_SIZE
    mul     x1, x23, x0
    add     x1, x28, x1                // x1 = strtab_offset
    // Save strtab_offset in stack scratch space
    str     x1, [sp, #96]              // sp+96 = strtab_offset

    // total_size = strtab_offset + strtab_size
    add     x2, x1, x24                // x2 = total file size
    str     x2, [sp, #104]             // sp+104 = total_size

    // -----------------------------------------------------------------------
    // Allocate output buffer
    // -----------------------------------------------------------------------
    mov     x0, x2                      // size = total_size
    bl      _malloc
    cbz     x0, Lme_error_malloc

    // Save buffer pointer — we use a stack slot since we ran out of
    // callee-saved registers
    // Actually, let's reuse sp scratch. We still have x19 free (fd saved).
    // We'll use the buffer pointer a lot, so keep it in a stack slot.
    // But let's re-think register usage:
    //   x19 = fd
    //   x20 = text_size
    //   x21 = data_size
    //   x22 = reloc_count
    //   x23 = sym_count
    //   x24 = strtab_size
    //   x25 = text_offset
    //   x26 = data_offset
    //   x27 = reloc_offset
    //   x28 = symtab_offset
    //   sp+96  = strtab_offset
    //   sp+104 = total_size
    // We need buf_ptr. Let's store fd in stack and use x19 for buf.
    str     x19, [sp, #-16]!           // push fd
    mov     x19, x0                     // x19 = buf_ptr

    // Zero the entire output buffer
    mov     x0, x19                     // dst
    mov     x1, #0                      // value
    ldr     x2, [sp, #104+16]          // total_size (adjusted for push)
    bl      _memset_custom

    // -----------------------------------------------------------------------
    // Write mach_header_64 (32 bytes at offset 0)
    // -----------------------------------------------------------------------
    // magic (4 bytes)
    mov     w0, #0xFACF
    movk    w0, #0xFEED, lsl #16       // MH_MAGIC_64 = 0xFEEDFACF
    str     w0, [x19, #0]

    // cputype (4 bytes)
    mov     w0, #0x000C
    movk    w0, #0x0100, lsl #16       // CPU_TYPE_ARM64 = 0x0100000C
    str     w0, [x19, #4]

    // cpusubtype (4 bytes) = 0
    str     wzr, [x19, #8]

    // filetype (4 bytes) = MH_OBJECT = 1
    mov     w0, #MH_OBJECT
    str     w0, [x19, #12]

    // ncmds (4 bytes) = 4
    mov     w0, #NUM_LOAD_CMDS
    str     w0, [x19, #16]

    // sizeofcmds (4 bytes) = TOTAL_CMDS_SIZE
    mov     w0, #TOTAL_CMDS_SIZE
    str     w0, [x19, #20]

    // flags (4 bytes) = MH_SUBSECTIONS_VIA_SYMBOLS
    mov     w0, #MH_SUBSECTIONS_VIA_SYMBOLS
    str     w0, [x19, #24]

    // reserved (4 bytes) = 0
    str     wzr, [x19, #28]

    // -----------------------------------------------------------------------
    // Write LC_SEGMENT_64 (72 bytes at offset 32)
    // -----------------------------------------------------------------------
    add     x9, x19, #MACH_HEADER_SIZE // x9 = ptr to segment command

    // cmd = LC_SEGMENT_64
    mov     w0, #LC_SEGMENT_64
    str     w0, [x9, #0]

    // cmdsize = LC_SEG_TOTAL_SIZE (72 + 2*80 = 232)
    mov     w0, #LC_SEG_TOTAL_SIZE
    str     w0, [x9, #4]

    // segname[16] = "" (empty for MH_OBJECT)
    // Already zeroed by memset

    // vmaddr = 0 (offset 24)
    str     xzr, [x9, #24]

    // vmsize = text_size + data_size (round up to 8-byte align)
    add     x0, x20, x21               // text + data
    add     x0, x0, #7
    and     x0, x0, #~7
    str     x0, [x9, #32]              // vmsize

    // fileoff = text_offset (where section content starts)
    str     x25, [x9, #40]             // fileoff

    // filesize = data_offset + data_size - text_offset
    add     x0, x26, x21               // data_offset + data_size
    sub     x0, x0, x25                // - text_offset
    str     x0, [x9, #48]              // filesize

    // maxprot = 7 (rwx)
    mov     w0, #7
    str     w0, [x9, #56]

    // initprot = 7 (rwx)
    mov     w0, #7
    str     w0, [x9, #60]

    // nsects = 2
    mov     w0, #2
    str     w0, [x9, #64]

    // flags = 0
    str     wzr, [x9, #68]

    // -----------------------------------------------------------------------
    // Write section_64 __text (80 bytes at offset 32 + 72 = 104)
    // -----------------------------------------------------------------------
    add     x9, x19, #(MACH_HEADER_SIZE + SEGMENT_CMD_SIZE)  // offset 104

    // sectname = "__text" (16 bytes, null-padded)
    adrp    x0, _sectname_text@PAGE
    add     x0, x0, _sectname_text@PAGEOFF
    mov     x1, x9                      // dst
    mov     x2, #6                      // "__text" is 6 bytes
    // Write the 6 bytes then rest is zero from memset
    ldrb    w3, [x0, #0]
    strb    w3, [x1, #0]
    ldrb    w3, [x0, #1]
    strb    w3, [x1, #1]
    ldrb    w3, [x0, #2]
    strb    w3, [x1, #2]
    ldrb    w3, [x0, #3]
    strb    w3, [x1, #3]
    ldrb    w3, [x0, #4]
    strb    w3, [x1, #4]
    ldrb    w3, [x0, #5]
    strb    w3, [x1, #5]

    // segname = "__TEXT" (16 bytes at offset +16)
    adrp    x0, _segname_TEXT@PAGE
    add     x0, x0, _segname_TEXT@PAGEOFF
    add     x1, x9, #16
    ldrb    w3, [x0, #0]
    strb    w3, [x1, #0]
    ldrb    w3, [x0, #1]
    strb    w3, [x1, #1]
    ldrb    w3, [x0, #2]
    strb    w3, [x1, #2]
    ldrb    w3, [x0, #3]
    strb    w3, [x1, #3]
    ldrb    w3, [x0, #4]
    strb    w3, [x1, #4]
    ldrb    w3, [x0, #5]
    strb    w3, [x1, #5]

    // addr = 0 (offset +32)
    str     xzr, [x9, #32]

    // size = text_size (offset +40)
    str     x20, [x9, #40]

    // offset = text_offset (offset +48)
    str     w25, [x9, #48]

    // align = 2 (2^2 = 4-byte alignment) (offset +52)
    mov     w0, #2
    str     w0, [x9, #52]

    // reloff = reloc_offset (offset +56)
    str     w27, [x9, #56]

    // nreloc = reloc_count (offset +60)
    str     w22, [x9, #60]

    // flags = S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS (offset +64)
    mov     w0, #S_ATTR_SOME_INSTRUCTIONS       // 0x400
    movk    w0, #0x8000, lsl #16                 // | 0x80000000
    str     w0, [x9, #64]

    // reserved1, reserved2, reserved3 = 0 (offsets +68, +72, +76)
    // Already zeroed

    // -----------------------------------------------------------------------
    // Write section_64 __data (80 bytes at offset 104 + 80 = 184)
    // -----------------------------------------------------------------------
    add     x9, x19, #(MACH_HEADER_SIZE + SEGMENT_CMD_SIZE + SECTION_SIZE)  // offset 184

    // sectname = "__data" (16 bytes)
    adrp    x0, _sectname_data@PAGE
    add     x0, x0, _sectname_data@PAGEOFF
    mov     x1, x9
    ldrb    w3, [x0, #0]
    strb    w3, [x1, #0]
    ldrb    w3, [x0, #1]
    strb    w3, [x1, #1]
    ldrb    w3, [x0, #2]
    strb    w3, [x1, #2]
    ldrb    w3, [x0, #3]
    strb    w3, [x1, #3]
    ldrb    w3, [x0, #4]
    strb    w3, [x1, #4]
    ldrb    w3, [x0, #5]
    strb    w3, [x1, #5]

    // segname = "__DATA" (16 bytes at offset +16)
    adrp    x0, _segname_DATA@PAGE
    add     x0, x0, _segname_DATA@PAGEOFF
    add     x1, x9, #16
    ldrb    w3, [x0, #0]
    strb    w3, [x1, #0]
    ldrb    w3, [x0, #1]
    strb    w3, [x1, #1]
    ldrb    w3, [x0, #2]
    strb    w3, [x1, #2]
    ldrb    w3, [x0, #3]
    strb    w3, [x1, #3]
    ldrb    w3, [x0, #4]
    strb    w3, [x1, #4]
    ldrb    w3, [x0, #5]
    strb    w3, [x1, #5]

    // addr = text_size (data starts after text in vm) (offset +32)
    // For MH_OBJECT with sections at vmaddr 0, __data addr = text_size aligned
    add     x0, x20, #7
    and     x0, x0, #~7               // align text_size to 8 for data vmaddr
    str     x0, [x9, #32]

    // size = data_size (offset +40)
    str     x21, [x9, #40]

    // offset = data_offset (offset +48)
    str     w26, [x9, #48]

    // align = 3 (2^3 = 8-byte alignment) (offset +52)
    mov     w0, #3
    str     w0, [x9, #52]

    // reloff = 0 (no data relocations for now) (offset +56)
    str     wzr, [x9, #56]

    // nreloc = 0 (offset +60)
    str     wzr, [x9, #60]

    // flags = S_REGULAR = 0 (offset +64)
    str     wzr, [x9, #64]

    // reserved1, reserved2, reserved3 = 0
    // Already zeroed

    // -----------------------------------------------------------------------
    // Write LC_BUILD_VERSION (24 bytes at offset 32 + 232 = 264)
    // -----------------------------------------------------------------------
    mov     x9, #(MACH_HEADER_SIZE + LC_SEG_TOTAL_SIZE)
    add     x9, x19, x9                // x9 = ptr to build version cmd

    // cmd = LC_BUILD_VERSION
    mov     w0, #LC_BUILD_VERSION
    str     w0, [x9, #0]

    // cmdsize = 24 (no tool entries)
    mov     w0, #BUILD_VER_CMD_SIZE
    str     w0, [x9, #4]

    // platform = PLATFORM_MACOS = 1
    mov     w0, #PLATFORM_MACOS
    str     w0, [x9, #8]

    // minos = macOS 14.0.0 = 0x000E0000
    mov     w0, #0x0000
    movk    w0, #0x000E, lsl #16
    str     w0, [x9, #12]

    // sdk = 0 (unspecified)
    str     wzr, [x9, #16]

    // ntools = 0
    str     wzr, [x9, #20]

    // -----------------------------------------------------------------------
    // Write LC_SYMTAB (24 bytes at offset 264 + 24 = 288)
    // -----------------------------------------------------------------------
    mov     x9, #(MACH_HEADER_SIZE + LC_SEG_TOTAL_SIZE + BUILD_VER_CMD_SIZE)
    add     x9, x19, x9

    // cmd = LC_SYMTAB
    mov     w0, #LC_SYMTAB
    str     w0, [x9, #0]

    // cmdsize = 24
    mov     w0, #SYMTAB_CMD_SIZE
    str     w0, [x9, #4]

    // symoff = symtab_offset
    str     w28, [x9, #8]

    // nsyms = sym_count
    str     w23, [x9, #12]

    // stroff = strtab_offset
    ldr     x0, [sp, #96+16]           // strtab_offset (adjusted for push)
    str     w0, [x9, #16]

    // strsize = strtab_size
    str     w24, [x9, #20]

    // -----------------------------------------------------------------------
    // Write LC_DYSYMTAB (80 bytes at offset 288 + 24 = 312)
    // -----------------------------------------------------------------------
    mov     x9, #(MACH_HEADER_SIZE + LC_SEG_TOTAL_SIZE + BUILD_VER_CMD_SIZE + SYMTAB_CMD_SIZE)
    add     x9, x19, x9

    // cmd = LC_DYSYMTAB
    mov     w0, #LC_DYSYMTAB
    str     w0, [x9, #0]

    // cmdsize = 80
    mov     w0, #DYSYMTAB_CMD_SIZE
    str     w0, [x9, #4]

    // ilocalsym = 0
    str     wzr, [x9, #8]

    // nlocalsym = num_locals
    adrp    x0, _macho_num_locals@PAGE
    add     x0, x0, _macho_num_locals@PAGEOFF
    ldr     x1, [x0]
    str     w1, [x9, #12]

    // iextdefsym = num_locals
    str     w1, [x9, #16]

    // nextdefsym = num_defined_ext
    adrp    x0, _macho_num_defined_ext@PAGE
    add     x0, x0, _macho_num_defined_ext@PAGEOFF
    ldr     x2, [x0]
    str     w2, [x9, #20]

    // iundefsym = num_locals + num_defined_ext
    add     w3, w1, w2
    str     w3, [x9, #24]

    // nundefsym = num_undef_ext
    adrp    x0, _macho_num_undef_ext@PAGE
    add     x0, x0, _macho_num_undef_ext@PAGEOFF
    ldr     x4, [x0]
    str     w4, [x9, #28]

    // Remaining fields (tocoff, ntoc, modtaboff, nmodtab, extrefsymoff,
    //   nextrefsyms, indirectsymoff, nindirectsyms, extreloff, nextrel,
    //   locreloff, nlocrel) = 0
    // Already zeroed by memset

    // -----------------------------------------------------------------------
    // Copy __text section content into buffer at text_offset
    // -----------------------------------------------------------------------
    cbz     x20, Lme_skip_text        // skip if text_size == 0

    add     x0, x19, x25               // dst = buf + text_offset
    adrp    x1, _macho_text_buf@PAGE
    add     x1, x1, _macho_text_buf@PAGEOFF
    ldr     x1, [x1]                   // src = text buffer
    mov     x2, x20                     // len = text_size
    bl      _memcpy_custom

Lme_skip_text:

    // -----------------------------------------------------------------------
    // Copy __data section content into buffer at data_offset
    // -----------------------------------------------------------------------
    cbz     x21, Lme_skip_data        // skip if data_size == 0

    add     x0, x19, x26               // dst = buf + data_offset
    adrp    x1, _macho_data_buf@PAGE
    add     x1, x1, _macho_data_buf@PAGEOFF
    ldr     x1, [x1]                   // src = data buffer
    mov     x2, x21                     // len = data_size
    bl      _memcpy_custom

Lme_skip_data:

    // -----------------------------------------------------------------------
    // Write relocation entries at reloc_offset
    //
    // Convert from our internal 16-byte format to Mach-O relocation_info (8 bytes):
    //   int32_t r_address;
    //   uint32_t r_info = (r_symbolnum & 0x00FFFFFF)
    //                   | ((r_pcrel & 1) << 24)
    //                   | ((r_length & 3) << 25)
    //                   | ((r_extern & 1) << 27)
    //                   | ((r_type & 0xF) << 28)
    // -----------------------------------------------------------------------
    cbz     x22, Lme_skip_relocs      // skip if reloc_count == 0

    adrp    x0, _macho_relocs@PAGE
    add     x0, x0, _macho_relocs@PAGEOFF
    ldr     x10, [x0]                  // x10 = internal reloc array base

    add     x11, x19, x27              // x11 = output ptr (buf + reloc_offset)
    mov     x12, x22                    // x12 = remaining count

Lme_reloc_loop:
    cbz     x12, Lme_skip_relocs

    // Read internal reloc entry (24 bytes)
    ldr     w0, [x10, #0]              // r_address
    ldr     x1, [x10, #8]             // sym_entry_ptr (8 bytes)
    ldr     w1, [x1, #40]             // nlist_index from symbol entry
    ldr     w2, [x10, #16]            // type
    ldr     w3, [x10, #20]            // flags

    // Write r_address
    str     w0, [x11, #0]

    // Pack r_info from sym_index, type, and flags
    // flags bits: 0=pcrel, 1=extern, 4-5=length
    and     w4, w1, #0x00FFFFFF        // r_symbolnum (24 bits)

    // Extract pcrel (bit 0 of flags)
    and     w5, w3, #1
    lsl     w5, w5, #24                // pcrel << 24

    // Extract length (bits 4-5 of flags)
    ubfx    w6, w3, #4, #2            // extract bits 4-5
    lsl     w6, w6, #25                // length << 25

    // Extract extern (bit 1 of flags)
    ubfx    w7, w3, #1, #1            // extract bit 1
    lsl     w7, w7, #27                // extern << 27

    // r_type (4 bits)
    and     w8, w2, #0xF
    lsl     w8, w8, #28                // type << 28

    // Combine into r_info
    orr     w4, w4, w5
    orr     w4, w4, w6
    orr     w4, w4, w7
    orr     w4, w4, w8

    // Write r_info
    str     w4, [x11, #4]

    // Advance pointers
    add     x10, x10, #INT_RELOC_SIZE  // next internal entry (16 bytes)
    add     x11, x11, #RELOC_INFO_SIZE // next output entry (8 bytes)
    sub     x12, x12, #1
    b       Lme_reloc_loop

Lme_skip_relocs:

    // -----------------------------------------------------------------------
    // Write symbol table (nlist_64 entries) at symtab_offset
    //
    // Our internal format (32 bytes) -> nlist_64 (16 bytes):
    //   offset 0: strx (4)   -> n_strx (4)
    //   offset 4: type (1)   -> n_type (1)
    //   offset 5: sect (1)   -> n_sect (1)
    //   offset 6: desc (2)   -> n_desc (2)
    //   offset 8: value (8)  -> n_value (8)
    // -----------------------------------------------------------------------
    cbz     x23, Lme_skip_symtab      // skip if sym_count == 0

    adrp    x0, _macho_syms@PAGE
    add     x0, x0, _macho_syms@PAGEOFF
    ldr     x10, [x0]                  // x10 = internal sym array base

    add     x11, x19, x28              // x11 = output ptr (buf + symtab_offset)
    mov     x12, x23                    // x12 = remaining count

Lme_sym_loop:
    cbz     x12, Lme_skip_symtab

    // Read internal sym entry and write nlist_64
    // n_strx (4 bytes)
    ldr     w0, [x10, #0]
    str     w0, [x11, #0]

    // n_type (1 byte)
    ldrb    w0, [x10, #4]
    strb    w0, [x11, #4]

    // n_sect (1 byte)
    ldrb    w0, [x10, #5]
    strb    w0, [x11, #5]

    // n_desc (2 bytes)
    ldrh    w0, [x10, #6]
    strh    w0, [x11, #6]

    // n_value (8 bytes)
    ldr     x0, [x10, #8]
    str     x0, [x11, #8]

    // Advance
    add     x10, x10, #INT_SYM_SIZE     // next internal entry (32 bytes)
    add     x11, x11, #NLIST_SIZE        // next output entry (16 bytes)
    sub     x12, x12, #1
    b       Lme_sym_loop

Lme_skip_symtab:

    // -----------------------------------------------------------------------
    // Copy string table at strtab_offset
    // -----------------------------------------------------------------------
    cbz     x24, Lme_skip_strtab      // skip if strtab_size == 0

    ldr     x0, [sp, #96+16]           // strtab_offset (adjusted for push)
    add     x0, x19, x0                // dst = buf + strtab_offset
    adrp    x1, _macho_strtab@PAGE
    add     x1, x1, _macho_strtab@PAGEOFF
    ldr     x1, [x1]                   // src = strtab buffer
    mov     x2, x24                     // len = strtab_size
    bl      _memcpy_custom

Lme_skip_strtab:

    // -----------------------------------------------------------------------
    // Write the entire buffer to the output file descriptor
    // -----------------------------------------------------------------------
    ldr     x0, [sp]                    // fd (saved on stack)
    mov     x1, x19                     // buf = output buffer
    ldr     x2, [sp, #104+16]          // total_size (adjusted for push)
    bl      _write_all
    mov     x9, x0                      // save return value

    // -----------------------------------------------------------------------
    // Free the output buffer
    // -----------------------------------------------------------------------
    mov     x0, x19
    bl      _free

    // Check write result
    cmp     x9, #0
    b.lt    Lme_error_write

    // Success
    add     sp, sp, #16                 // pop saved fd
    mov     x0, #0
    b       Lme_done

Lme_error_malloc:
    adrp    x0, _macho_err_malloc@PAGE
    add     x0, x0, _macho_err_malloc@PAGEOFF
    bl      _error_exit

Lme_error_write:
    add     sp, sp, #16                 // pop saved fd
    mov     x0, #-1

Lme_done:
    ldr     x28, [sp, #88]             // Restore x28 from its proper slot
    ldr     x27, [sp, #80]
    ldp     x25, x26, [sp, #64]
    ldp     x23, x24, [sp, #48]
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #112
    ret


// =============================================================================
// _write_all — Write all bytes to fd, handling partial writes
//   x0 = fd, x1 = buf, x2 = total_len
//   Returns: x0 = 0 on success, -1 on error
// =============================================================================
.p2align 2
_write_all:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]
    stp     x21, x22, [sp, #32]

    mov     x19, x0                     // x19 = fd
    mov     x20, x1                     // x20 = current buf ptr
    mov     x21, x2                     // x21 = remaining bytes

Lwa_loop:
    cbz     x21, Lwa_success           // all bytes written

    mov     x0, x19                     // fd
    mov     x1, x20                     // buf
    mov     x2, x21                     // len
    bl      _write

    // Check for error
    cmp     x0, #0
    b.le    Lwa_error                  // write returned 0 or negative = error

    // Advance buffer and decrement remaining
    add     x20, x20, x0               // buf += bytes_written
    sub     x21, x21, x0               // remaining -= bytes_written
    b       Lwa_loop

Lwa_success:
    mov     x0, #0
    b       Lwa_done

Lwa_error:
    mov     x0, #-1

Lwa_done:
    ldp     x21, x22, [sp, #32]
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


// =============================================================================
// DATA SECTION — Global variables and string constants
// =============================================================================
.section __DATA,__data

// ---------------------------------------------------------------------------
// Input buffer pointers and sizes (set by the assembler before calling emit)
// ---------------------------------------------------------------------------
.p2align 3
_macho_text_buf:
    .quad 0                             // pointer to text section bytes
_macho_text_size:
    .quad 0                             // size of text section
_macho_data_buf:
    .quad 0                             // pointer to data section bytes
_macho_data_size:
    .quad 0                             // size of data section

// ---------------------------------------------------------------------------
// Internal relocation array
// ---------------------------------------------------------------------------
_macho_relocs:
    .quad 0                             // pointer to relocation entry array
_macho_reloc_count:
    .quad 0                             // number of relocation entries
_macho_reloc_cap:
    .quad 0                             // capacity of relocation array

// ---------------------------------------------------------------------------
// Symbol table output (built by _macho_build_symtab)
// ---------------------------------------------------------------------------
_macho_syms:
    .quad 0                             // pointer to symbol info array
_macho_sym_count:
    .quad 0                             // number of symbols

// ---------------------------------------------------------------------------
// String table output (built by _macho_build_symtab)
// ---------------------------------------------------------------------------
_macho_strtab:
    .quad 0                             // pointer to string table buffer
_macho_strtab_size:
    .quad 0                             // size of string table

// ---------------------------------------------------------------------------
// Symbol category counts (for LC_DYSYMTAB)
// ---------------------------------------------------------------------------
_macho_num_locals:
    .quad 0                             // local symbols count
_macho_num_defined_ext:
    .quad 0                             // defined external symbols count
_macho_num_undef_ext:
    .quad 0                             // undefined external symbols count

// ---------------------------------------------------------------------------
// Write cursors for _macho_build_symtab pass 2
// ---------------------------------------------------------------------------
_mbs_local_idx:
    .quad 0
_mbs_defext_idx:
    .quad 0
_mbs_undef_idx:
    .quad 0

// ---------------------------------------------------------------------------
// Section and segment name constants
// ---------------------------------------------------------------------------
_sectname_text:
    .ascii "__text\0\0\0\0\0\0\0\0\0\0" // 16 bytes, null-padded
_segname_TEXT:
    .ascii "__TEXT\0\0\0\0\0\0\0\0\0\0"  // 16 bytes, null-padded
_sectname_data:
    .ascii "__data\0\0\0\0\0\0\0\0\0\0"  // 16 bytes, null-padded
_segname_DATA:
    .ascii "__DATA\0\0\0\0\0\0\0\0\0\0"  // 16 bytes, null-padded

// ---------------------------------------------------------------------------
// Error messages
// ---------------------------------------------------------------------------
_macho_err_malloc:
    .asciz "macho: failed to allocate memory"
_macho_err_write:
    .asciz "macho: failed to write output file"

// .subsections_via_symbols
