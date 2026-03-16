#!/usr/bin/env python3
"""Function inlining pass for our SSA IR.

Inlines small functions at their call sites, eliminating call overhead
and enabling cross-function optimization (strength reduction, phi
coalescing, etc. across the former call boundary).

Algorithm:
1. Parse all functions
2. Identify "inlinable" functions (small, non-recursive, defined in file)
3. For each call to an inlinable function:
   a. Clone the callee's body with renamed vregs/blocks
   b. Replace `arg` instructions with the actual arguments
   c. Replace `ret` with assignment to call result + branch to continuation
   d. Splice into the caller
"""

import sys
import re
from collections import defaultdict

MAX_INLINE_INSTRS = 50  # Don't inline functions larger than this


def parse_ir(text):
    """Parse IR text into a structured representation."""
    lines = text.strip().split('\n')
    externs = []
    functions = []
    i = 0
    while i < len(lines):
        line = lines[i].strip()
        if line.startswith('extern '):
            externs.append(lines[i])
            i += 1
        elif line.startswith('func '):
            func, i = parse_function(lines, i)
            functions.append(func)
        elif line.startswith('//'):
            i += 1
        else:
            i += 1
    return externs, functions


def parse_function(lines, start):
    """Parse one function, returning (func_dict, next_line_index)."""
    header = lines[start].strip()
    m = re.match(r'func\s+@(\w+)\(([^)]*)\)\s*->\s*(\w+)\s*\{', header)
    if not m:
        # Try void return
        m = re.match(r'func\s+@(\w+)\(([^)]*)\)\s*\{', header)
        if m:
            name = m.group(1)
            params = m.group(2).strip()
            ret_type = 'void'
        else:
            return None, start + 1
    else:
        name = m.group(1)
        params = m.group(2).strip()
        ret_type = m.group(3)

    param_types = [p.strip() for p in params.split(',') if p.strip()] if params else []

    blocks = {}
    block_order = []
    current_block = None
    i = start + 1
    while i < len(lines):
        line = lines[i].strip()
        if line == '}':
            i += 1
            break
        if line.endswith(':') and not line.startswith('//'):
            current_block = line[:-1]
            blocks[current_block] = []
            block_order.append(current_block)
        elif current_block is not None and line:
            blocks[current_block].append(line)
        i += 1

    return {
        'name': name,
        'params': param_types,
        'ret_type': ret_type,
        'blocks': blocks,
        'block_order': block_order,
        'header': lines[start],
        'instr_count': sum(len(v) for v in blocks.values()),
    }, i


def is_inlinable(func, all_func_names):
    """Check if a function can be inlined."""
    if func['instr_count'] > MAX_INLINE_INSTRS:
        return False
    if func['name'] == 'main':
        return False
    # Check for recursive calls
    for block_instrs in func['blocks'].values():
        for instr in block_instrs:
            if f'@{func["name"]}' in instr and 'call' in instr:
                return False
    return True


