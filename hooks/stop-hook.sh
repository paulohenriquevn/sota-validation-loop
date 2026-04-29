#!/usr/bin/env bash
# =============================================================================
# SOTA Validation Loop — Stop Hook
# =============================================================================
# Implements the autonomous validation loop using the Ralph Wiggum pattern.
# On every Claude stop event, this script:
#   1. Reads phase state from .claude/sota-loop.local.md
#   2. Detects phase completion markers in Claude's output
#   3. Enforces quality gates (keep/discard)
#   4. Checks hard blocks (evidence in DB)
#   5. Advances or loops back
#   6. Re-injects the prompt to continue
# =============================================================================

set -euo pipefail

STATE_FILE=".claude/sota-loop.local.md"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
DB_SCRIPT="${PLUGIN_ROOT}/scripts/sota_database.py"

# Phase max iterations (tunable)
declare -A PHASE_MAX_ITER=(
  [1]=3   # probe — run E2E probes
  [2]=3   # analyze — identify worst gaps
  [3]=5   # refine — propose and apply fixes
  [4]=3   # validate — rerun probes, compare
  [5]=2   # report — final report
)

PHASE_NAMES=(
  ""        # 0-indexed placeholder
  "probe"
  "analyze"
  "refine"
  "validate"
  "report"
)

# -------------------------------------------------------------------
# 1. Check if loop is active
# -------------------------------------------------------------------
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

# Read YAML frontmatter
ACTIVE=$(sed -n 's/^active: *//p' "$STATE_FILE" | head -1)
if [ "$ACTIVE" != "true" ]; then
  exit 0
fi

# -------------------------------------------------------------------
# 2. Read current state
# -------------------------------------------------------------------
CURRENT_PHASE=$(sed -n 's/^current_phase: *//p' "$STATE_FILE" | head -1)
PHASE_ITERATION=$(sed -n 's/^phase_iteration: *//p' "$STATE_FILE" | head -1)
GLOBAL_ITERATION=$(sed -n 's/^global_iteration: *//p' "$STATE_FILE" | head -1)
MAX_GLOBAL=$(sed -n 's/^max_global_iterations: *//p' "$STATE_FILE" | head -1)
COMPLETION_PROMISE=$(sed -n 's/^completion_promise: *//p' "$STATE_FILE" | head -1 | tr -d '"')
OUTPUT_DIR=$(sed -n 's/^output_dir: *//p' "$STATE_FILE" | head -1 | tr -d '"')
REFINEMENT_CYCLES=$(sed -n 's/^refinement_cycles: *//p' "$STATE_FILE" | head -1)
MAX_REFINEMENT_CYCLES=$(sed -n 's/^max_refinement_cycles: *//p' "$STATE_FILE" | head -1)
FEATURES_TOTAL=$(sed -n 's/^features_total: *//p' "$STATE_FILE" | head -1)
FEATURES_PASSING=$(sed -n 's/^features_passing: *//p' "$STATE_FILE" | head -1)
FEATURES_FAILING=$(sed -n 's/^features_failing: *//p' "$STATE_FILE" | head -1)
BUDGET_USD=$(sed -n 's/^budget_usd: *//p' "$STATE_FILE" | head -1)
SPENT_USD=$(sed -n 's/^spent_usd: *//p' "$STATE_FILE" | head -1)

# Defaults
CURRENT_PHASE=${CURRENT_PHASE:-1}
PHASE_ITERATION=${PHASE_ITERATION:-1}
GLOBAL_ITERATION=${GLOBAL_ITERATION:-1}
MAX_GLOBAL=${MAX_GLOBAL:-30}
REFINEMENT_CYCLES=${REFINEMENT_CYCLES:-0}
MAX_REFINEMENT_CYCLES=${MAX_REFINEMENT_CYCLES:-5}
FEATURES_TOTAL=${FEATURES_TOTAL:-0}
FEATURES_PASSING=${FEATURES_PASSING:-0}
FEATURES_FAILING=${FEATURES_FAILING:-0}
BUDGET_USD=${BUDGET_USD:-0}
SPENT_USD=${SPENT_USD:-0.0}

PHASE_NAME="${PHASE_NAMES[$CURRENT_PHASE]:-unknown}"

# -------------------------------------------------------------------
# 3. Read hook input (Claude's last output)
# -------------------------------------------------------------------
HOOK_INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('transcript_path', ''))
except:
    print('')
" 2>/dev/null || echo "")

