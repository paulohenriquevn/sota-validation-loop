---
name: help
description: Explain SOTA evolution loop and available commands
user-invocable: true
allowed-tools: Read
---

# SOTA Evolution Loop — Help

## What It Does

Autonomous loop that **evolves** the system until ALL features reach SOTA
thresholds. It writes real production code (Rust,
tests, modules) to close every gap. Feature by feature, crate by crate.

**The target is SOTA. "Working" is not enough.**

## 6-Phase Evolution Cycle

```
Phase 0: RESEARCH  → Read docs/pesquisas/, consult domain architects, 95% confidence
Phase 1: PROBE     → Run deterministic probes against ALL features
Phase 2: ANALYZE   → Weighted scoring, root cause at file:line, consult domain architect
Phase 2.5: PLAN    → Evolution plan with tasks, acceptance criteria, DoDs, edge cases
Phase 3: EVOLVE    → Execute plan: read SOTA research + reference repos → TDD fix
Phase 4: VERIFY    → Compare before/after → KEEP or DISCARD (git rollback)
Phase 5: REPORT    → Progress report → LOOP BACK if features still failing

Loop-back: features failing → return to Phase 1 → next worst feature
Stop: ALL DOD-gates pass | stall (2 cycles, 0 progress) | budget exhausted
```

## Commands

| Command | Description |
|---------|-------------|
| `/sota-loop` | Start the evolution loop |
| `/sota-status` | View current phase, features, budget |
| `/sota-cancel` | Cancel the loop (preserves output) |
| `/help` | This help text |

## Options

```
/sota-loop [OPTIONS]
  --thresholds PATH      Path to TOML thresholds (default: docs/sota-thresholds.toml)
  --registry PATH        Path to feature registry (default: docs/feature-registry.toml)
  --max-cycles N         Max refinement cycles (default: 500)
  --max-iterations N     Hard iteration cap (default: 10000)
  --budget N             Max USD budget (default: unlimited)
  --completion-done TEXT  Promise text that terminates the loop
```

## How It Evolves

| Step | What happens |
|------|-------------|
| Gap found | Consults domain architect + reads `docs/pesquisas/<domain>/` |
| Fix proposed | Grounded in SOTA research + reference repo patterns |
| Code written | Real Rust production code with TDD (RED→GREEN→REFACTOR) |
| Code verified | `cargo test` + `cargo clippy` + `make check-arch` + `make check-unwrap` |
| Regression? | Deterministic rollback via `git checkout -- .` |
| Feature passes? | Next worst feature. Loop continues. |

## Resources Used

### 17 Domain Architects (`.claude/agents/*-architect`)
Each monitors SOTA alignment for its domain. The loop consults the relevant
architect before every fix: agent-loop, subagents, context, memory, providers,
model-routing, tools, wiki, CLI, debug, languages, security-governance,
observability, prompt-engineering, self-evolution, evals, agents.

### CTO Architect (`cto-architect`)
Verifies every completed phase: exists? implemented? usable? SOTA? integrated? data-driven?

### Edge Case Architect (`edge-case-architect`)
Verifies robustness of fixes: empty inputs, crash recovery, concurrency, permissions.

### SOTA Research (`docs/pesquisas/`)
18 research domains. Every fix cites its research basis.

### 11 Gate Scripts (`make check-*`)
Architecture, unwrap, panic, unsafe, sizes, secrets, changelog, complexity,
I/O tests, SOTA DoD (quick and full).

## Plugin Agents (9 internal)

| Agent | Phase | Role |
|-------|-------|------|
| `chief-evolver` | All | Orchestrator — meetings, strategy, delegates to domain architects |
| `sota-researcher` | 0 | Deep SOTA research via domain architects + papers |
| `e2e-prober` | 1 | Runs deterministic probe scripts |
| `gap-analyzer` | 2 | Weighted scoring + domain architect consultation |
| `hypothesis-generator` | 3 | SOTA-grounded fix proposal |
| `implementation-coder` | 3 | Writes production Rust with TDD |
| `evolution-verifier` | 4 | Baseline comparison, KEEP/DISCARD |
| `quality-evaluator` | Gates | Scores phases 0.0-1.0, repeats if < 0.7 |
| `report-writer` | 5 | Final report with trends |

## Output Structure

```
sota-output/
├── research/     # Phase 0 research reports
├── probes/       # Deterministic probe JSON results
├── analysis/     # Phase 2 gap analysis (with SOTA citations)
├── baselines/    # Pre-fix JSON snapshots
├── progress/     # history.jsonl (every iteration logged)
└── report/       # Final evolution report
```

## Tests

```bash
bash tests/test-hook-logic.sh  # 53 tests
```
