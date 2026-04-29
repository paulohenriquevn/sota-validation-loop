---
name: help
description: Explain SOTA validation loop and available commands
user-invocable: true
allowed-tools: Read
---

# SOTA Validation Loop — Help

## What It Does

Autonomous loop that validates ALL features of your project against evidence-based SOTA thresholds. It:

0. **Researches** current state-of-the-art — verifies thresholds are fresh
1. **Probes** every feature using deterministic probe scripts
2. **Analyzes** results with weighted scoring to identify the worst gap
3. **Refines** the weakest feature with targeted TDD improvements
4. **Validates** using persisted baselines — keep/discard with deterministic rollback
5. **Reports** final state with progress history and stall analysis

Iterates until all dod-gates pass, stall detected, or max cycles reached.

## 6-Phase State Machine

```
Phase 0: RESEARCH  → Deep SOTA research, update thresholds with fresh evidence
Phase 1: PROBE     → Run deterministic probe scripts + manual probes
Phase 2: ANALYZE   → Weighted scoring algorithm, root cause at file:line
Phase 3: REFINE    → Validated hypothesis + TDD fix (baseline auto-saved)
Phase 4: VALIDATE  → Compare against baseline, DISCARD → git rollback
Phase 5: REPORT    → Final report with progress trends

Loop-back: If features still failing → return to Phase 1
Stop: All pass, stall detected, budget exhausted, or max cycles
```

## Commands

| Command | Description |
|---------|-------------|
| `/sota-loop` | Start the validation loop |
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

## Key Principles

- **Deep Research**: Phase 0 ensures thresholds are actually SOTA, not stale
- **Deterministic probes**: `scripts/probe-runner.sh` — repeatable, not ad-hoc
- **Weighted scoring**: Gap analysis uses concrete 40%/30%/20%/10% weights
- **Validated hypotheses**: File paths verified via `ls`/`grep` before proposing
- **Deterministic rollback**: `<!-- DISCARD -->` → `git checkout` via hook
- **Baseline persistence**: JSON snapshots for accurate before/after comparison
- **Stall detection**: No progress for 2 cycles → auto-stop
- **Evidence-based**: Every threshold cites a research paper or internal benchmark

## Agents (9 specialists)

1. **sota-researcher** — Phase 0: Deep SOTA research, threshold verification
2. **e2e-prober** — Phase 1: Runs deterministic probe scripts
3. **gap-analyzer** — Phase 2: Weighted scoring, root cause at file:line
4. **hypothesis-generator** — Phase 3: Validated hypothesis with path checks
5. **implementation-coder** — Phase 3: Applies fix with strict TDD
6. **validation-runner** — Phase 4: Baseline comparison, DISCARD marker
7. **quality-evaluator** — Gates: Scores phases with verification commands
8. **report-writer** — Phase 5: Final report with progress trends
9. **chief-validator** — Orchestrator: meetings, strategy, loop-back/stop

## Output Structure

```
sota-output/
├── research/     # Phase 0 research reports
├── probes/       # Deterministic probe JSON results
├── analysis/     # Phase 2 gap analysis
├── baselines/    # Pre-fix snapshots
├── progress/     # history.jsonl (every iteration)
└── report/       # Final validation report
```

## Tests

```bash
bash tests/test-hook-logic.sh  # 53 tests
```
