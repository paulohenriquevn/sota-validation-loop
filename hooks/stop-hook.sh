#!/usr/bin/env bash
# =============================================================================
# SOTA Evolution Loop — Stop Hook (v2)
# =============================================================================
# Implements the autonomous evolution loop using the Ralph Wiggum pattern.
# On every Claude stop event, this script:
#   1. Reads phase state from .claude/sota-loop.local.md
#   2. Detects phase completion markers in Claude's output
#   3. Enforces quality gates (keep/discard)
#   4. Manages deterministic rollback via git stash
#   5. Persists baseline snapshots for before/after comparison
#   6. Tracks progress history for stall detection
#   7. Advances or loops back
#   8. Re-injects the prompt to continue
#
# v2 changes:
#   - Deterministic rollback via git (not LLM-dependent)
#   - Baseline persistence in JSON
#   - Progress history with stall detection
#   - Robust error handling throughout
#   - Phase 0 (research) support
# =============================================================================

set -euo pipefail

STATE_FILE=".claude/sota-loop.local.md"
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(realpath "$0")")")}"
PROBE_SCRIPT="${PLUGIN_ROOT}/scripts/probe-runner.sh"

# Phase max iterations (tunable)
declare -A PHASE_MAX_ITER=(
  [0]=10  # research — SOTA deep research (95% confidence rule)
  [1]=3   # probe — run E2E probes
  [2]=3   # analyze — identify worst gaps
  [3]=3   # plan — evolution plan (tasks, ACs, DoDs)
  [4]=5   # evolve — execute plan with TDD
  [5]=3   # verify — rerun probes, compare
  [6]=2   # report — final report
)

PHASE_NAMES=(
  "research"  # Phase 0 — Deep Research (95% confidence)
  "probe"     # Phase 1 — Deterministic probes
  "analyze"   # Phase 2 — Gap analysis
  "plan"      # Phase 2.5 — Evolution plan (tasks, ACs, DoDs)
  "evolve"    # Phase 3 — Execute plan with TDD
  "verify"    # Phase 4 — Keep/discard
  "report"    # Phase 5 — Final report
)

# -------------------------------------------------------------------
# Helper: safe read from YAML frontmatter
# -------------------------------------------------------------------
read_state_field() {
  local field="$1"
  local default="${2:-}"
  local value
  value=$(sed -n "s/^${field}: *//p" "$STATE_FILE" 2>/dev/null | head -1 | tr -d '"' || echo "")
  echo "${value:-$default}"
}

# -------------------------------------------------------------------
# Helper: write JSON to file atomically
# -------------------------------------------------------------------
write_json() {
  local file="$1"
  local content="$2"
  local tmpfile
  tmpfile=$(mktemp)
  echo "$content" > "$tmpfile"
  mv "$tmpfile" "$file"
}

# -------------------------------------------------------------------
# 1. Check if loop is active
# -------------------------------------------------------------------
if [ ! -f "$STATE_FILE" ]; then
  exit 0
fi

ACTIVE=$(read_state_field "active" "false")
if [ "$ACTIVE" != "true" ]; then
  exit 0
fi

# -------------------------------------------------------------------
# 2. Read current state (with safe defaults)
# -------------------------------------------------------------------
CURRENT_PHASE=$(read_state_field "current_phase" "0")
PHASE_ITERATION=$(read_state_field "phase_iteration" "1")
GLOBAL_ITERATION=$(read_state_field "global_iteration" "1")
MAX_GLOBAL=$(read_state_field "max_global_iterations" "10000")
COMPLETION_PROMISE=$(read_state_field "completion_promise" "")
OUTPUT_DIR=$(read_state_field "output_dir" "./sota-output")
REFINEMENT_CYCLES=$(read_state_field "refinement_cycles" "0")
MAX_REFINEMENT_CYCLES=$(read_state_field "max_refinement_cycles" "500")
FEATURES_TOTAL=$(read_state_field "features_total" "0")
FEATURES_PASSING=$(read_state_field "features_passing" "0")
FEATURES_FAILING=$(read_state_field "features_failing" "0")
BUDGET_USD=$(read_state_field "budget_usd" "0")
SPENT_USD=$(read_state_field "spent_usd" "0.0")

