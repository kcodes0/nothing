#!/bin/bash
# Build an IR file with optimization passes applied
# Usage: ./build_optimized.sh input.ir output_binary
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT="$1"
OUTPUT="$2"
SDK=$(xcrun --show-sdk-path)

# Apply optimization passes (Python prototypes)
OPTIMIZED=$(mktemp)
cat "$INPUT" | \
    python3 "$DIR/passes/constfold.py" | \
    python3 "$DIR/passes/dce.py" | \
    python3 "$DIR/passes/peephole.py" > "$OPTIMIZED"

# Compile: IR -> asm -> .o -> binary
"$DIR/../stage1/irc" "$OPTIMIZED" > "${OPTIMIZED}.s"
as -arch arm64 -o "${OPTIMIZED}.o" "${OPTIMIZED}.s"
ld -arch arm64 -platform_version macos 14.0 14.0 \
   -syslibroot "$SDK" -lSystem -e _main \
   -o "$OUTPUT" "${OPTIMIZED}.o"

rm -f "$OPTIMIZED" "${OPTIMIZED}.s" "${OPTIMIZED}.o"
