---
name: sota-cancel
description: Cancel active SOTA validation loop
user-invocable: true
allowed-tools: Bash(cat *), Bash(rm *), Read
---

# Cancel SOTA Validation Loop

To cancel the SOTA validation loop:

1. Check if `.claude/sota-loop.local.md` exists using Bash: `test -f .claude/sota-loop.local.md && echo "EXISTS" || echo "NOT_FOUND"`

2. **If NOT_FOUND**: Say "No active SOTA validation loop found."

3. **If EXISTS**:
   - Read `.claude/sota-loop.local.md` to get the current state
   - Display: phase, iteration, features passing/failing, cycles completed
   - Remove the file using Bash: `rm -f .claude/sota-loop.local.md`
   - Report: "Cancelled SOTA validation loop (was at phase N, cycle M, features X/Y passing)"
   - Note: All output files are preserved in the output directory.
