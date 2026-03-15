#!/bin/bash
if [ $# -lt 2 ]; then
    echo "Usage: $0 <baseline.txt> <optimized.txt>"
    exit 1
fi
echo "=== Comparing results ==="
# Parse timings from both files and compute speedup
paste <(grep "^PASS" "$1" | awk '{print $2, $3}') \
      <(grep "^PASS" "$2" | awk '{print $3}') | \
while read name base_time opt_time; do
    base_ms=$(echo "$base_time" | sed 's/ms//')
    opt_ms=$(echo "$opt_time" | sed 's/ms//')
    if [ "$base_ms" -gt 0 ]; then
        speedup=$(echo "scale=2; $base_ms / $opt_ms" | bc)
        echo "$name: ${base_ms}ms -> ${opt_ms}ms (${speedup}x)"
    fi
done
