#!/usr/bin/env python3
"""Fast single-process compiler: .lang → AArch64 assembly (stdout).

Combines frontend (lexer/parser/typechecker/IR emitter) and backend
(irc_opt.py) into a single Python invocation, eliminating ~600ms of
Python startup overhead and IR serialization/deserialization.
"""
import sys
import os

# Add paths for imports
script_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, script_dir)
sys.path.insert(0, os.path.join(script_dir, '..', 'stage2', 'codegen'))

from lexer import Lexer
from parser import Parser
from typechecker import TypeChecker
from ir_emitter import IREmitter

# Import the backend directly
import irc_opt

def main():
    if len(sys.argv) < 2:
        print("Usage: compile_fast.py <input.lang>", file=sys.stderr)
        sys.exit(1)

    input_file = sys.argv[1]
    with open(input_file) as f:
        source = f.read()

    # Frontend: .lang → IR text
    tokens = Lexer(source).tokenize()
    program = Parser(tokens).parse_program()
    TypeChecker().check(program)
    ir_text = IREmitter().emit(program)

    # Backend: IR text → assembly text
    compiler = irc_opt.IRCompiler()
    parser = irc_opt.IRParser(ir_text)
    compiler.functions = parser.parse()
    asm_text = compiler.compile()

    sys.stdout.write(asm_text)

if __name__ == '__main__':
    main()
