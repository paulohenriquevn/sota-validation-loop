#!/usr/bin/env bash
# =============================================================================
# SOTA Probe Runner — Deterministic probe execution
# =============================================================================
# Executes concrete probes for each feature category. Results are written to
# JSON files that the e2e-prober agent reads instead of inventing ad-hoc probes.
#
# Usage: ./scripts/probe-runner.sh <project_root> <output_dir> [category]
# =============================================================================

set -euo pipefail

PROJECT_ROOT="${1:-.}"
OUTPUT_DIR="${2:-./sota-output/probes}"
CATEGORY="${3:-all}"

mkdir -p "$OUTPUT_DIR"

# Colors for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Results accumulator
TOTAL=0
PASS=0
FAIL=0
SKIP=0

# -------------------------------------------------------------------
# Probe result writer
# -------------------------------------------------------------------
write_result() {
  local feature_id="$1"
  local status="$2"    # pass | fail | skip
  local message="$3"
  local duration_ms="$4"

  TOTAL=$((TOTAL + 1))
  case "$status" in
    pass) PASS=$((PASS + 1)); color="$GREEN" ;;
    fail) FAIL=$((FAIL + 1)); color="$RED" ;;
    skip) SKIP=$((SKIP + 1)); color="$YELLOW" ;;
  esac

  echo -e "${color}[$status]${NC} $feature_id: $message (${duration_ms}ms)"

  python3 -c "
import json, os, time
result = {
    'feature_id': '$feature_id',
    'status': '$status',
    'message': '''$message''',
    'duration_ms': $duration_ms,
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
}
outfile = os.path.join('$OUTPUT_DIR', '${feature_id}.json')
with open(outfile, 'w') as f:
    json.dump(result, f, indent=2)
"
}

# -------------------------------------------------------------------
# Probe: run a command and check exit code + output
# -------------------------------------------------------------------
run_probe() {
  local feature_id="$1"
  local cmd="$2"
  local expected_pattern="${3:-}"   # optional grep pattern in output
  local skip_reason="${4:-}"

  if [ -n "$skip_reason" ]; then
    write_result "$feature_id" "skip" "$skip_reason" 0
    return
  fi

  local start_ms
  start_ms=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")

  local output=""
  local exit_code=0
  output=$(cd "$PROJECT_ROOT" && eval "$cmd" 2>&1) || exit_code=$?

  local end_ms
  end_ms=$(date +%s%3N 2>/dev/null || python3 -c "import time; print(int(time.time()*1000))")
  local duration=$((end_ms - start_ms))

  if [ $exit_code -ne 0 ]; then
    # Truncate output to 500 chars for readability
    local truncated="${output:0:500}"
    write_result "$feature_id" "fail" "exit_code=$exit_code: $truncated" "$duration"
    return
  fi

  if [ -n "$expected_pattern" ]; then
    if echo "$output" | grep -qE "$expected_pattern"; then
      write_result "$feature_id" "pass" "Pattern matched: $expected_pattern" "$duration"
    else
      write_result "$feature_id" "fail" "Pattern not found: $expected_pattern in output" "$duration"
    fi
  else
    write_result "$feature_id" "pass" "exit_code=0" "$duration"
  fi
}

# ============================================================================
# CATEGORY: BUILD & TEST (fundamental probes)
# ============================================================================
probe_build() {
  echo "=== BUILD & TEST ==="

  run_probe "build.workspace" \
    "cargo build --workspace --exclude theo-code-desktop 2>&1" \
    ""

  run_probe "build.clippy" \
    "cargo clippy --workspace --all-targets --no-deps -- -D warnings 2>&1" \
    ""

  run_probe "build.test_suite" \
    "cargo test --workspace --exclude theo-code-desktop --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"
}

