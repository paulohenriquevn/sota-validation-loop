# SOTA Evolution Loop

Autonomous Claude Code plugin that evolves ALL features of a project toward
evidence-based SOTA thresholds. Researches current state-of-the-art, implements
improvements with TDD (RED/GREEN), tests on the real system with OAuth, and
iterates with keep/discard pattern until SOTA.

## Install

```bash
claude install /path/to/sota-evolution-loop
# or
claude install paulohenriquevn/sota-evolution-loop
```

## Prerequisites

Your project needs two TOML files:

1. **`docs/sota-thresholds.toml`** — DOD-gates with floors and research citations
2. **`docs/feature-registry.toml`** — Every feature mapped to a probe + pass/fail threshold

## Quick Start

```bash
# Start the autonomous evolution loop
/sota-loop --max-cycles 3 --budget 20

# Check status at any time
/sota-status

# Cancel if needed
/sota-cancel
```

## How It Works

```
┌──────────┐  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌──────────┐  ┌─────────┐
│ Phase 0   │─▶│ Phase 1  │─▶│ Phase 2  │─▶│ Phase 3  │─▶│ Phase 4   │─▶│ Phase 5  │
│ RESEARCH  │  │ PROBE    │  │ ANALYZE  │  │ REFINE   │  │ VERIFY    │  │ REPORT   │
│ Deep SOTA │  │ Run E2E  │  │ Find gap │  │ Fix it   │  │ Keep or   │  │ Summary  │
│ research  │  │ probes   │  │ root     │  │ with TDD │  │ discard   │  │          │
└──────────┘  └─────────┘  │ cause    │  │          │  └──────────┘  └─────────┘
                    ▲        └─────────┘  └─────────┘       │
                    │                                        │
                    └──── LOOP BACK (if features still fail) ┘
```

Each phase has:
- **Quality gates** (score >= 0.7 to advance, phases 2-4)
- **Hard blocks** (evidence required)
- **Max iterations** (timeout advances to next phase)
- **Deterministic probes** (probe scripts, not ad-hoc LLM checks)
- **Deterministic rollback** (git-based, not LLM-dependent)

## Key Features

### Deep Research (Phase 0)
- Audits all thresholds for staleness (> 90 days)
- Researches current SOTA per feature category
- Updates thresholds with fresh evidence and citations
- Discovers new SOTA capabilities not yet in the registry

### Deterministic Probes
Concrete probe scripts in `scripts/probe-runner.sh` test:
- Build & test (cargo build, test, clippy)
- Tools (tool registry, file ops, git ops, bash, planning)
- CLI subcommands (help, init, context, memory, stats)
- Languages (Tree-Sitter grammar existence for 14 langs)
- Context engine (retrieval tests, RRF fusion, tantivy)
- Agent runtime (state machine, doom loop, budget, compaction)
- Memory system (provider trait, types, wiring, wiki backend)
- Model routing (router trait, provider catalog)
- Security (secrets scan, arch contract, sandbox, governance)
- Quality gates (sizes, unwrap, unsafe, SOTA DOD)

### Deterministic Rollback
- Baseline snapshots saved as JSON before each fix
- DISCARD marker triggers `git checkout -- .` via the hook
- No reliance on LLM to manually revert files

### Progress Tracking & Stall Detection
- Every iteration logged to `{output_dir}/progress/history.jsonl`
- Stall detection: no progress for 2 consecutive cycles → auto-stop
- Before/after comparison uses persisted baselines, not LLM memory

## Architecture

```
sota-evolution-loop/
├── hooks/
│   ├── hooks.json           # Stop hook registration
│   └── stop-hook.sh         # Autonomous loop engine (v2)
├── commands/
│   ├── sota-loop.md         # /sota-loop — start the loop
│   ├── sota-status.md       # /sota-status — view progress
│   ├── sota-cancel.md       # /sota-cancel — stop the loop
│   └── help.md              # /help — explain the system
├── agents/
│   ├── chief-evolver.md     # Orchestrator — meetings, strategy
│   ├── sota-researcher.md   # Phase 0 — deep SOTA research
│   ├── e2e-prober.md        # Phase 1 — run deterministic probes
│   ├── gap-analyzer.md      # Phase 2 — weighted scoring algorithm
│   ├── hypothesis-generator.md  # Phase 3 — validated hypothesis
│   ├── implementation-coder.md  # Phase 3 — apply fix with TDD
│   ├── evolution-verifier.md # Phase 4 — baseline comparison + DISCARD
│   ├── quality-evaluator.md # Gates — score phases with verification
│   └── report-writer.md     # Phase 5 — final report
├── templates/
│   └── sota-prompt.md       # Main autonomous agent prompt
├── scripts/
│   ├── setup-sota-loop.sh   # Initialization script
│   └── probe-runner.sh      # Deterministic probe execution
├── tests/
│   └── test-hook-logic.sh   # 53 tests for hook logic
└── README.md
```

## Evidence Base

Based on research from:
- **Tsinghua ablation study**: Self-evolution loop +4.8 SWE-Bench (only consistently beneficial module)
- **Stanford harness engineering**: 6x performance from harness alone
- **Stanford Meta-Harness**: Rank 1 with Haiku on Terminal Bench 2 (76.4%)
- **Anthropic long-running agents**: Planner→Generator→Evaluator pattern
- **Karpathy autoresearch**: Keep/discard pattern for quality iteration
- **CoALA (TMLR 2024)**: 6-type memory taxonomy
- **MemGPT/Letta**: Virtual context management, paging tool calls
- **Mem0**: 91.6 LoCoMo score, production memory
- **Zep/Graphiti**: 94.8 DMR benchmark, temporal knowledge graph

Key anti-patterns avoided:
- Verifiers as separate agents (-0.8 to -8.4 points)
- Multi-candidate search (-2.4 points)
- 16-agent swarms (no evidence of benefit beyond 4-5 agents)

## Output Structure

```
sota-output/
├── research/          # Phase 0 research reports
├── probes/            # Deterministic probe JSON results
│   ├── summary.json   # Overall pass/fail/skip counts
│   └── *.json         # Per-feature probe results
├── analysis/          # Phase 2 gap analysis reports
├── baselines/         # Pre-fix snapshots for comparison
│   ├── baseline-*.json
│   └── stash-ref-*.txt
├── progress/
│   └── history.jsonl  # Every iteration logged
└── report/
    └── sota-evolution-report.md
```

## Configuration

The stop-hook reads configuration from `.claude/sota-loop.local.md`:

| Parameter | Default | Description |
|-----------|---------|-------------|
| max_refinement_cycles | 500 | Max times the loop restarts |
| max_global_iterations | 10000 | Hard iteration cap |
| budget_usd | 0 (unlimited) | Hard cost cap |
| quality_threshold | 0.7 | Min score to advance phase |

## Tests

```bash
bash tests/test-hook-logic.sh
# 53/53 tests: state reading, markers, advancement, loop-back,
# stall detection, baselines, rollback, completion promise
```

## License

MIT
