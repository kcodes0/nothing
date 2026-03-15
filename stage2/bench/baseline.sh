#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "=== Establishing baseline (no optimization) ==="
bash "$DIR/eval.sh" | tee "$DIR/baseline.txt"
