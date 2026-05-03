---
name: sota-loop
description: Start autonomous SOTA evolution loop — evolves the system until ALL features reach SOTA thresholds
user-invocable: true
hide-from-slash-command-tool: "true"
allowed-tools: Bash(bash *), Read, Glob, Grep, Agent, Write, Edit
argument-hint: "[--thresholds PATH] [--registry PATH] [--max-cycles N] [--budget N] [--completion-done TEXT]"
---

# SOTA Evolution Loop — Start

## Objective

This is NOT a validation tool. This is an **autonomous evolution engine**.

The loop writes REAL production code — Rust, tests, modules — into the Theo Code
workspace until every feature reaches its SOTA threshold. It doesn't just find
problems; it FIXES them. Feature by feature, crate by crate, until the system
is state-of-the-art or the budget runs out.

**The target is SOTA. "Working" is not enough. "Good enough" does not exist.**

## How it evolves the system

```
Phase 0: RESEARCH   Read docs/pesquisas/, consult 17 domain architects,
                    verify thresholds are actually SOTA (not stale numbers).
                    95% confidence required on ALL thresholds.

Phase 1: PROBE      Run deterministic probes against ALL features.
                    Measure: what's SOTA? What's below?

Phase 2: ANALYZE    Score every failing feature. The worst gap + highest
                    SOTA impact goes first. Consult domain architect for
                    root cause.

Phase 3: PLAN       Create evolution plan with tasks, acceptance criteria,
                    and DoDs. Run /edge-case-plan. No code without a plan.

Phase 4: EVOLVE     Execute the plan. Read the SOTA research. Read the
                    reference repos. Write the FIX with TDD.
                    This is where the system GROWS — real production code.

Phase 5: VERIFY     Compare before/after. Improved? KEEP the code.
                    Regressed? DISCARD via deterministic git rollback.
                    CTO architect verifies: exists? implemented? SOTA? integrated?

Phase 6: REPORT     Progress report. Features still failing?
                    → LOOP BACK to Phase 1. Next feature. Next evolution.
```

The loop keeps evolving until:
- ALL DOD-gates pass (SOTA achieved), OR
- Budget exhausted, OR
- Stall detected (2 cycles with zero progress)

## What makes this different from a linter or CI

| Traditional CI | SOTA Evolution Loop |
|---|---|
| Reports problems | **Fixes** problems |
| Runs once | **Loops** until SOTA |
| Static thresholds | **Research-backed** thresholds |
| Generic rules | **Domain architect** guidance per feature |
| No code generation | **Writes production Rust** with TDD |
| Manual rollback | **Deterministic git rollback** on regression |

## Resources it uses

### 17 Domain Architects (`.claude/agents/*-architect`)
Each domain has a specialist that knows the SOTA research and monitors alignment.
The loop consults the relevant architect before proposing and implementing fixes.

### SOTA Research (`docs/pesquisas/`)
18 research domains with INDEX.md files, papers, and reference implementations.
Every fix must be grounded in research — no invented patterns.

### Reference Repos (`referencias/`)
10 AI agent repos mapped to 14 categories. The loop reads how others solved
the same problem before writing code.

### Gate Scripts (`scripts/check-*.sh`)
11 enforcement gates validate every fix: architecture, unwrap, panic, unsafe,
sizes, secrets, changelog, complexity, I/O tests, SOTA DoD.

### CTO Architect (`cto-architect`)
Verifies every completed phase: Does the code exist? Is it 100% implemented?
Is it SOTA-backed? Is it integrated? Is it data-driven?

## Start

Execute the setup script to initialize:

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-sota-loop.sh" $ARGUMENTS
```

$ARGUMENTS

The stop hook is now active. On every iteration, the hook reads your output
markers, advances/repeats phases, saves baselines, detects stalls, and
re-injects the prompt. You will see your previous work in files and git
history — this is the self-referential loop that drives evolution.

CRITICAL RULES:
1. You are FULLY AUTONOMOUS — apply fixes, test, keep/discard without asking.
2. Every fix must be grounded in SOTA research and validated by domain architects.
3. If a completion promise is set, you may ONLY output it when the statement
   is completely and unequivocally TRUE. The loop continues until genuine completion.
4. "Working" is NOT the goal. SOTA is the goal.

Use /sota-status to check progress. Use /sota-cancel to stop.
