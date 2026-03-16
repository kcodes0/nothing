"""SSA IR emitter for the .lang language.

Converts a typed AST into SSA IR text compatible with irc_opt.py.

Key design:
- Each variable is tracked via current_defs[var_name] = ssa_vreg_name
- If/else: snapshot defs before each branch, emit phi nodes at join for differing defs
- While loops: pre-scan body for assigned vars, create phi placeholders at header,
  emit body, then patch phi nodes with back-edge values
"""

from ast_nodes import (
    Type, IntType, BoolType, PtrType, VoidType,
    Expr, IntLitExpr, BoolLitExpr, IdentExpr, BinOpExpr, UnaryOpExpr,
    CallExpr, IndexExpr, CastExpr,
    Stmt, LetStmt, AssignStmt, ReturnStmt, IfStmt, WhileStmt,
    ExprStmt, BreakStmt, ContinueStmt,
    Param, FuncDecl, ExternDecl, Program,
)


def ir_type(ty: Type) -> str:
    if isinstance(ty, IntType):
        return f'i{ty.bits}'
    elif isinstance(ty, BoolType):
        return 'i64'
    elif isinstance(ty, PtrType):
        return 'ptr'
    elif isinstance(ty, VoidType):
        return 'i64'  # void functions still need a return type in IR
    return 'i64'


