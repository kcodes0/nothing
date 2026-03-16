#!/bin/bash
# Fast build: single Python process for frontend+backend
set -e
INPUT="$1"
OUTPUT="${2:-${INPUT%.lang}}"
DIR="$(cd "$(dirname "$0")" && pwd)"
SDK=$(xcrun --show-sdk-path)
TMPBASE="/tmp/_fast_$$"

python3 "$DIR/compile_fast.py" "$INPUT" > "${TMPBASE}.s"
as -arch arm64 -o "${TMPBASE}.o" "${TMPBASE}.s"
ld -arch arm64 -platform_version macos 14.0 14.0 \
   -syslibroot "$SDK" -lSystem -e _main \
   -o "$OUTPUT" "${TMPBASE}.o"
rm -f "${TMPBASE}.s" "${TMPBASE}.o"
