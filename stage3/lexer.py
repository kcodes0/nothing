"""Tokenizer for the .lang language."""

from dataclasses import dataclass
from typing import Optional


# Token types
class TT:
    # Literals
    INT_LIT = 'INT_LIT'
    CHAR_LIT = 'CHAR_LIT'
    IDENT = 'IDENT'

    # Keywords
    FN = 'fn'
    LET = 'let'
    RETURN = 'return'
    IF = 'if'
    ELSE = 'else'
    WHILE = 'while'
    EXTERN = 'extern'
    AS = 'as'
    BREAK = 'break'
    CONTINUE = 'continue'
    TRUE = 'true'
    FALSE = 'false'

    # Operators
    PLUS = '+'
    MINUS = '-'
    STAR = '*'
    SLASH = '/'
    PERCENT = '%'
    AMP = '&'
    PIPE = '|'
    CARET = '^'
    TILDE = '~'
    BANG = '!'
    LT = '<'
    GT = '>'
    LE = '<='
    GE = '>='
    EQ = '=='
    NE = '!='
    SHL = '<<'
    SHR = '>>'
    AND = '&&'
    OR = '||'
    ASSIGN = '='

    # Delimiters
    LPAREN = '('
    RPAREN = ')'
    LBRACE = '{'
    RBRACE = '}'
    LBRACKET = '['
    RBRACKET = ']'
    COMMA = ','
    COLON = ':'
    ARROW = '->'

    # Special
    NEWLINE = 'NEWLINE'
    EOF = 'EOF'


KEYWORDS = {
    'fn': TT.FN,
    'let': TT.LET,
    'return': TT.RETURN,
    'if': TT.IF,
    'else': TT.ELSE,
    'while': TT.WHILE,
    'extern': TT.EXTERN,
    'as': TT.AS,
    'break': TT.BREAK,
    'continue': TT.CONTINUE,
    'true': TT.TRUE,
    'false': TT.FALSE,
}


@dataclass
class Token:
    type: str
    value: str
    line: int
    col: int

    def __repr__(self):
        return f'Token({self.type}, {self.value!r}, L{self.line})'


class LexError(Exception):
    def __init__(self, msg, line, col):
        self.line = line
        self.col = col
        super().__init__(f'Lex error at line {line}, col {col}: {msg}')