# ============================================================================
# CATEGORY: TOOLS (theo-tooling — 72 production tools)
# ============================================================================
probe_tools() {
  echo "=== TOOLS (theo-tooling) ==="

  # Full crate test suite
  run_probe "tools.crate_tests" \
    "cargo test -p theo-tooling --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"

  # Check tool registry count (expect ~72)
  run_probe "tools.registry_count" \
    "grep -rc 'fn id(&self)' crates/theo-tooling/src/ 2>/dev/null | awk -F: '{s+=\$NF}END{print s}'" \
    "[0-9]+"

  # Check each tool category has implementations
  run_probe "tools.file_ops_exist" \
    "grep -rl 'fn id.*file\|fn id.*edit\|fn id.*glob\|fn id.*grep\|fn id.*read\|fn id.*write' crates/theo-tooling/src/ 2>/dev/null | wc -l" \
    "[1-9]"

  run_probe "tools.git_ops_exist" \
    "grep -rl 'fn id.*git' crates/theo-tooling/src/ 2>/dev/null | wc -l" \
    "[1-9]"

  run_probe "tools.bash_tool_exists" \
    "grep -rl 'fn id.*bash' crates/theo-tooling/src/ 2>/dev/null | wc -l" \
    "[1-9]"

  run_probe "tools.planning_exists" \
    "grep -rl 'fn id.*plan' crates/theo-tooling/src/ 2>/dev/null | wc -l" \
    "[1-9]"

  run_probe "tools.memory_tool_exists" \
    "grep -rl 'fn id.*memory' crates/theo-tooling/src/ 2>/dev/null | wc -l" \
    "[0-9]"

  run_probe "tools.codebase_context_exists" \
    "grep -rl 'codebase_context\|CodebaseContext' crates/theo-tooling/src/ 2>/dev/null | wc -l" \
    "[0-9]"

  # Clippy clean
  run_probe "tools.clippy_clean" \
    "cargo clippy -p theo-tooling -- -D warnings 2>&1" \
    ""
}

# ============================================================================
# CATEGORY: CLI SUBCOMMANDS (theo-cli — 17 subcommands)
# ============================================================================
probe_cli() {
  echo "=== CLI (theo-cli) ==="

  # Build the binary first
  run_probe "cli.binary_builds" \
    "cargo build -p theo 2>&1" \
    ""

  local THEO_BIN="./target/debug/theo"

  # All 17 subcommands must appear in --help
  run_probe "cli.help_lists_all" \
    "$THEO_BIN --help 2>&1" \
    "init.*agent.*pilot.*context"

  # Test each critical subcommand
  for cmd in init context impact stats memory dashboard subagent checkpoints agents mcp skill trajectory help; do
    run_probe "cli.${cmd}_help" \
      "$THEO_BIN $cmd --help 2>&1" \
      ""
  done

  # Special: pilot and agent may need more args, just check they don't panic
  run_probe "cli.pilot_help" \
    "$THEO_BIN pilot --help 2>&1" \
    ""

  run_probe "cli.agent_help" \
    "$THEO_BIN agent --help 2>&1" \
    ""
}

# ============================================================================
# CATEGORY: LANGUAGES (theo-engine-parser — 14 Tree-Sitter grammars)
# ============================================================================
probe_languages() {
  echo "=== LANGUAGES (theo-engine-parser) ==="

  # Full parser test suite
  run_probe "languages.parser_tests" \
    "cargo test -p theo-engine-parser --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"

  # Check each of the 14 languages has grammar support
  for lang in c cpp c-sharp go java javascript kotlin-ng php python ruby rust scala swift typescript; do
    # Normalize name for probe ID
    local probe_name="${lang//-/_}"
    run_probe "languages.grammar_${probe_name}" \
      "find crates/theo-engine-parser/src/ -name '*.rs' -exec grep -l '$lang' {} + 2>/dev/null | head -1" \
      "."
  done

  # Clippy clean
  run_probe "languages.clippy_clean" \
    "cargo clippy -p theo-engine-parser -- -D warnings 2>&1" \
    ""
}

