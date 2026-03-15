#!/usr/bin/env python3
"""Register allocation pass for AArch64 assembly.

Transforms the naive stack-based assembly produced by our IR compiler into
register-optimized assembly by eliminating redundant loads/stores within
basic blocks.

The IR compiler generates code where every value lives on the stack (frame
pointer-relative addressing via [x29, #N]). This pass tracks which registers
currently hold which stack slot values, eliminating loads when the value is
already in a register and removing stores that are redundant.

Algorithm (load elimination within basic blocks):
  Within each basic block (between labels/branches):
  1. cache = {}  # stack_offset -> register currently holding that value
  2. For each instruction:
     - str xT, [x29, #N]: update cache[N] = xT, invalidate stale entries
     - ldr xT, [x29, #N]: if N in cache, replace with mov or eliminate
     - Any write to xT: invalidate cache entries whose value == xT
     - bl: invalidate all caller-saved registers (x0-x18)
     - Labels: clear entire cache
  3. Push/pop patterns: str x9,[sp,#-16]! ... ldr x9,[sp],#16 are tracked
     and eliminated where possible.

Also applies:
  - Immediate folding: mov xR, #IMM + op xA, xB, xR -> op xA, xB, #IMM
  - Push/pop elimination for condition values
  - Identity move elimination: mov xA, xA -> delete
"""
import sys
import re
from collections import defaultdict


# ---- Regex patterns ----

# str xT, [x29, #N]  (frame-relative store)
FRAME_STR_RE = re.compile(r'^(\s+)str\s+(x\d+),\s*\[x29,\s*#(\d+)\](.*)$')

# ldr xT, [x29, #N]  (frame-relative load)
FRAME_LDR_RE = re.compile(r'^(\s+)ldr\s+(x\d+),\s*\[x29,\s*#(\d+)\](.*)$')

# str xT, [sp, #-16]!  (push)
PUSH_RE = re.compile(r'^(\s+)str\s+(x\d+),\s*\[sp,\s*#-16\]!(.*)$')

# ldr xT, [sp], #16  (pop)
POP_RE = re.compile(r'^(\s+)ldr\s+(x\d+),\s*\[sp\],\s*#16(.*)$')

# Label
LABEL_RE = re.compile(r'^[.\w]+:\s*$')

# mov xA, xB (register move)
MOV_REG_RE = re.compile(r'^(\s+)mov\s+(x\d+),\s*(x\d+)\s*(.*)$')

# mov xA, #IMM
MOV_IMM_RE = re.compile(r'^(\s+)mov\s+(x\d+),\s*#(-?\d+)\s*(.*)$')

# Instruction that writes to a destination register (first operand)
# Matches: add, sub, mul, sdiv, and, orr, eor, lsl, lsr, asr, cset, msub, madd, movz, movk
WRITE_DEST_RE = re.compile(
    r'^(\s+)(add|sub|mul|sdiv|and|orr|eor|lsl|lsr|asr|cset|msub|madd|movz|movk|ubfx|sbfx|sxtw|uxtw)\s+(x\d+|w\d+)'
)

# cmp instruction: cmp xA, xB or cmp xA, #IMM
CMP_RE = re.compile(r'^(\s+)cmp\s+(x\d+),\s*(x\d+|#-?\d+)(.*)$')

# add xD, xS, xR (three-register form)
ADD_REG_RE = re.compile(r'^(\s+)add\s+(x\d+),\s*(x\d+),\s*(x\d+)\s*(.*)$')

# sub xD, xS, xR (three-register form)
SUB_REG_RE = re.compile(r'^(\s+)sub\s+(x\d+),\s*(x\d+),\s*(x\d+)\s*(.*)$')

# Branch/call/ret
BRANCH_RE = re.compile(r'^\s+(b|b\.\w+|bl|blr|br|cbnz|cbz|ret|svc)\s')
RET_RE = re.compile(r'^\s+ret\s*$')

# stp/ldp for prologue/epilogue
STP_RE = re.compile(r'^(\s+)stp\s+')
LDP_RE = re.compile(r'^(\s+)ldp\s+')

# bl (function call)
BL_RE = re.compile(r'^\s+bl\s+')

