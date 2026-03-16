#!/bin/bash
set -e
INPUT="$1"
OUTPUT="${2:-${INPUT%.lang}}"
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$DIR/.."
SDK=$(xcrun --show-sdk-path)
TMPBASE="/tmp/_stage3_$$"
python3 "$DIR/compiler.py" "$INPUT" > "${TMPBASE}.ir"
python3 "$PROJ/stage2/codegen/irc_opt.py" "${TMPBASE}.ir" > "${TMPBASE}.s"
as -arch arm64 -o "${TMPBASE}.o" "${TMPBASE}.s"
ld -arch arm64 -platform_version macos 14.0 14.0 -syslibroot "$SDK" -lSystem -e _main -o "$OUTPUT" "${TMPBASE}.o"
rm -f "${TMPBASE}.ir" "${TMPBASE}.s" "${TMPBASE}.o"
