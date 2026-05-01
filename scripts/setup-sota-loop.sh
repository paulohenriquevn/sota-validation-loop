#!/usr/bin/env bash
# =============================================================================
# SOTA Validation Loop — Setup Script
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
      MAX_CYCLES="$2"; shift 2 ;;
    --max-iterations)
      MAX_ITERATIONS="$2"; shift 2 ;;
    --budget)
      BUDGET="$2"; shift 2 ;;
    --output-dir)
      OUTPUT_DIR="$2"; shift 2 ;;
    --completion-done)
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

# Count features in registry
FEATURES_TOTAL=$(python3 -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open('$REGISTRY_PATH', 'rb') as f:
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
mkdir -p "$OUTPUT_DIR"/{research,probes,analysis,plans,baselines,progress,report,state}
mkdir -p .claude

# Create state file with prompt
STARTED_AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

cat > "$STATE_FILE" << EOF
---
active: true
topic: "SOTA Validation and Refinement"
current_phase: 0
phase_name: "research"
phase_iteration: 1
global_iteration: 1
max_global_iterations: $MAX_ITERATIONS
completion_promise: "$COMPLETION_PROMISE"
started_at: "$STARTED_AT"
output_dir: "$OUTPUT_DIR"
refinement_cycles: 0
max_refinement_cycles: $MAX_CYCLES
features_total: $FEATURES_TOTAL
features_passing: 0
features_failing: 0
budget_usd: $BUDGET
spent_usd: 0.0
thresholds_path: "$THRESHOLDS_PATH"
feature_registry_path: "$REGISTRY_PATH"
---
$(cat "$TEMPLATE")
EOF

echo ""
echo "🔄 SOTA Validation Loop initialized!"
echo ""
echo "  Features to validate: $FEATURES_TOTAL"
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
