#!/bin/bash
DIR="$(cd "$(dirname "$0")" && pwd)"
echo "Reverting to last known-good state..."
git checkout -- "$DIR/../passes/" "$DIR/../codegen/" 2>/dev/null
echo "Reverted."
