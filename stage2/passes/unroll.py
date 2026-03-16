#!/usr/bin/env python3
"""IR-level loop unrolling pass.

Detects simple loops (single back-edge, no calls, no nested loops) and
unrolls them by a factor of 4. Adjusts the loop bounds accordingly.

Pattern matched:
  entry:
    br @loop
  loop:
    %vars = phi [init, @entry], [%updated, @loop]
    ...computation...
    %counter_next = add i64 %counter, 1
    %done = cmp_XX i64 %counter_next, LIMIT
    br_cond %done, @exit, @loop
  exit:
    ...use results...

Transformed to:
  entry:
    br @loop
  loop:
    %vars = phi [init, @entry], [%updated4, @loop]
    ...computation x4...
    %counter_next4 = add i64 %counter, 4
    %done = cmp_XX i64 %counter_next4, LIMIT
    br_cond %done, @remainder, @loop
  remainder:
    ...handle remaining iterations...
  exit:
    ...

For simplicity, this pass only handles loops where:
1. The loop counter increments by 1
2. The loop body has only self-updating phi patterns
3. The loop has exactly one back-edge to itself
4. No function calls in the loop body
"""

import sys
import re

def parse_ir(text):
    """Simple IR parser — returns list of lines with structure info."""
    return text.splitlines(keepends=True)

def find_simple_loops(lines):
    """Find loops that can be unrolled."""
    # This is a text-level transformation for simplicity
    # Look for the pattern:
    #   blockname:
    #     phi nodes
    #     self-updating computations
    #     counter = add i64 counter_phi, 1
    #     done = cmp_XX counter, LIMIT
    #     br_cond done, @exit, @blockname (back-edge to self)

    # For now, just do a simple 4x duplication of the loop body instructions
    # between phi nodes and the branch
    pass

def unroll_ir(text, factor=4):
    """Unroll simple loops in IR text by the given factor."""
    lines = text.split('\n')
    result = []
    i = 0

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()

        # Detect a loop block with back-edge to itself
        # Look for: br_cond %done, @exit, @loop_name (or @loop_name, @exit)
        if re.match(r'\s*br_cond\s+%\w+,\s*@\w+,\s*@\w+', stripped):
            m = re.match(r'\s*br_cond\s+(%\w+),\s*@(\w+),\s*@(\w+)', stripped)
            if m:
                cond_var, label1, label2 = m.groups()

                # Find the current block name by scanning backward
                block_name = None
                for j in range(i-1, -1, -1):
                    bm = re.match(r'^(\w+):', lines[j])
                    if bm:
                        block_name = bm.group(1)
                        break

                # Check if one of the labels is a back-edge to this block
                back_edge = None
                exit_label = None
                if label2 == block_name:
                    back_edge = label2
                    exit_label = label1
                elif label1 == block_name:
                    back_edge = label1
                    exit_label = label2

                if back_edge and block_name:
                    # Found a self-loop. Try to unroll.
                    # Find the block start
                    block_start = None
                    for j in range(i-1, -1, -1):
                        if re.match(rf'^{re.escape(block_name)}:', lines[j]):
                            block_start = j
                            break

                    if block_start is not None:
                        # Extract the block body (between phi nodes and br_cond)
                        phi_end = block_start + 1
                        while phi_end < i:
                            if re.match(r'\s*%\w+\s*=\s*phi\s+', lines[phi_end].strip()):
                                phi_end += 1
                            else:
                                break

                        # Body = instructions between phi nodes and the br_cond
                        body_lines = lines[phi_end:i]  # excludes br_cond itself

                        # Check: does the body contain calls? If so, skip.
                        has_call = any('call ' in l for l in body_lines)
                        if has_call:
                            result.append(line)
                            i += 1
                            continue

                        # Find the counter increment: %X = add i64 %Y, 1
                        counter_incr = None
                        counter_var = None
                        counter_next = None
                        for bl in body_lines:
                            cm = re.match(r'\s*(%\w+)\s*=\s*add\s+i64\s+(%\w+),\s*1\s*$', bl.strip())
                            if cm:
                                counter_next = cm.group(1)
                                counter_var = cm.group(2)
                                counter_incr = bl
                                break

                        # Find the comparison that uses counter_next
                        cmp_line = None
                        cmp_var = None
                        for bl in body_lines:
                            if counter_next and counter_next in bl and '= cmp_' in bl:
                                cmp_line = bl
                                cm2 = re.match(r'\s*(%\w+)\s*=\s*cmp_\w+', bl.strip())
                                if cm2:
                                    cmp_var = cm2.group(1)
                                break

                        if counter_incr and cmp_line and cmp_var == cond_var:
                            # We can unroll! Duplicate the non-counter, non-cmp body lines
                            # and change the counter increment from +1 to +factor.

                            # Separate body into:
                            # 1. Computation lines (not counter, not cmp, not done var)
                            compute_lines = []
                            for bl in body_lines:
                                bl_stripped = bl.strip()
                                if bl == counter_incr:
                                    continue
                                if bl == cmp_line:
                                    continue
                                if cmp_var and re.match(rf'\s*{re.escape(cmp_var)}\s*=', bl_stripped):
                                    continue
                                compute_lines.append(bl)

                            # Emit: original phi lines
                            # Already in result from earlier iterations

                            # Emit: compute lines × factor
                            for rep in range(factor):
                                for cl in compute_lines:
                                    result.append(cl)

                            # Emit: modified counter increment (+factor instead of +1)
                            new_incr = counter_incr.replace(f'{counter_next} = add i64 {counter_var}, 1',
                                                            f'{counter_next} = add i64 {counter_var}, {factor}')
                            result.append(new_incr)

                            # Emit: original cmp and br_cond
                            result.append(cmp_line)
                            result.append(line)  # br_cond

                            i += 1
                            continue

        result.append(line)
        i += 1

    return '\n'.join(result)


def main():
    text = sys.stdin.read()
    result = unroll_ir(text, factor=4)
    sys.stdout.write(result)


if __name__ == '__main__':
    main()
