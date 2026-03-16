#!/usr/bin/env python3
"""Main compiler driver: .lang source -> SSA IR text."""

import sys
import os

# Add stage3 directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from lexer import Lexer, LexError
from parser import Parser, ParseError
from typechecker import TypeChecker, TypeError_
from ir_emitter import IREmitter


def compile_file(filename):
    with open(filename, 'r') as f:
        source = f.read()

    # Lex
    try:
        lexer = Lexer(source, filename)
        tokens = lexer.tokenize()
    except LexError as e:
        print(f'{filename}:{e.line}: {e}', file=sys.stderr)
        sys.exit(1)

    # Parse
    try:
        parser = Parser(tokens)
        program = parser.parse_program()
    except ParseError as e:
        print(f'{filename}:{e.line}: {e}', file=sys.stderr)
        sys.exit(1)

    # Type check
    try:
        checker = TypeChecker()
        checker.check(program)
    except TypeError_ as e:
        print(f'{filename}:{e.line}: {e}', file=sys.stderr)
        sys.exit(1)

    # Emit IR
    emitter = IREmitter()
    ir_text = emitter.emit(program)
    return ir_text


def main():
    if len(sys.argv) < 2:
        print('Usage: compiler.py <input.lang>', file=sys.stderr)
        sys.exit(1)

    ir_text = compile_file(sys.argv[1])
    sys.stdout.write(ir_text)


if __name__ == '__main__':
    main()
