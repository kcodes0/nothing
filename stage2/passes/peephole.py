#!/usr/bin/env python3
"""Peephole optimization pass for our IR."""
import sys
import re
import math

def peephole_optimize(lines):
    """Apply simple peephole optimizations."""
    result = []
    for line in lines:
        stripped = line.strip()
        new_line = line

        # mul %x, 1 -> (remove, replace uses with %x)  -- simplified: mul %x, 1 -> add %x, 0
        m = re.match(r'(\s*)(%\w+)\s*=\s*mul\s+(i\d+)\s+(%\w+),\s*1\s*$', stripped)
        if m:
            indent, name, typ, operand = m.groups()
            new_line = f'{indent}{name} = add {typ} {operand}, 0\n'

        # mul %x, 2 -> shl %x, 1
        m = re.match(r'(\s*)(%\w+)\s*=\s*mul\s+(i\d+)\s+(%\w+),\s*2\s*$', stripped)
        if m:
            indent, name, typ, operand = m.groups()
            new_line = f'{indent}{name} = shl {typ} {operand}, 1\n'

        # mul %x, power_of_2 -> shl %x, log2
        m = re.match(r'(\s*)(%\w+)\s*=\s*mul\s+(i\d+)\s+(%\w+),\s*(\d+)\s*$', stripped)
        if m:
            indent, name, typ, operand, val = m.groups()
            val = int(val)
            if val > 0 and (val & (val - 1)) == 0:
                shift = int(math.log2(val))
                new_line = f'{indent}{name} = shl {typ} {operand}, {shift}\n'

        # add %x, 0 -> identity
        # sub %x, 0 -> identity
        # These are harder to eliminate without full SSA renaming, skip for now

        result.append(new_line)

    return result

if __name__ == '__main__':
    lines = sys.stdin.readlines()
    result = peephole_optimize(lines)
    sys.stdout.writelines(result)
