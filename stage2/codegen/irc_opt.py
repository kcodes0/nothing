#!/usr/bin/env python3
"""
Optimizing IR-to-AArch64 compiler with register allocation.

Improvements over Stage 1:
  - Linear scan register allocation using x19-x28 (callee-saved) + x9-x15 (scratch)
  - Immediate folding for add/sub/cmp when constant fits in 12 bits
  - Phi node lowering with register-to-register moves
  - Dead code elimination for unused values
  - Compare+branch fusion
  - Strength reduction for multiply by small constants
  - Better branch layout (eliminate unnecessary labels and branches)
  - cbz/cbnz for compare-against-zero patterns
"""

import sys
import re
import math
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class Instruction:
    result: Optional[str]
    op: str
    ty: Optional[str]
    operands: list
    phi_args: list = field(default_factory=list)
    call_target: Optional[str] = None
    call_arg_types: list = field(default_factory=list)
    call_args: list = field(default_factory=list)
    seq: int = 0
    block_name: str = ''


@dataclass
class Block:
    name: str
    instructions: list = field(default_factory=list)
    preds: list = field(default_factory=list)
    succs: list = field(default_factory=list)


@dataclass
class Function:
    name: str
    param_types: list
    ret_type: str
    blocks: dict = field(default_factory=dict)
    block_order: list = field(default_factory=list)


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

class IRParser:
    def __init__(self, text):
        self.text = text
        self.functions = []
        self.externs = []  # list of extern function names (for reference)

    def parse(self):
        lines = self.text.split('\n')
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith('extern '):
                self._parse_extern(line)
                i += 1
            elif line.startswith('func '):
                func, i = self._parse_function(lines, i)
                self.functions.append(func)
            else:
                i += 1
        return self.functions

    def _parse_extern(self, line):
        """Parse extern declaration like: extern @write(i64, ptr, i64) -> i64"""
        m = re.match(r'extern\s+@(\w+)\(([^)]*)\)(?:\s*->\s*(\w+))?', line)
        assert m, f"Bad extern declaration: {line}"
        name = m.group(1)
        self.externs.append(name)

    def _parse_function(self, lines, start):
        header = lines[start].strip()
        m = re.match(r'func\s+@(\w+)\(([^)]*)\)\s*->\s*(\w+)\s*\{', header)
        assert m, f"Bad function header: {header}"
        name = m.group(1)
        params_str = m.group(2).strip()
        param_types = [p.strip() for p in params_str.split(',') if p.strip()] if params_str else []
        ret_type = m.group(3)
        func = Function(name=name, param_types=param_types, ret_type=ret_type)

        i = start + 1
        current_block = None
        while i < len(lines):
            line = lines[i].strip()
            if line == '}':
                i += 1
                break
            if not line or line.startswith('//'):
                i += 1
                continue
            if line.endswith(':'):
                bname = line[:-1]
                current_block = Block(name=bname)
                func.blocks[bname] = current_block
                func.block_order.append(bname)
                i += 1
                continue
            instr = self._parse_instruction(line)
            if current_block is not None:
                instr.block_name = current_block.name
                current_block.instructions.append(instr)
            i += 1

        # Build CFG edges
        for bname, block in func.blocks.items():
            for instr in block.instructions:
                if instr.op == 'br':
                    target = instr.operands[0]
                    if target not in block.succs:
                        block.succs.append(target)
                    if bname not in func.blocks[target].preds:
                        func.blocks[target].preds.append(bname)
                elif instr.op == 'br_cond':
                    for target in [instr.operands[1], instr.operands[2]]:
                        if target not in block.succs:
                            block.succs.append(target)
                        if bname not in func.blocks[target].preds:
                            func.blocks[target].preds.append(bname)
        return func, i

    def _parse_instruction(self, line):
        result = None
        rest = line
        m = re.match(r'(%\w+)\s*=\s*(.*)', line)
        if m:
            result = m.group(1)
            rest = m.group(2)
        parts = rest.split()
        op = parts[0]
        if op == 'phi':
            return self._parse_phi(result, rest)
        elif op == 'call':
            return self._parse_call(result, rest)
        elif op == 'br_cond':
            return self._parse_br_cond(rest)
        elif op == 'br':
            return self._parse_br(rest)
        elif op == 'ret':
            return self._parse_ret(rest)
        elif op == 'arg':
            return self._parse_arg(result, rest)
        elif op == 'load':
            return self._parse_load(result, rest)
        elif op == 'store':
            return self._parse_store(rest)
        elif op in ('zext', 'sext', 'trunc', 'ptrtoint', 'inttoptr'):
            return self._parse_cast(result, op, rest)
        else:
            return self._parse_binop(result, op, rest)

    def _parse_phi(self, result, rest):
        m = re.match(r'phi\s+(\w+)\s+(.*)', rest)
        assert m, f"Bad phi: {rest}"
        ty = m.group(1)
        args_str = m.group(2)
        phi_args = []
        for am in re.finditer(r'\[([^,]+),\s*@(\w+)\]', args_str):
            val = am.group(1).strip()
            label = am.group(2)
            phi_args.append((val, label))
        return Instruction(result=result, op='phi', ty=ty, operands=[], phi_args=phi_args)

    def _parse_call(self, result, rest):
        m = re.match(r'call\s+(\w+)\s+@(\w+)(.*)', rest)
        assert m, f"Bad call: {rest}"
        ret_ty = m.group(1)
        target = m.group(2)
        args_str = m.group(3).strip()
        call_args = []
        call_arg_types = []
        if args_str.startswith(','):
            args_str = args_str[1:].strip()
            for part in re.findall(r'(\w+)\s+([^,]+)', args_str):
                call_arg_types.append(part[0])
                call_args.append(part[1].strip())
        return Instruction(result=result, op='call', ty=ret_ty, operands=[],
                           call_target=target, call_arg_types=call_arg_types,
                           call_args=call_args)

    def _parse_br_cond(self, rest):
        m = re.match(r'br_cond\s+(%\w+),\s*@(\w+),\s*@(\w+)', rest)
        assert m, f"Bad br_cond: {rest}"
        return Instruction(result=None, op='br_cond', ty=None,
                           operands=[m.group(1), m.group(2), m.group(3)])

    def _parse_br(self, rest):
        m = re.match(r'br\s+@(\w+)', rest)
        assert m, f"Bad br: {rest}"
        return Instruction(result=None, op='br', ty=None, operands=[m.group(1)])

    def _parse_ret(self, rest):
        m = re.match(r'ret\s+(\w+)\s+(.+)', rest)
        assert m, f"Bad ret: {rest}"
        return Instruction(result=None, op='ret', ty=m.group(1), operands=[m.group(2).strip()])

    def _parse_arg(self, result, rest):
        m = re.match(r'arg\s+(\w+)\s+(\d+)', rest)
        assert m, f"Bad arg: {rest}"
        return Instruction(result=result, op='arg', ty=m.group(1), operands=[m.group(2)])


    def _parse_load(self, result, rest):
        """Parse: load type %ptr"""
        m = re.match(r'load\s+(\w+)\s+(%\w+)', rest)
        assert m, f"Bad load: {rest}"
        ty = m.group(1)
        ptr = m.group(2)
        return Instruction(result=result, op='load', ty=ty, operands=[ptr])

    def _parse_store(self, rest):
        """Parse: store type %val, ptr %ptr"""
        m = re.match(r'store\s+(\w+)\s+([^,]+),\s*(\w+)\s+(%\w+)', rest)
        assert m, f"Bad store: {rest}"
        val_ty = m.group(1)
        val = m.group(2).strip()
        # ptr_ty = m.group(3)  # e.g. 'ptr' — not needed for codegen
        ptr = m.group(4)
        return Instruction(result=None, op='store', ty=val_ty, operands=[val, ptr])

    def _parse_cast(self, result, op, rest):
        """Parse: zext/sext/trunc/ptrtoint/inttoptr type %val"""
        m = re.match(r'\w+\s+(\w+)\s+(%\w+)', rest)
        assert m, f"Bad {op}: {rest}"
        ty = m.group(1)
        val = m.group(2)
        return Instruction(result=result, op=op, ty=ty, operands=[val])

    def _parse_binop(self, result, op, rest):
        m = re.match(r'\w+\s+(\w+)\s+(.+),\s*(.+)', rest)
        assert m, f"Bad binop: {rest}"
        ty = m.group(1)
        lhs = m.group(2).strip()
        rhs = m.group(3).strip()
        return Instruction(result=result, op=op, ty=ty, operands=[lhs, rhs])


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

