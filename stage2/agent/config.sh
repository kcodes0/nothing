#!/bin/bash
# Agent configuration for agentic optimization experiments
export MODIFIABLE_DIRS="stage2/passes stage2/codegen"
export READONLY_DIRS="stage0 stage1 stage2/bench/benchmarks"
export TIME_BUDGET=300  # seconds per experiment
export METRIC="total_time"  # optimize total execution time