class Lexer:
    def __init__(self, source: str, filename: str = '<input>'):
        self.source = source
        self.filename = filename
        self.pos = 0
        self.line = 1
        self.col = 1
        self.tokens = []
        # Nesting depth for parens/brackets/braces — newlines inside are ignored
        self.nesting = 0

    def tokenize(self):
        self.tokens = []
        while self.pos < len(self.source):
            self._skip_whitespace_and_comments()
            if self.pos >= len(self.source):
                break

            ch = self.source[self.pos]

            # Newline handling
            if ch == '\n':
                if self.nesting == 0:
                    # Only emit NEWLINE if the last token could end a statement
                    if self.tokens and self.tokens[-1].type not in (
                        TT.NEWLINE, TT.LBRACE, TT.LPAREN, TT.LBRACKET,
                        TT.COMMA, TT.PLUS, TT.MINUS, TT.STAR, TT.SLASH,
                        TT.PERCENT, TT.AMP, TT.PIPE, TT.CARET, TT.AND,
                        TT.OR, TT.ASSIGN, TT.LT, TT.GT, TT.LE, TT.GE,
                        TT.EQ, TT.NE, TT.SHL, TT.SHR, TT.ARROW, TT.COLON,
                    ):
                        self.tokens.append(Token(TT.NEWLINE, '\\n', self.line, self.col))
                self._advance()
                continue

            # Integer literal
            if ch.isdigit():
                self._read_int()
                continue

            # Character literal
            if ch == "'":
                self._read_char()
                continue

            # Identifier / keyword
            if ch.isalpha() or ch == '_':
                self._read_ident()
                continue

            # Two-char operators
            if self.pos + 1 < len(self.source):
                two = self.source[self.pos:self.pos + 2]
                if two == '->':
                    self.tokens.append(Token(TT.ARROW, '->', self.line, self.col))
                    self._advance()
                    self._advance()
                    continue
                if two == '<=':
                    self.tokens.append(Token(TT.LE, '<=', self.line, self.col))
                    self._advance()
                    self._advance()
                    continue
                if two == '>=':
                    self.tokens.append(Token(TT.GE, '>=', self.line, self.col))
                    self._advance()
                    self._advance()
                    continue
                if two == '==':
                    self.tokens.append(Token(TT.EQ, '==', self.line, self.col))
                    self._advance()
                    self._advance()
                    continue
                if two == '!=':
                    self.tokens.append(Token(TT.NE, '!=', self.line, self.col))
                    self._advance()
                    self._advance()
                    continue
                if two == '<<':
                    self.tokens.append(Token(TT.SHL, '<<', self.line, self.col))
                    self._advance()
                    self._advance()
                    continue
                if two == '>>':
                    self.tokens.append(Token(TT.SHR, '>>', self.line, self.col))
                    self._advance()
                    self._advance()
                    continue
                if two == '&&':
                    self.tokens.append(Token(TT.AND, '&&', self.line, self.col))
                    self._advance()
                    self._advance()
                    continue
                if two == '||':
                    self.tokens.append(Token(TT.OR, '||', self.line, self.col))
                    self._advance()
                    self._advance()
                    continue

            # Single-char tokens
            single_map = {
                '+': TT.PLUS, '-': TT.MINUS, '*': TT.STAR, '/': TT.SLASH,
                '%': TT.PERCENT, '&': TT.AMP, '|': TT.PIPE, '^': TT.CARET,
                '~': TT.TILDE, '!': TT.BANG, '<': TT.LT, '>': TT.GT,
                '=': TT.ASSIGN, '(': TT.LPAREN, ')': TT.RPAREN,
                '{': TT.LBRACE, '}': TT.RBRACE, '[': TT.LBRACKET,
                ']': TT.RBRACKET, ',': TT.COMMA, ':': TT.COLON,
            }
            if ch in single_map:
                tt = single_map[ch]
                if ch in ('(', '[', '{'):
                    self.nesting += 1
                elif ch in (')', ']', '}'):
                    self.nesting = max(0, self.nesting - 1)
                self.tokens.append(Token(tt, ch, self.line, self.col))
                self._advance()
                continue

            raise LexError(f'Unexpected character: {ch!r}', self.line, self.col)

        # Ensure there's a final NEWLINE if the last token isn't one
        if self.tokens and self.tokens[-1].type not in (TT.NEWLINE, TT.EOF):
            self.tokens.append(Token(TT.NEWLINE, '\\n', self.line, self.col))

        self.tokens.append(Token(TT.EOF, '', self.line, self.col))
        return self.tokens

    def _advance(self):
        if self.pos < len(self.source):
            if self.source[self.pos] == '\n':
                self.line += 1
                self.col = 1
            else:
                self.col += 1
            self.pos += 1

    def _peek(self):
        if self.pos < len(self.source):
            return self.source[self.pos]
        return '\0'

    def _skip_whitespace_and_comments(self):
        while self.pos < len(self.source):
            ch = self.source[self.pos]
            if ch in (' ', '\t', '\r'):
                self._advance()
                continue
            # Line comment
            if ch == '/' and self.pos + 1 < len(self.source) and self.source[self.pos + 1] == '/':
                while self.pos < len(self.source) and self.source[self.pos] != '\n':
                    self._advance()
                continue
            break

    def _read_int(self):
        start_col = self.col
        start_line = self.line
        start = self.pos
        if self.source[self.pos] == '0' and self.pos + 1 < len(self.source):
            nch = self.source[self.pos + 1]
            if nch in ('x', 'X'):
                self._advance()
                self._advance()
                while self.pos < len(self.source) and self.source[self.pos] in '0123456789abcdefABCDEF_':
                    self._advance()
                val = int(self.source[start:self.pos].replace('_', ''), 16)
                self.tokens.append(Token(TT.INT_LIT, str(val), start_line, start_col))
                return
            if nch in ('b', 'B'):
                self._advance()
                self._advance()
                while self.pos < len(self.source) and self.source[self.pos] in '01_':
                    self._advance()
                val = int(self.source[start:self.pos].replace('_', ''), 2)
                self.tokens.append(Token(TT.INT_LIT, str(val), start_line, start_col))
                return

        while self.pos < len(self.source) and (self.source[self.pos].isdigit() or self.source[self.pos] == '_'):
            self._advance()
        val = int(self.source[start:self.pos].replace('_', ''))
        self.tokens.append(Token(TT.INT_LIT, str(val), start_line, start_col))

    def _read_char(self):
        start_line = self.line
        start_col = self.col
        self._advance()  # skip opening '
        if self.pos >= len(self.source):
            raise LexError('Unterminated character literal', start_line, start_col)
        ch = self.source[self.pos]
        if ch == '\\':
            self._advance()
            if self.pos >= len(self.source):
                raise LexError('Unterminated escape in character literal', start_line, start_col)
            esc = self.source[self.pos]
            escape_map = {'n': '\n', 't': '\t', 'r': '\r', '\\': '\\', "'": "'", '0': '\0'}
            if esc not in escape_map:
                raise LexError(f'Unknown escape \\{esc}', self.line, self.col)
            val = ord(escape_map[esc])
        else:
            val = ord(ch)
        self._advance()
        if self.pos >= len(self.source) or self.source[self.pos] != "'":
            raise LexError('Unterminated character literal', start_line, start_col)
        self._advance()  # skip closing '
        self.tokens.append(Token(TT.INT_LIT, str(val), start_line, start_col))

    def _read_ident(self):
        start = self.pos
        start_line = self.line
        start_col = self.col
        while self.pos < len(self.source) and (self.source[self.pos].isalnum() or self.source[self.pos] == '_'):
            self._advance()
        word = self.source[start:self.pos]
        tt = KEYWORDS.get(word, TT.IDENT)
        self.tokens.append(Token(tt, word, start_line, start_col))
