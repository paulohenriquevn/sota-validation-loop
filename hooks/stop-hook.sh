#!/usr/bin/env bash
# =============================================================================
# SOTA Evolution Loop — Stop Hook (v2)
# =============================================================================
# Implements the autonomous evolution loop using the Ralph Wiggum pattern.
# On every Claude stop event, this script:
#   1. Reads phase state from .claude/sota-loop.local.md
#   2. Detects phase completion markers in Claude's output
#   3. Enforces quality gates (keep/discard)
#   4. Manages deterministic rollback via git checkout
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
LOCK_FILE=".claude/sota-hook.lock"

# -------------------------------------------------------------------
# Concurrency guard — prevent two hook instances from corrupting state
# -------------------------------------------------------------------
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  exit 0  # Another hook instance is already running
fi
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
  "plan"      # Phase 3 — Evolution plan (tasks, ACs, DoDs)
  "evolve"    # Phase 4 — Execute plan with TDD
  "verify"    # Phase 5 — Keep/discard
  "report"    # Phase 6 — Final report
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
FEATURES_SKIP=$(read_state_field "features_skip" "0")
BUDGET_USD=$(read_state_field "budget_usd" "0")
SPENT_USD=$(read_state_field "spent_usd" "0.0")
BASELINE_GLOBAL_ITER=$(read_state_field "baseline_global_iter" "")

PHASE_NAME="${PHASE_NAMES[$CURRENT_PHASE]:-unknown}"

# Validate critical state fields
if [ "$CURRENT_PHASE" -lt 0 ] 2>/dev/null || [ "$CURRENT_PHASE" -gt 6 ] 2>/dev/null; then
  echo "⚠️  Invalid current_phase ($CURRENT_PHASE). Resetting to 0." >&2
  CURRENT_PHASE=0
  PHASE_NAME="research"
fi
if [ "$GLOBAL_ITERATION" -lt 1 ] 2>/dev/null; then
  echo "⚠️  Invalid global_iteration ($GLOBAL_ITERATION). Resetting to 1." >&2
  GLOBAL_ITERATION=1
fi

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

# Warn if transcript path was expected but empty
if [ -n "$HOOK_INPUT" ] && [ -z "$TRANSCRIPT_PATH" ]; then
  echo "⚠️  Hook received input but failed to extract transcript_path. Marker detection may fail." >&2
fi