# Extract last assistant message
LAST_OUTPUT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  LAST_OUTPUT=$(python3 -c "
import json, sys
with open('$TRANSCRIPT_PATH') as f:
    messages = json.load(f)
for msg in reversed(messages):
    if msg.get('role') == 'assistant':
        content = msg.get('content', '')
        if isinstance(content, list):
            content = ' '.join(c.get('text', '') for c in content if isinstance(c, dict))
        print(content[:5000])
        break
" 2>/dev/null || echo "")
fi

# -------------------------------------------------------------------
# 4. Check completion promise
# -------------------------------------------------------------------
if [ -n "$COMPLETION_PROMISE" ] && [ "$COMPLETION_PROMISE" != "null" ]; then
  if echo "$LAST_OUTPUT" | grep -qF "$COMPLETION_PROMISE"; then
    echo "✅ SOTA validation loop complete! Promise fulfilled: $COMPLETION_PROMISE" >&2
    echo "   Features: $FEATURES_PASSING/$FEATURES_TOTAL passing" >&2
    echo "   Refinement cycles: $REFINEMENT_CYCLES" >&2
    echo "   Budget spent: \$${SPENT_USD}" >&2
    rm -f "$STATE_FILE"
    exit 0
  fi
fi

# -------------------------------------------------------------------
# 5. Check global iteration limit
# -------------------------------------------------------------------
if [ "$GLOBAL_ITERATION" -ge "$MAX_GLOBAL" ]; then
  echo "⚠️  Max iterations reached ($MAX_GLOBAL). Stopping." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# -------------------------------------------------------------------
# 6. Detect phase completion markers
# -------------------------------------------------------------------
PHASE_COMPLETE=false
if echo "$LAST_OUTPUT" | grep -q "<!-- PHASE_${CURRENT_PHASE}_COMPLETE -->"; then
  PHASE_COMPLETE=true
fi

# Detect quality gate markers
QUALITY_SCORE=""
QUALITY_PASSED=""
if echo "$LAST_OUTPUT" | grep -q '<!-- QUALITY_SCORE:'; then
  QUALITY_SCORE=$(echo "$LAST_OUTPUT" | grep -oP '<!-- QUALITY_SCORE:(\K[0-9.]+)' | head -1)
fi
if echo "$LAST_OUTPUT" | grep -q '<!-- QUALITY_PASSED:'; then
  QUALITY_PASSED=$(echo "$LAST_OUTPUT" | grep -oP '<!-- QUALITY_PASSED:(\K[01])' | head -1)
fi

# Detect loop-back marker
LOOP_BACK=false
if echo "$LAST_OUTPUT" | grep -q '<!-- LOOP_BACK_TO_PROBE -->'; then
  LOOP_BACK=true
fi

# Detect feature count updates
if echo "$LAST_OUTPUT" | grep -q '<!-- FEATURES_STATUS:'; then
  NEW_TOTAL=$(echo "$LAST_OUTPUT" | grep -oP '<!-- FEATURES_STATUS:total=\K[0-9]+' | head -1)
  NEW_PASSING=$(echo "$LAST_OUTPUT" | grep -oP 'passing=\K[0-9]+' | head -1)
  NEW_FAILING=$(echo "$LAST_OUTPUT" | grep -oP 'failing=\K[0-9]+' | head -1)
  [ -n "$NEW_TOTAL" ] && FEATURES_TOTAL="$NEW_TOTAL"
  [ -n "$NEW_PASSING" ] && FEATURES_PASSING="$NEW_PASSING"
  [ -n "$NEW_FAILING" ] && FEATURES_FAILING="$NEW_FAILING"
fi

# -------------------------------------------------------------------
# 7. Phase advancement logic
# -------------------------------------------------------------------
NEXT_PHASE=$CURRENT_PHASE
NEXT_PHASE_ITER=$((PHASE_ITERATION + 1))

if [ "$PHASE_COMPLETE" = true ]; then
  # Quality gate check (phases 2-4)
  if [ "$CURRENT_PHASE" -ge 2 ] && [ "$CURRENT_PHASE" -le 4 ]; then
    if [ "$QUALITY_PASSED" = "0" ]; then
      # Quality gate FAILED — repeat phase with feedback
      echo "⚠️  Quality gate FAILED (score: $QUALITY_SCORE). Repeating phase $PHASE_NAME." >&2
      NEXT_PHASE=$CURRENT_PHASE
      NEXT_PHASE_ITER=$((PHASE_ITERATION + 1))

      # Check max iterations for this phase
      MAX_ITER=${PHASE_MAX_ITER[$CURRENT_PHASE]:-3}
      if [ "$NEXT_PHASE_ITER" -gt "$MAX_ITER" ]; then
        echo "⚠️  Phase $PHASE_NAME exhausted ($MAX_ITER iterations). Forcing advance." >&2
        NEXT_PHASE=$((CURRENT_PHASE + 1))
        NEXT_PHASE_ITER=1
      fi
    else
      # Quality gate PASSED — advance
      NEXT_PHASE=$((CURRENT_PHASE + 1))
      NEXT_PHASE_ITER=1
    fi
  else
    # No quality gate for this phase — advance
    NEXT_PHASE=$((CURRENT_PHASE + 1))
    NEXT_PHASE_ITER=1
  fi
else
  # Phase NOT complete — check iteration timeout
  MAX_ITER=${PHASE_MAX_ITER[$CURRENT_PHASE]:-3}
  if [ "$NEXT_PHASE_ITER" -gt "$MAX_ITER" ]; then
    echo "⚠️  Phase $PHASE_NAME timed out after $MAX_ITER iterations. Forcing advance." >&2
    NEXT_PHASE=$((CURRENT_PHASE + 1))
    NEXT_PHASE_ITER=1
  fi
fi

# -------------------------------------------------------------------
# 8. Loop-back logic
# -------------------------------------------------------------------
if [ "$LOOP_BACK" = true ] && [ "$REFINEMENT_CYCLES" -lt "$MAX_REFINEMENT_CYCLES" ]; then
  echo "🔄 Loop-back triggered. Returning to Phase 1 (probe). Cycle $((REFINEMENT_CYCLES + 1))/$MAX_REFINEMENT_CYCLES" >&2
  NEXT_PHASE=1
  NEXT_PHASE_ITER=1
  REFINEMENT_CYCLES=$((REFINEMENT_CYCLES + 1))
fi

# -------------------------------------------------------------------
# 9. Check if loop is complete (Phase 5 finished)
# -------------------------------------------------------------------
if [ "$NEXT_PHASE" -gt 5 ]; then
  # All phases done but no completion promise — check if we should loop back
  if [ "$FEATURES_FAILING" -gt 0 ] && [ "$REFINEMENT_CYCLES" -lt "$MAX_REFINEMENT_CYCLES" ]; then
    echo "🔄 Still $FEATURES_FAILING features failing. Auto loop-back to Phase 1. Cycle $((REFINEMENT_CYCLES + 1))/$MAX_REFINEMENT_CYCLES" >&2
    NEXT_PHASE=1
    NEXT_PHASE_ITER=1
    REFINEMENT_CYCLES=$((REFINEMENT_CYCLES + 1))
  else
    NEXT_PHASE=5  # Stay in report phase
  fi
fi

NEXT_PHASE_NAME="${PHASE_NAMES[$NEXT_PHASE]:-unknown}"

# -------------------------------------------------------------------
# 10. Update state file
# -------------------------------------------------------------------
PROMPT_TEXT=$(sed -n '/^---$/,/^---$/!p' "$STATE_FILE" | tail -n +1)

TMPFILE=$(mktemp)
cat > "$TMPFILE" << YAML_END
---
active: true
topic: $(sed -n 's/^topic: *//p' "$STATE_FILE" | head -1)
current_phase: $NEXT_PHASE
phase_name: "$NEXT_PHASE_NAME"
phase_iteration: $NEXT_PHASE_ITER
global_iteration: $((GLOBAL_ITERATION + 1))
max_global_iterations: $MAX_GLOBAL
completion_promise: "$COMPLETION_PROMISE"
started_at: $(sed -n 's/^started_at: *//p' "$STATE_FILE" | head -1)
output_dir: "$OUTPUT_DIR"
refinement_cycles: $REFINEMENT_CYCLES
max_refinement_cycles: $MAX_REFINEMENT_CYCLES
features_total: $FEATURES_TOTAL
features_passing: $FEATURES_PASSING
features_failing: $FEATURES_FAILING
budget_usd: $BUDGET_USD
spent_usd: $SPENT_USD
thresholds_path: $(sed -n 's/^thresholds_path: *//p' "$STATE_FILE" | head -1)
feature_registry_path: $(sed -n 's/^feature_registry_path: *//p' "$STATE_FILE" | head -1)
---
$PROMPT_TEXT
YAML_END

mv "$TMPFILE" "$STATE_FILE"

# -------------------------------------------------------------------
# 11. Build system message
# -------------------------------------------------------------------
SYSTEM_MSG="Phase ${NEXT_PHASE}/5: ${NEXT_PHASE_NAME} | Phase iter ${NEXT_PHASE_ITER}/${PHASE_MAX_ITER[$NEXT_PHASE]:-3} | Global iter $((GLOBAL_ITERATION + 1))/${MAX_GLOBAL} | Cycle ${REFINEMENT_CYCLES}/${MAX_REFINEMENT_CYCLES} | Features: ${FEATURES_PASSING}/${FEATURES_TOTAL} passing, ${FEATURES_FAILING} failing | Budget: \$${SPENT_USD}/\$${BUDGET_USD}"

if [ -n "$QUALITY_SCORE" ]; then
  SYSTEM_MSG="$SYSTEM_MSG | Last quality: ${QUALITY_SCORE}"
fi

# -------------------------------------------------------------------
# 12. Return block decision to re-inject prompt
# -------------------------------------------------------------------
python3 -c "
import json, sys
prompt = open('$STATE_FILE').read()
# Extract everything after the second ---
parts = prompt.split('---', 2)
if len(parts) >= 3:
    prompt_text = parts[2].strip()
else:
    prompt_text = prompt

print(json.dumps({
    'decision': 'block',
    'reason': prompt_text,
    'systemMessage': '$SYSTEM_MSG'
}))
"
