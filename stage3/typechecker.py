"""Type checker for the .lang language.

Resolves types for every expression and validates type correctness.
Annotates each expression node with its resolved_type field.
"""

from ast_nodes import (
    Type, IntType, BoolType, PtrType, VoidType,
    Expr, IntLitExpr, BoolLitExpr, IdentExpr, BinOpExpr, UnaryOpExpr,
    CallExpr, IndexExpr, CastExpr,
    Stmt, LetStmt, AssignStmt, ReturnStmt, IfStmt, WhileStmt,
    ExprStmt, BreakStmt, ContinueStmt,
    Param, FuncDecl, ExternDecl, Program,
)


class TypeError_(Exception):
    def __init__(self, msg, line=0):
        self.line = line
        super().__init__(f'Type error at line {line}: {msg}')


def types_equal(a: Type, b: Type) -> bool:
    if type(a) != type(b):
        return False
    if isinstance(a, IntType):
        return a.bits == b.bits
    return True


def type_name(t: Type) -> str:
    if t is None:
        return '<unresolved>'
    return repr(t)


class TypeChecker:
    def __init__(self):
        # Global function signatures: name -> (param_types, ret_type)
        self.functions = {}
        # Stack of scopes; each scope is {name: Type}
        self.scopes = []
        # Current function return type
        self.current_ret_type = None
        self.in_loop = False

    def check(self, program: Program):
        # First pass: register all function signatures
        for decl in program.decls:
            if isinstance(decl, FuncDecl):
                ptypes = [p.type_ann for p in decl.params]
                self.functions[decl.name] = (ptypes, decl.ret_type)
            elif isinstance(decl, ExternDecl):
                self.functions[decl.name] = (decl.param_types, decl.ret_type)

        # Second pass: type-check function bodies
        for decl in program.decls:
            if isinstance(decl, FuncDecl):
                self._check_func(decl)

    def _push_scope(self):
        self.scopes.append({})

    def _pop_scope(self):
        self.scopes.pop()

    def _define(self, name: str, ty: Type, line: int):
        if name in self.scopes[-1]:
            raise TypeError_(f'Variable {name!r} already defined in this scope', line)
        self.scopes[-1][name] = ty

    def _lookup(self, name: str, line: int) -> Type:
        for scope in reversed(self.scopes):
            if name in scope:
                return scope[name]
        raise TypeError_(f'Undefined variable {name!r}', line)

    def _check_func(self, decl: FuncDecl):
        self.current_ret_type = decl.ret_type
        self._push_scope()
        for p in decl.params:
            self._define(p.name, p.type_ann, decl.line)
        for stmt in decl.body:
            self._check_stmt(stmt)
        self._pop_scope()

    def _check_stmt(self, stmt: Stmt):
        if isinstance(stmt, LetStmt):
            self._check_let(stmt)
        elif isinstance(stmt, AssignStmt):
            self._check_assign(stmt)
        elif isinstance(stmt, ReturnStmt):
            self._check_return(stmt)
        elif isinstance(stmt, IfStmt):
            self._check_if(stmt)
        elif isinstance(stmt, WhileStmt):
            self._check_while(stmt)
        elif isinstance(stmt, ExprStmt):
            self._check_expr(stmt.expr)
        elif isinstance(stmt, BreakStmt):
            if not self.in_loop:
                raise TypeError_('break outside of loop', stmt.line)
        elif isinstance(stmt, ContinueStmt):
            if not self.in_loop:
                raise TypeError_('continue outside of loop', stmt.line)

    def _check_let(self, stmt: LetStmt):
        init_type = self._check_expr(stmt.init)
        declared = stmt.type_ann
        if not types_equal(init_type, declared):
            # Allow implicit conversion for integer types and bool->int
            if isinstance(init_type, BoolType) and isinstance(declared, IntType):
                pass  # bool -> int is ok
            elif isinstance(init_type, IntType) and isinstance(declared, IntType):
                pass  # i8 <-> i64 is ok for now
            else:
                raise TypeError_(
                    f'Cannot assign {type_name(init_type)} to {type_name(declared)}',
                    stmt.line,
                )
        self._define(stmt.name, declared, stmt.line)

    def _check_assign(self, stmt: AssignStmt):
        var_type = self._lookup(stmt.target, stmt.line)
        val_type = self._check_expr(stmt.value)
        if not types_equal(var_type, val_type):
            if isinstance(val_type, BoolType) and isinstance(var_type, IntType):
                pass
            elif isinstance(val_type, IntType) and isinstance(var_type, IntType):
                pass
            else:
                raise TypeError_(
                    f'Cannot assign {type_name(val_type)} to variable of type {type_name(var_type)}',
                    stmt.line,
                )

    def _check_return(self, stmt: ReturnStmt):
        if stmt.value is None:
            if not isinstance(self.current_ret_type, VoidType):
                raise TypeError_('Missing return value', stmt.line)
        else:
            val_type = self._check_expr(stmt.value)
            if not isinstance(self.current_ret_type, VoidType):
                if not types_equal(val_type, self.current_ret_type):
                    if isinstance(val_type, BoolType) and isinstance(self.current_ret_type, IntType):
                        pass
                    elif isinstance(val_type, IntType) and isinstance(self.current_ret_type, IntType):
                        pass
                    else:
                        raise TypeError_(
                            f'Return type mismatch: expected {type_name(self.current_ret_type)}, '
                            f'got {type_name(val_type)}',
                            stmt.line,
                        )

    def _check_if(self, stmt: IfStmt):
        cond_type = self._check_expr(stmt.condition)
        # Allow bool or int as condition
        if not isinstance(cond_type, (BoolType, IntType)):
            raise TypeError_(f'Condition must be bool or int, got {type_name(cond_type)}', stmt.line)
        self._push_scope()
        for s in stmt.then_body:
            self._check_stmt(s)
        self._pop_scope()
        if stmt.else_body:
            self._push_scope()
            for s in stmt.else_body:
                self._check_stmt(s)
            self._pop_scope()

    def _check_while(self, stmt: WhileStmt):
        cond_type = self._check_expr(stmt.condition)
        if not isinstance(cond_type, (BoolType, IntType)):
            raise TypeError_(f'Condition must be bool or int, got {type_name(cond_type)}', stmt.line)
        old_in_loop = self.in_loop
        self.in_loop = True
        self._push_scope()
        for s in stmt.body:
            self._check_stmt(s)
        self._pop_scope()
        self.in_loop = old_in_loop

    def _check_expr(self, expr: Expr) -> Type:
        if isinstance(expr, IntLitExpr):
            expr.resolved_type = IntType(64)
            return expr.resolved_type
        elif isinstance(expr, BoolLitExpr):
            expr.resolved_type = BoolType()
            return expr.resolved_type
        elif isinstance(expr, IdentExpr):
            ty = self._lookup(expr.name, expr.line)
            expr.resolved_type = ty
            return ty
        elif isinstance(expr, BinOpExpr):
            return self._check_binop(expr)
        elif isinstance(expr, UnaryOpExpr):
            return self._check_unary(expr)
        elif isinstance(expr, CallExpr):
            return self._check_call(expr)
        elif isinstance(expr, IndexExpr):
            return self._check_index(expr)
        elif isinstance(expr, CastExpr):
            self._check_expr(expr.expr)
            expr.resolved_type = expr.target_type
            return expr.resolved_type
        else:
            raise TypeError_(f'Unknown expression type: {type(expr).__name__}', expr.line)

    def _check_binop(self, expr: BinOpExpr) -> Type:
        left_type = self._check_expr(expr.left)
        right_type = self._check_expr(expr.right)

        # Logical operators: both bool/int, result is bool
        if expr.op in ('&&', '||'):
            if not isinstance(left_type, (BoolType, IntType)):
                raise TypeError_(f'Logical operator requires bool/int, got {type_name(left_type)}', expr.line)
            if not isinstance(right_type, (BoolType, IntType)):
                raise TypeError_(f'Logical operator requires bool/int, got {type_name(right_type)}', expr.line)
            expr.resolved_type = BoolType()
            return expr.resolved_type

        # Comparison operators: result is bool
        if expr.op in ('==', '!=', '<', '>', '<=', '>='):
            # Both operands should be same numeric type (we allow int)
            expr.resolved_type = BoolType()
            return expr.resolved_type

        # Arithmetic / bitwise operators: result is same as operands
        if expr.op in ('+', '-', '*', '/', '%', '&', '|', '^', '<<', '>>'):
            # Determine result type — prefer i64 if either is i64
            if isinstance(left_type, IntType) and isinstance(right_type, IntType):
                result_bits = max(left_type.bits, right_type.bits)
                expr.resolved_type = IntType(result_bits)
            elif isinstance(left_type, BoolType) and isinstance(right_type, IntType):
                expr.resolved_type = right_type
            elif isinstance(left_type, IntType) and isinstance(right_type, BoolType):
                expr.resolved_type = left_type
            else:
                raise TypeError_(
                    f'Cannot apply {expr.op} to {type_name(left_type)} and {type_name(right_type)}',
                    expr.line,
                )
            return expr.resolved_type

        raise TypeError_(f'Unknown binary operator: {expr.op}', expr.line)

    def _check_unary(self, expr: UnaryOpExpr) -> Type:
        operand_type = self._check_expr(expr.operand)
        if expr.op == '-':
            if not isinstance(operand_type, IntType):
                raise TypeError_(f'Unary minus requires int, got {type_name(operand_type)}', expr.line)
            expr.resolved_type = operand_type
        elif expr.op == '!':
            expr.resolved_type = BoolType()
        elif expr.op == '~':
            if not isinstance(operand_type, IntType):
                raise TypeError_(f'Bitwise NOT requires int, got {type_name(operand_type)}', expr.line)
            expr.resolved_type = operand_type
        elif expr.op == '*':
            # Dereference
            if not isinstance(operand_type, PtrType):
                raise TypeError_(f'Cannot dereference non-pointer', expr.line)
            expr.resolved_type = operand_type.pointee or IntType(8)
        elif expr.op == '&':
            # Address-of
            expr.resolved_type = PtrType(pointee=operand_type)
        else:
            raise TypeError_(f'Unknown unary operator: {expr.op}', expr.line)
        return expr.resolved_type

    def _check_call(self, expr: CallExpr) -> Type:
        if expr.func_name not in self.functions:
            raise TypeError_(f'Undefined function {expr.func_name!r}', expr.line)
        param_types, ret_type = self.functions[expr.func_name]
        if len(expr.args) != len(param_types):
            raise TypeError_(
                f'{expr.func_name} expects {len(param_types)} arguments, got {len(expr.args)}',
                expr.line,
            )
        for i, (arg, ptype) in enumerate(zip(expr.args, param_types)):
            atype = self._check_expr(arg)
            if not types_equal(atype, ptype):
                if isinstance(atype, IntType) and isinstance(ptype, IntType):
                    pass  # allow int size mismatch
                elif isinstance(atype, BoolType) and isinstance(ptype, IntType):
                    pass  # bool -> int
                else:
                    raise TypeError_(
                        f'Argument {i+1} of {expr.func_name}: expected {type_name(ptype)}, '
                        f'got {type_name(atype)}',
                        expr.line,
                    )
        expr.resolved_type = ret_type
        return ret_type

    def _check_index(self, expr: IndexExpr) -> Type:
        base_type = self._check_expr(expr.base)
        idx_type = self._check_expr(expr.index)
        if not isinstance(base_type, PtrType):
            raise TypeError_(f'Cannot index non-pointer type {type_name(base_type)}', expr.line)
        if not isinstance(idx_type, (IntType, BoolType)):
            raise TypeError_(f'Index must be integer, got {type_name(idx_type)}', expr.line)
        expr.resolved_type = base_type.pointee or IntType(8)
        return expr.resolved_type