def inline_call(caller_blocks, caller_block_order, block_name, instr_idx,
                callee, call_instr, vreg_counter, block_counter):
    """Inline a function call, replacing it with the callee's body."""
    # Parse the call instruction
    # Format: %result = call ret_type @func, type arg1, type arg2, ...
    # Or: call void @func, type arg1, ...
    m = re.match(r'(%\w+)\s*=\s*call\s+(\w+)\s+@(\w+)(?:,\s*(.*))?', call_instr)
    if not m:
        m = re.match(r'call\s+(\w+)\s+@(\w+)(?:,\s*(.*))?', call_instr)
        if not m:
            return vreg_counter, block_counter, False
        result_vreg = None
        ret_type = m.group(1)
        func_name = m.group(2)
        args_str = m.group(3) or ''
    else:
        result_vreg = m.group(1)
        ret_type = m.group(2)
        func_name = m.group(3)
        args_str = m.group(4) or ''

    # Parse arguments: "i64 %x, i64 %y" or "i64 42, ptr %buf"
    args = []
    if args_str.strip():
        for arg_part in re.findall(r'(\w+)\s+([^,]+)', args_str):
            args.append((arg_part[0], arg_part[1].strip()))

    # Create unique prefix for renaming
    prefix = f'_inl{block_counter}'
    block_counter += 1

    # Rename all vregs and blocks in the callee
    vreg_map = {}  # old_vreg -> new_vreg
    block_map = {}  # old_block -> new_block

    for bname in callee['block_order']:
        new_name = f'{bname}{prefix}'
        block_map[bname] = new_name

    def rename_vreg(name):
        if name not in vreg_map:
            vreg_counter_ref[0] += 1
            vreg_map[name] = f'%_i{vreg_counter_ref[0]}'
        return vreg_map[name]

    vreg_counter_ref = [vreg_counter]

    def rename_operand(op):
        op = op.strip()
        if op.startswith('%'):
            return rename_vreg(op)
        return op

    def rename_line(line):
        """Rename all vregs and block references in an IR line."""
        result = line
        # Rename block references (@blockname)
        for old_block, new_block in block_map.items():
            result = re.sub(r'@' + re.escape(old_block) + r'\b', f'@{new_block}', result)
        # Rename vreg definitions (%name =)
        m = re.match(r'(\s*)(%\w+)\s*=\s*(.*)', result)
        if m:
            indent, vreg, rest = m.groups()
            new_vreg = rename_vreg(vreg)
            result = f'{indent}{new_vreg} = {rest}'
            # Rename vregs in the rest
            def replace_vreg(match):
                return rename_vreg(match.group(0))
            # Find all %name references in rest that aren't the definition
            rest_part = result.split('=', 1)[1] if '=' in result else result
            # Replace %name patterns
            parts = result.split('=', 1)
            if len(parts) == 2:
                rhs = parts[1]
                rhs = re.sub(r'%\w+', replace_vreg, rhs)
                result = f'{parts[0]}={rhs}'
        else:
            # No definition — just rename vreg uses
            def replace_vreg(match):
                return rename_vreg(match.group(0))
            result = re.sub(r'%\w+', replace_vreg, result)
        return result

    # Create a continuation block for after the inlined function
    cont_block = f'cont{prefix}'

    # Split the caller block: instructions before the call stay, the call
    # is replaced with a branch to the inlined entry, and instructions after
    # become the continuation block.
    caller_instrs = caller_blocks[block_name]
    before_call = caller_instrs[:instr_idx]
    after_call = caller_instrs[instr_idx + 1:]

    # Map arg instructions to actual arguments
    arg_replacements = {}  # maps inline vreg for arg result -> actual arg value
    for bname in callee['block_order']:
        for instr in callee['blocks'][bname]:
            m = re.match(r'(%\w+)\s*=\s*arg\s+\w+\s+(\d+)', instr.strip())
            if m:
                arg_vreg = m.group(1)
                arg_idx = int(m.group(2))
                if arg_idx < len(args):
                    arg_val = args[arg_idx][1]  # the actual argument value
                    renamed = rename_vreg(arg_vreg)
                    arg_replacements[renamed] = arg_val

    # Build the inlined blocks
    inlined_blocks = {}
    inlined_order = []
    ret_values = []  # (value, block_name) for phi at return
    ret_blocks = []

    for bname in callee['block_order']:
        new_bname = block_map[bname]
        inlined_blocks[new_bname] = []
        inlined_order.append(new_bname)

        for instr in callee['blocks'][bname]:
            stripped = instr.strip()
            # Skip arg instructions (handled via replacement)
            if re.match(r'%\w+\s*=\s*arg\s+', stripped):
                continue

            # Handle ret: replace with assignment + branch to continuation
            m_ret = re.match(r'ret\s+(\w+)\s+(.+)', stripped)
            if m_ret:
                ret_ty = m_ret.group(1)
                ret_val = m_ret.group(2).strip()
                renamed_val = rename_operand(ret_val)
                # Apply arg replacements
                if renamed_val in arg_replacements:
                    renamed_val = arg_replacements[renamed_val]
                ret_values.append((renamed_val, new_bname))
                ret_blocks.append(new_bname)
                inlined_blocks[new_bname].append(f'  br @{cont_block}')
                continue

            # Rename everything in the instruction
            renamed = rename_line('  ' + stripped)

            # Apply arg replacements in the renamed instruction
            for old_vreg, new_val in arg_replacements.items():
                renamed = renamed.replace(old_vreg, new_val)

            inlined_blocks[new_bname].append(renamed)

    # Modify the caller:
    # 1. Original block ends with branch to inlined entry
    entry_block = block_map[callee['block_order'][0]]
    before_call.append(f'  br @{entry_block}')
    caller_blocks[block_name] = before_call

    # 2. Add all inlined blocks
    insert_idx = caller_block_order.index(block_name) + 1
    for ib_name in inlined_order:
        caller_blocks[ib_name] = inlined_blocks[ib_name]
        caller_block_order.insert(insert_idx, ib_name)
        insert_idx += 1

    # 3. Add continuation block
    cont_instrs = []
    if result_vreg and ret_values:
        if len(ret_values) == 1:
            # Single return — just assign
            val, from_block = ret_values[0]
            cont_instrs.append(f'  {result_vreg} = add {ret_type} {val}, 0')
        else:
            # Multiple returns — phi node
            phi_args = ', '.join(f'[{val}, @{blk}]' for val, blk in ret_values)
            cont_instrs.append(f'  {result_vreg} = phi {ret_type} {phi_args}')

    cont_instrs.extend(after_call)
    caller_blocks[cont_block] = cont_instrs
    caller_block_order.insert(insert_idx, cont_block)

    return vreg_counter_ref[0], block_counter, True