PHASE_NAME="${PHASE_NAMES[$CURRENT_PHASE]:-unknown}"

# Ensure output directories exist
mkdir -p "$OUTPUT_DIR"/{research,probes,analysis,plans,baselines,progress,report}

# -------------------------------------------------------------------
# 3. Read hook input (Claude's last output) — with error handling
# -------------------------------------------------------------------
HOOK_INPUT=""
if ! HOOK_INPUT=$(cat 2>/dev/null); then
  HOOK_INPUT=""
fi

TRANSCRIPT_PATH=""
if [ -n "$HOOK_INPUT" ]; then
  TRANSCRIPT_PATH=$(echo "$HOOK_INPUT" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('transcript_path', ''))
except Exception:
    print('')
" 2>/dev/null || echo "")
fi

# Extract last assistant message with fallback
LAST_OUTPUT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  LAST_OUTPUT=$(python3 -c "
import json, sys
try:
    with open('$TRANSCRIPT_PATH') as f:
        messages = json.load(f)
    for msg in reversed(messages):
        if msg.get('role') == 'assistant':
            content = msg.get('content', '')
            if isinstance(content, list):
                content = ' '.join(c.get('text', '') for c in content if isinstance(c, dict))
            print(content[:8000])
            break
except Exception as e:
    print('', file=sys.stderr)
" 2>/dev/null || echo "")
fi

# -------------------------------------------------------------------
# 4. Check completion promise
# -------------------------------------------------------------------
if [ -n "$COMPLETION_PROMISE" ] && [ "$COMPLETION_PROMISE" != "null" ]; then
  if echo "$LAST_OUTPUT" | grep -qF "$COMPLETION_PROMISE"; then
    echo "✅ SOTA evolution loop complete! Promise fulfilled: $COMPLETION_PROMISE" >&2
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
# Phase 3 (plan) can also be signaled via the legacy "2.5" marker
if [ "$CURRENT_PHASE" -eq 3 ] && echo "$LAST_OUTPUT" | grep -q '<!-- PHASE_2_5_COMPLETE -->'; then
  PHASE_COMPLETE=true
fi

# Detect quality gate markers
QUALITY_SCORE=""
QUALITY_PASSED=""
if echo "$LAST_OUTPUT" | grep -q '<!-- QUALITY_SCORE:'; then
  QUALITY_SCORE=$(echo "$LAST_OUTPUT" | grep -oP '<!-- QUALITY_SCORE:\K[0-9.]+' | head -1 || echo "")
fi
if echo "$LAST_OUTPUT" | grep -q '<!-- QUALITY_PASSED:'; then
  QUALITY_PASSED=$(echo "$LAST_OUTPUT" | grep -oP '<!-- QUALITY_PASSED:\K[01]' | head -1 || echo "")
fi

# Detect loop-back marker
LOOP_BACK=false
if echo "$LAST_OUTPUT" | grep -q '<!-- LOOP_BACK_TO_PROBE -->'; then
  LOOP_BACK=true
fi

# Detect feature count updates
if echo "$LAST_OUTPUT" | grep -q '<!-- FEATURES_STATUS:'; then
  NEW_TOTAL=$(echo "$LAST_OUTPUT" | grep -oP '<!-- FEATURES_STATUS:total=\K[0-9]+' | head -1 || echo "")
  NEW_PASSING=$(echo "$LAST_OUTPUT" | grep -oP 'passing=\K[0-9]+' | head -1 || echo "")
  NEW_FAILING=$(echo "$LAST_OUTPUT" | grep -oP 'failing=\K[0-9]+' | head -1 || echo "")
  [ -n "$NEW_TOTAL" ] && FEATURES_TOTAL="$NEW_TOTAL"
  [ -n "$NEW_PASSING" ] && FEATURES_PASSING="$NEW_PASSING"
  [ -n "$NEW_FAILING" ] && FEATURES_FAILING="$NEW_FAILING"
fi

# Detect DISCARD marker — trigger deterministic rollback
if echo "$LAST_OUTPUT" | grep -q '<!-- DISCARD -->'; then
  echo "🔄 DISCARD detected — performing deterministic rollback via git" >&2
  STASH_REF_FILE="$OUTPUT_DIR/baselines/stash-ref-iter-${GLOBAL_ITERATION}.txt"
  if [ -f "$STASH_REF_FILE" ]; then
    STASH_REF=$(cat "$STASH_REF_FILE")
    if git stash list 2>/dev/null | grep -q "$STASH_REF"; then
      # Restore to pre-fix state
      git checkout -- . 2>/dev/null || true
      git clean -fd 2>/dev/null || true
      echo "   Rolled back to pre-fix state (stash: $STASH_REF)" >&2
    else
      echo "   ⚠️  Stash ref not found, attempting git checkout" >&2
      git checkout -- . 2>/dev/null || true
    fi
  else
    echo "   ⚠️  No stash ref file found, performing git checkout" >&2
    git checkout -- . 2>/dev/null || true
  fi
fi

# -------------------------------------------------------------------
# 7. Baseline snapshot management
# -------------------------------------------------------------------
# Before Phase 3 (refine) starts, snapshot the current state
# Baseline saved before Phase 4 (evolve), which executes the plan from Phase 3 (plan)
if [ "$CURRENT_PHASE" -eq 4 ] && [ "$PHASE_ITERATION" -eq 1 ] && [ "$PHASE_COMPLETE" = false ]; then
  BASELINE_FILE="$OUTPUT_DIR/baselines/baseline-cycle-${REFINEMENT_CYCLES}-iter-${GLOBAL_ITERATION}.json"
  if [ ! -f "$BASELINE_FILE" ]; then
    echo "📸 Saving baseline snapshot before fix" >&2

    # Save git state
    STASH_MSG="sota-baseline-iter-${GLOBAL_ITERATION}"
    git stash push -m "$STASH_MSG" --include-untracked 2>/dev/null || true
    git stash pop 2>/dev/null || true
    echo "$STASH_MSG" > "$OUTPUT_DIR/baselines/stash-ref-iter-${GLOBAL_ITERATION}.txt"

    # Save feature status baseline
    python3 -c "
import json, time
baseline = {
    'iteration': $GLOBAL_ITERATION,
    'cycle': $REFINEMENT_CYCLES,
    'features_total': $FEATURES_TOTAL,
    'features_passing': $FEATURES_PASSING,
    'features_failing': $FEATURES_FAILING,
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'git_head': '$(git rev-parse HEAD 2>/dev/null || echo unknown)'
}
with open('$BASELINE_FILE', 'w') as f:
    json.dump(baseline, f, indent=2)
" 2>/dev/null || echo "⚠️  Failed to save baseline" >&2
  fi
fi

# -------------------------------------------------------------------
# 8. Progress history tracking
# -------------------------------------------------------------------
PROGRESS_FILE="$OUTPUT_DIR/progress/history.jsonl"
python3 -c "
import json, time
entry = {
    'iteration': $GLOBAL_ITERATION,
    'phase': $CURRENT_PHASE,
    'phase_name': '$PHASE_NAME',
    'phase_iteration': $PHASE_ITERATION,
    'cycle': $REFINEMENT_CYCLES,
    'features_passing': $FEATURES_PASSING,
    'features_failing': $FEATURES_FAILING,
    'features_total': $FEATURES_TOTAL,
    'quality_score': '${QUALITY_SCORE:-}' or None,
    'phase_complete': $( [ "$PHASE_COMPLETE" = true ] && echo "True" || echo "False" ),
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
}
with open('$PROGRESS_FILE', 'a') as f:
    f.write(json.dumps(entry) + '\n')
" 2>/dev/null || true

# -------------------------------------------------------------------
# 9. Stall detection — no progress for 2 cycles
# -------------------------------------------------------------------
STALL_DETECTED=false
if [ -f "$PROGRESS_FILE" ] && [ "$REFINEMENT_CYCLES" -ge 2 ]; then
  STALL_DETECTED=$(python3 -c "
import json
entries = []
with open('$PROGRESS_FILE') as f:
    for line in f:
        line = line.strip()
        if line:
            entries.append(json.loads(line))

# Get passing counts at end of each cycle (phase 6/report entries)
cycle_results = {}
for e in entries:
    if e.get('phase') == 6:
        cycle_results[e['cycle']] = e['features_passing']

# Check last 2 cycles
cycles = sorted(cycle_results.keys())
if len(cycles) >= 2:
    last = cycle_results[cycles[-1]]
    prev = cycle_results[cycles[-2]]
    if last <= prev:
        print('true')
    else:
        print('false')
else:
    print('false')
" 2>/dev/null || echo "false")
fi

if [ "$STALL_DETECTED" = "true" ]; then
  echo "⚠️  No progress detected for 2 consecutive cycles. Consider stopping." >&2
fi

# -------------------------------------------------------------------
# 10. Phase advancement logic
# -------------------------------------------------------------------
NEXT_PHASE=$CURRENT_PHASE
NEXT_PHASE_ITER=$((PHASE_ITERATION + 1))

if [ "$PHASE_COMPLETE" = true ]; then
  # Quality gate check (phases 2-4)
  # Quality gates on phases 2-5 (analyze, plan, evolve, verify)
  if [ "$CURRENT_PHASE" -ge 2 ] && [ "$CURRENT_PHASE" -le 5 ]; then
    if [ "$QUALITY_PASSED" = "0" ]; then
      # Quality gate FAILED — repeat phase with feedback
      echo "⚠️  Quality gate FAILED (score: ${QUALITY_SCORE:-?}). Repeating phase $PHASE_NAME." >&2
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
    # No quality gate for phases 0, 1, 6 — advance
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
# 11. Loop-back logic
# -------------------------------------------------------------------
if [ "$LOOP_BACK" = true ] && [ "$REFINEMENT_CYCLES" -lt "$MAX_REFINEMENT_CYCLES" ]; then
  if [ "$STALL_DETECTED" = "true" ]; then
    echo "🛑 Loop-back requested but stall detected (no progress for 2 cycles). Stopping." >&2
    rm -f "$STATE_FILE"
    exit 0
  fi
  echo "🔄 Loop-back triggered. Returning to Phase 1 (probe). Cycle $((REFINEMENT_CYCLES + 1))/$MAX_REFINEMENT_CYCLES" >&2
  NEXT_PHASE=1
  NEXT_PHASE_ITER=1
  REFINEMENT_CYCLES=$((REFINEMENT_CYCLES + 1))
fi

# -------------------------------------------------------------------
# 12. Check if loop is complete (Phase 5 finished)
# -------------------------------------------------------------------
if [ "$NEXT_PHASE" -gt 6 ]; then
  if [ "$FEATURES_FAILING" -gt 0 ] && [ "$REFINEMENT_CYCLES" -lt "$MAX_REFINEMENT_CYCLES" ]; then
    if [ "$STALL_DETECTED" = "true" ]; then
      echo "🛑 Features still failing but no progress. Stopping after $REFINEMENT_CYCLES cycles." >&2
      NEXT_PHASE=6
    else
      echo "🔄 Still $FEATURES_FAILING features failing. Auto loop-back. Cycle $((REFINEMENT_CYCLES + 1))/$MAX_REFINEMENT_CYCLES" >&2
      NEXT_PHASE=1
      NEXT_PHASE_ITER=1
      REFINEMENT_CYCLES=$((REFINEMENT_CYCLES + 1))
    fi
  else
    NEXT_PHASE=6  # Stay in report phase — loop is done
  fi
fi

NEXT_PHASE_NAME="${PHASE_NAMES[$NEXT_PHASE]:-unknown}"

# -------------------------------------------------------------------
# 13. Update state file (atomic write)
# -------------------------------------------------------------------
PROMPT_TEXT=$(sed -n '/^---$/,/^---$/!p' "$STATE_FILE" | tail -n +1)

TMPFILE=$(mktemp)
cat > "$TMPFILE" << YAML_END
---
active: true
topic: $(read_state_field "topic" "SOTA Evolution")
current_phase: $NEXT_PHASE
phase_name: "$NEXT_PHASE_NAME"
phase_iteration: $NEXT_PHASE_ITER
global_iteration: $((GLOBAL_ITERATION + 1))
max_global_iterations: $MAX_GLOBAL
completion_promise: "$COMPLETION_PROMISE"
started_at: $(read_state_field "started_at" "")
output_dir: "$OUTPUT_DIR"
refinement_cycles: $REFINEMENT_CYCLES
max_refinement_cycles: $MAX_REFINEMENT_CYCLES
features_total: $FEATURES_TOTAL
features_passing: $FEATURES_PASSING
features_failing: $FEATURES_FAILING
budget_usd: $BUDGET_USD
spent_usd: $SPENT_USD
thresholds_path: $(read_state_field "thresholds_path" "docs/sota-thresholds.toml")
feature_registry_path: $(read_state_field "feature_registry_path" "docs/feature-registry.toml")
stall_detected: $STALL_DETECTED
---
$PROMPT_TEXT
YAML_END

mv "$TMPFILE" "$STATE_FILE"

# -------------------------------------------------------------------
# 14. Build system message
# -------------------------------------------------------------------
MAX_ITER_CURRENT=${PHASE_MAX_ITER[$NEXT_PHASE]:-3}
SYSTEM_MSG="Phase ${NEXT_PHASE}/5: ${NEXT_PHASE_NAME} | Phase iter ${NEXT_PHASE_ITER}/${MAX_ITER_CURRENT} | Global iter $((GLOBAL_ITERATION + 1))/${MAX_GLOBAL} | Cycle ${REFINEMENT_CYCLES}/${MAX_REFINEMENT_CYCLES} | Features: ${FEATURES_PASSING}/${FEATURES_TOTAL} passing, ${FEATURES_FAILING} failing | Budget: \$${SPENT_USD}/\$${BUDGET_USD}"

if [ -n "$QUALITY_SCORE" ]; then
  SYSTEM_MSG="$SYSTEM_MSG | Last quality: ${QUALITY_SCORE}"
fi
if [ "$STALL_DETECTED" = "true" ]; then
  SYSTEM_MSG="$SYSTEM_MSG | ⚠️ STALL DETECTED"
fi

# -------------------------------------------------------------------
# 15. Return block decision to re-inject prompt
# -------------------------------------------------------------------
python3 -c "
import json, sys
try:
    with open('$STATE_FILE') as f:
        prompt = f.read()
    # Extract everything after the second ---
    parts = prompt.split('---', 2)
    if len(parts) >= 3:
        prompt_text = parts[2].strip()
    else:
        prompt_text = prompt

    result = {
        'decision': 'block',
        'reason': prompt_text,
        'systemMessage': '$SYSTEM_MSG'
    }
    print(json.dumps(result))
except Exception as e:
    print(json.dumps({
        'decision': 'block',
        'reason': 'Error reading state file: ' + str(e),
        'systemMessage': '$SYSTEM_MSG'
    }), file=sys.stdout)
"
