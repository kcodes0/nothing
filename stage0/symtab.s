// symtab.s — Symbol table for the bootstrapped assembler
// AArch64 macOS (Apple Silicon)
// Calling convention: AAPCS64 (x0-x7 args, x0 return, x29/x30 frame pair, x18 reserved)
//
// The symbol table uses a hash table with 256 buckets and chaining.
// Each symbol entry is 64 bytes, heap-allocated via _malloc.
//
// Symbol entry layout (64 bytes):
//   offset  0: name_ptr   (8 bytes) — pointer to name string (NOT copied)
//   offset  8: name_len   (8 bytes) — length of name
//   offset 16: value      (8 bytes) — offset within section
//   offset 24: section    (4 bytes) — 0 = __text, 1 = __data
//   offset 28: flags      (4 bytes) — bit 0: defined, bit 1: global
//   offset 32: next       (8 bytes) — pointer to next entry in chain (0 = end)
//   offset 40: nlist_index(4 bytes) — index in output symbol table
//   offset 44: reserved   (20 bytes)
//
// Hash function: DJB2 — hash = 5381; hash = hash*33 + c; return hash & 0xFF

.section __TEXT,__text

// =============================================================================
// sym_init — Initialize the symbol table (zero all 256 buckets)
//   No args, no return value.
// =============================================================================
.globl _sym_init
.p2align 2
_sym_init:
    // Leaf function — zero 256 * 8 = 2048 bytes
    adrp    x0, _sym_buckets@PAGE
    add     x0, x0, _sym_buckets@PAGEOFF
    mov     x1, #256                // 256 buckets
.Lsi_loop:
    str     xzr, [x0], #8          // Zero one bucket
    subs    x1, x1, #1
    b.ne    .Lsi_loop
    ret


// =============================================================================
// sym_hash — Internal helper: compute DJB2 hash of a name
//   x0 = name_ptr, x1 = name_len
//   Returns: x0 = hash & 0xFF (bucket index)
// =============================================================================
.p2align 2
_sym_hash:
    // Leaf function
    mov     x2, #5381               // hash = 5381
    cbz     x1, .Lsh_done

    mov     x3, x0                  // x3 = walking pointer
    mov     x4, x1                  // x4 = remaining count

.Lsh_loop:
    ldrb    w5, [x3], #1            // c = *ptr++
    // hash = hash * 33 + c
    // hash * 33 = hash * 32 + hash = (hash << 5) + hash
    lsl     x6, x2, #5             // hash << 5
    add     x2, x6, x2             // hash * 33
    add     x2, x2, x5             // hash * 33 + c
    subs    x4, x4, #1
    b.ne    .Lsh_loop

.Lsh_done:
    and     x0, x2, #0xFF          // hash & 0xFF
    ret


