#!/usr/bin/env python3
"""Constant folding optimization pass for our IR."""
import sys
import re

def fold_constants(lines):
    """Find and fold constant expressions."""
    constants = {}  # vreg -> constant value
    result = []

    for line in lines:
        stripped = line.strip()
        # Match: %name = op type imm1, imm2
        m = re.match(r'(\s*)(%\w+)\s*=\s*(add|sub|mul|div|mod|and|or|xor|shl|shr)\s+(i\d+|ptr)\s+(-?\d+),\s*(-?\d+)', stripped)
        if m:
            indent, name, op, typ, a, b = m.groups()
            a, b = int(a), int(b)
            result_val = None
            if op == 'add': result_val = a + b
            elif op == 'sub': result_val = a - b
            elif op == 'mul': result_val = a * b
            elif op == 'div' and b != 0: result_val = a // b
            elif op == 'mod' and b != 0: result_val = a % b
            elif op == 'and': result_val = a & b
            elif op == 'or': result_val = a | b
            elif op == 'xor': result_val = a ^ b
            elif op == 'shl': result_val = a << b
            elif op == 'shr': result_val = a >> b
            if result_val is not None:
                constants[name] = result_val
                # Replace with: %name = add type result_val, 0
                result.append(f'{indent}{name} = add {typ} {result_val}, 0\n')
                continue

        # Check comparison with two constants
        m = re.match(r'(\s*)(%\w+)\s*=\s*(cmp_\w+)\s+(i\d+|ptr)\s+(-?\d+),\s*(-?\d+)', stripped)
        if m:
            indent, name, op, typ, a, b = m.groups()
            a, b = int(a), int(b)
            result_val = None
            if op == 'cmp_eq': result_val = 1 if a == b else 0
            elif op == 'cmp_ne': result_val = 1 if a != b else 0
            elif op == 'cmp_lt': result_val = 1 if a < b else 0
            elif op == 'cmp_gt': result_val = 1 if a > b else 0
            elif op == 'cmp_le': result_val = 1 if a <= b else 0
            elif op == 'cmp_ge': result_val = 1 if a >= b else 0
            if result_val is not None:
                constants[name] = result_val
                result.append(f'{indent}{name} = add i64 {result_val}, 0\n')
                continue

        # Substitute known constants in operands
        new_line = line
        for vreg, val in constants.items():
            # Replace vreg references with constant values (careful not to replace definitions)
            pattern = re.escape(vreg) + r'(?!\s*=)'
            new_line = re.sub(pattern, str(val), new_line)

        result.append(new_line)

    return result

if __name__ == '__main__':
    lines = sys.stdin.readlines()
    result = fold_constants(lines)
    sys.stdout.writelines(result)
