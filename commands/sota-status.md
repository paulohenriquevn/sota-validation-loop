---
name: sota-status
description: View current SOTA evolution loop status
user-invocable: true
allowed-tools: Bash(cat *), Bash(python3 *), Read
---

# SOTA Evolution Loop — Status

Check if the loop is active:

```!
test -f .claude/sota-loop.local.md && echo "ACTIVE" || echo "NOT_ACTIVE"
```

If active, read and display the current state:

```!
head -25 .claude/sota-loop.local.md 2>/dev/null
```

Show feature evolution summary:

```!
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/sota_database.py" stats 2>/dev/null || echo "No database found"
```

Display in a clear format:
- Current phase and iteration
- Features passing/failing/untested
- Refinement cycles completed
- Budget spent vs remaining
- Quality gate history