// =============================================================================
// sym_add — Add a new symbol (or return existing if already present)
//   x0 = name_ptr, x1 = name_len
//   Returns: x0 = pointer to symbol entry
//
//   Hashes the name, scans the chain. If found, returns existing entry.
//   If not found, mallocs a 64-byte entry, initializes it, prepends to chain.
// =============================================================================
.globl _sym_add
.p2align 2
_sym_add:
    stp     x29, x30, [sp, #-64]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]    // x19 = name_ptr, x20 = name_len
    stp     x21, x22, [sp, #32]    // x21 = bucket index, x22 = bucket base addr

    mov     x19, x0                 // Save name_ptr
    mov     x20, x1                 // Save name_len

    // Compute hash
    bl      _sym_hash               // x0 = bucket index
    mov     x21, x0

    // Compute bucket address
    adrp    x22, _sym_buckets@PAGE
    add     x22, x22, _sym_buckets@PAGEOFF
    add     x22, x22, x21, lsl #3  // x22 = &buckets[hash] (pointer to bucket slot)

    // Walk the chain looking for a match
    ldr     x9, [x22]              // x9 = first entry in chain (or 0)

.Lsa_scan:
    cbz     x9, .Lsa_not_found     // End of chain — not found

    // Compare names: call _str_cmp(name_ptr, name_len, entry->name_ptr, entry->name_len)
    str     x9, [sp, #48]          // Save current entry pointer in scratch slot
    mov     x0, x19                 // our name_ptr
    mov     x1, x20                 // our name_len
    ldr     x2, [x9, #0]           // entry->name_ptr
    ldr     x3, [x9, #8]           // entry->name_len
    bl      _str_cmp

    ldr     x9, [sp, #48]          // Restore current entry pointer
    cbz     x0, .Lsa_found         // str_cmp returned 0 — match!

    // Follow chain
    ldr     x9, [x9, #32]          // x9 = entry->next
    b       .Lsa_scan

.Lsa_found:
    // x9 = existing entry
    mov     x0, x9
    b       .Lsa_return

.Lsa_not_found:
    // Allocate a new 64-byte entry
    mov     x0, #64
    bl      _malloc                 // x0 = new entry pointer

    // Zero the entire 64-byte entry
    // Use 8 stores of xzr to clear 64 bytes
    stp     xzr, xzr, [x0, #0]
    stp     xzr, xzr, [x0, #16]
    stp     xzr, xzr, [x0, #32]
    stp     xzr, xzr, [x0, #48]

    // Set name_ptr and name_len
    str     x19, [x0, #0]          // entry->name_ptr
    str     x20, [x0, #8]          // entry->name_len

    // Prepend to chain: entry->next = old head; bucket = entry
    ldr     x9, [x22]              // Old head of chain
    str     x9, [x0, #32]          // entry->next = old head
    str     x0, [x22]              // bucket[hash] = new entry

    // x0 already points to the new entry

.Lsa_return:
    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x29, x30, [sp], #64
    ret


// =============================================================================
// sym_lookup — Find a symbol by name
//   x0 = name_ptr, x1 = name_len
//   Returns: x0 = pointer to symbol entry, or 0 if not found
// =============================================================================
.globl _sym_lookup
.p2align 2
_sym_lookup:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]    // x19 = name_ptr, x20 = name_len

    mov     x19, x0                 // Save name_ptr
    mov     x20, x1                 // Save name_len

    // Compute hash
    bl      _sym_hash               // x0 = bucket index

    // Load chain head
    adrp    x2, _sym_buckets@PAGE
    add     x2, x2, _sym_buckets@PAGEOFF
    ldr     x9, [x2, x0, lsl #3]   // x9 = buckets[hash]

.Lsl_scan:
    cbz     x9, .Lsl_not_found     // End of chain

    // Compare names
    str     x9, [sp, #32]          // Save entry pointer in scratch slot
    mov     x0, x19
    mov     x1, x20
    ldr     x2, [x9, #0]           // entry->name_ptr
    ldr     x3, [x9, #8]           // entry->name_len
    bl      _str_cmp

    ldr     x9, [sp, #32]          // Restore entry pointer
    cbz     x0, .Lsl_found         // Match!

    ldr     x9, [x9, #32]          // entry->next
    b       .Lsl_scan

.Lsl_found:
    mov     x0, x9
    b       .Lsl_return

.Lsl_not_found:
    mov     x0, #0

.Lsl_return:
    ldp     x19, x20, [sp, #16]
    ldp     x29, x30, [sp], #48
    ret


// =============================================================================
// sym_define — Mark a symbol as defined with a value
//   x0 = symbol_entry_ptr, x1 = value (offset), x2 = section (0=text, 1=data)
//   Sets value, section, and defined flag (bit 0 of flags).
// =============================================================================
.globl _sym_define
.p2align 2
_sym_define:
    // Leaf function
    str     x1, [x0, #16]          // entry->value = x1
    str     w2, [x0, #24]          // entry->section = x2
    ldr     w3, [x0, #28]          // w3 = current flags
    orr     w3, w3, #1             // Set bit 0 (defined)
    str     w3, [x0, #28]          // entry->flags = w3
    ret


// =============================================================================
// sym_set_global — Mark a symbol as global
//   x0 = symbol_entry_ptr
//   Sets bit 1 of flags.
// =============================================================================
.globl _sym_set_global
.p2align 2
_sym_set_global:
    // Leaf function
    ldr     w1, [x0, #28]          // w1 = current flags
    orr     w1, w1, #2             // Set bit 1 (global)
    str     w1, [x0, #28]          // entry->flags = w1
    ret


// =============================================================================
// sym_is_defined — Check if symbol is defined
//   x0 = symbol_entry_ptr
//   Returns: x0 = 1 if defined, 0 if not
// =============================================================================
.globl _sym_is_defined
.p2align 2
_sym_is_defined:
    // Leaf function
    ldr     w1, [x0, #28]          // w1 = flags
    and     x0, x1, #1             // Isolate bit 0
    ret


// =============================================================================
// sym_is_global — Check if symbol is global
//   x0 = symbol_entry_ptr
//   Returns: x0 = 1 if global, 0 if not
// =============================================================================
.globl _sym_is_global
.p2align 2
_sym_is_global:
    // Leaf function
    ldr     w1, [x0, #28]          // w1 = flags
    ubfx    x0, x1, #1, #1         // Extract bit 1
    ret


// =============================================================================
// sym_count — Count total number of symbols across all buckets
//   No args
//   Returns: x0 = count
// =============================================================================
.globl _sym_count
.p2align 2
_sym_count:
    // Leaf function — walks all 256 buckets and their chains
    adrp    x1, _sym_buckets@PAGE
    add     x1, x1, _sym_buckets@PAGEOFF
    mov     x0, #0                  // x0 = count
    mov     x2, #256                // x2 = buckets remaining

.Lsc_bucket:
    ldr     x3, [x1], #8           // x3 = chain head, advance to next bucket
    // Walk chain
.Lsc_chain:
    cbz     x3, .Lsc_next_bucket   // End of chain
    add     x0, x0, #1             // count++
    ldr     x3, [x3, #32]          // x3 = entry->next
    b       .Lsc_chain

.Lsc_next_bucket:
    subs    x2, x2, #1
    b.ne    .Lsc_bucket

    ret


// =============================================================================
// sym_iterate — Iterate over all symbols, calling a callback for each
//   x0 = callback function pointer (called with x0 = symbol_entry_ptr)
//   Iterates all 256 buckets and their chains.
//   Must preserve callee-saved registers across callbacks.
// =============================================================================
.globl _sym_iterate
.p2align 2
_sym_iterate:
    stp     x29, x30, [sp, #-48]!
    mov     x29, sp
    stp     x19, x20, [sp, #16]    // x19 = callback, x20 = current entry
    stp     x21, x22, [sp, #32]    // x21 = bucket pointer, x22 = buckets remaining

    mov     x19, x0                 // Save callback pointer

    adrp    x21, _sym_buckets@PAGE
    add     x21, x21, _sym_buckets@PAGEOFF
    mov     x22, #256               // 256 buckets

.Lsit_bucket:
    ldr     x20, [x21], #8         // x20 = chain head, advance bucket pointer

.Lsit_chain:
    cbz     x20, .Lsit_next_bucket // End of chain

    // x20 is callee-saved so it survives the callback call.
    // After the call, we reload entry->next from x20.
    mov     x0, x20                 // arg0 = symbol entry pointer
    blr     x19                     // Call callback

    // x20 is callee-saved, so it survived the call
    ldr     x20, [x20, #32]        // x20 = entry->next (reload from preserved x20)
    b       .Lsit_chain

.Lsit_next_bucket:
    subs    x22, x22, #1
    b.ne    .Lsit_bucket

    ldp     x19, x20, [sp, #16]
    ldp     x21, x22, [sp, #32]
    ldp     x29, x30, [sp], #48
    ret


// =============================================================================
// Data: hash table bucket array — 256 pointers, zero-initialized
// =============================================================================
.zerofill __DATA,__bss,_sym_buckets,2048,3