class IREmitter:
    def __init__(self):
        self.output_lines = []
        self._vreg_counter = 0
        self._block_counter = 0
        # Current definitions: var_name -> vreg_name
        self.current_defs = {}
        # Var types: var_name -> IR type string
        self.var_types = {}
        # Lines for the current function body (buffered)
        self._func_lines = []
        # Current block name
        self._current_block = None
        # For break/continue
        self._break_target = None
        self._continue_target = None
        # Track which blocks are terminated (have br/br_cond/ret)
        self._block_terminated = False
        # Deferred phi patches: list of (line_index, phi_info) for while loops
        self._phi_patches = []

    def emit(self, program: Program) -> str:
        self.output_lines = []

        # Emit extern declarations first
        for decl in program.decls:
            if isinstance(decl, ExternDecl):
                self._emit_extern(decl)

        # Emit function definitions
        for decl in program.decls:
            if isinstance(decl, FuncDecl):
                self._emit_func(decl)

        return '\n'.join(self.output_lines) + '\n'

    def _emit_extern(self, decl: ExternDecl):
        param_types = ', '.join(ir_type(t) for t in decl.param_types)
        ret = ir_type(decl.ret_type)
        if isinstance(decl.ret_type, VoidType):
            self.output_lines.append(f'extern @{decl.name}({param_types})')
        else:
            self.output_lines.append(f'extern @{decl.name}({param_types}) -> {ret}')

    def _emit_func(self, decl: FuncDecl):
        self._vreg_counter = 0
        self._block_counter = 0
        self.current_defs = {}
        self.var_types = {}
        self._func_lines = []
        self._current_block = None
        self._block_terminated = False
        self._break_target = None
        self._continue_target = None

        # Function header
        param_type_strs = ', '.join(ir_type(p.type_ann) for p in decl.params)
        ret_ty = ir_type(decl.ret_type)
        self.output_lines.append(f'func @{decl.name}({param_type_strs}) -> {ret_ty} {{')

        # Entry block
        self._start_block('entry')

        # Load parameters
        for i, p in enumerate(decl.params):
            vreg = self._new_vreg(p.name)
            ity = ir_type(p.type_ann)
            self._emit(f'  {vreg} = arg {ity} {i}')
            self.current_defs[p.name] = vreg
            self.var_types[p.name] = ity

        # Emit body
        for stmt in decl.body:
            self._emit_stmt(stmt)

        # If function doesn't end with a return, add a default one
        if not self._block_terminated:
            self._emit(f'  ret {ret_ty} 0')

        # Write function lines
        for line in self._func_lines:
            self.output_lines.append(line)
        self.output_lines.append('}')
        self.output_lines.append('')

    def _new_vreg(self, hint='t'):
        self._vreg_counter += 1
        return f'%{hint}_{self._vreg_counter}'

    def _new_block(self, hint='bb'):
        self._block_counter += 1
        return f'{hint}_{self._block_counter}'

    def _emit(self, line):
        self._func_lines.append(line)

    def _start_block(self, name):
        self._current_block = name
        self._block_terminated = False
        self._emit(f'{name}:')

    def _terminate_block(self):
        self._block_terminated = True

    # ----- Statement emission -----

    def _emit_stmt(self, stmt: Stmt):
        if self._block_terminated:
            return  # Dead code after terminator

        if isinstance(stmt, LetStmt):
            self._emit_let(stmt)
        elif isinstance(stmt, AssignStmt):
            self._emit_assign(stmt)
        elif isinstance(stmt, ReturnStmt):
            self._emit_return(stmt)
        elif isinstance(stmt, IfStmt):
            self._emit_if(stmt)
        elif isinstance(stmt, WhileStmt):
            self._emit_while(stmt)
        elif isinstance(stmt, ExprStmt):
            self._emit_expr(stmt.expr)
        elif isinstance(stmt, BreakStmt):
            self._emit_break()
        elif isinstance(stmt, ContinueStmt):
            self._emit_continue()

    def _emit_let(self, stmt: LetStmt):
        vreg = self._emit_expr(stmt.init)
        ity = ir_type(stmt.type_ann)
        self.current_defs[stmt.name] = vreg
        self.var_types[stmt.name] = ity

    def _emit_assign(self, stmt: AssignStmt):
        target = stmt.target
        vreg = self._emit_expr(stmt.value)

        if isinstance(target, IdentExpr):
            # Simple variable assignment
            self.current_defs[target.name] = vreg
        elif isinstance(target, UnaryOpExpr) and target.op == '*':
            # Pointer dereference store: *ptr = value
            ptr_vreg = self._emit_expr(target.operand)
            val_ty = self._expr_ir_type(stmt.value)
            self._emit(f'  store {val_ty} {vreg}, ptr {ptr_vreg}')
        elif isinstance(target, IndexExpr):
            # Indexed store: arr[i] = value
            base_vreg = self._emit_expr(target.base)
            idx_vreg = self._emit_expr(target.index)
            val_ty = self._expr_ir_type(stmt.value)
            # Compute element size from pointee type
            pointee_ty = target.resolved_type
            if isinstance(pointee_ty, IntType):
                elem_size = pointee_ty.bits // 8
            else:
                elem_size = 8  # pointer size
            offset = self._new_vreg('offset')
            self._emit(f'  {offset} = mul i64 {idx_vreg}, {elem_size}')
            addr = self._new_vreg('addr')
            self._emit(f'  {addr} = add ptr {base_vreg}, {offset}')
            self._emit(f'  store {val_ty} {vreg}, ptr {addr}')

    def _emit_return(self, stmt: ReturnStmt):
        if stmt.value is not None:
            vreg = self._emit_expr(stmt.value)
            # Determine type from the expression
            ity = self._expr_ir_type(stmt.value)
            self._emit(f'  ret {ity} {vreg}')
        else:
            self._emit(f'  ret i64 0')
        self._terminate_block()

    def _emit_break(self):
        if self._break_target:
            self._emit(f'  br @{self._break_target}')
            self._terminate_block()

    def _emit_continue(self):
        if self._continue_target:
            self._emit(f'  br @{self._continue_target}')
            self._terminate_block()

    # ----- If/else SSA -----

    def _emit_if(self, stmt: IfStmt):
        cond_vreg = self._emit_expr(stmt.condition)

        # Convert bool condition to proper form for br_cond
        # br_cond expects a vreg that is non-zero for true
        cond_to_use = self._ensure_i64_cond(cond_vreg, stmt.condition)

        then_block = self._new_block('then')
        else_block = self._new_block('else') if stmt.else_body else None
        join_block = self._new_block('join')

        # Check: do both branches always return? If so, no join needed.
        then_always_returns = self._always_returns(stmt.then_body)
        else_always_returns = self._always_returns(stmt.else_body) if stmt.else_body else False

        if stmt.else_body:
            self._emit(f'  br_cond {cond_to_use}, @{then_block}, @{else_block}')
        else:
            self._emit(f'  br_cond {cond_to_use}, @{then_block}, @{join_block}')
        self._terminate_block()

        # Save definitions before branching
        defs_before = dict(self.current_defs)
        pre_block = self._current_block

        # Emit then-block
        self._start_block(then_block)
        for s in stmt.then_body:
            self._emit_stmt(s)
        defs_after_then = dict(self.current_defs)
        then_exit_block = self._current_block
        then_terminated = self._block_terminated
        if not self._block_terminated:
            self._emit(f'  br @{join_block}')
            self._terminate_block()

        # Emit else-block (if present)
        defs_after_else = dict(defs_before)
        else_exit_block = None
        else_terminated = False
        if stmt.else_body:
            self.current_defs = dict(defs_before)
            self._start_block(else_block)
            for s in stmt.else_body:
                self._emit_stmt(s)
            defs_after_else = dict(self.current_defs)
            else_exit_block = self._current_block
            else_terminated = self._block_terminated
            if not self._block_terminated:
                self._emit(f'  br @{join_block}')
                self._terminate_block()
        else:
            else_exit_block = pre_block
            else_terminated = False

        # If both branches always return, no join block needed
        if then_always_returns and else_always_returns:
            # Both branches return, don't emit join block.
            # Mark as terminated since there's no continuation.
            self._block_terminated = True
            return

        # Emit join block with phi nodes for any differing defs
        self._start_block(join_block)

        # Determine which defs to use for the join
        if then_terminated and else_terminated:
            # Both terminated -- shouldn't reach here normally
            self._block_terminated = True
            return

        if then_terminated and not else_terminated:
            # Only else path reaches join
            if stmt.else_body:
                self.current_defs = dict(defs_after_else)
            else:
                self.current_defs = dict(defs_before)
            return

        if not then_terminated and else_terminated:
            # Only then path reaches join
            self.current_defs = dict(defs_after_then)
            return

        # Both branches reach join -- need phi nodes
        all_vars = set(defs_after_then.keys()) | set(defs_after_else.keys())
        new_defs = {}
        for var in all_vars:
            then_val = defs_after_then.get(var)
            else_val = defs_after_else.get(var)
            if then_val is None or else_val is None:
                # Variable defined in only one branch -- use whatever we have
                new_defs[var] = then_val or else_val
            elif then_val != else_val:
                # Different definitions -- need phi
                ity = self.var_types.get(var, 'i64')
                phi_reg = self._new_vreg(var)
                self._emit(f'  {phi_reg} = phi {ity} [{then_val}, @{then_exit_block}], [{else_val}, @{else_exit_block}]')
                new_defs[var] = phi_reg
            else:
                new_defs[var] = then_val

        self.current_defs = new_defs

    # ----- While loop SSA -----

    def _emit_while(self, stmt: WhileStmt):
        # Pre-scan body for assigned variables
        assigned_vars = self._scan_assigned_vars(stmt.body)

        header_block = self._new_block('while_header')
        body_block = self._new_block('while_body')
        exit_block = self._new_block('while_exit')

        # Save break/continue targets
        old_break = self._break_target
        old_continue = self._continue_target
        self._break_target = exit_block
        self._continue_target = header_block

        # Branch to header
        entry_block = self._current_block
        self._emit(f'  br @{header_block}')
        self._terminate_block()

        # Start header block
        self._start_block(header_block)

        # Create phi placeholders for assigned vars
        # phi_info: var_name -> (phi_vreg, phi_line_index, entry_val)
        phi_info = {}
        defs_at_entry = dict(self.current_defs)

        for var in assigned_vars:
            if var in self.current_defs:
                ity = self.var_types.get(var, 'i64')
                phi_vreg = self._new_vreg(var)
                entry_val = self.current_defs[var]
                # Emit placeholder phi -- will be patched after body
                phi_line_idx = len(self._func_lines)
                self._emit(f'  {phi_vreg} = phi {ity} [{entry_val}, @{entry_block}], [PLACEHOLDER, @PLACEHOLDER_BLOCK]')
                phi_info[var] = (phi_vreg, phi_line_idx, entry_val)
                self.current_defs[var] = phi_vreg

        # Emit condition
        cond_vreg = self._emit_expr(stmt.condition)
        cond_to_use = self._ensure_i64_cond(cond_vreg, stmt.condition)

        self._emit(f'  br_cond {cond_to_use}, @{body_block}, @{exit_block}')
        self._terminate_block()

        # Emit body
        self._start_block(body_block)
        for s in stmt.body:
            self._emit_stmt(s)

        body_exit_block = self._current_block
        if not self._block_terminated:
            self._emit(f'  br @{header_block}')
            self._terminate_block()

        # Patch phi nodes with back-edge values
        for var, (phi_vreg, phi_line_idx, entry_val) in phi_info.items():
            back_val = self.current_defs.get(var, entry_val)
            ity = self.var_types.get(var, 'i64')
            self._func_lines[phi_line_idx] = f'  {phi_vreg} = phi {ity} [{entry_val}, @{entry_block}], [{back_val}, @{body_exit_block}]'

        # Restore break/continue targets
        self._break_target = old_break
        self._continue_target = old_continue

        # Start exit block with defs from header (phi results)
        self._start_block(exit_block)

        # After the loop, current_defs should reflect the phi results for
        # any variable that was assigned in the loop (since the loop may
        # have run zero times, the phi in the header covers both cases)
        for var, (phi_vreg, _, _) in phi_info.items():
            self.current_defs[var] = phi_vreg

    def _scan_assigned_vars(self, stmts) -> set:
        """Pre-scan a statement list for all variables that are assigned."""
        assigned = set()
        for stmt in stmts:
            if isinstance(stmt, AssignStmt):
                target = stmt.target
                if isinstance(target, IdentExpr):
                    assigned.add(target.name)
                # Deref/index stores don't create SSA variable assignments
            elif isinstance(stmt, IfStmt):
                assigned |= self._scan_assigned_vars(stmt.then_body)
                assigned |= self._scan_assigned_vars(stmt.else_body)
            elif isinstance(stmt, WhileStmt):
                assigned |= self._scan_assigned_vars(stmt.body)
            elif isinstance(stmt, LetStmt):
                # LetStmt introduces a new variable -- if it's reassigned later
                # we'll catch it via AssignStmt. But we also need to handle
                # the case where a let inside a loop body shadows an outer var.
                assigned.add(stmt.name)
        return assigned

    # ----- Expression emission -----

    def _emit_expr(self, expr: Expr) -> str:
        """Emit IR for an expression and return the vreg holding the result."""
        if isinstance(expr, IntLitExpr):
            return str(expr.value)
        elif isinstance(expr, BoolLitExpr):
            return '1' if expr.value else '0'
        elif isinstance(expr, IdentExpr):
            return self.current_defs.get(expr.name, f'%{expr.name}')
        elif isinstance(expr, BinOpExpr):
            return self._emit_binop(expr)
        elif isinstance(expr, UnaryOpExpr):
            return self._emit_unary(expr)
        elif isinstance(expr, CallExpr):
            return self._emit_call(expr)
        elif isinstance(expr, CastExpr):
            return self._emit_expr(expr.expr)
        elif isinstance(expr, IndexExpr):
            return self._emit_index(expr)
        return '0'

    def _emit_binop(self, expr: BinOpExpr) -> str:
        op = expr.op

        # Short-circuit logical operators
        if op == '&&':
            return self._emit_logical_and(expr)
        if op == '||':
            return self._emit_logical_or(expr)

        left = self._emit_expr(expr.left)
        right = self._emit_expr(expr.right)
        ity = self._expr_ir_type(expr.left)

        # Map language operators to IR opcodes
        op_map = {
            '+': 'add', '-': 'sub', '*': 'mul', '/': 'div', '%': 'mod',
            '&': 'and', '|': 'or', '^': 'xor', '<<': 'shl', '>>': 'shr',
            '==': 'cmp_eq', '!=': 'cmp_ne',
            '<': 'cmp_lt', '>': 'cmp_gt', '<=': 'cmp_le', '>=': 'cmp_ge',
        }
        ir_op = op_map.get(op)
        if ir_op is None:
            raise RuntimeError(f'Unknown binary operator: {op}')

        result = self._new_vreg('t')
        self._emit(f'  {result} = {ir_op} {ity} {left}, {right}')
        return result

    def _emit_logical_and(self, expr: BinOpExpr) -> str:
        """Short-circuit &&: if left is false, result is 0, else result is right."""
        left = self._emit_expr(expr.left)
        left_cond = self._ensure_i64_cond(left, expr.left)

        rhs_block = self._new_block('and_rhs')
        join_block = self._new_block('and_join')

        left_block = self._current_block
        self._emit(f'  br_cond {left_cond}, @{rhs_block}, @{join_block}')
        self._terminate_block()

        # Save defs
        defs_before = dict(self.current_defs)

        self._start_block(rhs_block)
        right = self._emit_expr(expr.right)
        right_cond = self._ensure_i64_cond(right, expr.right)
        rhs_exit = self._current_block
        self._emit(f'  br @{join_block}')
        self._terminate_block()

        self._start_block(join_block)
        result = self._new_vreg('and')
        self._emit(f'  {result} = phi i64 [0, @{left_block}], [{right_cond}, @{rhs_exit}]')

        # Merge defs
        self.current_defs = dict(defs_before)
        return result

    def _emit_logical_or(self, expr: BinOpExpr) -> str:
        """Short-circuit ||: if left is true, result is 1, else result is right."""
        left = self._emit_expr(expr.left)
        left_cond = self._ensure_i64_cond(left, expr.left)

        rhs_block = self._new_block('or_rhs')
        join_block = self._new_block('or_join')

        left_block = self._current_block
        self._emit(f'  br_cond {left_cond}, @{join_block}, @{rhs_block}')
        self._terminate_block()

        defs_before = dict(self.current_defs)

        self._start_block(rhs_block)
        right = self._emit_expr(expr.right)
        right_cond = self._ensure_i64_cond(right, expr.right)
        rhs_exit = self._current_block
        self._emit(f'  br @{join_block}')
        self._terminate_block()

        self._start_block(join_block)
        result = self._new_vreg('or')
        self._emit(f'  {result} = phi i64 [1, @{left_block}], [{right_cond}, @{rhs_exit}]')

        self.current_defs = dict(defs_before)
        return result

    def _emit_unary(self, expr: UnaryOpExpr) -> str:
        operand = self._emit_expr(expr.operand)
        ity = self._expr_ir_type(expr.operand)

        if expr.op == '-':
            result = self._new_vreg('neg')
            self._emit(f'  {result} = sub {ity} 0, {operand}')
            return result
        elif expr.op == '!':
            result = self._new_vreg('not')
            self._emit(f'  {result} = cmp_eq {ity} {operand}, 0')
            return result
        elif expr.op == '~':
            # Bitwise NOT: XOR with -1
            all_ones = self._new_vreg('ones')
            self._emit(f'  {all_ones} = sub {ity} 0, 1')
            result = self._new_vreg('bnot')
            self._emit(f'  {result} = xor {ity} {operand}, {all_ones}')
            return result
        elif expr.op == '*':
            # Pointer dereference (load)
            load_ty = ir_type(expr.resolved_type) if expr.resolved_type else 'i64'
            result = self._new_vreg('deref')
            self._emit(f'  {result} = load {load_ty} {operand}')
            return result
        return operand

    def _emit_call(self, expr: CallExpr) -> str:
        arg_strs = []
        for arg in expr.args:
            vreg = self._emit_expr(arg)
            ity = self._expr_ir_type(arg)
            arg_strs.append(f'{ity} {vreg}')

        ret_ty = ir_type(expr.resolved_type) if expr.resolved_type else 'i64'
        result = self._new_vreg('call')
        args_part = ', '.join(arg_strs)
        if args_part:
            self._emit(f'  {result} = call {ret_ty} @{expr.func_name}, {args_part}')
        else:
            self._emit(f'  {result} = call {ret_ty} @{expr.func_name}')
        return result

    def _emit_index(self, expr: IndexExpr) -> str:
        """Emit IR for arr[i] — pointer arithmetic + load."""
        base_vreg = self._emit_expr(expr.base)
        idx_vreg = self._emit_expr(expr.index)
        # Compute element size from the resolved pointee type
        load_ty = ir_type(expr.resolved_type) if expr.resolved_type else 'i64'
        pointee_ty = expr.resolved_type
        if isinstance(pointee_ty, IntType):
            elem_size = pointee_ty.bits // 8
        else:
            elem_size = 8  # pointer size
        offset = self._new_vreg('offset')
        self._emit(f'  {offset} = mul i64 {idx_vreg}, {elem_size}')
        addr = self._new_vreg('addr')
        self._emit(f'  {addr} = add ptr {base_vreg}, {offset}')
        result = self._new_vreg('idx')
        self._emit(f'  {result} = load {load_ty} {addr}')
        return result

    # ----- Helpers -----

    def _expr_ir_type(self, expr: Expr) -> str:
        """Get the IR type string for a resolved expression."""
        if expr.resolved_type:
            return ir_type(expr.resolved_type)
        return 'i64'

    def _ensure_i64_cond(self, vreg: str, expr: Expr) -> str:
        """Ensure a condition value is usable by br_cond.

        br_cond expects a vreg, not an immediate. If the expression result
        is a literal, we need to generate an instruction to materialize it.
        Also, comparison results are already 0/1 vregs so they work directly.
        """
        # If it's already a vreg, use it directly
        if vreg.startswith('%'):
            return vreg
        # It's a literal -- need to materialize it via a comparison or identity op
        result = self._new_vreg('cond')
        self._emit(f'  {result} = cmp_ne i64 {vreg}, 0')
        return result

    def _always_returns(self, stmts) -> bool:
        """Check if a list of statements always returns."""
        for stmt in stmts:
            if isinstance(stmt, ReturnStmt):
                return True
            if isinstance(stmt, IfStmt):
                if (stmt.else_body and
                    self._always_returns(stmt.then_body) and
                    self._always_returns(stmt.else_body)):
                    return True
        return False
