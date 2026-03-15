#!/usr/bin/env python3
"""Assembly-level peephole optimizer for AArch64 assembly.

Reads AArch64 assembly (produced by our IR compiler's naive codegen) from stdin
and applies peephole optimizations to eliminate redundant instructions.

The codegen is extremely naive — every value goes to/from the stack. This pass
cleans up the worst redundancies without needing a full register allocator.

Patterns optimized:
  1. Redundant load after store (same address) -> mov or eliminate
  2. Redundant store-load chain (same reg, same address) -> eliminate load
  3. Compare with zero: mov x10, #0 / cmp x9, x10 -> cmp x9, #0
  4. Compare with small immediate (12-bit): mov + cmp -> cmp with imm
  5. Sub with immediate: mov + sub -> sub with imm
  6. Add with immediate: mov + add -> add with imm
  7. Redundant save/restore around branch: str x9,[sp,#-16]! / ldr x9,[sp],#16
  8. Identity moves: mov x9, x9 -> eliminate
  9. Add/sub with zero immediate -> eliminate
"""
import sys
import re


# ---- Instruction parsing helpers ----

# Matches an instruction line: (indent, opcode, operands)
INSTR_RE = re.compile(r'^(\s+)([\w.]+)\s+(.*)$')

# Matches a label line
LABEL_RE = re.compile(r'^[.\w]+:')

# str xA, [base, #offset]
STR_MEM_RE = re.compile(r'str\s+(x\d+),\s*\[([^]]+)\]')
# ldr xA, [base, #offset]
LDR_MEM_RE = re.compile(r'ldr\s+(x\d+),\s*\[([^]]+)\]')

# mov xA, #IMM
MOV_IMM_RE = re.compile(r'mov\s+(x\d+),\s*#(-?\d+)')

# cmp xA, xB
CMP_REG_RE = re.compile(r'cmp\s+(x\d+),\s*(x\d+)')

# add xA, xB, xC (register form)
ADD_REG_RE = re.compile(r'add\s+(x\d+),\s*(x\d+),\s*(x\d+)')

# sub xA, xB, xC (register form)
SUB_REG_RE = re.compile(r'sub\s+(x\d+),\s*(x\d+),\s*(x\d+)')

# mov xA, xB (register-to-register)
MOV_REG_RE = re.compile(r'mov\s+(x\d+),\s*(x\d+)$')

# str xA, [sp, #-16]!  (pre-index push)
PUSH_RE = re.compile(r'str\s+(x\d+),\s*\[sp,\s*#-16\]!')
# ldr xA, [sp], #16  (post-index pop)
POP_RE = re.compile(r'ldr\s+(x\d+),\s*\[sp\],\s*#16')

# mul xA, xB, xC (register form)
MUL_REG_RE = re.compile(r'mul\s+(x\d+),\s*(x\d+),\s*(x\d+)')


def is_label(line):
    """Check if a line is a label (basic block boundary)."""
    stripped = line.strip()
    return bool(LABEL_RE.match(stripped))


def is_branch_or_call(line):
    """Check if a line is a branch or call (control flow boundary)."""
    stripped = line.strip()
    for prefix in ('b ', 'b.', 'bl ', 'br ', 'blr ', 'cbnz ', 'cbz ',
                    'ret', 'svc'):
        if stripped.startswith(prefix):
            return True
    if stripped == 'ret':
        return True
    return False


def is_boundary(line):
    """Check if a line is a basic block boundary (label, branch, call)."""
    return is_label(line) or is_branch_or_call(line)


def parse_instr(line):
    """Parse instruction into (indent, opcode, operands) or None."""
    m = INSTR_RE.match(line.rstrip())
    if m:
        return m.group(1), m.group(2), m.group(3)
    return None


def stripped_instr(line):
    """Return the instruction part of a line, stripped of whitespace."""
    return line.strip()


def fits_in_12_bits(imm):
    """Check if an immediate value fits in 12-bit unsigned range (0..4095)."""
    return 0 <= imm <= 4095