# Any instruction (has leading whitespace and an opcode)
INSTR_RE = re.compile(r'^(\s+)([\w.]+)\s*(.*)')


def is_label(line):
    return bool(LABEL_RE.match(line.strip()))


def is_branch(line):
    s = line.strip()
    for prefix in ('b ', 'b.', 'bl ', 'br ', 'blr ', 'cbnz ', 'cbz ', 'ret', 'svc'):
        if s.startswith(prefix):
            return True
    if s == 'ret':
        return True
    return False


def is_call(line):
    return bool(BL_RE.match(line))


def get_dest_reg(line):
    """Get the destination register written by this instruction, or None."""
    s = line.strip()

    # mov xA, ... (both reg and imm)
    m = re.match(r'(mov|movz|movk)\s+(x\d+|w\d+)', s)
    if m:
        return m.group(2)

    # ldr xA, ...
    m = re.match(r'ldr\s+(x\d+|w\d+)', s)
    if m:
        return m.group(1)

    # cset xA, ...
    m = re.match(r'cset\s+(x\d+|w\d+)', s)
    if m:
        return m.group(1)

    # Arithmetic: add, sub, mul, sdiv, etc. - dest is first operand
    m = WRITE_DEST_RE.match(line)
    if m:
        return m.group(3)

    return None


def fits_12bit(imm):
    """Check if immediate fits in 12-bit unsigned (0..4095)."""
    return 0 <= imm <= 4095


