#!/bin/bash
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$DIR/../.."
PASS=0; FAIL=0; TOTAL=0

for test_file in "$DIR"/test_*.lang; do
    name=$(basename "$test_file" .lang)
    expected=$(head -1 "$test_file" | sed -n 's|^// expect: \([0-9]*\).*|\1|p')
    [ -z "$expected" ] && continue
    TOTAL=$((TOTAL + 1))

    if ! bash "$DIR/../build.sh" "$test_file" "/tmp/${name}" 2>/dev/null; then
        echo "FAIL $name (compilation failed)"
        FAIL=$((FAIL + 1))
        continue
    fi

    set +e
    /tmp/${name}; actual=$?
    set -e

    if [ "$actual" -eq "$expected" ]; then
        echo "PASS $name (exit $actual)"
        PASS=$((PASS + 1))
    else
        echo "FAIL $name (expected $expected, got $actual)"
        FAIL=$((FAIL + 1))
    fi
done

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL tests"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
