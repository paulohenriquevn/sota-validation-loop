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

If active, read and display the current state (frontmatter only):

```!
awk '/^---$/{n++; if(n==2) exit; next} n==1{print}' .claude/sota-loop.local.md 2>/dev/null
```

Show feature evolution summary:

```!
python3 - <<'PY'
from pathlib import Path
import json
import sys

state_path = Path(".claude/sota-loop.local.md")
if not state_path.exists():
    print("No active SOTA evolution loop found.")
    sys.exit(0)

text = state_path.read_text()
parts = text.split("---")
frontmatter = parts[1] if len(parts) >= 3 else ""
state = {}
for line in frontmatter.splitlines():
    if ":" not in line:
        continue
    key, value = line.split(":", 1)
    state[key.strip()] = value.strip().strip('"')

progress_path = Path(state.get("output_dir", "./sota-output")) / "progress" / "history.jsonl"
quality_history = []
if progress_path.exists():
    for raw in progress_path.read_text().splitlines():
        if not raw.strip():
            continue
        try:
            entry = json.loads(raw)
        except json.JSONDecodeError:
            continue
        score = entry.get("quality_score")
        if score not in (None, ""):
            quality_history.append(str(score))

print("Feature summary:")
print(f"  passing={state.get('features_passing', '?')}")
print(f"  failing={state.get('features_failing', '?')}")
print(f"  total={state.get('features_total', '?')}")
print(f"  cycles={state.get('refinement_cycles', '?')}/{state.get('max_refinement_cycles', '?')}")
print(f"  budget=${state.get('spent_usd', '?')}/${state.get('budget_usd', '?')}")
print("  quality_history=" + (", ".join(quality_history[-5:]) if quality_history else "none"))
PY
```

Display in a clear format:
- Current phase and iteration
- Features passing/failing/untested
- Refinement cycles completed
- Budget spent vs remaining
- Quality gate history
