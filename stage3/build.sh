#!/bin/bash
set -e
INPUT="$1"
OUTPUT="${2:-${INPUT%.lang}}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$DIR/.."
SDK=$(xcrun --show-sdk-path)
python3 "$DIR/compiler.py" "$INPUT" > /tmp/_stage3.ir
python3 "$PROJ/stage2/codegen/irc_opt.py" /tmp/_stage3.ir > /tmp/_stage3.s
as -arch arm64 -o /tmp/_stage3.o /tmp/_stage3.s
ld -arch arm64 -platform_version macos 14.0 14.0 -syslibroot "$SDK" -lSystem -e _main -o "$OUTPUT" /tmp/_stage3.o
