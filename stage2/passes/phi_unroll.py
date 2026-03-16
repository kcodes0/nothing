#!/usr/bin/env python3
"""Loop unrolling for circular phi dependencies.

Detects the pattern where phi copies form a circular chain:
  %a = phi [..., %b, @loop]
  %b = phi [..., %next, @loop]
  %next = add %a, %b            (or any op using both phi results)

In this case, 3x unrolling with register rotation eliminates ALL phi copies:
  iter 1: %next1 = add %a, %b         -> results in (a=b, b=next1)
  iter 2: %next2 = add %b, %next1     -> results in (a=next1, b=next2)
  iter 3: %next3 = add %next1, %next2  -> results in (a=next2, b=next3)
After 3 iterations, %a and %b rotate through 3 SSA names, avoiding copies.

This specifically targets fibonacci-like patterns.
"""
import sys
import re


def process_ir(text):
    """Look for simple loops with circular phi deps and unroll 3x."""
    lines = text.split('\n')
    result = []
    i = 0

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Look for a block that starts with multiple phi nodes
        if stripped.endswith(':') and not stripped.startswith('//'):
            block_name = stripped[:-1]
            block_lines = [line]
            i += 1

            # Collect all lines in this block
            while i < len(lines):
                s = lines[i].strip()
                if s.endswith(':') and not s.startswith('//') and s != '':
                    break
                if s == '}' or (s.startswith('func ') and '{' in s):
                    break
                block_lines.append(lines[i])
                i += 1

            # Check if this block has the circular phi + counter pattern
            unrolled = try_unroll_circular_phi(block_name, block_lines)
            if unrolled:
                result.extend(unrolled)
            else:
                result.extend(block_lines)
            continue

        result.append(line)
        i += 1

    return '\n'.join(result)


def try_unroll_circular_phi(block_name, block_lines):
    """Try to 3x unroll a loop with circular phi dependencies."""
    # Parse phi nodes and body instructions
    phis = []  # (result, type, [(val, label), ...])
    body = []  # non-phi instructions
    terminator = None

    for line in block_lines[1:]:  # skip the label
        stripped = line.strip()
        if not stripped:
            continue

        # Parse phi
        m = re.match(r'(%\w+)\s*=\s*phi\s+(\w+)\s+(.*)', stripped)
        if m and not body:  # phis must come before body
            result, ty, args_str = m.groups()
            # Parse phi args: [val, @block], [val, @block], ...
            phi_args = re.findall(r'\[([^,]+),\s*@(\w+)\]', args_str)
            phis.append((result, ty, phi_args))
            continue

        # Parse terminator
        if stripped.startswith('br_cond ') or stripped.startswith('br @') or stripped.startswith('ret '):
            terminator = stripped
            continue

        body.append(stripped)

    if not phis or not terminator:
        return None

    # Check if this is a self-loop (br_cond ... @this_block ... or br @this_block)
    if not (block_name in terminator):
        return None

    # Find the back-edge label (should be block_name itself)
    back_label = block_name

    # Identify circular phi dependencies on the back-edge
    # A circular dep exists when phi A uses phi B's back-edge value,
    # and phi B uses a value computed from phi A
    phi_results = {p[0] for p in phis}

    # Find which phis reference other phis on the back edge
    circular_phis = []
    counter_phi = None

    for result, ty, args in phis:
        for val, label in args:
            if label == back_label:
                if val in phi_results:
                    circular_phis.append((result, ty, val, args))
                elif any(val == body_line.split('=')[0].strip()
                        for body_line in body if '=' in body_line):
                    # This phi's back value is computed in the body
                    # Check if it's a simple counter (add %x, 1)
                    for body_line in body:
                        bm = re.match(rf'({re.escape(val)})\s*=\s*(add|sub)\s+\w+\s+{re.escape(result)},\s*(\d+)', body_line)
                        if bm:
                            counter_phi = (result, ty, val, args)
                            break

    # Only handle the specific case: 2 circular phis + 1 counter phi
    # This is the fibonacci pattern
    if len(circular_phis) != 2 or counter_phi is None:
        return None

    # For now, don't transform — this is complex to do at the IR text level
    # Instead, let's focus on what we CAN do in the assembly peephole
    return None


def main():
    text = sys.stdin.read()
    result = process_ir(text)
    sys.stdout.write(result)


if __name__ == '__main__':
    main()