class RegisterAllocator:
    """Performs load/store elimination within basic blocks."""

    def __init__(self):
        # cache: stack_offset (int) -> register name (str)
        # Tracks which register currently holds the value from each stack slot
        self.cache = {}
        # imm_cache: register name -> immediate value
        # Tracks mov xR, #IMM for folding
        self.imm_cache = {}
        # push_stack: list of (register, line_index) for push tracking
        self.push_stack = []

    def clear_cache(self):
        self.cache.clear()
        self.imm_cache.clear()

    def invalidate_reg(self, reg):
        """Invalidate all cache entries whose value is the given register."""
        # Remove from frame cache any entry mapping to this register
        to_remove = [off for off, r in self.cache.items() if r == reg]
        for off in to_remove:
            del self.cache[off]
        # Remove from imm cache
        self.imm_cache.pop(reg, None)

    def invalidate_caller_saved(self):
        """Invalidate all caller-saved registers (x0-x18) from caches."""
        caller_saved = {f'x{i}' for i in range(19)}
        to_remove = [off for off, r in self.cache.items() if r in caller_saved]
        for off in to_remove:
            del self.cache[off]
        for reg in list(self.imm_cache.keys()):
            if reg in caller_saved:
                del self.imm_cache[reg]

    def process_function(self, lines):
        """Process a complete function's assembly lines."""
        result = []
        self.clear_cache()
        self.push_stack = []

        i = 0
        while i < len(lines):
            line = lines[i]
            stripped = line.rstrip()

            # Labels: clear cache (values may arrive from different predecessors)
            if is_label(line):
                self.clear_cache()
                self.push_stack = []
                result.append(line)
                i += 1
                continue

            # Handle push: str xT, [sp, #-16]!
            m_push = PUSH_RE.match(stripped)
            if m_push:
                indent, reg, comment = m_push.group(1), m_push.group(2), m_push.group(3)
                # Record the push with the current result index
                self.push_stack.append((reg, len(result), i))
                result.append(line)  # tentatively keep it
                i += 1
                continue

            # Handle pop: ldr xT, [sp], #16
            m_pop = POP_RE.match(stripped)
            if m_pop:
                indent, pop_reg, comment = m_pop.group(1), m_pop.group(2), m_pop.group(3)
                if self.push_stack:
                    push_reg, push_result_idx, push_line_idx = self.push_stack.pop()
                    if push_reg == pop_reg:
                        # Check if any instruction between push and here clobbers pop_reg
                        # Look at all result lines from push_result_idx+1 to now
                        clobbered = False
                        for j in range(push_result_idx + 1, len(result)):
                            dest = get_dest_reg(result[j])
                            if dest == pop_reg:
                                clobbered = True
                                break
                        if not clobbered:
                            # Safe to eliminate both push and pop
                            # Remove the push from result
                            result[push_result_idx] = None  # mark for removal
                            # Skip the pop
                            i += 1
                            continue
                        else:
                            # push_reg was clobbered; the pop restores it.
                            # Can't eliminate. Keep the pop.
                            result.append(line)
                            i += 1
                            continue
                    else:
                        # Different registers - keep both
                        result.append(line)
                        i += 1
                        continue
                else:
                    result.append(line)
                    i += 1
                    continue

            # Handle frame store: str xT, [x29, #N]
            m_str = FRAME_STR_RE.match(stripped)
            if m_str:
                indent, reg, offset_str, comment = (
                    m_str.group(1), m_str.group(2),
                    m_str.group(3), m_str.group(4)
                )
                offset = int(offset_str)
                # Update cache: this stack slot now holds the value in reg
                self.cache[offset] = reg
                # Keep the store (needed for cross-block references)
                result.append(line)
                i += 1
                continue

            # Handle frame load: ldr xT, [x29, #N]
            m_ldr = FRAME_LDR_RE.match(stripped)
            if m_ldr:
                indent, reg, offset_str, comment = (
                    m_ldr.group(1), m_ldr.group(2),
                    m_ldr.group(3), m_ldr.group(4)
                )
                offset = int(offset_str)

                if offset in self.cache:
                    cached_reg = self.cache[offset]
                    if cached_reg == reg:
                        # Value already in this register - eliminate load
                        i += 1
                        continue
                    else:
                        # Value in a different register - replace with mov
                        # But first invalidate since we're writing to reg
                        self.invalidate_reg(reg)
                        self.cache[offset] = reg
                        # Copy imm_cache if source had it
                        if cached_reg in self.imm_cache:
                            self.imm_cache[reg] = self.imm_cache[cached_reg]
                        result.append(f'{indent}mov {reg}, {cached_reg}{comment}\n')
                        i += 1
                        continue
                else:
                    # Not in cache - keep the load, record in cache
                    self.invalidate_reg(reg)
                    self.cache[offset] = reg
                    result.append(line)
                    i += 1
                    continue

            # Handle mov xA, #IMM - track in imm_cache
            m_imm = MOV_IMM_RE.match(stripped)
            if m_imm:
                indent, reg, imm_str, comment = (
                    m_imm.group(1), m_imm.group(2),
                    m_imm.group(3), m_imm.group(4)
                )
                imm = int(imm_str)
                self.invalidate_reg(reg)
                self.imm_cache[reg] = imm
                result.append(line)
                i += 1
                continue

            # Handle calls: invalidate caller-saved registers
            if is_call(line):
                self.invalidate_caller_saved()
                self.push_stack = []
                result.append(line)
                i += 1
                continue

            # Handle branches: don't clear cache for fall-through after cbnz/cbz
            if is_branch(line):
                # Clear imm_cache since we're at a control flow point
                # but keep frame cache for fall-through path
                result.append(line)
                # Unconditional branches/ret: clear cache entirely
                s = line.strip()
                if s.startswith('b ') or s == 'ret' or s.startswith('ret '):
                    self.clear_cache()
                    self.push_stack = []
                i += 1
                continue

            # For any other instruction that writes a register, invalidate cache
            dest = get_dest_reg(line)
            if dest:
                self.invalidate_reg(dest)

            result.append(line)
            i += 1

        # Remove None entries (eliminated pushes)
        result = [l for l in result if l is not None]
        return result


