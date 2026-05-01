---
name: sota-cancel
description: Cancel active SOTA evolution loop
user-invocable: true
allowed-tools: Bash(cat *), Bash(rm *), Read
---

# Cancel SOTA Evolution Loop

To cancel the SOTA evolution loop:

1. Check if `.claude/sota-loop.local.md` exists using Bash: `test -f .claude/sota-loop.local.md && echo "EXISTS" || echo "NOT_FOUND"`

2. **If NOT_FOUND**: Say "No active SOTA evolution loop found."

3. **If EXISTS**:
   - Read `.claude/sota-loop.local.md` to get the current state
   - Display: phase, iteration, features passing/failing, cycles completed
   - Remove the file using Bash: `rm -f .claude/sota-loop.local.md`
   - Report: "Cancelled SOTA evolution loop (was at phase N, cycle M, features X/Y passing)"
   - Note: All output files are preserved in the output directory.