# Extract last assistant message with fallback
LAST_OUTPUT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
  LAST_OUTPUT=$(TRANSCRIPT_PATH="$TRANSCRIPT_PATH" python3 -c "
import json, os, sys
try:
    with open(os.environ['TRANSCRIPT_PATH']) as f:
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
    # Block SOTA declaration if E2E probes were skipped — features not validated
    if [ "$FEATURES_SKIP" -gt 0 ] 2>/dev/null; then
      echo "🚫 Completion promise found but ${FEATURES_SKIP} features were SKIPPED (not validated by real E2E probes)." >&2
      echo "   SOTA cannot be declared without real E2E testing. Run 'theo login' and retry." >&2
      echo "   Continuing loop to allow E2E validation..." >&2
    else
      echo "✅ SOTA evolution loop complete! Promise fulfilled: $COMPLETION_PROMISE" >&2
      echo "   Features: $FEATURES_PASSING/$FEATURES_TOTAL passing, 0 skipped" >&2
      echo "   Refinement cycles: $REFINEMENT_CYCLES" >&2
      echo "   Budget spent: \$${SPENT_USD}" >&2
      rm -f "$STATE_FILE"
      exit 0
    fi
  fi
fi

# -------------------------------------------------------------------
# 5. Check global iteration limit and budget
# -------------------------------------------------------------------
if [ "$GLOBAL_ITERATION" -ge "$MAX_GLOBAL" ]; then
  echo "⚠️  Max iterations reached ($MAX_GLOBAL). Stopping." >&2
  rm -f "$STATE_FILE"
  exit 0
fi

# Budget enforcement: stop if budget is set and exceeded
if [ "$BUDGET_USD" != "0" ] && [ -n "$BUDGET_USD" ]; then
  BUDGET_EXCEEDED=$(SPENT="$SPENT_USD" BUDGET="$BUDGET_USD" python3 -c "
import os
spent = float(os.environ['SPENT'])
budget = float(os.environ['BUDGET'])
print('true' if budget > 0 and spent >= budget else 'false')
" 2>/dev/null || echo "false")
  if [ "$BUDGET_EXCEEDED" = "true" ]; then
    echo "⚠️  Budget exhausted (\$${SPENT_USD}/\$${BUDGET_USD}). Stopping." >&2
    rm -f "$STATE_FILE"
    exit 0
  fi
fi

# -------------------------------------------------------------------
# 6. Detect phase completion markers
# -------------------------------------------------------------------
PHASE_COMPLETE=false
if echo "$LAST_OUTPUT" | grep -q "<!-- PHASE_${CURRENT_PHASE}_COMPLETE -->"; then
  PHASE_COMPLETE=true
fi
# Legacy marker support (backward compatibility with prompts using old numbering)
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
  NEW_PASSING=$(echo "$LAST_OUTPUT" | grep -oP '<!-- FEATURES_STATUS:[^-]*passing=\K[0-9]+' | head -1 || echo "")
  NEW_FAILING=$(echo "$LAST_OUTPUT" | grep -oP '<!-- FEATURES_STATUS:[^-]*failing=\K[0-9]+' | head -1 || echo "")
  NEW_SKIP=$(echo "$LAST_OUTPUT" | grep -oP '<!-- FEATURES_STATUS:[^-]*skip=\K[0-9]+' | head -1 || echo "")
  [ -n "$NEW_TOTAL" ] && FEATURES_TOTAL="$NEW_TOTAL"
  [ -n "$NEW_PASSING" ] && FEATURES_PASSING="$NEW_PASSING"
  [ -n "$NEW_FAILING" ] && FEATURES_FAILING="$NEW_FAILING"
  [ -n "$NEW_SKIP" ] && FEATURES_SKIP="$NEW_SKIP"
fi

# Detect DISCARD marker — trigger deterministic rollback
if echo "$LAST_OUTPUT" | grep -q '<!-- DISCARD -->'; then
  echo "🔄 DISCARD detected — performing deterministic rollback via git" >&2
  BASELINE_HEAD_FILE="$OUTPUT_DIR/baselines/head-ref-iter-${BASELINE_GLOBAL_ITER}.txt"
  BASELINE_HEAD=""
  if [ -f "$BASELINE_HEAD_FILE" ]; then
    BASELINE_HEAD=$(cat "$BASELINE_HEAD_FILE")
    echo "   Restoring to baseline HEAD: $BASELINE_HEAD" >&2
  fi
  # Rollback to baseline HEAD if available, otherwise to current HEAD
  if [ -n "$BASELINE_HEAD" ] && git cat-file -t "$BASELINE_HEAD" >/dev/null 2>&1; then
    git checkout "$BASELINE_HEAD" -- . 2>/dev/null || git checkout -- . 2>/dev/null || true
  else
    git checkout -- . 2>/dev/null || true
  fi
  git clean -fd --exclude="sota-output/" --exclude=".claude/" 2>/dev/null || true
  echo "   Rolled back to pre-fix state" >&2
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

    # Save git HEAD reference for rollback tracking
    GIT_HEAD=$(git rev-parse HEAD 2>/dev/null || echo "unknown")
    echo "$GIT_HEAD" > "$OUTPUT_DIR/baselines/head-ref-iter-${GLOBAL_ITERATION}.txt"
    BASELINE_GLOBAL_ITER="$GLOBAL_ITERATION"

    # Save feature status baseline via env vars (no shell injection)
    BASELINE_SAVE_OK=false
    if BASELINE_FILE="$BASELINE_FILE" \
    ITER="$GLOBAL_ITERATION" \
    CYCLE="$REFINEMENT_CYCLES" \
    F_TOTAL="$FEATURES_TOTAL" \
    F_PASSING="$FEATURES_PASSING" \
    F_FAILING="$FEATURES_FAILING" \
    F_SKIP="$FEATURES_SKIP" \
    GIT_HEAD="$GIT_HEAD" \
    python3 -c "
import json, os, time
baseline = {
    'iteration': int(os.environ['ITER']),
    'cycle': int(os.environ['CYCLE']),
    'features_total': int(os.environ['F_TOTAL']),
    'features_passing': int(os.environ['F_PASSING']),
    'features_failing': int(os.environ['F_FAILING']),
    'features_skip': int(os.environ['F_SKIP']),
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'git_head': os.environ['GIT_HEAD']
}
with open(os.environ['BASELINE_FILE'], 'w') as f:
    json.dump(baseline, f, indent=2)
" 2>/dev/null; then
      BASELINE_SAVE_OK=true
    else
      echo "❌ CRITICAL: Failed to save baseline snapshot. DISCARD rollback will not work correctly." >&2
      echo "   Retrying baseline save..." >&2
      # Retry once with simpler fallback
      echo "{\"iteration\":$GLOBAL_ITERATION,\"cycle\":$REFINEMENT_CYCLES,\"features_passing\":$FEATURES_PASSING,\"features_failing\":$FEATURES_FAILING,\"git_head\":\"$GIT_HEAD\"}" > "$BASELINE_FILE" 2>/dev/null && BASELINE_SAVE_OK=true || true
    fi
  fi
fi

# -------------------------------------------------------------------
# 8. Progress history tracking
# -------------------------------------------------------------------
PROGRESS_FILE="$OUTPUT_DIR/progress/history.jsonl"
PROGRESS_FILE="$PROGRESS_FILE" \
ITER="$GLOBAL_ITERATION" \
PHASE="$CURRENT_PHASE" \
PHASE_NAME="$PHASE_NAME" \
PHASE_ITER="$PHASE_ITERATION" \
CYCLE="$REFINEMENT_CYCLES" \
F_PASSING="$FEATURES_PASSING" \
F_FAILING="$FEATURES_FAILING" \
F_SKIP="$FEATURES_SKIP" \
F_TOTAL="$FEATURES_TOTAL" \
Q_SCORE="${QUALITY_SCORE:-}" \
P_COMPLETE="$PHASE_COMPLETE" \
python3 -c "
import json, os, time
entry = {
    'iteration': int(os.environ['ITER']),
    'phase': int(os.environ['PHASE']),
    'phase_name': os.environ['PHASE_NAME'],
    'phase_iteration': int(os.environ['PHASE_ITER']),
    'cycle': int(os.environ['CYCLE']),
    'features_passing': int(os.environ['F_PASSING']),
    'features_failing': int(os.environ['F_FAILING']),
    'features_skip': int(os.environ['F_SKIP']),
    'features_total': int(os.environ['F_TOTAL']),
    'quality_score': os.environ['Q_SCORE'] or None,
    'phase_complete': os.environ['P_COMPLETE'] == 'true',
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
}
with open(os.environ['PROGRESS_FILE'], 'a') as f:
    f.write(json.dumps(entry) + '\n')
" 2>/dev/null || true

# -------------------------------------------------------------------
# 9. Stall detection — no progress for 2 cycles
# -------------------------------------------------------------------
STALL_DETECTED=false
if [ -f "$PROGRESS_FILE" ] && [ "$REFINEMENT_CYCLES" -ge 2 ]; then
  STALL_DETECTED=$(PROGRESS_FILE="$PROGRESS_FILE" python3 -c "
import json, os
entries = []
with open(os.environ['PROGRESS_FILE']) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue

# Get passing counts at end of each cycle (phase 5/verify entries, since
# phase 6 is skipped on auto loop-back when features are still failing)
cycle_results = {}
for e in entries:
    if e.get('phase') in (5, 6) and e.get('phase_complete'):
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
  # Quality gates on phases 2-5 (analyze, plan, evolve, verify)
  if [ "$CURRENT_PHASE" -ge 2 ] && [ "$CURRENT_PHASE" -le 5 ]; then
    if [ "$QUALITY_PASSED" = "1" ]; then
      # Quality gate PASSED — advance
      NEXT_PHASE=$((CURRENT_PHASE + 1))
      NEXT_PHASE_ITER=1
    else
      # Quality gate FAILED or ABSENT — repeat phase with feedback
      if [ -z "$QUALITY_PASSED" ]; then
        echo "⚠️  Quality gate marker ABSENT. Repeating phase $PHASE_NAME (gate requires explicit QUALITY_PASSED:1)." >&2
      else
        echo "⚠️  Quality gate FAILED (score: ${QUALITY_SCORE:-?}). Repeating phase $PHASE_NAME." >&2
      fi
      NEXT_PHASE=$CURRENT_PHASE
      NEXT_PHASE_ITER=$((PHASE_ITERATION + 1))

      # Check max iterations for this phase
      MAX_ITER=${PHASE_MAX_ITER[$CURRENT_PHASE]:-3}
      if [ "$NEXT_PHASE_ITER" -gt "$MAX_ITER" ]; then
        echo "⚠️  Phase $PHASE_NAME exhausted ($MAX_ITER iterations). Forcing advance." >&2
        NEXT_PHASE=$((CURRENT_PHASE + 1))
        NEXT_PHASE_ITER=1
      fi
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
if [ "$LOOP_BACK" = true ] && [ "$REFINEMENT_CYCLES" -ge "$MAX_REFINEMENT_CYCLES" ]; then
  echo "⚠️  Loop-back requested but max refinement cycles reached ($MAX_REFINEMENT_CYCLES). Ignoring loop-back." >&2
fi
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
  # Features still failing → loop back
  if [ "$FEATURES_FAILING" -gt 0 ] 2>/dev/null && [ "$REFINEMENT_CYCLES" -lt "$MAX_REFINEMENT_CYCLES" ]; then
    if [ "$STALL_DETECTED" = "true" ]; then
      echo "🛑 Features still failing but no progress. Stopping after $REFINEMENT_CYCLES cycles." >&2
      NEXT_PHASE=6
    else
      echo "🔄 Still $FEATURES_FAILING features failing. Auto loop-back. Cycle $((REFINEMENT_CYCLES + 1))/$MAX_REFINEMENT_CYCLES" >&2
      NEXT_PHASE=1
      NEXT_PHASE_ITER=1
      REFINEMENT_CYCLES=$((REFINEMENT_CYCLES + 1))
    fi
  # Features skipped (not validated by real E2E) → loop back, cannot declare SOTA
  elif [ "$FEATURES_SKIP" -gt 0 ] 2>/dev/null && [ "$REFINEMENT_CYCLES" -lt "$MAX_REFINEMENT_CYCLES" ]; then
    if [ "$STALL_DETECTED" = "true" ]; then
      echo "🛑 ${FEATURES_SKIP} features skipped (E2E not validated) but stall detected. Stopping." >&2
      echo "   ⚠️ SOTA NOT REACHED — skipped features need real E2E probes (run 'theo login')." >&2
      NEXT_PHASE=6
    else
      echo "🚫 ${FEATURES_SKIP} features SKIPPED — not validated by real E2E probes. Cannot declare SOTA." >&2
      echo "   Looping back to probe. Ensure OAuth session is active (run 'theo login')." >&2
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
PROMPT_TEXT=$(awk 'BEGIN{c=0} /^---$/{c++; next} c>=2{print}' "$STATE_FILE")

TMPFILE=$(mktemp "$(dirname "$STATE_FILE")/.sota-loop.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT

# Write YAML frontmatter (variable expansion needed for state fields)
{
  echo "---"
  echo "active: true"
  echo "topic: $(read_state_field "topic" "SOTA Evolution")"
  echo "current_phase: $NEXT_PHASE"
  echo "phase_name: \"$NEXT_PHASE_NAME\""
  echo "phase_iteration: $NEXT_PHASE_ITER"
  echo "global_iteration: $((GLOBAL_ITERATION + 1))"
  echo "max_global_iterations: $MAX_GLOBAL"
  echo "completion_promise: \"$COMPLETION_PROMISE\""
  echo "started_at: $(read_state_field "started_at" "")"
  echo "output_dir: \"$OUTPUT_DIR\""
  echo "refinement_cycles: $REFINEMENT_CYCLES"
  echo "max_refinement_cycles: $MAX_REFINEMENT_CYCLES"
  echo "features_total: $FEATURES_TOTAL"
  echo "features_passing: $FEATURES_PASSING"
  echo "features_failing: $FEATURES_FAILING"
  echo "features_skip: $FEATURES_SKIP"
  echo "budget_usd: $BUDGET_USD"
  echo "spent_usd: $SPENT_USD"
  echo "thresholds_path: $(read_state_field "thresholds_path" "docs/sota-thresholds.toml")"
  echo "feature_registry_path: $(read_state_field "feature_registry_path" "docs/feature-registry.toml")"
  echo "stall_detected: $STALL_DETECTED"
  echo "baseline_global_iter: $BASELINE_GLOBAL_ITER"
  echo "---"
} > "$TMPFILE"

# Write prompt body (no shell expansion — literal content)
printf '%s\n' "$PROMPT_TEXT" >> "$TMPFILE"

mv "$TMPFILE" "$STATE_FILE"

# -------------------------------------------------------------------
# 14. Build system message
# -------------------------------------------------------------------
MAX_ITER_CURRENT=${PHASE_MAX_ITER[$NEXT_PHASE]:-3}
SYSTEM_MSG="Phase ${NEXT_PHASE}/6: ${NEXT_PHASE_NAME} | Phase iter ${NEXT_PHASE_ITER}/${MAX_ITER_CURRENT} | Global iter $((GLOBAL_ITERATION + 1))/${MAX_GLOBAL} | Cycle ${REFINEMENT_CYCLES}/${MAX_REFINEMENT_CYCLES} | Features: ${FEATURES_PASSING}/${FEATURES_TOTAL} passing, ${FEATURES_FAILING} failing, ${FEATURES_SKIP} skip | Budget: \$${SPENT_USD}/\$${BUDGET_USD}"

if [ -n "$QUALITY_SCORE" ]; then
  SYSTEM_MSG="$SYSTEM_MSG | Last quality: ${QUALITY_SCORE}"
fi
if [ "$FEATURES_SKIP" -gt 0 ] 2>/dev/null; then
  SYSTEM_MSG="$SYSTEM_MSG | ⚠️ E2E NOT VALIDATED: ${FEATURES_SKIP} features skipped — SOTA cannot be declared without real E2E probes"
fi
if [ "$STALL_DETECTED" = "true" ]; then
  SYSTEM_MSG="$SYSTEM_MSG | ⚠️ STALL DETECTED"
fi

# -------------------------------------------------------------------
# 15. Return block decision to re-inject prompt
# -------------------------------------------------------------------
STATE_FILE="$STATE_FILE" \
SYSTEM_MSG="$SYSTEM_MSG" \
python3 -c "
import json, os, sys
try:
    with open(os.environ['STATE_FILE']) as f:
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
        'systemMessage': os.environ['SYSTEM_MSG']
    }
    print(json.dumps(result))
except Exception as e:
    print(json.dumps({
        'decision': 'block',
        'reason': 'Error reading state file: ' + str(e),
        'systemMessage': os.environ.get('SYSTEM_MSG', '')
    }), file=sys.stdout)
"
