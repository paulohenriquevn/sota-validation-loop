---
name: sota-loop
description: Start autonomous SOTA validation loop
user-invocable: true
hide-from-slash-command-tool: "true"
allowed-tools: Bash(bash *), Read, Glob, Grep, Agent, Write, Edit
argument-hint: "[--thresholds PATH] [--registry PATH] [--max-cycles N] [--budget N] [--completion-done TEXT]"
---

# SOTA Validation Loop — Start

Execute the setup script to initialize the SOTA validation loop:

```!
bash "${CLAUDE_PLUGIN_ROOT}/scripts/setup-sota-loop.sh" $ARGUMENTS
```

🔄 SOTA validation loop activated in this session!

The loop starts at **Phase 0: RESEARCH** — deep research to verify thresholds
are actually SOTA before any validation begins. Then proceeds through:
Phase 1 (PROBE) → Phase 2 (ANALYZE) → Phase 3 (REFINE) → Phase 4 (VALIDATE) → Phase 5 (REPORT)

The stop hook is now active. When you try to exit, the SAME PROMPT will be
fed back to you. You'll see your previous work in files, creating a
self-referential loop where you iteratively improve features until all
dod-gates pass.

⚠️  WARNING: This loop runs until all features pass or max cycles reached.
    Use /sota-cancel to stop manually.

🔄

$ARGUMENTS

Please work on the task. When you try to exit, the SOTA loop will feed the SAME PROMPT back to you for the next iteration. You'll see your previous work in files and git history, allowing you to iterate and improve.

CRITICAL RULE: If a completion promise is set, you may ONLY output it when the statement is completely and unequivocally TRUE. Do not output false promises to escape the loop, even if you think you're stuck or should exit for other reasons. The loop is designed to continue until genuine completion.
