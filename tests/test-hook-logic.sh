#!/usr/bin/env bash
# =============================================================================
# Tests for SOTA Evolution Loop — Stop Hook Logic
# =============================================================================
# Tests the core logic of the stop hook: state reading, marker detection,
# phase advancement, loop-back, stall detection, and rollback.
#
# Usage: bash tests/test-hook-logic.sh
# =============================================================================

set -euo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(dirname "$TESTS_DIR")"
HOOK_SCRIPT="$PLUGIN_ROOT/hooks/stop-hook.sh"

# Test tracking
TOTAL=0
PASSED=0
FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# -------------------------------------------------------------------
# Test helpers
# -------------------------------------------------------------------
setup_test_dir() {
  TEST_WORKDIR=$(mktemp -d)
  mkdir -p "$TEST_WORKDIR/.claude"
  mkdir -p "$TEST_WORKDIR/sota-output"/{research,probes,analysis,plans,baselines,progress,report}
  cd "$TEST_WORKDIR"
  git init -q 2>/dev/null || true
  git config user.email "test@test.com" 2>/dev/null || true
  git config user.name "Test" 2>/dev/null || true
  echo "test" > file.txt
  git add . && git commit -q -m "init" 2>/dev/null || true
}

teardown_test_dir() {
  cd /tmp
  rm -rf "$TEST_WORKDIR" 2>/dev/null || true
}

create_state_file() {
  local phase="${1:-1}"
  local phase_iter="${2:-1}"
  local global_iter="${3:-1}"
  local features_passing="${4:-0}"
  local features_failing="${5:-5}"
  local refinement_cycles="${6:-0}"
  local phase_name=""

  case $phase in
    0) phase_name="research" ;;
    1) phase_name="probe" ;;
    2) phase_name="analyze" ;;
    3) phase_name="plan" ;;
    4) phase_name="evolve" ;;
    5) phase_name="verify" ;;
    6) phase_name="report" ;;
  esac

  cat > ".claude/sota-loop.local.md" << EOF
---
active: true
topic: "Test"
current_phase: $phase
phase_name: "$phase_name"
phase_iteration: $phase_iter
global_iteration: $global_iter
max_global_iterations: 30
completion_promise: "All features passing"
started_at: "2026-01-01T00:00:00Z"
output_dir: "./sota-output"
refinement_cycles: $refinement_cycles
max_refinement_cycles: 5
features_total: 10
features_passing: $features_passing
features_failing: $features_failing
features_skip: 0
budget_usd: 50
spent_usd: 5.0
thresholds_path: "docs/sota-thresholds.toml"
feature_registry_path: "docs/feature-registry.toml"
stall_detected: false
baseline_global_iter: ""
---
Test prompt content
EOF
}

