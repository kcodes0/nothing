# Project: Bootstrapped Language & Toolchain — From Nothing

## Philosophy

We are building a programming language and its entire compilation toolchain as
if modern compiler infrastructure does not exist. No LLVM. No GCC backend. No
borrowed code generators. Every layer is ours.

The guiding question: **how were programming languages made before programming
languages existed?** The answer is that each tool was built using only the tools
that came before it. An assembler was hand-assembled from machine code. A
compiler was written in assembly. A better compiler was written using the first
compiler. Each layer is scaffolding for the next.

We follow the same chain. We start at the bottom — raw machine code and
assembly — and build upward, one layer at a time. Each layer must be **fully
functional and testable on its own** before we begin the next. No forward
references to things that don't exist yet.

The target architecture is **AArch64 macOS (Apple Silicon)**. Mach-O binaries,
ARM64 instruction set, Apple's AAPCS64-based calling convention. We are making
real programs that the kernel can execute directly. We will link against
`libSystem.dylib` for syscalls (macOS does not guarantee a stable syscall ABI —
calling the kernel directly is undefined behavior on Darwin, so linking
libSystem is not a shortcut, it's the correct thing to do).

---

## The Bootstrap Chain

### Stage 0: The Assembler (written in AArch64 assembly, assembled with `as` once)

A minimal assembler that reads a text file of ARM64 assembly mnemonics and
outputs AArch64 machine code in a Mach-O 64 object file (linked with `ld` to
produce an executable).

ARM64 is ideal for a hand-built assembler: every instruction is exactly 4 bytes
wide with regular encoding fields. No variable-length encoding, no REX prefix
hell, no ModR/M byte. Encoding an instruction is a matter of ORing fixed
bitfields together.

Requirements:
- Support a small instruction subset:
  - Arithmetic: `add`, `sub`, `mul`, `madd`, `msub`, `neg`
  - Logic: `and`, `orr`, `eor`, `mvn`
  - Shift: `lsl`, `lsr`, `asr`
  - Compare: `cmp`, `cmn`, `tst`
  - Branch: `b`, `b.eq`, `b.ne`, `b.lt`, `b.gt`, `b.le`, `b.ge`, `bl`, `ret`,
    `cbz`, `cbnz`
  - Load/store: `ldr`, `str`, `ldrb`, `strb`, `ldp`, `stp`
  - Address: `adr`, `adrp`
  - Move: `mov`, `movz`, `movk`, `movn`
  - System: `svc`, `nop`
- Register operands: `x0`–`x30`, `sp`, `xzr` (64-bit); `w0`–`w30`, `wzr`
  (32-bit)
- Immediate operands, shifted immediates
- Addressing modes: `[xN]`, `[xN, #imm]`, `[xN, xM]`, `[xN, #imm]!` (pre-
  index), `[xN], #imm` (post-index)
- Labels and forward references (two-pass assembly)
- `.data` section for string literals and constants
- `.text` section for code
- Output a valid Mach-O 64-bit object file (or use the system linker `ld` to
  produce the final executable from a flat object)

Note on macOS specifics: Mach-O is more complex than ELF. The minimum viable
approach is to emit a relocatable object file (.o) with `__TEXT,__text` and
`__DATA,__data` sections, then let the system `ld` handle linking against
`libSystem.dylib` and producing the final executable. This is not cheating —
the linker is a system tool like the kernel, not a compiler component.

This is the foundation. Every tool after this is built using this assembler.
Once it works, we can optionally self-host: rewrite the assembler in its own
assembly language and assemble it with itself.

### Stage 1: The IR and IR Compiler (written in assembly using our Stage 0 assembler)

A simple intermediate representation and a program that compiles IR text files
into assembly (which Stage 0 then assembles into executables).

IR design principles:
- **SSA form** (Static Single Assignment): every variable is assigned exactly
  once. Use phi nodes at control flow join points.
- **Typed**: at minimum, `i64` (64-bit integer), `i8` (byte), `ptr` (pointer).
  We can add `i32`, `i16`, `f64` later.
- **Basic block structure**: code is organized into labeled basic blocks. Each
  block ends with exactly one terminator (branch, conditional branch, return).
- **Explicit memory model**: `load`, `store` for memory access. Stack
  allocation via `alloca`.
- **Minimal opcode set**:
  - Arithmetic: `add`, `sub`, `mul`, `div`, `mod`
  - Bitwise: `and`, `or`, `xor`, `shl`, `shr`
  - Comparison: `cmp_eq`, `cmp_ne`, `cmp_lt`, `cmp_gt`, `cmp_le`, `cmp_ge`
    (produce an `i8` 0 or 1)
  - Memory: `load`, `store`, `alloca`
  - Control flow: `br` (unconditional), `br_cond` (conditional), `ret`
  - Functions: `call`, `arg` (access function parameters)
  - Conversion: `zext`, `sext`, `trunc`, `ptrtoint`, `inttoptr`
  - Phi: `phi` (SSA join)
- **Text format**: human-readable, one instruction per line.

Example IR:
```
func @main() -> i64 {
entry:
  %x = add i64 10, 20
  %y = mul i64 %x, 3
  %cond = cmp_lt i64 %y, 100
  br_cond %cond, @then, @else

then:
  ret i64 %y

else:
  ret i64 0
}
```

The IR compiler reads this text, parses it into an in-memory graph, and emits
AArch64 assembly. Initial codegen can be extremely naive:
- Every virtual register maps to a stack slot
- Every operation loads operands from stack, computes, stores result to stack
- Function calls follow Apple's ARM64 ABI (x0–x7 for args, x0 for return
  value, x29 frame pointer, x30 link register, 16-byte stack alignment)

