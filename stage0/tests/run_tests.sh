#!/bin/bash
#
# Test runner for the AArch64 macOS assembler.
#
# Usage: ./run_tests.sh [path/to/assembler]
#
# For each test_*.s file, assembles it, links it against libSystem,
# runs the resulting binary, and checks the exit code (and optionally
# stdout) against the expected values embedded in the test file.
#
# Expected exit code is declared on the first line as: // expect: N
# Optional stdout check is declared as:                // stdout: <text>

set -euo pipefail

ASM="${1:-../asm}"
USE_SYSTEM_AS="${USE_SYSTEM_AS:-0}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
mkdir -p "$BUILD_DIR"

PASS=0
FAIL=0
SKIP=0
TOTAL=0

# Colors (disabled if not a tty)
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    NC=''
fi

cleanup() {
    rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

for test_file in "$SCRIPT_DIR"/test_*.s; do
    test_name="$(basename "$test_file" .s)"
    TOTAL=$((TOTAL + 1))

    # Parse expected exit code from first line
    expected_exit=$(head -1 "$test_file" | sed -n 's|^// expect: \([0-9]*\).*|\1|p')
    if [ -z "$expected_exit" ]; then
        printf "${YELLOW}SKIP${NC} %-20s (no expected exit code found)\n" "$test_name"
        SKIP=$((SKIP + 1))
        continue
    fi

    # Check for stdout expectation (optional)
    expected_stdout=$(grep -m1 '// stdout: ' "$test_file" 2>/dev/null | sed 's|^// stdout: ||' || true)

    obj_file="$BUILD_DIR/${test_name}.o"
    bin_file="$BUILD_DIR/${test_name}"

    # Step 1: Assemble
    if [ "$USE_SYSTEM_AS" = "1" ]; then
        if ! as -o "$obj_file" "$test_file" 2>/dev/null; then
            printf "${RED}FAIL${NC} %-20s (system assembler failed)\n" "$test_name"
            FAIL=$((FAIL + 1))
            continue
        fi
    else
        if ! "$ASM" "$test_file" -o "$obj_file" 2>/dev/null; then
            printf "${RED}FAIL${NC} %-20s (assembler failed)\n" "$test_name"
            FAIL=$((FAIL + 1))
            continue
        fi
    fi

    # Step 2: Link against libSystem
    if ! ld -o "$bin_file" "$obj_file" -lSystem -syslibroot "$(xcrun --show-sdk-path)" -e _main -arch arm64 2>/dev/null; then
        printf "${RED}FAIL${NC} %-20s (linker failed)\n" "$test_name"
        FAIL=$((FAIL + 1))
        continue
    fi

    # Step 3: Run and capture exit code + stdout
    set +e
    actual_stdout=$("$bin_file" 2>/dev/null)
    actual_exit=$?
    set -e

    # Step 4: Check exit code
    if [ "$actual_exit" -ne "$expected_exit" ]; then
        printf "${RED}FAIL${NC} %-20s (expected exit %d, got %d)\n" "$test_name" "$expected_exit" "$actual_exit"
        FAIL=$((FAIL + 1))
        continue
    fi

    # Step 5: Check stdout if expected
    if [ -n "$expected_stdout" ]; then
        if [ "$actual_stdout" != "$expected_stdout" ]; then
            printf "${RED}FAIL${NC} %-20s (exit OK, but stdout mismatch: expected '%s', got '%s')\n" \
                "$test_name" "$expected_stdout" "$actual_stdout"
            FAIL=$((FAIL + 1))
            continue
        fi
    fi

    printf "${GREEN}PASS${NC} %-20s (exit code %d)\n" "$test_name" "$actual_exit"
    PASS=$((PASS + 1))
done

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped out of $TOTAL tests"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