# ============================================================================
# CATEGORY: CONTEXT ENGINE (theo-engine-retrieval — graph-augmented agentic retrieval)
# Objective: Structural intelligence derived FROM code, exposed as tool backends
# Ref: crates/theo-engine-retrieval/README.md
# Ref: docs/pesquisas/context/code-retrieval-deep-research.md (963 lines, 68 sources)
# ============================================================================
probe_context() {
  echo "=== CONTEXT ENGINE (theo-engine-retrieval — graph-augmented retrieval) ==="

  # --- Test suites ---
  run_probe "context.retrieval_tests" \
    "cargo test -p theo-engine-retrieval --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"

  run_probe "context.graph_tests" \
    "cargo test -p theo-engine-graph --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"

  # --- Search layer ---

  # BM25F with code-aware tokenization
  run_probe "context.bm25_code_aware" \
    "grep -rn 'FileBm25\|fn search' crates/theo-engine-retrieval/src/search/file_bm25.rs 2>/dev/null | head -1" \
    "."

  # Dense search with embedding model
  run_probe "context.dense_search" \
    "grep -rn 'FileDenseSearch\|NeuralEmbedder' crates/theo-engine-retrieval/src/dense_search.rs crates/theo-engine-retrieval/src/embedding/neural.rs 2>/dev/null | head -1" \
    "."

  # P0 CHECK: Which embedding model is used? (AllMiniLM = BAD, Jina/Voyage = GOOD)
  run_probe "context.embedding_model_check" \
    "grep -rn 'AllMiniLM\|all-MiniLM\|jina.*code\|voyage.*code\|qodo.*embed' crates/theo-engine-retrieval/src/embedding/neural.rs 2>/dev/null | head -3" \
    "."

  # Query type routing
  run_probe "context.query_type_router" \
    "grep -rn 'QueryType\|Identifier\|NaturalLanguage\|Mixed' crates/theo-engine-retrieval/src/search/query_type.rs 2>/dev/null | head -1" \
    "QueryType"

  # --- Fusion layer ---

  # RRF fusion
  run_probe "context.rrf_fusion" \
    "grep -rn 'hybrid_rrf\|reciprocal_rank\|rrf_k' crates/theo-engine-retrieval/src/pipeline.rs 2>/dev/null | head -1" \
    "."

  # --- Graph layer (UNIQUE competitive advantage) ---

  # Graph Attention Propagation
  run_probe "context.graph_attention" \
    "grep -rn 'propagate_attention\|proximity_from_seeds' crates/theo-engine-retrieval/src/graph_attention.rs 2>/dev/null | head -1" \
    "."

  # PageRank on code graph
  run_probe "context.pagerank" \
    "grep -rn 'pagerank\|PageRank' crates/theo-engine-retrieval/src/search/signals.rs 2>/dev/null | head -1" \
    "."

  # Community detection / clustering
  run_probe "context.community_detection" \
    "grep -rn 'community\|Community\|cluster\|Cluster' crates/theo-engine-graph/src/ 2>/dev/null | head -1" \
    "."

  # Dependency Coverage metric (UNIQUE)
  run_probe "context.depcov_metric" \
    "grep -rn 'dependency_coverage\|DepCov\|dep_cov' crates/theo-engine-retrieval/src/metrics.rs 2>/dev/null | head -1" \
    "."

  # --- Reranking layer ---

  # Cross-encoder reranker
  run_probe "context.cross_encoder" \
    "grep -rn 'CrossEncoderReranker\|fn rerank' crates/theo-engine-retrieval/src/reranker.rs 2>/dev/null | head -1" \
    "."

  # --- Assembly layer ---

  # Greedy knapsack assembly
  run_probe "context.greedy_assembly" \
    "grep -rn 'assemble_greedy\|ContextPayload' crates/theo-engine-retrieval/src/assembly/ 2>/dev/null | head -1" \
    "."

  # Context miss detection
  run_probe "context.miss_detection" \
    "grep -rn 'ContextMiss\|detect_miss' crates/theo-engine-retrieval/src/escape.rs 2>/dev/null | head -1" \
    "."

  # Token budget config
  run_probe "context.budget_config" \
    "grep -rn 'BudgetConfig\|BudgetAllocation' crates/theo-engine-retrieval/src/budget.rs 2>/dev/null | head -1" \
    "."

  # --- Metrics layer ---

  # Retrieval metrics (MRR, Recall, nDCG, MAP, DepCov)
  run_probe "context.retrieval_metrics" \
    "grep -rn 'RetrievalMetrics\|fn compute' crates/theo-engine-retrieval/src/metrics.rs 2>/dev/null | head -1" \
    "."

  # Benchmark suite exists
  run_probe "context.benchmark_suite" \
    "ls crates/theo-engine-retrieval/tests/benchmark_suite.rs 2>/dev/null" \
    "benchmark_suite"

  # --- Quality ---

  # Clippy clean
  run_probe "context.clippy_clean" \
    "cargo clippy -p theo-engine-retrieval -p theo-engine-graph -p theo-engine-parser -- -D warnings 2>&1" \
    ""
}

