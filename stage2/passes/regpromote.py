#!/usr/bin/env python3
"""Register promotion + copy propagation for AArch64 assembly.

Transforms naive stack-based code into register-optimized code:
1. Map stack slots [x29, #N] to callee-saved registers x19-x26
2. Replace ldr/str with direct register usage via copy propagation
3. Eliminate redundant mov instructions
"""

import sys
import re
from collections import defaultdict

# Registers we can use for promotion
PROMO_REGS = [f'x{i}' for i in range(19, 27)]  # x19-x26

def analyze_slots(lines):
    """Find all stack slot accesses and count usage."""
    counts = defaultdict(int)
    slot_re = re.compile(r'\[x29,\s*#(0x[0-9a-fA-F]+|\d+)\]')
    for line in lines:
        for m in slot_re.finditer(line):
            offset = int(m.group(1), 0)
            if offset >= 16:
                counts[offset] += 1
    return counts

def assign_slots(counts):
    """Map most-used slots to callee-saved registers."""
    sorted_slots = sorted(counts.items(), key=lambda x: -x[1])
    mapping = {}
    for i, (slot, count) in enumerate(sorted_slots):
        if i >= len(PROMO_REGS) or count < 2:
            break
        mapping[slot] = PROMO_REGS[i]
    return mapping

def optimize_block(lines, slot_map):
    """Optimize a basic block with register promotion and copy propagation.

    Tracks: copies[reg] = what register's value `reg` currently holds.
    E.g. after `mov x9, x19`, copies['x9'] = 'x19'
    """
    result = []
    copies = {}  # reg -> source reg (copy propagation)

    def resolve(reg):
        """Get the "real" register through copy chain."""
        seen = set()
        r = reg
        while r in copies and r not in seen:
            seen.add(r)
            r = copies[r]
        return r

    def invalidate(reg):
        """Invalidate all copy entries involving reg."""
        copies.pop(reg, None)
        # Also invalidate anything that was a copy of reg
        to_remove = [k for k, v in copies.items() if v == reg]
        for k in to_remove:
            del copies[k]

    for line in lines:
        stripped = line.strip()

        # Skip empty lines, comments, directives
        if not stripped or stripped.startswith('//') or stripped.startswith('.'):
            result.append(line)
            continue

        # Parse: ldr xT, [x29, #N]
        m = re.match(r'(\s*)ldr\s+(x\d+),\s*\[x29,\s*#(0x[0-9a-fA-F]+|\d+)\]', stripped)
        if m:
            indent, target, off_str = m.groups()
            offset = int(off_str, 0)
            if offset in slot_map:
                promo_reg = slot_map[offset]
                if target == promo_reg:
                    # Already in the right register, eliminate
                    continue
                # Track that target is a copy of promo_reg
                invalidate(target)
                copies[target] = promo_reg
                # Don't emit the mov yet — copy propagation may eliminate it
                result.append(f'{indent}mov {target}, {promo_reg}\n')
                continue
            else:
                invalidate(target)
                result.append(line)
                continue

        # Parse: str xT, [x29, #N]
        m = re.match(r'(\s*)str\s+(x\d+),\s*\[x29,\s*#(0x[0-9a-fA-F]+|\d+)\]', stripped)
        if m:
            indent, source, off_str = m.groups()
            offset = int(off_str, 0)
            if offset in slot_map:
                promo_reg = slot_map[offset]
                # Resolve: if source is a copy of something, use the original
                real_src = resolve(source)
                if real_src == promo_reg:
                    # Already in the right register, eliminate
                    continue
                result.append(f'{indent}mov {promo_reg}, {real_src}\n')
                invalidate(promo_reg)
                copies[promo_reg] = real_src
                continue
            else:
                result.append(line)
                continue

        # Parse: str xR, [sp, #-16]! (push) — eliminate if matched with pop
        if re.match(r'\s*str\s+x\d+,\s*\[sp,\s*#-16\]!', stripped):
            result.append(line)  # Keep for now, eliminate in cleanup pass
            continue

        # Parse: ldr xR, [sp], #16 (pop) — eliminate if previous was matching push
        if re.match(r'\s*ldr\s+x\d+,\s*\[sp\],\s*#16', stripped):
            # Check if previous instruction was matching push
            for i in range(len(result) - 1, -1, -1):
                prev = result[i].strip()
                if not prev:
                    continue
                pm = re.match(r'\s*str\s+(x\d+),\s*\[sp,\s*#-16\]!', prev)
                if pm:
                    lm = re.match(r'\s*ldr\s+(x\d+),\s*\[sp\],\s*#16', stripped)
                    if lm and pm.group(1) == lm.group(1):
                        result[i] = ''  # Remove push
                        # Don't add pop
                        break
                    else:
                        result.append(line)
                        break
                else:
                    result.append(line)
                    break
            continue

        # Parse: arithmetic/logic instructions — apply copy propagation to operands
        # Pattern: op xD, xA, xB or op xD, xA, #imm
        m = re.match(r'(\s*)(add|sub|mul|madd|msub|sdiv|udiv|and|orr|eor|lsl|lsr|asr)\s+(x\d+),\s*(x\d+),\s*(x\d+|#-?\d+)', stripped)
        if m:
            indent, op, rd, ra, rb = m.groups()
            real_ra = resolve(ra)
            if rb.startswith('x'):
                real_rb = resolve(rb)
            else:
                real_rb = rb

            # Determine the actual destination
            real_rd = rd
            invalidate(rd)

            result.append(f'{indent}{op} {real_rd}, {real_ra}, {real_rb}\n')
            continue

        # cmp xA, xB or cmp xA, #imm
        m = re.match(r'(\s*)cmp\s+(x\d+),\s*(x\d+|#-?\d+)', stripped)
        if m:
            indent, ra, rb = m.groups()
            real_ra = resolve(ra)
            if rb.startswith('x'):
                real_rb = resolve(rb)
            else:
                real_rb = rb
            result.append(f'{indent}cmp {real_ra}, {real_rb}\n')
            continue

        # cset xD, cond
        m = re.match(r'(\s*)cset\s+(x\d+),\s*(\w+)', stripped)
        if m:
            indent, rd, cond = m.groups()
            invalidate(rd)
            result.append(f'{indent}cset {rd}, {cond}\n')
            continue

        # cbnz/cbz xR, label
        m = re.match(r'(\s*)(cbnz|cbz)\s+(x\d+),\s*(\S+)', stripped)
        if m:
            indent, op, reg, label = m.groups()
            real_reg = resolve(reg)
            result.append(f'{indent}{op} {real_reg}, {label}\n')
            continue

        # mov xD, xS
        m = re.match(r'(\s*)mov\s+(x\d+),\s*(x\d+)', stripped)
        if m:
            indent, rd, rs = m.groups()
            real_rs = resolve(rs)
            if rd == real_rs:
                continue  # Identity mov, eliminate
            invalidate(rd)
            copies[rd] = real_rs
            result.append(f'{indent}mov {rd}, {real_rs}\n')
            continue

        # mov xD, #imm
        m = re.match(r'(\s*)mov\s+(x\d+),\s*(#.+)', stripped)
        if m:
            indent, rd, imm = m.groups()
            invalidate(rd)
            result.append(line)
            continue

        # movz, movk
        m = re.match(r'(\s*)(movz|movk)\s+(x\d+)', stripped)
        if m:
            invalidate(m.group(3))
            result.append(line)
            continue

        # msub, sdiv with 3+ register operands
        m = re.match(r'(\s*)(msub|sdiv)\s+(x\d+),\s*(x\d+),\s*(x\d+),?\s*(x\d+)?', stripped)
        if m:
            indent, op = m.group(1), m.group(2)
            regs = [m.group(i) for i in range(3, 7) if m.group(i)]
            resolved = [resolve(r) for r in regs]
            invalidate(resolved[0])
            result.append(f'{indent}{op} {", ".join(resolved)}\n')
            continue

        # bl — invalidate caller-saved registers
        if re.match(r'\s*bl\s+', stripped):
            for r in [f'x{i}' for i in range(19)]:
                copies.pop(r, None)
            result.append(line)
            continue

        # b label (unconditional) — clear copies
        if re.match(r'\s*b\s+\.\w+', stripped):
            copies.clear()
            result.append(line)
            continue

        # ldr x0, ... (return value load)
        m = re.match(r'(\s*)ldr\s+(x0),\s*\[x29,\s*#(0x[0-9a-fA-F]+|\d+)\]', stripped)
        if m:
            indent, target, off_str = m.groups()
            offset = int(off_str, 0)
            if offset in slot_map:
                promo_reg = slot_map[offset]
                result.append(f'{indent}mov x0, {promo_reg}\n')
                continue

        # mov x0, xR (return value)
        m = re.match(r'(\s*)mov\s+x0,\s*(x\d+)', stripped)
        if m:
            indent, rs = m.groups()
            real_rs = resolve(rs)
            if real_rs == 'x0':
                continue
            result.append(f'{indent}mov x0, {real_rs}\n')
            continue

        # Default: keep the line, invalidate any written register
        result.append(line)

    return [l for l in result if l]  # Remove empty entries

