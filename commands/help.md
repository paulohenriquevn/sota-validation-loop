---
name: help
description: Explain SOTA validation loop and available commands
user-invocable: true
allowed-tools: Read
---

# SOTA Validation Loop — Help

## What It Does

Autonomous loop that validates ALL features of your project against evidence-based SOTA thresholds. It:

1. **Probes** every feature (tools, CLI commands, providers, languages, runtime phases)
2. **Analyzes** results to identify the weakest component
3. **Refines** the weakest feature with targeted improvements
4. **Validates** that the improvement worked (keep/discard)
5. **Reports** final state with pass/fail per feature

Iterates until all dod-gates pass or max cycles reached.

## 5-Phase State Machine

```
Phase 1: PROBE    → Run E2E probes against feature registry
Phase 2: ANALYZE  → Compare against thresholds, identify worst gap
Phase 3: REFINE   → Propose and apply targeted fix (human-gated)
Phase 4: VALIDATE → Rerun probes, compare before/after, keep or discard
Phase 5: REPORT   → Final report with pass/fail per feature

Loop-back: If features still failing → return to Phase 1
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
  --max-cycles N         Max refinement cycles (default: 5)
  --budget N             Max USD budget (default: 50)
  --completion-done TEXT  Promise text that terminates the loop
```

## Key Principles

- **Evidence-based**: Every threshold cites a research paper or internal benchmark
- **Feature-granular**: Validates per-tool, per-provider, per-language — not just aggregates
- **Keep/discard**: Changes that don't improve metrics are automatically reverted
- **Human-gated**: Code changes require explicit approval before merge
- **Budget-capped**: Hard USD limit prevents runaway costs

## Agents (8 specialists)

1. **e2e-prober** — Runs probes against feature registry
2. **gap-analyzer** — Identifies worst-performing feature
3. **hypothesis-generator** — Proposes targeted improvement
4. **implementation-coder** — Applies fix with TDD
5. **validation-runner** — Retests and compares
6. **quality-evaluator** — Keep/discard gate (threshold 0.7)
7. **report-writer** — Final pass/fail report
8. **chief-validator** — Orchestrates, conducts meetings, decides loop-back