CALLEE_SAVED = [f'x{i}' for i in range(19, 29)]  # x19-x28
CALLER_SAVED_SCRATCH = [f'x{i}' for i in range(9, 16)]  # x9-x15
CMP_OPS = {'cmp_eq': 'eq', 'cmp_ne': 'ne', 'cmp_lt': 'lt',
           'cmp_gt': 'gt', 'cmp_le': 'le', 'cmp_ge': 'ge'}


def is_vreg(s):
    return isinstance(s, str) and s.startswith('%')


def is_immediate(s):
    if isinstance(s, str):
        try:
            int(s)
            return True
        except ValueError:
            return False
    return False


def imm_val(s):
    return int(s)


def fits_12bit(v):
    return 0 <= v <= 4095


def emit_mov_imm(reg, val):
    """Generate instructions to load an arbitrary 64-bit immediate into reg."""
    lines = []
    if val == 0:
        lines.append(f'    mov {reg}, #0')
        return lines
    if val < 0:
        val = val & 0xFFFFFFFFFFFFFFFF
    chunks = []
    for shift in range(0, 64, 16):
        chunk = (val >> shift) & 0xFFFF
        if chunk != 0:
            chunks.append((chunk, shift))
    if not chunks:
        lines.append(f'    mov {reg}, #0')
        return lines
    first = True
    for chunk, shift in chunks:
        if first:
            if shift == 0:
                lines.append(f'    movz {reg}, #{chunk}')
            else:
                lines.append(f'    movz {reg}, #{chunk}, lsl #{shift}')
            first = False
        else:
            if shift == 0:
                lines.append(f'    movk {reg}, #{chunk}')
            else:
                lines.append(f'    movk {reg}, #{chunk}, lsl #{shift}')
    return lines


def invert_cond(cond):
    inv = {'eq': 'ne', 'ne': 'eq', 'lt': 'ge', 'ge': 'lt',
           'gt': 'le', 'le': 'gt'}
    return inv[cond]


def strength_reduce_mul(v):
    """Return (type, shift) for single-instruction strength reduction, or None.

    For power-of-2 values: replace mul with lsl.
    For (2^k + 1) values: replace mul with add with lsl (e.g., x + x<<k).
    """
    if v <= 0:
        return None
    # Power of 2: use lsl
    if v & (v - 1) == 0:
        return ('lsl', int(math.log2(v)))
    # 2^k + 1: use add with lsl (src + src << k = src * (2^k + 1))
    if v >= 3 and (v - 1) & (v - 2) == 0:
        return ('add_lsl', int(math.log2(v - 1)))
    return None


def get_used_vregs(instr):
    """Get all vregs read by an instruction."""
    used = set()
    if instr.op == 'phi':
        for val, label in instr.phi_args:
            if is_vreg(val):
                used.add(val)
    elif instr.op == 'call':
        for arg in instr.call_args:
            if is_vreg(arg):
                used.add(arg)
    elif instr.op == 'br_cond':
        if is_vreg(instr.operands[0]):
            used.add(instr.operands[0])
    elif instr.op == 'ret':
        if is_vreg(instr.operands[0]):
            used.add(instr.operands[0])
    elif instr.op in ('br', 'arg'):
        pass
    elif instr.op == 'load':
        # load uses the pointer operand
        if is_vreg(instr.operands[0]):
            used.add(instr.operands[0])
    elif instr.op == 'store':
        # store uses both the value and the pointer
        for op in instr.operands:
            if is_vreg(op):
                used.add(op)
    elif instr.op in ('zext', 'sext', 'trunc', 'ptrtoint', 'inttoptr'):
        # cast ops use their single operand
        if is_vreg(instr.operands[0]):
            used.add(instr.operands[0])
    else:
        for op in instr.operands:
            if is_vreg(op):
                used.add(op)
    return used


# ---------------------------------------------------------------------------
# Compiler
# ---------------------------------------------------------------------------