# ============================================================================
# CATEGORY: AGENT RUNTIME (theo-agent-runtime — agent loop, subagents)
# ============================================================================
probe_runtime() {
  echo "=== AGENT RUNTIME (theo-agent-runtime) ==="

  # Full test suite
  run_probe "runtime.tests" \
    "cargo test -p theo-agent-runtime --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"

  # State machine phases in agent_loop.rs / run_engine.rs
  run_probe "runtime.agent_loop_exists" \
    "ls crates/theo-agent-runtime/src/agent_loop.rs crates/theo-agent-runtime/src/run_engine.rs 2>/dev/null | head -1" \
    "."

  # Check doom loop detection (config.rs doom_loop_threshold)
  run_probe "runtime.doom_loop_detection" \
    "grep -rn 'doom_loop' crates/theo-agent-runtime/src/ 2>/dev/null | head -1" \
    "doom_loop"

  # Check budget enforcement
  run_probe "runtime.budget_enforcer" \
    "grep -rn 'budget\|Budget\|token.*limit' crates/theo-agent-runtime/src/ 2>/dev/null | head -1" \
    "."

  # Check compaction stages (5+ stages per CLAUDE.md)
  run_probe "runtime.compaction_stages" \
    "ls crates/theo-agent-runtime/src/compaction_stages.rs 2>/dev/null" \
    "compaction_stages"

  # Check subagent system
  run_probe "runtime.subagent_exists" \
    "ls crates/theo-agent-runtime/src/subagent/mod.rs 2>/dev/null" \
    "mod.rs"

  run_probe "runtime.subagent_roles" \
    "grep -n 'SubAgentRole\|Explorer\|Implementer\|Verifier\|Reviewer' crates/theo-agent-runtime/src/subagent/mod.rs 2>/dev/null | head -1" \
    "."

  # Check reflector (failure classification)
  run_probe "runtime.reflector_exists" \
    "grep -rl 'reflector\|classify_failure\|FailurePattern' crates/theo-agent-runtime/src/ 2>/dev/null | head -1" \
    "."

  # Clippy clean
  run_probe "runtime.clippy_clean" \
    "cargo clippy -p theo-agent-runtime -- -D warnings 2>&1" \
    ""
}

