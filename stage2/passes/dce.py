#!/usr/bin/env python3
"""Dead code elimination pass for our IR."""
import sys
import re

def eliminate_dead_code(lines):
    """Remove instructions whose results are never used."""
    # First pass: find all used vregs
    used = set()
    for line in lines:
        stripped = line.strip()
        # Skip definitions, find uses
        m = re.match(r'\s*%\w+\s*=\s*(.+)', stripped)
        if m:
            rhs = m.group(1)
        else:
            rhs = stripped
        # Find all %name references in the RHS
        for ref in re.findall(r'%\w+', rhs):
            if not re.match(r'\s*' + re.escape(ref) + r'\s*=', stripped):
                used.add(ref)

    # Second pass: remove unused definitions (except side-effecting ops)
    side_effects = {'store', 'call', 'br', 'br_cond', 'ret'}
    result = []
    for line in lines:
        stripped = line.strip()
        m = re.match(r'\s*(%\w+)\s*=\s*(\w+)', stripped)
        if m:
            name, op = m.groups()
            if name not in used and op not in side_effects:
                continue  # dead code, skip
        result.append(line)

    return result

if __name__ == '__main__':
    lines = sys.stdin.readlines()
    result = eliminate_dead_code(lines)
    sys.stdout.writelines(result)