def pass_immediate_folding(lines):
    """Fold mov xR, #IMM + op xA, xB, xR into op xA, xB, #IMM.

    Patterns:
      mov xR, #IMM + cmp xA, xR -> cmp xA, #IMM (if fits 12 bits)
      mov xR, #IMM + add xD, xS, xR -> add xD, xS, #IMM (if fits 12 bits)
      mov xR, #IMM + sub xD, xS, xR -> sub xD, xS, #IMM (if fits 12 bits)
    """
    changed = False
    result = []
    i = 0
    while i < len(lines):
        if i + 1 < len(lines):
            s1 = lines[i].strip()
            s2 = lines[i + 1].strip()

            m_imm = MOV_IMM_RE.match(lines[i].rstrip())
            if m_imm and not is_label(lines[i]):
                imm_reg = m_imm.group(2)
                imm_val = int(m_imm.group(3))
                indent = m_imm.group(1)

                # cmp xA, xR -> cmp xA, #IMM
                m_cmp = CMP_RE.match(lines[i + 1].rstrip())
                if m_cmp and m_cmp.group(3) == imm_reg and fits_12bit(abs(imm_val)):
                    indent2 = m_cmp.group(1)
                    cmp_src = m_cmp.group(2)
                    comment = m_cmp.group(4)
                    if imm_val >= 0:
                        result.append(f'{indent2}cmp {cmp_src}, #{imm_val}{comment}\n')
                    else:
                        result.append(f'{indent2}cmn {cmp_src}, #{-imm_val}{comment}\n')
                    i += 2
                    changed = True
                    continue

                # add xD, xS, xR -> add xD, xS, #IMM
                m_add = ADD_REG_RE.match(lines[i + 1].rstrip())
                if m_add and m_add.group(4) == imm_reg and fits_12bit(imm_val) and imm_val >= 0:
                    indent2 = m_add.group(1)
                    dst, src = m_add.group(2), m_add.group(3)
                    comment = m_add.group(5)
                    result.append(f'{indent2}add {dst}, {src}, #{imm_val}{comment}\n')
                    i += 2
                    changed = True
                    continue

                # sub xD, xS, xR -> sub xD, xS, #IMM
                m_sub = SUB_REG_RE.match(lines[i + 1].rstrip())
                if m_sub and m_sub.group(4) == imm_reg and fits_12bit(imm_val) and imm_val >= 0:
                    indent2 = m_sub.group(1)
                    dst, src = m_sub.group(2), m_sub.group(3)
                    comment = m_sub.group(5)
                    result.append(f'{indent2}sub {dst}, {src}, #{imm_val}{comment}\n')
                    i += 2
                    changed = True
                    continue

        result.append(lines[i])
        i += 1
    return result, changed


def pass_identity_moves(lines):
    """Eliminate mov xA, xA."""
    changed = False
    result = []
    for line in lines:
        m = MOV_REG_RE.match(line.rstrip())
        if m and m.group(2) == m.group(3):
            changed = True
            continue
        result.append(line)
    return result, changed


def pass_add_sub_zero(lines):
    """Eliminate add/sub with #0."""
    ADD_SUB_ZERO_RE = re.compile(r'^(\s+)(add|sub)\s+(x\d+),\s*(x\d+),\s*#0\s*(.*)$')
    changed = False
    result = []
    for line in lines:
        m = ADD_SUB_ZERO_RE.match(line.rstrip())
        if m:
            indent, op, dst, src, comment = m.groups()
            if dst == src:
                changed = True
                continue
            else:
                result.append(f'{indent}mov {dst}, {src}{comment}\n')
                changed = True
                continue
        result.append(line)
    return result, changed


def pass_dead_store_elimination(lines):
    """Eliminate stores to stack slots that are immediately overwritten.

    Pattern:
      str xA, [x29, #N]
      ... (no load of [x29, #N]) ...
      str xB, [x29, #N]
    -> eliminate the first store

    Only within basic blocks (between labels/branches).
    """
    # This is more complex - skip for now, the load elimination is the big win
    return lines, False


def optimize(text):
    """Apply all optimization passes."""
    lines = text.splitlines(keepends=True)
    lines = [l if l.endswith('\n') else l + '\n' for l in lines]

    # Pass 1: Register allocation (load/store elimination)
    allocator = RegisterAllocator()
    lines = allocator.process_function(lines)

    # Pass 2: Immediate folding (mov #IMM + op -> op #IMM)
    max_iters = 10
    for _ in range(max_iters):
        any_changed = False

        lines, changed = pass_immediate_folding(lines)
        any_changed |= changed

        lines, changed = pass_identity_moves(lines)
        any_changed |= changed

        lines, changed = pass_add_sub_zero(lines)
        any_changed |= changed

        if not any_changed:
            break

    return ''.join(lines)


def main():
    text = sys.stdin.read()
    result = optimize(text)
    sys.stdout.write(result)


if __name__ == '__main__':
    main()