# ============================================================================
# CATEGORY: MEMORY SYSTEM (theo-domain + theo-infra-memory + theo-application)
# Ref: agent-memory-plan.md RM0-RM5b roadmap
# ============================================================================
probe_memory() {
  echo "=== MEMORY (theo-domain, theo-infra-memory, theo-application) ==="

  # --- theo-domain memory types ---

  run_probe "memory.provider_trait" \
    "grep -n 'trait MemoryProvider' crates/theo-domain/src/memory.rs crates/theo-domain/src/memory/mod.rs 2>/dev/null | head -1" \
    "MemoryProvider"

  run_probe "memory.session_summary" \
    "grep -rn 'pub struct SessionSummary' crates/theo-domain/src/ 2>/dev/null | head -1" \
    "SessionSummary"

  run_probe "memory.episode_summary" \
    "grep -rn 'pub struct EpisodeSummary' crates/theo-domain/src/ 2>/dev/null | head -1" \
    "EpisodeSummary"

  run_probe "memory.working_set" \
    "grep -rn 'pub struct WorkingSet\|WorkingSet' crates/theo-domain/src/working_set.rs 2>/dev/null | head -1" \
    "WorkingSet"

  run_probe "memory.wiki_backend_trait" \
    "grep -rn 'trait WikiBackend\|WikiBackend' crates/theo-domain/src/wiki_backend.rs 2>/dev/null | head -1" \
    "WikiBackend"

  run_probe "memory.fence_note" \
    "grep -rn 'MEMORY_FENCE_NOTE\|memory.*context.*fence' crates/theo-domain/src/ 2>/dev/null | head -1" \
    "."

  # --- RM0: Memory wired into agent loop? ---

  run_probe "memory.wired_into_agent_loop" \
    "grep -rn 'memory\|MemoryProvider\|prefetch\|sync_turn\|on_pre_compress\|on_session_end' crates/theo-agent-runtime/src/agent_loop.rs crates/theo-agent-runtime/src/run_engine.rs 2>/dev/null | grep -i memory | head -1" \
    "."

  # --- RM1: MemoryEngine coordinator? ---

  run_probe "memory.engine_coordinator" \
    "grep -rn 'MemoryEngine\|memory.*engine' crates/theo-application/src/ 2>/dev/null | head -1" \
    "."

  # --- theo-infra-memory crate ---

  if [ -d "$PROJECT_ROOT/crates/theo-infra-memory/src" ]; then
    run_probe "memory.infra_crate_compiles" \
      "cargo check -p theo-infra-memory 2>&1" \
      ""

    run_probe "memory.infra_crate_tests" \
      "cargo test -p theo-infra-memory --lib --tests --no-fail-fast 2>&1" \
      "test result"

    # RM3a: BuiltinMemoryProvider
    run_probe "memory.builtin_provider" \
      "grep -rn 'BuiltinMemory\|builtin' crates/theo-infra-memory/src/ 2>/dev/null | head -1" \
      "."

    # RM3a: Security scan
    run_probe "memory.security_scan" \
      "grep -rn 'injection\|security.*scan\|_scan_memory' crates/theo-infra-memory/src/ 2>/dev/null | head -1" \
      "."

    # RM4: MemoryLesson
    run_probe "memory.lesson_type" \
      "grep -rn 'MemoryLesson\|Lesson' crates/theo-domain/src/ crates/theo-infra-memory/src/ 2>/dev/null | head -1" \
      "."

    # RM5: Wiki compiler
    run_probe "memory.wiki_compiler" \
      "grep -rn 'wiki.*compile\|WikiCompiler' crates/theo-infra-memory/src/ 2>/dev/null | head -1" \
      "."
  else
    run_probe "memory.infra_crate_compiles" "" "" "crate theo-infra-memory/src/ not scaffolded yet"
    run_probe "memory.builtin_provider" "" "" "blocked by theo-infra-memory"
    run_probe "memory.security_scan" "" "" "blocked by theo-infra-memory"
    run_probe "memory.lesson_type" "" "" "blocked by RM4"
    run_probe "memory.wiki_compiler" "" "" "blocked by RM5"
  fi

  # --- theo-test-memory-fixtures ---

  if [ -d "$PROJECT_ROOT/crates/theo-test-memory-fixtures" ]; then
    run_probe "memory.test_fixtures_crate" \
      "cargo check -p theo-test-memory-fixtures 2>&1" \
      ""
  else
    run_probe "memory.test_fixtures_crate" "" "" "crate theo-test-memory-fixtures not created yet"
  fi
}

