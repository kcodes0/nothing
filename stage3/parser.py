"""Recursive descent parser for the .lang language."""

from ast_nodes import (
    Type, IntType, BoolType, PtrType, VoidType,
    Expr, IntLitExpr, BoolLitExpr, IdentExpr, BinOpExpr, UnaryOpExpr,
    CallExpr, IndexExpr, CastExpr,
    Stmt, LetStmt, AssignStmt, ReturnStmt, IfStmt, WhileStmt,
    ExprStmt, BreakStmt, ContinueStmt,
    Param, FuncDecl, ExternDecl, Program,
)
from lexer import Token, TT


class ParseError(Exception):
    def __init__(self, msg, token):
        self.token = token
        self.line = token.line if token else 0
        super().__init__(f'Parse error at line {self.line}: {msg}')


class Parser:
    def __init__(self, tokens):
        self.tokens = tokens
        self.pos = 0

    # ----- helpers -----

    def _cur(self) -> Token:
        if self.pos < len(self.tokens):
            return self.tokens[self.pos]
        return self.tokens[-1]  # EOF

    def _peek(self, offset=0) -> Token:
        idx = self.pos + offset
        if idx < len(self.tokens):
            return self.tokens[idx]
        return self.tokens[-1]

    def _at(self, *types) -> bool:
        return self._cur().type in types

    def _eat(self, tt) -> Token:
        tok = self._cur()
        if tok.type != tt:
            raise ParseError(f'Expected {tt}, got {tok.type} ({tok.value!r})', tok)
        self.pos += 1
        return tok

    def _skip_newlines(self):
        while self._at(TT.NEWLINE):
            self.pos += 1

    def _expect_newline_or_eof(self):
        if self._at(TT.NEWLINE):
            self.pos += 1
        elif self._at(TT.EOF):
            pass
        elif self._at(TT.RBRACE):
            pass  # closing brace can end a statement
        else:
            raise ParseError(
                f'Expected newline or end of statement, got {self._cur().type} ({self._cur().value!r})',
                self._cur(),
            )

    # ----- top-level -----

    def parse_program(self) -> Program:
        decls = []
        self._skip_newlines()
        while not self._at(TT.EOF):
            if self._at(TT.FN):
                decls.append(self._parse_func_decl())
            elif self._at(TT.EXTERN):
                decls.append(self._parse_extern_decl())
            else:
                raise ParseError(
                    f'Expected function or extern declaration, got {self._cur().type}',
                    self._cur(),
                )
            self._skip_newlines()
        return Program(decls=decls)

    def _parse_extern_decl(self) -> ExternDecl:
        tok = self._eat(TT.EXTERN)
        self._eat(TT.FN)
        name_tok = self._eat(TT.IDENT)
        self._eat(TT.LPAREN)
        param_types = []
        if not self._at(TT.RPAREN):
            param_types.append(self._parse_type())
            while self._at(TT.COMMA):
                self.pos += 1
                param_types.append(self._parse_type())
        self._eat(TT.RPAREN)
        ret_type = VoidType()
        if self._at(TT.ARROW):
            self.pos += 1
            ret_type = self._parse_type()
        self._expect_newline_or_eof()
        return ExternDecl(line=tok.line, name=name_tok.value,
                          param_types=param_types, ret_type=ret_type)

    def _parse_func_decl(self) -> FuncDecl:
        tok = self._eat(TT.FN)
        name_tok = self._eat(TT.IDENT)
        self._eat(TT.LPAREN)
        params = []
        if not self._at(TT.RPAREN):
            params.append(self._parse_param())
            while self._at(TT.COMMA):
                self.pos += 1
                self._skip_newlines()
                params.append(self._parse_param())
        self._eat(TT.RPAREN)
        ret_type = VoidType()
        if self._at(TT.ARROW):
            self.pos += 1
            ret_type = self._parse_type()
        self._eat(TT.LBRACE)
        self._skip_newlines()
        body = self._parse_block_body()
        self._eat(TT.RBRACE)
        self._skip_newlines()
        return FuncDecl(line=tok.line, name=name_tok.value, params=params,
                        ret_type=ret_type, body=body)

    def _parse_param(self) -> Param:
        name_tok = self._eat(TT.IDENT)
        self._eat(TT.COLON)
        ty = self._parse_type()
        return Param(name=name_tok.value, type_ann=ty)

    def _parse_type(self) -> Type:
        tok = self._cur()
        if tok.type == TT.IDENT:
            self.pos += 1
            if tok.value == 'i64':
                return IntType(64)
            elif tok.value == 'i8':
                return IntType(8)
            elif tok.value == 'bool':
                return BoolType()
            elif tok.value == 'ptr':
                return PtrType()
            elif tok.value == 'void':
                return VoidType()
            else:
                raise ParseError(f'Unknown type: {tok.value}', tok)
        elif tok.type == TT.STAR:
            self.pos += 1
            inner = self._parse_type()
            return PtrType(pointee=inner)
        else:
            raise ParseError(f'Expected type, got {tok.type}', tok)

    # ----- statements -----

    def _parse_block_body(self) -> list:
        stmts = []
        while not self._at(TT.RBRACE, TT.EOF):
            self._skip_newlines()
            if self._at(TT.RBRACE, TT.EOF):
                break
            stmts.append(self._parse_stmt())
            self._skip_newlines()
        return stmts

    def _parse_stmt(self) -> Stmt:
        tok = self._cur()

        if tok.type == TT.LET:
            return self._parse_let()
        elif tok.type == TT.RETURN:
            return self._parse_return()
        elif tok.type == TT.IF:
            return self._parse_if()
        elif tok.type == TT.WHILE:
            return self._parse_while()
        elif tok.type == TT.BREAK:
            self.pos += 1
            self._expect_newline_or_eof()
            return BreakStmt(line=tok.line)
        elif tok.type == TT.CONTINUE:
            self.pos += 1
            self._expect_newline_or_eof()
            return ContinueStmt(line=tok.line)
        else:
            # Could be assignment (ident = expr) or expression statement
            return self._parse_assign_or_expr_stmt()

    def _parse_let(self) -> LetStmt:
        tok = self._eat(TT.LET)
        name_tok = self._eat(TT.IDENT)
        self._eat(TT.COLON)
        ty = self._parse_type()
        self._eat(TT.ASSIGN)
        expr = self._parse_expr()
        self._expect_newline_or_eof()
        return LetStmt(line=tok.line, name=name_tok.value, type_ann=ty, init=expr)

    def _parse_return(self) -> ReturnStmt:
        tok = self._eat(TT.RETURN)
        expr = None
        if not self._at(TT.NEWLINE, TT.RBRACE, TT.EOF):
            expr = self._parse_expr()
        self._expect_newline_or_eof()
        return ReturnStmt(line=tok.line, value=expr)

    def _parse_if(self) -> IfStmt:
        tok = self._eat(TT.IF)
        cond = self._parse_expr()
        self._eat(TT.LBRACE)
        self._skip_newlines()
        then_body = self._parse_block_body()
        self._eat(TT.RBRACE)
        else_body = []
        if self._at(TT.ELSE):
            self.pos += 1
            if self._at(TT.IF):
                # else if
                else_body = [self._parse_if()]
            else:
                self._eat(TT.LBRACE)
                self._skip_newlines()
                else_body = self._parse_block_body()
                self._eat(TT.RBRACE)
        self._skip_newlines()
        return IfStmt(line=tok.line, condition=cond, then_body=then_body,
                       else_body=else_body)

    def _parse_while(self) -> WhileStmt:
        tok = self._eat(TT.WHILE)
        cond = self._parse_expr()
        self._eat(TT.LBRACE)
        self._skip_newlines()
        body = self._parse_block_body()
        self._eat(TT.RBRACE)
        self._skip_newlines()
        return WhileStmt(line=tok.line, condition=cond, body=body)

    def _parse_assign_or_expr_stmt(self):
        tok = self._cur()
        # Check if this is `ident = expr`
        if tok.type == TT.IDENT and self._peek(1).type == TT.ASSIGN:
            name_tok = self._eat(TT.IDENT)
            self._eat(TT.ASSIGN)
            expr = self._parse_expr()
            self._expect_newline_or_eof()
            return AssignStmt(line=tok.line, target=name_tok.value, value=expr)
        # Expression statement
        expr = self._parse_expr()
        self._expect_newline_or_eof()
        return ExprStmt(line=tok.line, expr=expr)

    # ----- expression parsing with precedence -----

    def _parse_expr(self) -> Expr:
        return self._parse_or()

    def _parse_or(self) -> Expr:
        left = self._parse_and()
        while self._at(TT.OR):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_and()
            left = BinOpExpr(line=op_tok.line, op='||', left=left, right=right)
        return left

    def _parse_and(self) -> Expr:
        left = self._parse_bitor()
        while self._at(TT.AND):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_bitor()
            left = BinOpExpr(line=op_tok.line, op='&&', left=left, right=right)
        return left

    def _parse_bitor(self) -> Expr:
        left = self._parse_bitxor()
        while self._at(TT.PIPE):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_bitxor()
            left = BinOpExpr(line=op_tok.line, op='|', left=left, right=right)
        return left

    def _parse_bitxor(self) -> Expr:
        left = self._parse_bitand()
        while self._at(TT.CARET):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_bitand()
            left = BinOpExpr(line=op_tok.line, op='^', left=left, right=right)
        return left

    def _parse_bitand(self) -> Expr:
        left = self._parse_equality()
        while self._at(TT.AMP):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_equality()
            left = BinOpExpr(line=op_tok.line, op='&', left=left, right=right)
        return left

    def _parse_equality(self) -> Expr:
        left = self._parse_comparison()
        while self._at(TT.EQ, TT.NE):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_comparison()
            left = BinOpExpr(line=op_tok.line, op=op_tok.value, left=left, right=right)
        return left

    def _parse_comparison(self) -> Expr:
        left = self._parse_shift()
        while self._at(TT.LT, TT.GT, TT.LE, TT.GE):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_shift()
            left = BinOpExpr(line=op_tok.line, op=op_tok.value, left=left, right=right)
        return left

    def _parse_shift(self) -> Expr:
        left = self._parse_add()
        while self._at(TT.SHL, TT.SHR):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_add()
            left = BinOpExpr(line=op_tok.line, op=op_tok.value, left=left, right=right)
        return left

    def _parse_add(self) -> Expr:
        left = self._parse_mul()
        while self._at(TT.PLUS, TT.MINUS):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_mul()
            left = BinOpExpr(line=op_tok.line, op=op_tok.value, left=left, right=right)
        return left

    def _parse_mul(self) -> Expr:
        left = self._parse_unary()
        while self._at(TT.STAR, TT.SLASH, TT.PERCENT):
            op_tok = self._cur()
            self.pos += 1
            right = self._parse_unary()
            left = BinOpExpr(line=op_tok.line, op=op_tok.value, left=left, right=right)
        return left

    def _parse_unary(self) -> Expr:
        tok = self._cur()
        if tok.type == TT.MINUS:
            self.pos += 1
            operand = self._parse_unary()
            return UnaryOpExpr(line=tok.line, op='-', operand=operand)
        if tok.type == TT.BANG:
            self.pos += 1
            operand = self._parse_unary()
            return UnaryOpExpr(line=tok.line, op='!', operand=operand)
        if tok.type == TT.TILDE:
            self.pos += 1
            operand = self._parse_unary()
            return UnaryOpExpr(line=tok.line, op='~', operand=operand)
        if tok.type == TT.STAR:
            self.pos += 1
            operand = self._parse_unary()
            return UnaryOpExpr(line=tok.line, op='*', operand=operand)
        if tok.type == TT.AMP:
            self.pos += 1
            operand = self._parse_unary()
            return UnaryOpExpr(line=tok.line, op='&', operand=operand)
        return self._parse_postfix()

    def _parse_postfix(self) -> Expr:
        expr = self._parse_primary()
        while True:
            if self._at(TT.LPAREN):
                # Function call
                if not isinstance(expr, IdentExpr):
                    raise ParseError('Only named functions can be called', self._cur())
                self.pos += 1
                args = []
                if not self._at(TT.RPAREN):
                    self._skip_newlines()
                    args.append(self._parse_expr())
                    while self._at(TT.COMMA):
                        self.pos += 1
                        self._skip_newlines()
                        args.append(self._parse_expr())
                    self._skip_newlines()
                self._eat(TT.RPAREN)
                expr = CallExpr(line=expr.line, func_name=expr.name, args=args,
                                resolved_type=expr.resolved_type)
            elif self._at(TT.LBRACKET):
                self.pos += 1
                index = self._parse_expr()
                self._eat(TT.RBRACKET)
                expr = IndexExpr(line=expr.line, base=expr, index=index)
            elif self._at(TT.AS):
                self.pos += 1
                target_type = self._parse_type()
                expr = CastExpr(line=expr.line, expr=expr, target_type=target_type)
            else:
                break
        return expr

    def _parse_primary(self) -> Expr:
        tok = self._cur()

        if tok.type == TT.INT_LIT:
            self.pos += 1
            return IntLitExpr(line=tok.line, value=int(tok.value))

        if tok.type == TT.TRUE:
            self.pos += 1
            return BoolLitExpr(line=tok.line, value=True)

        if tok.type == TT.FALSE:
            self.pos += 1
            return BoolLitExpr(line=tok.line, value=False)

        if tok.type == TT.IDENT:
            self.pos += 1
            return IdentExpr(line=tok.line, name=tok.value)

        if tok.type == TT.LPAREN:
            self.pos += 1
            self._skip_newlines()
            expr = self._parse_expr()
            self._skip_newlines()
            self._eat(TT.RPAREN)
            return expr

        raise ParseError(
            f'Expected expression, got {tok.type} ({tok.value!r})', tok
        )
