#!/bin/bash
# pass_manager.sh — Orchestrate optimization passes
# Usage: ./pass_manager.sh input.ir [output.ir]
# Currently a no-op passthrough; passes will be added as they're implemented
INPUT="$1"
OUTPUT="${2:-/dev/stdout}"
cp "$INPUT" "$OUTPUT"