def pass_redundant_store_load(lines):
    """Pattern 1 & 2: Eliminate redundant load after store to same address.

    str xA, [addr]  /  ldr xB, [addr]
    -> if A==B: eliminate the ldr
    -> if A!=B: replace ldr with mov xB, xA
    """
    changed = False
    result = []
    i = 0
    while i < len(lines):
        if i + 1 < len(lines):
            s1 = stripped_instr(lines[i])
            s2 = stripped_instr(lines[i + 1])

            m_str = STR_MEM_RE.match(s1)
            m_ldr = LDR_MEM_RE.match(s2)

            if m_str and m_ldr:
                str_reg, str_addr = m_str.group(1), m_str.group(2)
                ldr_reg, ldr_addr = m_ldr.group(1), m_ldr.group(2)

                # Normalize whitespace in address for comparison
                str_addr_norm = re.sub(r'\s+', '', str_addr)
                ldr_addr_norm = re.sub(r'\s+', '', ldr_addr)

                if str_addr_norm == ldr_addr_norm:
                    # Keep the store
                    result.append(lines[i])
                    if str_reg == ldr_reg:
                        # Same register: eliminate the load entirely
                        pass
                    else:
                        # Different register: replace load with mov
                        indent = '    '
                        p = parse_instr(lines[i + 1])
                        if p:
                            indent = p[0]
                        result.append(f'{indent}mov {ldr_reg}, {str_reg}\n')
                    i += 2
                    changed = True
                    continue

        result.append(lines[i])
        i += 1
    return result, changed


def pass_compare_with_immediate(lines):
    """Patterns 3 & 4: mov xR, #IMM / cmp xA, xR -> cmp xA, #IMM.

    Only if IMM fits in 12-bit unsigned range.
    """
    changed = False
    result = []
    i = 0
    while i < len(lines):
        if i + 1 < len(lines) and not is_boundary(lines[i]):
            s1 = stripped_instr(lines[i])
            s2 = stripped_instr(lines[i + 1])

            m_mov = MOV_IMM_RE.match(s1)
            m_cmp = CMP_REG_RE.match(s2)

            if m_mov and m_cmp:
                mov_reg = m_mov.group(1)
                imm = int(m_mov.group(2))
                cmp_reg1 = m_cmp.group(1)
                cmp_reg2 = m_cmp.group(2)

                if cmp_reg2 == mov_reg and fits_in_12_bits(abs(imm)):
                    # Replace: eliminate the mov, change cmp to use immediate
                    indent = '    '
                    p = parse_instr(lines[i + 1])
                    if p:
                        indent = p[0]
                    if imm >= 0:
                        result.append(f'{indent}cmp {cmp_reg1}, #{imm}\n')
                    else:
                        # cmp with negative -> cmn with positive
                        result.append(f'{indent}cmn {cmp_reg1}, #{-imm}\n')
                    i += 2
                    changed = True
                    continue

        result.append(lines[i])
        i += 1
    return result, changed


def pass_add_sub_with_immediate(lines):
    """Patterns 5 & 6: mov xR, #IMM / {add,sub} xD, xS, xR -> {add,sub} xD, xS, #IMM.

    Only if IMM fits in 12-bit unsigned range.
    """
    changed = False
    result = []
    i = 0
    while i < len(lines):
        if i + 1 < len(lines) and not is_boundary(lines[i]):
            s1 = stripped_instr(lines[i])
            s2 = stripped_instr(lines[i + 1])

            m_mov = MOV_IMM_RE.match(s1)

            if m_mov:
                mov_reg = m_mov.group(1)
                imm = int(m_mov.group(2))

                # Check for add
                m_add = ADD_REG_RE.match(s2)
                if m_add and m_add.group(3) == mov_reg and fits_in_12_bits(imm) and imm >= 0:
                    indent = '    '
                    p = parse_instr(lines[i + 1])
                    if p:
                        indent = p[0]
                    result.append(f'{indent}add {m_add.group(1)}, {m_add.group(2)}, #{imm}\n')
                    i += 2
                    changed = True
                    continue

                # Check for sub
                m_sub = SUB_REG_RE.match(s2)
                if m_sub and m_sub.group(3) == mov_reg and fits_in_12_bits(imm) and imm >= 0:
                    indent = '    '
                    p = parse_instr(lines[i + 1])
                    if p:
                        indent = p[0]
                    result.append(f'{indent}sub {m_sub.group(1)}, {m_sub.group(2)}, #{imm}\n')
                    i += 2
                    changed = True
                    continue

                # Check for mul by small power of 2 -> shift left
                m_mul = MUL_REG_RE.match(s2)
                if m_mul and m_mul.group(3) == mov_reg and imm > 0 and (imm & (imm - 1)) == 0:
                    import math
                    shift = int(math.log2(imm))
                    indent = '    '
                    p = parse_instr(lines[i + 1])
                    if p:
                        indent = p[0]
                    result.append(f'{indent}lsl {m_mul.group(1)}, {m_mul.group(2)}, #{shift}\n')
                    i += 2
                    changed = True
                    continue

        result.append(lines[i])
        i += 1
    return result, changed