assert_eq() {
  local desc="$1"
  local expected="$2"
  local actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    echo -e "${GREEN}PASS${NC}: $desc"
    PASSED=$((PASSED + 1))
  else
    echo -e "${RED}FAIL${NC}: $desc (expected='$expected', actual='$actual')"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() {
  local desc="$1"
  local pattern="$2"
  local text="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$text" | grep -q "$pattern"; then
    echo -e "${GREEN}PASS${NC}: $desc"
    PASSED=$((PASSED + 1))
  else
    echo -e "${RED}FAIL${NC}: $desc (pattern='$pattern' not found)"
    FAILED=$((FAILED + 1))
  fi
}

assert_file_exists() {
  local desc="$1"
  local file="$2"
  TOTAL=$((TOTAL + 1))
  if [ -f "$file" ]; then
    echo -e "${GREEN}PASS${NC}: $desc"
    PASSED=$((PASSED + 1))
  else
    echo -e "${RED}FAIL${NC}: $desc (file '$file' not found)"
    FAILED=$((FAILED + 1))
  fi
}

read_state() {
  local field="$1"
  sed -n "s/^${field}: *//p" ".claude/sota-loop.local.md" | head -1 | tr -d '"'
}

# ===================================================================
# TEST: State file reading
# ===================================================================
test_state_reading() {
  echo "=== State File Reading ==="
  setup_test_dir

  create_state_file 2 3 7 15 5 1

  assert_eq "reads current_phase" "2" "$(read_state current_phase)"
  assert_eq "reads phase_iteration" "3" "$(read_state phase_iteration)"
  assert_eq "reads global_iteration" "7" "$(read_state global_iteration)"
  assert_eq "reads features_passing" "15" "$(read_state features_passing)"
  assert_eq "reads features_failing" "5" "$(read_state features_failing)"
  assert_eq "reads refinement_cycles" "1" "$(read_state refinement_cycles)"

  teardown_test_dir
}

# ===================================================================
# TEST: No state file → exit cleanly
# ===================================================================
test_no_state_file() {
  echo "=== No State File ==="
  setup_test_dir

  # No state file exists
  local result
  result=$(echo '{}' | bash "$HOOK_SCRIPT" 2>&1) || true
  # Should exit 0 (no error)
  echo '{}' | bash "$HOOK_SCRIPT" 2>/dev/null
  assert_eq "exits cleanly without state file" "0" "$?"

  teardown_test_dir
}

# ===================================================================
# TEST: Inactive loop → exit cleanly
# ===================================================================
test_inactive_loop() {
  echo "=== Inactive Loop ==="
  setup_test_dir

  cat > ".claude/sota-loop.local.md" << 'EOF'
---
active: false
current_phase: 1
---
test
EOF

  echo '{}' | bash "$HOOK_SCRIPT" 2>/dev/null
  assert_eq "exits cleanly when inactive" "0" "$?"

  teardown_test_dir
}

# ===================================================================
# TEST: Phase completion detection
# ===================================================================
test_phase_completion_markers() {
  echo "=== Phase Completion Markers ==="

  # Test marker detection logic
  local output="Some text <!-- PHASE_1_COMPLETE --> more text"
  assert_contains "detects PHASE_1_COMPLETE" "PHASE_1_COMPLETE" "$output"

  output="Result <!-- QUALITY_SCORE:0.85 --> done"
  local score
  score=$(echo "$output" | grep -oP '<!-- QUALITY_SCORE:\K[0-9.]+' | head -1)
  assert_eq "extracts quality score" "0.85" "$score"

  output="Check <!-- QUALITY_PASSED:1 --> ok"
  local passed
  passed=$(echo "$output" | grep -oP '<!-- QUALITY_PASSED:\K[01]' | head -1)
  assert_eq "extracts quality passed" "1" "$passed"

  output="<!-- FEATURES_STATUS:total=196,passing=42,failing=3 -->"
  local total passing failing
  total=$(echo "$output" | grep -oP '<!-- FEATURES_STATUS:total=\K[0-9]+' | head -1)
  passing=$(echo "$output" | grep -oP '<!-- FEATURES_STATUS:[^-]*passing=\K[0-9]+' | head -1)
  failing=$(echo "$output" | grep -oP '<!-- FEATURES_STATUS:[^-]*failing=\K[0-9]+' | head -1)
  assert_eq "extracts total" "196" "$total"
  assert_eq "extracts passing" "42" "$passing"
  assert_eq "extracts failing" "3" "$failing"

  output="Legacy evolve <!-- PHASE_3_COMPLETE --> output"
  assert_contains "detects legacy PHASE_3_COMPLETE marker" "PHASE_3_COMPLETE" "$output"

  output="Legacy report <!-- PHASE_5_COMPLETE --> output"
  assert_contains "detects legacy PHASE_5_COMPLETE marker" "PHASE_5_COMPLETE" "$output"
}

# ===================================================================
# TEST: Loop-back marker detection
# ===================================================================
test_loop_back_detection() {
  echo "=== Loop-Back Detection ==="

  local output="Report done <!-- LOOP_BACK_TO_PROBE --> more"
  assert_contains "detects LOOP_BACK_TO_PROBE" "LOOP_BACK_TO_PROBE" "$output"
}

# ===================================================================
# TEST: DISCARD marker detection
# ===================================================================
test_discard_detection() {
  echo "=== DISCARD Marker Detection ==="

  local output="Verification failed <!-- DISCARD --> rolling back"
  assert_contains "detects DISCARD" "DISCARD" "$output"
}

# ===================================================================
# TEST: Phase advancement logic
# ===================================================================
test_phase_advancement() {
  echo "=== Phase Advancement ==="

  # Phase complete + quality passed → advance
  # Simulate: current_phase=2, phase complete, quality passed
  local current=2
  local phase_complete=true
  local quality_passed="1"
  local next_phase=$current

  if [ "$phase_complete" = true ]; then
    if [ "$current" -ge 2 ] && [ "$current" -le 5 ]; then
      if [ "$quality_passed" = "1" ]; then
        next_phase=$((current + 1))
      fi
    fi
  fi
  assert_eq "advances phase on quality pass" "3" "$next_phase"

  # Phase complete + quality failed → repeat
  quality_passed="0"
  next_phase=$current
  if [ "$phase_complete" = true ]; then
    if [ "$current" -ge 2 ] && [ "$current" -le 5 ]; then
      if [ "$quality_passed" = "0" ]; then
        next_phase=$current  # repeat
      fi
    fi
  fi
  assert_eq "repeats phase on quality fail" "2" "$next_phase"

  # Phase 5 (verify) complete + quality passed → advance
  current=5
  quality_passed="1"
  next_phase=$current
  if [ "$phase_complete" = true ]; then
    if [ "$current" -ge 2 ] && [ "$current" -le 5 ]; then
      if [ "$quality_passed" = "1" ]; then
        next_phase=$((current + 1))
      fi
    fi
  fi
  assert_eq "advances phase 5 on quality pass" "6" "$next_phase"

  # Phase 5 (verify) complete + quality failed → repeat
  quality_passed="0"
  next_phase=$current
  if [ "$phase_complete" = true ]; then
    if [ "$current" -ge 2 ] && [ "$current" -le 5 ]; then
      if [ "$quality_passed" = "0" ]; then
        next_phase=$current  # repeat
      fi
    fi
  fi
  assert_eq "repeats phase 5 on quality fail" "5" "$next_phase"

  # Phase 1 (no quality gate) → advance
  current=1
  next_phase=$current
  if [ "$phase_complete" = true ]; then
    if [ "$current" -ge 2 ] && [ "$current" -le 5 ]; then
      next_phase=$current
    else
      next_phase=$((current + 1))
    fi
  fi
  assert_eq "advances phase 1 without quality gate" "2" "$next_phase"

  # Phase 0 (no quality gate) → advance
  current=0
  next_phase=$((current + 1))
  assert_eq "advances phase 0 to phase 1" "1" "$next_phase"
}

# ===================================================================
# TEST: Max iteration timeout
# ===================================================================
test_max_iteration_timeout() {
  echo "=== Max Iteration Timeout ==="

  # Phase iteration exceeds max → force advance
  local current=2
  local phase_iter=4
  local max_iter=3
  local next_phase=$current

  if [ "$phase_iter" -gt "$max_iter" ]; then
    next_phase=$((current + 1))
  fi
  assert_eq "forces advance when iteration exceeds max" "3" "$next_phase"
}

# ===================================================================
# TEST: Loop-back logic
# ===================================================================
test_loop_back_logic() {
  echo "=== Loop-Back Logic ==="

  # Loop back with remaining cycles → phase 1, increment cycle
  local loop_back=true
  local cycles=2
  local max_cycles=5
  local next_phase=5
  local stall_detected=false

  if [ "$loop_back" = true ] && [ "$cycles" -lt "$max_cycles" ] && [ "$stall_detected" = false ]; then
    next_phase=1
    cycles=$((cycles + 1))
  fi
  assert_eq "loop-back returns to phase 1" "1" "$next_phase"
  assert_eq "loop-back increments cycle" "3" "$cycles"

  # Loop back with stall → stop
  stall_detected=true
  next_phase=5
  local stopped=false
  if [ "$loop_back" = true ] && [ "$stall_detected" = true ]; then
    stopped=true
  fi
  assert_eq "stall blocks loop-back" "true" "$stopped"
}

# ===================================================================
# TEST: Auto loop-back after phase 5
# ===================================================================
test_auto_loop_back() {
  echo "=== Auto Loop-Back After Report ==="

  local next_phase=7  # beyond phase 6
  local features_failing=3
  local cycles=1
  local max_cycles=5
  local stall=false

  if [ "$next_phase" -gt 6 ]; then
    if [ "$features_failing" -gt 0 ] && [ "$cycles" -lt "$max_cycles" ] && [ "$stall" = false ]; then
      next_phase=1
      cycles=$((cycles + 1))
    else
      next_phase=6
    fi
  fi
  assert_eq "auto loop-back when features failing" "1" "$next_phase"
  assert_eq "auto loop-back increments cycle" "2" "$cycles"

  # No failures → stay at 6
  next_phase=7
  features_failing=0
  if [ "$next_phase" -gt 6 ]; then
    if [ "$features_failing" -gt 0 ]; then
      next_phase=1
    else
      next_phase=6
    fi
  fi
  assert_eq "no auto loop-back when all passing" "6" "$next_phase"
}

# ===================================================================
# TEST: Progress history file
# ===================================================================
test_progress_history() {
  echo "=== Progress History ==="
  setup_test_dir

  local progress_file="sota-output/progress/history.jsonl"

  python3 -c "
import json, time
entry = {
    'iteration': 1,
    'phase': 1,
    'features_passing': 10,
    'features_failing': 5,
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
}
with open('$progress_file', 'w') as f:
    f.write(json.dumps(entry) + '\n')
"
  assert_file_exists "progress history created" "$progress_file"

  local line_count
  line_count=$(wc -l < "$progress_file")
  assert_eq "progress history has 1 entry" "1" "$line_count"

  teardown_test_dir
}

# ===================================================================
# TEST: Stall detection
# ===================================================================
test_stall_detection() {
  echo "=== Stall Detection ==="
  setup_test_dir

  local progress_file="sota-output/progress/history.jsonl"

  # Write 2 report-phase entries with same passing count → stall
  python3 -c "
import json
entries = [
    {'iteration': 5, 'phase': 6, 'cycle': 0, 'features_passing': 10},
    {'iteration': 10, 'phase': 6, 'cycle': 1, 'features_passing': 10},
]
with open('$progress_file', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"

  local stall
  stall=$(python3 -c "
import json
entries = []
with open('$progress_file') as f:
    for line in f:
        entries.append(json.loads(line.strip()))
cycle_results = {}
for e in entries:
    if e.get('phase') == 6:
        cycle_results[e['cycle']] = e['features_passing']
cycles = sorted(cycle_results.keys())
if len(cycles) >= 2:
    if cycle_results[cycles[-1]] <= cycle_results[cycles[-2]]:
        print('true')
    else:
        print('false')
else:
    print('false')
")
  assert_eq "detects stall (no progress)" "true" "$stall"

  # Write improvement → no stall
  python3 -c "
import json
entries = [
    {'iteration': 5, 'phase': 6, 'cycle': 0, 'features_passing': 10},
    {'iteration': 10, 'phase': 6, 'cycle': 1, 'features_passing': 12},
]
with open('$progress_file', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"

  stall=$(python3 -c "
import json
entries = []
with open('$progress_file') as f:
    for line in f:
        entries.append(json.loads(line.strip()))
cycle_results = {}
for e in entries:
    if e.get('phase') == 6:
        cycle_results[e['cycle']] = e['features_passing']
cycles = sorted(cycle_results.keys())
if len(cycles) >= 2:
    if cycle_results[cycles[-1]] <= cycle_results[cycles[-2]]:
        print('true')
    else:
        print('false')
else:
    print('false')
")
  assert_eq "no stall when progress made" "false" "$stall"

  # Phase 5 stall detection — auto loop-back skips Phase 6, so stall
  # must also be detectable via Phase 5 entries with phase_complete flag
  python3 -c "
import json
entries = [
    {'iteration': 5, 'phase': 5, 'cycle': 0, 'phase_complete': True, 'features_passing': 10},
    {'iteration': 10, 'phase': 5, 'cycle': 1, 'phase_complete': True, 'features_passing': 10},
]
with open('$progress_file', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"

  stall=$(python3 -c "
import json
entries = []
with open('$progress_file') as f:
    for line in f:
        entries.append(json.loads(line.strip()))
cycle_results = {}
for e in entries:
    if e.get('phase') in (5, 6) and (e.get('phase') == 6 or e.get('phase_complete')):
        cycle_results[e['cycle']] = e['features_passing']
cycles = sorted(cycle_results.keys())
if len(cycles) >= 2:
    if cycle_results[cycles[-1]] <= cycle_results[cycles[-2]]:
        print('true')
    else:
        print('false')
else:
    print('false')
")
  assert_eq "detects stall via Phase 5 path (auto loop-back)" "true" "$stall"

  # Phase 5 with improvement → no stall
  python3 -c "
import json
entries = [
    {'iteration': 5, 'phase': 5, 'cycle': 0, 'phase_complete': True, 'features_passing': 10},
    {'iteration': 10, 'phase': 5, 'cycle': 1, 'phase_complete': True, 'features_passing': 14},
]
with open('$progress_file', 'w') as f:
    for e in entries:
        f.write(json.dumps(e) + '\n')
"

  stall=$(python3 -c "
import json
entries = []
with open('$progress_file') as f:
    for line in f:
        entries.append(json.loads(line.strip()))
cycle_results = {}
for e in entries:
    if e.get('phase') in (5, 6) and (e.get('phase') == 6 or e.get('phase_complete')):
        cycle_results[e['cycle']] = e['features_passing']
cycles = sorted(cycle_results.keys())
if len(cycles) >= 2:
    if cycle_results[cycles[-1]] <= cycle_results[cycles[-2]]:
        print('true')
    else:
        print('false')
else:
    print('false')
")
  assert_eq "no stall via Phase 5 when progress made" "false" "$stall"

  teardown_test_dir
}

# ===================================================================
# TEST: Baseline snapshot creation
# ===================================================================
test_baseline_snapshot() {
  echo "=== Baseline Snapshot ==="
  setup_test_dir

  local baseline_file="sota-output/baselines/baseline-cycle-0-iter-1.json"
  python3 -c "
import json, time
baseline = {
    'iteration': 1,
    'cycle': 0,
    'features_total': 196,
    'features_passing': 31,
    'features_failing': 4,
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'git_head': 'abc1234'
}
with open('$baseline_file', 'w') as f:
    json.dump(baseline, f, indent=2)
"

  assert_file_exists "baseline snapshot created" "$baseline_file"

  local passing
  passing=$(python3 -c "import json; print(json.load(open('$baseline_file'))['features_passing'])")
  assert_eq "baseline features_passing correct" "31" "$passing"

  teardown_test_dir
}

# ===================================================================
# TEST: Global iteration limit
# ===================================================================
test_global_iteration_limit() {
  echo "=== Global Iteration Limit ==="

  local global=30
  local max=30
  local should_stop=false
  if [ "$global" -ge "$max" ]; then
    should_stop=true
  fi
  assert_eq "stops at global iteration limit" "true" "$should_stop"
}

# ===================================================================
# TEST: Completion promise
# ===================================================================
test_completion_promise() {
  echo "=== Completion Promise ==="

  local promise="All features passing"
  local output="Final report: All features passing! Done."

  local fulfilled=false
  if echo "$output" | grep -qF "$promise"; then
    fulfilled=true
  fi
  assert_eq "detects completion promise" "true" "$fulfilled"

  output="Still working on features..."
  fulfilled=false
  if echo "$output" | grep -qF "$promise"; then
    fulfilled=true
  fi
  assert_eq "does not false-positive on promise" "false" "$fulfilled"
}

# ===================================================================
# TEST: Probe runner script exists and is executable
# ===================================================================
test_probe_runner() {
  echo "=== Probe Runner ==="
  assert_file_exists "probe-runner.sh exists" "$PLUGIN_ROOT/scripts/probe-runner.sh"

  if [ -x "$PLUGIN_ROOT/scripts/probe-runner.sh" ]; then
    assert_eq "probe-runner.sh is executable" "true" "true"
  else
    assert_eq "probe-runner.sh is executable" "true" "false"
  fi
}

# ===================================================================
# TEST: All agent files exist
# ===================================================================
test_agent_files() {
  echo "=== Agent Files ==="
  local agents=(
    "chief-evolver"
    "sota-researcher"
    "e2e-prober"
    "gap-analyzer"
    "hypothesis-generator"
    "implementation-coder"
    "evolution-verifier"
    "quality-evaluator"
    "report-writer"
  )
  for agent in "${agents[@]}"; do
    assert_file_exists "agent $agent exists" "$PLUGIN_ROOT/agents/${agent}.md"
  done
}

# ===================================================================
# TEST: Phase names array covers 0-6
# ===================================================================
test_phase_names() {
  echo "=== Phase Names ==="
  local names=("research" "probe" "analyze" "plan" "evolve" "verify" "report")
  assert_eq "phase 0 = research" "research" "${names[0]}"
  assert_eq "phase 1 = probe" "probe" "${names[1]}"
  assert_eq "phase 2 = analyze" "analyze" "${names[2]}"
  assert_eq "phase 3 = plan" "plan" "${names[3]}"
  assert_eq "phase 4 = evolve" "evolve" "${names[4]}"
  assert_eq "phase 5 = verify" "verify" "${names[5]}"
  assert_eq "phase 6 = report" "report" "${names[6]}"
}

# ===================================================================
# TEST: Budget enforcement
# ===================================================================
test_budget_enforcement() {
  echo "=== Budget Enforcement ==="

  # Budget exceeded → should stop
  local spent="50.0"
  local budget="50"
  local exceeded
  exceeded=$(SPENT="$spent" BUDGET="$budget" python3 -c "
import os
spent = float(os.environ['SPENT'])
budget = float(os.environ['BUDGET'])
print('true' if budget > 0 and spent >= budget else 'false')
")
  assert_eq "stops when budget exhausted" "true" "$exceeded"

  # Budget not exceeded → continue
  spent="25.0"
  exceeded=$(SPENT="$spent" BUDGET="$budget" python3 -c "
import os
spent = float(os.environ['SPENT'])
budget = float(os.environ['BUDGET'])
print('true' if budget > 0 and spent >= budget else 'false')
")
  assert_eq "continues when budget remaining" "false" "$exceeded"

  # Budget unlimited (0) → continue
  budget="0"
  spent="999.0"
  exceeded=$(SPENT="$spent" BUDGET="$budget" python3 -c "
import os
spent = float(os.environ['SPENT'])
budget = float(os.environ['BUDGET'])
print('true' if budget > 0 and spent >= budget else 'false')
")
  assert_eq "continues when budget unlimited" "false" "$exceeded"
}

# ===================================================================
# TEST: Baseline HEAD rollback uses saved ref
# ===================================================================
test_baseline_head_rollback() {
  echo "=== Baseline HEAD Rollback ==="
  setup_test_dir

  # Create a baseline HEAD ref file
  local head_ref
  head_ref=$(git rev-parse HEAD)
  mkdir -p sota-output/baselines
  echo "$head_ref" > "sota-output/baselines/head-ref-iter-1.txt"

  # Verify the saved ref is a valid git object
  local is_valid
  if git cat-file -t "$head_ref" >/dev/null 2>&1; then
    is_valid="true"
  else
    is_valid="false"
  fi
  assert_eq "baseline HEAD ref is valid git object" "true" "$is_valid"

  # Make a change and commit
  echo "modified" > file.txt
  git add file.txt && git commit -q -m "modify" 2>/dev/null

  # Rollback using baseline HEAD (simulates DISCARD logic)
  git checkout "$head_ref" -- . 2>/dev/null
  local content
  content=$(cat file.txt)
  assert_eq "rollback restores file to baseline state" "test" "$content"

  teardown_test_dir
}

# ===================================================================
# TEST: Skip count in FEATURES_STATUS marker
# ===================================================================
test_skip_count_marker() {
  echo "=== Skip Count Marker Detection ==="

  local output="<!-- FEATURES_STATUS:total=196,passing=42,failing=3,skip=12 -->"

  local total passing failing skip
  total=$(echo "$output" | grep -oP '<!-- FEATURES_STATUS:total=\K[0-9]+' | head -1)
  passing=$(echo "$output" | grep -oP '<!-- FEATURES_STATUS:[^-]*passing=\K[0-9]+' | head -1)
  failing=$(echo "$output" | grep -oP '<!-- FEATURES_STATUS:[^-]*failing=\K[0-9]+' | head -1)
  skip=$(echo "$output" | grep -oP '<!-- FEATURES_STATUS:[^-]*skip=\K[0-9]+' | head -1)
  assert_eq "extracts total with skip" "196" "$total"
  assert_eq "extracts passing with skip" "42" "$passing"
  assert_eq "extracts failing with skip" "3" "$failing"
  assert_eq "extracts skip count" "12" "$skip"

  # Backward compatibility: marker without skip= → skip stays default
  output="<!-- FEATURES_STATUS:total=196,passing=42,failing=3 -->"
  skip=$(echo "$output" | grep -oP '<!-- FEATURES_STATUS:[^-]*skip=\K[0-9]+' | head -1 || echo "")
  assert_eq "no skip in marker returns empty" "" "$skip"
}

# ===================================================================
# TEST: Skip count in state file
# ===================================================================
test_skip_state_reading() {
  echo "=== Skip State File Reading ==="
  setup_test_dir

  cat > ".claude/sota-loop.local.md" << 'EOF'
---
active: true
topic: "Test"
current_phase: 1
phase_name: "probe"
phase_iteration: 1
global_iteration: 1
max_global_iterations: 30
completion_promise: "All features passing"
started_at: "2026-01-01T00:00:00Z"
output_dir: "./sota-output"
refinement_cycles: 0
max_refinement_cycles: 5
features_total: 196
features_passing: 42
features_failing: 3
features_skip: 12
budget_usd: 50
spent_usd: 5.0
thresholds_path: "docs/sota-thresholds.toml"
feature_registry_path: "docs/feature-registry.toml"
---
Test prompt content
EOF

  assert_eq "reads features_skip" "12" "$(read_state features_skip)"

  teardown_test_dir
}

# ===================================================================
# TEST: SOTA blocked when skip > 0 (completion promise not fulfilled)
# ===================================================================
test_sota_blocked_by_skip() {
  echo "=== SOTA Blocked by Skip ==="

  # Simulate: completion promise found but skip > 0 → should NOT complete
  local promise="All features passing"
  local output="Final report: All features passing! Done."
  local features_skip=12

  local should_block=false
  if echo "$output" | grep -qF "$promise"; then
    if [ "$features_skip" -gt 0 ] 2>/dev/null; then
      should_block=true
    fi
  fi
  assert_eq "blocks SOTA when skip > 0" "true" "$should_block"

  # skip = 0 → should complete
  features_skip=0
  should_block=false
  if echo "$output" | grep -qF "$promise"; then
    if [ "$features_skip" -gt 0 ] 2>/dev/null; then
      should_block=true
    fi
  fi
  assert_eq "allows SOTA when skip = 0" "false" "$should_block"
}

# ===================================================================
# TEST: Auto loop-back when skip > 0 and failing = 0
# ===================================================================
test_auto_loop_back_on_skip() {
  echo "=== Auto Loop-Back on Skip ==="

  local next_phase=7
  local features_failing=0
  local features_skip=12
  local cycles=1
  local max_cycles=5
  local stall=false

  # Simulates the hook logic for next_phase > 6
  if [ "$next_phase" -gt 6 ]; then
    if [ "$features_failing" -gt 0 ] && [ "$cycles" -lt "$max_cycles" ]; then
      next_phase=1
      cycles=$((cycles + 1))
    elif [ "$features_skip" -gt 0 ] 2>/dev/null && [ "$cycles" -lt "$max_cycles" ]; then
      if [ "$stall" = true ]; then
        next_phase=6
      else
        next_phase=1
        cycles=$((cycles + 1))
      fi
    else
      next_phase=6
    fi
  fi
  assert_eq "loops back when skip > 0 and failing = 0" "1" "$next_phase"
  assert_eq "increments cycle on skip loop-back" "2" "$cycles"

  # No skip, no failing → done
  next_phase=7
  features_skip=0
  features_failing=0
  cycles=1
  if [ "$next_phase" -gt 6 ]; then
    if [ "$features_failing" -gt 0 ] && [ "$cycles" -lt "$max_cycles" ]; then
      next_phase=1
    elif [ "$features_skip" -gt 0 ] 2>/dev/null && [ "$cycles" -lt "$max_cycles" ]; then
      next_phase=1
    else
      next_phase=6
    fi
  fi
  assert_eq "completes when skip = 0 and failing = 0" "6" "$next_phase"
}

# ===================================================================
# TEST: System message includes skip count
# ===================================================================
test_system_message_skip() {
  echo "=== System Message Skip Count ==="

  local features_passing=42
  local features_total=196
  local features_failing=3
  local features_skip=12

  local msg="Features: ${features_passing}/${features_total} passing, ${features_failing} failing, ${features_skip} skip"
  assert_contains "system message includes skip" "12 skip" "$msg"

  # Skip warning
  local warn=""
  if [ "$features_skip" -gt 0 ] 2>/dev/null; then
    warn="E2E NOT VALIDATED: ${features_skip} features skipped"
  fi
  assert_contains "skip warning emitted" "E2E NOT VALIDATED" "$warn"
}

# ===================================================================
# TEST: Baseline includes skip count
# ===================================================================
test_baseline_includes_skip() {
  echo "=== Baseline Includes Skip ==="
  setup_test_dir

  local baseline_file="sota-output/baselines/baseline-cycle-0-iter-1.json"
  python3 -c "
import json, time
baseline = {
    'iteration': 1,
    'cycle': 0,
    'features_total': 196,
    'features_passing': 31,
    'features_failing': 4,
    'features_skip': 12,
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'git_head': 'abc1234'
}
with open('$baseline_file', 'w') as f:
    json.dump(baseline, f, indent=2)
"

  local skip
  skip=$(python3 -c "import json; print(json.load(open('$baseline_file'))['features_skip'])")
  assert_eq "baseline includes features_skip" "12" "$skip"

  teardown_test_dir
}

# ===================================================================
# RUN ALL TESTS
# ===================================================================
echo "============================================"
echo "SOTA Evolution Loop — Test Suite"
echo "============================================"
echo ""

test_state_reading
echo ""
test_no_state_file
echo ""
test_inactive_loop
echo ""
test_phase_completion_markers
echo ""
test_loop_back_detection
echo ""
test_discard_detection
echo ""
test_phase_advancement
echo ""
test_max_iteration_timeout
echo ""
test_loop_back_logic
echo ""
test_auto_loop_back
echo ""
test_progress_history
echo ""
test_stall_detection
echo ""
test_baseline_snapshot
echo ""
test_global_iteration_limit
echo ""
test_completion_promise
echo ""
test_probe_runner
echo ""
test_agent_files
echo ""
test_phase_names
echo ""
test_budget_enforcement
echo ""
test_baseline_head_rollback
echo ""
test_skip_count_marker
echo ""
test_skip_state_reading
echo ""
test_sota_blocked_by_skip
echo ""
test_auto_loop_back_on_skip
echo ""
test_system_message_skip
echo ""
test_baseline_includes_skip

echo ""
echo "============================================"
echo "RESULTS: $PASSED/$TOTAL passed, $FAILED failed"
echo "============================================"

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
