#!/bin/bash
set -e
SDK=$(xcrun --show-sdk-path)
DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$DIR/../.."
IRC="${IRC:-$PROJ/stage1/irc}"
ASM="${ASM:-as}"  # Use system as by default, switch to stage0/asm later
ASM_OPT="${PROJ}/stage2/passes/asm_peephole.py"
REGALLOC="${PROJ}/stage2/passes/regalloc.py"
OUT="$DIR/out"
mkdir -p "$OUT"

echo "=== Compiling benchmarks ==="
if [ "${USE_ASM_OPT:-0}" = "1" ]; then
    echo "(assembly peephole optimization enabled)"
fi
if [ "${USE_REGALLOC:-0}" = "1" ]; then
    echo "(register allocation optimization enabled)"
fi
PASS=0
FAIL=0
TOTAL=0
TOTAL_TIME=0

for bench in "$DIR"/benchmarks/*.ir; do
    name=$(basename "$bench" .ir)
    expected=$(head -1 "$bench" | sed -n 's|^// expect: \([0-9]*\).*|\1|p')
    [ -z "$expected" ] && continue
    TOTAL=$((TOTAL + 1))

    # Compile: IR -> asm (-> optional asm peephole) -> .o -> executable
    if ! "$IRC" "$bench" > "$OUT/${name}.s" 2>/dev/null; then
        echo "FAIL $name (irc failed)"
        FAIL=$((FAIL + 1))
        continue
    fi
    if [ "${USE_ASM_OPT:-0}" = "1" ]; then
        if ! python3 "$ASM_OPT" < "$OUT/${name}.s" > "$OUT/${name}_opt.s" 2>/dev/null; then
            echo "FAIL $name (asm peephole failed)"
            FAIL=$((FAIL + 1))
            continue
        fi
        mv "$OUT/${name}_opt.s" "$OUT/${name}.s"
    fi
    if [ "${USE_REGALLOC:-0}" = "1" ]; then
        if ! python3 "$REGALLOC" < "$OUT/${name}.s" > "$OUT/${name}_opt.s" 2>/dev/null; then
            echo "FAIL $name (regalloc failed)"
            FAIL=$((FAIL + 1))
            continue
        fi
        mv "$OUT/${name}_opt.s" "$OUT/${name}.s"
    fi
    if ! $ASM -arch arm64 -o "$OUT/${name}.o" "$OUT/${name}.s" 2>/dev/null; then
        echo "FAIL $name (assembler failed)"
        FAIL=$((FAIL + 1))
        continue
    fi
    if ! ld -arch arm64 -platform_version macos 14.0 14.0 \
         -syslibroot "$SDK" -lSystem -e _main \
         -o "$OUT/${name}" "$OUT/${name}.o" 2>/dev/null; then
        echo "FAIL $name (linker failed)"
        FAIL=$((FAIL + 1))
        continue
    fi

    # Run and time (3 iterations, take median)
    times=()
    correct=true
    for i in 1 2 3; do
        start_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time_ns()))')
        set +e
        "$OUT/$name"
        actual=$?
        set -e
        end_ns=$(date +%s%N 2>/dev/null || python3 -c 'import time; print(int(time.time_ns()))')
        elapsed=$(( (end_ns - start_ns) / 1000000 )) # ms
        times+=($elapsed)
        if [ "$actual" != "$expected" ]; then
            correct=false
        fi
    done

    if [ "$correct" = "false" ]; then
        echo "FAIL $name (expected $expected, got $actual)"
        FAIL=$((FAIL + 1))
        continue
    fi

    # Sort and take median
    IFS=$'\n' sorted=($(printf '%s\n' "${times[@]}" | sort -n)); unset IFS
    median=${sorted[1]}
    echo "PASS $name: ${median}ms (exit $actual)"
    PASS=$((PASS + 1))
    TOTAL_TIME=$((TOTAL_TIME + median))
done

echo ""
echo "Results: $PASS passed, $FAIL failed out of $TOTAL benchmarks"
echo "Total time: ${TOTAL_TIME}ms"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