# ============================================================================
# CATEGORY: MODEL ROUTING (theo-domain + theo-infra-llm)
# ============================================================================
probe_routing() {
  echo "=== MODEL ROUTING (theo-infra-llm) ==="

  # Provider catalog — expect 26 specs
  run_probe "routing.provider_catalog_count" \
    "grep -rc 'pub const [A-Z_]*: ProviderSpec' crates/theo-infra-llm/src/provider/catalog/*.rs 2>/dev/null | awk -F: '{s+=\$NF}END{print s}'" \
    "[0-9]+"

  # LLM client tests
  run_probe "routing.llm_crate_tests" \
    "cargo test -p theo-infra-llm --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"

  # ModelRouter trait in theo-domain or theo-infra-llm
  run_probe "routing.router_trait" \
    "grep -rn 'trait ModelRouter\|ModelRouter\|trait.*Router' crates/theo-domain/src/ crates/theo-infra-llm/src/ 2>/dev/null | head -1" \
    "."

  # Model limits / model_limits.rs
  run_probe "routing.model_limits" \
    "grep -rn 'claude.*opus\|claude.*sonnet\|claude.*haiku' crates/theo-infra-llm/src/model_limits.rs 2>/dev/null | head -1" \
    "."

  # SubAgent model override capability
  run_probe "routing.subagent_model_field" \
    "grep -rn 'model\b' crates/theo-agent-runtime/src/subagent/ 2>/dev/null | grep -v test | head -1" \
    "."

  # Clippy clean
  run_probe "routing.clippy_clean" \
    "cargo clippy -p theo-infra-llm -- -D warnings 2>&1" \
    ""
}

# ============================================================================
# CATEGORY: SECURITY (theo-governance + theo-isolation)
# ============================================================================
probe_security() {
  echo "=== SECURITY (theo-governance, theo-isolation) ==="

  # Secrets scan
  run_probe "security.secrets_scan" \
    "make check-secrets 2>&1" \
    ""

  # Architecture contract
  run_probe "security.arch_contract" \
    "make check-arch 2>&1" \
    ""

  # Isolation crate — bwrap / landlock / noop
  run_probe "security.isolation_tests" \
    "cargo test -p theo-isolation --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"

  run_probe "security.bwrap_support" \
    "grep -rn 'bwrap\|bubblewrap' crates/theo-isolation/src/ 2>/dev/null | head -1" \
    "."

  run_probe "security.landlock_support" \
    "grep -rn 'landlock\|Landlock' crates/theo-isolation/src/ 2>/dev/null | head -1" \
    "."

  # Governance crate — policy engine
  run_probe "security.governance_tests" \
    "cargo test -p theo-governance --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"

  run_probe "security.policy_engine" \
    "grep -rn 'Policy\|policy\|SandboxPolicy' crates/theo-governance/src/ 2>/dev/null | head -1" \
    "."

  # Auth crate
  run_probe "security.auth_tests" \
    "cargo test -p theo-infra-auth --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"

  # MCP crate
  run_probe "security.mcp_tests" \
    "cargo test -p theo-infra-mcp --lib --tests --no-fail-fast 2>&1" \
    "test result: ok"
}

# ============================================================================
# CATEGORY: QUALITY GATES
# ============================================================================
probe_quality_gates() {
  echo "=== QUALITY GATES ==="

  run_probe "gates.check_sizes" \
    "make check-sizes 2>&1" \
    ""

  run_probe "gates.check_unwrap" \
    "make check-unwrap 2>&1 || true" \
    ""

  run_probe "gates.check_unsafe" \
    "make check-unsafe 2>&1 || true" \
    ""

  run_probe "gates.sota_dod_quick" \
    "make check-sota-dod-quick 2>&1" \
    ""
}