def pass_redundant_push_pop(lines):
    """Pattern 7: str xA, [sp, #-16]! / ldr xA, [sp], #16 -> eliminate both.

    This pattern appears around br_cond in the codegen.
    """
    changed = False
    result = []
    i = 0
    while i < len(lines):
        if i + 1 < len(lines):
            s1 = stripped_instr(lines[i])
            s2 = stripped_instr(lines[i + 1])

            m_push = PUSH_RE.match(s1)
            m_pop = POP_RE.match(s2)

            if m_push and m_pop:
                push_reg = m_push.group(1)
                pop_reg = m_pop.group(1)
                if push_reg == pop_reg:
                    # Eliminate both instructions
                    i += 2
                    changed = True
                    continue

        result.append(lines[i])
        i += 1
    return result, changed


def pass_identity_moves(lines):
    """Pattern 8: mov xA, xA -> eliminate."""
    changed = False
    result = []
    for line in lines:
        s = stripped_instr(line)
        m = MOV_REG_RE.match(s)
        if m and m.group(1) == m.group(2):
            changed = True
            continue
        result.append(line)
    return result, changed


def pass_add_sub_zero(lines):
    """Eliminate add/sub with #0.

    add xA, xB, #0 -> mov xA, xB (or eliminate if xA == xB)
    sub xA, xB, #0 -> mov xA, xB (or eliminate if xA == xB)
    """
    ADD_IMM_RE = re.compile(r'(add|sub)\s+(x\d+),\s*(x\d+),\s*#0\s*$')
    changed = False
    result = []
    for line in lines:
        s = stripped_instr(line)
        m = ADD_IMM_RE.match(s)
        if m:
            dst = m.group(2)
            src = m.group(3)
            if dst == src:
                # Eliminate entirely
                changed = True
                continue
            else:
                indent = '    '
                p = parse_instr(line)
                if p:
                    indent = p[0]
                result.append(f'{indent}mov {dst}, {src}\n')
                changed = True
                continue
        result.append(line)
    return result, changed


def pass_store_load_different_addr(lines):
    """Optimize chains like:
        str x9, [x29, #N]
        ldr x9, [x29, #M]    <- this is NOT redundant, different address

    But catch:
        str x9, [x29, #N]
        ldr x9, [x29, #N]
        str x9, [x29, #M]

    Where the load is redundant (x9 already has the value from the store).
    This is handled by pass_redundant_store_load, but we also want to catch
    the case where there's a str-ldr-str chain that copies a value:

        str x9, [x29, #72]
        ldr x9, [x29, #72]   <- redundant, x9 still has the value
        str x9, [x29, #24]

    The first two instructions are already handled by pass_redundant_store_load.
    This pass is a no-op — the pattern is already covered.
    """
    return lines, False


def optimize(text):
    """Apply all peephole optimization passes until fixed point."""
    lines = text.splitlines(keepends=True)

    # Ensure all lines end with newline
    lines = [l if l.endswith('\n') else l + '\n' for l in lines]

    passes = [
        ("redundant_push_pop", pass_redundant_push_pop),
        ("redundant_store_load", pass_redundant_store_load),
        ("compare_with_immediate", pass_compare_with_immediate),
        ("add_sub_with_immediate", pass_add_sub_with_immediate),
        ("identity_moves", pass_identity_moves),
        ("add_sub_zero", pass_add_sub_zero),
    ]

    iteration = 0
    max_iterations = 20  # Safety limit

    while iteration < max_iterations:
        any_changed = False
        for name, pass_fn in passes:
            lines, changed = pass_fn(lines)
            if changed:
                any_changed = True
        if not any_changed:
            break
        iteration += 1

    return ''.join(lines)


def main():
    text = sys.stdin.read()
    result = optimize(text)
    sys.stdout.write(result)


if __name__ == '__main__':
    main()
