#!/bin/bash
set -e
SDK=$(xcrun --show-sdk-path)
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Building stage 1 IR compiler..."
for f in irc.s ir_lexer.s ir_parser.s codegen.s; do
    echo "  Assembling $f..."
    as -arch arm64 -o "$DIR/${f%.s}.o" "$DIR/$f"
done
echo "  Linking..."
ld -arch arm64 -platform_version macos 14.0 14.0 \
    -syslibroot "$SDK" -lSystem \
    -o "$DIR/irc" "$DIR/irc.o" "$DIR/ir_lexer.o" "$DIR/ir_parser.o" "$DIR/codegen.o"
echo "Stage 1 IR compiler built: $DIR/irc"
rm -f "$DIR"/*.o
echo "Done."
