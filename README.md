# SOTA Validation Loop

Autonomous Claude Code plugin that validates ALL features of a project against
evidence-based SOTA thresholds. Identifies gaps, proposes fixes, retests, and
iterates with keep/discard pattern until all quality gates pass.

## Install

```bash
claude install /path/to/sota-validation-loop
# or
claude install paulohenriquevn/sota-validation-loop
```

## Prerequisites

Your project needs two TOML files:

1. **`docs/sota-thresholds.toml`** — DOD-gates with floors and research citations
2. **`docs/feature-registry.toml`** — Every feature mapped to a probe + pass/fail threshold

## Quick Start

```bash
# Start the autonomous validation loop
/sota-loop --max-cycles 3 --budget 20

# Check status at any time
/sota-status

# Cancel if needed
/sota-cancel
```

## How It Works

```
┌─────────┐     ┌─────────┐     ┌─────────┐     ┌──────────┐     ┌─────────┐
│ Phase 1  │────▶│ Phase 2  │────▶│ Phase 3  │────▶│ Phase 4   │────▶│ Phase 5  │
│ PROBE    │     │ ANALYZE  │     │ REFINE   │     │ VALIDATE  │     │ REPORT   │
│ Run E2E  │     │ Find gap │     │ Fix it   │     │ Keep or   │     │ Summary  │
│ probes   │     │ root     │     │ with TDD │     │ discard   │     │          │
└─────────┘     │ cause    │     │          │     └──────────┘     └─────────┘
     ▲          └─────────┘     └─────────┘           │
     │                                                 │
     └─────────── LOOP BACK (if features still fail) ──┘
```

Each phase has:
- **Quality gates** (score >= 0.7 to advance)
- **Hard blocks** (evidence required)
- **Max iterations** (timeout advances to next phase)

## Architecture

```
sota-validation-loop/
├── .claude-plugin/
│   ├── plugin.json          # Plugin manifest
│   └── marketplace.json     # Marketplace metadata
├── hooks/
│   ├── hooks.json           # Stop hook registration
│   └── stop-hook.sh         # Autonomous loop engine (Ralph Wiggum pattern)
├── commands/
│   ├── sota-loop.md         # /sota-loop — start the loop
│   ├── sota-status.md       # /sota-status — view progress
│   ├── sota-cancel.md       # /sota-cancel — stop the loop
│   └── help.md              # /help — explain the system
├── agents/
│   ├── chief-validator.md   # Orchestrator — meetings, strategy, loop-back
│   ├── e2e-prober.md        # Phase 1 — run probes per feature
│   ├── gap-analyzer.md      # Phase 2 — identify worst gap
│   ├── hypothesis-generator.md  # Phase 3 — propose fix
│   ├── implementation-coder.md  # Phase 3 — apply fix with TDD
│   ├── validation-runner.md # Phase 4 — retest, keep/discard
│   ├── quality-evaluator.md # Gates — score phases 0.0-1.0
│   └── report-writer.md     # Phase 5 — final report
├── templates/
│   └── sota-prompt.md       # Main autonomous agent prompt
├── scripts/
│   └── setup-sota-loop.sh   # Initialization script
└── README.md
```

## Evidence Base

Based on research from:
- **Tsinghua ablation study**: Self-evolution loop +4.8 SWE-Bench (only consistently beneficial module)
- **Stanford harness engineering**: 6x performance from harness alone
- **Anthropic long-running agents**: Planner→Generator→Evaluator pattern
- **Karpathy autoresearch**: Keep/discard pattern for quality iteration

Key anti-patterns avoided:
- Verifiers as separate agents (-0.8 to -8.4 points)
- Multi-candidate search (-2.4 points)
- 16-agent swarms (no evidence of benefit beyond 4-5 agents)

## Configuration

The stop-hook reads configuration from `.claude/sota-loop.local.md` (created by setup script):

| Parameter | Default | Description |
|-----------|---------|-------------|
| max_refinement_cycles | 5 | Max times the loop restarts |
| max_global_iterations | 30 | Hard iteration cap |
| budget_usd | 50 | Hard cost cap |
| quality_threshold | 0.7 | Min score to advance phase |

## License

MIT