def process(lines):
    """Process entire assembly file."""
    text = ''.join(lines)

    # Analyze all stack slots
    slot_counts = analyze_slots(lines)
    slot_map = assign_slots(slot_counts)

    if not slot_map:
        return lines

    used_regs = sorted(set(slot_map.values()), key=lambda r: int(r[1:]))

    # Split into sections at labels for block-level processing
    blocks = []
    current_block = []
    for line in lines:
        stripped = line.strip()
        if stripped.endswith(':') and not stripped.startswith('//'):
            if current_block:
                blocks.append(current_block)
            current_block = [line]
        else:
            current_block.append(line)
    if current_block:
        blocks.append(current_block)

    # Optimize each block
    result = []
    for block in blocks:
        optimized = optimize_block(block, slot_map)
        result.extend(optimized)

    # Add callee-saved register saves after "mov x29, sp"
    final = []
    for i, line in enumerate(result):
        final.append(line)
        if line.strip() == 'mov x29, sp':
            for j in range(0, len(used_regs), 2):
                if j + 1 < len(used_regs):
                    final.append(f'    stp {used_regs[j]}, {used_regs[j+1]}, [sp, #-16]!\n')
                else:
                    final.append(f'    str {used_regs[j]}, [sp, #-16]!\n')

    # Add restores before "ldp x29, x30"
    final2 = []
    for i, line in enumerate(final):
        if 'ldp x29, x30' in line.strip():
            for j in range(len(used_regs) - 1, -1, -2):
                if j >= 1:
                    final2.append(f'    ldp {used_regs[j-1]}, {used_regs[j]}, [sp], #16\n')
                else:
                    final2.append(f'    ldr {used_regs[j]}, [sp], #16\n')
        final2.append(line)

    # Final cleanup: eliminate redundant mov xA, xA
    cleaned = []
    for line in final2:
        m = re.match(r'\s*mov\s+(x\d+),\s*(x\d+)\s*$', line.strip())
        if m and m.group(1) == m.group(2):
            continue
        cleaned.append(line)

    return cleaned

def main():
    lines = sys.stdin.readlines()
    result = process(lines)
    sys.stdout.writelines(result)

if __name__ == '__main__':
    main()
