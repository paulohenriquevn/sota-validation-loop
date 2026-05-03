#!/usr/bin/env bash
# =============================================================================
# SOTA Evolution Loop — Setup Script
# =============================================================================
# Called by /sota-loop command. Creates state file and output directory.
# =============================================================================

set -euo pipefail

PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
STATE_FILE=".claude/sota-loop.local.md"
TEMPLATE="${PLUGIN_ROOT}/templates/sota-prompt.md"

# Default values
THRESHOLDS_PATH="docs/sota-thresholds.toml"
REGISTRY_PATH="docs/feature-registry.toml"
MAX_CYCLES=500
MAX_ITERATIONS=10000
BUDGET=0
OUTPUT_DIR="./sota-output"
COMPLETION_PROMISE=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --thresholds)
      THRESHOLDS_PATH="$2"; shift 2 ;;
    --registry)
      REGISTRY_PATH="$2"; shift 2 ;;
    --max-cycles)
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --max-cycles must be a non-negative integer" >&2; exit 1
      fi
      MAX_CYCLES="$2"; shift 2 ;;
    --max-iterations)
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --max-iterations must be a non-negative integer" >&2; exit 1
      fi
      MAX_ITERATIONS="$2"; shift 2 ;;
    --budget)
      if ! [[ "$2" =~ ^[0-9]+$ ]]; then
        echo "ERROR: --budget must be a non-negative integer" >&2; exit 1
      fi
      BUDGET="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --completion-done)
      if [[ "$2" =~ [\"\\] ]]; then
        echo 'ERROR: --completion-done must not contain double quotes or backslashes' >&2; exit 1
      fi
      COMPLETION_PROMISE="$2"; shift 2 ;;
    *)
      # Unknown args — pass through as topic
      shift ;;
  esac
done

# Validate prerequisites
if [ ! -f "$THRESHOLDS_PATH" ]; then
  echo "ERROR: Thresholds file not found: $THRESHOLDS_PATH" >&2
  echo "Run Phase 2 of the SOTA pipeline plan first." >&2
  exit 1
fi

if [ ! -f "$REGISTRY_PATH" ]; then
  echo "ERROR: Feature registry not found: $REGISTRY_PATH" >&2
  echo "Create docs/feature-registry.toml first." >&2
  exit 1
fi

# Count features in registry (path passed via env to avoid shell injection)
FEATURES_TOTAL=$(REGISTRY_PATH="$REGISTRY_PATH" python3 -c "
import os
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open(os.environ['REGISTRY_PATH'], 'rb') as f:
    data = tomllib.load(f)
count = 0
for section, values in data.items():
    if section == 'meta': continue
    for key, val in values.items():
        if isinstance(val, dict) and 'type' in val:
            count += 1
print(count)
" 2>/dev/null || echo "0")

# Create output directory structure
mkdir -p "$OUTPUT_DIR"/{research,probes,analysis,plans,baselines,progress,report}
mkdir -p .claude

# Create state file with prompt
STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

{
  echo "---"
  echo "active: true"
  echo 'topic: "SOTA Evolution"'
  echo "current_phase: 0"
  echo 'phase_name: "research"'
  echo "phase_iteration: 1"
  echo "global_iteration: 1"
  echo "max_global_iterations: $MAX_ITERATIONS"
  printf 'completion_promise: "%s"\n' "$COMPLETION_PROMISE"
  echo "started_at: \"$STARTED_AT\""
  printf 'output_dir: "%s"\n' "$OUTPUT_DIR"
  echo "refinement_cycles: 0"
  echo "max_refinement_cycles: $MAX_CYCLES"
  echo "features_total: $FEATURES_TOTAL"
  echo "features_passing: 0"
  echo "features_failing: 0"
  echo "features_skip: 0"
  echo "budget_usd: $BUDGET"
  echo "spent_usd: 0.0"
  printf 'thresholds_path: "%s"\n' "$THRESHOLDS_PATH"
  printf 'feature_registry_path: "%s"\n' "$REGISTRY_PATH"
  echo "baseline_global_iter: "
  echo "---"
  cat "$TEMPLATE"
} > "$STATE_FILE"

echo ""
echo "🔄 SOTA Evolution Loop initialized!"
echo ""
echo "  Features to evolve: $FEATURES_TOTAL"
echo "  Thresholds: $THRESHOLDS_PATH"
echo "  Registry: $REGISTRY_PATH"
echo "  Max cycles: $MAX_CYCLES"
echo "  Budget: \$$BUDGET"
echo "  Output: $OUTPUT_DIR"
echo "  State: $STATE_FILE"
if [ -n "$COMPLETION_PROMISE" ]; then
  echo "  Completion: \"$COMPLETION_PROMISE\""
fi
echo ""
