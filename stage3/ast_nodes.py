"""AST node definitions for the .lang language."""

from dataclasses import dataclass, field
from typing import Optional


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

@dataclass
class Type:
    pass

@dataclass
class IntType(Type):
    bits: int = 64  # i64 or i8

    def __repr__(self):
        return f'i{self.bits}'

@dataclass
class BoolType(Type):
    def __repr__(self):
        return 'bool'

@dataclass
class PtrType(Type):
    pointee: Optional[Type] = None

    def __repr__(self):
        return 'ptr'

@dataclass
class VoidType(Type):
    def __repr__(self):
        return 'void'


# ---------------------------------------------------------------------------
# Expressions
# ---------------------------------------------------------------------------

@dataclass
class Expr:
    line: int = 0
    resolved_type: Optional[Type] = None

@dataclass
class IntLitExpr(Expr):
    value: int = 0

@dataclass
class BoolLitExpr(Expr):
    value: bool = False

@dataclass
class IdentExpr(Expr):
    name: str = ''

@dataclass
class BinOpExpr(Expr):
    op: str = ''
    left: Optional[Expr] = None
    right: Optional[Expr] = None

@dataclass
class UnaryOpExpr(Expr):
    op: str = ''
    operand: Optional[Expr] = None

@dataclass
class CallExpr(Expr):
    func_name: str = ''
    args: list = field(default_factory=list)

@dataclass
class IndexExpr(Expr):
    base: Optional[Expr] = None
    index: Optional[Expr] = None

@dataclass
class CastExpr(Expr):
    expr: Optional[Expr] = None
    target_type: Optional[Type] = None


# ---------------------------------------------------------------------------
# Statements
# ---------------------------------------------------------------------------

@dataclass
class Stmt:
    line: int = 0

@dataclass
class LetStmt(Stmt):
    name: str = ''
    type_ann: Optional[Type] = None
    init: Optional[Expr] = None

@dataclass
class AssignStmt(Stmt):
    target: str = ''
    value: Optional[Expr] = None

@dataclass
class ReturnStmt(Stmt):
    value: Optional[Expr] = None

@dataclass
class IfStmt(Stmt):
    condition: Optional[Expr] = None
    then_body: list = field(default_factory=list)
    else_body: list = field(default_factory=list)  # empty if no else

@dataclass
class WhileStmt(Stmt):
    condition: Optional[Expr] = None
    body: list = field(default_factory=list)

@dataclass
class ExprStmt(Stmt):
    expr: Optional[Expr] = None

@dataclass
class BreakStmt(Stmt):
    pass

@dataclass
class ContinueStmt(Stmt):
    pass


# ---------------------------------------------------------------------------
# Declarations
# ---------------------------------------------------------------------------

@dataclass
class Param:
    name: str = ''
    type_ann: Optional[Type] = None

@dataclass
class FuncDecl:
    line: int = 0
    name: str = ''
    params: list = field(default_factory=list)  # list of Param
    ret_type: Optional[Type] = None
    body: list = field(default_factory=list)     # list of Stmt
    is_extern: bool = False

@dataclass
class ExternDecl:
    line: int = 0
    name: str = ''
    param_types: list = field(default_factory=list)  # list of Type
    ret_type: Optional[Type] = None

@dataclass
class Program:
    decls: list = field(default_factory=list)  # FuncDecl | ExternDecl