class IRCompiler:
    def __init__(self):
        self.functions = []
        self.output = []

    def parse(self, text):
        parser = IRParser(text)
        self.functions = parser.parse()

    def compile(self):
        self.output = []
        self.output.append('.text')
        self.output.append('.align 4')
        for func in self.functions:
            self.compile_function(func)
        return '\n'.join(self.output) + '\n'

    def compile_function(self, func):
        # ===================================================================
        # Phase 1: Number instructions and compute liveness
        # ===================================================================

        # Assign sequence numbers
        seq = 0
        all_instrs = []
        block_start = {}  # block_name -> first seq
        block_end = {}    # block_name -> last seq + 1
        for bname in func.block_order:
            block = func.blocks[bname]
            block_start[bname] = seq
            for instr in block.instructions:
                instr.seq = seq
                all_instrs.append(instr)
                seq += 1
            block_end[bname] = seq

        total_instr = seq

        # Collect all vregs
        all_vregs = set()
        for instr in all_instrs:
            if instr.result:
                all_vregs.add(instr.result)

        # Compute uses of each vreg
        vreg_uses = {v: set() for v in all_vregs}
        for instr in all_instrs:
            for v in get_used_vregs(instr):
                if v in vreg_uses:
                    vreg_uses[v].add(instr.seq)

        # Dead code elimination: find vregs never used (except side-effecting)
        dead = set()
        for v in all_vregs:
            if not vreg_uses[v]:
                dead.add(v)

        # Compute live intervals properly, handling phi nodes and loops
        # For a vreg defined at point D and used at points U1, U2, ...:
        #   interval = [D, max(U1, U2, ...)]
        # BUT: phi nodes are special. A phi use in block B for predecessor P
        # means the value is live at the END of block P, not at the phi instruction.
        # Also, for loops, we need to extend intervals to cover back-edges.

        # Better approach: compute live-in/live-out sets per block, then derive intervals.

        # Step 1: compute gen/kill sets
        block_gen = {b: set() for b in func.block_order}
        block_kill = {b: set() for b in func.block_order}

        for bname in func.block_order:
            block = func.blocks[bname]
            for instr in block.instructions:
                if instr.op == 'phi':
                    # Phi defines its result but uses come from predecessors
                    if instr.result:
                        block_kill[bname].add(instr.result)
                else:
                    used = get_used_vregs(instr)
                    for v in used:
                        if v not in block_kill[bname]:
                            block_gen[bname].add(v)
                    if instr.result:
                        block_kill[bname].add(instr.result)

        # Phi uses: a phi in block B referencing vreg %v from predecessor P
        # means %v is in gen[P] (if not killed in P before the end)
        # More precisely, %v is live-out of P.
        for bname in func.block_order:
            block = func.blocks[bname]
            for instr in block.instructions:
                if instr.op != 'phi':
                    break
                for val, pred_label in instr.phi_args:
                    if is_vreg(val):
                        # val must be live at end of pred_label
                        # Add to gen of pred_label if not killed there
                        if val not in block_kill[pred_label]:
                            block_gen[pred_label].add(val)

        # Step 2: iterate to compute live-in/live-out
        live_in = {b: set() for b in func.block_order}
        live_out = {b: set() for b in func.block_order}

        changed = True
        while changed:
            changed = False
            for bname in reversed(func.block_order):
                block = func.blocks[bname]
                # live_out = union of live_in of successors
                # BUT: for phi nodes in successors, only the value from this predecessor
                new_out = set()
                for succ_name in block.succs:
                    succ = func.blocks[succ_name]
                    # Add live_in of successor minus phi-defined vars
                    phi_defs = set()
                    for si in succ.instructions:
                        if si.op != 'phi':
                            break
                        if si.result:
                            phi_defs.add(si.result)
                    new_out |= (live_in[succ_name] - phi_defs)
                    # For phi nodes in successor, add the value from this pred
                    for si in succ.instructions:
                        if si.op != 'phi':
                            break
                        for val, pred_label in si.phi_args:
                            if pred_label == bname and is_vreg(val):
                                new_out.add(val)

                # live_in = gen + (live_out - kill)
                new_in = block_gen[bname] | (new_out - block_kill[bname])

                if new_in != live_in[bname] or new_out != live_out[bname]:
                    changed = True
                    live_in[bname] = new_in
                    live_out[bname] = new_out

        # Step 3: compute live intervals from live-in/live-out
        # For each vreg, find the range of seq numbers where it's live
        intervals = {}  # vreg -> (start, end)

        for v in all_vregs:
            if v in dead:
                continue
            start = total_instr
            end = 0

            # Find def point
            for instr in all_instrs:
                if instr.result == v:
                    start = min(start, instr.seq)
                    end = max(end, instr.seq)
                    break

            # Find use points
            for instr in all_instrs:
                if v in get_used_vregs(instr):
                    end = max(end, instr.seq)

            # Extend for liveness across blocks
            for bname in func.block_order:
                if v in live_in[bname] or v in live_out[bname]:
                    if block_start[bname] < total_instr:
                        bs = block_start[bname]
                        be = block_end[bname] - 1 if block_end[bname] > 0 else 0
                        if v in live_in[bname]:
                            start = min(start, bs)
                            end = max(end, be)
                        if v in live_out[bname]:
                            end = max(end, be)

            intervals[v] = (start, end)

        # ===================================================================
        # Phase 2: Register allocation (linear scan) with phi coalescing
        # ===================================================================

        has_calls = any(i.op == 'call' for i in all_instrs)
        call_seqs = [i.seq for i in all_instrs if i.op == 'call']

        live_across_call = set()
        for v, (s, e) in intervals.items():
            for cs in call_seqs:
                if s <= cs <= e:
                    live_across_call.add(v)
                    break

        # Phi coalescing: identify self-update patterns where a phi result
        # is updated in-place (e.g., %i_next = add %i, 1 with phi %i <- %i_next).
        # For these, merge the intervals so they get the same register.
        phi_prefs = {}
        coalesced = {}  # vreg -> canonical vreg (representative)

        # Find self-update phi patterns
        for instr in all_instrs:
            if instr.op == 'phi' and instr.result:
                for val, label in instr.phi_args:
                    if is_vreg(val):
                        phi_prefs.setdefault(instr.result, set()).add(val)
                        phi_prefs.setdefault(val, set()).add(instr.result)

        # Attempt to coalesce: for each phi edge %x <- %y, check if %y is
        # defined using %x (self-update) AND %x is not used as a source
        # by any other phi on the same back-edge (which would need the old value).
        #
        # First, collect all phi groups by back-edge label
        phi_groups = {}  # label -> [(phi_result, incoming_val)]
        for instr in all_instrs:
            if instr.op == 'phi' and instr.result:
                for val, label in instr.phi_args:
                    phi_groups.setdefault(label, []).append((instr.result, val))

        for instr in all_instrs:
            if instr.op != 'phi' or not instr.result:
                continue
            phi_result = instr.result
            if phi_result in coalesced or phi_result not in intervals:
                continue
            for val, label in instr.phi_args:
                if not is_vreg(val) or val not in intervals:
                    continue
                # Skip if val already coalesced
                if val in coalesced:
                    continue

                # Check safety: is phi_result used as a SOURCE by another phi
                # in the same group? If so, coalescing would destroy the value
                # before the other phi can read it.
                used_as_source = False
                if label in phi_groups:
                    for other_dst, other_src in phi_groups[label]:
                        if other_dst != phi_result and is_vreg(other_src):
                            if other_src == phi_result:
                                used_as_source = True
                                break
                if used_as_source:
                    continue  # Unsafe to coalesce

                # Try two coalescing strategies:
                # 1. Self-update: val is defined using phi_result (strongest)
                # 2. Non-overlapping: val's live range ends before phi_result starts
                can_coalesce = False

                # Strategy 1: Self-update pattern
                for def_instr in all_instrs:
                    if def_instr.result == val:
                        used = get_used_vregs(def_instr)
                        if phi_result in used:
                            can_coalesce = True
                        break

                # Strategy 2: Non-overlapping live ranges
                # val is only live from its def to the phi point (end of predecessor block)
                # phi_result is live from the phi point onward
                # If they don't truly interfere, coalesce.
                if not can_coalesce:
                    s1, e1 = intervals[phi_result]
                    s2, e2 = intervals[val]
                    # val's last use should be at or before phi_result's definition
                    # (the phi node is at the start of phi_result's block)
                    if e2 <= s1 or s2 >= e1:
                        can_coalesce = True

                if can_coalesce:
                    s1, e1 = intervals[phi_result]
                    s2, e2 = intervals[val]
                    intervals[phi_result] = (min(s1, s2), max(e1, e2))
                    coalesced[val] = phi_result

        # Store coalesced map for phi move filtering
        self._coalesced = coalesced

        # Remove coalesced vregs from the interval map (they'll share their canonical's register)
        for v in coalesced:
            if v in intervals:
                del intervals[v]
            if v in dead:
                dead.discard(v)

        sorted_vregs = sorted(intervals.keys(), key=lambda v: intervals[v][0])

        reg_assignment = {}
        spill_slots = {}
        active = []  # (end, vreg, preg)

        avail_callee = list(reversed(CALLEE_SAVED))
        avail_scratch = list(reversed(CALLER_SAVED_SCRATCH))

        def expire_old(point):
            nonlocal active
            new_active = []
            for end_pt, v, preg in active:
                if end_pt < point:
                    if preg in CALLEE_SAVED:
                        avail_callee.append(preg)
                    else:
                        avail_scratch.append(preg)
                else:
                    new_active.append((end_pt, v, preg))
            active = new_active

        spill_count = 0
        for v in sorted_vregs:
            start, end = intervals[v]
            expire_old(start)

            reg = None

            # Try phi coalescing: prefer the register of a phi-related vreg
            if v in phi_prefs:
                for partner in phi_prefs[v]:
                    if partner in reg_assignment:
                        preferred = reg_assignment[partner]
                        # Check if preferred reg is available (partner's interval ended)
                        if preferred in avail_callee:
                            reg = preferred
                            avail_callee.remove(reg)
                            break
                        elif preferred in avail_scratch:
                            reg = preferred
                            avail_scratch.remove(reg)
                            break
                        # If partner is still active but they share a phi edge,
                        # we can still coalesce if their live ranges don't truly
                        # overlap (one ends at the phi point where the other starts).
                        # Check: does partner's interval end at or before our start?
                        if partner in intervals:
                            p_start, p_end = intervals[partner]
                            if p_end <= start:
                                # Partner has expired but wasn't cleaned up yet
                                # Force expire
                                expire_old(start)
                                if preferred in avail_callee:
                                    reg = preferred
                                    avail_callee.remove(reg)
                                    break
                                elif preferred in avail_scratch:
                                    reg = preferred
                                    avail_scratch.remove(reg)
                                    break

            if reg is None:
                if v in live_across_call:
                    if avail_callee:
                        reg = avail_callee.pop()
                else:
                    if avail_scratch:
                        reg = avail_scratch.pop()
                    elif avail_callee:
                        reg = avail_callee.pop()

            if reg is None:
                # Try to spill the longest-lived active
                if active:
                    active.sort(key=lambda x: x[0])
                    spill_end, spill_v, spill_reg = active[-1]
                    if spill_end > end:
                        active.pop()
                        spill_slots[spill_v] = spill_count
                        spill_count += 1
                        del reg_assignment[spill_v]
                        reg = spill_reg
                    else:
                        spill_slots[v] = spill_count
                        spill_count += 1
                        continue
                else:
                    spill_slots[v] = spill_count
                    spill_count += 1
                    continue

            reg_assignment[v] = reg
            active.append((end, v, reg))

        # ===================================================================
        # Phase 3: Determine frame layout
        # ===================================================================

        used_callee = set()
        for v, preg in reg_assignment.items():
            if preg in CALLEE_SAVED:
                used_callee.add(preg)

        # Pre-scan for constants needing register preloading (affects callee-saved usage)
        _REG_ONLY_OPS = {'mul', 'div', 'mod', 'and', 'or', 'xor'}
        _pre_needs = set()
        for instr in all_instrs:
            if instr.op in _REG_ONLY_OPS:
                for op in instr.operands:
                    if is_immediate(op) and imm_val(op) != 0:
                        v = imm_val(op)
                        # Skip mul constants that can be strength-reduced
                        if instr.op == 'mul' and strength_reduce_mul(v):
                            continue
                        # Skip div/mod by power of 2 (will use shift/and)
                        if instr.op in ('div', 'mod') and v > 0 and (v & (v-1)) == 0:
                            continue
                        _pre_needs.add(v)
            elif instr.op in CMP_OPS:
                for op in instr.operands:
                    if is_immediate(op) and not fits_12bit(abs(imm_val(op))):
                        _pre_needs.add(imm_val(op))

        _const_pool_regs = []
        for r in ['x27', 'x28', 'x26', 'x25']:
            if r not in reg_assignment.values():
                _const_pool_regs.append(r)
        for i, v in enumerate(sorted(_pre_needs)[:len(_const_pool_regs)]):
            used_callee.add(_const_pool_regs[i])

        # Count max simultaneous caller-saved regs that need saving around calls
        max_caller_save = 0
        for instr in all_instrs:
            if instr.op == 'call':
                count = 0
                for v, preg in reg_assignment.items():
                    if preg in CALLER_SAVED_SCRATCH and v in intervals:
                        s, e = intervals[v]
                        if s < instr.seq and e > instr.seq:
                            count += 1
                max_caller_save = max(max_caller_save, count)

        # Frame layout:
        # [sp+0]: x29, x30 (always saved)
        # [sp+16]: callee-saved pairs
        # [sp+N]: spill slots
        # [sp+M]: caller-save scratch area

        saved_callee_list = sorted(used_callee, key=lambda r: int(r[1:]))
        save_pairs = [('x29', 'x30')]
        callee_to_save = list(saved_callee_list)
        while len(callee_to_save) >= 2:
            save_pairs.append((callee_to_save.pop(0), callee_to_save.pop(0)))
        if callee_to_save:
            save_pairs.append((callee_to_save[0], None))

        pairs_space = len(save_pairs) * 16
        spill_space = spill_count * 8
        caller_save_space = max_caller_save * 8

        total_extra = spill_space + caller_save_space
        # Align to 16
        if total_extra % 16 != 0:
            total_extra += 16 - (total_extra % 16)

        frame_size = pairs_space + total_extra
        if frame_size < 16:
            frame_size = 16

        spill_base = pairs_space  # spill slots start here
        caller_save_base = pairs_space + spill_count * 8  # caller-save area starts here

        # ===================================================================
        # Phase 4: Code generation
        # ===================================================================

        SCRATCH1 = 'x8'
        SCRATCH2 = 'x16'
        SCRATCH3 = 'x17'

        def resolve_vreg(vreg):
            """Resolve coalesced vregs to their canonical representative."""
            return coalesced.get(vreg, vreg)

        def get_reg(vreg):
            v = resolve_vreg(vreg)
            if v in reg_assignment:
                return reg_assignment[v]
            return None

        def ensure_in_reg(vreg, target_reg=SCRATCH1):
            v = resolve_vreg(vreg)
            if v in reg_assignment:
                return reg_assignment[v]
            if v in spill_slots:
                off = spill_base + spill_slots[v] * 8
                self.output.append(f'    ldr {target_reg}, [x29, #{off}]')
                return target_reg
            raise RuntimeError(f"vreg {v} (from {vreg}) not assigned: {reg_assignment}")

        def store_result(vreg, src_reg):
            v = resolve_vreg(vreg)
            if v in spill_slots:
                off = spill_base + spill_slots[vreg] * 8
                self.output.append(f'    str {src_reg}, [x29, #{off}]')

        # Constant hoisting: reuse registers for repeated constant loads
        const_reg_cache = {}  # imm_value -> register holding it

        def load_operand(op, target_reg=SCRATCH1):
            if is_vreg(op):
                return ensure_in_reg(op, target_reg)
            elif is_immediate(op):
                v = imm_val(op)
                # Check if this constant is already in a register
                if v in const_reg_cache:
                    return const_reg_cache[v]
                for l in emit_mov_imm(target_reg, v):
                    self.output.append(l)
                # Cache if it required more than one instruction (worth hoisting)
                if len(emit_mov_imm(target_reg, v)) > 1 or not fits_12bit(abs(v)):
                    const_reg_cache[v] = target_reg
                return target_reg
            raise RuntimeError(f"Unknown operand: {op}")

        def clear_const_cache(*regs):
            """Invalidate cached constants in specified registers."""
            for r in regs:
                to_remove = [k for k, v in const_reg_cache.items() if v == r]
                for k in to_remove:
                    del const_reg_cache[k]

        def clear_const_cache_all():
            const_reg_cache.clear()

        def result_reg(instr):
            v = resolve_vreg(instr.result) if instr.result else None
            if v and v in reg_assignment:
                return reg_assignment[v]
            return SCRATCH1

        # Determine which cmp results are ONLY used by the immediately following br_cond
        # in the same block, so we can fuse them
        cmp_info = {}
        cmp_fuseable = set()
        for instr in all_instrs:
            if instr.op in CMP_OPS and instr.result:
                cmp_info[instr.result] = instr

        for bname in func.block_order:
            block = func.blocks[bname]
            for idx, instr in enumerate(block.instructions):
                if instr.op in CMP_OPS and instr.result:
                    # Check if only used by br_cond and that br_cond is the very next non-dead instruction
                    v = instr.result
                    uses_list = []
                    for other in all_instrs:
                        if v in get_used_vregs(other):
                            uses_list.append(other)
                    if len(uses_list) == 1 and uses_list[0].op == 'br_cond':
                        # Make sure the br_cond is in the same block and comes after
                        br_instr = uses_list[0]
                        if br_instr.block_name == bname:
                            cmp_fuseable.add(v)

        # Emit prologue
        self.output.append(f'.global _{func.name}')
        self.output.append(f'_{func.name}:')

        first_pair = True
        offset = 0
        for p in save_pairs:
            if first_pair:
                if p[1]:
                    self.output.append(f'    stp {p[0]}, {p[1]}, [sp, #-{frame_size}]!')
                else:
                    self.output.append(f'    str {p[0]}, [sp, #-{frame_size}]!')
                first_pair = False
                offset = 16
            else:
                if p[1]:
                    self.output.append(f'    stp {p[0]}, {p[1]}, [sp, #{offset}]')
                else:
                    self.output.append(f'    str {p[0]}, [sp, #{offset}]')
                offset += 16
        self.output.append(f'    mov x29, sp')

        # ===================================================================
        # Constant preloading: find immediate values that need multi-instr
        # materialization and are used in ops without immediate forms (mul,
        # div, mod) or are large (>12 bit) for cmp. Pre-load into scratch
        # registers before the first block so they survive across loops.
        # ===================================================================
        preload_regs = {}  # imm_value -> register name
        needs_preload = set()  # set of immediate values needing preload

        # Ops that have no immediate form — must use register for 2nd operand
        REG_ONLY_OPS = {'mul', 'div', 'mod', 'and', 'or', 'xor'}
        for instr in all_instrs:
            if instr.op in REG_ONLY_OPS:
                for op in instr.operands:
                    if is_immediate(op):
                        v = imm_val(op)
                        if v != 0:  # 0 can use xzr
                            # Skip mul constants that can be strength-reduced
                            if instr.op == 'mul' and strength_reduce_mul(v):
                                continue
                            needs_preload.add(v)
            elif instr.op in CMP_OPS:
                for op in instr.operands:
                    if is_immediate(op) and not fits_12bit(abs(imm_val(op))):
                        needs_preload.add(imm_val(op))

        # Assign registers for preloaded constants
        # Use caller-saved regs that aren't used as scratch: x2-x7 are unused
        # by our codegen except for call args. Use x2-x7 for constants if
        # they're not used for call args in this function. Actually safer to
        # just use additional callee-saved regs or specific scratch regs.
        # Use x27, x28 (callee-saved we can add to save list), and x8, x16-x17
        # which are our scratch regs but only within a single instruction emission.
        # Between instructions, scratch regs are free — BUT they get overwritten.
        # So we need callee-saved regs for constants that survive across instructions.
        #
        # We'll steal from the callee-saved pool: use x27, x28 for up to 2 constants.
        # If the register allocator already used them, we can't. Check.
        const_pool_regs = []
        for r in ['x27', 'x28', 'x26', 'x25']:
            if r not in reg_assignment.values():
                const_pool_regs.append(r)

        preload_values = sorted(needs_preload)[:len(const_pool_regs)]
        preload_save_regs = set()
        for i, v in enumerate(preload_values):
            reg = const_pool_regs[i]
            preload_regs[v] = reg
            preload_save_regs.add(reg)
            const_reg_cache[v] = reg  # Pre-fill the cache

        # Emit preload instructions right after prologue
        if preload_regs:
            for v, reg in preload_regs.items():
                for l in emit_mov_imm(reg, v):
                    self.output.append(l)

        # Emit blocks
        for bi, bname in enumerate(func.block_order):
            block = func.blocks[bname]
            self.output.append(f'.LBB_{func.name}_{bname}:')
            # Reset the volatile cache but keep preloaded constants
            volatile_keys = [k for k in const_reg_cache if k not in preload_regs]
            for k in volatile_keys:
                del const_reg_cache[k]

            for instr in block.instructions:
                # Skip dead instructions
                if instr.result and instr.result in dead and instr.op not in ('call', 'load'):
                    continue

                if instr.op == 'phi':
                    # Handled at predecessors
                    continue

                elif instr.op == 'arg':
                    arg_idx = int(instr.operands[0])
                    src = f'x{arg_idx}'
                    dst = result_reg(instr)
                    if src != dst:
                        self.output.append(f'    mov {dst}, {src}')
                    store_result(instr.result, dst)

                elif instr.op in ('add', 'sub'):
                    lhs, rhs = instr.operands
                    dst = result_reg(instr)

                    if is_immediate(lhs) and is_immediate(rhs):
                        v = imm_val(lhs) + imm_val(rhs) if instr.op == 'add' else imm_val(lhs) - imm_val(rhs)
                        for l in emit_mov_imm(dst, v):
                            self.output.append(l)
                    elif is_immediate(rhs) and fits_12bit(abs(imm_val(rhs))):
                        v = imm_val(rhs)
                        lhs_r = load_operand(lhs, SCRATCH1)
                        if v >= 0:
                            self.output.append(f'    {instr.op} {dst}, {lhs_r}, #{v}')
                        else:
                            alt = 'sub' if instr.op == 'add' else 'add'
                            self.output.append(f'    {alt} {dst}, {lhs_r}, #{-v}')
                    elif is_immediate(lhs) and fits_12bit(abs(imm_val(lhs))) and instr.op == 'add':
                        v = imm_val(lhs)
                        rhs_r = load_operand(rhs, SCRATCH1)
                        self.output.append(f'    add {dst}, {rhs_r}, #{v}')
                    else:
                        lhs_r = load_operand(lhs, SCRATCH1)
                        rhs_r = load_operand(rhs, SCRATCH2)
                        self.output.append(f'    {instr.op} {dst}, {lhs_r}, {rhs_r}')
                    store_result(instr.result, dst)

                elif instr.op == 'mul':
                    lhs, rhs = instr.operands
                    dst = result_reg(instr)

                    # Try strength reduction: replace mul by constant with lsl/add
                    sr_done = False
                    if is_immediate(rhs):
                        sr = strength_reduce_mul(imm_val(rhs))
                        if sr:
                            lhs_r = load_operand(lhs, SCRATCH1)
                            if sr[0] == 'lsl':
                                self.output.append(f'    lsl {dst}, {lhs_r}, #{sr[1]}')
                            else:  # add_lsl
                                self.output.append(f'    add {dst}, {lhs_r}, {lhs_r}, lsl #{sr[1]}')
                            sr_done = True
                    elif is_immediate(lhs):
                        sr = strength_reduce_mul(imm_val(lhs))
                        if sr:
                            rhs_r = load_operand(rhs, SCRATCH1)
                            if sr[0] == 'lsl':
                                self.output.append(f'    lsl {dst}, {rhs_r}, #{sr[1]}')
                            else:  # add_lsl
                                self.output.append(f'    add {dst}, {rhs_r}, {rhs_r}, lsl #{sr[1]}')
                            sr_done = True

                    if not sr_done:
                        # Fall back to regular mul
                        lhs_r = load_operand(lhs, SCRATCH1)
                        rhs_r = load_operand(rhs, SCRATCH2)
                        self.output.append(f'    mul {dst}, {lhs_r}, {rhs_r}')
                    store_result(instr.result, dst)

                elif instr.op == 'div':
                    lhs, rhs = instr.operands
                    dst = result_reg(instr)
                    # Strength reduce: div by power of 2 → arithmetic shift right
                    if is_immediate(rhs):
                        v = imm_val(rhs)
                        if v > 0 and (v & (v - 1)) == 0:
                            shift = int(math.log2(v))
                            lhs_r = load_operand(lhs, SCRATCH1)
                            if shift == 0:
                                if dst != lhs_r:
                                    self.output.append(f'    mov {dst}, {lhs_r}')
                            else:
                                self.output.append(f'    asr {dst}, {lhs_r}, #{shift}')
                            store_result(instr.result, dst)
                            continue
                    lhs_r = load_operand(lhs, SCRATCH1)
                    rhs_r = load_operand(rhs, SCRATCH2)
                    self.output.append(f'    sdiv {dst}, {lhs_r}, {rhs_r}')
                    store_result(instr.result, dst)

                elif instr.op == 'mod':
                    lhs, rhs = instr.operands
                    dst = result_reg(instr)
                    # Strength reduce: mod by power of 2 → bitwise AND
                    if is_immediate(rhs):
                        v = imm_val(rhs)
                        if v > 0 and (v & (v - 1)) == 0:
                            mask = v - 1
                            lhs_r = load_operand(lhs, SCRATCH1)
                            if fits_12bit(mask):
                                self.output.append(f'    and {dst}, {lhs_r}, #{mask}')
                            else:
                                for l in emit_mov_imm(SCRATCH2, mask):
                                    self.output.append(l)
                                self.output.append(f'    and {dst}, {lhs_r}, {SCRATCH2}')
                            store_result(instr.result, dst)
                            continue
                    lhs_r = load_operand(lhs, SCRATCH1)
                    rhs_r = load_operand(rhs, SCRATCH2)
                    self.output.append(f'    sdiv {SCRATCH3}, {lhs_r}, {rhs_r}')
                    self.output.append(f'    msub {dst}, {SCRATCH3}, {rhs_r}, {lhs_r}')
                    store_result(instr.result, dst)

                elif instr.op in ('and', 'or', 'xor'):
                    lhs, rhs = instr.operands
                    dst = result_reg(instr)
                    if is_immediate(lhs) and is_immediate(rhs):
                        vl, vr = imm_val(lhs), imm_val(rhs)
                        if instr.op == 'and': v = vl & vr
                        elif instr.op == 'or': v = vl | vr
                        else: v = vl ^ vr
                        for l in emit_mov_imm(dst, v):
                            self.output.append(l)
                    else:
                        lhs_r = load_operand(lhs, SCRATCH1)
                        rhs_r = load_operand(rhs, SCRATCH2)
                        aop = {'xor': 'eor', 'or': 'orr', 'and': 'and'}[instr.op]
                        self.output.append(f'    {aop} {dst}, {lhs_r}, {rhs_r}')
                    store_result(instr.result, dst)

                elif instr.op == 'shl':
                    lhs, rhs = instr.operands
                    dst = result_reg(instr)
                    lhs_r = load_operand(lhs, SCRATCH1)
                    if is_immediate(rhs):
                        self.output.append(f'    lsl {dst}, {lhs_r}, #{imm_val(rhs)}')
                    else:
                        rhs_r = load_operand(rhs, SCRATCH2)
                        self.output.append(f'    lsl {dst}, {lhs_r}, {rhs_r}')
                    store_result(instr.result, dst)

                elif instr.op == 'shr':
                    lhs, rhs = instr.operands
                    dst = result_reg(instr)
                    lhs_r = load_operand(lhs, SCRATCH1)
                    if is_immediate(rhs):
                        self.output.append(f'    asr {dst}, {lhs_r}, #{imm_val(rhs)}')
                    else:
                        rhs_r = load_operand(rhs, SCRATCH2)
                        self.output.append(f'    asr {dst}, {lhs_r}, {rhs_r}')
                    store_result(instr.result, dst)

                elif instr.op in CMP_OPS:
                    if instr.result in cmp_fuseable:
                        # Will be emitted with br_cond
                        continue
                    lhs, rhs = instr.operands
                    dst = result_reg(instr)
                    cond = CMP_OPS[instr.op]
                    self._emit_cmp(lhs, rhs, load_operand)
                    self.output.append(f'    cset {dst}, {cond}')
                    store_result(instr.result, dst)

                elif instr.op == 'load':
                    ptr_vreg = instr.operands[0]
                    dst = result_reg(instr)
                    ptr_r = load_operand(ptr_vreg, SCRATCH1)
                    if instr.ty == 'i8':
                        self.output.append(f'    ldrb {dst}, [{ptr_r}]')
                    else:
                        # i64, ptr, or anything else: 64-bit load
                        self.output.append(f'    ldr {dst}, [{ptr_r}]')
                    store_result(instr.result, dst)

                elif instr.op == 'store':
                    val_op = instr.operands[0]
                    ptr_vreg = instr.operands[1]
                    val_r = load_operand(val_op, SCRATCH1)
                    ptr_r = load_operand(ptr_vreg, SCRATCH2)
                    if instr.ty == 'i8':
                        self.output.append(f'    strb {val_r}, [{ptr_r}]')
                    else:
                        # i64, ptr, or anything else: 64-bit store
                        self.output.append(f'    str {val_r}, [{ptr_r}]')

                elif instr.op == 'zext':
                    src_vreg = instr.operands[0]
                    dst = result_reg(instr)
                    src_r = load_operand(src_vreg, SCRATCH1)
                    self.output.append(f'    and {dst}, {src_r}, #0xFF')
                    store_result(instr.result, dst)

                elif instr.op == 'sext':
                    src_vreg = instr.operands[0]
                    dst = result_reg(instr)
                    src_r = load_operand(src_vreg, SCRATCH1)
                    self.output.append(f'    sxtb {dst}, {src_r}')
                    store_result(instr.result, dst)

                elif instr.op == 'trunc':
                    src_vreg = instr.operands[0]
                    dst = result_reg(instr)
                    src_r = load_operand(src_vreg, SCRATCH1)
                    self.output.append(f'    and {dst}, {src_r}, #0xFF')
                    store_result(instr.result, dst)

                elif instr.op in ('ptrtoint', 'inttoptr'):
                    src_vreg = instr.operands[0]
                    dst = result_reg(instr)
                    src_r = load_operand(src_vreg, SCRATCH1)
                    if dst != src_r:
                        self.output.append(f'    mov {dst}, {src_r}')
                    store_result(instr.result, dst)

                elif instr.op == 'br':
                    target = instr.operands[0]
                    self._emit_phi_moves_for_edge(func, bname, target,
                                                   reg_assignment, spill_slots,
                                                   spill_base, load_operand, ensure_in_reg)
                    next_block = func.block_order[bi + 1] if bi + 1 < len(func.block_order) else None
                    if next_block != target:
                        self.output.append(f'    b .LBB_{func.name}_{target}')

                elif instr.op == 'br_cond':
                    cond_vreg = instr.operands[0]
                    true_label = instr.operands[1]
                    false_label = instr.operands[2]
                    next_block = func.block_order[bi + 1] if bi + 1 < len(func.block_order) else None

                    true_phis = self._get_phi_move_list(func, bname, true_label)
                    false_phis = self._get_phi_move_list(func, bname, false_label)

                    # Determine condition and emit comparison
                    use_cbz = False
                    cbz_reg = None
                    if cond_vreg in cmp_fuseable and cond_vreg in cmp_info:
                        ci = cmp_info[cond_vreg]
                        cond = CMP_OPS[ci.op]
                        cmp_lhs, cmp_rhs = ci.operands[0], ci.operands[1]
                        # Use cbz/cbnz when comparing against zero with eq/ne
                        if cond in ('eq', 'ne') and is_immediate(cmp_rhs) and imm_val(cmp_rhs) == 0:
                            cbz_reg = load_operand(cmp_lhs, SCRATCH1)
                            use_cbz = True
                        elif cond in ('eq', 'ne') and is_immediate(cmp_lhs) and imm_val(cmp_lhs) == 0:
                            cbz_reg = load_operand(cmp_rhs, SCRATCH1)
                            # Swap: cmp 0, x  with eq/ne is same as cmp x, 0
                            use_cbz = True
                        else:
                            self._emit_cmp(cmp_lhs, cmp_rhs, load_operand)
                    else:
                        # Compare against zero — use cbz/cbnz
                        cbz_reg = load_operand(cond_vreg, SCRATCH1)
                        cond = 'ne'
                        use_cbz = True

                    if not true_phis and not false_phis:
                        # Simple case: no phi copies needed
                        if next_block == false_label:
                            if use_cbz:
                                cbz_op = 'cbnz' if cond == 'ne' else 'cbz'
                                self.output.append(f'    {cbz_op} {cbz_reg}, .LBB_{func.name}_{true_label}')
                            else:
                                self.output.append(f'    b.{cond} .LBB_{func.name}_{true_label}')
                        elif next_block == true_label:
                            if use_cbz:
                                cbz_op = 'cbz' if cond == 'ne' else 'cbnz'
                                self.output.append(f'    {cbz_op} {cbz_reg}, .LBB_{func.name}_{false_label}')
                            else:
                                self.output.append(f'    b.{invert_cond(cond)} .LBB_{func.name}_{false_label}')
                        else:
                            if use_cbz:
                                cbz_op = 'cbnz' if cond == 'ne' else 'cbz'
                                self.output.append(f'    {cbz_op} {cbz_reg}, .LBB_{func.name}_{true_label}')
                            else:
                                self.output.append(f'    b.{cond} .LBB_{func.name}_{true_label}')
                            self.output.append(f'    b .LBB_{func.name}_{false_label}')
                    else:
                        # Phi copies needed — optimize branch layout
                        # Case 1: true path has no phi copies, false path does
                        #   -> branch to true on condition, fall through to false phi copies
                        if not true_phis and false_phis:
                            if use_cbz:
                                cbz_op = 'cbnz' if cond == 'ne' else 'cbz'
                                self.output.append(f'    {cbz_op} {cbz_reg}, .LBB_{func.name}_{true_label}')
                            else:
                                self.output.append(f'    b.{cond} .LBB_{func.name}_{true_label}')
                            # Fall through: false path phi copies
                            self._emit_phi_moves_for_edge(func, bname, false_label,
                                                           reg_assignment, spill_slots,
                                                           spill_base, load_operand, ensure_in_reg)
                            if next_block != false_label:
                                self.output.append(f'    b .LBB_{func.name}_{false_label}')

                        # Case 2: false path has no phi copies, true path does
                        #   -> branch to false on inverted condition, fall through to true phi copies
                        elif true_phis and not false_phis:
                            if use_cbz:
                                cbz_op = 'cbz' if cond == 'ne' else 'cbnz'
                                self.output.append(f'    {cbz_op} {cbz_reg}, .LBB_{func.name}_{false_label}')
                            else:
                                self.output.append(f'    b.{invert_cond(cond)} .LBB_{func.name}_{false_label}')
                            # Fall through: true path phi copies
                            self._emit_phi_moves_for_edge(func, bname, true_label,
                                                           reg_assignment, spill_slots,
                                                           spill_base, load_operand, ensure_in_reg)
                            if next_block != true_label:
                                self.output.append(f'    b .LBB_{func.name}_{true_label}')

                        # Case 3: both paths have phi copies — need skip label
                        else:
                            skip_label = f'.LBB_{func.name}_{bname}_to_false'
                            if use_cbz:
                                cbz_op = 'cbz' if cond == 'ne' else 'cbnz'
                                self.output.append(f'    {cbz_op} {cbz_reg}, {skip_label}')
                            else:
                                self.output.append(f'    b.{invert_cond(cond)} {skip_label}')
                            # True path
                            self._emit_phi_moves_for_edge(func, bname, true_label,
                                                           reg_assignment, spill_slots,
                                                           spill_base, load_operand, ensure_in_reg)
                            self.output.append(f'    b .LBB_{func.name}_{true_label}')
                            self.output.append(f'{skip_label}:')
                            # False path
                            self._emit_phi_moves_for_edge(func, bname, false_label,
                                                           reg_assignment, spill_slots,
                                                           spill_base, load_operand, ensure_in_reg)
                            if next_block != false_label:
                                self.output.append(f'    b .LBB_{func.name}_{false_label}')

                elif instr.op == 'ret':
                    val = instr.operands[0]
                    if is_vreg(val):
                        src = ensure_in_reg(val, 'x0')
                        if src != 'x0':
                            self.output.append(f'    mov x0, {src}')
                    else:
                        for l in emit_mov_imm('x0', imm_val(val)):
                            self.output.append(l)
                    # Restore callee-saved
                    offset = 16
                    for p in save_pairs[1:]:
                        if p[1]:
                            self.output.append(f'    ldp {p[0]}, {p[1]}, [sp, #{offset}]')
                        else:
                            self.output.append(f'    ldr {p[0]}, [sp, #{offset}]')
                        offset += 16
                    self.output.append(f'    ldp x29, x30, [sp], #{frame_size}')
                    self.output.append('    ret')

                elif instr.op == 'call':
                    # Save caller-saved registers that are live past this call
                    live_caller = []
                    for v, preg in reg_assignment.items():
                        if preg in CALLER_SAVED_SCRATCH and v in intervals:
                            s, e = intervals[v]
                            if s < instr.seq and e > instr.seq:
                                live_caller.append((v, preg))

                    save_offsets = {}
                    for ci_idx, (v, preg) in enumerate(live_caller):
                        off = caller_save_base + ci_idx * 8
                        self.output.append(f'    str {preg}, [x29, #{off}]')
                        save_offsets[preg] = off

                    # Set up arguments: x0-x7
                    # Be careful not to clobber source regs before reading them
                    # Simple approach: if an arg reg is a source for a later arg, use indirection
                    arg_moves = []
                    for ai, arg_val in enumerate(instr.call_args):
                        dst_reg = f'x{ai}'
                        if is_vreg(arg_val):
                            src = ensure_in_reg(arg_val, SCRATCH1)
                            arg_moves.append((dst_reg, src))
                        else:
                            # Load immediate directly
                            for l in emit_mov_imm(dst_reg, imm_val(arg_val)):
                                self.output.append(l)

                    # Emit register moves for args
                    for dst_reg, src_reg in arg_moves:
                        if dst_reg != src_reg:
                            self.output.append(f'    mov {dst_reg}, {src_reg}')

                    self.output.append(f'    bl _{instr.call_target}')

                    # Move result
                    if instr.result and instr.result not in dead:
                        dst = result_reg(instr)
                        if dst != 'x0':
                            self.output.append(f'    mov {dst}, x0')
                        store_result(instr.result, dst)

                    # Restore caller-saved regs
                    for v, preg in live_caller:
                        off = save_offsets[preg]
                        self.output.append(f'    ldr {preg}, [x29, #{off}]')

    def _emit_cmp(self, lhs, rhs, load_operand):
        """Emit a cmp instruction with immediate folding."""
        if is_immediate(rhs) and fits_12bit(abs(imm_val(rhs))):
            v = imm_val(rhs)
            lhs_r = load_operand(lhs, 'x8')
            if v >= 0:
                self.output.append(f'    cmp {lhs_r}, #{v}')
            else:
                self.output.append(f'    cmn {lhs_r}, #{-v}')
        elif is_immediate(lhs) and is_immediate(rhs):
            lhs_r = load_operand(lhs, 'x8')
            rhs_r = load_operand(rhs, 'x16')
            self.output.append(f'    cmp {lhs_r}, {rhs_r}')
        else:
            lhs_r = load_operand(lhs, 'x8')
            rhs_r = load_operand(rhs, 'x16')
            self.output.append(f'    cmp {lhs_r}, {rhs_r}')

    def _get_phi_move_list(self, func, src_block_name, dst_block_name):
        """Get [(dst_vreg, src_value)] for phi nodes when branching from src to dst.
        Filters out coalesced pairs (same register = no move needed)."""
        dst_block = func.blocks[dst_block_name]
        moves = []
        for instr in dst_block.instructions:
            if instr.op != 'phi':
                break
            for val, label in instr.phi_args:
                if label == src_block_name:
                    # Skip if coalesced (same canonical vreg)
                    dst_canonical = self._coalesced.get(instr.result, instr.result)
                    if is_vreg(val):
                        src_canonical = self._coalesced.get(val, val)
                        if dst_canonical == src_canonical:
                            continue  # Coalesced — no copy needed!
                    moves.append((instr.result, val))
        return moves

    def _emit_phi_moves_for_edge(self, func, src_block_name, dst_block_name,
                                  reg_assignment, spill_slots, spill_base,
                                  load_operand, ensure_in_reg):
        """Emit parallel register moves for phi nodes."""
        moves = self._get_phi_move_list(func, src_block_name, dst_block_name)
        if not moves:
            return

        SCRATCH1 = 'x8'
        SCRATCH3 = 'x17'

        # Resolve to concrete locations (with coalescing)
        concrete = []  # (dst_loc, src_loc, dst_vreg_name)
        for dst_vreg, src_val in moves:
            # Resolve coalesced names
            dst_v = self._coalesced.get(dst_vreg, dst_vreg)
            # dst location
            if dst_v in reg_assignment:
                dst_loc = reg_assignment[dst_v]
            elif dst_v in spill_slots:
                dst_loc = ('spill', spill_base + spill_slots[dst_v] * 8)
            else:
                continue

            # src location
            if is_vreg(src_val):
                src_v = self._coalesced.get(src_val, src_val)
                if src_v in reg_assignment:
                    src_loc = reg_assignment[src_v]
                elif src_v in spill_slots:
                    src_loc = ('spill', spill_base + spill_slots[src_val] * 8)
                else:
                    continue
            elif is_immediate(src_val):
                src_loc = ('imm', imm_val(src_val))
            else:
                continue

            if dst_loc != src_loc:
                concrete.append((dst_loc, src_loc))

        if not concrete:
            return

        # Emit parallel moves handling circular dependencies
        remaining = list(concrete)
        max_iter = len(remaining) * 3 + 5
        iteration = 0

        while remaining and iteration < max_iter:
            iteration += 1
            progress = False
            new_remaining = []

            for dst, src in remaining:
                # Check if dst is used as source by another remaining move
                blocking = False
                for d2, s2 in remaining:
                    if (d2, s2) != (dst, src) and s2 == dst:
                        blocking = True
                        break

                if not blocking:
                    self._emit_move(dst, src, SCRATCH1)
                    progress = True
                else:
                    new_remaining.append((dst, src))

            remaining = new_remaining

            if not progress and remaining:
                # Cycle: break with temp register
                dst, src = remaining[0]
                # Save dst to SCRATCH3
                self._emit_move(SCRATCH3, dst, SCRATCH1)
                self._emit_move(dst, src, SCRATCH1)
                remaining = [(d, (SCRATCH3 if s == dst else s)) for d, s in remaining[1:]]

    def _emit_move(self, dst, src, scratch):
        """Emit a single move. dst/src can be register name, ('spill', off), or ('imm', val)."""
        if isinstance(src, tuple):
            if src[0] == 'imm':
                if isinstance(dst, tuple) and dst[0] == 'spill':
                    for l in emit_mov_imm(scratch, src[1]):
                        self.output.append(l)
                    self.output.append(f'    str {scratch}, [x29, #{dst[1]}]')
                else:
                    for l in emit_mov_imm(dst, src[1]):
                        self.output.append(l)
            elif src[0] == 'spill':
                if isinstance(dst, tuple) and dst[0] == 'spill':
                    self.output.append(f'    ldr {scratch}, [x29, #{src[1]}]')
                    self.output.append(f'    str {scratch}, [x29, #{dst[1]}]')
                else:
                    self.output.append(f'    ldr {dst}, [x29, #{src[1]}]')
        else:
            # src is a register
            if isinstance(dst, tuple) and dst[0] == 'spill':
                self.output.append(f'    str {src}, [x29, #{dst[1]}]')
            else:
                if dst != src:
                    self.output.append(f'    mov {dst}, {src}')


def main():
    if len(sys.argv) < 2:
        print("Usage: irc_opt.py <input.ir>", file=sys.stderr)
        sys.exit(1)
    with open(sys.argv[1]) as f:
        text = f.read()
    compiler = IRCompiler()
    compiler.parse(text)
    asm = compiler.compile()
    sys.stdout.write(asm)


if __name__ == '__main__':
    main()
