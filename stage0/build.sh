#!/bin/bash
set -e

# Build the stage 0 assembler using the system assembler (one-time bootstrap)
# This script assembles each .s source file with the system `as` and links
# them together with `ld` to produce the stage 0 assembler binary.

SDK=$(xcrun --show-sdk-path)
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Building stage 0 assembler..."

# Assemble each source file
for f in asm.s lexer.s parser.s encoder.s macho.s symtab.s strings.s tables.s error.s; do
    echo "  Assembling $f..."
    as -arch arm64 -o "$DIR/${f%.s}.o" "$DIR/$f"
done

# Link everything together
echo "  Linking..."
ld -arch arm64 \
    -platform_version macos 14.0 14.0 \
    -syslibroot "$SDK" \
    -lSystem \
    -o "$DIR/asm" \
    "$DIR/asm.o" "$DIR/lexer.o" "$DIR/parser.o" "$DIR/encoder.o" \
    "$DIR/macho.o" "$DIR/symtab.o" "$DIR/strings.o" "$DIR/tables.o" \
    "$DIR/error.o"

echo "Stage 0 assembler built: $DIR/asm"

# Clean up object files
rm -f "$DIR"/*.o

echo "Done."