def inline_functions(text):
    """Main pass: inline small functions."""
    externs, functions = parse_ir(text)

    if not functions:
        return text

    func_map = {f['name']: f for f in functions}
    func_names = set(func_map.keys())

    # Find inlinable functions
    inlinable = set()
    for f in functions:
        if is_inlinable(f, func_names):
            inlinable.add(f['name'])

    if not inlinable:
        return text

    # Process each function, inlining calls
    vreg_counter = 1000
    block_counter = 1000
    changed = True
    max_passes = 3

    for pass_num in range(max_passes):
        changed = False
        for func in functions:
            for bname in list(func['block_order']):
                if bname not in func['blocks']:
                    continue
                instrs = func['blocks'][bname]
                for i, instr in enumerate(instrs):
                    # Check for call to inlinable function
                    m = re.search(r'call\s+\w+\s+@(\w+)', instr)
                    if m and m.group(1) in inlinable and m.group(1) in func_map:
                        callee = func_map[m.group(1)]
                        vreg_counter, block_counter, did_inline = inline_call(
                            func['blocks'], func['block_order'],
                            bname, i, callee, instr.strip(),
                            vreg_counter, block_counter
                        )
                        if did_inline:
                            changed = True
                            break  # Restart scanning this function
                if changed:
                    break
            if changed:
                break

        if not changed:
            break

    # Reconstruct IR text
    output = []
    for ext in externs:
        output.append(ext)
    if externs:
        output.append('')

    for func in functions:
        params_str = ', '.join(func['params'])
        if func['ret_type'] == 'void':
            output.append(f'func @{func["name"]}({params_str}) {{')
        else:
            output.append(f'func @{func["name"]}({params_str}) -> {func["ret_type"]} {{')

        for bname in func['block_order']:
            output.append(f'{bname}:')
            for instr in func['blocks'].get(bname, []):
                output.append(instr)

        output.append('}')
        output.append('')

    return '\n'.join(output)


def main():
    text = sys.stdin.read()
    result = inline_functions(text)
    sys.stdout.write(result)


if __name__ == '__main__':
    main()