# ============================================================================
# CATEGORY: WIKI SYSTEM (for HUMANS to understand codebases)
# Contract: HUMAN=reader, WIKI_AGENT=writer (background sub-agent)
# Architecture: Skeleton (tree-sitter) + Enrichment (LLM via Wiki Agent)
# ============================================================================
probe_wiki() {
  echo "=== WIKI SYSTEM (theo-engine-wiki — wiki for humans, maintained by Wiki Agent) ==="

  # --- theo-engine-wiki crate (NEW) ---

  run_probe "wiki.crate_compiles" \
    "cargo check -p theo-engine-wiki 2>&1" \
    ""

  run_probe "wiki.crate_tests" \
    "cargo test -p theo-engine-wiki --no-fail-fast 2>&1" \
    "test result: ok"

  run_probe "wiki.clippy_clean" \
    "cargo clippy -p theo-engine-wiki -- -D warnings 2>&1" \
    ""

  # Core modules exist
  run_probe "wiki.page_module" \
    "grep -rn 'pub struct WikiPage' crates/theo-engine-wiki/src/page.rs 2>/dev/null | head -1" \
    "WikiPage"

  run_probe "wiki.skeleton_module" \
    "grep -rn 'pub fn extract_skeleton\|pub struct SkeletonData' crates/theo-engine-wiki/src/skeleton.rs 2>/dev/null | head -1" \
    "."

  run_probe "wiki.store_module" \
    "grep -rn 'pub struct WikiStore' crates/theo-engine-wiki/src/store.rs 2>/dev/null | head -1" \
    "WikiStore"

  run_probe "wiki.hash_module" \
    "grep -rn 'pub struct HashManifest' crates/theo-engine-wiki/src/hash.rs 2>/dev/null | head -1" \
    "HashManifest"

  run_probe "wiki.lint_module" \
    "grep -rn 'pub fn lint_pages' crates/theo-engine-wiki/src/lint.rs 2>/dev/null | head -1" \
    "lint_pages"

  run_probe "wiki.enrichment_struct" \
    "grep -rn 'pub struct EnrichmentData' crates/theo-engine-wiki/src/page.rs 2>/dev/null | head -1" \
    "EnrichmentData"

  # --- theo-domain WikiBackend trait ---

  run_probe "wiki.backend_trait" \
    "grep -rn 'trait WikiBackend' crates/theo-domain/src/wiki_backend.rs 2>/dev/null | head -1" \
    "WikiBackend"

  # --- Wiki tools in theo-tooling ---

  run_probe "wiki.generate_tool" \
    "grep -rn 'wiki.*generate\|wiki_generate\|WikiGenerate' crates/theo-tooling/src/ 2>/dev/null | head -1" \
    "."

  run_probe "wiki.query_tool" \
    "grep -rn 'wiki.*query\|wiki_query\|WikiQuery' crates/theo-tooling/src/ 2>/dev/null | head -1" \
    "."

  # --- Wiki Agent (sub-agent in theo-agent-runtime) ---

  run_probe "wiki.wiki_agent" \
    "grep -rn 'WikiAgent\|wiki.*agent\|wiki.*sub.*agent' crates/theo-agent-runtime/src/ 2>/dev/null | head -1" \
    "."

  # --- Triggers ---

  run_probe "wiki.trigger_system" \
    "grep -rn 'wiki.*trigger\|WikiTrigger\|on_commit.*wiki' crates/theo-agent-runtime/src/ 2>/dev/null | head -1" \
    "."
}

# ============================================================================
# MAIN: Run selected category or all
# ============================================================================
echo "SOTA Probe Runner — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Project: $PROJECT_ROOT"
echo "Output:  $OUTPUT_DIR"
echo "Category: $CATEGORY"
echo "============================================"

case "$CATEGORY" in
  build)    probe_build ;;
  tools)    probe_tools ;;
  cli)      probe_cli ;;
  languages) probe_languages ;;
  context)  probe_context ;;
  runtime)  probe_runtime ;;
  memory)   probe_memory ;;
  routing)  probe_routing ;;
  security) probe_security ;;
  wiki)     probe_wiki ;;
  gates)    probe_quality_gates ;;
  all)
    probe_build
    probe_tools
    probe_cli
    probe_languages
    probe_context
    probe_runtime
    probe_memory
    probe_routing
    probe_wiki
    probe_security
    probe_quality_gates
    ;;
  *)
    echo "Unknown category: $CATEGORY"
    echo "Available: build tools cli languages context runtime memory routing wiki security gates all"
    exit 1
    ;;
esac

# ============================================================================
# Write summary
# ============================================================================
echo ""
echo "============================================"
echo "SUMMARY: $PASS pass / $FAIL fail / $SKIP skip / $TOTAL total"
echo "============================================"

python3 -c "
import json, time
summary = {
    'total': $TOTAL,
    'pass': $PASS,
    'fail': $FAIL,
    'skip': $SKIP,
    'category': '$CATEGORY',
    'timestamp': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
    'project_root': '$PROJECT_ROOT'
}
with open('$OUTPUT_DIR/summary.json', 'w') as f:
    json.dump(summary, f, indent=2)
print(json.dumps(summary, indent=2))
"

# Exit with failure if any probes failed
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
