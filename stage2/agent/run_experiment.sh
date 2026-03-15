#!/bin/bash
# run_experiment.sh — Run a single optimization experiment
# 1. Backup current state
# 2. Apply modifications (done by the agent before calling this)
# 3. Build and evaluate
# 4. Report results

DIR="$(cd "$(dirname "$0")" && pwd)"
PROJ="$DIR/../.."

echo "=== Running experiment ==="
start=$(date +%s)

# Build the toolchain
echo "Building toolchain..."
bash "$PROJ/stage1/build.sh" 2>/dev/null || { echo "BUILD FAILED"; exit 1; }

# Run evaluation
echo "Running benchmarks..."
bash "$DIR/../bench/eval.sh" 2>&1 | tee "$DIR/last_result.txt"

end=$(date +%s)
elapsed=$((end - start))
echo "Experiment completed in ${elapsed}s"

# Extract total time from results
total=$(grep "Total time:" "$DIR/last_result.txt" | awk '{print $3}' | sed 's/ms//')
echo "Total time: ${total}ms"