This will produce slow but **correct** code. Optimization comes later.

### Stage 2: Optimization Passes (written in IR or assembly)

Once the IR compiler works, we write optimization passes that transform IR
into better IR. Each pass is an IR -> IR function.

Priority order:
1. **mem2reg**: Promote `alloca`/`load`/`store` patterns into SSA registers.
   This is the single most important optimization — it's what makes SSA useful.
2. **Constant folding**: Evaluate operations on constants at compile time.
3. **Dead code elimination**: Remove instructions whose results are never used.
4. **Common subexpression elimination**: Reuse previously computed values.
5. **Peephole optimizations**: Pattern-match and simplify (e.g., `mul x, 2` →
   `shl x, 1`; `add x, 0` → `x`).

**This is where the agentic optimization loop applies.** Once passes exist,
an agent can:
- Reorder passes to find the best pipeline
- Tune thresholds and heuristics within passes
- Write new peephole rules
- Modify register allocation strategies in the codegen
- Measure the result on a benchmark suite of IR programs
- Keep improvements, discard regressions

The metric is: total execution time of the benchmark suite (lower is better),
with a secondary metric of total binary size.

### Stage 3: The Frontend (written using our IR)

A parser and compiler for our actual programming language, targeting our IR.
This is where language design happens — syntax, semantics, type system.

By this point we have a working IR compiler with optimization passes, so the
frontend's only job is: parse source text → emit IR. All the heavy lifting of
code generation is handled by the layers below.

Eventually, the language should be expressive enough to **rewrite the entire
toolchain in itself** — the assembler, the IR compiler, the optimization
passes, and the frontend. At that point the language is self-hosting and the
assembly scaffolding can be retired.

---

## Rules

1. **No LLVM, no GCC backend, no borrowed codegen.** Every byte of machine
   code comes from our toolchain.
2. **Each stage must fully work before the next begins.** No building stage 2
   on a broken stage 1.
3. **Test constantly.** Every stage gets a test suite. The assembler gets
   hand-verified binaries. The IR compiler gets programs with known outputs.
   The optimizer gets before/after IR comparisons.
4. **Correct first, fast later.** Naive codegen that produces right answers
   beats clever codegen that doesn't.
5. **We can use the system `as` and `ld` exactly once** — to bootstrap Stage
   0. After that, everything is built with our own tools. (We continue using
   `ld` to link against `libSystem.dylib`, as the linker is a system tool,
   not a compiler component.)
6. **Mach-O + macOS + AArch64.** One platform, no abstraction layers, no
   portability concerns. We can generalize later.
7. **Everything is plaintext.** IR is text. Assembly is text. Build scripts
   are shell scripts. No binary formats except the final Mach-O output.

---

## Agentic Optimization Setup (for Stage 2+)

Once the toolchain is functional through Stage 2, set up the autoresearch-style
loop:

- **Workspace**: the optimization pass source files + codegen
- **Eval harness**: compile and run a benchmark suite of 10-20 small IR
  programs (fibonacci, sorting, string manipulation, linked list traversal,
  matrix multiply, etc.)
- **Metric**: geometric mean of execution times across the suite, normalized
  to the unoptimized baseline
- **Time budget**: 5 minutes per experiment (compile the toolchain + run all
  benchmarks)
- **Agent loop**: read the current pass code → hypothesize an improvement →
  modify → build → benchmark → keep/discard → commit/revert → repeat

The agent is allowed to modify:
- Optimization pass logic and ordering
- Register allocator strategy
- Instruction selection patterns in codegen
- Peephole rules

The agent is NOT allowed to modify:
- The IR specification (opcodes, format)
- The assembler
- The test harness or benchmarks
- The Mach-O output format

This keeps the search space bounded while still giving the agent meaningful
room to improve codegen quality.
