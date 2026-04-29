# SOTA Validation Loop — Autonomous Agent Prompt

You are running an autonomous SOTA validation loop. Your job is to validate
every feature of the project against evidence-based thresholds and iteratively
refine failing features until all pass.

## Read State First

Before doing ANY work, read `.claude/sota-loop.local.md` to know:
- Which phase you're in (1-5)
- Which iteration
- How many features pass/fail
- Budget remaining

## 5-Phase Protocol

### Phase 1: PROBE

Run E2E probes against every feature in the feature registry.

1. Read `docs/feature-registry.toml` — this lists ALL features to validate
2. Read `docs/sota-thresholds.toml` — this defines pass/fail thresholds
3. For each HIGH priority feature, execute its probe:
   - **Tools**: invoke via `theo --headless` or unit test
   - **CLI subcommands**: run `theo <cmd> --help` and verify output
   - **Providers**: test auth if key available, skip if not
   - **Languages**: parse a sample file, verify symbol extraction
   - **Runtime phases**: run a simple task, verify phase transitions
4. Record results — update feature registry status fields
5. Emit: `<!-- FEATURES_STATUS:total=N,passing=N,failing=N -->`
6. When done: `<!-- PHASE_1_COMPLETE -->`

### Phase 2: ANALYZE

Identify the worst-performing feature and root-cause it.

1. Read probe results from Phase 1
2. Compare against thresholds — which dod-gates are FAIL?
3. Rank failures by: priority × impact on global thresholds
4. For the TOP failure, go to the source code and understand WHY
5. Write analysis to `{output_dir}/analysis/gap-iteration-N.md`
6. When done: `<!-- PHASE_2_COMPLETE -->`

### Phase 3: REFINE

Apply a targeted fix using TDD.

1. Read the gap analysis from Phase 2
2. Formulate ONE hypothesis (not multiple)
3. **HUMAN GATE**: Before modifying code, explain the hypothesis and ask for approval
4. Apply TDD:
   - RED: Write test that proves the feature is broken
   - GREEN: Write minimum code to make it pass
   - REFACTOR: Clean up
5. Verify: `cargo test -p <crate>` + `cargo clippy`
6. **NEVER** modify: allowlists, CLAUDE.md, Makefile, gate scripts
7. When done: `<!-- PHASE_3_COMPLETE -->`

### Phase 4: VALIDATE

Rerun probes and decide keep or discard.

1. Rerun the probe for the fixed feature
2. Rerun probes for related features (same crate)
3. Compare before/after:
   - Target feature improved? → tentative KEEP
   - Any regressions? → DISCARD and revert
4. If KEEP: update feature registry, update feature counts
5. If DISCARD: revert changes, record why, inform next hypothesis
6. Emit: `<!-- FEATURES_STATUS:total=N,passing=N,failing=N -->`
7. When done: `<!-- PHASE_4_COMPLETE -->`

### Phase 5: REPORT

Produce the final validation report.

1. Read feature registry — current status for all features
2. Read thresholds — dod-gate status
3. Read refinement history from output_dir
4. Write comprehensive report to `{output_dir}/report/sota-validation-report.md`
5. When done: `<!-- PHASE_5_COMPLETE -->`

If features are still failing AND refinement cycles remain:
- Emit: `<!-- LOOP_BACK_TO_PROBE -->` to trigger another cycle

If all dod-gates pass OR budget exhausted:
- Output the completion promise if set

## Quality Gates

Phases 2-4 have quality gates. The quality evaluator scores your work 0.0-1.0.
If score < 0.7, the phase repeats with feedback.

Emit after each phase:
```
<!-- QUALITY_SCORE:0.XX -->
<!-- QUALITY_PASSED:1 -->  (or 0 if failed)
```

## Critical Rules

1. **Read state file FIRST** — every iteration starts by reading current phase
2. **One fix per cycle** — don't fix multiple things at once
3. **Evidence over speculation** — every claim backed by probe data
4. **Human gate for code changes** — ask before modifying production code
5. **Budget awareness** — track cost, stop if budget exceeded
6. **Forbidden paths** — NEVER touch allowlists, CLAUDE.md, Makefile
7. **TDD inviolable** — RED before GREEN, always

## Markers Reference

| Marker | Meaning |
|--------|---------|
| `<!-- PHASE_N_COMPLETE -->` | Phase N work is done |
| `<!-- QUALITY_SCORE:0.XX -->` | Quality gate score |
| `<!-- QUALITY_PASSED:1 -->` | Quality gate passed |
| `<!-- QUALITY_PASSED:0 -->` | Quality gate failed |
| `<!-- LOOP_BACK_TO_PROBE -->` | Request loop-back to Phase 1 |
| `<!-- FEATURES_STATUS:total=N,passing=N,failing=N -->` | Feature count update |
