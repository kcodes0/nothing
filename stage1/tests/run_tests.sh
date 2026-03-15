#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
IRC="$DIR/../irc"
SDK=$(xcrun --show-sdk-path)
PASS=0
FAIL=0
TOTAL=0

if [ ! -f "$IRC" ]; then
    echo "ERROR: irc not found at $IRC"
    echo "Run build.sh first."
    exit 1
fi

for ir_file in "$DIR"/test_*.ir; do
    TOTAL=$((TOTAL + 1))
    test_name=$(basename "$ir_file" .ir)

    # Extract expected exit code from first line: // expect: N
    expected=$(head -1 "$ir_file" | sed 's/.*expect: //')

    echo -n "Testing $test_name (expect $expected)... "

    # Create temp directory for test artifacts
    TMPDIR_TEST=$(mktemp -d)

    # Compile IR to assembly
    if ! "$IRC" "$ir_file" > "$TMPDIR_TEST/test.s" 2>"$TMPDIR_TEST/irc_err.txt"; then
        echo "FAIL (irc failed)"
        cat "$TMPDIR_TEST/irc_err.txt"
        FAIL=$((FAIL + 1))
        rm -rf "$TMPDIR_TEST"
        continue
    fi

    # Assemble
    if ! as -arch arm64 -o "$TMPDIR_TEST/test.o" "$TMPDIR_TEST/test.s" 2>"$TMPDIR_TEST/as_err.txt"; then
        echo "FAIL (as failed)"
        cat "$TMPDIR_TEST/as_err.txt"
        echo "--- Generated assembly ---"
        cat "$TMPDIR_TEST/test.s"
        echo "--- End assembly ---"
        FAIL=$((FAIL + 1))
        rm -rf "$TMPDIR_TEST"
        continue
    fi

    # Link
    if ! ld -arch arm64 -platform_version macos 15.5 15.5 \
        -syslibroot "$SDK" -lSystem \
        -o "$TMPDIR_TEST/test" "$TMPDIR_TEST/test.o" 2>"$TMPDIR_TEST/ld_err.txt"; then
        echo "FAIL (ld failed)"
        cat "$TMPDIR_TEST/ld_err.txt"
        FAIL=$((FAIL + 1))
        rm -rf "$TMPDIR_TEST"
        continue
    fi

    # Run and check exit code
    set +e
    "$TMPDIR_TEST/test"
    actual=$?
    set -e

    if [ "$actual" -eq "$expected" ]; then
        echo "PASS"
        PASS=$((PASS + 1))
    else
        echo "FAIL (got $actual, expected $expected)"
        echo "--- Generated assembly ---"
        cat "$TMPDIR_TEST/test.s"
        echo "--- End assembly ---"
        FAIL=$((FAIL + 1))
    fi

    rm -rf "$TMPDIR_TEST"
done

echo ""
echo "Results: $PASS/$TOTAL passed, $FAIL failed"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
